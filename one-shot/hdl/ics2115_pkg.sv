package ics2115_pkg;

    // Chip constants
    localparam CHIP_REVISION    = 8'h01;
    localparam NUM_VOICES       = 32;
    localparam DEFAULT_ACTIVE_OSC = 5'd31;
    localparam MAX_RAMP         = 7'd64;
    localparam VOLUME_BITS      = 15;

    // osc_conf bit positions
    localparam OSC_ULAW      = 0;
    localparam OSC_STOP      = 1;
    localparam OSC_EIGHTBIT  = 2;
    localparam OSC_LOOP      = 3;
    localparam OSC_BIDIR     = 4;
    localparam OSC_IRQ       = 5;
    localparam OSC_INVERT    = 6;
    localparam OSC_IRQ_PEND  = 7;

    // vol_ctrl bit positions
    localparam VOL_DONE      = 0;
    localparam VOL_STOP      = 1;
    localparam VOL_ROLLOVER  = 2;
    localparam VOL_LOOP      = 3;
    localparam VOL_BIDIR     = 4;
    localparam VOL_IRQ       = 5;
    localparam VOL_INVERT    = 6;
    localparam VOL_IRQ_PEND  = 7;

    typedef struct packed {
        // Oscillator fields
        logic [28:0] osc_acc;    // 20.9 fixed-point address accumulator
        logic [15:0] osc_fc;     // 6.9 fixed-point frequency control
        logic [28:0] osc_start;  // loop start address (20.9)
        logic [28:0] osc_end;    // loop end address (20.9)
        logic [7:0]  osc_saddr;  // sample bank address (bits 27-20)
        logic [7:0]  osc_conf;   // oscillator config flags
        logic [7:0]  osc_ctl;    // oscillator control register

        // Volume envelope fields
        logic [25:0] vol_acc;    // envelope accumulator (regacc << 10)
        logic [25:0] vol_start;  // envelope start
        logic [25:0] vol_end;    // envelope end
        logic [7:0]  vol_incr;   // increment register
        logic [7:0]  vol_pan;    // pan value (0-255)
        logic [7:0]  vol_ctrl;   // volume control flags
        logic [7:0]  vol_mode;   // mode (unused/reserved)

        // Voice state
        logic        state_on;   // voice is keyed on
        logic [6:0]  state_ramp; // ramp value (0-64)
    } voice_state_t;

endpackage
