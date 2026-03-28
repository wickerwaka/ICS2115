# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a SystemVerilog reimplementation of the **ICS2115 WaveFront sound synthesizer** chip. The ICS2115 is a 32-voice wavetable synthesis IC that supports 16-bit, 8-bit, and u-law encoded audio samples with hardware volume envelopes, panning, looping (including bidirectional), and interrupt generation.

The `hdl/` directory is where new SystemVerilog source files should be placed.

## Reference Materials

- `docs/ics2115.pdf` — the only known datasheet for the ICS2115
- `docs/UltraSound Lowlevel ToolKit v2.22 (21 December 1994).pdf` — describes the related Gravis UltraSound (GF1) card from a PC programming perspective; useful for filling gaps in the ICS2115 datasheet since the register interface is nearly identical
- `mame/src/devices/sound/ics2115.cpp` and `.h` — MAME's software emulation of the ICS2115, the primary behavioral reference for the HDL implementation
- `LPC-GUS/gf1.v` and `gf1_lpc.v` — Verilog implementation of the related GF1 chip reverse-engineered from decapped die photos; useful as a structural reference

## Key ICS2115 Architecture Details (from MAME reference)

- **32 voices**, each with an independent oscillator and volume envelope
- **Oscillator**: 20.9 fixed-point address accumulator, 6.9 fixed-point frequency control, 8-bit sample address bank (`saddr`), configurable for 16-bit/8-bit/u-law formats
- **Volume envelope**: 12-bit accumulator (stored as upper bits of a larger register), with configurable start/end/increment, direction inversion, looping, and bidirectional looping
- **Pan law**: logarithmic, applied per-voice using a 256-entry lookup table
- **Volume table**: 4096-entry table derived from patent 5809466 formula: `((0x100 | (i & 0xff)) << (volume_bits-9)) >> (15 - (i>>8))`
- **Sample rate**: `clock / ((active_osc + 1) * 32)` where active_osc defaults to 31
- **Interrupts**: per-voice oscillator and volume envelope IRQs, plus two hardware timers; interrupt source register (0x0F) returns lowest-numbered pending voice
- **Registers**: per-voice registers 0x00–0x0F (oscillator config, frequency, loop start/end, volume params, pan, address, envelope control) and global registers (active voices, timers, IRQ enable/pending)
- **Looping logic and next-state address calculations** are documented in US patents 5809466 and 6246774 B1

## Working with the MAME Directory

The `mame/` directory contains the full MAME emulator source. It is very large — avoid reading files beyond `mame/src/devices/sound/ics2115.*` to prevent context pollution. The MAME code serves as a behavioral reference, not as code to modify.
