REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

CVA_PATH ?= $(abspath $(REPO_ROOT)/../cheri-cva6-default)
TASK ?= prove_all_safety
SBY ?= sby
OPEN_WAVE ?= 1
TRACE ?=
ENGINE ?= engine_0
SIMVIEW ?= $(abspath $(REPO_ROOT)/../simview/build/simview)
TOOLS_PATH ?= $(abspath $(REPO_ROOT)/../cheri-cva6/tools)
TARGET_CFG ?= cv64a6_imafdczcheri_sv39_hpdcache_wb
VIEW_SCRIPT := $(REPO_ROOT)/mmu/scripts/scripts.sh

.PHONY: all formal view help

all: formal

formal:
	@test -f "$(CVA_PATH)/core/cva6_mmu/cva6_mmu.sv" || { \
		echo "error: CVA_PATH does not point to a CVA6 checkout: $(CVA_PATH)"; \
		exit 2; \
	}
	@formal_status=0; \
	cd "$(REPO_ROOT)/mmu" && \
		CVA_PATH="$(abspath $(CVA_PATH))" "$(SBY)" -f sby/mmu.sby "$(TASK)" || \
		formal_status=$$?; \
	if [ "$(OPEN_WAVE)" = "1" ]; then \
		CVA_PATH="$(abspath $(CVA_PATH))" \
		TASK="$(TASK)" \
		ENGINE="$(ENGINE)" \
		TRACE="$(TRACE)" \
		SIMVIEW="$(SIMVIEW)" \
		TOOLS_PATH="$(TOOLS_PATH)" \
		TARGET_CFG="$(TARGET_CFG)" \
		"$(VIEW_SCRIPT)" || \
			echo "warning: no waveform was opened"; \
	fi; \
	exit $$formal_status

view:
	@CVA_PATH="$(abspath $(CVA_PATH))" \
	TASK="$(TASK)" \
	ENGINE="$(ENGINE)" \
	TRACE="$(TRACE)" \
	SIMVIEW="$(SIMVIEW)" \
	TOOLS_PATH="$(TOOLS_PATH)" \
	TARGET_CFG="$(TARGET_CFG)" \
	"$(VIEW_SCRIPT)"

help:
	@echo "Run an MMU formal task:"
	@echo "  make formal TASK=<task> CVA_PATH=/path/to/cva6"
	@echo "  make formal TASK=<task> OPEN_WAVE=0"
	@echo
	@echo "Open a waveform:"
	@echo "  make view TRACE=/path/to/trace.vcd CVA_PATH=/path/to/cva6"
	@echo "  make view TASK=<task>"
	@echo
	@echo "Defaults:"
	@echo "  TASK=$(TASK)"
	@echo "  CVA_PATH=$(CVA_PATH)"
	@echo "  OPEN_WAVE=$(OPEN_WAVE)"
