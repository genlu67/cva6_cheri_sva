// Independent PMP reference for the MMU assertions. Bounds are half-open byte
// ranges; the lowest entry overlapping any byte must cover the entire access.
module mmu_pmp_ref #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    // Grain is 2**(PMP_G+2) bytes. Address inputs are the raw stored registers,
    // before the mode-dependent CSR readback mask is applied.
    parameter int unsigned PMP_G = 0
) (
    input logic [CVA6Cfg.PLEN-1:0] addr_i,
    input logic [CVA6Cfg.PLEN:0] size_bytes_i,
    input riscv::pmp_access_t access_type_i,
    input riscv::priv_lvl_t priv_lvl_i,
    input riscv::pmpcfg_t [(CVA6Cfg.NrPMPEntries > 0 ? CVA6Cfg.NrPMPEntries : 1)-1:0]
        pmpcfg_i,
    input logic [(CVA6Cfg.NrPMPEntries > 0 ? CVA6Cfg.NrPMPEntries : 1)-1:0]
        [CVA6Cfg.PLEN-3:0] pmpaddr_i,
    output logic allow_o
);
  // An extra two bits preserve the exclusive physical-address limit, oversized
  // NAPOT encodings, and a carry from the access length without wrapping.
  localparam int unsigned BOUND_W = CVA6Cfg.PLEN + 2;
  localparam int unsigned PMP_ADDR_W = CVA6Cfg.PLEN - 2;
  localparam logic [BOUND_W-1:0] PHYS_LIMIT = BOUND_W'(1) << CVA6Cfg.PLEN;
  localparam logic [PMP_ADDR_W-1:0] TOR_ADDR_MASK = {PMP_ADDR_W{1'b1}} << PMP_G;
  localparam logic [PMP_ADDR_W-1:0] NAPOT_ADDR_ONES =
      (PMP_G >= 2) ? ~({PMP_ADDR_W{1'b1}} << (PMP_G-1)) : '0;
  logic [BOUND_W-1:0] access_lo, access_hi;
  logic [BOUND_W-1:0] entry_lo, entry_hi, napot_size;
  logic [PMP_ADDR_W-1:0] napot_addr;
  logic selected, trailing_ones;
  int unsigned napot_bits;

  always_comb begin
    access_lo = {2'b00, addr_i};
    access_hi = access_lo + {1'b0, size_bytes_i};
    allow_o = (CVA6Cfg.NrPMPEntries == 0) || (priv_lvl_i == riscv::PRIV_LVL_M);
    selected = 1'b0;
    entry_lo = '0;
    entry_hi = '0;
    napot_size = '0;
    napot_addr = '0;
    napot_bits = 3;
    trailing_ones = 1'b0;

    for (int unsigned entry = 0; entry < CVA6Cfg.NrPMPEntries; entry++) begin
      entry_lo = '0;
      entry_hi = '0;
      napot_size = '0;
      napot_addr = pmpaddr_i[entry] | NAPOT_ADDR_ONES;
      napot_bits = 3;
      trailing_ones = 1'b1;
      case (pmpcfg_i[entry].addr_mode)
        riscv::TOR: begin
          // The predecessor's mode does not change the TOR lower bound:
          // low G bits of both raw address registers are ignored.
          if (entry > 0)
            entry_lo = {2'b00, (pmpaddr_i[entry-1] & TOR_ADDR_MASK), 2'b00};
          entry_hi = {2'b00, (pmpaddr_i[entry] & TOR_ADDR_MASK), 2'b00};
        end
        riscv::NA4: begin
          if (PMP_G == 0) begin
            entry_lo = {2'b00, pmpaddr_i[entry], 2'b00};
            entry_hi = entry_lo + BOUND_W'(4);
          end
        end
        riscv::NAPOT: begin
          // At G=1 no NAPOT bits are forced; raw bit zero distinguishes
          // eight-byte from larger regions. At G>=2, force bits [G-2:0].
          for (int unsigned bit_idx = 0; bit_idx < CVA6Cfg.PLEN - 2; bit_idx++) begin
            if (trailing_ones && napot_addr[bit_idx]) napot_bits++;
            else trailing_ones = 1'b0;
          end
          napot_size = BOUND_W'(1) << napot_bits;
          entry_lo = {2'b00, napot_addr, 2'b00} & ~(napot_size - BOUND_W'(1));
          entry_hi = entry_lo + napot_size;
        end
        default: ;  // OFF entries describe an empty range.
      endcase

      if (!selected && (entry_lo < entry_hi) &&
          (access_lo < entry_hi) && (entry_lo < access_hi)) begin
        selected = 1'b1;
        allow_o = (entry_lo <= access_lo) && (access_hi <= entry_hi) &&
                  (((priv_lvl_i == riscv::PRIV_LVL_M) && !pmpcfg_i[entry].locked) ||
                   ((pmpcfg_i[entry].access_type & access_type_i) == access_type_i));
      end
    end

    if ((size_bytes_i == '0) || (access_hi > PHYS_LIMIT)) allow_o = 1'b0;
  end
endmodule
