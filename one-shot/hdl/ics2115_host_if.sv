// ICS2115 Host CPU Interface
// 4-port indirect register access scheme:
//   Port 0 (read):  IRQ/Status register
//   Port 1 (r/w):   Register address select
//   Port 2 (r/w):   Data low byte or full 16-bit word
//   Port 3 (r/w):   Data high byte

module ics2115_host_if (
    input  logic        clk,
    input  logic        reset_n,

    // External host bus
    input  logic [1:0]  addr,
    input  logic [15:0] din,
    output logic [15:0] dout,
    input  logic        cs_n,
    input  logic        rd_n,
    input  logic        wr_n,

    // Internal register bus
    output logic [7:0]  reg_select,
    output logic [15:0] reg_wdata,
    output logic [1:0]  reg_wmask,   // [0]=low byte valid, [1]=high byte valid
    output logic        reg_wr,
    output logic        reg_rd,
    input  logic [15:0] reg_rdata,

    // Status inputs
    input  logic        irq_on,
    input  logic        timer_irq_any,
    input  logic        voice_irq_any
);

    // Edge detection for CS-qualified read/write strobes
    logic rd_prev, wr_prev;
    logic rd_active, wr_active;
    logic rd_pulse, wr_pulse;

    assign rd_active = ~cs_n & ~rd_n;
    assign wr_active = ~cs_n & ~wr_n;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_prev <= 1'b0;
            wr_prev <= 1'b0;
        end else begin
            rd_prev <= rd_active;
            wr_prev <= wr_active;
        end
    end

    assign rd_pulse = rd_active & ~rd_prev;
    assign wr_pulse = wr_active & ~wr_prev;

    // Register select latch
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_select <= 8'd0;
        end else if (wr_pulse && addr == 2'd1) begin
            reg_select <= din[7:0];
        end
    end

    // Write dispatch
    always_comb begin
        reg_wr    = 1'b0;
        reg_wdata = 16'd0;
        reg_wmask = 2'b00;

        if (wr_pulse) begin
            case (addr)
                2'd2: begin
                    // Low byte write (8-bit access)
                    reg_wr    = 1'b1;
                    reg_wdata = {8'd0, din[7:0]};
                    reg_wmask = 2'b01;
                end
                2'd3: begin
                    // High byte write (8-bit access)
                    reg_wr    = 1'b1;
                    reg_wdata = {din[7:0], 8'd0};
                    reg_wmask = 2'b10;
                end
                default: ;
            endcase
        end
    end

    // Read dispatch
    always_comb begin
        reg_rd = 1'b0;
        dout   = 16'd0;

        if (rd_active) begin
            case (addr)
                2'd0: begin
                    // Status register
                    dout[7] = irq_on;
                    dout[6:2] = 5'd0;
                    dout[1] = irq_on & voice_irq_any;
                    dout[0] = irq_on & timer_irq_any;
                end
                2'd1: begin
                    dout = {8'd0, reg_select};
                end
                2'd2: begin
                    reg_rd = 1'b1;
                    dout   = {8'd0, reg_rdata[7:0]};
                end
                2'd3: begin
                    reg_rd = 1'b1;
                    dout   = {8'd0, reg_rdata[15:8]};
                end
            endcase
        end
    end

endmodule
