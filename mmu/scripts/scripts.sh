#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SVA_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

CVA_PATH=${CVA_PATH:-"$SVA_ROOT/../cheri-cva6-default"}
TASK=${TASK:-prove_all_safety}
ENGINE=${ENGINE:-engine_0}
TRACE=${TRACE:-${1:-}}
SIMVIEW=${SIMVIEW:-"$SVA_ROOT/../simview/build/simview"}
TOOLS_PATH=${TOOLS_PATH:-"$SVA_ROOT/../cheri-cva6/tools"}
TARGET_CFG=${TARGET_CFG:-cv64a6_imafdczcheri_sv39_hpdcache_wb}
FILELIST=${FILELIST:-"$SVA_ROOT/mmu/sby/mmu_filelists.f"}

if [[ ! -f "$CVA_PATH/core/cva6_mmu/cva6_mmu.sv" ]]; then
    echo "error: CVA_PATH does not point to a CVA6 checkout: $CVA_PATH" >&2
    exit 2
fi

if [[ ! -x "$SIMVIEW" ]]; then
    echo "error: simview executable was not found: $SIMVIEW" >&2
    exit 2
fi

if [[ -z "$TRACE" ]]; then
    trace_dir="$SVA_ROOT/mmu/sby/mmu_${TASK}/${ENGINE}"
    for candidate in "$trace_dir/trace.vcd" "$trace_dir/trace_induct.vcd"; do
        if [[ -f "$candidate" ]] && { [[ -z "$TRACE" ]] || [[ "$candidate" -nt "$TRACE" ]]; }; then
            TRACE=$candidate
        fi
    done
fi

if [[ -z "$TRACE" || ! -f "$TRACE" ]]; then
    echo "error: no VCD trace found for TASK=$TASK, ENGINE=$ENGINE" >&2
    echo "       specify one with TRACE=/path/to/trace.vcd" >&2
    exit 3
fi

trace_parent=$(cd -- "$(dirname -- "$TRACE")" && pwd)
TRACE="$trace_parent/$(basename -- "$TRACE")"

export CVA_PATH
export SVA_ROOT
export CVA6_REPO_DIR="$CVA_PATH"
export HPDCACHE_DIR="$CVA_PATH/core/cache_subsystem/hpdcache"

rtl_args=$(
    make -s --no-print-directory -C "$CVA_PATH" \
        target="$TARGET_CFG" \
        defines=DEBUG \
        spike-tandem= \
        rvfi-dii= \
        RISCV="$TOOLS_PATH/riscv-toolchain" \
        SPIKE_INSTALL_DIR="$TOOLS_PATH/spike" \
        VERILATOR_INSTALL_DIR="$TOOLS_PATH/verilator" \
        --eval='print-simview-vars: ; @printf "%s " "$(ariane_pkg)" "$(src)" "$(list_incdir)"' \
        print-simview-vars 2>/dev/null
)
read -r -a simview_rtl_args <<< "$rtl_args"

echo "Opening waveform: $TRACE"
exec "$SIMVIEW" \
    -waves "$TRACE" \
    --top mmu_wrapper \
    --single-unit \
    --timescale=1ns/1ns \
    --compat=all \
    +define+VERILATOR=1+PRELOAD=1+DEBUG \
    -F "$FILELIST" \
    "${simview_rtl_args[@]}"
