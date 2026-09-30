# -----------------------------------------------------------------------------
# RTL portfolio — build / regression / coverage flow (Verilator + Yosys)
#
#   make test               build and run every module with all SEEDS
#   make test MOD=crc       one module
#   make cov                test + coverage report (build/coverage.md, lcov)
#   make lint               verilator -Wall on the RTL only
#   make synth              yosys generic synthesis, cell statistics
#   make mutate             mutation testing (scripts/mutate.py)
#   make SEEDS="1 2 3 4 5"  change the regression seed list
# -----------------------------------------------------------------------------

MODULES := sync_fifo async_fifo rr_arbiter uart spi_master apb_regfile \
           axis_skid_buffer crc seq_divider fir_filter

MOD   ?= $(MODULES)
SEEDS ?= 1 2 3
BUILD := build

VERILATOR ?= verilator
YOSYS     ?= yosys
PYTHON    ?= python3

VFLAGS := --binary --timing --assert --coverage-line --coverage-toggle --coverage-user \
          --timescale 1ns/1ps -j 0 -Icommon \
          -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

rtl_srcs = $(sort $(wildcard modules/$(1)/rtl/*.sv))
tb_srcs  = common/tb_pkg.sv $(sort $(wildcard modules/$(1)/tb/*.sv))

.PHONY: all test cov lint synth mutate clean $(addprefix test-,$(MODULES)) \
        $(addprefix lint-,$(MODULES)) $(addprefix synth-,$(MODULES))

all: test

test: $(addprefix test-,$(MOD))

# ---- simulation --------------------------------------------------------------
define SIM_RULES
$(BUILD)/$(1)/Vtb_$(1): $(call rtl_srcs,$(1)) $(call tb_srcs,$(1))
	@mkdir -p $(BUILD)/$(1)
	@echo "[build] $(1)"
	@$(VERILATOR) $(VFLAGS) --top-module tb_$(1) -Mdir $(BUILD)/$(1)/obj \
	    -o ../Vtb_$(1) $$^ > $(BUILD)/$(1)/build.log 2>&1 \
	    || (cat $(BUILD)/$(1)/build.log; exit 1)

test-$(1): $(BUILD)/$(1)/Vtb_$(1)
	@rm -f $(BUILD)/$(1)/cov_*.dat $(BUILD)/$(1)/fcov_*.txt
	@for s in $(SEEDS); do \
	    ./$(BUILD)/$(1)/Vtb_$(1) +verilator+seed+$$$$s \
	        +verilator+coverage+file+$(BUILD)/$(1)/cov_$$$$s.dat \
	        +func_cov=$(BUILD)/$(1)/fcov_$$$$s.txt \
	        > $(BUILD)/$(1)/sim_$$$$s.log 2>&1; rc=$$$$?; \
	    if [ $$$$rc -ne 0 ] || ! grep -q "TEST PASSED" $(BUILD)/$(1)/sim_$$$$s.log; then \
	        cat $(BUILD)/$(1)/sim_$$$$s.log; echo "[FAIL] $(1) seed=$$$$s"; exit 1; fi; \
	    echo "[PASS] $(1) seed=$$$$s: $$$$(grep -o '[0-9]* checks' $(BUILD)/$(1)/sim_$$$$s.log | tail -1)"; \
	done

lint-$(1):
	@echo "[lint] $(1)"
	@$(VERILATOR) --lint-only --quiet -Wall --top-module $(1) $(call rtl_srcs,$(1))

synth-$(1):
	@mkdir -p $(BUILD)/$(1)
	@$(YOSYS) -q -p "read_verilog -sv $(call rtl_srcs,$(1)); synth -flatten -top $(1); \
	    tee -o $(BUILD)/$(1)/synth.txt stat" > $(BUILD)/$(1)/synth.log 2>&1 \
	    || (cat $(BUILD)/$(1)/synth.log; exit 1)
	@echo "[synth] $(1): $$$$(grep -m1 -E 'Number of cells|cells$$$$' $(BUILD)/$(1)/synth.txt | xargs)"
endef
$(foreach m,$(MODULES),$(eval $(call SIM_RULES,$(m))))

# ---- coverage ----------------------------------------------------------------
cov: test
	@$(PYTHON) scripts/coverage_report.py $(BUILD) $(MOD) --md $(BUILD)/coverage.md \
	    --info $(BUILD)/coverage.info
	@if command -v genhtml > /dev/null; then \
	    genhtml -q -o $(BUILD)/cov_html $(BUILD)/coverage.info && \
	    echo "HTML report: $(BUILD)/cov_html/index.html"; fi

lint:  $(addprefix lint-,$(MOD))
synth: $(addprefix synth-,$(MOD))

mutate:
	@$(PYTHON) scripts/mutate.py $(if $(filter command line,$(origin MOD)),$(MOD))

clean:
	rm -rf $(BUILD)
