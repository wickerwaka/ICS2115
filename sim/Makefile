VERILATOR   ?= verilator
HDL_DIR     := ../rtl
OBJ_DIR     := obj_dir
TOP_MODULE  := ics2115
PREFIX      := Vics2115

# Source order matters: package first, then modules, then top
HDL_SRCS := $(HDL_DIR)/ics2115_pkg.sv \
            $(HDL_DIR)/ics2115_tables.sv \
            $(HDL_DIR)/ics2115_osc.sv \
            $(HDL_DIR)/ics2115.sv

TB_SRC := ics2115_tb.cpp

VFLAGS := --cc --exe --trace \
          --top-module $(TOP_MODULE) \
          --prefix $(PREFIX) \
          --Mdir $(OBJ_DIR) \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL \
          -Wno-UNOPTFLAT -Wno-BLKSEQ \
          -Wno-LATCH -Wno-MULTIDRIVEN \
          -CFLAGS "-std=c++17 -O2"

.PHONY: all build run run-vcd run-vol-env run-vol-loop gen-multi-rom run-multi run-pan run-irq run-timer clean

all: build

build: $(HDL_SRCS) $(TB_SRC)
	$(VERILATOR) $(VFLAGS) $(HDL_SRCS) $(TB_SRC)
	$(MAKE) -C $(OBJ_DIR) -f $(PREFIX).mk

run: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test.script -wav output.wav -no-vcd

run-vcd: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test.script -wav output.wav -vcd trace.vcd

run-vol-env: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_vol_env.script -wav vol_env_output.wav -no-vcd

run-vol-loop: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_vol_loop.script -wav vol_loop_output.wav -no-vcd

gen-multi-rom:
	python3 gen_multi_rom.py

run-multi: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_multi.script -wav multi_output.wav -no-vcd

run-pan: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_pan.script -wav pan_output.wav -no-vcd

run-readback: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_readback.script -wav /dev/null -no-vcd

run-irq: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_irq.script -wav /dev/null -no-vcd

run-timer: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_timer.script -wav /dev/null -no-vcd

clean:
	rm -rf $(OBJ_DIR)
