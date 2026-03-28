module ics2115_tables (
    input  logic        clk,

    // Volume table (4096 entries, 16-bit unsigned)
    input  logic [11:0] vol_addr,
    output logic [15:0] vol_data,

    // Pan law (combinational, 256 entries, 12-bit)
    input  logic [7:0]  pan_addr,
    output logic [11:0] pan_data,

    // u-Law decode (combinational, 256 entries, signed 16-bit)
    input  logic [7:0]  ulaw_addr,
    output logic signed [15:0] ulaw_data
);

    // =========================================================================
    // Volume table: vol[i] = ((0x100 | (i & 0xFF)) << (VOLUME_BITS-9)) >> (15 - (i>>8))
    // VOLUME_BITS = 15, so << 6 then >> (15 - exponent)
    // =========================================================================
    logic [15:0] vol_mem [0:4095];

    initial begin
        for (int i = 0; i < 4096; i++) begin
            // VOLUME_BITS=15: shift = VOLUME_BITS - 9 = 6
            vol_mem[i] = ((16'h100 | i[7:0]) << 6) >> (15 - i[11:8]);
        end
    end

    always_ff @(posedge clk) begin
        vol_data <= vol_mem[vol_addr];
    end

    // =========================================================================
    // Pan law table: panlaw[0] = 0xFFF, panlaw[i] = 16 - floor(log2(i))
    // Implemented as priority encoder (count leading zeros)
    // =========================================================================
    always_comb begin
        if (pan_addr == 8'd0) begin
            pan_data = 12'hFFF;
        end else begin
            // floor(log2(i)) = position of highest set bit
            // panlaw = 16 - bit_position
            casez (pan_addr)
                8'b1???_????: pan_data = 12'd9;   // log2 = 7, 16-7 = 9
                8'b01??_????: pan_data = 12'd10;   // log2 = 6
                8'b001?_????: pan_data = 12'd11;   // log2 = 5
                8'b0001_????: pan_data = 12'd12;   // log2 = 4
                8'b0000_1???: pan_data = 12'd13;   // log2 = 3
                8'b0000_01??: pan_data = 12'd14;   // log2 = 2
                8'b0000_001?: pan_data = 12'd15;   // log2 = 1
                8'b0000_0001: pan_data = 12'd16;   // log2 = 0
                default:      pan_data = 12'd0;
            endcase
        end
    end

    // =========================================================================
    // u-Law decode table (MIL-STD-188-113)
    // exp = (~i >> 4) & 7; mant = ~i & 0xF
    // lut_base[j] = (132 << j) - 132
    // value = lut_base[exp] + (mant << (exp + 3))
    // result = (i[7]) ? -value : value
    // =========================================================================
    always_comb begin
        logic [2:0]  ulaw_exp;
        logic [3:0]  ulaw_mant;
        logic [15:0] lut_base;
        logic [15:0] ulaw_value;

        ulaw_exp  = (~ulaw_addr >> 4) & 3'd7;
        ulaw_mant = ~ulaw_addr & 4'hF;

        // lut_base[j] = (132 << j) - 132
        case (ulaw_exp)
            3'd0: lut_base = 16'd0;     // 132 - 132
            3'd1: lut_base = 16'd132;   // 264 - 132
            3'd2: lut_base = 16'd396;   // 528 - 132
            3'd3: lut_base = 16'd924;   // 1056 - 132
            3'd4: lut_base = 16'd1980;  // 2112 - 132
            3'd5: lut_base = 16'd4092;  // 4224 - 132
            3'd6: lut_base = 16'd8316;  // 8448 - 132
            3'd7: lut_base = 16'd16764; // 16896 - 132
        endcase

        // value = lut_base + (mant << (exp + 3))
        case (ulaw_exp)
            3'd0: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 3);
            3'd1: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 4);
            3'd2: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 5);
            3'd3: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 6);
            3'd4: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 7);
            3'd5: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 8);
            3'd6: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 9);
            3'd7: ulaw_value = lut_base + ({12'd0, ulaw_mant} << 10);
        endcase

        // Sign: bit 7 of input = 1 means negative
        if (ulaw_addr[7])
            ulaw_data = -$signed({1'b0, ulaw_value[14:0]});
        else
            ulaw_data = $signed({1'b0, ulaw_value[14:0]});
    end

endmodule
