#include "Vics2115.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32_t SYS_CLK_HZ     = 50'000'000;
static constexpr uint32_t CRYSTAL_HZ      = 33'868'800;
static constexpr uint64_t DEFAULT_TIMEOUT  = 10'000'000;
static constexpr int      RESET_CYCLES     = 200;

// ---------------------------------------------------------------------------
// Script command types
// ---------------------------------------------------------------------------
enum class CmdType { WRITE, READ, WAIT, WAIT_IRQ, UNTIL, EXPECT };

struct ScriptCmd {
    CmdType  type;
    uint32_t reg;
    uint32_t value;
    uint32_t mask;
    uint64_t cycles;
    int      line_num;
};

// ---------------------------------------------------------------------------
// Simulation state
// ---------------------------------------------------------------------------
struct SimState {
    Vics2115*       top;
    VerilatedVcdC*  tfp;        // nullptr when VCD disabled
    uint64_t        sim_time = 0;

    // Clock enable phase accumulator
    uint32_t        ce_accum = 0;

    // ROM (loaded from file)
    std::vector<uint16_t> rom;

    // ROM 1-cycle latency pipeline
    bool     rom_rd_prev   = false;
    uint32_t rom_addr_prev = 0;

    // Audio capture (interleaved L/R)
    std::vector<int16_t> audio_samples;
};

// ---------------------------------------------------------------------------
// Clock enable generator
// ---------------------------------------------------------------------------
static bool generate_ce(SimState& s) {
    s.ce_accum += CRYSTAL_HZ;
    if (s.ce_accum >= SYS_CLK_HZ) {
        s.ce_accum -= SYS_CLK_HZ;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Core simulation tick — one full clock cycle
// ---------------------------------------------------------------------------
static void tick(SimState& s) {
    auto* top = s.top;
    auto* tfp = s.tfp;

    // Provide ROM data from previous cycle's request (1-cycle latency)
    if (s.rom_rd_prev) {
        if (s.rom_addr_prev < s.rom.size())
            top->rom_data = s.rom[s.rom_addr_prev];
        else
            top->rom_data = 0;
    }

    // Generate clock enable
    top->ce = generate_ce(s) ? 1 : 0;

    // Rising edge
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(s.sim_time++);

    // Capture ROM request for next cycle
    s.rom_rd_prev   = top->rom_rd;
    s.rom_addr_prev = top->rom_addr;

    // Capture parallel audio output
    if (top->audio_valid) {
        s.audio_samples.push_back(static_cast<int16_t>(top->audio_left));
        s.audio_samples.push_back(static_cast<int16_t>(top->audio_right));
    }

    // Falling edge
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(s.sim_time++);
}

// ---------------------------------------------------------------------------
// Host bus: write to a port
// ---------------------------------------------------------------------------
static void host_write_port(SimState& s, uint8_t port, uint16_t data) {
    auto* top = s.top;

    // Assert CS + WR with address and data
    top->host_addr  = port;
    top->host_din   = data;
    top->host_cs_n  = 0;
    top->host_wr_n  = 0;
    tick(s);

    // Deassert
    top->host_cs_n = 1;
    top->host_wr_n = 1;
    tick(s);
}

// ---------------------------------------------------------------------------
// Host bus: read from a port
// ---------------------------------------------------------------------------
static uint16_t host_read_port(SimState& s, uint8_t port) {
    auto* top = s.top;

    // Assert CS + RD with address
    top->host_addr  = port;
    top->host_cs_n  = 0;
    top->host_rd_n  = 0;
    tick(s);

    // Capture output while still asserted
    uint16_t val = top->host_dout;

    // Deassert
    top->host_cs_n = 1;
    top->host_rd_n = 1;
    tick(s);

    return val;
}

// ---------------------------------------------------------------------------
// Register read: set reg address via port 1 write, then read high/low bytes
// ---------------------------------------------------------------------------
static uint16_t host_reg_read(SimState& s, uint8_t reg) {
    // Port 1: set register address
    host_write_port(s, 1, reg);
    // Port 3: read high byte (returns value in high byte position)
    uint16_t hi = host_read_port(s, 3);
    // Port 2: read low byte (returns value in low byte position)
    uint16_t lo = host_read_port(s, 2);
    return (hi & 0xFF00) | (lo & 0x00FF);
}

// ---------------------------------------------------------------------------
// Register write: set reg address, then write high and low bytes
// ---------------------------------------------------------------------------
static void host_reg_write(SimState& s, uint8_t reg, uint16_t value) {
    // Port 1: set register address
    host_write_port(s, 1, reg);
    // Port 3: write high byte
    host_write_port(s, 3, (value >> 8) & 0xFF);
    // Port 2: write low byte
    host_write_port(s, 2, value & 0xFF);
}

// ---------------------------------------------------------------------------
// ROM loader
// ---------------------------------------------------------------------------
static std::vector<uint16_t> load_rom(const char* filename) {
    std::ifstream f(filename, std::ios::binary | std::ios::ate);
    if (!f) {
        fprintf(stderr, "ERROR: cannot open ROM file: %s\n", filename);
        exit(1);
    }

    auto size = f.tellg();
    f.seekg(0);

    std::vector<uint8_t> raw(size);
    f.read(reinterpret_cast<char*>(raw.data()), size);

    // Convert to 16-bit words (little-endian)
    size_t word_count = (raw.size() + 1) / 2;
    std::vector<uint16_t> rom(word_count, 0);
    for (size_t i = 0; i < raw.size(); i += 2) {
        uint16_t lo = raw[i];
        uint16_t hi = (i + 1 < raw.size()) ? raw[i + 1] : 0;
        rom[i / 2] = (hi << 8) | lo;
    }

    printf("Loaded ROM: %zu bytes (%zu words)\n", raw.size(), word_count);
    return rom;
}

// ---------------------------------------------------------------------------
// Script parser
// ---------------------------------------------------------------------------
static std::vector<ScriptCmd> parse_script(const char* filename) {
    std::ifstream f(filename);
    if (!f) {
        fprintf(stderr, "ERROR: cannot open script file: %s\n", filename);
        exit(1);
    }

    std::vector<ScriptCmd> cmds;
    std::string line;
    int line_num = 0;

    while (std::getline(f, line)) {
        line_num++;

        // Strip comments
        auto hash_pos = line.find('#');
        if (hash_pos != std::string::npos)
            line = line.substr(0, hash_pos);

        // Skip blank lines
        std::istringstream iss(line);
        std::string cmd;
        if (!(iss >> cmd))
            continue;

        ScriptCmd sc{};
        sc.line_num = line_num;

        if (cmd == "write") {
            sc.type = CmdType::WRITE;
            std::string reg_s, val_s;
            if (!(iss >> reg_s >> val_s)) {
                fprintf(stderr, "ERROR: line %d: write requires <reg> <value>\n", line_num);
                exit(1);
            }
            sc.reg   = std::stoul(reg_s, nullptr, 0);
            sc.value = std::stoul(val_s, nullptr, 0);
        } else if (cmd == "read") {
            sc.type = CmdType::READ;
            std::string reg_s;
            if (!(iss >> reg_s)) {
                fprintf(stderr, "ERROR: line %d: read requires <reg>\n", line_num);
                exit(1);
            }
            sc.reg = std::stoul(reg_s, nullptr, 0);
        } else if (cmd == "wait") {
            sc.type = CmdType::WAIT;
            std::string cyc_s;
            if (!(iss >> cyc_s)) {
                fprintf(stderr, "ERROR: line %d: wait requires <cycles>\n", line_num);
                exit(1);
            }
            sc.cycles = std::stoull(cyc_s, nullptr, 0);
        } else if (cmd == "wait_irq") {
            sc.type = CmdType::WAIT_IRQ;
            std::string timeout_s;
            if (iss >> timeout_s)
                sc.cycles = std::stoull(timeout_s, nullptr, 0);
            else
                sc.cycles = DEFAULT_TIMEOUT;
        } else if (cmd == "until") {
            sc.type = CmdType::UNTIL;
            std::string reg_s, val_s, mask_s, timeout_s;
            if (!(iss >> reg_s >> val_s >> mask_s)) {
                fprintf(stderr, "ERROR: line %d: until requires <reg> <value> <mask>\n", line_num);
                exit(1);
            }
            sc.reg   = std::stoul(reg_s, nullptr, 0);
            sc.value = std::stoul(val_s, nullptr, 0);
            sc.mask  = std::stoul(mask_s, nullptr, 0);
            if (iss >> timeout_s)
                sc.cycles = std::stoull(timeout_s, nullptr, 0);
            else
                sc.cycles = DEFAULT_TIMEOUT;
        } else if (cmd == "expect") {
            sc.type = CmdType::EXPECT;
            std::string reg_s, val_s, mask_s;
            if (!(iss >> reg_s >> val_s)) {
                fprintf(stderr, "ERROR: line %d: expect requires <reg> <value> [mask]\n", line_num);
                exit(1);
            }
            sc.reg   = std::stoul(reg_s, nullptr, 0);
            sc.value = std::stoul(val_s, nullptr, 0);
            if (iss >> mask_s)
                sc.mask = std::stoul(mask_s, nullptr, 0);
            else
                sc.mask = 0xFFFF;
        } else {
            fprintf(stderr, "ERROR: line %d: unknown command '%s'\n", line_num, cmd.c_str());
            exit(1);
        }

        cmds.push_back(sc);
    }

    printf("Parsed %zu script commands\n", cmds.size());
    return cmds;
}

// ---------------------------------------------------------------------------
// WAV file writer
// ---------------------------------------------------------------------------
static void write_wav(const char* filename,
                      const std::vector<int16_t>& samples,
                      uint32_t sample_rate) {
    FILE* f = fopen(filename, "wb");
    if (!f) {
        fprintf(stderr, "ERROR: cannot open WAV output: %s\n", filename);
        return;
    }

    uint32_t num_channels   = 2;
    uint32_t bits_per_sample = 16;
    uint32_t byte_rate      = sample_rate * num_channels * (bits_per_sample / 8);
    uint16_t block_align    = num_channels * (bits_per_sample / 8);
    uint32_t data_size      = samples.size() * sizeof(int16_t);
    uint32_t chunk_size     = 36 + data_size;

    // RIFF header
    fwrite("RIFF", 1, 4, f);
    fwrite(&chunk_size, 4, 1, f);
    fwrite("WAVE", 1, 4, f);

    // fmt subchunk
    fwrite("fmt ", 1, 4, f);
    uint32_t subchunk1_size = 16;
    uint16_t audio_format   = 1;  // PCM
    uint16_t num_ch         = num_channels;
    uint16_t bps            = bits_per_sample;
    fwrite(&subchunk1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    fwrite(&num_ch, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bps, 2, 1, f);

    // data subchunk
    fwrite("data", 1, 4, f);
    fwrite(&data_size, 4, 1, f);
    fwrite(samples.data(), sizeof(int16_t), samples.size(), f);

    fclose(f);
    printf("Wrote WAV: %s (%u frames, %u Hz)\n",
           filename, static_cast<uint32_t>(samples.size() / 2), sample_rate);
}

// ---------------------------------------------------------------------------
// Script executor
// ---------------------------------------------------------------------------
static int execute_script(SimState& s, const std::vector<ScriptCmd>& cmds) {
    int error_count = 0;

    for (size_t i = 0; i < cmds.size(); i++) {
        const auto& cmd = cmds[i];

        switch (cmd.type) {
        case CmdType::WRITE:
            printf("[%zu] write reg 0x%02X = 0x%04X\n", i, cmd.reg, cmd.value);
            host_reg_write(s, cmd.reg, cmd.value);
            break;

        case CmdType::READ: {
            uint16_t val = host_reg_read(s, cmd.reg);
            printf("[%zu] read reg 0x%02X = 0x%04X\n", i, cmd.reg, val);
            break;
        }

        case CmdType::WAIT: {
            printf("[%zu] wait %llu cycles\n", i, (unsigned long long)cmd.cycles);
            for (uint64_t c = 0; c < cmd.cycles; c++)
                tick(s);
            break;
        }

        case CmdType::WAIT_IRQ: {
            printf("[%zu] wait_irq (timeout %llu)\n", i, (unsigned long long)cmd.cycles);
            bool got_irq = false;
            for (uint64_t c = 0; c < cmd.cycles; c++) {
                tick(s);
                if (s.top->host_irq) {
                    printf("  IRQ asserted after %llu cycles\n", (unsigned long long)(c + 1));
                    got_irq = true;
                    break;
                }
            }
            if (!got_irq) {
                printf("  FAIL: wait_irq timed out\n");
                error_count++;
            }
            break;
        }

        case CmdType::UNTIL: {
            printf("[%zu] until reg 0x%02X & 0x%04X == 0x%04X (timeout %llu)\n",
                   i, cmd.reg, cmd.mask, cmd.value, (unsigned long long)cmd.cycles);
            bool matched = false;
            uint16_t last_val = 0;
            for (uint64_t c = 0; c < cmd.cycles; c++) {
                last_val = host_reg_read(s, cmd.reg);
                if ((last_val & cmd.mask) == cmd.value) {
                    printf("  matched after %llu iterations: 0x%04X\n",
                           (unsigned long long)(c + 1), last_val);
                    matched = true;
                    break;
                }
                // Tick a few cycles between polls to avoid spinning too tightly
                for (int t = 0; t < 4; t++) tick(s);
            }
            if (!matched) {
                printf("  FAIL: until timed out, last value 0x%04X\n", last_val);
                error_count++;
            }
            break;
        }

        case CmdType::EXPECT: {
            uint16_t actual = host_reg_read(s, cmd.reg);
            uint16_t masked = actual & cmd.mask;
            if (masked == cmd.value) {
                printf("[%zu] EXPECT reg 0x%02X: expected 0x%04X got 0x%04X (mask 0x%04X) — PASS\n",
                       i, cmd.reg, cmd.value, masked, cmd.mask);
            } else {
                printf("[%zu] EXPECT reg 0x%02X: expected 0x%04X got 0x%04X (mask 0x%04X) — FAIL\n",
                       i, cmd.reg, cmd.value, masked, cmd.mask);
                error_count++;
            }
            break;
        }
        }
    }

    if (error_count > 0)
        printf("ERRORS: %d assertion(s) failed\n", error_count);

    return error_count;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    const char* rom_file    = nullptr;
    const char* script_file = nullptr;
    const char* wav_file    = "output.wav";
    const char* vcd_file    = "trace.vcd";
    uint32_t    sample_rate = 33075;
    bool        enable_vcd  = true;

    // Parse arguments
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-rom") && i + 1 < argc)
            rom_file = argv[++i];
        else if (!strcmp(argv[i], "-script") && i + 1 < argc)
            script_file = argv[++i];
        else if (!strcmp(argv[i], "-wav") && i + 1 < argc)
            wav_file = argv[++i];
        else if (!strcmp(argv[i], "-vcd") && i + 1 < argc)
            vcd_file = argv[++i];
        else if (!strcmp(argv[i], "-sample-rate") && i + 1 < argc)
            sample_rate = std::stoul(argv[++i]);
        else if (!strcmp(argv[i], "-no-vcd"))
            enable_vcd = false;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("Usage: %s [options]\n"
                   "  -rom <file>          ROM binary file (required)\n"
                   "  -script <file>       Script file (required)\n"
                   "  -wav <file>          Output WAV file (default: output.wav)\n"
                   "  -vcd <file>          Output VCD file (default: trace.vcd)\n"
                   "  -no-vcd              Skip VCD generation (saves disk space)\n"
                   "  -sample-rate <hz>    WAV sample rate (default: 33075)\n",
                   argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 1;
        }
    }

    if (!rom_file || !script_file) {
        fprintf(stderr, "ERROR: -rom and -script are required\n");
        return 1;
    }

    // Initialize Verilator (use static API — VerilatedContext has mutex issues
    // with tracing on Verilator 5.018/macOS)
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto top = std::make_unique<Vics2115>();

    // Set up simulation state
    SimState s;
    s.top = top.get();
    s.tfp = nullptr;

    // VCD tracing (optional) — keep tfp alive for the whole function scope
    std::unique_ptr<VerilatedVcdC> tfp;
    if (enable_vcd) {
        tfp = std::make_unique<VerilatedVcdC>();
        top->trace(tfp.get(), 99);
        tfp->open(vcd_file);
        s.tfp = tfp.get();
    }

    // Load ROM
    s.rom = load_rom(rom_file);

    // Parse script
    auto cmds = parse_script(script_file);

    // Initialize signals
    top->clk       = 0;
    top->ce        = 0;
    top->reset_n   = 0;
    top->host_cs_n = 1;
    top->host_rd_n = 1;
    top->host_wr_n = 1;
    top->host_addr = 0;
    top->host_din  = 0;
    top->rom_data  = 0;

    // Reset sequence
    printf("Applying reset (%d cycles)...\n", RESET_CYCLES);
    for (int i = 0; i < RESET_CYCLES; i++)
        tick(s);

    top->reset_n = 1;
    printf("Reset released\n");

    // Post-reset stabilization
    for (int i = 0; i < 10; i++)
        tick(s);

    // Execute script
    printf("Executing script...\n");
    int errors = execute_script(s, cmds);

    // Write WAV output
    write_wav(wav_file, s.audio_samples, sample_rate);

    // Cleanup
    if (tfp) {
        tfp->close();
    }
    top->final();

    printf("Simulation complete. %zu audio frames captured.\n",
           s.audio_samples.size() / 2);
    if (enable_vcd)
        printf("VCD: %s\n", vcd_file);

    return errors < 255 ? errors : 255;
}
