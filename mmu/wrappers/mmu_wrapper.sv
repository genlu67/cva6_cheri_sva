// wrapper for cva6_mmu
module mmu_wrapper
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

) ();
    logic clk_i;
    logic flush_i;
    logic enable_translation_i;
    logic enable_g_translation_i;
    logic en_ld_st_translation_i;  // enable virtual memory translation for load/stores
    logic en_ld_st_g_translation_i;  // enable G-Stage translation for load/stores
    // IF interface
    icache_arsp_t icache_areq_i;
    icache_areq_t icache_areq_o; // Output
    // LSU interface
    // this is a more minimalistic interface because the actual addressing logic is handled
    // in the LSU as we distinguish load and stores; what we do here is simple address translation
    exception_t pre_mmu_ex_i;
    logic lsu_req_i;  // request address translation
    logic [CVA6Cfg.VLEN-1:0] lsu_vaddr_i;  // virtual address in
    logic [31:0] lsu_tinst_i;  // transformed instruction in
    logic lsu_is_store_i;  // the translation is requested by a store
    logic lsu_is_cap_i;  // the data has the capability tag set
    // Output
    logic      csr_hs_ld_st_inst_o;  // hyp load store instruction
    // if we need to walk the page table we can't grant in the same cycle
    // Cycle 0
    logic      lsu_dtlb_hit_o;  // sent in same cycle as the request if translation hits in DTLB
    logic      [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o;  // ppn (send same cycle as hit)
    // Cycle 1
    logic      lsu_valid_o;  // translation is valid
    logic      [CVA6Cfg.PLEN-1:0] lsu_paddr_o;  // translated address
    logic      lsu_allow_tag_o;  // If clear; strip tag from result capability; happens when PTE.CR = PTE.CRM = PTE.CRG = 0;

    exception_t   lsu_exception_o;  // address translation threw an exception
    // General control signals
    riscv::priv_lvl_t     priv_lvl_i;
    logic v_i;
    riscv::priv_lvl_t     ld_st_priv_lvl_i;
    logic ld_st_v_i;
    logic sum_i;
    logic vs_sum_i;
    logic mxr_i;
    logic vmxr_i;
    logic hlvx_inst_i;
    logic hs_ld_st_inst_i;
    logic cap_ucrg_i;
    // logic flag_mprv_i;
    logic [CVA6Cfg.PPNW-1:0] satp_ppn_i;
    logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i;
    logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i;

    logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i;
    logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i;
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i;
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i;
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i;
    logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i;
    logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i;

    logic flush_tlb_i;
    logic flush_tlb_vvma_i;
    logic flush_tlb_gvma_i;

    // Performance counters
    logic      itlb_miss_o;
    logic     dtlb_miss_o;
    // PTW memory interface
    dcache_req_o_t req_port_i;
    dcache_req_i_t        req_port_o;

    // PMP

    riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0]                   pmpcfg_i;
    logic           [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_i;


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
      .*
  );

  mmu_sva #(
      .CVA6Cfg             (CVA6Cfg),
      .icache_areq_t       (icache_areq_t),
      .icache_arsp_t       (icache_arsp_t),
      .icache_dreq_t       (icache_dreq_t),
      .icache_drsp_t       (icache_drsp_t),
      .dcache_req_i_t      (dcache_req_i_t),
      .dcache_req_o_t      (dcache_req_o_t),
      .exception_t         (exception_t),
      .HYP_EXT             (HYP_EXT)
  ) u_mmu_sva (
      .clk_i                        (clk_i),
      .rst_ni                       (rst_done),
      .dut_itlb_update_valid        (dut.update_itlb.valid),
      .dut_dtlb_update_valid        (dut.update_dtlb.valid),
      .dut_shared_tlb_update_valid  (dut.update_shared_tlb.valid),
      .dut_itlb_access              (dut.itlb_lu_access),
      .dut_itlb_hit                 (dut.itlb_lu_hit),
      .dut_dtlb_access              (dut.dtlb_lu_access),
      .*
  );

endmodule
