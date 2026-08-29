# CVA6 CHERI MMU Verification Plan

## 1. Scope

Verify the MMU interfaces and behavior for:

- Instruction translation
- Load/store translation
- TLB hits and misses
- Page-table walks
- TODO: Coherency 
- Stage-1 translation
- Optional guest/stage-2 translation
- PMP/PMA checks
- SFENCE/TLB invalidation
- Flush and reset behavior
- Privilege and permission checks
- CHERI-related translation faults, if exposed by the MMU interface

The exact signal names and timing must be derived from the `cva6_mmu` RTL interface.

---
**ENV_1**: Only Address translation: 
Assumptions:
- enable_g_translation_i    == 0 
- enable_translation_i      == 1
- en_ld_st_translation_i    == 1 
- en_ld_st_g_translation_i  == 0
- lsu_tinst_i               == 31'b0
- satp_ppn_i                : stable 
- asid_i                    : stable ?
  
Checks: 
- csr_hs_ld_st_inst_o       == 0
- hypervisor lsu return exceptions: wrong privilege 
--- 
**ENV_2**: dcache data return - trackable life of transaction: 
Assumption: 
- dc_rsp within 1 cycle after dc_req
- dc_rsp_data == dc_req_addr >> 3
--- 

## 2. End to End Checks

### 2.0 Signals have not been handle: 
- icache_areq_i.fetch_exception 
- misaligned_ex_i
- lsu_tinst_i 
- priv_lvl_i
- v_i
- ld_st_priv_lvl_i
- ld_st_v_i
- sum_i
- vs_sum_i 
- mxr_i 
- vmxr_i 
- hlvx_inst_i
- hs_ld_st_inst_i
- asid_i
- vs_asid_i
- vmid_i
- asid_to_be_flushed_i
- vmid_to_be_flushed_i
- vaddr_to_be_flushed_i
- gpaddr_to_be_flushed_i
- req_port_o.cbo_op
- req_port_o.tag_valid
- req_port_o.kill_req
- req_port_o.data_wuser
- req_port_i.data_ruser


### 2.1 Data translation 

Verify that every accepted request contains a stable and valid set of attributes:

- Virtual address
- Access type: instruction, load, or store
- Privilege mode
- ASID
- VMID
- Translation mode
- Stage-1 enable
- Stage-2 enable
- SUM/MXR/VMXR/VSUM configuration
- Endianness configuration, if used
- Capability metadata, if present

Assumptions: 
1. IC req must be asserted until IC rsp vld  (vaddr must be stable)
2. LSU req must be asserted until DC rsp vld (vaddr must be stable)
3. [OVC] Data coloring: VPN of IC and LS req will always be different;
   - TODO: Should we always assume IC and LS VA is different ? 
4. [OVC] Fault coloring: if return PTE has fault 
4. [OVC] E2E data: 
   - MODEL:
    - Model: PTW, ITLB, Share_tlb: assume that vpn -> ppn maintain some invariants 
    - TODO: fix - The return of DC rsp is PTE, not just address, need to identify this
    - satp.ppn  << 12 + vpn[2] << 3 -> pte[2]
    - pte[2]    << 12 + vpn[1] << 3 -> pte[1] 
    - pte[1]    << 12 + vpn[0] << 3 -> pte[0]
    - pte[0] == PPN -> PA = PNN << 12 + VA[11:0]
    - what if DATA_rsp == ADDR_REQ >> 3 -> pte[2] == {satp.ppn, vpn[2]}
                                         - pte[1] == {satp.pnn, vpn[2], vpn[1]}
                                         - pte[0] == {satp.pnn, vp[2], vpn[1], vpn[0]}

Checks:
1. [IC] If there is no ic req -> no ic rsp 
2. [IC] Offset of rsp should be the same as offset of req 
3. [IC] E2E check: 
   - If No Exeception, Flush: PA == VA (due to AM 2.1.3)
4. [IC] If there is REQ |-> s_eventually RSP 
   - BOUND: REQ |-> ##[0:15] RSP 
5. [IC] Verify a life cycle of IC req: 
   - IC req pending: 
     - Use on DC request side, which picks which VPN is used 
     - Based on the PTE, determine wether any request is expected Address next
     - Based on the leaf or superpage PTE, determine what should be return to IC
     - Put overconstraint on PTE to do modelling 
6. [IC] Assess permission are appropriate 
7. [IC_LS] Rsp cannot get a faulty PPN:
   - Fault that propagate from PTW -> cache 
7. [LS] Verify a life cycle of LS req: 
   - LS req pending: 
     - Also use on DC req side, which picks which VPN is used
     - Based on the PTE, determine wether any request is expected Address next
     - Based on the leaf or superpage PTE, determine what should be return to IC
     - Put overconstraint on PTE to do modelling 
8. [LS] Assess permission are appropriate 

9.  [LS] If there is no ls req -> no ls rsp 
10. [LS] Offset of rsp should be the same as offset of req

11. [DC] Format and permission is correct: data_wdata, data_wuser, data_we, data_be, data_size, is 0 
12. [DC] The root should be correct: satp
13. [DC] Correct VPN should be choosen for each level 
14. [DC] Leaf PTE should return rsp to correct requester & terminate the walk 
15. [DC] Address for request should be correct 
16. [DC] Correct valid: Eg: No req after cancellation 

### 2.2 Exception
- [PF] HPTW: throwing exception - page fault exception 
- [AE] PMP: access exception 
- DTLB hit:  
  - [LS][ST]: If page is not writable, dirty flags not set, privilege violates -> page fault 
  - [LS][ST]: If PMP violates -> access fault
  - [LS][ST]: page fault > access fault 
  - [LS][LD]: If insufficient access -> page fault 
  - [LS][LD]: If PMP violated -> access fault 
- DTLB miss: 
  - PTW indicates page fault |-> corresponding (LD/ST) page fault signalled 
  - PMP indicates access fault -> laod access fault is indicated through address translation 
- [IC]: What should happend on IC_REQ_exp 
- Page Fault has higher priority to Access fault 
- [PF] Misalign super page result in page fault
- [PF] Invalid PTE generate page fault
- 
---

### 2.3 Flush and reset

Verify:
1. After flush, there should be
   - No itlb hit
   - No dtlb hit 
   - No Shared TLB hit
  For a given VA, vmid 
2. After flush, non relate entry should remain hit 

### 2.4 Performance checks
1. Flush should not impact other VA, ASID, VMID 

## 3. Permission and Privilege Checks

Verify all combinations of:

- M-mode
- S-mode
- U-mode
- VS-mode
- VU-mode
- Instruction access
- Read access
- Write access
- User and supervisor pages
- SUM disabled and enabled
- MXR disabled and enabled
- VMXR disabled and enabled
- VSUM disabled and enabled
- Read, write, and execute PTE permissions

Required checks:

- `SUM=0` prevents supervisor access to user pages where required.
- `SUM=1` permits only architecturally allowed accesses.
- `MXR=1` permits reads from executable pages where required.
- `MXR=0` does not permit execute-only pages to be read.
- Instruction fetches require execute permission.
- Stores require write permission.
- Loads require read permission or the applicable MXR rule.
- Invalid permission combinations generate page faults.
- Privilege checks are applied consistently on TLB hits and PTW results.

---
IMPORTANT: in verification of Privilege, this should be a seperate environment with constant CSR input 
- Since changing ID, Mode, CSR, required Flush and it will need complex modelling 
- We will assign this with variable instead -> verify each configuration and how its behave 
- The Transition MUST be verified differently
- 
## 4. PMP and PMA Verification

Verify:

- PMP checks are applied to the final physical address.
- PMP checks cover the complete access range.
- Accesses crossing PMP regions are handled correctly.
- Instruction, load, and store permissions are checked independently.
- Locked PMP entries cannot be modified incorrectly.
- TOR, NA4, and NAPOT regions are handled correctly if supported.
- PMP faults have the correct priority relative to page faults.
- PTW accesses use the correct PMP privilege and access type.
- PTW PMP failures are returned as the correct MMU exception.
- PMA restrictions are checked for memory type and access legality.

---

## 5. Address and Boundary Cases

Verify:

- Page offset preservation.
- Page-aligned and non-page-aligned addresses.
- Accesses crossing a page boundary.
- Accesses crossing a PMP boundary.
- Minimum and maximum physical addresses.
- Canonical-address checks.
- Sign extension of physical addresses.
- Superpage alignment.
- Misaligned accesses, if checked by the MMU.
- Instruction fetches crossing a page boundary.
- XLEN-specific address behavior.

---

## 6. CHERI-Specific Checks

If CHERI metadata is part of the MMU interface, verify:

- Capability tag propagation.
- Capability validity for translated accesses.
- Capability permission checks.
- Execute permission for instruction fetches.
- Load/store permission checks.
- Bounds checks for the complete access range.
- Sealed-capability behavior.
- Capability faults are not converted into page faults.
- Capability metadata is not lost during TLB refill or PTW operation.
- Flush and invalidation do not leave stale capability metadata.
- Physical-address translation does not incorrectly modify capability bounds or permissions.

If CHERI checks are implemented outside the MMU, document the boundary and verify that the MMU passes all required metadata unchanged.

---

## 7. Priority and Ordering

Define and verify the priority between:

1. Reset
2. Flush
3. SFENCE/TLB invalidation
4. PTW response
5. Cache response
6. New translation request
7. TLB response

Verify:

- A flush cannot be bypassed by an old response.
- A stale PTW response cannot refill an invalidated TLB entry.
- Fault responses are not overwritten by later requests.
- Requests and responses remain ordered as specified.
- No deadlock occurs when flush, cache backpressure, and PTW activity overlap.

---

## 8. Functional Coverage // Not in the scope 

Cover:

- TLB hit and miss
- Each supported page-table mode
- Each page-table level
- Base pages and superpages
- Stage-1 only
- Stage-2 only, if supported
- Two-stage translation
- Each privilege mode
- Instruction, load, and store accesses
- ASID match and mismatch
- VMID match and mismatch
- Global and non-global mappings
- SUM/MXR/VMXR/VSUM combinations
- All PTE permission combinations
- Page faults, access faults, guest-page faults, PMP faults, and CHERI faults
- SFENCE variants
- Flush during TLB hit
- Flush during PTW
- Flush during cache backpressure
- Reset during an outstanding request
- Requests crossing page, PMP, and capability bounds
- PTW cache errors
- Multiple back-to-back requests
- Maximum supported outstanding transactions

---