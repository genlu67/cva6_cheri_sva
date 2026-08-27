module mmu_live_sva
(
    input logic clk_i,
    input logic rst_ni,
    input logic icache_req_i,
    input logic lsu_req_i,
    input logic ic_trans_pending,
    input logic icache_rsp_o,
    input logic lsu_valid_o,
    input logic flush_i,
    input logic flush_asserted, 
    input logic dc_rsp_gnt,
    input logic dc_rsp_rvalid,
    input logic dc_req_valid,
    input logic dc_req_we,
    input logic dc_rsp_id_matches_req
);


logic [23:0] past_valid;
logic lsu_rsp_or_flush;
assign lsu_rsp_or_flush = lsu_valid_o || flush_i;

  always @(posedge clk_i) begin
    if(!rst_ni) begin
      // Reset the past_valid register on reset
      past_valid <= 24'b0;
    end else begin 


      // !ic_trans_pending && !icache_req_i |-> !icache_areq_o.fetch_valid
      // Prove that without any pending translation, the icache_areq_o.fetch_valid should not be high

    // Control signal end2end 
      `ifdef AS_LIVE_IC_RSP_VLD // icache_req_i |-> s_eventually(icache_rsp_o || flush_asserted)
      if(icache_req_i) begin
        assert property (s_eventually(icache_rsp_o || flush_asserted));
      end
      `endif
      `ifdef AS_LIVE_BOUND_IC_RSP_VLD // icache_req_i |-> s_eventually(icache_rsp_o)
        past_valid <= {past_valid[22:0], 1'b1};
        if (rst_ni && past_valid[15]) begin
            assert (
            !$past(icache_req_i, 15) ||
            $past(icache_rsp_o, 15) || $past(icache_rsp_o, 14) || $past(icache_rsp_o, 13) ||
            $past(icache_rsp_o, 12) || $past(icache_rsp_o, 11) ||  $past(icache_rsp_o, 10) ||
            $past(icache_rsp_o, 9) || $past(icache_rsp_o, 8) || $past(icache_rsp_o, 7) ||
            $past(icache_rsp_o, 6) ||  $past(icache_rsp_o, 5) || $past(icache_rsp_o, 4) ||
            $past(icache_rsp_o, 3) || $past(icache_rsp_o, 2) || $past(icache_rsp_o, 1) ||
            icache_rsp_o
            );
        end 
      `endif

      `ifdef AS_LIVE_BOUND_LS_RSP_VLD // lsu_req_i |-> ##[0:23] (lsu_valid_o || flush_i)
        past_valid <= {past_valid[22:0], 1'b1};
        if (rst_ni && past_valid[23]) begin
          assert (
            !$past(lsu_req_i, 23) ||
            $past(lsu_rsp_or_flush, 23) || $past(lsu_rsp_or_flush, 22) ||
            $past(lsu_rsp_or_flush, 21) ||  $past(lsu_rsp_or_flush, 20) || $past(lsu_rsp_or_flush, 19) ||
            $past(lsu_rsp_or_flush, 18) ||  $past(lsu_rsp_or_flush, 17) || $past(lsu_rsp_or_flush, 16) ||
            $past(lsu_rsp_or_flush, 15) || $past(lsu_rsp_or_flush, 14) ||
            $past(lsu_rsp_or_flush, 13) || $past(lsu_rsp_or_flush, 12) ||
            $past(lsu_rsp_or_flush, 11) || $past(lsu_rsp_or_flush, 10) ||
            $past(lsu_rsp_or_flush,  9) || $past(lsu_rsp_or_flush,  8) ||
            $past(lsu_rsp_or_flush,  7) || $past(lsu_rsp_or_flush,  6) ||
            $past(lsu_rsp_or_flush,  5) || $past(lsu_rsp_or_flush,  4) ||
            $past(lsu_rsp_or_flush,  3) || $past(lsu_rsp_or_flush,  2) ||
            $past(lsu_rsp_or_flush,  1) || lsu_rsp_or_flush
          );
        end
      `endif
    end end
endmodule
