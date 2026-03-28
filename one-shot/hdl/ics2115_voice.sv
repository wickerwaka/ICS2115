// ICS2115 Voice Processing Pipeline
// Processes voices sequentially via TDM. Each voice takes ~18 clock cycles.
// Triggered once per sample frame by sample_tick.

import ics2115_pkg::*;

module ics2115_voice (
    input  logic        clk,
    input  logic        reset_n,

    // Timing control
    input  logic        sample_tick,
    input  logic [4:0]  active_osc,
    input  logic [7:0]  vmode,

    // Voice state interface
    output logic [4:0]  voice_idx,
    output logic        voice_rd,
    output logic        voice_wr,
    input  voice_state_t voice_rdata,
    output voice_state_t voice_wdata,
    output logic        voice_busy,

    // ROM interface (24-bit byte address, 16-bit data, 1-cycle latency)
    output logic [23:0] rom_byte_addr,
    output logic        rom_rd,
    input  logic [15:0] rom_data,

    // Table lookup interfaces
    output logic [11:0] vol_table_addr,
    input  logic [15:0] vol_table_data,
    output logic [7:0]  pan_table_addr,
    input  logic [11:0] pan_table_data,
    output logic [7:0]  ulaw_table_addr,
    input  logic signed [15:0] ulaw_table_data,

    // Audio output
    output logic signed [23:0] audio_out_l,
    output logic signed [23:0] audio_out_r,
    output logic        audio_valid,

    // IRQ flag: set if any voice IRQ was triggered this frame
    output logic        irq_changed
);

    // Pipeline state machine
    typedef enum logic [4:0] {
        S_IDLE,
        S_READ_STATE,
        S_READ_WAIT,
        S_OSC_UPDATE,
        S_OSC_BOUNDARY,
        S_ROM_ADDR_1,
        S_ROM_WAIT_1,
        S_ROM_LATCH_1,
        S_ROM_ADDR_2,
        S_ROM_WAIT_2,
        S_ROM_LATCH_2,
        S_INTERPOLATE,
        S_VOL_UPDATE,
        S_VOL_BOUNDARY,
        S_PAN_LOOKUP,
        S_VOL_SCALE_L,
        S_VOL_SCALE_R,
        S_MIX,
        S_RAMP_UPDATE,
        S_WRITE_STATE
    } state_t;

    state_t state;

    // Working voice state
    voice_state_t v;

    // Current voice counter
    logic [4:0] cur_voice;

    // Audio accumulators
    logic signed [23:0] accum_l, accum_r;

    // Sample processing temporaries
    logic signed [15:0] sample1, sample2;
    logic signed [15:0] interp_sample;
    logic [8:0]         interp_frac;

    // Volume processing temporaries
    logic [15:0] vleft;
    logic signed [12:0] vlefti, vrighti;
    logic [11:0]        volacc;

    // IRQ tracking
    logic irq_flag;

    // Combinational intermediates (declared at module scope for synthesis safety)
    logic signed [29:0] osc_left_c;
    logic               new_invert_c;
    logic [19:0]        next_addr_c;
    logic [19:0]        cur_addr_c;
    logic [28:0]        remaining_c;
    logic signed [31:0] s1_shifted_c;
    logic signed [31:0] diff_frac_c;
    logic signed [31:0] interp_result_c;
    logic [25:0]        vol_add_c;
    logic signed [26:0] vol_left_c;
    logic signed [12:0] pan_idx_c;
    logic [15:0]        vright_now_c;
    logic signed [31:0] mix_l_c, mix_r_c;

    // Voice active check (computed from working copy)
    logic voice_playing;
    assign voice_playing = v.state_on & ~v.osc_conf[OSC_STOP];

    // Byte extracted from ROM word based on address alignment
    logic [7:0] rom_byte;
    assign rom_byte = rom_byte_addr[0] ? rom_data[15:8] : rom_data[7:0];

    // State machine
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= S_IDLE;
            cur_voice     <= 5'd0;
            accum_l       <= 24'sd0;
            accum_r       <= 24'sd0;
            audio_out_l   <= 24'sd0;
            audio_out_r   <= 24'sd0;
            audio_valid   <= 1'b0;
            irq_changed   <= 1'b0;
            irq_flag      <= 1'b0;
            voice_rd      <= 1'b0;
            voice_wr      <= 1'b0;
            voice_idx     <= 5'd0;
            voice_busy    <= 1'b0;
            rom_rd        <= 1'b0;
            rom_byte_addr <= 24'd0;
            v             <= '0;
            sample1       <= 16'sd0;
            sample2       <= 16'sd0;
            interp_sample <= 16'sd0;
            interp_frac   <= 9'd0;
            vleft         <= 16'd0;
            vlefti        <= 13'sd0;
            vrighti       <= 13'sd0;
            volacc        <= 12'd0;
            vol_table_addr <= 12'd0;
            pan_table_addr <= 8'd0;
            ulaw_table_addr <= 8'd0;
            voice_wdata   <= '0;
        end else begin
            // Default: clear one-cycle pulses
            voice_rd    <= 1'b0;
            voice_wr    <= 1'b0;
            audio_valid <= 1'b0;
            irq_changed <= 1'b0;
            rom_rd      <= 1'b0;

            case (state)
                // =============================================================
                S_IDLE: begin
                    voice_busy <= 1'b0;
                    if (sample_tick) begin
                        cur_voice  <= 5'd0;
                        accum_l    <= 24'sd0;
                        accum_r    <= 24'sd0;
                        irq_flag   <= 1'b0;
                        voice_busy <= 1'b1;
                        state      <= S_READ_STATE;
                    end
                end

                // =============================================================
                S_READ_STATE: begin
                    voice_idx <= cur_voice;
                    voice_rd  <= 1'b1;
                    state     <= S_READ_WAIT;
                end

                S_READ_WAIT: begin
                    v     <= voice_rdata;
                    state <= S_OSC_UPDATE;
                end

                // =============================================================
                // Oscillator update: acc += or -= (fc << 2)
                // =============================================================
                S_OSC_UPDATE: begin
                    if (v.osc_conf[OSC_STOP]) begin
                        state <= S_ROM_ADDR_1;
                    end else begin
                        if (v.osc_conf[OSC_INVERT])
                            v.osc_acc <= v.osc_acc - {11'd0, v.osc_fc, 2'b00};
                        else
                            v.osc_acc <= v.osc_acc + {11'd0, v.osc_fc, 2'b00};
                        state <= S_OSC_BOUNDARY;
                    end
                end

                // =============================================================
                // Oscillator boundary check
                // Forward:  left = end - acc.   Boundary if left <= 0.
                // Backward: left = acc - start. Boundary if left <= 0.
                // =============================================================
                S_OSC_BOUNDARY: begin
                    if (v.osc_conf[OSC_INVERT])
                        osc_left_c = $signed({1'b0, v.osc_acc}) - $signed({1'b0, v.osc_start});
                    else
                        osc_left_c = $signed({1'b0, v.osc_end}) - $signed({1'b0, v.osc_acc});

                    if (osc_left_c > 30'sd0) begin
                        state <= S_ROM_ADDR_1;
                    end else begin
                        if (v.osc_conf[OSC_IRQ]) begin
                            v.osc_conf[OSC_IRQ_PEND] <= 1'b1;
                            irq_flag <= 1'b1;
                        end

                        if (v.osc_conf[OSC_LOOP]) begin
                            // Compute new invert (bidir toggles direction)
                            new_invert_c = v.osc_conf[OSC_BIDIR] ?
                                           ~v.osc_conf[OSC_INVERT] : v.osc_conf[OSC_INVERT];
                            v.osc_conf[OSC_INVERT] <= new_invert_c;

                            // Wrap using NEW direction (matches MAME behavior)
                            if (new_invert_c)
                                v.osc_acc <= v.osc_end + osc_left_c[28:0];
                            else
                                v.osc_acc <= v.osc_start - osc_left_c[28:0];
                        end else begin
                            v.state_on <= 1'b0;
                            v.osc_conf[OSC_STOP] <= 1'b1;
                            if (!v.osc_conf[OSC_INVERT])
                                v.osc_acc <= v.osc_end;
                            else
                                v.osc_acc <= v.osc_start;
                        end
                        state <= S_ROM_ADDR_1;
                    end
                end

                // =============================================================
                // ROM sample fetch — sample 1
                // curaddr = acc[28:9] (20-bit integer part of 20.9 fixed-point)
                // ROM byte address = {saddr[3:0], curaddr} (24 bits)
                // =============================================================
                S_ROM_ADDR_1: begin
                    rom_byte_addr <= {4'd0, v.osc_saddr[3:0], v.osc_acc[28:9]};
                    interp_frac   <= v.osc_acc[8:0];
                    rom_rd        <= 1'b1;
                    state         <= S_ROM_WAIT_1;
                end

                S_ROM_WAIT_1: begin
                    if (v.osc_conf[OSC_ULAW]) begin
                        ulaw_table_addr <= rom_byte;
                        state <= S_ROM_LATCH_1;
                    end else if (v.osc_conf[OSC_EIGHTBIT]) begin
                        // (s8)byte << 8: byte in upper 8 bits, zeros below
                        sample1 <= {rom_byte, 8'h00};
                        state   <= S_ROM_ADDR_2;
                    end else begin
                        sample1 <= $signed(rom_data);
                        state   <= S_ROM_ADDR_2;
                    end
                end

                // Extra cycle for u-law combinational table to settle
                S_ROM_LATCH_1: begin
                    sample1 <= ulaw_table_data;
                    state   <= S_ROM_ADDR_2;
                end

                // =============================================================
                // ROM sample fetch — sample 2 (for interpolation)
                // =============================================================
                S_ROM_ADDR_2: begin
                    cur_addr_c = v.osc_acc[28:9];

                    if (v.osc_conf[OSC_EIGHTBIT] || v.osc_conf[OSC_ULAW]) begin
                        next_addr_c = cur_addr_c + 20'd1;
                    end else begin
                        // 16-bit: next sample 2 bytes ahead
                        // Near loop boundary (non-bidir): use loop start for interpolation
                        remaining_c = v.osc_end - v.osc_acc;
                        if (voice_playing && v.osc_conf[OSC_LOOP] && !v.osc_conf[OSC_BIDIR] &&
                            remaining_c < {11'd0, v.osc_fc, 2'b00})
                            next_addr_c = v.osc_start[28:9];
                        else
                            next_addr_c = cur_addr_c + 20'd2;
                    end

                    rom_byte_addr <= {4'd0, v.osc_saddr[3:0], next_addr_c};
                    rom_rd        <= 1'b1;
                    state         <= S_ROM_WAIT_2;
                end

                S_ROM_WAIT_2: begin
                    if (v.osc_conf[OSC_ULAW]) begin
                        ulaw_table_addr <= rom_byte;
                        state <= S_ROM_LATCH_2;
                    end else if (v.osc_conf[OSC_EIGHTBIT]) begin
                        sample2 <= {rom_byte, 8'h00};
                        state   <= S_INTERPOLATE;
                    end else begin
                        sample2 <= $signed(rom_data);
                        state   <= S_INTERPOLATE;
                    end
                end

                S_ROM_LATCH_2: begin
                    sample2 <= ulaw_table_data;
                    state   <= S_INTERPOLATE;
                end

                // =============================================================
                // Linear interpolation
                // result = ((s1 << 9) + (s2 - s1) * fract) >> 9
                // =============================================================
                S_INTERPOLATE: begin
                    s1_shifted_c = $signed(sample1) <<< 9;
                    diff_frac_c = ($signed(sample2) - $signed(sample1)) *
                                  $signed({1'b0, interp_frac});
                    interp_result_c = (s1_shifted_c + diff_frac_c) >>> 9;
                    interp_sample <= interp_result_c[15:0];
                    state <= S_VOL_UPDATE;
                end

                // =============================================================
                // Volume envelope update
                // =============================================================
                S_VOL_UPDATE: begin
                    if (v.vol_ctrl[VOL_DONE] || v.vol_ctrl[VOL_STOP]) begin
                        state <= S_PAN_LOOKUP;
                    end else begin
                        case (v.vol_incr[7:6])
                            2'b00:   vol_add_c = {11'd0, v.vol_incr[5:0], 9'd0};
                            2'b01:   vol_add_c = {18'd0, v.vol_incr[5:0], 2'd0};
                            default: vol_add_c = 26'd0;
                        endcase

                        if (v.vol_ctrl[VOL_INVERT])
                            v.vol_acc <= v.vol_acc - vol_add_c;
                        else
                            v.vol_acc <= v.vol_acc + vol_add_c;

                        state <= S_VOL_BOUNDARY;
                    end
                end

                // =============================================================
                // Volume envelope boundary check
                // =============================================================
                S_VOL_BOUNDARY: begin
                    if (v.vol_ctrl[VOL_INVERT])
                        vol_left_c = $signed({1'b0, v.vol_acc}) - $signed({1'b0, v.vol_start});
                    else
                        vol_left_c = $signed({1'b0, v.vol_end}) - $signed({1'b0, v.vol_acc});

                    if (vol_left_c > 27'sd0) begin
                        state <= S_PAN_LOOKUP;
                    end else begin
                        if (v.vol_ctrl[VOL_IRQ]) begin
                            v.vol_ctrl[VOL_IRQ_PEND] <= 1'b1;
                            irq_flag <= 1'b1;
                        end

                        if (v.osc_conf[OSC_EIGHTBIT]) begin
                            state <= S_PAN_LOOKUP;
                        end else if (v.vol_ctrl[VOL_LOOP]) begin
                            if (v.vol_ctrl[VOL_BIDIR]) begin
                                if (!v.vol_ctrl[VOL_INVERT])
                                    v.vol_acc <= v.vol_end + v.vol_end - v.vol_acc;
                                else
                                    v.vol_acc <= v.vol_start + v.vol_start - v.vol_acc;
                                v.vol_ctrl[VOL_INVERT] <= ~v.vol_ctrl[VOL_INVERT];
                            end else begin
                                if (!v.vol_ctrl[VOL_INVERT])
                                    v.vol_acc <= v.vol_start - vol_left_c[25:0];
                                else
                                    v.vol_acc <= v.vol_end + vol_left_c[25:0];
                            end
                            state <= S_PAN_LOOKUP;
                        end else begin
                            v.vol_ctrl[VOL_DONE] <= 1'b1;
                            state <= S_PAN_LOOKUP;
                        end
                    end
                end

                // =============================================================
                // Pan lookup — start left channel pan law lookup
                // =============================================================
                S_PAN_LOOKUP: begin
                    volacc <= v.vol_acc[25:14];
                    pan_table_addr <= 8'd255 - v.vol_pan;
                    state <= S_VOL_SCALE_L;
                end

                // =============================================================
                // Left volume: compute pan-adjusted index, look up volume table
                // =============================================================
                S_VOL_SCALE_L: begin
                    // pan_table_data = panlaw[255-pan] (left attenuation)
                    vlefti <= $signed({1'b0, volacc}) - $signed({1'b0, pan_table_data});

                    // Set up volume table lookup using same computation
                    pan_idx_c = $signed({1'b0, volacc}) - $signed({1'b0, pan_table_data});
                    vol_table_addr <= (pan_idx_c > 13'sd0) ? pan_idx_c[11:0] : 12'd0;

                    // Start right pan lookup (combinational table, available next cycle)
                    pan_table_addr <= v.vol_pan;

                    state <= S_VOL_SCALE_R;
                end

                // =============================================================
                // Right volume: latch left vol from table, set up right vol lookup
                // =============================================================
                S_VOL_SCALE_R: begin
                    // vol_table_data = volume[vlefti] (1-cycle registered ROM latency)
                    if (vlefti > 13'sd0)
                        vleft <= (vol_table_data * {9'd0, v.state_ramp}) >> 6;
                    else
                        vleft <= 16'd0;

                    // pan_table_data = panlaw[pan] (right attenuation, combinational)
                    vrighti <= $signed({1'b0, volacc}) - $signed({1'b0, pan_table_data});

                    // Set up right volume table lookup
                    pan_idx_c = $signed({1'b0, volacc}) - $signed({1'b0, pan_table_data});
                    vol_table_addr <= (pan_idx_c > 13'sd0) ? pan_idx_c[11:0] : 12'd0;

                    state <= S_MIX;
                end

                // =============================================================
                // Mix: compute right vol, accumulate both channels
                // =============================================================
                S_MIX: begin
                    // vol_table_data = volume[vrighti] (from registered ROM)
                    if (vrighti > 13'sd0)
                        vright_now_c = (vol_table_data * {9'd0, v.state_ramp}) >> 6;
                    else
                        vright_now_c = 16'd0;

                    // Mix: output += (sample * volume) >> 20
                    // 15 bits volume + 5 bits for 32 voices = 20 bit shift
                    if (vmode == 8'd0 || voice_playing) begin
                        mix_l_c = $signed(interp_sample) * $signed({1'b0, vleft});
                        mix_r_c = $signed(interp_sample) * $signed({1'b0, vright_now_c});
                        accum_l <= accum_l + {{12{mix_l_c[31]}}, mix_l_c[31:20]};
                        accum_r <= accum_r + {{12{mix_r_c[31]}}, mix_r_c[31:20]};
                    end

                    state <= S_RAMP_UPDATE;
                end

                // =============================================================
                // Ramp update (soft attack/release)
                // =============================================================
                S_RAMP_UPDATE: begin
                    if (v.state_on && !v.osc_conf[OSC_STOP]) begin
                        if (v.state_ramp < MAX_RAMP)
                            v.state_ramp <= v.state_ramp + 7'd1;
                    end else begin
                        if (v.state_ramp > 7'd0)
                            v.state_ramp <= v.state_ramp - 7'd1;
                    end
                    state <= S_WRITE_STATE;
                end

                // =============================================================
                // Write back and advance to next voice
                // =============================================================
                S_WRITE_STATE: begin
                    voice_idx   <= cur_voice;
                    voice_wdata <= v;
                    voice_wr    <= 1'b1;

                    if (cur_voice == active_osc) begin
                        audio_out_l <= accum_l;
                        audio_out_r <= accum_r;
                        audio_valid <= 1'b1;
                        if (irq_flag)
                            irq_changed <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        cur_voice <= cur_voice + 5'd1;
                        state     <= S_READ_STATE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
