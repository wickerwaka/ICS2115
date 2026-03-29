#!/usr/bin/env python3
"""Convert MAME ICS2115 I/O log (CSV) to testbench script commands.

Input format (one per line):
    write,PP,VV   — host wrote value VV to port PP
    read,PP,VV    — host read value VV from port PP
    irq            — IRQ handler was called

Output format:
    pwrite 0xPP 0xVV
    pexpect 0xPP 0xVV
    wait_irq <timeout>
"""

import argparse
import os
import sys
from datetime import datetime


def convert(infile, outfile, timeout):
    writes = 0
    reads = 0
    irqs = 0
    total = 0

    outfile.write(f"# Converted from {os.path.basename(infile.name)}\n")
    outfile.write(f"# Generated {datetime.now().isoformat()}\n")
    outfile.write(f"# wait_irq timeout: {timeout} cycles\n")
    outfile.write("#\n")

    for line in infile:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        total += 1

        if line == "irq":
            outfile.write(f"wait_irq {timeout}\n")
            irqs += 1
            continue

        parts = line.split(",")
        if len(parts) != 3:
            print(f"WARNING: skipping malformed line {total}: {line!r}", file=sys.stderr)
            continue

        action, port, value = parts
        port = port.strip()
        value = value.strip()

        if action == "write":
            outfile.write(f"pwrite 0x{port} 0x{value}\n")
            writes += 1
        elif action == "read":
            outfile.write(f"pexpect 0x{port} 0x{value}\n")
            reads += 1
        else:
            print(f"WARNING: unknown action '{action}' on line {total}: {line!r}", file=sys.stderr)

    print(f"Converted {total} lines: {writes} writes, {reads} reads, {irqs} irqs", file=sys.stderr)
    return total, writes, reads, irqs


def main():
    parser = argparse.ArgumentParser(description="Convert MAME ICS2115 I/O log to testbench script")
    parser.add_argument("input", help="Input MAME CSV log file")
    parser.add_argument("output_positional", nargs="?", default=None,
                        help="Output script file (positional, optional)")
    parser.add_argument("--output", "-o", dest="output_flag", default=None,
                        help="Output script file (default: stdout)")
    parser.add_argument("--timeout", "-t", type=int, default=10000000,
                        help="Cycle timeout for wait_irq (default: 10000000)")
    args = parser.parse_args()

    # --output flag takes precedence over positional output arg
    output_path = args.output_flag or args.output_positional

    with open(args.input, "r") as infile:
        if output_path:
            with open(output_path, "w") as outfile:
                convert(infile, outfile, args.timeout)
        else:
            convert(infile, sys.stdout, args.timeout)


if __name__ == "__main__":
    main()
