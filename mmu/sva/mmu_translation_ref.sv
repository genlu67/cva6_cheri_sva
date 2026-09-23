// Architectural reference for a non-virtualized Sv39/Sv32 translation.
// The caller supplies stable page-table words and independently checks PMP
// for each returned PTE address. No DUT state or fault output is observed.
module mmu_translation_ref #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter bit INSTR = 1'b0,
    parameter type pte_cva6_t = logic
) (
    input logic [CVA6Cfg.VLEN-1:0] vaddr_i,
    input logic [CVA6Cfg.PPNW-1:0] root_ppn_i,
    input logic translation_en_i,
    input riscv::priv_lvl_t priv_lvl_i,
    input logic sum_i,
    input logic mxr_i,
    input logic is_store_i,
    input logic is_cap_i,
    input logic cap_ucrg_i,
    input logic [CVA6Cfg.PtLevels-1:0][CVA6Cfg.XLEN-1:0] pte_words_i,
    input logic [CVA6Cfg.PtLevels-1:0] pmp_allow_i,
    output logic [CVA6Cfg.PtLevels-1:0][CVA6Cfg.PLEN-1:0] pte_addr_o,
    output logic fault_o,
    output logic [CVA6Cfg.XLEN-1:0] cause_o,
    output logic [CVA6Cfg.PLEN-1:0] paddr_o,
    output logic strip_tag_o,
    // 0 success, 1 canonical, 2 PMP, 3 format, 4 nonleaf,
    // 5 permission/A/D, 6 alignment, 7 NAPOT, 8 CHERI.
    output logic [3:0] fault_kind_o
);
  localparam int VPN_BITS = CVA6Cfg.VpnLen / CVA6Cfg.PtLevels;
  localparam int PTE_SHIFT = $clog2(CVA6Cfg.XLEN / 8);
  localparam logic [CVA6Cfg.XLEN-1:0] PAGE_CAUSE =
      CVA6Cfg.XLEN'(INSTR ? riscv::INSTR_PAGE_FAULT : riscv::LOAD_PAGE_FAULT);

  logic [CVA6Cfg.PtLevels-1:0][CVA6Cfg.PPNW-1:0] ppn;
  logic [CVA6Cfg.PtLevels-1:0][VPN_BITS-1:0] vpn;
  logic done;
  logic canonical;
  // The caller supplies the CVA6 PTE layout, including extension fields.
  // Casting encoded Sv32 words zero-extends the absent extension fields.
  pte_cva6_t [CVA6Cfg.PtLevels-1:0] decoded_pte;
  pte_cva6_t word;
  logic leaf, bad_privilege, bad_permission, bad_alignment, cap_fault;
  logic [CVA6Cfg.PLEN-1:0] translated_addr;

  // Build the complete address chain even when an earlier word terminates
  // the walk. Words beyond that point do not affect the translation result.
  always_comb begin
    for (int level = 0; level < CVA6Cfg.PtLevels; level++) begin
      decoded_pte[level] = pte_cva6_t'(pte_words_i[level]);
      ppn[level] = decoded_pte[level].ppn;
      vpn[level] = VPN_BITS'(vaddr_i >>
          (12 + VPN_BITS * (CVA6Cfg.PtLevels - level - 1)));
      if (level == 0)
        pte_addr_o[level] = (CVA6Cfg.PLEN'(root_ppn_i) << 12) |
                            (CVA6Cfg.PLEN'(vpn[level]) << PTE_SHIFT);
      else
        pte_addr_o[level] = (CVA6Cfg.PLEN'(ppn[level-1]) << 12) |
                            (CVA6Cfg.PLEN'(vpn[level]) << PTE_SHIFT);
    end
  end

  always_comb begin
    fault_o = 1'b0;
    cause_o = '0;
    fault_kind_o = '0;
    paddr_o = CVA6Cfg.PLEN'(vaddr_i);
    strip_tag_o = 1'b0;
    done = !translation_en_i;
    word = '0;
    leaf = 1'b0;
    bad_privilege = 1'b0;
    bad_permission = 1'b0;
    bad_alignment = 1'b0;
    cap_fault = 1'b0;
    translated_addr = '0;

    canonical = 1'b1;
    for (int bit_idx = CVA6Cfg.SV; bit_idx < CVA6Cfg.VLEN; bit_idx++)
      canonical &= vaddr_i[bit_idx] == vaddr_i[CVA6Cfg.SV-1];

    if (!done && !canonical) begin
      fault_o = 1'b1;
      fault_kind_o = 4'd1;
      done = 1'b1;
    end

    for (int level = 0; level < CVA6Cfg.PtLevels; level++) begin
      if (!done) begin
        word = decoded_pte[level];
        leaf = word.r || word.x;
        // U pages never grant supervisor instruction fetch, even with SUM.
        bad_privilege = ((priv_lvl_i == riscv::PRIV_LVL_U) && !word.u) ||
            ((priv_lvl_i == riscv::PRIV_LVL_S) && word.u &&
             (INSTR || !sum_i));
        if (INSTR)
          bad_permission = !word.x;
        else if (is_store_i)
          bad_permission = !word.w;
        else
          bad_permission = !(word.r || (mxr_i && word.x));

        bad_alignment = 1'b0;
        for (int bit_idx = 0; bit_idx < CVA6Cfg.PPNW; bit_idx++) begin
          if (bit_idx < VPN_BITS * (CVA6Cfg.PtLevels - level - 1))
            bad_alignment |= ppn[level][bit_idx];
        end

        cap_fault = !INSTR && CVA6Cfg.CheriPresent && is_cap_i &&
            ((is_store_i && !word.cw) ||
             (!is_store_i && word.u && word.cw && (word.crg != cap_ucrg_i)));

        if (!pmp_allow_i[level]) begin
          // Failure of an implicit PTE read has the original access type.
          fault_o = 1'b1;
          fault_kind_o = 4'd2;
          done = 1'b1;
        end else if (!word.v || (!word.r && word.w) ||
                     ((CVA6Cfg.XLEN == 64) &&
                      // Reserved bits must be zero; CW/CRG require CHERI.
                      ((|word.res_hi) || (|word.reserved) ||
                       (!CVA6Cfg.CheriPresent && (word.cw || word.crg))))) begin
          fault_o = 1'b1;
          fault_kind_o = 4'd3;
          done = 1'b1;
        end else if (word.n &&
                     (!CVA6Cfg.SvnapotEn || !leaf ||
                      (level != CVA6Cfg.PtLevels-1) ||
                      (ppn[level][3:0] != 4'b1000))) begin
          fault_o = 1'b1;
          fault_kind_o = 4'd7;
          done = 1'b1;
        end else if (!leaf) begin
          if ((level == CVA6Cfg.PtLevels-1) || word.a || word.d || word.u ||
              (CVA6Cfg.CheriPresent && (word.cw || word.crg))) begin
            fault_o = 1'b1;
            fault_kind_o = 4'd4;
            done = 1'b1;
          end
        end else begin
          done = 1'b1;
          if (bad_privilege || bad_permission) begin
            fault_o = 1'b1;
            fault_kind_o = 4'd5;
          end else if (bad_alignment) begin
            fault_o = 1'b1;
            fault_kind_o = 4'd6;
          end else if (!word.a || (!INSTR && is_store_i && !word.d)) begin
            // CVA6 uses software-managed A/D bits (Svade behavior).
            fault_o = 1'b1;
            fault_kind_o = 4'd5;
          end else if (cap_fault) begin
            fault_o = 1'b1;
            fault_kind_o = 4'd8;
          end else begin
            // Walk order is root [0] to final PTE [PtLevels-1]. For an
            // ordinary Sv39 4 KiB leaf: PA = {PTE[2].PPN, VA[11:0]}.
            translated_addr = CVA6Cfg.PLEN'({word.ppn, vaddr_i[11:0]});
            // Earlier leaves are superpages: Sv39 level 0 uses VA[29:0]
            // (1 GiB), level 1 uses VA[20:0] (2 MiB). Sv32 level 0
            // uses VA[21:0] (4 MiB). Alignment was checked above.
            // A valid Svnapot leaf instead substitutes VA[15:12].
            for (int bit_idx = 12; bit_idx < CVA6Cfg.PLEN; bit_idx++) begin
              if ((bit_idx < 12 + VPN_BITS * (CVA6Cfg.PtLevels - level - 1)) ||
                  (word.n && (bit_idx < 16)))
                translated_addr[bit_idx] = 1'(CVA6Cfg.PLEN'(vaddr_i) >> bit_idx);
            end
            paddr_o = translated_addr;
            strip_tag_o = !INSTR && CVA6Cfg.CheriPresent && !word.cw;
          end
        end
      end
    end

    if (fault_o) begin
      if (fault_kind_o == 4'd2)
        cause_o = CVA6Cfg.XLEN'(INSTR ? riscv::INSTR_ACCESS_FAULT :
                  (is_store_i ? riscv::ST_ACCESS_FAULT : riscv::LD_ACCESS_FAULT));
      else
        cause_o = (!INSTR && is_store_i) ? CVA6Cfg.XLEN'(riscv::STORE_PAGE_FAULT) : PAGE_CAUSE;
    end
  end
endmodule
