// ICS2115 WaveFront Synthesizer — Top-Level Module
// Wires package, tables, oscillator into a working system.
// Voice state array, sample tick generator, voice processing sequencer,
// ROM arbiter, audio clamping, and stub host bus for S02 testbench.

module ics2115
    import ics2115_pkg::*;
(
    input  logic        clk,
    input  logic        ce,         // clock enable (~33.8688 MHz)
    input  logic        reset_n,

    // Host bus interface — matches one-shot port signature for testbench reuse
    input  logic [1:0]  host_addr,
    input  logic [15:0] host_din,
    output logic [15:0] host_dout,
    input  logic        host_cs_n,
    input  logic        host_rd_n,
    input  logic        host_wr_n,
    output logic        host_irq,
    output logic        host_ready,

    // ROM interface (16-bit wide, synchronous, 1-cycle latency)
    output logic [22:0] rom_addr,    // word address
    input  logic [15:0] rom_data,
    output logic        rom_rd,

    // Audio output (parallel, directly captured by testbench)
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid
);

    // =========================================================================
    // Voice state array
    // =========================================================================
    voice_state_t voice_regs [0:NUM_VOICES-1];

    // =========================================================================
    // Global registers
    // =========================================================================
    logic [4:0] active_osc;
    logic [4:0] osc_select;
    logic [7:0] reg_select;     // latched register address from port 1
    logic [7:0] vmode;

    // =========================================================================
    // Tables instance
    // =========================================================================
    logic [11:0] vol_tbl_addr;
    logic [15:0] vol_tbl_data;
    logic [7:0]  pan_tbl_addr;
    logic [11:0] pan_tbl_data;
    logic [7:0]  ulaw_tbl_addr;
    logic signed [15:0] ulaw_tbl_data;

    ics2115_tables u_tables (
        .clk       (clk),
        .vol_addr  (vol_tbl_addr),
        .vol_data  (vol_tbl_data),
        .pan_addr  (pan_tbl_addr),
        .pan_data  (pan_tbl_data),
        .ulaw_addr (ulaw_tbl_addr),
        .ulaw_data (ulaw_tbl_data)
    );

    // =========================================================================
    // Sample tick generator
    // =========================================================================
    // Period = (active_osc + 1) * 32 CE clocks per sample
    logic [15:0] sample_div_counter;
    logic [15:0] sample_div_period;
    logic        sample_tick;

    assign sample_div_period = ({11'd0, active_osc} + 16'd1) * 16'd32;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_div_counter <= 16'd0;
            sample_tick        <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (ce) begin
                if (sample_div_counter >= sample_div_period - 16'd1) begin
                    sample_div_counter <= 16'd0;
                    sample_tick        <= 1'b1;
                end else begin
                    sample_div_counter <= sample_div_counter + 16'd1;
                end
            end
        end
    end

    // =========================================================================
    // Voice processing sequencer
    // =========================================================================
    typedef enum logic [2:0] {
        SEQ_IDLE    = 3'd0,
        SEQ_LOAD    = 3'd1,
        SEQ_WAIT    = 3'd2,
        SEQ_STORE   = 3'd3,
        SEQ_OUTPUT  = 3'd4
    } seq_state_t;

    seq_state_t seq_state;
    logic [4:0] seq_voice_idx;

    // Audio accumulators (24-bit signed to sum across all voices)
    logic signed [23:0] acc_left;
    logic signed [23:0] acc_right;

    // Sequencer output signals for voice write-back
    logic        seq_voice_wr;      // pulse: write back voice state
    logic [4:0]  seq_wr_idx;        // which voice to write back
    voice_state_t seq_wr_data;      // data to write back

    // Oscillator instance signals
    logic        osc_start;
    logic        osc_done;
    logic        osc_irq_osc;
    logic        osc_irq_vol;
    voice_state_t osc_voice_in;
    voice_state_t osc_voice_out;
    logic [23:0] osc_rom_byte_addr;
    logic        osc_rom_rd;
    logic [11:0] osc_vol_tbl_addr;
    logic [7:0]  osc_pan_tbl_addr;
    logic [7:0]  osc_ulaw_tbl_addr;
    logic signed [23:0] osc_audio_left;
    logic signed [23:0] osc_audio_right;
    logic        osc_audio_valid;

    ics2115_osc u_osc (
        .clk           (clk),
        .reset_n       (reset_n),
        .start         (osc_start),
        .done          (osc_done),
        .irq_osc       (osc_irq_osc),
        .irq_vol       (osc_irq_vol),
        .voice_in      (osc_voice_in),
        .voice_out     (osc_voice_out),
        .vmode         (vmode),
        .rom_byte_addr (osc_rom_byte_addr),
        .rom_rd        (osc_rom_rd),
        .rom_data      (rom_data),
        .vol_tbl_addr  (osc_vol_tbl_addr),
        .vol_tbl_data  (vol_tbl_data),
        .pan_tbl_addr  (osc_pan_tbl_addr),
        .pan_tbl_data  (pan_tbl_data),
        .ulaw_tbl_addr (osc_ulaw_tbl_addr),
        .ulaw_tbl_data (ulaw_tbl_data),
        .audio_left    (osc_audio_left),
        .audio_right   (osc_audio_right),
        .audio_valid   (osc_audio_valid)
    );

    // Connect oscillator table ports to tables module
    assign vol_tbl_addr  = osc_vol_tbl_addr;
    assign pan_tbl_addr  = osc_pan_tbl_addr;
    assign ulaw_tbl_addr = osc_ulaw_tbl_addr;

    // ROM address translation: byte address → word address
    assign rom_addr = osc_rom_byte_addr[23:1];
    assign rom_rd   = osc_rom_rd;

    // Sequencer FSM — drives osc_start, accumulates audio, signals write-back
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            seq_state     <= SEQ_IDLE;
            seq_voice_idx <= 5'd0;
            osc_start     <= 1'b0;
            osc_voice_in  <= '0;
            acc_left      <= 24'sd0;
            acc_right     <= 24'sd0;
            audio_left    <= 16'sd0;
            audio_right   <= 16'sd0;
            audio_valid   <= 1'b0;
            seq_voice_wr  <= 1'b0;
            seq_wr_idx    <= 5'd0;
            seq_wr_data   <= '0;
        end else begin
            // Defaults
            osc_start    <= 1'b0;
            audio_valid  <= 1'b0;
            seq_voice_wr <= 1'b0;

            case (seq_state)
                SEQ_IDLE: begin
                    if (sample_tick) begin
                        seq_voice_idx <= 5'd0;
                        acc_left      <= 24'sd0;
                        acc_right     <= 24'sd0;
                        seq_state     <= SEQ_LOAD;
                    end
                end

                SEQ_LOAD: begin
                    osc_voice_in <= voice_regs[seq_voice_idx];
                    osc_start    <= 1'b1;
                    seq_state    <= SEQ_WAIT;
                end

                SEQ_WAIT: begin
                    if (osc_done) begin
                        seq_state <= SEQ_STORE;
                    end
                end

                SEQ_STORE: begin
                    // Signal write-back to unified register block
                    seq_voice_wr <= 1'b1;
                    seq_wr_idx   <= seq_voice_idx;
                    seq_wr_data  <= osc_voice_out;

                    // Accumulate audio
                    acc_left  <= acc_left  + osc_audio_left;
                    acc_right <= acc_right + osc_audio_right;

                    if (seq_voice_idx >= active_osc) begin
                        seq_state <= SEQ_OUTPUT;
                    end else begin
                        seq_voice_idx <= seq_voice_idx + 5'd1;
                        seq_state     <= SEQ_LOAD;
                    end
                end

                SEQ_OUTPUT: begin
                    // Clamp 24-bit accumulators to 16-bit signed range
                    if (acc_left > 24'sd32767)
                        audio_left <= 16'sd32767;
                    else if (acc_left < -24'sd32768)
                        audio_left <= -16'sd32768;
                    else
                        audio_left <= acc_left[15:0];

                    if (acc_right > 24'sd32767)
                        audio_right <= 16'sd32767;
                    else if (acc_right < -24'sd32768)
                        audio_right <= -16'sd32768;
                    else
                        audio_right <= acc_right[15:0];

                    audio_valid <= 1'b1;
                    seq_state   <= SEQ_IDLE;
                end

                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Host bus write detection
    // =========================================================================
    logic host_wr_pulse;
    logic host_wr_prev;

    assign host_wr_pulse = ~host_cs_n & ~host_wr_n & host_wr_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            host_wr_prev <= 1'b1;
        else
            host_wr_prev <= host_cs_n | host_wr_n;
    end

    // Stub outputs — full protocol is S05
    assign host_ready = 1'b1;
    assign host_dout  = 16'd0;
    assign host_irq   = 1'b0;

    // =========================================================================
    // Unified voice_regs + global register write block
    // =========================================================================
    // Single always_ff drives voice_regs to avoid MULTIDRIVEN.
    // Priority: sequencer write-back > host writes (sequencer is pipeline-hot).

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_osc <= DEFAULT_ACTIVE_OSC;
            osc_select <= 5'd0;
            reg_select <= 8'd0;
            vmode      <= 8'd0;
            for (int i = 0; i < NUM_VOICES; i++) begin
                voice_regs[i].osc_acc   <= 29'd0;
                voice_regs[i].osc_fc    <= 16'd0;
                voice_regs[i].osc_start <= 29'd0;
                voice_regs[i].osc_end   <= 29'd0;
                voice_regs[i].osc_saddr <= 8'd0;
                voice_regs[i].osc_conf  <= 8'h02;  // stop=1
                voice_regs[i].osc_ctl   <= 8'd0;
                voice_regs[i].vol_acc   <= 26'd0;
                voice_regs[i].vol_start <= 26'd0;
                voice_regs[i].vol_end   <= 26'd0;
                voice_regs[i].vol_incr  <= 8'd0;
                voice_regs[i].vol_pan   <= 8'h7F;  // center
                voice_regs[i].vol_ctrl  <= 8'h01;  // done=1
                voice_regs[i].vol_mode  <= 8'd0;
                voice_regs[i].state_on  <= 1'b0;
                voice_regs[i].state_ramp <= 7'd0;
            end
        end else begin

            // ── Sequencer voice write-back (highest priority) ──
            if (seq_voice_wr) begin
                voice_regs[seq_wr_idx] <= seq_wr_data;
            end

            // ── Host bus port writes ──
            if (host_wr_pulse) begin
                case (host_addr)
                    2'd1: begin
                        reg_select <= host_din[7:0];
                    end
                    2'd3: begin
                        // High-byte write — per-voice and global registers
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h00: voice_regs[osc_select].osc_conf[6:0]  <= host_din[6:0];
                                5'h01: voice_regs[osc_select].osc_fc[15:8]   <= host_din[7:0];
                                5'h02: voice_regs[osc_select].osc_start[28:21] <= host_din[7:0];
                                5'h03: voice_regs[osc_select].osc_start[12:5]  <= host_din[7:0];
                                5'h04: voice_regs[osc_select].osc_end[28:21]   <= host_din[7:0];
                                5'h05: voice_regs[osc_select].osc_end[12:5]    <= host_din[7:0];
                                5'h06: voice_regs[osc_select].vol_incr         <= host_din[7:0];
                                5'h09: voice_regs[osc_select].vol_acc[25:18]   <= host_din[7:0];
                                5'h0A: voice_regs[osc_select].osc_acc[28:21]   <= host_din[7:0];
                                5'h0B: voice_regs[osc_select].osc_acc[12:5]    <= host_din[7:0];
                                5'h0C: voice_regs[osc_select].vol_pan          <= host_din[7:0];
                                5'h0D: voice_regs[osc_select].vol_ctrl[6:0]    <= host_din[6:0];
                                5'h0E: active_osc                              <= host_din[4:0];
                                5'h10: begin
                                    voice_regs[osc_select].osc_ctl <= host_din[7:0];
                                    if (host_din[7:0] == 8'h00) begin
                                        // Keyon
                                        voice_regs[osc_select].state_on        <= 1'b1;
                                        voice_regs[osc_select].state_ramp      <= MAX_RAMP;
                                        voice_regs[osc_select].osc_conf[OSC_STOP] <= 1'b0;
                                    end else if (host_din[7:0] == 8'h0F) begin
                                        // Keyoff
                                        voice_regs[osc_select].state_on        <= 1'b0;
                                        voice_regs[osc_select].osc_conf[OSC_STOP] <= 1'b1;
                                    end
                                end
                                5'h11: voice_regs[osc_select].osc_saddr        <= host_din[7:0];
                                5'h12: vmode                                    <= host_din[7:0];
                                default: ;
                            endcase
                        end else begin
                            case (reg_select)
                                8'h4F: osc_select <= host_din[4:0];
                                default: ;
                            endcase
                        end
                    end
                    2'd2: begin
                        // Low-byte write — per-voice registers that need low byte
                        if (reg_select < 8'h20) begin
                            case (reg_select[4:0])
                                5'h01: voice_regs[osc_select].osc_fc[7:0]      <= host_din[7:0];
                                5'h02: voice_regs[osc_select].osc_start[20:13]  <= host_din[7:0];
                                5'h04: voice_regs[osc_select].osc_end[20:13]    <= host_din[7:0];
                                5'h07: voice_regs[osc_select].vol_start         <= {host_din[7:0], 18'd0};
                                5'h08: voice_regs[osc_select].vol_end           <= {host_din[7:0], 18'd0};
                                5'h09: begin
                                    voice_regs[osc_select].vol_acc[17:10] <= host_din[7:0];
                                    voice_regs[osc_select].vol_acc[9:0]   <= 10'd0;
                                end
                                5'h0A: voice_regs[osc_select].osc_acc[20:13]    <= host_din[7:0];
                                5'h0B: voice_regs[osc_select].osc_acc[4:0]      <= host_din[7:3];
                                default: ;
                            endcase
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
