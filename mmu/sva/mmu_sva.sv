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
  
// Flush: When flush happend, there should be no valid translation, and no allow_tag_o signal.
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
  localparam VS2_N_OFFSET_W = OFFSET_WIDTH + VPN_W;
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
  logic [CVA6Cfg.DcacheIdWidth-1:0] dc_req_id_q;
  logic dc_rsp_id_matches_req;
  logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] dc_req_address_index;
  logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] dc_req_address_tag;
  logic [CVA6Cfg.XLEN-1:0] dc_rsp_rdata , dc_req_data_wdata;
  // Exception signals
  logic [CVA6Cfg.XLEN-1:0] ic_rsp_exp_cause, ic_rsp_exp_tval, ls_rsp_exp_cause, ls_rsp_exp_tval;
  logic [31:0] ic_rsp_exp_tinst, ls_rsp_exp_tinst;
  logic ic_rsp_exp_gva, ls_rsp_exp_gva;
  logic ic_rsp_exp_valid, ls_rsp_exp_valid;
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
  assign ls_req_paddr_offset      = ls_rsp_paddr[OFFSET_WIDTH-1:0];
  assign ls_req_vaddr_vpn2     = ls_req_vaddr[VPN_W*3+OFFSET_WIDTH-1:VPN_W*2+OFFSET_WIDTH];
  assign ls_req_vaddr_vpn1     = ls_req_vaddr[VPN_W*2+OFFSET_WIDTH-1:VPN_W*1+OFFSET_WIDTH];
  assign ls_req_vaddr_vpn0     = ls_req_vaddr[VPN_W*1+OFFSET_WIDTH-1:VPN_W*0+OFFSET_WIDTH];
  assign dc_rsp_gnt = req_port_i.data_gnt;
  assign dc_rsp_rvalid = req_port_i.data_rvalid;
  assign dc_rsp_rid = req_port_i.data_rid;
  assign dc_req_valid = req_port_o.data_req;
  assign dc_req_we = req_port_o.data_we;
  assign dc_req_id = req_port_o.data_id;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) dc_req_id_q <= '0;
    else if (dc_req_valid && dc_rsp_gnt) dc_req_id_q <= dc_req_id;
  end
  assign dc_rsp_id_matches_req = (dc_rsp_rid == dc_req_id_q);
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

  logic[63:0] dc_req_address;
  assign dc_req_address = {dc_req_address_tag,dc_req_address_index} >> 3;
  logic [23:0] past_valid;

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
  
  logic dc_req_pending; 
  always_ff @( posedge clk_i ) begin 
    if(!rst_ni) begin 
      dc_req_pending <= 1'b0;
    end else begin
      if (dc_req_valid && dc_rsp_gnt) begin
        dc_req_pending <= 1'b1;
      end else if (dc_req_pending && dc_rsp_rvalid) begin
        dc_req_pending <= 1'b0;
      end
  end end

  logic [9+12-1:0] s_ic_vaddr, s_ls_vaddr;
  logic [9+12-1:0] s_ic_vaddr_init, s_ls_vaddr_init;
  always_ff @( posedge clk_i ) begin 
    if(!rst_ni) begin 
      s_ic_vaddr <= s_ic_vaddr_init;
      s_ls_vaddr <= s_ls_vaddr_init;
    end 
  end

  logic [1:0] ic_ptw_s_cnt, ls_ptw_s_cnt; 
  pte_cva6_t pte_data_i;
  assign pte_data_i = pte_cva6_t'(dc_rsp_rdata);

  // Only work with coloring
  always_ff @( posedge clk_i ) begin 
    if (!rst_ni) begin 
      ic_ptw_s_cnt <= 0; 
      ls_ptw_s_cnt <= 0; 
    end else begin 
      if(dc_req_valid && dc_rsp_gnt && dc_req_address[1] && icache_req_i) begin// {pte.pnn, vpn}
        ic_ptw_s_cnt <= ic_ptw_s_cnt + 1;
      end else if (icache_req_i && icache_rsp_o) begin 
        ic_ptw_s_cnt <= 0; 
      end 
      if(dc_req_valid && dc_rsp_gnt && !dc_req_address[1] && lsu_req_i) begin 
        ls_ptw_s_cnt <= ls_ptw_s_cnt; 
      end else if (ls_ptw_s_cnt && lsu_valid_o) begin 
        ls_ptw_s_cnt <= 0; 
      end 
    end 
  end 

  logic dut_ptw_state_d_is_KILL_REQ, dut_ptw_state_d_is_WAIT_RVALID, dut_ptw_state_d_is_WAIT_GRANT; 
  // assign dut_ptw_state_d_is_KILL_REQ = dut.i_ptw.state_d == dut.i_ptw.KILL_REQ; 
  // assign dut_ptw_state_d_is_WAIT_RVALID = dut.i_ptw.state_d == dut.i_ptw.WAIT_RVALID; 
  // assign dut_ptw_state_d_is_WAIT_GRANT = dut.i_ptw.state_d == dut.i_ptw.WAIT_GRANT; 

// ASSUME: Evironment
// In this Environment, lets assume there is no g translation 
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin 
      // AM1: No hypervisor translation 
        assume (enable_translation_i == 1'b1);
        assume (enable_g_translation_i == 1'b0); 
        assume (en_ld_st_translation_i == 1'b1);
        assume (en_ld_st_g_translation_i == 1'b0);  
        // This harness uses an RVH-disabled configuration.  HFENCE.VVMA/GVMA
        // cannot be generated in that configuration, so keep those controls
        // inactive.  In particular, flush_tlb_vvma_i also selects vs_asid_i
        // for a DTLB lookup even when RVH is disabled.
        assume (!flush_tlb_vvma_i);
        assume (!flush_tlb_gvma_i);

      // AM2: No flush_tlb_i without flush_i
        assume (flush_i || !flush_tlb_i);  

      // AM3: Icache req has to be high until response is valid
      // icache_req_i && ! (icache_rsp_o || flush_asserted) |=> icache_req_i
        assume (icache_req_i || 
                !$past(icache_req_i && !(icache_areq_o.fetch_valid || flush_asserted), 1));
      // AM4: icache_req_vaddr should be stable 
        assume ( $past(!icache_req_i) || (!icache_req_i || (icache_req_vaddr == $past(icache_req_vaddr))));
      // AM5: lsu_req_i will be high until response 
        assume (lsu_req_i || !$past(lsu_req_i && !lsu_valid_o &&
                                    !lsu_dtlb_hit_o, 1));
      // AM6: The LSU request address remains stable until the translation completes.
        assume ($past(!lsu_req_i) ||
                !lsu_req_i || (lsu_vaddr_i == $past(lsu_vaddr_i)));
      // AM7: The translation context belongs to the same outstanding LSU request.
        assume ($past(!lsu_req_i) || !lsu_req_i ||
                ({lsu_is_store_i, lsu_is_cap_i, ld_st_v_i,
                  asid_i, vs_asid_i, vmid_i,
                  satp_ppn_i, vsatp_ppn_i, hgatp_ppn_i, pre_mmu_ex_i} ==
                 $past({lsu_is_store_i, lsu_is_cap_i, ld_st_v_i,
                        asid_i, vs_asid_i, vmid_i,
                        satp_ppn_i, vsatp_ppn_i, hgatp_ppn_i, pre_mmu_ex_i})));
      // Zero-wait dcache model in terms of the PTW handshake: grant a request
      // immediately, then return its matching response in WAIT_RVALID on the
      // following clock.  A same-edge rvalid is too early for the PTW FSM.
      // OVERCONSTRAINTS
        // if(past_valid[1]) begin        
        //   assume (!$past(dc_req_valid && dc_rsp_gnt) == (dc_rsp_rvalid));
        // end
        // assume (!$past(rst_ni) || !$past(dc_req_valid && dc_rsp_gnt) ||
        //         (dc_rsp_rvalid && dc_rsp_id_matches_req));
      // VPN of icache and ls can be used to coloring
      `ifdef OAM_DATA_COLOR // AM8
        assume (icache_req_vaddr_vpn2[1] && icache_req_vaddr_vpn1[1] && icache_req_vaddr_vpn0[1]);
        assume (!ls_req_vaddr_vpn2[1] && !ls_req_vaddr_vpn1[1] && !ls_req_vaddr_vpn0[1]);
      `endif
      // DC model: 1 request at a time 
      // AM9: Only rsp valid when dc_req_pending: !dc_req_pending |-> !dc_rsp_rvalid  
        assume (dc_req_pending || !dc_rsp_rvalid);
      // Model
        if (dc_rsp_rvalid) begin
          assume (pte_data_i.ppn[CVA6Cfg.PPNW-1:0] == $past(dc_req_address[CVA6Cfg.PPNW-1:0]));
        end 
        // assume (!lsu_req_i || (lsu_vaddr_i[9+12-1:0] == s_ls_vaddr));
        // assume (!icache_req_i || (icache_req_vaddr[9+12-1:0] == s_ic_vaddr));
        // assume (s_ic_vaddr != s_ls_vaddr);
    end end


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

    // IC rsp end2end 
      `ifdef AS_IC_E2E_RSP_DATA_VLD // icache_rsp_o |-> icache_areq_o.paddr[39:0] == icache_req_vaddr[39:0]
      if(past_valid[1]) begin
        as_ic_e2e_rsp_data_vld: assert(!icache_rsp_o || ic_rsp_exp_valid || (icache_rsp_paddr[VS2_N_OFFSET_W-1:0] == icache_req_vaddr[VS2_N_OFFSET_W-1:0]));
      end
      `endif
      `ifdef AS_LS_E2E_RSP_DATA_VLD // lsu_valid_o |-> lsu_paddr_o[39:0] == lsu_vaddr_i[39:0]
      if(past_valid[1]) begin
        as_ls_e2e_rsp_data_vld: assert(!lsu_valid_o || ls_rsp_exp_valid || (lsu_paddr_o[VS2_N_OFFSET_W-1:0] == $past(lsu_vaddr_i[VS2_N_OFFSET_W-1:0]))); 
      end
      `endif

    // IC priority 
      `ifdef AS_ITLB_UPDATE_PRIORITY // ic_ls_priority_pending |-> !dut_dtlb_update_valid
        as_itlb_update_priority: assert (!ic_ls_priority_pending || !dut_dtlb_update_valid);
      `endif

    // IC RSP addr will always have coloring: 
      `ifdef AS_IC_E2E_RSP_DATA_COLOR
        //icache_rsp_o |-> icache_rsp_paddr[OFFSET_WIDTH+1] == 1 
        as_ic_e2e_rsp_data_color: assert (!icache_rsp_o || 
                ic_rsp_exp_valid || icache_rsp_paddr[OFFSET_WIDTH+1]);
      `endif

    // LS RSP addr will always have coloring: 
      `ifdef AS_LS_E2E_RSP_DATA_COLOR
        //lsu_valid_o |-> lsu_paddr_o[OFFSET_WIDTH+1] == 0 
        as_ls_e2e_rsp_data_color: assert (!lsu_valid_o || ls_rsp_exp_valid || !lsu_paddr_o[OFFSET_WIDTH+1]);
      `endif

      // DC req stay high until grant dc_req_valid && !dc_rsp_gnt |-> dc_req_valid
      `ifdef AS_DC_REQ_STABLE_UNTIL_GRANT
        as_dc_req_stable_until_grant: assert (dc_req_valid || !$past(dc_req_valid && !dc_rsp_gnt, 1));
      `endif 

      `ifdef AS_DC_REQ_DATA_STABLE_UNTIL_GRANT
        // assert (); // Stability of request    
      `endif 

      `ifdef AS_LSU_DTLB_HIT_IMPLY_VALID_RSP
        as_lsu_dtlb_hit_imply_valid_rsp: assert (!$past(lsu_req_i && lsu_dtlb_hit_o) || lsu_valid_o);
      `endif
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
