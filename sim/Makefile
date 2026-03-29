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

.PHONY: all build run run-vcd run-vol-env run-vol-loop gen-multi-rom run-multi run-pan run-multi-check run-pan-check run-irq run-timer run-s05-integration run-8bit run-ulaw run-bidir run-vol-irq run-pwrite-test run-mame-log run-all clean

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

run-multi-check: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_multi.script -wav multi_output.wav -no-vcd
	python3 analyze_wav.py multi_output.wav --min-peak 690

run-pan-check: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_pan.script -wav pan_output.wav -no-vcd
	python3 analyze_wav.py pan_output.wav --check-separation

run-readback: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_readback.script -wav /dev/null -no-vcd

run-irq: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_irq.script -wav /dev/null -no-vcd

run-timer: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_timer.script -wav /dev/null -no-vcd

run-s05-integration: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_s05_integration.script -wav /dev/null -no-vcd

run-8bit: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_8bit.script -wav 8bit_output.wav -no-vcd
	python3 analyze_wav.py 8bit_output.wav --min-peak 1

run-ulaw: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_ulaw.script -wav ulaw_output.wav -no-vcd
	python3 analyze_wav.py ulaw_output.wav --min-peak 1

run-bidir: build gen-multi-rom
	./$(OBJ_DIR)/$(PREFIX) -rom multi_test.rom -script test_bidir.script -wav bidir_output.wav -no-vcd

run-vol-irq: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_vol_irq.script -wav vol_irq_output.wav -no-vcd

run-pwrite-test: build
	./$(OBJ_DIR)/$(PREFIX) -rom test.rom -script test_port.script -wav /dev/null -no-vcd

run-mame-log: build
	@if [ -z "$(LOG)" ]; then echo "Usage: make run-mame-log LOG=<mame_csv> ROM=<rom_file>"; exit 1; fi
	@if [ -z "$(ROM)" ]; then echo "Usage: make run-mame-log LOG=<mame_csv> ROM=<rom_file>"; exit 1; fi
	python3 mame_log_to_script.py $(LOG) mame_converted.script
	./$(OBJ_DIR)/$(PREFIX) -rom $(ROM) -script mame_converted.script -wav /dev/null -no-vcd

run-all: build gen-multi-rom
	@echo "=== Running all tests ==="
	@passed=0; failed=0; total=0; \
	for target in run run-vol-env run-vol-loop run-multi-check run-pan-check run-readback run-irq run-timer run-s05-integration run-8bit run-ulaw run-bidir run-vol-irq run-pwrite-test; do \
	  total=$$((total + 1)); \
	  echo "--- $$target ---"; \
	  if $(MAKE) --no-print-directory $$target; then \
	    passed=$$((passed + 1)); \
	  else \
	    failed=$$((failed + 1)); \
	    echo "FAILED: $$target"; \
	  fi; \
	done; \
	echo "=== Results: $$passed/$$total passed, $$failed failed ==="; \
	test $$failed -eq 0

clean:
	rm -rf $(OBJ_DIR)
