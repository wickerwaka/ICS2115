#!/usr/bin/env python3
"""Generate a test ROM containing two distinct 16-bit signed waveforms.

Layout (4096 bytes total):
  0x0000 - 0x07FF: 1024-sample sine wave (2048 bytes)
  0x0800 - 0x0FFF: 1024-sample square wave (2048 bytes)

Both stored as little-endian 16-bit signed PCM.
"""
import math
import os
import struct

NUM_SAMPLES = 1024
AMPLITUDE = 32000  # slightly below 16-bit max to avoid clipping

# Sine wave: one complete cycle
sine_samples = [int(AMPLITUDE * math.sin(2 * math.pi * i / NUM_SAMPLES))
                for i in range(NUM_SAMPLES)]

# Square wave: one complete cycle (half positive, half negative)
square_samples = [AMPLITUDE if i < NUM_SAMPLES // 2 else -AMPLITUDE
                  for i in range(NUM_SAMPLES)]

script_dir = os.path.dirname(os.path.abspath(__file__))
rom_path = os.path.join(script_dir, 'multi_test.rom')

with open(rom_path, 'wb') as f:
    # Sine at offset 0x0000
    for s in sine_samples:
        f.write(struct.pack('<h', s))
    # Square at offset 0x0800
    for s in square_samples:
        f.write(struct.pack('<h', s))

rom_size = (NUM_SAMPLES + NUM_SAMPLES) * 2
print(f"Generated multi_test.rom: {rom_size} bytes")
print(f"  Sine   @ 0x0000: {NUM_SAMPLES} samples, peak={max(abs(s) for s in sine_samples)}")
print(f"  Square @ 0x0800: {NUM_SAMPLES} samples, peak={max(abs(s) for s in square_samples)}")
