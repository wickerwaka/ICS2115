// ICS2115 WaveFront Synthesizer — Top Level Module
// 50 MHz system clock with clock enable for ~33.8688 MHz crystal

import ics2115_pkg::*;

module ics2115 (
    input  logic        clk,
    input  logic        ce,          // clock enable at ~33.8688 MHz
    input  logic        reset_n,

    // Host bus
    input  logic [1:0]  host_addr,
    input  logic [15:0] host_din,
    output logic [15:0] host_dout,
    input  logic        host_cs_n,
    input  logic        host_rd_n,
    input  logic        host_wr_n,
    output logic        host_irq,
    output logic        host_ready,  // IOCHRDY: low when host must wait

    // ROM interface (16-bit wide, synchronous, 1-cycle latency)
    output logic [22:0] rom_addr,    // word address
    input  logic [15:0] rom_data,
    output logic        rom_rd,

    // DAC serial output
    output logic        dac_bck,
    output logic        dac_lrck,
    output logic        dac_wdck,
    output logic        dac_sdata
);

    // =========================================================================
    // Voice state array
    // =========================================================================
    voice_state_t voice [0:NUM_VOICES-1];

    // =========================================================================
    // Global registers
    // =========================================================================
    logic [4:0]  active_osc;
    logic [4:0]  osc_select;
    logic [7:0]  reg_select;
    logic [7:0]  irq_enabled;
    logic [7:0]  irq_pending;
    logic [7:0]  vmode;
    logic        irq_on;

    // Timer registers
    logic [7:0]  timer_preset  [0:1];
    logic [7:0]  timer_scale   [0:1];
    logic        timer_reload  [0:1];

    // =========================================================================
    // Sample rate tick generator
    // =========================================================================
    logic [15:0] sample_div_counter;
    logic [15:0] sample_div_period;
    logic        sample_tick;

    assign sample_div_period = {6'd0, ({5'd0, active_osc} + 16'd1)} * 16'd32;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_div_counter <= 16'd0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (ce) begin
                if (sample_div_counter >= sample_div_period - 16'd1) begin
                    sample_div_counter <= 16'd0;
                    sample_tick <= 1'b1;
                end else begin
                    sample_div_counter <= sample_div_counter + 16'd1;
                end
            end
        end
    end

    // =========================================================================
    // Host interface
    // =========================================================================
    logic [7:0]  hif_reg_select;
    logic [15:0] hif_reg_wdata;
    logic [1:0]  hif_reg_wmask;
    logic        hif_reg_wr;
    logic        hif_reg_rd;
    logic [15:0] hif_reg_rdata;
    logic        timer_irq_any;
    logic        voice_irq_any;

    assign timer_irq_any = |(irq_pending[1:0] & irq_enabled[1:0]);

    // Scan for any voice with osc IRQ pending
    always_comb begin
        voice_irq_any = 1'b0;
        for (int i = 0; i < NUM_VOICES; i++) begin
            if (i[4:0] <= active_osc) begin
                if (voice[i].osc_conf[OSC_IRQ_PEND])
                    voice_irq_any = 1'b1;
            end
        end
    end

    ics2115_host_if u_host_if (
        .clk        (clk),
        .reset_n    (reset_n),
        .addr       (host_addr),
        .din        (host_din),
        .dout       (host_dout),
        .cs_n       (host_cs_n),
        .rd_n       (host_rd_n),
        .wr_n       (host_wr_n),
        .reg_select (hif_reg_select),
        .reg_wdata  (hif_reg_wdata),
        .reg_wmask  (hif_reg_wmask),
        .reg_wr     (hif_reg_wr),
        .reg_rd     (hif_reg_rd),
        .reg_rdata  (hif_reg_rdata),
        .irq_on     (irq_on),
        .timer_irq_any (timer_irq_any),
        .voice_irq_any (voice_irq_any)
    );

    // Use the host_if's reg_select output (it latches port 1 writes)
    always_comb reg_select = hif_reg_select;

    // =========================================================================
    // Timers
    // =========================================================================
    logic timer0_fire, timer1_fire;

    ics2115_timers u_timers (
        .clk           (clk),
        .ce            (ce),
        .reset_n       (reset_n),
        .timer0_preset (timer_preset[0]),
        .timer0_scale  (timer_scale[0]),
        .timer0_reload (timer_reload[0]),
        .timer0_fire   (timer0_fire),
        .timer1_preset (timer_preset[1]),
        .timer1_scale  (timer_scale[1]),
        .timer1_reload (timer_reload[1]),
        .timer1_fire   (timer1_fire)
    );

    // =========================================================================
    // Tables
    // =========================================================================
    logic [11:0] vol_table_addr;
    logic [15:0] vol_table_data;
    logic [7:0]  pan_table_addr;
    logic [11:0] pan_table_data;
    logic [7:0]  ulaw_table_addr;
    logic signed [15:0] ulaw_table_data;

    ics2115_tables u_tables (
        .clk        (clk),
        .vol_addr   (vol_table_addr),
        .vol_data   (vol_table_data),
        .pan_addr   (pan_table_addr),
        .pan_data   (pan_table_data),
        .ulaw_addr  (ulaw_table_addr),
        .ulaw_data  (ulaw_table_data)
    );

    // =========================================================================
    // Voice processing pipeline
    // =========================================================================
    logic [4:0]  pipe_voice_idx;
    logic        pipe_voice_rd;
    logic        pipe_voice_wr;
    voice_state_t pipe_voice_rdata;
    voice_state_t pipe_voice_wdata;
    logic        pipe_voice_busy;
    logic [23:0] pipe_rom_byte_addr;
    logic        pipe_rom_rd;
    logic signed [23:0] pipe_audio_l;
    logic signed [23:0] pipe_audio_r;
    logic        pipe_audio_valid;
    logic        pipe_irq_changed;

    ics2115_voice u_voice (
        .clk            (clk),
        .reset_n        (reset_n),
        .sample_tick    (sample_tick),
        .active_osc     (active_osc),
        .vmode          (vmode),
        .voice_idx      (pipe_voice_idx),
        .voice_rd       (pipe_voice_rd),
        .voice_wr       (pipe_voice_wr),
        .voice_rdata    (pipe_voice_rdata),
        .voice_wdata    (pipe_voice_wdata),
        .voice_busy     (pipe_voice_busy),
        .rom_byte_addr  (pipe_rom_byte_addr),
        .rom_rd         (pipe_rom_rd),
        .rom_data       (rom_data),
        .vol_table_addr (vol_table_addr),
        .vol_table_data (vol_table_data),
        .pan_table_addr (pan_table_addr),
        .pan_table_data (pan_table_data),
        .ulaw_table_addr(ulaw_table_addr),
        .ulaw_table_data(ulaw_table_data),
        .audio_out_l    (pipe_audio_l),
        .audio_out_r    (pipe_audio_r),
        .audio_valid    (pipe_audio_valid),
        .irq_changed    (pipe_irq_changed)
    );

    // ROM address translation: byte address to word address
    assign rom_addr = pipe_rom_byte_addr[23:1];
    assign rom_rd   = pipe_rom_rd;

    // Pipeline voice state read
    assign pipe_voice_rdata = voice[pipe_voice_idx];

    // =========================================================================
    // DAC serial output
    // =========================================================================
    logic signed [15:0] dac_audio_l, dac_audio_r;
    logic dac_audio_load;

    // Latch audio output from pipeline
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dac_audio_l    <= 16'sd0;
            dac_audio_r    <= 16'sd0;
            dac_audio_load <= 1'b0;
        end else begin
            dac_audio_load <= 1'b0;
            if (pipe_audio_valid) begin
                // Clamp 24-bit accumulator to 16-bit output
                if (pipe_audio_l > 24'sd32767)
                    dac_audio_l <= 16'sd32767;
                else if (pipe_audio_l < -24'sd32768)
                    dac_audio_l <= -16'sd32768;
                else
                    dac_audio_l <= pipe_audio_l[15:0];

                if (pipe_audio_r > 24'sd32767)
                    dac_audio_r <= 16'sd32767;
                else if (pipe_audio_r < -24'sd32768)
                    dac_audio_r <= -16'sd32768;
                else
                    dac_audio_r <= pipe_audio_r[15:0];

                dac_audio_load <= 1'b1;
            end
        end
    end

    ics2115_dac u_dac (
        .clk        (clk),
        .ce         (ce),
        .reset_n    (reset_n),
        .audio_l    (dac_audio_l),
        .audio_r    (dac_audio_r),
        .audio_load (dac_audio_load),
        .bck        (dac_bck),
        .lrck       (dac_lrck),
        .wdck       (dac_wdck),
        .sdata      (dac_sdata)
    );

    // =========================================================================
    // Host arbitration (IOCHRDY)
    // =========================================================================
    // Deassert host_ready when:
    // 1. Pipeline is busy processing a voice, AND
    // 2. Host is trying to access a per-voice register (0x00-0x12)
    logic host_accessing_voice_reg;
    assign host_accessing_voice_reg = ~host_cs_n & (reg_select < 8'h20);

    assign host_ready = !(pipe_voice_busy && host_accessing_voice_reg &&
                          (~host_rd_n || ~host_wr_n));

    // =========================================================================
    // IRQ recalculation
    // =========================================================================
    always_comb begin
        logic any_voice_irq;
        any_voice_irq = 1'b0;
        for (int i = 0; i < NUM_VOICES; i++) begin
            any_voice_irq |= (voice[i].osc_conf[OSC_IRQ] & voice[i].osc_conf[OSC_IRQ_PEND]);
            any_voice_irq |= (voice[i].vol_ctrl[VOL_IRQ] & voice[i].vol_ctrl[VOL_IRQ_PEND]);
        end
        irq_on = (|(irq_pending & irq_enabled)) | any_voice_irq;
    end

    assign host_irq = irq_on;

    // =========================================================================
    // Register read decode
    // =========================================================================
    logic [7:0] conf_read_c;  // for register 0x00 read

    always_comb begin
        hif_reg_rdata = 16'd0;
        conf_read_c = voice[osc_select].osc_conf;
        conf_read_c[3] = voice[osc_select].state_on;

        if (reg_select < 8'h20) begin
            // Per-voice registers (indexed by osc_select)
            case (reg_select[4:0])
                5'h00: begin // Oscillator Configuration
                    hif_reg_rdata = {conf_read_c, 8'h00};
                end
                5'h01: hif_reg_rdata = voice[osc_select].osc_fc;
                5'h02: hif_reg_rdata = voice[osc_select].osc_start[28:13]; // start >> 16
                5'h03: hif_reg_rdata = {voice[osc_select].osc_start[12:5], 8'h00}; // (start >> 0) & 0xFF00
                5'h04: hif_reg_rdata = voice[osc_select].osc_end[28:13];
                5'h05: hif_reg_rdata = {voice[osc_select].osc_end[12:5], 8'h00};
                5'h06: hif_reg_rdata = {voice[osc_select].vol_incr, 8'h00};
                5'h07: hif_reg_rdata = {8'h00, voice[osc_select].vol_start[25:18]};
                5'h08: hif_reg_rdata = {8'h00, voice[osc_select].vol_end[25:18]};
                5'h09: hif_reg_rdata = voice[osc_select].vol_acc[25:10]; // acc >> 10
                5'h0A: hif_reg_rdata = voice[osc_select].osc_acc[28:13]; // acc >> 16
                5'h0B: begin
                    // MAME: (acc >> 0) & 0xFFF8
                    // Our acc[12:0] = MAME acc[15:3], plus 3 zero bits
                    hif_reg_rdata = {voice[osc_select].osc_acc[12:0], 3'b000};
                end
                5'h0C: hif_reg_rdata = {voice[osc_select].vol_pan, 8'h00};
                5'h0D: begin // Volume Envelope Control
                    if (vmode == 8'd0)
                        hif_reg_rdata = voice[osc_select].vol_ctrl[VOL_IRQ] ? {8'h81, 8'h00} : {8'h01, 8'h00};
                    else
                        hif_reg_rdata = {8'h01, 8'h00};
                end
                5'h0E: hif_reg_rdata = {3'd0, active_osc, 8'h00};
                5'h0F: begin
                    // Interrupt source register (side effects handled in sequential block)
                    hif_reg_rdata = {irqv_result, 8'h00};
                end
                5'h10: hif_reg_rdata = {voice[osc_select].osc_ctl, 8'h00};
                5'h11: hif_reg_rdata = {voice[osc_select].osc_saddr, 8'h00};
                default: hif_reg_rdata = 16'd0;
            endcase
        end else begin
            // Global registers
            case (reg_select)
                8'h40: hif_reg_rdata = {8'h00, timer_preset[0]};
                8'h41: hif_reg_rdata = {8'h00, timer_preset[1]};
                8'h43: hif_reg_rdata = {8'h00, 6'd0, irq_pending[1:0]};
                8'h4A: hif_reg_rdata = {8'h00, irq_pending};
                8'h4B: hif_reg_rdata = {8'h00, 8'h80}; // always 0x80
                8'h4C: hif_reg_rdata = {8'h00, CHIP_REVISION};
                default: hif_reg_rdata = 16'd0;
            endcase
        end
    end

    // =========================================================================
    // Register 0x0F read with side effects (interrupt source scan)
    // Handled combinationally for data, sequentially for flag clearing
    // =========================================================================
    logic [7:0]  irqv_result;
    logic [4:0]  irqv_voice;
    logic        irqv_osc_pending;
    logic        irqv_vol_pending;
    logic        irqv_found;

    always_comb begin
        irqv_result = 8'hFF;
        irqv_voice  = 5'd0;
        irqv_osc_pending = 1'b0;
        irqv_vol_pending = 1'b0;
        irqv_found  = 1'b0;

        for (int i = 0; i < NUM_VOICES; i++) begin
            if (!irqv_found && i[4:0] <= active_osc) begin
                if (voice[i].osc_conf[OSC_IRQ_PEND] || voice[i].vol_ctrl[VOL_IRQ_PEND]) begin
                    irqv_voice  = i[4:0];
                    irqv_result = {1'b1, 1'b1, 1'b1, i[4:0]};
                    if (voice[i].osc_conf[OSC_IRQ_PEND]) begin
                        irqv_result[7] = 1'b0;
                        irqv_osc_pending = 1'b1;
                    end
                    if (voice[i].vol_ctrl[VOL_IRQ_PEND]) begin
                        irqv_result[6] = 1'b0;
                        irqv_vol_pending = 1'b1;
                    end
                    irqv_found = 1'b1;
                end
            end
        end
    end

    // Register 0x0F read data is wired via irqv_result in the reg read comb block

    // =========================================================================
    // Register write decode and state update
    // =========================================================================
    // Edge detect for reg 0x0F read (to clear IRQ flags)
    logic reg0f_rd_pulse;
    logic reg0f_rd_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            reg0f_rd_prev <= 1'b0;
        else
            reg0f_rd_prev <= (hif_reg_rd && reg_select == 8'h0F);
    end
    assign reg0f_rd_pulse = (hif_reg_rd && reg_select == 8'h0F) && !reg0f_rd_prev;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_osc  <= DEFAULT_ACTIVE_OSC;
            osc_select  <= 5'd0;
            irq_enabled <= 8'd0;
            irq_pending <= 8'd0;
            vmode       <= 8'd0;
            timer_reload[0] <= 1'b0;
            timer_reload[1] <= 1'b0;
            timer_preset[0] <= 8'd0;
            timer_preset[1] <= 8'd0;
            timer_scale[0]  <= 8'd0;
            timer_scale[1]  <= 8'd0;

            for (int i = 0; i < NUM_VOICES; i++) begin
                voice[i].osc_acc   <= 29'd0;
                voice[i].osc_fc    <= 16'd0;
                voice[i].osc_start <= 29'd0;
                voice[i].osc_end   <= 29'd0;
                voice[i].osc_saddr <= 8'd0;
                voice[i].osc_conf  <= 8'h02;  // stop=1
                voice[i].osc_ctl   <= 8'd0;
                voice[i].vol_acc   <= 26'd0;
                voice[i].vol_start <= 26'd0;
                voice[i].vol_end   <= 26'd0;
                voice[i].vol_incr  <= 8'd0;
                voice[i].vol_pan   <= 8'h7F;  // center
                voice[i].vol_ctrl  <= 8'h01;  // done=1
                voice[i].vol_mode  <= 8'd0;
                voice[i].state_on  <= 1'b0;
                voice[i].state_ramp <= 7'd0;
            end
        end else begin
            // Default: clear one-shot signals
            timer_reload[0] <= 1'b0;
            timer_reload[1] <= 1'b0;

            // Timer fire events
            if (timer0_fire && !irq_pending[0]) begin
                irq_pending[0] <= 1'b1;
            end
            if (timer1_fire && !irq_pending[1]) begin
                irq_pending[1] <= 1'b1;
            end

            // Pipeline voice state write-back
            if (pipe_voice_wr) begin
                voice[pipe_voice_idx] <= pipe_voice_wdata;
            end

            // Register 0x0F read side effects: clear IRQ flags
            if (reg0f_rd_pulse && irqv_found) begin
                if (irqv_osc_pending)
                    voice[irqv_voice].osc_conf[OSC_IRQ_PEND] <= 1'b0;
                if (irqv_vol_pending)
                    voice[irqv_voice].vol_ctrl[VOL_IRQ_PEND] <= 1'b0;
            end

            // Register 0x40/0x41 read side effects: clear timer IRQ
            if (hif_reg_rd && (reg_select == 8'h40 || reg_select == 8'h41)) begin
                irq_pending[reg_select[0]] <= 1'b0;
            end

            // Host register writes
            if (hif_reg_wr && host_ready) begin
                if (reg_select < 8'h20) begin
                    // Per-voice registers
                    case (reg_select[4:0])
                        5'h00: begin // Oscillator Configuration
                            if (hif_reg_wmask[1]) begin
                                voice[osc_select].osc_conf[6:0] <= hif_reg_wdata[14:8];
                                // Preserve bit 7 (irq_pending)
                            end
                        end

                        5'h01: begin // Wavesample frequency
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_fc[15:8] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].osc_fc[7:1] <= hif_reg_wdata[7:1];
                                // bit 0 not used
                        end

                        5'h02: begin // Loop start high
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_start[28:21] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].osc_start[20:13] <= hif_reg_wdata[7:0];
                        end

                        5'h03: begin // Loop start low
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_start[12:5] <= hif_reg_wdata[15:8];
                        end

                        5'h04: begin // Loop end high
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_end[28:21] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].osc_end[20:13] <= hif_reg_wdata[7:0];
                        end

                        5'h05: begin // Loop end low
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_end[12:5] <= hif_reg_wdata[15:8];
                        end

                        5'h06: begin // Volume increment
                            if (hif_reg_wmask[1])
                                voice[osc_select].vol_incr <= hif_reg_wdata[15:8];
                        end

                        5'h07: begin // Volume start
                            if (hif_reg_wmask[0])
                                voice[osc_select].vol_start <= {hif_reg_wdata[7:0], 18'd0};
                        end

                        5'h08: begin // Volume end
                            if (hif_reg_wmask[0])
                                voice[osc_select].vol_end <= {hif_reg_wdata[7:0], 18'd0};
                        end

                        5'h09: begin // Volume accumulator
                            if (hif_reg_wmask[1])
                                voice[osc_select].vol_acc[25:18] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].vol_acc[17:10] <= hif_reg_wdata[7:0];
                            // Lower 10 bits derived from regacc << 10 (set to 0)
                            voice[osc_select].vol_acc[9:0] <= 10'd0;
                        end

                        5'h0A: begin // Oscillator address high
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_acc[28:21] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].osc_acc[20:13] <= hif_reg_wdata[7:0];
                        end

                        5'h0B: begin // Oscillator address low
                            // MAME: high byte → acc bits 15:8; low byte → acc bits 7:3 (mask 0xF8)
                            // Our mapping: acc[12:5] = MAME[15:8], acc[4:0] = MAME[7:3]
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_acc[12:5] <= hif_reg_wdata[15:8];
                            if (hif_reg_wmask[0])
                                voice[osc_select].osc_acc[4:0] <= hif_reg_wdata[7:3];
                        end

                        5'h0C: begin // Pan
                            if (hif_reg_wmask[1])
                                voice[osc_select].vol_pan <= hif_reg_wdata[15:8];
                        end

                        5'h0D: begin // Volume Envelope Control
                            if (hif_reg_wmask[1]) begin
                                voice[osc_select].vol_ctrl[6:0] <= hif_reg_wdata[14:8];
                                // Preserve bit 7 (irq_pending)
                            end
                        end

                        5'h0E: begin // Active Voices
                            if (hif_reg_wmask[1])
                                active_osc <= hif_reg_wdata[12:8];
                        end

                        5'h10: begin // Oscillator Control
                            if (hif_reg_wmask[1]) begin
                                voice[osc_select].osc_ctl <= hif_reg_wdata[15:8];

                                if (hif_reg_wdata[15:8] == 8'h00) begin
                                    // Keyon
                                    voice[osc_select].state_on <= 1'b1;
                                    voice[osc_select].state_ramp <= MAX_RAMP;
                                end else if (hif_reg_wdata[15:8] == 8'h0F) begin
                                    // Keyoff
                                    voice[osc_select].state_on <= ~|vmode;
                                    if (vmode == 8'd0) begin
                                        voice[osc_select].osc_conf[OSC_STOP] <= 1'b1;
                                        voice[osc_select].vol_ctrl[VOL_STOP] <= 1'b1;
                                    end
                                end
                            end
                        end

                        5'h11: begin // Wavesample static address
                            if (hif_reg_wmask[1])
                                voice[osc_select].osc_saddr <= hif_reg_wdata[15:8];
                        end

                        5'h12: begin // VMode
                            if (hif_reg_wmask[1])
                                vmode <= {hif_reg_wdata[15:8]};
                        end

                        default: ;
                    endcase
                end else begin
                    // Global registers
                    case (reg_select)
                        8'h40: begin // Timer 0 preset
                            if (hif_reg_wmask[0]) begin
                                timer_preset[0] <= hif_reg_wdata[7:0];
                                timer_reload[0] <= 1'b1;
                            end
                        end
                        8'h41: begin // Timer 1 preset
                            if (hif_reg_wmask[0]) begin
                                timer_preset[1] <= hif_reg_wdata[7:0];
                                timer_reload[1] <= 1'b1;
                            end
                        end
                        8'h42: begin // Timer 0 prescale
                            if (hif_reg_wmask[0]) begin
                                timer_scale[0] <= hif_reg_wdata[7:0];
                                timer_reload[0] <= 1'b1;
                            end
                        end
                        8'h43: begin // Timer 1 prescale
                            if (hif_reg_wmask[0]) begin
                                timer_scale[1] <= hif_reg_wdata[7:0];
                                timer_reload[1] <= 1'b1;
                            end
                        end
                        8'h4A: begin // IRQ Enable
                            if (hif_reg_wmask[0])
                                irq_enabled <= hif_reg_wdata[7:0];
                        end
                        8'h4F: begin // Oscillator select
                            if (hif_reg_wmask[0]) begin
                                // osc_select = data % (1 + active_osc)
                                if (hif_reg_wdata[7:0] <= {3'd0, active_osc})
                                    osc_select <= hif_reg_wdata[4:0];
                                else
                                    osc_select <= hif_reg_wdata[4:0] % (active_osc + 5'd1);
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
