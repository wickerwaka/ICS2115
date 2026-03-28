// ICS2115 Testbench — Minimal stub for build verification (T01)
// Full implementation with ROM loading, scripting, and WAV output is T03.

#include "Vics2115.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto top = new Vics2115;

    // Reset
    top->reset_n = 0;
    top->clk = 0;
    top->ce = 0;
    top->host_addr = 0;
    top->host_din = 0;
    top->host_wr = 0;
    top->host_rd = 0;
    top->rom_data = 0;

    // Toggle clock a few times under reset
    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
    }

    // Release reset
    top->reset_n = 1;

    // Run a few more clocks
    for (int i = 0; i < 20; i++) {
        top->clk = !top->clk;
        top->eval();
    }

    printf("ICS2115 stub testbench: compilation OK, basic reset/clock verified.\n");

    top->final();
    delete top;
    return 0;
}
