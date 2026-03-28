// ICS2115 Serial DAC Output
// BCK = crystal / 4, 48-BCK frame (24-bit left + 24-bit right, MSB first)
// 16-bit audio sign-extended to 24-bit
// SERDATA changes on BCK falling edge, sampled on rising edge

module ics2115_dac (
    input  logic        clk,
    input  logic        ce,         // chip clock enable (~33.8688 MHz)
    input  logic        reset_n,

    // Audio data input (16-bit signed)
    input  logic signed [15:0] audio_l,
    input  logic signed [15:0] audio_r,
    input  logic        audio_load,  // pulse to load new sample pair

    // Serial output
    output logic        bck,
    output logic        lrck,
    output logic        wdck,
    output logic        sdata
);

    // BCK generation: crystal / 4 = toggle every 2 ce ticks
    logic [1:0] bck_div;
    logic       bck_fall;  // BCK falling edge indicator

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bck_div <= 2'd0;
        end else if (ce) begin
            bck_div <= bck_div + 2'd1;
        end
    end

    assign bck = bck_div[1];

    // Detect BCK falling edge (bck_div transitions from 2'b1x to 2'b0x)
    logic bck_prev;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            bck_prev <= 1'b0;
        else
            bck_prev <= bck;
    end
    assign bck_fall = bck_prev & ~bck;

    // 48-bit shift register and frame counter
    logic [47:0] shift_reg;
    logic [5:0]  frame_cnt;  // 0-47
    logic        frame_active;

    // Sign-extend 16-bit to 24-bit
    wire [23:0] left_24  = {{8{audio_l[15]}}, audio_l};
    wire [23:0] right_24 = {{8{audio_r[15]}}, audio_r};

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            shift_reg    <= 48'd0;
            frame_cnt    <= 6'd0;
            frame_active <= 1'b0;
            sdata        <= 1'b0;
            lrck         <= 1'b1;
            wdck         <= 1'b0;
        end else begin
            // Load new sample data
            if (audio_load) begin
                shift_reg    <= {left_24, right_24};
                frame_cnt    <= 6'd0;
                frame_active <= 1'b1;
            end else if (bck_fall && frame_active) begin
                // Output MSB and shift on each BCK falling edge
                sdata     <= shift_reg[47];
                shift_reg <= {shift_reg[46:0], 1'b0};

                // LRCK: high during left (0-23), low during right (24-47)
                if (frame_cnt == 6'd23)
                    lrck <= 1'b0;
                else if (frame_cnt == 6'd47)
                    lrck <= 1'b1;

                // WDCK: transitions low-to-high between bits 12 and 11
                // (i.e., at frame_cnt 11 and 35), high-to-low after bit 0
                // (at frame_cnt 23 and 47)
                // Left channel: bit 23=MSB is frame_cnt 0, bit 0 is frame_cnt 23
                // "between bits 12 and 11" = frame_cnt 12
                // "after bit 0" = frame_cnt 23
                if (frame_cnt == 6'd12 || frame_cnt == 6'd36)
                    wdck <= 1'b1;
                else if (frame_cnt == 6'd23 || frame_cnt == 6'd47)
                    wdck <= 1'b0;

                if (frame_cnt == 6'd47)
                    frame_active <= 1'b0;
                else
                    frame_cnt <= frame_cnt + 6'd1;
            end
        end
    end

endmodule
