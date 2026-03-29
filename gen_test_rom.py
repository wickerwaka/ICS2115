#!/usr/bin/env python3
"""Wrapper — delegates to sim/gen_test_rom.py."""
import runpy, os, sys
sys.argv[0] = os.path.join(os.path.dirname(__file__), 'sim', 'gen_test_rom.py')
runpy.run_path(sys.argv[0], run_name='__main__')
