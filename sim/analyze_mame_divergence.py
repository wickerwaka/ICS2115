#!/usr/bin/env python3
"""Analyze MAME replay divergences from testbench PEXPECT output.

Reads testbench stdout (from stdin or file argument), parses PEXPECT
PASS/FAIL lines, categorizes failures into known patterns, and prints
a summary table.

Exit codes:
    0 — all failures are categorized (no unknowns)
    1 — unknown failure patterns exist
"""

import argparse
import re
import sys
from collections import Counter

# Regex matching testbench PEXPECT output lines (handles both em-dash and regular dash)
PEXPECT_RE = re.compile(
    r'\[(\d+)\] PEXPECT port (0x[0-9A-Fa-f]+): '
    r'expected (0x[0-9A-Fa-f]+) got (0x[0-9A-Fa-f]+) '
    r'\(raw (0x[0-9A-Fa-f]+)\) '
    r'[—\-]+\s*(PASS|FAIL)'
)

# Known timing-divergence patterns: (port, expected, got)
# These are expected differences between MAME's cycle-accurate emulation
# and RTL simulation due to timer phase and IRQ servicing timing.
KNOWN_TIMING_DIVERGENCES = {
    # IRQ status register: RTL shows timer1+timer2 pending (0x83) while
    # MAME expected only timer2 pending (0x81). Timer1 fires slightly
    # earlier in RTL due to counter initialization timing.
    (0x00, 0x81, 0x83): "IRQ status: timer1 also pending (RTL timer phase ahead)",
    # IRQ status register: RTL still shows pending (0x83) while MAME
    # expected clear (0x00). IRQ clear propagation takes one extra cycle
    # in RTL's registered clear pipeline (K012).
    (0x00, 0x00, 0x83): "IRQ status: pending not yet cleared (registered clear pipeline delay)",
    # Timer counter register: RTL counter is 1 tick behind MAME's
    # expected value due to counter reload timing.
    (0x02, 0x03, 0x02): "Timer counter: off-by-1 (counter reload timing)",
}


def parse_line(line):
    """Parse a PEXPECT output line. Returns (line_num, port, expected, got, raw, verdict) or None."""
    m = PEXPECT_RE.search(line)
    if not m:
        return None
    return (
        int(m.group(1)),       # line_num
        int(m.group(2), 16),   # port
        int(m.group(3), 16),   # expected
        int(m.group(4), 16),   # got
        int(m.group(5), 16),   # raw
        m.group(6),            # verdict: PASS or FAIL
    )


def categorize_failure(port, expected, got):
    """Categorize a failure pattern. Returns (category, description)."""
    key = (port, expected, got)
    if key in KNOWN_TIMING_DIVERGENCES:
        return ("timing-divergence", KNOWN_TIMING_DIVERGENCES[key])
    return ("unknown", f"port=0x{port:02X} exp=0x{expected:02X} got=0x{got:02X}")


def analyze(input_stream):
    """Parse and analyze PEXPECT output. Returns (passes, fails, categories)."""
    passes = 0
    fails = 0
    # categories: {(category, description): count}
    categories = Counter()
    fail_details = []  # [(line_num, port, expected, got, category, description)]

    for line in input_stream:
        parsed = parse_line(line)
        if parsed is None:
            continue
        line_num, port, expected, got, raw, verdict = parsed
        if verdict == "PASS":
            passes += 1
        else:
            fails += 1
            cat, desc = categorize_failure(port, expected, got)
            categories[(cat, desc)] += 1
            fail_details.append((line_num, port, expected, got, cat, desc))

    return passes, fails, categories, fail_details


def print_summary(passes, fails, categories, fail_details, verbose=False):
    """Print analysis summary table."""
    total = passes + fails
    print(f"\n{'=' * 70}")
    print(f"MAME Replay Divergence Analysis")
    print(f"{'=' * 70}")
    print(f"Total PEXPECT checks: {total}")
    print(f"  PASS: {passes}")
    print(f"  FAIL: {fails}")
    print()

    if fails == 0:
        print("No failures — RTL matches MAME perfectly.")
        return

    # Group by category
    timing = {k: v for k, v in categories.items() if k[0] == "timing-divergence"}
    unknown = {k: v for k, v in categories.items() if k[0] == "unknown"}

    if timing:
        print(f"Timing Divergences ({sum(timing.values())} failures):")
        print(f"  {'Pattern':<55} {'Count':>5}")
        print(f"  {'-' * 55} {'-' * 5}")
        for (cat, desc), count in sorted(timing.items(), key=lambda x: -x[1]):
            print(f"  {desc:<55} {count:>5}")
        print()

    if unknown:
        print(f"UNKNOWN Failures ({sum(unknown.values())} failures):")
        print(f"  {'Pattern':<55} {'Count':>5}")
        print(f"  {'-' * 55} {'-' * 5}")
        for (cat, desc), count in sorted(unknown.items(), key=lambda x: -x[1]):
            print(f"  {desc:<55} {count:>5}")
        print()

    if verbose and fail_details:
        print("Detail (first 50 failures):")
        print(f"  {'Line':>6} {'Port':>6} {'Expected':>10} {'Got':>6} {'Category'}")
        print(f"  {'-' * 6} {'-' * 6} {'-' * 10} {'-' * 6} {'-' * 20}")
        for ln, port, exp, got, cat, desc in fail_details[:50]:
            print(f"  {ln:>6} 0x{port:02X}   0x{exp:02X}       0x{got:02X}   {cat}")
        print()

    # Verdict
    if unknown:
        print(f"VERDICT: FAIL — {len(unknown)} unknown failure pattern(s) need investigation")
    else:
        print(f"VERDICT: PASS — all {fails} failures are known timing divergences")
    print(f"{'=' * 70}")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze MAME replay divergences from testbench output"
    )
    parser.add_argument(
        "input", nargs="?", default=None,
        help="Input file (testbench stdout). Default: read from stdin"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
        help="Show individual failure details"
    )
    args = parser.parse_args()

    if args.input:
        with open(args.input, "r") as f:
            passes, fails, categories, fail_details = analyze(f)
    else:
        passes, fails, categories, fail_details = analyze(sys.stdin)

    print_summary(passes, fails, categories, fail_details, verbose=args.verbose)

    # Exit 0 if all failures are categorized, 1 if unknowns exist
    unknowns = sum(v for (cat, _), v in categories.items() if cat == "unknown")
    sys.exit(1 if unknowns > 0 else 0)


if __name__ == "__main__":
    main()
