// The single assumption environment included by every mmu_sva property suite.
// The watched-memory model uses only MMU interface signals.
// Two arbitrary watched translations share an immutable, coherent memory.
// Other virtual addresses and other memory locations remain unconstrained.
  (* anyconst *) logic [1:0][CVA6Cfg.VLEN-1:0] watch_vaddr;
  (* anyconst *) pte_cva6_t [1:0][CVA6Cfg.PtLevels-1:0] watch_pte;
  // Independent symbolic lookup selected by the TLB-flush assertions.
  (* anyconst *) logic [CVA6Cfg.VLEN-1:0] s_vaddr_to_be_flushed_tlb;
  (* anyconst *) logic [CVA6Cfg.ASID_WIDTH-1:0] s_asid_to_be_flushed_tlb;
  logic [1:0][CVA6Cfg.PtLevels-1:0][CVA6Cfg.PLEN-1:0] pte_addr;
  logic [1:0][CVA6Cfg.PtLevels-1:0] watch_pmp_allow;
  logic [1:0] watch_expected_fault, watch_expected_strip;
  logic [1:0][CVA6Cfg.XLEN-1:0] watch_expected_cause;
  logic [1:0][CVA6Cfg.PLEN-1:0] watch_expected_paddr;
  logic [1:0][3:0] watch_fault_kind;

  logic dc_req_pending, watch_dc_killed;
  logic [CVA6Cfg.PLEN-1:0] dc_addr_q;
  logic [CVA6Cfg.DcacheIdWidth-1:0] dc_id_q;
  logic [CVA6Cfg.XLEN-1:0] watch_dc_pte;
  logic watch_lsu_req_q, watch_lsu_store_q, watch_lsu_cap_q, watch_lsu_hit_q;
  logic watch_lsu_sum_q, watch_lsu_mxr_q, watch_lsu_ucrg_q;
  logic watch_lsu_translation_q, watch_flush_q;
  logic [CVA6Cfg.VLEN-1:0] watch_lsu_vaddr_q;
  riscv::priv_lvl_t watch_lsu_priv_q;
  exception_t watch_pre_ex_q;
  logic watch_lsu_response_matches_request;

  // A pipelined response can belong to the preceding request while a new
  // request misses. Only completion of this request releases its miss hold.
  assign watch_lsu_response_matches_request = lsu_valid_o && watch_lsu_req_q &&
      ({lsu_vaddr_i, lsu_is_store_i, lsu_is_cap_i, pre_mmu_ex_i} ==
       {watch_lsu_vaddr_q, watch_lsu_store_q, watch_lsu_cap_q, watch_pre_ex_q});

  // Select the PTE's lane if the cache interface carries a capability word.
  assign watch_dc_pte = CVA6Cfg.XLEN'(req_port_i.data_rdata >>
      (8 * (dc_addr_q % ($bits(req_port_i.data_rdata) / 8))));

  for (genvar watched = 0; watched < 2; watched++) begin : gen_watch_translation
    for (genvar level = 0; level < CVA6Cfg.PtLevels; level++) begin : gen_pmp
      mmu_pmp_ref #(.CVA6Cfg(CVA6Cfg), .PMP_G(1)) i_pmp_ref (
          .addr_i(pte_addr[watched][level]),
          .size_bytes_i((CVA6Cfg.PLEN+1)'(CVA6Cfg.XLEN / 8)),
          .access_type_i(riscv::ACCESS_READ),
          .priv_lvl_i(riscv::PRIV_LVL_S),
          .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
          .allow_o(watch_pmp_allow[watched][level])
      );
    end
    mmu_translation_ref #(
        .CVA6Cfg(CVA6Cfg), .INSTR(watched == 0), .pte_cva6_t(pte_cva6_t)
    ) i_translation_ref (
        .vaddr_i(watch_vaddr[watched]), .root_ppn_i(satp_ppn_i),
        .translation_en_i(watched == 0 ? enable_translation_i : watch_lsu_translation_q),
        .priv_lvl_i(watched == 0 ? priv_lvl_i : watch_lsu_priv_q),
        .sum_i(watch_lsu_sum_q), .mxr_i(watch_lsu_mxr_q),
        .is_store_i(watched == 0 ? 1'b0 : watch_lsu_store_q),
        .is_cap_i(watched == 0 ? 1'b0 : watch_lsu_cap_q),
        .cap_ucrg_i(watch_lsu_ucrg_q),
        .pte_words_i(watch_pte[watched]), .pmp_allow_i(watch_pmp_allow[watched]),
        .pte_addr_o(pte_addr[watched]), .fault_o(watch_expected_fault[watched]),
        .cause_o(watch_expected_cause[watched]), .paddr_o(watch_expected_paddr[watched]),
        .strip_tag_o(watch_expected_strip[watched]), .fault_kind_o(watch_fault_kind[watched])
    );
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      dc_req_pending <= 1'b0;
      watch_dc_killed <= 1'b0;
      dc_addr_q <= '0;
      dc_id_q <= '0;
      watch_lsu_req_q <= 1'b0;
      watch_lsu_hit_q <= 1'b0;
      watch_lsu_vaddr_q <= '0;
      watch_lsu_store_q <= 1'b0;
      watch_lsu_cap_q <= 1'b0;
      watch_lsu_priv_q <= riscv::PRIV_LVL_S;
      watch_lsu_sum_q <= 1'b0;
      watch_lsu_mxr_q <= 1'b0;
      watch_lsu_ucrg_q <= 1'b0;
      watch_lsu_translation_q <= 1'b0;
      watch_pre_ex_q <= '0;
      watch_flush_q <= 1'b0;
    end else begin
      watch_lsu_req_q <= lsu_req_i;
      watch_lsu_hit_q <= lsu_dtlb_hit_o;
      watch_lsu_vaddr_q <= lsu_vaddr_i;
      watch_lsu_store_q <= lsu_is_store_i;
      watch_lsu_cap_q <= lsu_is_cap_i;
      watch_lsu_priv_q <= ld_st_priv_lvl_i;
      watch_lsu_sum_q <= sum_i;
      watch_lsu_mxr_q <= mxr_i;
      watch_lsu_ucrg_q <= cap_ucrg_i;
      watch_lsu_translation_q <= en_ld_st_translation_i;
      watch_pre_ex_q <= pre_mmu_ex_i;
      watch_flush_q <= flush_i;

      // A flush may abort a walk, but its outstanding cache response must drain.
      if (dc_rsp_rvalid) dc_req_pending <= 1'b0;
      if (flush_i || req_port_o.kill_req) watch_dc_killed <= 1'b1;
      if (dc_req_valid && dc_rsp_gnt) begin
        dc_req_pending <= 1'b1;
        watch_dc_killed <= flush_i;
        dc_addr_q <= {dc_req_address_tag, dc_req_address_index};
        dc_id_q <= dc_req_id;
      end
    end
  end

  // This suite models the normal, single-stage MMU, not RVFI-DII's address
  // range workaround. Additional configurations need their own harness.
  initial begin
    as_watch_configuration: assert (!CVA6Cfg.RVH && !CVA6Cfg.RVFI_DII &&
                                    CVA6Cfg.XLEN == 64 && CVA6Cfg.PtLevels == 3);
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Legal non-hypervisor inputs; no assumptions on exception outputs.
      assume (!enable_g_translation_i && !en_ld_st_g_translation_i);
      assume (!v_i && !ld_st_v_i && !hlvx_inst_i && !hs_ld_st_inst_i);
      assume (!flush_tlb_vvma_i && !flush_tlb_gvma_i);
      // CVA6's SFENCE.VMA controller asserts flush_ex with flush_tlb.
      assume (!flush_tlb_i || flush_i);
      assume (priv_lvl_i inside {riscv::PRIV_LVL_U, riscv::PRIV_LVL_S, riscv::PRIV_LVL_M});
      assume (ld_st_priv_lvl_i inside {riscv::PRIV_LVL_U, riscv::PRIV_LVL_S, riscv::PRIV_LVL_M});
      assume (!enable_translation_i || priv_lvl_i != riscv::PRIV_LVL_M);
      assume (!en_ld_st_translation_i || ld_st_priv_lvl_i != riscv::PRIV_LVL_M);
      // CVA6's CSR implementation does not expose NA4 configurations.
      for (int entry = 0; entry < CVA6Cfg.NrPMPEntries; entry++) begin
        assume (pmpcfg_i[entry].addr_mode != riscv::NA4);
        assume (!pmpcfg_i[entry].access_type[1] || pmpcfg_i[entry].access_type[0]);
        `ifdef MMU_ERRORS_PMP_NAPOT_ONLY
          // Explicit diagnostic subset; normal error tasks still check TOR.
          assume (pmpcfg_i[entry].addr_mode inside {riscv::OFF, riscv::NAPOT});
        `endif
      end
      // This integration suite assumes canonical translated requests. Bypass
      // addresses have no Sv39 sign-extension restriction.
      if (icache_req_i && enable_translation_i)
        assume (icache_req_vaddr[CVA6Cfg.VLEN-1:39] ==
                {(CVA6Cfg.VLEN-39){icache_req_vaddr[38]}});
      if (lsu_req_i && en_ld_st_translation_i)
        assume (lsu_vaddr_i[CVA6Cfg.VLEN-1:39] ==
                {(CVA6Cfg.VLEN-39){lsu_vaddr_i[38]}});
      if (past_valid[0]) begin
        // Some slang versions preserve anyconst only as an attribute. State
        // the memory/watch stability explicitly for those frontends as well.
        assume (watch_vaddr == $past(watch_vaddr));
        assume (watch_pte == $past(watch_pte));
        assume (s_vaddr_to_be_flushed_tlb == $past(s_vaddr_to_be_flushed_tlb));
        assume (s_asid_to_be_flushed_tlb == $past(s_asid_to_be_flushed_tlb));
        // Fixed tables/configuration make cached and freshly walked mappings
        // comparable. Permission/operation inputs may change between requests.
        assume ({satp_ppn_i, asid_i, pmpcfg_i, pmpaddr_i,
                enable_translation_i, en_ld_st_translation_i} == 
                $past({satp_ppn_i, asid_i, pmpcfg_i, pmpaddr_i,
                enable_translation_i, en_ld_st_translation_i}));
        // cva6_icache keeps fetch_req and its saved VA in KILL_ATRANS until
        // fetch_valid, even when a flush/kill discards the frontend result.
        if ($past(icache_req_i && !icache_rsp_o)) begin
          assume (icache_req_i);
          assume (icache_req_vaddr == $past(icache_req_vaddr));
        end
        // Privilege comes from the CSR block, not the I-cache request register.
        // Keep the existing context restriction only away from flush boundaries.
        if ($past(icache_req_i && !icache_rsp_o && !flush_i) && !flush_i)
          assume (priv_lvl_i == $past(priv_lvl_i));
        // A pre-MMU exception is accepted without a TLB hit and responds on
        // the next cycle. Otherwise keep an unaccepted request until its
        // own completion, a hit, or flush; an older response is insufficient.
        if ($past(lsu_req_i && !pre_mmu_ex_i.valid && !lsu_dtlb_hit_o &&
                  !watch_lsu_response_matches_request && !flush_i) && !flush_i) begin
          assume (lsu_req_i);
          assume ({lsu_vaddr_i, lsu_is_store_i, lsu_is_cap_i, pre_mmu_ex_i} ==
                  $past({lsu_vaddr_i, lsu_is_store_i, lsu_is_cap_i, pre_mmu_ex_i}));
        end
        // CSR permission controls also belong to a hit's following response
        // cycle. Address and operation may advance with the LSU pipeline.
        if ($past(lsu_req_i && !flush_i) && !flush_i)
          assume ({ld_st_priv_lvl_i, sum_i, mxr_i, cap_ucrg_i} == 
                  $past({ld_st_priv_lvl_i, sum_i, mxr_i, cap_ucrg_i}));
      end

      // Response data belongs to the granted request, even with arbitrary
      // latency or cancellation. No address coloring or VPN->PPN identity.
      if (dc_rsp_rvalid) assume (dc_req_pending && dc_rsp_id_matches_req);

      // wt_dcache_ctrl completes a killed read in the kill cycle. Ordinary
      // reads retain arbitrary latency; flush alone is not a cache kill.
      if (CVA6Cfg.DCacheType == config_pkg::WT &&
          dc_req_pending && req_port_o.kill_req)
        am_watch_wt_kill_response: assume (dc_rsp_rvalid);

      as_watch_ptw_read_only: assert (!dc_req_valid || !dc_req_we);

      for (int watch_a = 0; watch_a < 2; watch_a++) begin
        for (int level_a = 0; level_a < CVA6Cfg.PtLevels; level_a++) begin
          // WT kill responses acknowledge cancellation; their data is unspecified.
          if (dc_rsp_rvalid &&
              !(CVA6Cfg.DCacheType == config_pkg::WT && req_port_o.kill_req) &&
              dc_addr_q == pte_addr[watch_a][level_a])
            assume (watch_dc_pte == watch_pte[watch_a][level_a]);
          // Check each unordered pair once; aliases share one memory cell.
          for (int watch_b = 0; watch_b < 2; watch_b++) begin
            for (int level_b = 0; level_b < CVA6Cfg.PtLevels; level_b++) begin
              if (((watch_b > watch_a) ||
                   ((watch_b == watch_a) && (level_b > level_a))) &&
                  pte_addr[watch_a][level_a] == pte_addr[watch_b][level_b])
                assume (watch_pte[watch_a][level_a] == watch_pte[watch_b][level_b]);
            end
          end
        end
      end

    end
  end
