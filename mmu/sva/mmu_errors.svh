// Included inside mmu_sva after mmu_watch_model.svh.
// Error payload checks share the watched translations with the data suite.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      `ifdef AS_MMU_IC_ERRORS
        if (!flush_i) begin
          as_ic_error_response_request: assert (!icache_rsp_o || icache_req_i);
          if (icache_req_i && icache_req_vaddr == watch_vaddr[0]) begin
            if (!enable_translation_i)
              as_ic_error_bypass_response: assert (icache_rsp_o);
            if (icache_rsp_o) begin
              as_ic_error_valid: assert (ic_rsp_exp_valid == watch_expected_fault[0]);
              if (watch_expected_fault[0]) begin
                as_ic_error_cause: assert (ic_rsp_exp_cause == watch_expected_cause[0]);
                if (watch_expected_cause[0] == riscv::INSTR_PAGE_FAULT)
                  as_ic_pte_page_fault: assert (ic_rsp_exp_valid &&
                                               ic_rsp_exp_cause == riscv::INSTR_PAGE_FAULT);
                if (CVA6Cfg.TvalEn)
                  as_ic_error_tval: assert (ic_rsp_exp_tval == CVA6Cfg.XLEN'(icache_req_vaddr));
              end else begin
                as_ic_error_success_paddr: assert (icache_rsp_paddr == watch_expected_paddr[0]);
              end
            end
          end
        end
      `endif

      `ifdef AS_MMU_LS_ERRORS
        if (!flush_i && !watch_flush_q) begin
          as_ls_error_response_request: assert (!lsu_valid_o || watch_lsu_req_q);
          if (watch_lsu_req_q && watch_lsu_hit_q)
            as_ls_error_hit_response: assert (lsu_valid_o);
          if (watch_lsu_req_q && watch_lsu_vaddr_q == watch_vaddr[1]) begin
            if (watch_pre_ex_q.valid || !watch_lsu_translation_q)
              as_ls_error_bypass_response: assert (lsu_valid_o);
            if (lsu_valid_o) begin
              as_ls_error_valid: assert (ls_rsp_exp_valid ==
                                         (watch_pre_ex_q.valid || watch_expected_fault[1]));
              if (watch_pre_ex_q.valid) begin
                as_ls_error_prior_cause: assert (ls_rsp_exp_cause == watch_pre_ex_q.cause);
                as_ls_error_prior_metadata: assert (
                    {lsu_exception_o.tval2, ls_rsp_exp_tinst, ls_rsp_exp_gva} ==
                    {watch_pre_ex_q.tval2, watch_pre_ex_q.tinst, watch_pre_ex_q.gva});
              end else if (watch_expected_fault[1]) begin
                as_ls_error_cause: assert (ls_rsp_exp_cause == watch_expected_cause[1]);
              end else begin
                as_ls_error_success_paddr: assert (lsu_paddr_o == watch_expected_paddr[1]);
                if (CVA6Cfg.CheriPresent && !watch_lsu_store_q)
                  as_ls_error_strip_tag: assert (lsu_allow_tag_o ==
                      (watch_lsu_cap_q && !watch_expected_strip[1]));
              end
              if (CVA6Cfg.TvalEn && (watch_pre_ex_q.valid || watch_expected_fault[1]))
                as_ls_error_tval: assert (ls_rsp_exp_tval ==
                    {{CVA6Cfg.XLEN-CVA6Cfg.VLEN{watch_lsu_vaddr_q[CVA6Cfg.VLEN-1]}}, watch_lsu_vaddr_q});
            end
          end
        end
      `endif

      cp_error_cancelled_response: cover (dc_rsp_rvalid && watch_dc_killed);
      cp_error_concurrent_requests: cover (icache_req_i && lsu_req_i);
      `ifdef AS_MMU_IC_ERRORS
        cp_ic_error_bypass: cover (!flush_i && icache_req_i && icache_rsp_o &&
            icache_req_vaddr == watch_vaddr[0] && !enable_translation_i && !ic_rsp_exp_valid);
      `endif
      `ifdef AS_MMU_LS_ERRORS
        cp_ls_error_hit: cover (!flush_i && !watch_flush_q &&
            watch_lsu_req_q && watch_lsu_hit_q && lsu_valid_o &&
            watch_lsu_translation_q && !watch_pre_ex_q.valid &&
            watch_lsu_vaddr_q == watch_vaddr[1] &&
            ls_rsp_exp_valid == watch_expected_fault[1] &&
            (watch_expected_fault[1] ? ls_rsp_exp_cause == watch_expected_cause[1] :
                                      lsu_paddr_o == watch_expected_paddr[1]));
        cp_ls_error_previous_response_new_miss: cover (!flush_i && !watch_flush_q &&
            lsu_valid_o && watch_lsu_req_q && lsu_req_i &&
            !lsu_dtlb_hit_o && !pre_mmu_ex_i.valid &&
            !watch_lsu_response_matches_request);
        cp_ls_error_bypass: cover (!flush_i && !watch_flush_q && watch_lsu_req_q && lsu_valid_o &&
            watch_lsu_vaddr_q == watch_vaddr[1] && !watch_lsu_translation_q &&
            !watch_pre_ex_q.valid && !ls_rsp_exp_valid);
        cp_ls_error_prior: cover (!flush_i && !watch_flush_q && watch_lsu_req_q && lsu_valid_o &&
            watch_lsu_vaddr_q == watch_vaddr[1] && watch_pre_ex_q.valid &&
            ls_rsp_exp_valid && ls_rsp_exp_cause == watch_pre_ex_q.cause);
      `endif
    end
  end

  for (genvar kind = 0; kind <= 8; kind++) begin : gen_error_coverage
    always_ff @(posedge clk_i) begin
      if (rst_ni && !flush_i) begin
        `ifdef AS_MMU_IC_ERRORS
          if (kind < 8 && kind != 1) begin
            cp_ic_error_kind: cover (icache_req_i && icache_rsp_o &&
              icache_req_vaddr == watch_vaddr[0] && enable_translation_i &&
              watch_fault_kind[0] == kind && ic_rsp_exp_valid == watch_expected_fault[0] &&
              (watch_expected_fault[0] ? ic_rsp_exp_cause == watch_expected_cause[0] :
                                        icache_rsp_paddr == watch_expected_paddr[0]));
          end
        `endif
        `ifdef AS_MMU_LS_ERRORS
          if ((kind < 8 || CVA6Cfg.CheriPresent) && kind != 1) begin
            cp_ls_error_kind: cover (watch_lsu_req_q && lsu_valid_o && !watch_flush_q &&
              watch_lsu_vaddr_q == watch_vaddr[1] && watch_lsu_translation_q &&
              !watch_pre_ex_q.valid && watch_fault_kind[1] == kind &&
              ls_rsp_exp_valid == watch_expected_fault[1] &&
              (watch_expected_fault[1] ? ls_rsp_exp_cause == watch_expected_cause[1] :
                                        lsu_paddr_o == watch_expected_paddr[1]));
          end
        `endif
      end
    end
  end
