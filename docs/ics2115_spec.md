# ICS2115 WaveFront Synthesizer — Hardware Reference Specification

## 1. Overview

The ICS2115 is a wavetable synthesis chip manufactured by Integrated Circuit Systems (ICS). It produces 16-bit CD-quality audio by reading sample data from external ROM or DRAM, applying per-voice volume envelopes and panning, and outputting a stereo mix to an external DAC via a serial interface. (Datasheet: p1)

### 1.1 Key Capabilities

| Parameter | Value | Source |
|-----------|-------|--------|
| Max voices | 32 | (Datasheet: p1) |
| Max sample rate | 44.1 kHz (24 voices) | (Datasheet: p1) |
| Min sample rate (32 voices) | 33.075 kHz | (MAME: stream_alloc, `clock()/(32*32)`) |
| Sample formats | 16-bit linear, 8-bit linear, 8-bit µ-law | (Datasheet: p1) |
| ROM address space | 24-bit (16 MB) | (MAME: `m_data_config` 24-bit address bus) |
| DRAM support | Up to 16 MB | (Datasheet: p1) |
| DAC output | 16-bit sign-extended to 24-bit, serial MSB-first | (Datasheet: DAC Output section) |
| Chip revision | 0x1 | (MAME: `ics2115.h` `revision = 0x1`) |
| Timers | 2 | (MAME/Datasheet) |

### 1.2 Sample Rate Formula

The output sample rate depends on the number of active oscillators:

```
sample_rate = clock / ((active_osc + 1) * 32)
```

(MAME: `device_start()` L73 — `stream_alloc(0, 2, clock() / (32 * 32))`, `device_clock_changed()`, and reg 0x0E write handler)

With a typical 33.8688 MHz clock:
- 32 voices (active_osc = 31): 33,075 Hz
- 24 voices (active_osc = 23): 44,100 Hz

The GUS/GF1 uses a different formula based on a 1.6 µs per-voice service time with a minimum of 14 voices, yielding 44.1 kHz at 14 voices. The ICS2115 appears to use a simpler integer divisor model with a different minimum voice count. (GUS SDK: Section 1.4, p3; MAME: `device_clock_changed()`)

### 1.3 Pin Groups (Summary)

| Group | Key Pins | Function |
|-------|----------|----------|
| Host Interface | SD[15:0], SA[1:0], IOR, IOW, CS, CSMM, SBHE | ISA bus register access |
| Wavetable Memory | DD[7:0], MA[10:0], CAS[3:0], ROMA[17:9], RAS, ROMEN, BYTE | ROM/DRAM sample data |
| DAC Interface | SERDATA, LRCK, BCK, WDCK | Serial audio output |
| DMA | DRQ, DACK, TC | Host DMA transfers |
| Interrupts | IRQ, MMIRQ | Synthesis and MIDI interrupts |
| Clock | XTLI, XTLO | Crystal oscillator (÷2 internally) |
| MIDI Emulation | (via CSMM-selected registers) | 6850/MPU-401 compatible |

(Datasheet: Pin Descriptions p4-11)

### 1.4 DAC Output Format

The DAC interface uses a 48-clock frame, MSB-first, left/right multiplexed serial stream:
- BCK = XTLI / 4 (always running)
- SERDATA: 16-bit internal data sign-extended to 24 bits, left then right
- LRCK: transitions at bit 0 boundaries (high→low after left bit 0, low→high after right bit 0)
- WDCK: transitions between bits 12 and 11, and after bit 0

(Datasheet: DAC Output section p11)

---

## 2. Fixed-Point Formats

All internal numeric representations use fixed-point arithmetic. Understanding these formats is critical for correct register programming and sample playback.

### 2.1 Oscillator Accumulator — 20.9 Fixed Point

The oscillator accumulator tracks the current position within a sample. It is stored as a 32-bit value internally, but only 29 bits are significant.

```
Bit layout (internal 32-bit representation):
[31:29] unused (part of saddr construction)
[28:9]  integer part — 20-bit sample address (byte address within bank)
[8:0]   fractional part — 9-bit sub-sample position (used for interpolation)
```

The full ROM address is constructed by prepending the static address register (saddr):

```
ROM address = (saddr << 20) | (acc >> 12)
```

where `acc >> 12` yields the 20-bit integer address. The lower 12 bits of `acc` contain the 9-bit fraction (bits [11:3]) plus 3 unused low bits. (MAME: `read_sample()` in `ics2115.h`, `get_sample()` L365-367)

**Register mapping:**
- Reg 0x0A (OscAccH): bits [28:16] of acc → `(acc >> 16) & 0xFFFF`
- Reg 0x0B (OscAccL): bits [15:3] of acc → `acc & 0xFFF8`
- Start/End registers (0x02-0x05) use the same 20.9 format split across high/low pairs

(MAME: `reg_read()` cases 0x0A/0x0B, `reg_write()` cases 0x0A/0x0B)

**Interpolation:**
The fractional position is used for linear interpolation between adjacent samples:

```
fract = (acc & 0xFF8) >> 3    // 8-bit fraction from bits [11:3]
sample = (sample1 << 9 + (sample2 - sample1) * fract) >> 9
```

(MAME: `get_sample()` L396-403; US Patent 6,246,774 B1 column 2 row 59)

### 2.2 Frequency Counter — 6.9+1 Fixed Point

The frequency counter (FC) register controls the playback rate of each voice. It determines how much the oscillator accumulator advances per sample tick.

```
Bit layout (16-bit register):
[15:10] integer part — 6 bits (0–63)
[9:1]   fractional part — 9 bits
[0]     unused (always 0, "last bit not used")
```

The accumulator is advanced by `fc << 2` per sample tick, which effectively shifts the 6.9 fixed-point value into the 20.9 accumulator space:

```
acc += fc << 2    // forward playback
acc -= fc << 2    // reverse playback (when invert bit set)
```

(MAME: `update_oscillator()` L306-314; `reg_write()` case 0x01 — "last bit not used!")

**Frequency calculation:**
```
playback_freq = fc * sample_rate / 1024
```

With 32 voices: `freq = fc * 33075 / 1024`
With 24 voices: `freq = fc * 44100 / 1024`

(MAME: `reg_read()` case 0x01 comment)

The GUS SDK describes the FC formula as: `fc = ((speed_khz << 9) + (divisor >> 1)) / divisor; fc = fc << 1;` where the left shift accounts for bit 0 being unused. (GUS SDK: Section 1.4 p3)

### 2.3 Volume Accumulator — Exponential (4.8 Exponent-Mantissa)

Volume is represented in an exponential format that provides approximately logarithmic scaling, giving perceptually uniform volume control.

**Internal accumulator:** 32-bit value, but only the upper bits are used:
```
Internal:  vol.acc is 32 bits
Register:  vol.regacc is 16 bits = vol.acc >> 10
Lookup:    volume index = (vol.acc >> 14) & 0xFFF  → 12-bit index into volume table
```

**Register 0x09 (VolAcc) — 16-bit:**
```
[15:8]  written/read as high byte
[7:0]   written/read as low byte
Internal: vol.acc = regacc << 10
```

(MAME: `reg_read()` case 0x09 — `voice.vol.acc >> 10`; `reg_write()` case 0x09)

**Volume Start/End registers — 8-bit (compressed):**

Registers 0x07 (VStart) and 0x08 (VEnd) are 8-bit values in 4.4 exponent-mantissa format:
```
[7:4]  exponent (0–15)
[3:0]  mantissa (0–15)
```

Internally expanded: `vol.start = data << 18` (i.e., `data << (10+8)`), placing the 8-bit compressed value into the upper portion of the 32-bit accumulator space. (MAME: `reg_write()` cases 0x07/0x08)

The GUS SDK confirms this format: "Bits 7-4: Exponent, Bits 3-0: Mantissa" for both ramp start and ramp end registers. (GUS SDK: Section 2.6.2.8-2.6.2.9)

### 2.4 Volume Increment — Rate-Scaled Step

Register 0x06 (VIncr) is an 8-bit value controlling the volume envelope ramp speed:

```
[7:6]  rate scale (2 bits) — controls the step granularity
[5:0]  increment magnitude (6 bits, range 1–63)
```

The increment is decoded into an internal add value:

```c
fine = 1 << (3 * (incr >> 6));       // rate scale: 0→1, 1→8, 2→64, 3→512
vol.add = (incr & 0x3F) << (10 - fine);
```

(MAME: `fill_output()` L445-446)

> **Uncertainty:** The `fine` calculation uses `1 << (3 * scale)` which gives {1, 8, 64, 512}, but then `10 - fine` becomes negative for scale values 2 and 3 (10-64 = -54, 10-512 = -502). This would cause undefined behavior with a left shift. The MAME implementation may have a bug here, or the shift may be interpreted as a right shift in practice. The GUS SDK describes this as: "Bits 7-6 define the rate at which the increment is applied" without specifying the exact formula. (GUS SDK: Section 2.6.2.7)

---

## 3. Lookup Tables

The ICS2115 uses three lookup tables computed at initialization. These are implemented in software (MAME) but likely correspond to hardware ROM or combinational logic in the real chip.

### 3.1 Volume Table (4096 entries)

**Purpose:** Converts the 12-bit exponential volume index (from `vol.acc >> 14`) into a linear amplitude multiplier.

**Size:** 4096 entries × 16-bit = 8 KB

**Generation formula (patent-derived):**
```c
// From US Patent 5,809,466, Section V, Subsection F (column 124, page 198)
for (int i = 0; i < 4096; i++)
    volume[i] = ((0x100 | (i & 0xFF)) << (volume_bits - 9)) >> (15 - (i >> 8));
```

Where `volume_bits = 15`. (MAME: `device_start()` L88-89, `ics2115.h` `volume_bits = 15`)

**Breakdown:**
- `i & 0xFF` = 8-bit mantissa portion of the index
- `i >> 8` = 4-bit exponent portion of the index (0–15)
- `0x100 | mantissa` = prepend implicit leading 1 (like IEEE 754 significand)
- Left shift by `(15 - 9) = 6`, then right shift by `(15 - exponent)`
- Net shift = `exponent - 9`

**Domain:** Index 0–4095 (12-bit, from volume accumulator)
**Range:** 0–32767 (15-bit linear amplitude)

**Behavior:**
- Index 0 (exp=0, mant=0): `(0x100) << 6 >> 15` = 0 (silence)
- Index 3840 (exp=15, mant=0): `(0x100) << 6 >> 0` = 0x4000 = 16384
- Index 4095 (exp=15, mant=255): `(0x1FF) << 6 >> 0` = 0x7FC0 ≈ 32704

**Approximation:** This table implements a piecewise-linear approximation of `2^(i/256)` scaled to 15 bits. The commented-out code in MAME shows the equivalent floating-point formula: `32768.0 * pow(2.0, (i-3840)/256.0)`. (MAME: `device_start()` L82-85 comments)

### 3.2 µ-Law Decode Table (256 entries)

**Purpose:** Decodes 8-bit µ-law (ITU-T G.711 / MIL-STD-188-113) compressed samples into 16-bit linear PCM.

**Size:** 256 entries × 16-bit (signed) = 512 bytes

**Generation formula:**
```c
// Step sizes per exponent segment
u16 lut[8];
const u16 lut_initial = 33 << 2;   // = 132, shifted up 2 bits for 16-bit range
for (int i = 0; i < 8; i++)
    lut[i] = (lut_initial << i) - lut_initial;

// Decode each of 256 possible input bytes
for (int i = 0; i < 256; i++) {
    const u8 exponent = (~i >> 4) & 0x07;   // bits [6:4], inverted
    const u8 mantissa = ~i & 0x0F;           // bits [3:0], inverted
    const s16 value = lut[exponent] + (mantissa << (exponent + 3));
    m_ulaw[i] = (i & 0x80) ? -value : value; // bit 7 = sign (inverted)
}
```

(MAME: `device_start()` L91-103)

**µ-law encoding (input byte layout):**
```
[7]     sign (1 = positive after inversion, 0 = negative)
[6:4]   exponent (inverted: ~exp gives segment 0–7)
[3:0]   mantissa (inverted: ~mant gives step within segment)
```

Note: The input byte is bitwise inverted per the standard (all bits complemented for transmission), so the code inverts back with `~i`.

**Domain:** Input 0–255 (8-bit µ-law encoded byte)
**Range:** −32124 to +32124 (signed 16-bit linear PCM, approximately)

**Segment base values (lut[]):**
| Exponent | lut[exp] | Step size |
|----------|----------|-----------|
| 0 | 0 | 8 |
| 1 | 132 | 16 |
| 2 | 396 | 32 |
| 3 | 924 | 64 |
| 4 | 1980 | 128 |
| 5 | 4092 | 256 |
| 6 | 8316 | 512 |
| 7 | 16764 | 1024 |

**Approximation:** µ-law is a companding scheme that provides ~14-bit dynamic range in 8 bits, with finer quantization at low amplitudes and coarser at high amplitudes. Used in North American telephone networks. (MIL-STD-188-113)

### 3.3 Pan Law Table (256 entries)

**Purpose:** Provides logarithmic panning attenuation. The pan register value is used to compute separate left and right volume index offsets, which are subtracted from the volume accumulator index before the volume table lookup.

**Size:** 256 entries × 16-bit = 512 bytes

**Generation formula:**
```c
constexpr int PAN_LEVEL = 16;

for (int i = 0; i < 256; i++)
    panlaw[i] = PAN_LEVEL - (31 - count_leading_zeros_32(i));
    // Equivalent to: panlaw[i] = PAN_LEVEL - floor(log2(i))

panlaw[0] = 0xFFF;   // special case: all bits set = full attenuation (no pan)
```

(MAME: `device_start()` L105-109)

**Usage in mixing:**
```c
// From fill_output():
volacc = (vol.acc >> 14) & 0xFFF;         // 12-bit volume index
vlefti  = volacc - panlaw[255 - pan];      // left channel index
vrighti = volacc - panlaw[pan];            // right channel index
vleft  = (vlefti > 0) ? volume[vlefti] : 0;  // look up linear volume
vright = (vrighti > 0) ? volume[vrighti] : 0;
```

(MAME: `fill_output()` L449-454)

**Domain:** Pan register value 0–255 (8-bit, from register 0x0C)
**Range:** Table entries are small integers (typically 0–16+), subtracted from the 12-bit volume index

**Behavior:**
- `pan = 0`: `panlaw[0] = 0xFFF` → right is fully attenuated; `panlaw[255]` → left gets minimal attenuation
- `pan = 127` or `128`: approximately equal left/right levels (center pan)
- `pan = 255`: left is fully attenuated; `panlaw[0] = 0xFFF` used for right → right fully attenuated too

> **Uncertainty:** The `panlaw[0] = 0xFFF` special case causes both channels to be fully attenuated when pan = 0 (since `panlaw[255-0] = panlaw[255]` for left and `panlaw[0] = 0xFFF` for right). This seems like it might be a "voice off" indicator rather than a normal pan position. The GUS uses only 4-bit pan (0–15, where 0=full left, 15=full right). The ICS2115 uses 8-bit pan, which is a significant difference. (GUS SDK: Section 2.6.2.13; Datasheet: "Pan Value — Note: 10 bits on 2210")

**Approximation:** `floor(log2(i))` gives a crude step-function approximation of logarithmic attenuation. Each doubling of the pan index adds 1 to the attenuation (≈6 dB). The comment mentions "-3dB" but `PAN_LEVEL = 16` appears to be a power-of-two scaling constant rather than a dB value.

---

## 4. Register Map & Access Protocol

### 4.1 Host Interface — Direct Registers

The host CPU accesses the ICS2115 through 4 I/O addresses, selected by SA[1:0] with CS asserted:

| Offset | Direction | Name | Description |
|--------|-----------|------|-------------|
| Base+0 | Read | IRQ/Status | Interrupt status register |
| Base+1 | Read/Write | Register Address | Indirect register select |
| Base+2 | Read/Write | Data Low | Low byte (or full word for 16-bit access) |
| Base+3 | Read/Write | Data High | High byte |

(Datasheet: Synthesizer Registers p14-15; MAME: `read()`/`write()` L943-990)

**IRQ/Status register (Base+0, Read):**
```
[7]  IRQ active (any interrupt pending)
[6]  Busy (previous write not yet completed)
[5]  Reserved
[4]  Reserved
[3]  Emulation interrupt
[2]  DMA interrupt
[1]  Oscillator interrupt (any voice osc IRQ pending)
[0]  Timer interrupt (timer IRQ enabled and pending)
```

(Datasheet: Interrupt Status Register p14; MAME: `read()` case 0, L944-960)

**Indirect access protocol:**
1. Write the target register number to Base+1
2. Read or write data at Base+2 (low byte) and/or Base+3 (high byte)
3. For 16-bit registers, Base+2 holds the low byte and Base+3 the high byte
4. Word access (SBHE low, /IOCS16 asserted): read/write full 16-bit value at offset 2

(Datasheet: Indirect Register Access p15; MAME: `word_r()`/`word_w()` L992-1040)

**Register timing considerations:**
- Registers 0x00–0x3F are **synthesizer registers**: internally buffered, transfers complete at required times
- Registers 0x40–0x7F are **general purpose registers**: immediately available for access
- The Busy bit (status bit 6) indicates when a synthesizer register write is still pending

(Datasheet: Indirect Register Access p15)

### 4.2 Voice Select

Register 0x4F (OscNumber) selects which of the 32 voices is targeted by per-voice register reads/writes:

```c
osc_select = data % (1 + active_osc);
```

This means voice selection wraps at the active voice count, not at 32. (MAME: `reg_write()` case 0x4F)

The GUS uses a separate "Page Register" at a different I/O address (3X2) for voice selection. (GUS SDK: Section 2.5)

### 4.3 Synthesizer Registers (Per-Voice, 0x00–0x1F)

These registers are replicated for each of the 32 voices. The target voice is selected by writing to register 0x4F.

| Reg | Name | R/W | Width | Description | Bit Layout |
|-----|------|-----|-------|-------------|------------|
| 0x00 | OscConf | R/W | 8 | Oscillator Configuration | `[7] irq_pending (RO) \| [6] invert \| [5] irq_en \| [4] bidir_loop \| [3] loop \| [2] 8-bit \| [1] stop \| [0] µ-law` |
| 0x01 | OscFC | R/W | 16 | Wavesample Frequency | `[15:10] integer (6-bit) \| [9:1] fraction (9-bit) \| [0] unused` |
| 0x02 | OscStrtH | R/W | 16 | Loop Start Address High | `[15:0] → start[28:16]` upper 16 bits of start address |
| 0x03 | OscStrtL | R/W | 8 | Loop Start Address Low | `[15:8] → start[15:8]` next 8 bits (low byte unused on write) |
| 0x04 | OscEndH | R/W | 16 | Loop End Address High | `[15:0] → end[28:16]` upper 16 bits of end address |
| 0x05 | OscEndL | R/W | 8 | Loop End Address Low | `[15:8] → end[15:8]` next 8 bits (low byte unused on write) |
| 0x06 | VIncr | R/W | 8 | Volume Increment | `[7:6] rate scale \| [5:0] increment (1–63)` |
| 0x07 | VStart | R/W | 8 | Volume Ramp Start | `[7:4] exponent \| [3:0] mantissa` → expanded to `data << 18` |
| 0x08 | VEnd | R/W | 8 | Volume Ramp End | `[7:4] exponent \| [3:0] mantissa` → expanded to `data << 18` |
| 0x09 | VolAcc | R/W | 16 | Volume Accumulator | `[15:0] = vol.acc >> 10` (read); `vol.acc = regacc << 10` (write) |
| 0x0A | OscAccH | R/W | 16 | Current Address High | `[15:0] = (osc.acc >> 16) & 0xFFFF` |
| 0x0B | OscAccL | R/W | 16 | Current Address Low | `[15:3] = (osc.acc >> 3) & 0x1FFF` ; `[2:0]` masked to 0 on write |
| 0x0C | OscPan | R/W | 8 | Pan Position | `[7:0] pan value` (8-bit; GUS uses only 4-bit, ICS2210 uses 10-bit) |
| 0x0D | VCtl | R/W | 8 | Volume Envelope Control | `[7] irq_pending (RO) \| [6] invert \| [5] irq_en \| [4] bidir_loop \| [3] loop \| [2] rollover \| [1] stop \| [0] done` |
| 0x0E | ActiveOsc | R/W | 8 | Active Voices | `[4:0] active_osc (0–31)` — write triggers sample rate recalc |
| 0x0F | IRQV | Read | 8 | IRQ Source/Oscillator | `[7] ~osc_irq \| [6] ~vol_irq \| [4:0] voice#` ; returns 0xFF if none |
| 0x10 | OscCtl | R/W | 8 | Oscillator Control | `[7] R \| [6] M2 \| [5] M1 \| [1] Timer2 Start \| [0] Timer1 Start` ; write 0x00 = key on, 0x0F = key off |
| 0x11 | OscSAddr | R/W | 8 | Static Address Bits 27-20 | `[7:0] saddr` — selects 1 MB ROM/DRAM bank |
| 0x12 | VMode | R/W | 8 | Reserved (write 0) | Controls vmode flag; affects vol IRQ read behavior |
| 0x13–0x1F | — | — | — | RESERVED | Do not access |

(Datasheet: Register Map p16; MAME: `reg_read()` / `reg_write()` L523-930; GUS SDK: Section 2.6.2)

**Register 0x00 (OscConf) bit details:**

| Bit | Name | R/W | Description |
|-----|------|-----|-------------|
| 7 | irq_pending | R | Oscillator IRQ pending (set by hardware on boundary cross) |
| 6 | invert | R/W | Playback direction: 0=forward, 1=reverse (self-modifying on bidir loop) |
| 5 | irq | R/W | Enable oscillator boundary IRQ |
| 4 | loop_bidir | R/W | Bidirectional loop enable |
| 3 | loop | R/W | Loop enable |
| 2 | eightbit | R/W | 8-bit sample format (0=16-bit) |
| 1 | stop | R/W | Stop oscillator |
| 0 | ulaw | R/W | µ-law compressed format |

Note: Bit 0 (µ-law) is unique to the ICS2115 — the GF1/GUS does not support µ-law. The GUS uses bit 0 as "voice stopped" (read-only, self-modifying) and bit 2 as "16-bit data". (GUS SDK: Section 2.6.2.1; MAME: `ics2115.h` bitfield union)

**Register 0x0D (VCtl) bit details:**

| Bit | Name | R/W | Description |
|-----|------|-----|-------------|
| 7 | irq_pending | R | Volume ramp IRQ pending |
| 6 | invert | R/W | Ramp direction: 0=increasing, 1=decreasing (self-modifying on bidir) |
| 5 | irq | R/W | Enable volume ramp IRQ |
| 4 | loop_bidir | R/W | Bidirectional ramp looping |
| 3 | loop | R/W | Ramp loop enable |
| 2 | rollover | R/W | Rollover condition (address continues past boundary without stopping) |
| 1 | stop | R/W | Stop ramp |
| 0 | done | R/W | Ramp has completed (set by hardware) |

(MAME: `ics2115.h` `vol_ctrl` bitfield; GUS SDK: Section 2.6.2.14)

**Register 0x0F (IRQV) — Interrupt Source:**

Returns the index of the first voice with a pending interrupt, or 0xFF if none:
```
[7]    0 = oscillator IRQ pending on this voice (inverted logic)
[6]    0 = volume ramp IRQ pending on this voice (inverted logic)
[5]    1 (always set)
[4:0]  voice number (0–31)
```

Reading this register clears the pending flags on the reported voice and triggers IRQ recalculation. Only the first pending voice is reported per read; software must poll until 0xFF is returned. (MAME: `reg_read()` case 0x0F L639-665)

### 4.4 General Purpose Registers (0x40–0x7F)

| Reg | Name | R/W | Width | Description |
|-----|------|-----|-------|-------------|
| 0x40 | Timer1 | Write | 8 | Timer 1 preset value |
| 0x41 | Timer2 | Write | 8 | Timer 2 preset value |
| 0x42 | Timer1PreS | Write | 8 | Timer 1 prescaler |
| 0x43 | Timer2PreS_S | R/W | 8 | Timer 2 prescaler (write) / Timer status (read: `irq_pending & 3`) |
| 0x44 | DMAddrLo | Write | 8 | DMA start address [11:4] |
| 0x45 | DMAddrMd | Write | 8 | DMA start address [19:12] |
| 0x46 | DMAddrHi | Write | 8 | DMA start address [21:20] / DMA data |
| 0x47 | DMACS | R/W | 8 | DMA control/status |
| 0x48 | AccMonS | Read | 8 | Accumulator monitor status |
| 0x49 | AccMonData | Read | 16 | Accumulator monitor data |
| 0x4A | DOCIntCS | R/W | 8 | IRQ enable (write) / IRQ pending (read) |
| 0x4B | IntOscAddr | Read | 8 | Address of interrupting oscillator |
| 0x4C | MemCfg_Rev | R/W | 8 | Memory config (write) / Chip revision (read: returns 0x01) |
| 0x4D | SysCtrl | R/W | 8 | System control |
| 0x4F | OscNumber | Write | 8 | Voice select: `osc_select = data % (active_osc + 1)` |
| 0x50 | IndMIDIData | R/W | 8 | MIDI data register |
| 0x51 | IndMIDICS | R/W | 8 | MIDI control/status |
| 0x52 | IndHostData | R/W | 8 | Host data register |
| 0x53 | IndHostCS | R/W | 8 | Host control/status |
| 0x54 | IndMIDIIntC | R/W | 8 | MIDI emulation interrupt control |
| 0x55 | IndHostIntC | R/W | 8 | Host emulation interrupt control |
| 0x56 | IndIntStatus | R/W | 8 | Host/MIDI emulation interrupt status (read) |
| 0x57 | IndEmulMode | R/W | 8 | Emulation mode |

(Datasheet: General Purpose Register Definitions p17; MAME: `reg_read()`/`reg_write()` — timer, IRQ, and misc cases)

### 4.5 Timer Operation

Timer period is calculated from prescaler and preset values:

```c
period = ((scale & 0x1F) + 1) * (preset + 1);
period = period << (4 + (scale >> 5));
// Final period is in clock ticks; convert to time with: attotime::from_ticks(period, clock)
```

(MAME: `recalc_timer()` L1094-1103)

- `scale[4:0]`: 5-bit base divider (1–32)
- `scale[7:5]`: 3-bit shift amount (adds 4–11 bit positions of binary scaling)
- `preset`: 8-bit countdown value (0–255)

Reading registers 0x40/0x41 returns the preset value and clears the corresponding timer IRQ. (MAME: `reg_read()` cases 0x40/0x41)

The GUS timers are simpler: Timer 1 has 80 µs granularity, Timer 2 has 320 µs granularity, both count up to 0xFF. (GUS SDK: Section 2.6.1.5)

### 4.6 IRQ Architecture

The ICS2115 has multiple interrupt sources consolidated into a single IRQ pin:

```
IRQ = (irq_pending & irq_enabled)    // timer/DMA/emulation IRQs
    | (any voice osc_conf.irq && osc_conf.irq_pending)   // per-voice oscillator IRQs
    | (any voice vol_ctrl.irq && vol_ctrl.irq_pending)    // per-voice volume ramp IRQs
```

(MAME: `recalc_irq()` L1073-1083)

**IRQ enable register (0x4A write):** Enables/disables timer and DMA interrupts.
**IRQ pending register (0x4A read):** Shows pending timer/DMA/emulation interrupts.
**Per-voice IRQs:** Enabled individually via OscConf bit 5 and VCtl bit 5.

**Key-on (register 0x10 write):**
- Write 0x00: Key on — starts voice playback, initializes ramp to 0x40
- Write 0x0F: Key off — sets osc stop and vol stop bits (when vmode == 0)

(MAME: `reg_write()` case 0x10 L856-880; `keyon()` L1042-1065)

---

## 5. Differences from GF1 (GUS)

The ICS2115 shares the same basic register architecture as the GF1 used in the Gravis UltraSound, but with several differences:

| Feature | GF1 (GUS) | ICS2115 |
|---------|-----------|---------|
| µ-law support | No | Yes (OscConf bit 0) |
| Pan resolution | 4-bit (0–15) | 8-bit (0–255) |
| Min active voices | 14 | Not explicitly limited (register allows 0–31) |
| Sample rate formula | `1000000 / (1.6µs × voices)` | `clock / ((active_osc + 1) × 32)` |
| Voice select mechanism | Separate page register (3X2) | Register 0x4F in indirect space |
| Timer granularity | Fixed 80µs / 320µs | Programmable via prescaler+preset |
| Host bus | ISA with GF1-specific port map | ISA with CS/CSMM pin-selected bases |
| DRAM interface | On-card DRAM via GF1 | Direct DRAM interface on chip |
| Reset register | Global register 0x4C with DAC/IRQ enable | Different: 0x4C reads chip revision |
| MIDI emulation | External (board-level) | Integrated (6850/MPU-401 compatible) |

(GUS SDK: Sections 2.5, 2.6; Datasheet: Register Map; MAME: source comparison)

> **Uncertainty:** The exact voice-servicing pipeline timing of the ICS2115 vs. GF1 is not fully documented. The GUS SDK states 1.6 µs per voice for the GF1. The ICS2115 may use a different internal pipeline, as suggested by the `clock/(N*32)` formula in MAME which implies 32 clock cycles per voice rather than a fixed microsecond timing.

---

## 6. Oscillator (Wavesample Engine)

The oscillator is the core sample playback engine. Each of the 32 voices has an independent oscillator that reads sample data from ROM/DRAM, advances a position accumulator at a programmable rate, and performs linear interpolation between adjacent samples.

### 6.1 Accumulator Update

On each sample tick, the oscillator accumulator advances by the frequency counter value:

```
if not stopped:
    if direction == FORWARD:
        acc += fc << 2
        left = end - acc
    else:  // REVERSE
        acc -= fc << 2
        left = acc - start
```

The `fc << 2` shift aligns the 6.9 frequency counter (see §2.2) into the 20.9 accumulator space. The `left` variable tracks the signed distance remaining before a boundary crossing — when `left` goes to zero or negative, a boundary has been reached. (MAME: `update_oscillator()` L309-318)

> **Uncertainty:** MAME uses `left > 0` rather than `left >= 0` for the boundary check, with a comment "> instead of >= to stop crackling?" This means a boundary is crossed when `left` is exactly zero, which may not match the real hardware's comparator behavior.

### 6.2 Boundary Crossing and Loop Modes

When the accumulator crosses a boundary (`left <= 0`), the behavior depends on the OscConf register bits:

**Next-Address Logic Table** (US Patent 6,246,774 B1, column 111, row 25):

```
LEN   BLEN   DIR   BC    NextAddress
─────────────────────────────────────────────────────────
 x     x      0     0    acc + fc              // forward, no boundary
 x     x      1     0    acc - fc              // reverse, no boundary
 0     x      x     1    acc                   // no loop: stop, hold position
 1     0      0     1    start - (end - (acc + fc))   // forward loop wraparound
 1     0      1     1    end + ((acc - fc) - start)   // reverse loop wraparound
 1     1      0     1    end + (end - (acc + fc))     // bidir: reflect at end
 1     1      1     1    start - ((acc - fc) - start) // bidir: reflect at start
```

Where LEN = loop enable, BLEN = bidirectional loop enable, DIR = invert (direction), BC = boundary cross.

**MAME implementation of boundary handling:**

```
if loop_enabled:
    if bidir_loop:
        invert = !invert               // flip direction
    if invert (now heading reverse):
        acc = end + left                // left is negative, so acc = end - |overshoot|
    else (now heading forward):
        acc = start - left              // left is negative, so acc = start + |overshoot|
else:  // one-shot mode
    state.on = false
    stop = true
    if direction == FORWARD:
        acc = end                       // clamp to end
    else:
        acc = start                     // clamp to start
```

(MAME: `update_oscillator()` L319-358)

The `left` variable carries the signed overshoot, so `start - left` (where left is negative) correctly places the accumulator past the start boundary by the overshoot amount. This produces seamless loop wrapping without losing fractional position.

**Oscillator IRQ:** If the IRQ enable bit (OscConf bit 5) is set and a boundary crossing occurs, the `irq_pending` flag (OscConf bit 7) is set. The IRQ is raised regardless of loop mode — even one-shot voices can generate a boundary IRQ. (MAME: `update_oscillator()` L323-327)

### 6.3 Sample Fetch and Address Construction

Sample data is fetched from ROM/DRAM using the static address register and the accumulator:

```
byte_address = (saddr << 20) | (acc >> 12)
```

Where `saddr` (register 0x11, 8-bit) selects the 1 MB bank and `acc >> 12` yields the 20-bit byte offset within that bank. (MAME: `ics2115.h` L129 — `read_sample()`)

**Three sample formats** are supported, determined by OscConf bits 2 and 0:

| `eightbit` | `ulaw` | Format | Bytes per sample | Fetch |
|------------|--------|--------|-----------------|-------|
| 0 | 0 | 16-bit linear signed | 2 | Little-endian: `lo \| (hi << 8)` |
| 1 | 0 | 8-bit linear signed | 1 | Sign-extended to 16-bit: `(s8)byte << 8` |
| x | 1 | 8-bit µ-law compressed | 1 | Decoded via µ-law table (see §3.2) |

(MAME: `get_sample()` L376-394)

For **16-bit samples**, two bytes are read per sample point in little-endian order:
```
sample = read_byte(curaddr) | (s8(read_byte(curaddr + 1)) << 8)
```

For **8-bit samples**, one byte is read and sign-extended to 16-bit:
```
sample = s8(read_byte(curaddr)) << 8
```

For **µ-law samples**, one byte is read and decoded through the 256-entry lookup table:
```
sample = ulaw_table[read_byte(curaddr)]
```

### 6.4 Next-Sample Address for Interpolation

The interpolator needs two adjacent samples. The "next" sample address depends on whether the voice is approaching a loop boundary:

```
if voice_on AND loop_enabled AND NOT bidir_loop AND (left < fc << 2):
    nextaddr = start >> 12      // next sample wraps to loop start
else:
    nextaddr = curaddr + 2      // next sequential sample (2 bytes for 16-bit)
```

This handles the case where the current position is within one step of the loop end — the interpolator blends between the last sample before the end and the first sample at the loop start, preventing a discontinuity at the loop point. (MAME: `get_sample()` L367-375)

> **Uncertainty:** The `nextaddr = curaddr + 2` assumes 16-bit (2-byte) samples, but this same offset is used for 8-bit and µ-law modes in MAME. For 8-bit/µ-law, the next sample should logically be at `curaddr + 1`. The MAME code fetches `curaddr + 1` for 8-bit and µ-law sample2, which is the correct adjacent byte — but then `nextaddr` is only used for the 16-bit path. This appears correct but the variable naming is misleading.

### 6.5 Linear Interpolation

The oscillator performs linear interpolation between two adjacent samples using the fractional part of the accumulator:

```
Bit layout of fractional position:
acc[11:3] = 9-bit fraction (0–511)

fract = (acc & 0xFF8) >> 3      // extract 9-bit fraction
diff = sample2 - sample1
output = (sample1 << 9 + diff * fract) >> 9
```

This is equivalent to:
```
output = sample1 + (sample2 - sample1) * fract / 512
```

The formula blends linearly from `sample1` (when fract=0) to `sample2` (when fract=511). The intermediate result uses 25 bits (16-bit sample × 9-bit fraction) before the final right shift. (MAME: `get_sample()` L396-403; US Patent 6,246,774 B1, column 2, row 59)

> **Source Divergence:** The MAME comment says "no need for interpolation since it's around 1 note a cycle?" and has commented-out code that would skip interpolation when `fract == 0`. The production code always interpolates. The patent explicitly describes the interpolation formula, confirming it is part of the hardware design.

### 6.6 GF1 Oscillator Comparison

The GF1 uses the same fundamental accumulator+interpolation architecture. Key differences:

| Aspect | GF1 (from `gf1.v`) | ICS2115 |
|--------|---------------------|---------|
| Accumulator width | 29 bits in 148-bit voice RAM | 32 bits (29 significant) |
| Sample formats | 8-bit, 16-bit | 8-bit, 16-bit, µ-law |
| Interpolation | Same formula (patent-derived) | Same formula |
| Next-address logic | Same table (patent column 111) | Same table |
| Voice RAM storage | 148-bit interleaved shift register | Separate register fields |

(GF1: `gf1.v` L73 — `voice_ram[0:31]` is 148 bits; MAME/Patent: shared next-address table)

---

## 7. Volume Envelope (Ramp System)

The ICS2115 has two distinct volume-control mechanisms per voice:
1. **Volume envelope** — a programmable ramp controlled by registers VStart (0x07), VEnd (0x08), VIncr (0x06), VolAcc (0x09), and VCtl (0x0D). This implements ADSR-style envelope segments.
2. **Voice ramp** — a simple 7-bit amplitude gate (`state.ramp`, range 0x00–0x40) that provides slow attack/release smoothing independent of the volume envelope.

### 7.1 Volume Envelope Accumulator Update

The volume envelope operates on a 32-bit accumulator (`vol.acc`). On each sample tick, if the envelope is running (not stopped, not done):

```
if direction == INCREASING (invert = 0):
    vol.acc += vol.add
    left = vol.end - vol.acc
else:  // DECREASING (invert = 1)
    vol.acc -= vol.add
    left = vol.acc - vol.start
```

When `left <= 0`, a boundary has been crossed. (MAME: `update_volume_envelope()` L247-258)

### 7.2 Increment Calculation

The volume increment is decoded from the 8-bit VIncr register (0x06) into the internal `vol.add` value:

```
incr = register 0x06 value (8-bit)
fine = 1 << (3 * (incr >> 6))       // rate scale bits [7:6]
vol.add = (incr & 0x3F) << (10 - fine)   // magnitude bits [5:0]
```

**Rate scale decoding:**

| Bits [7:6] | fine | Shift (10 - fine) | Effect |
|------------|------|-------------------|--------|
| 0 | 1 | 9 | Fastest: large steps, applied every tick |
| 1 | 8 | 2 | Fast: medium steps |
| 2 | 64 | −54 | **Bug: negative shift** |
| 3 | 512 | −502 | **Bug: negative shift** |

(MAME: `fill_output()` L444-445)

> **Uncertainty:** The `fine = 1 << (3 * scale)` formula produces values {1, 8, 64, 512} for scales {0, 1, 2, 3}. For scales 2 and 3, `10 - fine` is massively negative, which would cause undefined behavior in C++. The GUS SDK describes the rate bits differently — as controlling how often the increment is applied (every tick, every 8th tick, every 64th tick, every 512th tick) rather than affecting the shift amount. The GF1 hardware verilog (`gf1.v` L243-245, L286) implements rate scaling by dividing a counter by the rate factor, confirming the GUS SDK interpretation. The MAME formula appears to be a misinterpretation that only works correctly for rate scales 0 and 1.

**GUS SDK interpretation** (Section 2.22): The rate bits define the Volume Update Rate as a divisor of the fundamental update rate (FUR):

```
Rate 00: update every tick (FUR)
Rate 01: update every 8th tick (FUR/8)
Rate 10: update every 64th tick (FUR/64)
Rate 11: update every 512th tick (FUR/512)
```

Where `FUR = 1 / (1.6µs × active_voices)` for the GF1. Each rate increment is 8× longer than the previous. (GUS SDK: Section 2.22, p34)

**GF1 hardware implementation** (`gf1.v` L286): The GF1 uses a 9-bit ramp counter (`ramp_cnt`) with the rate bits selecting which counter bits to test, effectively creating a divider chain.

> **Source Divergence:** MAME's increment calculation differs from both the GUS SDK description and the GF1 verilog. The GUS SDK and GF1 verilog agree that rate bits control *how often* the increment is applied, not *how much* the increment is shifted. For implementation, the GF1/GUS SDK model (counter-based rate divider) is more likely correct for the ICS2115 as well, given the shared register architecture.

### 7.3 Boundary Crossing Behavior

When the volume accumulator crosses its boundary (`left <= 0`), the behavior depends on VCtl register bits:

**Volume Next-State Logic Table** (US Patent 5,809,466, column 126):

```
UVOL  LEN   BLEN   DIR   BC    Next VOL(L)
────────────────────────────────────────────────────────────────
 0     x     x      x     x    VOL(L)                            // envelope disabled
 1     x     x      0     0    VOL(L) + VINC                     // increasing, no boundary
 1     x     x      1     0    VOL(L) - VINC                     // decreasing, no boundary
 1     0     x      x     1    VOL(L)                             // no loop: hold at boundary
────────────────────────────────────────────────────────────────
 1     1     0      0     1    start - (end - (VOL(L) + VINC))   // loop fwd: wrap to start
 1     1     0      1     1    end + ((VOL(L) - VINC) - start)   // loop rev: wrap to end
 1     1     1      0     1    end + (end - (VOL(L) + VINC))     // bidir fwd: reflect at end
 1     1     1      1     1    start - ((VOL(L) - VINC) - start) // bidir rev: reflect at start
```

Where UVOL = volume envelope update enable, LEN = loop enable, BLEN = bidirectional loop enable, DIR = invert, BC = boundary cross. (MAME: `update_volume_envelope()` comment block L218-231)

**Volume IRQ:** If IRQ enable (VCtl bit 5) is set, the `irq_pending` flag is set on boundary crossing regardless of loop mode. (MAME: `update_volume_envelope()` L260-264)

**8-bit mode exception:** When OscConf `eightbit` bit is set, the boundary crossing loop logic is skipped entirely — only the IRQ is generated but no accumulator wrapping occurs. This may be related to reduced precision requirements for 8-bit samples. (MAME: `update_volume_envelope()` L266-267)

**Non-looping termination:** When loop is disabled and a boundary is crossed, `vol_ctrl.done` is set, which permanently stops the envelope until software resets it. (MAME: `update_volume_envelope()` L293-294)

### 7.4 The Boundary Cross Bug

The MAME implementation has a known tautological bug in the boundary cross detection:

```c
// MAME L240-241:
if (vol.acc >= vol.end || vol.acc <= vol.end)
    bc = true;
```

This condition is always true — `bc` is always set to `true`. The variable `bc` is then used in the loop wrapping logic (only the `bc` branch of the wrap equations is ever taken).

**Intended behavior (derived from context):** The boundary cross should be directional, matching the oscillator's approach:

```
if direction == INCREASING:
    bc = (vol.acc >= vol.end)
else:
    bc = (vol.acc <= vol.start)    // or possibly vol.end
```

The patent next-state table (§7.3) shows BC as a distinct condition separate from the `left <= 0` check. In the current MAME code, the `left <= 0` check controls whether the boundary path is entered at all, and `bc` controls which wrap formula is used within that path. Since `bc` is always true, the wrap formulas are always applied, which appears to produce correct-enough behavior for the common case. (MAME: `update_volume_envelope()` L240-241)

> **Uncertainty:** The `bc` variable in the volume envelope may have been intended to detect a specific boundary crossing condition distinct from the `left` overflow check — possibly distinguishing between "at boundary" versus "past boundary." With `bc` always true, the MAME implementation collapses these cases. The real hardware's behavior at the exact boundary point may differ subtly.

### 7.5 Voice Ramp (Amplitude Gate)

Separate from the volume envelope, each voice has a `state.ramp` field — a 7-bit value (range 0x00–0x40) that acts as a global amplitude gate. This provides click-free key-on/key-off transitions:

```
if voice_on AND NOT stopped:
    // slow attack
    if ramp < 0x40:
        ramp += 1
    else:
        ramp = 0x40        // clamp at maximum
else:
    // slow release
    if ramp > 0:
        ramp -= 1
```

The ramp value is applied as a multiplier in the mixing stage (see §8.1), scaled by shifting right 6 bits (`RAMP_SHIFT = 6`). At maximum (`0x40` = 64), the ramp is unity (64 >> 6 = 1). At zero, the voice is fully muted. (MAME: `update_ramp()` L413-429)

**Key-on behavior:** When `keyon()` is called (register 0x10 write with value 0x00), the ramp is initialized to `0x40` (full volume immediately), bypassing the slow attack:

```
state.ramp = 0x40    // immediate full volume on keyon
```

(MAME: `keyon()` L1049)

> **Uncertainty:** The MAME comment says "set initial condition (may need to invert?) -- does NOT work since these are set to zero even no ramp up..." This suggests uncertainty about whether keyon should set ramp to 0x40 (bypassing attack) or to 0x00 (requiring the slow ramp-up). The current implementation sets it to 0x40, which means the slow attack ramp never engages after keyon — only after a voice is stopped and restarted without going through keyon. The slow release (ramp decrement when voice stops) does function, providing click-free note-off.

### 7.6 ADSR Implementation via IRQ Chain

The volume envelope hardware implements a single ramp segment at a time. ADSR (attack-decay-sustain-release) envelopes are built by software using the volume IRQ:

1. **Attack:** Set VStart=0 (silence), VEnd=peak, direction=increasing, IRQ=enabled. Start ramp.
2. When attack reaches peak → volume IRQ fires.
3. **Decay:** In IRQ handler, set VStart=sustain_level, VEnd=peak, direction=decreasing, IRQ=enabled.
4. When decay reaches sustain → volume IRQ fires.
5. **Sustain:** In IRQ handler, set stop=true (hold) or set loop between two close values for vibrato.
6. **Release:** On note-off, set VEnd=0, direction=decreasing, IRQ=enabled (or disabled for final fade).

This matches the GUS SDK approach: "A section of the envelope can be programmed such that the PC does not need to be burdened with the task of changing each volume at specified intervals. At the end of that particular section, an IRQ can be generated so that the next section can be programmed in." (GUS SDK: Section 2.22, p33)

### 7.7 Volume Ramp Format (GUS SDK)

The GUS SDK documents the volume register formats in the "EEEEMMMM" notation:

```
Current Volume (reg 0x09):  EEEEMMMMMMMM xxxx  (bits 15-4, 12-bit: 4 exponent + 8 mantissa)
Volume Start (reg 0x07):    EEEEMMMM            (8-bit: 4 exponent + 4 mantissa)
Volume End (reg 0x08):      EEEEMMMM            (8-bit: 4 exponent + 4 mantissa)
Volume Incr (reg 0x06):     RRMMMMMM            (8-bit: 2 rate + 6 magnitude)
```

The Current Volume register has 4 extra mantissa bits compared to Start/End, providing "finer granularity of volume placement" during ramping. Start and End registers are expanded internally by shifting left to align with the full-precision accumulator. (GUS SDK: Section 2.22, p33; Section 2.6.2.10, p22)

**Approximate ramp times** for a full-scale sweep (0–4095) with 14 active voices (GUS):

| Rate | Vol Inc | Time (14 voices) | Time (32 voices) |
|------|---------|-------------------|-------------------|
| 0 | 63 | 1.4 ms | 3.3 ms |
| 0 | 1 | 91.7 ms | 209.7 ms |
| 1 | 63 | 11.5 ms | 26.2 ms |
| 1 | 1 | 733.8 ms | 1.7 s |
| 2 | 63 | 91.8 ms | 209.7 ms |
| 3 | 1 | 5.9 s | 13.4 s |
| 3 | 63 | 734.0 ms | 1.7 s |
| 3 | 1 | 47.0 s | 107.3 s |

(GUS SDK: Section 2.22, p34)

### 7.8 GF1 Ramp Pipeline Comparison

The GF1 hardware implements the volume ramp as a multi-stage pipeline in `gf1.v`:

```
Voice RAM layout (148 bits per voice, ramp-related fields):
  ramp_cur[11:0]    — current volume (12-bit, interleaved in voice RAM)
  ramp_start[11:0]  — ramp start (8-bit, lower 4 bits zero-padded)
  ramp_end[11:0]    — ramp end (8-bit, lower 4 bits zero-padded)
  ramp_inc[5:0]     — increment value (6-bit, gated by w368)
  ramp_params[7:0]  — control bits (stop, done, bidir, loop, irq_en, irq_pending, dir)
```

The GF1 ramp uses dedicated next-state logic wires:

```verilog
ramp_end_cond    = ramp_end_reach
ramp_irq_pend    = irq_en & (irq_pending | ramp_end_reach)
ramp_status_next = done | (~done & (ramp_end_cond & ~stop))
ramp_dir_next    = dir ^ (ramp_end_cond & (stop & bidir))
```

(GF1: `gf1.v` L243-258, L266-297, L300-340)

Key difference: the GF1 stores ramp values in 12-bit interleaved format within the 148-bit voice RAM, while the ICS2115 (per MAME) uses a 32-bit accumulator with the upper 12 bits used for lookup. The GF1 ramp pipeline operates in hardware clock cycles; the ICS2115's register-level behavior is compatible but the internal pipeline may differ.

---

## 8. Mixing & Audio Output

The mixing stage combines the interpolated sample, volume envelope, pan law, and voice ramp into the final stereo output.

### 8.1 Per-Voice Rendering Pipeline

For each voice, on each sample tick, the following pipeline executes:

```
Step 1: Volume lookup
    volacc = (vol.acc >> 14) & 0xFFF          // 12-bit volume index from accumulator
    vlefti  = volacc - panlaw[255 - pan]       // left attenuation index
    vrighti = volacc - panlaw[pan]             // right attenuation index

Step 2: Clamp negative indices (prevents table underrun)
    vleft  = (vlefti > 0) ? volume_table[vlefti] : 0
    vright = (vrighti > 0) ? volume_table[vrighti] : 0

Step 3: Apply voice ramp (amplitude gate)
    vleft  = vleft * state.ramp >> RAMP_SHIFT  // RAMP_SHIFT = 6
    vright = vright * state.ramp >> RAMP_SHIFT

Step 4: Fetch interpolated sample
    sample = get_sample(voice)                 // see §6.5

Step 5: Scale and accumulate into stereo bus
    left_bus  += (sample * vleft) >> (5 + volume_bits)
    right_bus += (sample * vright) >> (5 + volume_bits)
```

Where `volume_bits = 15` and the `>> (5 + 15) = >> 20` normalizes the product of a 16-bit sample × 15-bit volume into the 16-bit output range. The 5-bit headroom accounts for summing up to 32 voices (2^5 = 32). (MAME: `fill_output()` L431-472)

### 8.2 Pan Law Application

Panning is implemented by subtracting a pan-law offset from the volume index *before* the volume table lookup. This is an attenuation model — panning reduces one channel's volume rather than boosting the other:

```
Bit layout of pan register (0x0C, 8-bit):
[7:0]  pan position (0 = left, 255 = right)

Left volume index  = volacc - panlaw[255 - pan]   // more attenuation as pan moves right
Right volume index = volacc - panlaw[pan]          // more attenuation as pan moves left
```

Since the volume table is exponential (see §3.1), subtracting from the index in the exponential domain is equivalent to dividing in the linear domain — this produces a logarithmic pan law. Each unit of pan table offset corresponds to approximately 6 dB of attenuation (one exponent step). (MAME: `fill_output()` L449-452; §3.3 Pan Law Table)

**Negative index clamping:** If the pan attenuation drives the volume index below zero (heavy attenuation), the volume is clamped to zero (silence) rather than wrapping. The MAME comment "check negative values so no cracks, is it a hardware feature?" suggests this may be a deliberate hardware protection against lookup table underrun. (MAME: `fill_output()` L453-454)

### 8.3 Vmode and Stopped Voice Contribution

The `vmode` flag (register 0x12) controls whether stopped voices contribute to the output mix:

```
if vmode == 0 OR voice.playing():
    // voice contributes to output
    left_bus += scaled_sample
    right_bus += scaled_sample
```

When `vmode = 0` (default): all voices contribute to the output, even stopped ones. Whatever sample data the stopped voice's accumulator points at is included in the mix. When `vmode = 1`: only playing voices contribute. (MAME: `fill_output()` L462-467)

The GUS SDK confirms this behavior: "In general, it is necessary to remember that all voices are being summed in to the final output, even if they are not running. This means that whatever data value that the voice is pointing at is contributing to the summation." (GUS SDK: as cited in MAME comments)

> **Uncertainty:** The exact purpose of `vmode` is unclear. Setting `vmode = 0` means stopped voices add DC offset or noise to the output. This could be the intended GUS-compatible behavior (matching the GUS SDK description), while `vmode = 1` provides cleaner output by silencing inactive voices. The register is documented as "Reserved (write 0)" in the datasheet, suggesting `vmode = 0` is the expected operating mode.

### 8.4 Per-Sample Update Order

Within each sample tick, the operations execute in this order for each voice:

```
1. Compute volume (pan, ramp, table lookup)
2. Fetch and interpolate sample
3. Scale sample by volume and accumulate into stereo bus
4. Update voice ramp (slow attack/release)
5. If voice is playing:
   a. Update oscillator accumulator (may trigger boundary cross / IRQ)
   b. Update volume envelope accumulator (may trigger boundary cross / IRQ)
```

Volume and sample fetch happen *before* the accumulator updates, meaning the output reflects the *current* position and volume, not the next-tick values. IRQs from boundary crossings are collected and processed after all voices have been rendered. (MAME: `fill_output()` L447-473)

### 8.5 Multi-Voice Mixing Loop

The `sound_stream_update()` function iterates over all active voices:

```
for osc = 0 to active_osc:
    irq_invalid |= fill_output(voice[osc])

if irq_invalid:
    recalc_irq()
```

The output stream is initialized to silence (zero) before the loop begins. Each voice's contribution is *added* to the running sum — the mix is purely additive. IRQ recalculation is deferred until all voices have been processed, preventing re-entrant IRQ handling during the mixing loop. (MAME: `sound_stream_update()` L474-522)

**Sample rate:** The output stream runs at `clock / ((active_osc + 1) * 32)` Hz (see §1.2). All voices are rendered at this same rate — there is no per-voice sample rate. Voices that need different playback frequencies achieve this through their frequency counter (FC) register, which controls the accumulator advancement rate.

### 8.6 Output Bit Budget

The bit widths through the mixing pipeline:

```
Sample:           16-bit signed (-32768 to +32767)
Volume:           15-bit unsigned (0 to 32767, from volume table)
Ramp:              7-bit unsigned (0 to 64, >> 6 makes it 0 or 1)
Product:          31-bit signed (sample × volume)
Shift:            >> 20 (5 for 32-voice headroom + 15 for volume normalization)
Per-voice result: 11-bit signed (approximate, before accumulation)
Accumulation:     up to 32 voices summed
Final output:     16-bit signed (clipped at ±32768 by stream)
```

### 8.7 GF1 Mixing Pipeline Comparison

The GF1 hardware mixing pipeline (from `gf1.v`) differs in implementation but achieves a similar result:

**Attenuation:** The GF1 combines the 12-bit volume with a 9-bit pan attenuation value, then shifts:
```verilog
atten1 = atten_l + { pan_atten, 4'h0 }     // volume + pan offset (shifted left 4)
atten = (pan == 0xF | overflow) ? 0 : atten1  // full atten if pan=15 or overflow
val_shifted = mul_result >> (~atten[11:8])   // shift by inverted exponent
```

The GF1 uses a 4-bit pan (0–15) with a hardware lookup table for attenuation values. Pan position 0x0F acts as full mute for that channel. (GF1: `gf1.v` L714-721, L2806-2821)

**GF1 Pan Attenuation Table** (from die decode):

| Pan | Atten (9-bit) | Pan | Atten (9-bit) |
|-----|---------------|-----|---------------|
| 0 | 0x000 | 8 | 0x1F0 |
| 1 | 0x1FE | 9 | 0x1EB |
| 2 | 0x1FC | 10 | 0x1E7 |
| 3 | 0x1FA | 11 | 0x1E2 |
| 4 | 0x1F8 | 12 | 0x1DA |
| 5 | 0x1F7 | 13 | 0x1D2 |
| 6 | 0x1F4 | 14 | 0x1C0 |
| 7 | 0x1F2 | 15 | 0x000 (full mute) |

(GF1: `gf1.v` L2806-2821)

**Accumulator Clipping:** The GF1 uses a 21-bit accumulator with explicit clipping to the 16-bit signed range:
```verilog
accum_sum = accum_add + sign_extended(val_shifted)
accum_clip = (positive_overflow) ? 0x7FFF :     // +32767
             (negative_overflow) ? 0x8000 :     // -32768
             accum_sum[15:0]
```

(GF1: `gf1.v` L727-731)

**Key differences from ICS2115:**

| Aspect | GF1 | ICS2115 |
|--------|-----|---------|
| Pan resolution | 4-bit (16 positions) | 8-bit (256 positions) |
| Pan attenuation | 9-bit hardware LUT (16 entries) | `floor(log2(i))` formula (256 entries) |
| Volume × sample | Hardware multiplier + shift | Software multiply + shift |
| Accumulator | 21-bit with explicit clip at ±32768 | Stream-managed accumulation |
| Ramp mechanism | Not visible in GF1 verilog | `state.ramp` 0x00–0x40 amplitude gate |
| DAC output | Serial MSB-first via shift register | Serial MSB-first (see §1.4) |
