// ICS2115 WaveFront Synthesizer — Top-Level Module (stub for S02/T01)
// This minimal version instantiates the package and tables module so Verilator
// can validate all types and table logic. Full implementation is T03.

module ics2115
    import ics2115_pkg::*;
(
    input  logic        clk,
    input  logic        ce,         // clock enable (active high)
    input  logic        reset_n,

    // Host bus interface (directly-mapped for testbench programming)
    input  logic [7:0]  host_addr,
    input  logic [15:0] host_din,
    output logic [15:0] host_dout,
    input  logic        host_wr,
    input  logic        host_rd,

    // ROM interface
    output logic [22:0] rom_addr,
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
    logic [7:0] vmode;

    // =========================================================================
    // Tables instance — validates table compilation
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
    // Stub outputs — will be replaced by real logic in T02/T03
    // =========================================================================
    assign host_dout   = 16'd0;
    assign rom_addr    = 23'd0;
    assign rom_rd      = 1'b0;
    assign audio_left  = 16'sd0;
    assign audio_right = 16'sd0;
    assign audio_valid = 1'b0;

    // Tie table inputs to zero for now
    assign vol_tbl_addr  = 12'd0;
    assign pan_tbl_addr  = 8'd0;
    assign ulaw_tbl_addr = 8'd0;

    // =========================================================================
    // Reset and initialization
    // =========================================================================
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_osc <= DEFAULT_ACTIVE_OSC;
            osc_select <= 5'd0;
            vmode      <= 8'd0;
            for (int i = 0; i < NUM_VOICES; i++) begin
                voice_regs[i] <= '0;
            end
        end
    end

endmodule
