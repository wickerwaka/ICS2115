This project is a SystemVerilog implementation of the ICS2115 Wavefront sound synthesizer.

The docs/ directory contains the ./docs/ics2115.pdf datasheet which is the only available datasheet for the processor.

The ICS2115 is closely related to the GF1 chip used in the gravis ultrasound sound card. It seems likely that it's internal voice control is almost identical since it uses the same set of registers for voice control. However the ICS2115 supports higher sample rates when all channels are in use and it supports u-law encoded audio. ./docs/UltraSound Lowlevel ToolKit v2.22 (21 December 1994).pdf describes the Ultrasound card from a PC programming perspective and might have some useful information that is missing in the ICS2115 datasheet.

The ./LPC-GUS directory contains a verilog implementation of the GF1 created from decapped photos of the die.

The mame/ directory contains the full source code for the MAME emulator. It is a very large directory so avoid polluting your context with it. The most important files are mame/src/devices/sound/ics2115.cpp and mame/src/devices/sound/ics2115.h. These are the mame implementation of the ICS2115.

The one-shot/ directory contains a previous implementation and should not be referenced.

