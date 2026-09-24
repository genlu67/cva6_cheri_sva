// Preserve the original standalone define as an instruction-only error suite.
`ifdef AS_IC_PTE_PAGE_FAULT
  `ifndef AS_MMU_ERRORS
    `define AS_MMU_ERRORS
  `endif
  `ifndef AS_MMU_IC_ERRORS
    `define AS_MMU_IC_ERRORS
  `endif
`endif
// Legacy color switches select the same full-address watched checks.
`ifdef AS_IC_E2E_RSP_DATA_COLOR
  `ifndef AS_IC_E2E_RSP_DATA_VLD
    `define AS_IC_E2E_RSP_DATA_VLD
  `endif
`endif
`ifdef AS_LS_E2E_RSP_DATA_COLOR
  `ifndef AS_LS_E2E_RSP_DATA_VLD
    `define AS_LS_E2E_RSP_DATA_VLD
  `endif
`endif
// Select endpoint coverage; the assumption environment is always included.
`ifdef AS_MMU_ERRORS
  `define MMU_ENDPOINT_CHECKS
`endif
`ifdef AS_IC_E2E_RSP_DATA_VLD
  `ifndef MMU_ENDPOINT_CHECKS
    `define MMU_ENDPOINT_CHECKS
  `endif
`endif
`ifdef AS_LS_E2E_RSP_DATA_VLD
  `ifndef MMU_ENDPOINT_CHECKS
    `define MMU_ENDPOINT_CHECKS
  `endif
`endif
`ifdef AS_IC_E2E_RSP_FAULT_VLD
  `ifndef MMU_ENDPOINT_CHECKS
    `define MMU_ENDPOINT_CHECKS
  `endif
`endif
`ifdef AS_LS_E2E_RSP_FAULT_VLD
  `ifndef MMU_ENDPOINT_CHECKS
    `define MMU_ENDPOINT_CHECKS
  `endif
`endif
`ifdef AS_MMU_ERRORS
  `ifndef AS_MMU_IC_ERRORS
    `ifndef AS_MMU_LS_ERRORS
      `define AS_MMU_IC_ERRORS
      `define AS_MMU_LS_ERRORS
    `endif
  `endif
`endif
module mmu_sva
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg        = config_pkg::cva6_cfg_empty,
    parameter type                   icache_areq_t  = logic,
    parameter type                   icache_arsp_t  = logic,
    parameter type                   icache_dreq_t  = logic,
    parameter type                   icache_drsp_t  = logic,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic,
    parameter type                   exception_t    = logic,
    parameter int unsigned           HYP_EXT        = 0

) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic enable_translation_i,
    input logic enable_g_translation_i,
    input logic en_ld_st_translation_i,  // enable virtual memory translation for load/stores
    input logic en_ld_st_g_translation_i,  // enable G-Stage translation for load/stores
    // IF interface
    input icache_arsp_t icache_areq_i,
    input         icache_areq_t icache_areq_o,
    // LSU interface
    // this is a more minimalistic interface because the actual addressing logic is handled
    // in the LSU as we distinguish load and stores, what we do here is simple address translation
    input exception_t pre_mmu_ex_i,
    input logic lsu_req_i,  // request address translation
    input logic [CVA6Cfg.VLEN-1:0] lsu_vaddr_i,  // virtual address in
    input logic [31:0] lsu_tinst_i,  // transformed instruction in
    input logic lsu_is_store_i,  // the translation is requested by a store
    input logic lsu_is_cap_i,  // the data has the capability tag set
    input         logic csr_hs_ld_st_inst_o,  // hyp load store instruction
    // if we need to walk the page table we can't grant in the same cycle
    // Cycle 0
    input         logic lsu_dtlb_hit_o,  // sent in same cycle as the request if translation hits in DTLB
    input         logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,  // ppn (send same cycle as hit)
    // Cycle 1
    input         logic lsu_valid_o,  // translation is valid
    input         logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,  // translated address
    input         logic lsu_allow_tag_o,  // If clear, strip tag from result capability, happens when PTE.CR = PTE.CRM = PTE.CRG = 0;

    input         exception_t lsu_exception_o,  // address translation threw an exception
    // General control signals
    input riscv::priv_lvl_t priv_lvl_i,
    input logic v_i,
    input riscv::priv_lvl_t ld_st_priv_lvl_i,
    input logic ld_st_v_i,
    input logic sum_i,
    input logic vs_sum_i,
    input logic mxr_i,
    input logic vmxr_i,
    input logic hlvx_inst_i,
    input logic hs_ld_st_inst_i,
    input logic cap_ucrg_i,
    // input logic flag_mprv_i,
    input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i,

    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i,

    input logic flush_tlb_i,
    input logic flush_tlb_vvma_i,
    input logic flush_tlb_gvma_i,

    // Performance counters
    input         logic itlb_miss_o,
    input         logic dtlb_miss_o,
    // PTW memory interface
    input dcache_req_o_t req_port_i,
    input         dcache_req_i_t req_port_o,

    // Internal DUT observations supplied explicitly by the formal wrapper.
    input logic dut_itlb_update_valid,
    input logic dut_dtlb_update_valid,
    input logic dut_shared_tlb_update_valid,
    input logic dut_itlb_access,
    input logic dut_itlb_hit,
    input logic dut_dtlb_access,
    input logic dut_dtlb_hit,
    // ITLB is index 0, DTLB index 1. Single-stage refill metadata.
    input logic [1:0][CVA6Cfg.VpnLen-1:0] dut_tlb_update_vpn,
    input logic [1:0][CVA6Cfg.ASID_WIDTH-1:0] dut_tlb_update_asid,
    input logic [1:0][CVA6Cfg.PtLevels-2:0] dut_tlb_update_is_page,
    input logic [1:0] dut_tlb_update_napot,
    input logic [1:0] dut_tlb_update_global,
    input logic [1:0] dut_tlb_hit_global,
    input logic dut_ptw_pte_valid,
    input logic [CVA6Cfg.XLEN-1:0] dut_ptw_pte_data,
    input logic [CVA6Cfg.PtLevels-2:0] dut_ptw_level,
    input logic dut_ptw_is_instr,
    input logic dut_ptw_access_allowed,

    // PMP

    input riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0]                   pmpcfg_i,
    input logic           [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_i
);
  localparam type pte_cva6_t = struct packed {
    logic n;
    logic [1:0] res_hi;
    logic cw;  // capability write
    logic crg;  // capability read generation
    logic [4:0] reserved;
    logic [CVA6Cfg.PPNW-1:0] ppn;  // PPN length for
    logic [1:0] rsw;
    logic d;
    logic a;
    logic g;
    logic u;
    logic x;
    logic w;
    logic r;
    logic v;
  };
  
// Combined pipeline/TLB flush indication used by the legacy control checks.
  logic flush_asserted;
  assign flush_asserted = flush_i && flush_tlb_i;
                          // flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i || 
                          // (asid_to_be_flushed_i != '0) || (vmid_to_be_flushed_i != '0) || 
                          // (vaddr_to_be_flushed_i != '0) || (gpaddr_to_be_flushed_i != '0); 
  logic ic_trans_pending, ls_trans_pending;
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin 
      ic_trans_pending <= 1'b0;
      ls_trans_pending <= 1'b0;
    end else begin
      if (icache_areq_i.fetch_req) begin
        ic_trans_pending <= 1'b1;
      end else if (ic_trans_pending && 
                  ((icache_areq_o.fetch_valid) || 
                  flush_asserted)) begin // translation is valid and ready, or flush happened
        ic_trans_pending <= 1'b0;
      end
      if (lsu_req_i) begin
        ls_trans_pending <= 1'b1;
      end else if (ls_trans_pending && lsu_valid_o) begin
        ls_trans_pending <= 1'b0; 
      end
    end end 


// FORMAL debug enhancement: 
  localparam OFFSET_WIDTH = 12;
  localparam int unsigned DCACHE_ID_WIDTH = CVA6Cfg.DcacheIdWidth;
  localparam VPN_W = 9;
  logic icache_rsp_o, icache_req_i; 
  logic [CVA6Cfg.VLEN-1:0] icache_req_vaddr;
  logic [CVA6Cfg.PLEN-1:0] icache_rsp_paddr;
  logic [OFFSET_WIDTH-1:0] icache_req_vaddr_offset, icache_rsp_paddr_offset;
  logic [VPN_W-1:0] icache_req_vaddr_vpn2, icache_req_vaddr_vpn1, icache_req_vaddr_vpn0;
  logic [CVA6Cfg.VLEN-1:0] ls_req_vaddr; 
  logic [CVA6Cfg.PLEN-1:0] ls_rsp_paddr; 
  logic [OFFSET_WIDTH-1:0] ls_req_vaddr_offset, ls_rsp_paddr_offset; 
  logic [VPN_W-1:0] ls_req_vaddr_vpn2, ls_req_vaddr_vpn1, ls_req_vaddr_vpn0; 
  logic dc_rsp_gnt, dc_rsp_rvalid;
  logic [CVA6Cfg.DcacheIdWidth-1:0] dc_rsp_rid;
  logic dc_req_valid, dc_req_we;
  logic [CVA6Cfg.DcacheIdWidth-1:0] dc_req_id;
  logic dc_rsp_id_matches_req;
  logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] dc_req_address_index;
  logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] dc_req_address_tag;
  logic [CVA6Cfg.XLEN-1:0] dc_rsp_rdata , dc_req_data_wdata;
  // Exception signals
  logic [CVA6Cfg.XLEN-1:0] ic_rsp_exp_cause, ic_rsp_exp_tval, ls_rsp_exp_cause, ls_rsp_exp_tval;
  logic [31:0] ic_rsp_exp_tinst, ls_rsp_exp_tinst;
  logic ic_rsp_exp_gva, ls_rsp_exp_gva;
  logic ic_rsp_exp_valid, ls_rsp_exp_valid;

  logic dut_shared_tlb_hit;

  assign icache_rsp_o = icache_areq_o.fetch_valid;
  assign icache_req_i = icache_areq_i.fetch_req;
  assign icache_rsp_paddr = icache_areq_o.fetch_paddr;
  assign icache_req_vaddr = icache_areq_i.fetch_vaddr; 
  assign icache_req_vaddr_offset = icache_req_vaddr[OFFSET_WIDTH-1:0];
  assign icache_rsp_paddr_offset = icache_rsp_paddr[OFFSET_WIDTH-1:0];
  assign icache_req_vaddr_vpn2 = icache_req_vaddr[VPN_W*3+OFFSET_WIDTH-1:VPN_W*2+OFFSET_WIDTH];
  assign icache_req_vaddr_vpn1 = icache_req_vaddr[VPN_W*2+OFFSET_WIDTH-1:VPN_W*1+OFFSET_WIDTH];
  assign icache_req_vaddr_vpn0 = icache_req_vaddr[VPN_W*1+OFFSET_WIDTH-1:VPN_W*0+OFFSET_WIDTH];
  assign ls_req_vaddr     = lsu_vaddr_i; 
  assign ls_rsp_paddr     = lsu_paddr_o;
  assign ls_req_vaddr_offset      = ls_req_vaddr[OFFSET_WIDTH-1:0]; 
  assign ls_rsp_paddr_offset      = ls_rsp_paddr[OFFSET_WIDTH-1:0];
  assign ls_req_vaddr_vpn2     = ls_req_vaddr[VPN_W*3+OFFSET_WIDTH-1:VPN_W*2+OFFSET_WIDTH];
  assign ls_req_vaddr_vpn1     = ls_req_vaddr[VPN_W*2+OFFSET_WIDTH-1:VPN_W*1+OFFSET_WIDTH];
  assign ls_req_vaddr_vpn0     = ls_req_vaddr[VPN_W*1+OFFSET_WIDTH-1:VPN_W*0+OFFSET_WIDTH];
  assign dc_rsp_gnt = req_port_i.data_gnt;
  assign dc_rsp_rvalid = req_port_i.data_rvalid;
  assign dc_rsp_rid = req_port_i.data_rid;
  assign dc_req_valid = req_port_o.data_req;
  assign dc_req_we = req_port_o.data_we;
  assign dc_req_id = req_port_o.data_id;
  assign dc_req_address_index = req_port_o.address_index;
  assign dc_req_address_tag = req_port_o.address_tag;
  assign dc_rsp_rdata = req_port_i.data_rdata;
  assign ic_rsp_exp_cause = icache_areq_o.fetch_exception.cause;
  assign ic_rsp_exp_tval = icache_areq_o.fetch_exception.tval;
  assign ic_rsp_exp_tinst = icache_areq_o.fetch_exception.tinst;
  assign ic_rsp_exp_gva = icache_areq_o.fetch_exception.gva;
  assign ic_rsp_exp_valid = icache_areq_o.fetch_exception.valid;
  assign ls_rsp_exp_cause = lsu_exception_o.cause;
  assign ls_rsp_exp_tval = lsu_exception_o.tval;
  assign ls_rsp_exp_tinst = lsu_exception_o.tinst;
  assign ls_rsp_exp_gva = lsu_exception_o.gva;
  assign ls_rsp_exp_valid = lsu_exception_o.valid;
  assign dut_shared_tlb_hit = mmu_wrapper.dut.shared_tlb_hit;

  logic [23:0] past_valid;

  // Every property suite uses this one interface and watched-memory model.
  `include "mmu_watch_model.svh"
  `ifdef AS_MMU_ERRORS
    `include "mmu_errors.svh"
  `endif

  assign dc_rsp_id_matches_req = (dc_rsp_rid == dc_id_q);

  logic ic_ls_priority_pending, ic_ls_appear_same_cycle, ic_ls_not_in_prev_cycle; 
  assign ic_ls_appear_same_cycle = (icache_req_i && lsu_req_i) && ic_ls_not_in_prev_cycle;
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      ic_ls_priority_pending <= 1'b0;
      ic_ls_not_in_prev_cycle <= 1'b0;
    end else begin
      ic_ls_not_in_prev_cycle <= !icache_req_i && !lsu_req_i;
      if (icache_req_i && ic_ls_not_in_prev_cycle) begin
        ic_ls_priority_pending <= 1'b1;
      end else if (ic_ls_priority_pending && (dut_itlb_update_valid)) begin
        ic_ls_priority_pending <= 1'b0;
      end
  end end
  
  logic ic_s_vaddr_is_flushed_tlb, ls_s_vaddr_is_flushed_tlb;
  logic watched_ic_access, watched_ls_access;
  logic watched_flush, watched_flush_all_asids_q;
  logic [1:0] watched_tlb_refill;

  // Only translated accesses consume the check. The LSU hit output also
  // means "ready" during bypass, so bypass is not a TLB lookup here.
  assign watched_ic_access = dut_itlb_access &&
      (enable_translation_i || enable_g_translation_i) &&
      (icache_req_vaddr == s_vaddr_to_be_flushed_tlb) &&
      ((v_i ? vs_asid_i : asid_i) == s_asid_to_be_flushed_tlb);
  assign watched_ls_access = dut_dtlb_access &&
      (en_ld_st_translation_i || en_ld_st_g_translation_i) &&
      (lsu_vaddr_i == s_vaddr_to_be_flushed_tlb) &&
      (((ld_st_v_i || flush_tlb_vvma_i) ? vs_asid_i : asid_i) ==
       s_asid_to_be_flushed_tlb);

  // SFENCE addresses select pages, not individual bytes. ASID-specific
  // flushes preserve global mappings; remember that exception separately.
  assign watched_flush = flush_tlb_i &&
      ((s_vaddr_to_be_flushed_tlb[CVA6Cfg.VpnLen+11:12] ==
        vaddr_to_be_flushed_i[CVA6Cfg.VpnLen+11:12]) ||
       vaddr_to_be_flushed_i == '0) &&
      ((s_asid_to_be_flushed_tlb == asid_to_be_flushed_i) ||
       asid_to_be_flushed_i == '0);

  function automatic logic refill_covers_watched_page(
      input logic [CVA6Cfg.VpnLen-1:0] vpn,
      input logic [CVA6Cfg.PtLevels-2:0] is_page,
      input logic is_napot);
    logic [CVA6Cfg.VpnLen-1:0] mask;
    mask = '1;
    // is_page[0] is the root leaf (1 GiB for Sv39), [1] is 2 MiB.
    for (int level = 0; level < CVA6Cfg.PtLevels-1; level++)
      if (is_page[level])
        mask &= {CVA6Cfg.VpnLen{1'b1}} <<
                ((CVA6Cfg.PtLevels-1-level) * (CVA6Cfg.VpnLen/CVA6Cfg.PtLevels));
    if (CVA6Cfg.SvnapotEn && is_napot) mask &= {CVA6Cfg.VpnLen{1'b1}} << 4;
    return (vpn & mask) == (s_vaddr_to_be_flushed_tlb[CVA6Cfg.VpnLen+11:12] & mask);
  endfunction

  // Observe an accepted refill, not just any PTW result. TLB flush wins
  // over update, and these TLBs suppress updates when the lookup hits.
  // Refills for other pages/ASIDs must not release the watched obligation.
  always_comb begin
    watched_tlb_refill = '0;
    for (int tlb = 0; tlb < 2; tlb++) begin
      watched_tlb_refill[tlb] = !flush_tlb_i &&
          (tlb == 0 ? (dut_itlb_update_valid && !dut_itlb_hit) :
                      (dut_dtlb_update_valid && !dut_dtlb_hit)) &&
          (dut_tlb_update_global[tlb] ||
           dut_tlb_update_asid[tlb] == s_asid_to_be_flushed_tlb) &&
          refill_covers_watched_page(dut_tlb_update_vpn[tlb],
                                    dut_tlb_update_is_page[tlb],
                                    dut_tlb_update_napot[tlb]);
    end
  end

  // A flush removes old mappings. A later covering refill can make the
  // first exact-address lookup hit, so it ends that TLB's miss obligation.
  // Refill validity/PTE faults are checked by the separate endpoint suite.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ic_s_vaddr_is_flushed_tlb <= '0;
      ls_s_vaddr_is_flushed_tlb <= '0;
      watched_flush_all_asids_q <= '0;
    end else begin
      if (watched_flush) begin
        ic_s_vaddr_is_flushed_tlb <= '1;
        ls_s_vaddr_is_flushed_tlb <= '1;
        watched_flush_all_asids_q <= (asid_to_be_flushed_i == '0);
      end else begin
        if (watched_ic_access || watched_tlb_refill[0])
          ic_s_vaddr_is_flushed_tlb <= '0;
        if (watched_ls_access || watched_tlb_refill[1])
          ls_s_vaddr_is_flushed_tlb <= '0;
      end
    end
  end

  localparam DELAY = 10;
// Safety assertion
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      past_valid <= 24'b0;
    end else begin 
      past_valid <= {past_valid[22:0], 1'b1};
      // !ic_trans_pending && !icache_req_i |-> !icache_areq_o.fetch_valid
      // Prove that without any pending translation, the icache_areq_o.fetch_valid should not be high
    // Control signal end2end 
    `ifdef AS_IC_RSP_VLD
      as_ic_rsp_vld: assert((ic_trans_pending || icache_req_i) || !icache_rsp_o);
    `endif 

    // offset signal end2end
    `ifdef AS_IC_OFFSET_VLD // icache_rsp_o |-> icache_areq_o.paddr[11:0] == icache_req_vaddr[11:0]
      as_ic_offset_vld:  assert(!icache_rsp_o || (icache_rsp_paddr_offset == icache_req_vaddr_offset));
    `endif
    
    // LSU rsp end2end
      `ifdef AS_LS_RSP_VLD // !lsu_req_i |-> !lsu_valid_o || flush_i
      if(past_valid[1]) begin
        as_ls_rsp_vld: assert($past(lsu_req_i) || !lsu_valid_o);
      end
      `endif

    // Fault agreement and successful-response PA are independently selectable.
    // PA is defined only when both the reference and DUT report success.
      if (!flush_i && icache_req_i && icache_rsp_o &&
          icache_req_vaddr == watch_vaddr[0]) begin
        `ifdef AS_IC_E2E_RSP_FAULT_VLD
          as_ic_e2e_rsp_fault_vld: assert (ic_rsp_exp_valid == watch_expected_fault[0]);
        `endif
        `ifdef AS_IC_E2E_RSP_DATA_VLD
          if (!watch_expected_fault[0] && !ic_rsp_exp_valid) begin
            as_ic_e2e_rsp_data_vld: assert (icache_rsp_paddr == watch_expected_paddr[0]);
            cp_ic_e2e_rsp_data: cover (enable_translation_i &&
                icache_rsp_paddr == watch_expected_paddr[0]);
          end
        `endif
      end
      if (!flush_i && !watch_flush_q && watch_lsu_req_q && lsu_valid_o &&
          watch_lsu_vaddr_q == watch_vaddr[1]) begin
        `ifdef AS_LS_E2E_RSP_FAULT_VLD
          as_ls_e2e_rsp_fault_vld: assert (
              ls_rsp_exp_valid == (watch_pre_ex_q.valid || watch_expected_fault[1]));
        `endif
        `ifdef AS_LS_E2E_RSP_DATA_VLD
          if (!watch_pre_ex_q.valid && !watch_expected_fault[1] && !ls_rsp_exp_valid) begin
            as_ls_e2e_rsp_data_vld: assert (lsu_paddr_o == watch_expected_paddr[1]);
            cp_ls_e2e_rsp_data: cover (watch_lsu_translation_q &&
                lsu_paddr_o == watch_expected_paddr[1]);
          end
        `endif
      end

    // IC priority 
      `ifdef AS_ITLB_UPDATE_PRIORITY // ic_ls_priority_pending |-> !dut_dtlb_update_valid
        as_itlb_update_priority: assert (!ic_ls_priority_pending || !dut_dtlb_update_valid);
      `endif

      // Check the single outstanding PTW read contract independently.
      `ifdef AS_WATCH_SINGLE_PENDING_READ
        if (dc_req_valid && dc_rsp_gnt)
          as_watch_single_pending_read: assert (!dc_req_pending || dc_rsp_rvalid);
      `endif

      // DC req stay high until grant dc_req_valid && !dc_rsp_gnt |-> dc_req_valid
      `ifdef AS_DC_REQ_STABLE_UNTIL_GRANT
        as_dc_req_stable_until_grant: assert (dc_req_valid || !$past(dc_req_valid && !dc_rsp_gnt, 1));
      `endif 

      `ifdef AS_DC_REQ_DATA_STABLE_UNTIL_GRANT
        // dc_rsp_gnt && !dc_rsp_rvalid |-> dc_rsp_rdata == $past(dc_req_data_wdata);
        assert (!(dc_rsp_gnt && !dc_rsp_rvalid) || dc_rsp_rdata == $past(dc_req_data_wdata)); // Stability of request    
      `endif 

      `ifdef AS_LSU_DTLB_HIT_IMPLY_VALID_RSP
        as_lsu_dtlb_hit_imply_valid_rsp: assert (!$past(lsu_req_i && lsu_dtlb_hit_o) || lsu_valid_o);
      `endif

      `ifdef AS_FLUSH_TLB_IMPLY_NO_HIT
        // The assertion samples the armed flag before the matching access
        // clears it via a nonblocking assignment above.
        if (ic_s_vaddr_is_flushed_tlb && watched_ic_access)
          as_first_ic_access_misses: assert (!dut_itlb_hit ||
              (!watched_flush_all_asids_q && dut_tlb_hit_global[0]));
        if (ls_s_vaddr_is_flushed_tlb && watched_ls_access)
          as_first_ls_access_misses: assert (!lsu_dtlb_hit_o ||
              (!watched_flush_all_asids_q && dut_tlb_hit_global[1]));
      `endif

    `ifndef MMU_ENDPOINT_CHECKS
    if(past_valid[DELAY]) begin
      cover ($past(rst_ni && dut_itlb_access && !flush_i && 
                    !dut_itlb_hit &&
                    !dut_dtlb_access,  DELAY) && 
             $past(dut_itlb_access && !flush_i && 
                    !dut_itlb_hit &&
                    dut_dtlb_access, DELAY - 1) && 
                    dut_shared_tlb_update_valid &&
                    dut_dtlb_update_valid);
      // cover (dut.i_ptw.shared_tlb_update_valid);
    end
    `endif
    end
  end
  // Interface 
  // `ifdef FORMAL
  mmu_live_sva live_sva (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .lsu_valid_o             (lsu_valid_o),
      .*
  );
  // `endif

endmodule
