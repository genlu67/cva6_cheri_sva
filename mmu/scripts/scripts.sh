# cd /home/nguyen/project/cheri-cva6-default

export CVA6_REPO_DIR="$PWD"
export TARGET_CFG=cv64a6_imafdczcheri_sv39_hpdcache_wb
export HPDCACHE_DIR="$PWD/core/cache_subsystem/hpdcache"

SIMVIEW_RTL_ARGS=$(
    make -s --no-print-directory \
        target="$TARGET_CFG" \
        defines=DEBUG \
        spike-tandem= \
        rvfi-dii= \
        RISCV=/home/nguyen/project/cheri-cva6/tools/riscv-toolchain \
        SPIKE_INSTALL_DIR=/home/nguyen/project/cheri-cva6/tools/spike \
        VERILATOR_INSTALL_DIR=/home/nguyen/project/cheri-cva6/tools/verilator \
        --eval='print-simview-vars: ; @printf "%s " "$(ariane_pkg)" "$(src)" "$(list_incdir)"' \
        print-simview-vars 2>/dev/null
)

/home/nguyen/project/simview/build/simview \
    -waves "/home/nguyen/project/cheri-cva6-sva/mmu/sby/mmu_as_ic_e2e_rsp_data_vld/engine_0/trace.vcd" \
    --top mmu_fv_master \
    --single-unit \
    --timescale=1ns/1ns \
    --compat=all \
    +define+VERILATOR=1+PRELOAD=1+DEBUG \
    -f /home/nguyen/project/cheri-cva6-sva/mmu/sby/mmu_filelists.f \
    $SIMVIEW_RTL_ARGS