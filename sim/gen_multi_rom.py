#!/usr/bin/env python3
"""Generate a test ROM containing 16-bit, 8-bit, and µ-law signed waveforms.

Layout (word-addressed, little-endian 16-bit words):
  Word 0x0000 (byte 0x0000): 1024-sample 16-bit sine wave (2048 bytes)
  Word 0x0400 (byte 0x0800): 1024-sample 16-bit square wave (2048 bytes)
  Word 0x0800 (byte 0x1000): 1024 8-bit signed sine samples (512 words = 1024 bytes)
  Word 0x0A00 (byte 0x1400): 1024 µ-law encoded sine samples (512 words = 1024 bytes)

Total: 0x0C00 words = 3072 words = 6144 bytes

8-bit format: signed 8-bit samples, packed 2 per 16-bit word.
  Even byte address → low byte (rom_data[7:0])
  Odd byte address  → high byte (rom_data[15:8])

µ-law format: 8-bit µ-law codewords, packed 2 per 16-bit word.
  Same byte packing as 8-bit.
  Encoding matches RTL decode in ics2115_tables.sv:
    inverted = ~byte
    exp  = (inverted >> 4) & 7
    mant = inverted & 0xF
    base = (132 << exp) - 132  (precomputed per segment)
    value = base + (mant << (exp + 3))
    sign: bit 7 of original byte (1 = negative)
"""
import math
import os
import struct

NUM_SAMPLES = 1024
AMPLITUDE_16 = 32000  # 16-bit amplitude
AMPLITUDE_8 = 120     # 8-bit amplitude (below 127 to avoid clipping)

# --- Segment base values matching RTL ---
ULAW_BASES = [0, 132, 396, 924, 1980, 4092, 8316, 16764]


def ulaw_decode(byte_val):
    """Decode a µ-law byte exactly as the RTL does."""
    inv = (~byte_val) & 0xFF
    exp = (inv >> 4) & 0x7
    mant = inv & 0xF
    value = ULAW_BASES[exp] + (mant << (exp + 3))
    # Clamp to 15-bit unsigned
    value = min(value, 32767)
    if byte_val & 0x80:
        return -value
    return value


def ulaw_encode(linear):
    """Find the µ-law byte that decodes closest to the given 16-bit linear value."""
    best_byte = 0
    best_err = abs(linear - ulaw_decode(0))
    # Search all 256 codewords — small enough for offline generation
    for b in range(256):
        decoded = ulaw_decode(b)
        err = abs(linear - decoded)
        if err < best_err:
            best_err = err
            best_byte = b
            if err == 0:
                break
    return best_byte


# --- Generate waveforms ---

# 16-bit sine
sine_16 = [int(AMPLITUDE_16 * math.sin(2 * math.pi * i / NUM_SAMPLES))
           for i in range(NUM_SAMPLES)]

# 16-bit square
square_16 = [AMPLITUDE_16 if i < NUM_SAMPLES // 2 else -AMPLITUDE_16
             for i in range(NUM_SAMPLES)]

# 8-bit sine (signed, range -120 to +120)
sine_8 = [int(AMPLITUDE_8 * math.sin(2 * math.pi * i / NUM_SAMPLES))
          for i in range(NUM_SAMPLES)]

# µ-law sine: encode 16-bit sine samples to µ-law bytes
ulaw_sine = [ulaw_encode(s) for s in sine_16]

# --- Write ROM ---
script_dir = os.path.dirname(os.path.abspath(__file__))
rom_path = os.path.join(script_dir, 'multi_test.rom')

with open(rom_path, 'wb') as f:
    # 16-bit sine at byte 0x0000
    for s in sine_16:
        f.write(struct.pack('<h', s))

    # 16-bit square at byte 0x0800
    for s in square_16:
        f.write(struct.pack('<h', s))

    # 8-bit sine at byte 0x1000: pack pairs of signed bytes into 16-bit words
    # Even byte addr = low byte, odd byte addr = high byte
    for i in range(0, NUM_SAMPLES, 2):
        lo = sine_8[i] & 0xFF      # signed→unsigned byte
        hi = sine_8[i + 1] & 0xFF
        f.write(struct.pack('<BB', lo, hi))

    # µ-law sine at byte 0x1400: same packing
    for i in range(0, NUM_SAMPLES, 2):
        lo = ulaw_sine[i]
        hi = ulaw_sine[i + 1]
        f.write(struct.pack('<BB', lo, hi))

rom_size = os.path.getsize(rom_path)
print(f"Generated multi_test.rom: {rom_size} bytes")
print(f"  16-bit Sine   @ byte 0x0000: {NUM_SAMPLES} samples, peak={max(abs(s) for s in sine_16)}")
print(f"  16-bit Square @ byte 0x0800: {NUM_SAMPLES} samples, peak={max(abs(s) for s in square_16)}")
print(f"  8-bit  Sine   @ byte 0x1000: {NUM_SAMPLES} samples, peak={max(abs(s) for s in sine_8)}")
print(f"  µ-law  Sine   @ byte 0x1400: {NUM_SAMPLES} samples (encoded)")

# Verify a few µ-law round-trip values
print(f"  µ-law verify: encode({sine_16[256]})=0x{ulaw_sine[256]:02X} → decode={ulaw_decode(ulaw_sine[256])}")
print(f"  µ-law verify: encode({sine_16[0]})=0x{ulaw_sine[0]:02X} → decode={ulaw_decode(ulaw_sine[0])}")
