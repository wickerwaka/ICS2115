#!/usr/bin/env python3
"""Analyze a 16-bit stereo WAV file — per-channel peak amplitudes and separation checks.

Usage:
  python3 analyze_wav.py <file.wav> [options]

Options:
  --min-peak N          Exit nonzero if overall peak < N
  --check-separation    Verify stereo separation: dominant channel must be >= 4x
                        the opposite channel peak in each half of the file
  --help                Show this help message
"""
import argparse
import struct
import sys
import os


def read_wav(path):
    """Read a 16-bit stereo WAV file, return (sample_rate, frames).

    frames is a list of (left, right) tuples of signed 16-bit values.
    """
    with open(path, 'rb') as f:
        # RIFF header
        riff = f.read(4)
        if riff != b'RIFF':
            print(f"ERROR: not a RIFF file: {riff!r}", file=sys.stderr)
            sys.exit(1)
        f.read(4)  # file size
        wave = f.read(4)
        if wave != b'WAVE':
            print(f"ERROR: not a WAVE file: {wave!r}", file=sys.stderr)
            sys.exit(1)

        fmt_found = False
        sample_rate = 0
        num_channels = 0
        bits_per_sample = 0
        data_bytes = b''

        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                break
            chunk_id = chunk_hdr[:4]
            chunk_size = struct.unpack('<I', chunk_hdr[4:8])[0]

            if chunk_id == b'fmt ':
                fmt_data = f.read(chunk_size)
                audio_fmt = struct.unpack('<H', fmt_data[0:2])[0]
                num_channels = struct.unpack('<H', fmt_data[2:4])[0]
                sample_rate = struct.unpack('<I', fmt_data[4:8])[0]
                bits_per_sample = struct.unpack('<H', fmt_data[14:16])[0]
                fmt_found = True
                if audio_fmt != 1:
                    print(f"ERROR: not PCM format (got {audio_fmt})", file=sys.stderr)
                    sys.exit(1)
                if num_channels != 2:
                    print(f"ERROR: expected stereo (2 channels), got {num_channels}",
                          file=sys.stderr)
                    sys.exit(1)
                if bits_per_sample != 16:
                    print(f"ERROR: expected 16-bit, got {bits_per_sample}", file=sys.stderr)
                    sys.exit(1)
            elif chunk_id == b'data':
                data_bytes = f.read(chunk_size)
            else:
                f.read(chunk_size)

        if not fmt_found:
            print("ERROR: no fmt chunk found", file=sys.stderr)
            sys.exit(1)

        # Parse interleaved stereo frames
        frame_size = 4  # 2 bytes * 2 channels
        num_frames = len(data_bytes) // frame_size
        frames = []
        for i in range(num_frames):
            off = i * frame_size
            left = struct.unpack('<h', data_bytes[off:off + 2])[0]
            right = struct.unpack('<h', data_bytes[off + 2:off + 4])[0]
            frames.append((left, right))

        return sample_rate, frames


def analyze(frames):
    """Return dict with analysis results."""
    if not frames:
        return {'total_frames': 0, 'left_peak': 0, 'right_peak': 0, 'overall_peak': 0}

    left_peak = max(abs(f[0]) for f in frames)
    right_peak = max(abs(f[1]) for f in frames)
    overall_peak = max(left_peak, right_peak)

    return {
        'total_frames': len(frames),
        'left_peak': left_peak,
        'right_peak': right_peak,
        'overall_peak': overall_peak,
    }


def check_separation(frames):
    """Check stereo separation in first and second halves.

    Returns (ok, details_str). ok is True if dominant channel >= 4x opposite
    in both halves.
    """
    if len(frames) < 2:
        return False, "Not enough frames"

    mid = len(frames) // 2
    first_half = frames[:mid]
    second_half = frames[mid:]

    results = []
    ok = True

    for label, half in [("first_half", first_half), ("second_half", second_half)]:
        lp = max(abs(f[0]) for f in half) if half else 0
        rp = max(abs(f[1]) for f in half) if half else 0

        if lp == 0 and rp == 0:
            results.append(f"  {label}: both channels silent")
            ok = False
            continue

        if lp >= rp:
            dominant, weak, dom_name = lp, rp, "left"
        else:
            dominant, weak, dom_name = rp, lp, "right"

        ratio = dominant / weak if weak > 0 else float('inf')
        pass_str = "PASS" if ratio >= 4.0 else "FAIL"
        if ratio < 4.0:
            ok = False
        results.append(
            f"  {label}: dominant={dom_name} peak={dominant} weak={weak} "
            f"ratio={ratio:.1f}x {pass_str}"
        )

    return ok, "\n".join(results)


def main():
    parser = argparse.ArgumentParser(
        description="Analyze a 16-bit stereo WAV file"
    )
    parser.add_argument('wavfile', nargs='?', help='WAV file to analyze')
    parser.add_argument('--min-peak', type=int, default=0,
                        help='Exit nonzero if overall peak < N')
    parser.add_argument('--check-separation', action='store_true',
                        help='Verify stereo separation (dominant >= 4x opposite)')
    args = parser.parse_args()

    if args.wavfile is None:
        parser.print_help()
        sys.exit(0)

    if not os.path.exists(args.wavfile):
        print(f"ERROR: file not found: {args.wavfile}", file=sys.stderr)
        sys.exit(1)

    sample_rate, frames = read_wav(args.wavfile)
    stats = analyze(frames)

    print(f"file: {args.wavfile}")
    print(f"sample_rate: {sample_rate}")
    print(f"total_frames: {stats['total_frames']}")
    print(f"left_peak: {stats['left_peak']}")
    print(f"right_peak: {stats['right_peak']}")
    print(f"overall_peak: {stats['overall_peak']}")

    exit_code = 0

    if args.min_peak > 0:
        if stats['overall_peak'] < args.min_peak:
            print(f"FAIL: overall_peak {stats['overall_peak']} < min_peak {args.min_peak}")
            exit_code = 1
        else:
            print(f"PASS: overall_peak {stats['overall_peak']} >= min_peak {args.min_peak}")

    if args.check_separation:
        sep_ok, sep_detail = check_separation(frames)
        print(f"separation_check: {'PASS' if sep_ok else 'FAIL'}")
        print(sep_detail)
        if not sep_ok:
            exit_code = 1

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
