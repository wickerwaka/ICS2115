#!/usr/bin/env python3
"""Generate a test ROM containing a 16-bit signed sine wave.

1024 samples of one complete sine cycle, stored as little-endian 16-bit signed.
At native playback rate (fc=0x0800), this gives one period per 1024 output samples.
"""
import math
import os
import struct

NUM_SAMPLES = 1024
AMPLITUDE = 32000  # slightly below 16-bit max to avoid clipping

samples = [int(AMPLITUDE * math.sin(2 * math.pi * i / NUM_SAMPLES))
           for i in range(NUM_SAMPLES)]

# Write to the same directory as this script (works from any cwd)
script_dir = os.path.dirname(os.path.abspath(__file__))
rom_path = os.path.join(script_dir, 'test.rom')

with open(rom_path, 'wb') as f:
    for s in samples:
        f.write(struct.pack('<h', s))  # little-endian signed 16-bit

print(f"Generated test.rom: {NUM_SAMPLES} samples, {NUM_SAMPLES * 2} bytes")
print(f"  Peak amplitude: {max(abs(s) for s in samples)}")
print(f"  Sample[0]={samples[0]}, Sample[256]={samples[256]}, Sample[512]={samples[512]}")
