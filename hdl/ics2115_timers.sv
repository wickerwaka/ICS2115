// Two hardware timers for the ICS2115
// Period = ((scale & 0x1F) + 1) * (preset + 1) << (4 + (scale >> 5))
// Counted in chip clock (ce) ticks

module ics2115_timers (
    input  logic        clk,
    input  logic        ce,
    input  logic        reset_n,

    // Timer 0
    input  logic [7:0]  timer0_preset,
    input  logic [7:0]  timer0_scale,
    input  logic        timer0_reload,
    output logic        timer0_fire,

    // Timer 1
    input  logic [7:0]  timer1_preset,
    input  logic [7:0]  timer1_scale,
    input  logic        timer1_reload,
    output logic        timer1_fire
);

    // Compute period from preset and scale registers
    function automatic logic [31:0] calc_period(input logic [7:0] preset, input logic [7:0] scale);
        logic [14:0] base;
        logic [2:0]  shift_extra;
        begin
            // (scale[4:0]+1) * (preset+1): max 32*256 = 8192 = 13 bits
            base = ({9'd0, scale[4:0]} + 15'd1) * ({6'd0, preset} + 15'd1);
            shift_extra = scale[7:5];
            calc_period = {17'd0, base} << (4 + {1'b0, shift_extra});
        end
    endfunction

    // Timer 0
    logic [31:0] timer0_counter;
    logic [31:0] timer0_period;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            timer0_counter <= 32'd0;
            timer0_period  <= 32'd0;
            timer0_fire    <= 1'b0;
        end else begin
            timer0_fire <= 1'b0;

            if (timer0_reload) begin
                timer0_period  <= calc_period(timer0_preset, timer0_scale);
                timer0_counter <= calc_period(timer0_preset, timer0_scale);
            end else if (ce && timer0_period != 32'd0) begin
                if (timer0_counter <= 32'd1) begin
                    timer0_fire    <= 1'b1;
                    timer0_counter <= timer0_period;
                end else begin
                    timer0_counter <= timer0_counter - 32'd1;
                end
            end
        end
    end

    // Timer 1
    logic [31:0] timer1_counter;
    logic [31:0] timer1_period;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            timer1_counter <= 32'd0;
            timer1_period  <= 32'd0;
            timer1_fire    <= 1'b0;
        end else begin
            timer1_fire <= 1'b0;

            if (timer1_reload) begin
                timer1_period  <= calc_period(timer1_preset, timer1_scale);
                timer1_counter <= calc_period(timer1_preset, timer1_scale);
            end else if (ce && timer1_period != 32'd0) begin
                if (timer1_counter <= 32'd1) begin
                    timer1_fire    <= 1'b1;
                    timer1_counter <= timer1_period;
                end else begin
                    timer1_counter <= timer1_counter - 32'd1;
                end
            end
        end
    end

endmodule
