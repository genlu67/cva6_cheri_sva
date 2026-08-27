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


### 2.1 End to end address translation 

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
3. Verify a life cycle of IC req: 
   - IC req pending: 
     - Use on DC request side, which picks which VPN is used 
     - Based on the PTE, determine wether any request is expected Address next
     - Based on the leaf or superpage PTE, determine what should be return to IC
     - Put overconstraint on PTE to do modelling 
4. Verify a life cycle of LS req: 
   - LS req pending: 
     - Also use on DC req side, which picks which VPN is used
     - Based on the PTE, determine wether any request is expected Address next
     - Based on the leaf or superpage PTE, determine what should be return to IC
     - Put overconstraint on PTE to do modelling 
5. E2E data overconstraint: 
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
4. [IC] If there is REQ |-> s_eventually RSP : TODO: should fail due to bug https://github.com/Capabilities-Limited/cheri-cva6/issues/131
   - BOUND: REQ |-> ##[0:15] RSP 
5. 
6. [LS] If there is no ls req -> no ls rsp 
7. [LS] Offset of rsp should be the same as offset of req

8. [DC] data_wdata, data_wuser, data_we, data_be, data_size, is 0 
9. [DC] 

### 2.2 Translation response interface

Verify that each accepted request eventually produces exactly one of:

- A translated physical address
- A page fault
- An access fault
- A guest-page fault
- A PMP/PMA fault
- A CHERI capability fault, if applicable
- A cancellation due to flush/reset, if cancellation is part of the interface contract

Checks:

1. Response valid is asserted only for a valid response.
2. Physical address and exception fields are stable while response-ready is low.
6. A successful response and an exception cannot be asserted together.
7. Response timing matches the documented hit and miss latency.

### 2.3 Flush and reset

Verify:
- Reset clears all outstanding transactions.
- Flush cancels or drains outstanding translations according to the specification.
- No stale response is produced after flush.
- New requests are blocked for the required flush interval.
- `shared_tlb_flush_bsy_o` remains asserted until all required invalidation work is complete.
- Flush has defined priority over new requests, PTW responses, and cache responses.
- Back-to-back flushes are handled correctly.
- Reset during a page walk does not leave the MMU busy permanently.

1. After flush, there should be
   - No itlb hit
   - No dtlb hit 
   - No Shared TLB miss
  For a given VA, vmid 

### 2.4 Exception
- HPTW: throwing exception - page fault exception 
- PMP: access exception 
- DTLB hit:  
  - [LS][ST]: If page is not writable, dirty flags not set, privilege violates -> page fault 
  - [LS][ST]: If PMP violates -> access fault
  - [LS][ST]: page fault > access fault 
  - [LS][LD]: If insufficient access -> page fault 
  - [LS][LD]: If PMP violated -> access fault 
- DTLB miss: 
  - PTW indicates page fault |-> corresponding (LD/ST) page fault signalled 
  - PTW indicates access fault -> laod access fault is indicated through address translation 
- [IC]: What should happend on IC_REQ_exp 
---

## 3. TLB Verification

### 3.1 TLB hit behavior

Verify:

- TLB hit returns the correct physical page number.
- Hit response timing is correct.
- Page offset is preserved.
- Access permissions are checked on hits.
- ASID and VMID are included in matching where required.
- Global mappings ignore ASID where specified.
- Stage-1 and stage-2 entries are not confused.
- Superpage mappings compare only the required VPN bits.
- Invalid entries never hit.

### 3.2 TLB miss behavior

Verify:

- A miss starts exactly one page-table walk.
- PTW requests contain the correct virtual address, access type, privilege, ASID, and VMID.
- The original request remains associated with the PTW.
- PTW completion refills the correct TLB.
- A refill is not performed after a fault or flush.
- Multiple misses are either correctly serialized or correctly tracked.
- PTW responses cannot be associated with the wrong request.

### 3.3 SFENCE and invalidation

Verify invalidation for:

- All entries
- A specific virtual addressf
- A specific ASID
- A specific virtual address and ASID
- Guest/stage-2 entries by VMID
- A specific VMID and address, if supported

Checks:

- Invalidated entries no longer hit.
- Nonmatching entries remain valid.
- Global entries follow the architectural invalidation rules.
- Invalidation during a PTW has defined behavior.
- Invalidation during a TLB refill cannot install stale data.
- Invalidation completion is externally observable if required.

---

## 4. Page-Table Walker Verification

### 4.1 Stage-1 page walk

Verify:

- Correct root page-table base is selected from `satp`.
- Correct page-table level is selected for each translation mode.
- PTE address calculation is correct.
- PTE size and alignment are correct.
- Invalid PTEs generate page faults.
- Non-leaf PTEs are handled correctly.
- Leaf PTEs terminate the walk.
- Misaligned superpages generate page faults.
- A/D-bit behavior matches the implementation specification.
- Reserved PTE bits are handled correctly.
- Maximum walk depth is bounded.

### 4.2 Stage-2 or guest translation

For guest VA → guest PA → host PA, verify:

- Stage-1 uses `vsatp`.
- Stage-2 uses `hgatp`.
- Guest page faults are distinguished from host page faults.
- Both translations apply the required permissions.
- Guest and host page offsets are handled correctly.
- Stage-2 translation is not performed when disabled.
- VMID is used for stage-2 TLB matching.
- A fault in either stage prevents a successful response.
- Two-stage walks cannot deadlock or lose the original request.

### 4.3 PTW-to-cache interface

Verify:

- PTW requests are correctly formatted as data-cache requests.
- PTW requests use the required privilege and access type.
- PTW responses are matched to the correct PTW request.
- Cache errors are converted to the correct MMU exception.
- PTW does not issue requests after cancellation.
- PTW handles cache backpressure.
- PTW handles cache response latency and response stalls.
- PTW cannot issue more requests than the supported outstanding capacity.

---

## 5. Permission and Privilege Checks

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
## 6. PMP and PMA Verification

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

## 7. Address and Boundary Cases

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

## 8. CHERI-Specific Checks

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

## 9. Priority and Ordering

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

## 10. Assertions

Recommended assertions:

- Every accepted request eventually completes or is explicitly cancelled.
- No request produces more than one response.
- No response occurs without a corresponding request.
- TLB hit implies a valid matching entry.
- Invalidated entries cannot produce hits.
- PTW busy eventually deasserts after completion, fault, flush, or reset.
- Flush eventually completes.
- No stale response is produced after flush.
- Response fields remain stable while stalled.
- A successful response has no exception.
- A fault response cannot be marked as a valid translation.
- Physical address page offset equals virtual address page offset.
- TLB refill occurs only after a valid leaf PTE.
- No refill occurs after a PTW fault.
- No deadlock exists in the PTW/cache interface.

---

## 11. Functional Coverage // Not in the scope 

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

## 12. Directed Tests // Not in the scope 

Minimum directed tests:

1. TLB hit with valid read, write, and execute permissions.
2. TLB miss followed by successful PTW refill.
3. Invalid PTE.
4. Misaligned superpage.
5. Permission fault.
6. SUM/MXR/VMXR/VSUM combinations.
7. ASID isolation.
8. VMID isolation.
9. Global mapping behavior.
10. SFENCE by address and ASID.
11. Full TLB flush.
12. Flush during an active PTW.
13. Reset during an active PTW.
14. PMP allow and deny.
15. PTW access denied by PMP.
16. Stage-1 plus stage-2 translation.
17. Guest-page fault.
18. Cache backpressure during PTW.
19. Instruction fetch across a page boundary.
20. CHERI permission, tag, and bounds faults, if applicable.

---

## 13. Items Requiring RTL Clarification

The following must be defined from `cva6_mmu`:

- Exact request and response handshake signals.
- Whether responses can be stalled.
- Maximum number of outstanding requests.
- Whether requests are ordered or use transaction IDs.
- Exact hit and miss latency.
- Meaning of flush completion and `shared_tlb_flush_bsy_o`.
- Whether flush cancels or drains PTWs.
- Exception signal encoding and priority.
- Whether PMP/PMA checks are inside the MMU.
- Whether A/D bits are updated by the PTW.
- Supported Sv modes.
- Supported hypervisor translation modes.
- Whether CHERI checks are inside or outside the MMU.
- Whether misaligned accesses are split or rejected.
- Whether page-boundary accesses are handled by the MMU or LSU.
