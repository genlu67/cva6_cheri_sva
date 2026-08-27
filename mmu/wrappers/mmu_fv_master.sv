// formal top for mmu_fv_master at upstream master e4184b66 and its one-hunk
// descendant, common harness for the F10 before/ after comparison.
// Same as ptw_fv.sv except the reproduced types, which are localparam type
// inside modules and so cannot be imported, they must track the revision.
module mmu_fv_master
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(
        cva6_config_pkg::cva6_cfg
    ),
    parameter int unsigned N = (CVA6Cfg.NrPMPEntries > 0 ? CVA6Cfg.NrPMPEntries : 1),
    localparam int unsigned HYP_EXT = 0,
    parameter type exception_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] cause;  // cause of exception
      logic [CVA6Cfg.XLEN-1:0] tval;  // additional information of causing exception (e.g.: instruction causing it),
      // address of LD/ST fault
      logic [CVA6Cfg.GPLEN-1:0] tval2;  // additional information when the causing exception in a guest exception
      logic [31:0] tinst;  // transformed instruction information
      logic gva;  // signals when a guest virtual address is written to tval
      logic valid;
    },
    localparam type dcache_req_i_t = struct packed {
      logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
      logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
      logic [CVA6Cfg.XLEN-1:0]               data_wdata;
      logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
      logic                              data_req;
      logic                              data_we;
      logic [(CVA6Cfg.XLEN/8)-1:0]           data_be;
      logic [1:0]                        data_size;
      logic [CVA6Cfg.DcacheIdWidth-1:0]      data_id;
      logic                              kill_req;
      logic                              tag_valid;
      logic [7:0]                        cbo_op;         // cbo_t = logic [7:0], cva6.sv:172
    },  // cva6.sv:203

    localparam type dcache_req_o_t = struct packed {
      logic                             data_gnt;
      logic                             data_rvalid;
      logic [CVA6Cfg.DcacheIdWidth-1:0]     data_rid;
      logic [CVA6Cfg.XLEN-1:0]              data_rdata;
      logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] data_ruser;
    },  // cva6.sv:218

    localparam type icache_areq_t = struct packed {
      logic                    fetch_valid;      // address translation valid
      logic [CVA6Cfg.PLEN-1:0] fetch_paddr;      // physical address in
      exception_t              fetch_exception;  // exception occurred during fetch
    },  // cva6.sv:56

    localparam type icache_arsp_t = struct packed {
      logic                    fetch_req;        // address translation request
      logic [CVA6Cfg.VLEN-1:0] fetch_vaddr;      // virtual address out
      exception_t              fetch_exception;  // exception occurred during fetch
    }, // cva6.sv:61

    localparam type icache_dreq_t = struct packed {
      logic                        req;      // we request a new word
      logic [CVA6Cfg.DIIIDLEN-1:0] dii_id;   // next requested DII ID in instruction stream
      logic                        kill_s1;  // kill the current request
      logic                        kill_s2;  // kill the last request
      logic                        spec;     // request is speculative
      logic [CVA6Cfg.VLEN-1:0]     vaddr;    // 1st cycle: 12 bit index is taken for lookup
    },
    localparam type icache_drsp_t = struct packed {
      logic                                ready;   // icache is ready
      logic                                valid;   // signals a valid read
      logic [CVA6Cfg.FETCH_WIDTH-1:0]      data;    // 2+ cycle out: tag
      logic [CVA6Cfg.FETCH_USER_WIDTH-1:0] user;    // User bits
      logic [CVA6Cfg.VLEN-1:0]             vaddr;   // virtual address out
      logic [CVA6Cfg.DIIIDLEN-1:0]         dii_id;  // First DII ID in the returned data
      exception_t                          ex;      // we've encountered an exception
    } // cva6.sv:68

) (
    input logic clk_i,
    input logic flush_i,
    input logic enable_translation_i,
    input logic enable_g_translation_i,
    input logic en_ld_st_translation_i,  // enable virtual memory translation for load/stores
    input logic en_ld_st_g_translation_i,  // enable G-Stage translation for load/stores
    // IF interface
    input icache_arsp_t icache_areq_i,
    input    icache_areq_t icache_areq_o,
    // LSU interface
    // this is a more minimalistic interface because the actual addressing logic is handled
    // in the LSU as we distinguish load and stores, what we do here is simple address translation
    input exception_t pre_mmu_ex_i,
    input logic lsu_req_i,  // request address translation
    input logic [CVA6Cfg.VLEN-1:0] lsu_vaddr_i,  // virtual address in
    input logic [31:0] lsu_tinst_i,  // transformed instruction in
    input logic lsu_is_store_i,  // the translation is requested by a store
    input logic lsu_is_cap_i,  // the data has the capability tag set
    input    logic csr_hs_ld_st_inst_o,  // hyp load store instruction
    // if we need to walk the page table we can't grant in the same cycle
    // Cycle 0
    input    logic lsu_dtlb_hit_o,  // sent in same cycle as the request if translation hits in DTLB
    input    logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,  // ppn (send same cycle as hit)
    // Cycle 1
    input    logic lsu_valid_o,  // translation is valid
    input    logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,  // translated address
    input    logic lsu_allow_tag_o,  // If clear, strip tag from result capability, happens when PTE.CR = PTE.CRM = PTE.CRG = 0;

    input    exception_t lsu_exception_o,  // address translation threw an exception
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
    input    logic itlb_miss_o,
    input     logic dtlb_miss_o,
    // PTW memory interface
    input dcache_req_o_t req_port_i,
    input     dcache_req_i_t req_port_o,

    // PMP

    input riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0]                   pmpcfg_i,
    input logic           [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_i
);


  // one-shot reset
  logic rst_done = 1'b0;
  always_ff @(posedge clk_i) rst_done <= 1'b1;

  // logic ptw_active, walking_instr, ptw_error, ptw_error_at_g_st, ptw_err_at_g_int_st;
  // logic ptw_access_exception, shared_tlb_miss;
  // logic [Cfg.VLEN-1:0] update_vaddr;
  // logic [Cfg.PLEN-1:0] bad_paddr;
  // logic [Cfg.GPLEN-1:0] bad_gpaddr;
  // dcache_req_i_t req_port_o;
  // tlb_update_cva6_t shared_tlb_update;

  // Keep the formal-top interface input-only, but do not connect DUT outputs
  // directly onto those input variables.  Private observation wires avoid
  // multiple drivers and ensure assumptions/assertions see the actual DUT.
  icache_areq_t dut_icache_areq_o;
  logic dut_csr_hs_ld_st_inst_o;
  logic dut_lsu_dtlb_hit_o;
  logic [CVA6Cfg.PPNW-1:0] dut_lsu_dtlb_ppn_o;
  logic dut_lsu_valid_o;
  logic [CVA6Cfg.PLEN-1:0] dut_lsu_paddr_o;
  logic dut_lsu_allow_tag_o;
  exception_t dut_lsu_exception_o;
  logic dut_itlb_miss_o;
  logic dut_dtlb_miss_o;
  dcache_req_i_t dut_req_port_o;
  // memory management, pte for cva6
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
  cva6_mmu #(
      .CVA6Cfg          (CVA6Cfg),
      .icache_areq_t       (icache_areq_t),
      .icache_arsp_t       (icache_arsp_t),
      .icache_dreq_t       (icache_dreq_t),
      .icache_drsp_t       (icache_drsp_t),
      .dcache_req_i_t      (dcache_req_i_t),
      .dcache_req_o_t      (dcache_req_o_t),
      .exception_t          (exception_t),
      .HYP_EXT          (HYP_EXT)
  ) dut (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_done),
      .icache_areq_o           (dut_icache_areq_o),
      .csr_hs_ld_st_inst_o     (dut_csr_hs_ld_st_inst_o),
      .lsu_dtlb_hit_o          (dut_lsu_dtlb_hit_o),
      .lsu_dtlb_ppn_o          (dut_lsu_dtlb_ppn_o),
      .lsu_valid_o             (dut_lsu_valid_o),
      .lsu_paddr_o             (dut_lsu_paddr_o),
      .lsu_allow_tag_o         (dut_lsu_allow_tag_o),
      .lsu_exception_o         (dut_lsu_exception_o),
      .itlb_miss_o             (dut_itlb_miss_o),
      .dtlb_miss_o             (dut_dtlb_miss_o),
      .req_port_o              (dut_req_port_o),
      .*
  );

  // Flush: When flush happend, there should be no valid translation, and no allow_tag_o signal.
  logic flush_asserted;
  assign flush_asserted = flush_i && flush_tlb_i;
                          // flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i || 
                          // (asid_to_be_flushed_i != '0) || (vmid_to_be_flushed_i != '0) || 
                          // (vaddr_to_be_flushed_i != '0) || (gpaddr_to_be_flushed_i != '0); 
  logic ic_trans_pending, ls_trans_pending;
  always_ff @(posedge clk_i) begin
    if(!rst_done) begin 
      ic_trans_pending <= 1'b0;
      ls_trans_pending <= 1'b0;
    end else begin
      if (icache_areq_i.fetch_req) begin
        ic_trans_pending <= 1'b1;
      end else if (ic_trans_pending && 
                  ((dut_icache_areq_o.fetch_valid) || 
                  flush_asserted)) begin // translation is valid and ready, or flush happened
        ic_trans_pending <= 1'b0;
      end
      if (lsu_req_i) begin
        ls_trans_pending <= 1'b1;
      end else if (ls_trans_pending && dut_lsu_valid_o) begin
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
  assign icache_rsp_o = dut_icache_areq_o.fetch_valid;
  assign icache_req_i = icache_areq_i.fetch_req;
  assign icache_rsp_paddr = dut_icache_areq_o.fetch_paddr;
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
  assign dc_req_valid = dut_req_port_o.data_req;
  assign dc_req_we = dut_req_port_o.data_we;
  assign dc_req_id = dut_req_port_o.data_id;
  always_ff @(posedge clk_i) begin
    if (!rst_done) dc_req_id_q <= '0;
    else if (dc_req_valid && dc_rsp_gnt) dc_req_id_q <= dc_req_id;
  end
  assign dc_rsp_id_matches_req = (dc_rsp_rid == dc_req_id_q);
  assign dc_req_address_index = dut_req_port_o.address_index;
  assign dc_req_address_tag = dut_req_port_o.address_tag;
  assign dc_rsp_rdata = req_port_i.data_rdata;
  assign ic_rsp_exp_cause = dut_icache_areq_o.fetch_exception.cause;
  assign ic_rsp_exp_tval = dut_icache_areq_o.fetch_exception.tval;
  assign ic_rsp_exp_tinst = dut_icache_areq_o.fetch_exception.tinst;
  assign ic_rsp_exp_gva = dut_icache_areq_o.fetch_exception.gva;
  assign ic_rsp_exp_valid = dut_icache_areq_o.fetch_exception.valid;
  assign ls_rsp_exp_cause = lsu_exception_o.cause;
  assign ls_rsp_exp_tval = lsu_exception_o.tval;
  assign ls_rsp_exp_tinst = lsu_exception_o.tinst;
  assign ls_rsp_exp_gva = lsu_exception_o.gva;
  assign ls_rsp_exp_valid = lsu_exception_o.valid;

  // DUT level 
  logic dut_itlb_update_valid, dut_dtlb_update_valid, dut_shared_tlb_update_valid;
  assign dut_itlb_update_valid = dut.update_itlb.valid;
  assign dut_dtlb_update_valid = dut.update_dtlb.valid;
  assign dut_shared_tlb_update_valid = dut.update_shared_tlb.valid;

  logic[63:0] dc_req_address;
  assign dc_req_address = {dc_req_address_tag,dc_req_address_index} >> 3;
  logic [23:0] past_valid;

  logic ic_ls_priority_pending, ic_ls_appear_same_cycle, ic_ls_not_in_prev_cycle; 
  assign ic_ls_appear_same_cycle = (icache_req_i && lsu_req_i) && ic_ls_not_in_prev_cycle;
  always_ff @(posedge clk_i) begin
    if(!rst_done) begin
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
    if(!rst_done) begin 
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
    if(!rst_done) begin 
      s_ic_vaddr <= s_ic_vaddr_init;
      s_ls_vaddr <= s_ls_vaddr_init;
    end 
  end

  logic [1:0] ic_ptw_s_cnt, ls_ptw_s_cnt; 
  pte_cva6_t pte_data_i;
  assign pte_data_i = pte_cva6_t'(dc_rsp_rdata);

  // Only work with coloring
  always_ff @( posedge clk_i ) begin 
    if (!rst_done) begin 
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
    if (rst_done) begin 
      assume (enable_translation_i == 1'b1);
      assume (enable_g_translation_i == 1'b0); 
      assume (en_ld_st_translation_i == 1'b1);
      assume (en_ld_st_g_translation_i == 1'b0);  
      assume (flush_i || !flush_tlb_i);  
      // This harness uses an RVH-disabled configuration.  HFENCE.VVMA/GVMA
      // cannot be generated in that configuration, so keep those controls
      // inactive.  In particular, flush_tlb_vvma_i also selects vs_asid_i
      // for a DTLB lookup even when RVH is disabled.
      assume (!flush_tlb_vvma_i);
      assume (!flush_tlb_gvma_i);

      // Icache req has to be high until response is valid
      // icache_req_i && ! (icache_rsp_o || flush_asserted) |=> icache_req_i
        assume (icache_req_i || 
                !$past(icache_req_i && !(dut_icache_areq_o.fetch_valid || flush_asserted), 1));
      // icache_req_vaddr should be stable 
        assume ( $past(!icache_req_i) || (!icache_req_i || (icache_req_vaddr == $past(icache_req_vaddr))));
      // Overconstraint: lsu_req_i will be high until response 
        assume (lsu_req_i || !$past(lsu_req_i && !dut_lsu_valid_o &&
                                    !dut_lsu_dtlb_hit_o, 1));
      // The LSU request address remains stable until the translation completes.
        assume ($past(!lsu_req_i) ||
                !lsu_req_i || (lsu_vaddr_i == $past(lsu_vaddr_i)));
      // The translation context belongs to the same outstanding LSU request.
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
        // assume (!$past(rst_done) || !$past(dc_req_valid && dc_rsp_gnt) ||
        //         (dc_rsp_rvalid && dc_rsp_id_matches_req));
      // VPN of icache and ls can be used to coloring
        assume (icache_req_vaddr_vpn2[1] && icache_req_vaddr_vpn1[1] && icache_req_vaddr_vpn0[0]);
        assume (!ls_req_vaddr_vpn2[1] && !ls_req_vaddr_vpn1[1] && !ls_req_vaddr_vpn0[1]);

      // DC model: 1 request at a time 
      // DC req stay high until grant dc_req_valid && !dc_rsp_gnt |-> dc_req_valid
        assume (dc_req_valid || !$past(dc_req_valid && !dc_rsp_gnt, 1));
      // Only rsp valid when dc_req_pending: !dc_req_pending |-> !dc_rsp_rvalid  
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
    if(!rst_done) begin
      past_valid <= 24'b0;
    end else begin 
      past_valid <= {past_valid[22:0], 1'b1};
      // !ic_trans_pending && !icache_req_i |-> !icache_areq_o.fetch_valid
      // Prove that without any pending translation, the icache_areq_o.fetch_valid should not be high
    // Control signal end2end 
      `ifdef AS_IC_RSP_VLD
      assert((ic_trans_pending || icache_req_i) || !icache_rsp_o);
      `endif 

    // offset signal end2end
      `ifdef AS_IC_OFFSET_VLD // icache_rsp_o |-> icache_areq_o.paddr[11:0] == icache_req_vaddr[11:0]
      assert(!icache_rsp_o || (icache_rsp_paddr_offset == icache_req_vaddr_offset));
      `endif
    
    // LSU rsp end2end
      `ifdef AS_LS_RSP_VLD // !lsu_req_i |-> !lsu_valid_o || flush_i
      if(past_valid[1]) begin
        assert($past(lsu_req_i) || !dut.lsu_valid_o);
      end
      `endif

    // IC rsp end2end 
      `ifdef AS_IC_E2E_RSP_DATA_VLD // icache_rsp_o |-> icache_areq_o.paddr[39:0] == icache_req_vaddr[39:0]
      if(past_valid[1]) begin
        assert(!icache_rsp_o || ic_rsp_exp_valid || (icache_rsp_paddr[VS2_N_OFFSET_W-1:0] == icache_req_vaddr[VS2_N_OFFSET_W-1:0]));
      end
      `endif
      `ifdef AS_LS_E2E_RSP_DATA_VLD // dut_lsu_valid_o |-> lsu_paddr_o[39:0] == lsu_vaddr_i[39:0]
      if(past_valid[1]) begin
        assert(!dut_lsu_valid_o || ls_rsp_exp_valid || (dut.lsu_paddr_o[VS2_N_OFFSET_W-1:0] == $past(lsu_vaddr_i[VS2_N_OFFSET_W-1:0]))); 
      end
      `endif

    // IC priority 
      `ifdef AS_ITLB_UPDATE_PRIORITY // ic_ls_priority_pending |-> !dut_dtlb_update_valid
        assert (!ic_ls_priority_pending || !dut_dtlb_update_valid);
      `endif

    // IC RSP addr will always have coloring: 
      `ifdef AS_IC_E2E_RSP_DATA_COLOR
        //icache_rsp_o |-> icache_rsp_paddr[OFFSET_WIDTH+1] == 1 
        assert (!icache_rsp_o || icache_rsp_paddr[OFFSET_WIDTH+1]);
      `endif

    // LS RSP addr will always have coloring: 
      `ifdef AS_LS_E2E_RSP_DATA_COLOR
        //lsu_valid_o |-> lsu_paddr_o[OFFSET_WIDTH+1] == 0 
        assert (!lsu_valid_o || !lsu_paddr_o[OFFSET_WIDTH+1]);
      `endif
    // 
    
    if(past_valid[DELAY]) begin
      cover ($past(rst_done && dut.i_shared_tlb.itlb_access_i && !flush_i && 
                    !dut.i_shared_tlb.itlb_hit_i &&
                    !dut.i_shared_tlb.dtlb_access_i,  DELAY) && 
             $past(dut.i_shared_tlb.itlb_access_i && !flush_i && 
                    !dut.i_shared_tlb.itlb_hit_i &&
                    dut.i_shared_tlb.dtlb_access_i, DELAY - 1) && 
                    dut.i_shared_tlb.shared_tlb_update_i.valid &&
                    dut.i_shared_tlb.dtlb_update_o.valid
                    && dut_dtlb_update_valid);
      // cover (dut.i_ptw.shared_tlb_update_valid);
    end
    end
  end
  // Interface 
  // `ifdef FORMAL
  mmu_live_sva live_sva (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_done),
      .lsu_valid_o             (dut_lsu_valid_o),
      .*
  );
  // `endif

endmodule
