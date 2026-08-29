# Property list 

    Contains assumption and assertions property in MMU

| Num | Property name | Status | Notes |
|:---:|:---|:---|:---|
|ASSUMPTIONS| | |
| AM1 | | Overconstraint | Disable Hypervisor through disable enable signal and flush signal
| AM2 | | Overconstraint | No flush_tlb_i without flush_i
| AM3 | | Assumptions | Icache req has to be high until response is valid
| AM4 | | Assumptions | Icache vaddr should be stable during the same req
| AM5 | | Assumptions | Lsu req stay high if there is no dtlb hit and lsu valid in previous cycle
| AM6 | | Assumptions | Lsu req vaddr should stay stable for the same req
| AM7 | | Assumptions | Lsu context shoudl be stable for the same req
| AM8 | DATA_COLOR | Overconstraint | Color the VPN of req from icache and lsu: Should we do this ?
| AM9 | | Assumptions | Only 1 DC rsp for 1 DC req
| AM10 | | Overconstraint | Model DC PPN return to resemble VPN
|ASSERTIONS| | |
| AS1 | AS_IC_RSP_VLD | Running | No spurious IC rsp valid 
| AS2 | AS_IC_OFFSET_VLD | Running | Offset of IC rsp PA always equal to IC req PA
| AS3 | AS_LS_RSP_VLD | Running | No spurious LS rsp valid 
| AS4 | AS_IC_E2E_RSP_DATA_VLD | Modelling | The return IC PA should be correct to the model 
| AS5 | AS_LS_E2E_RSP_DATA_VLD | Modelling | The return LS PA shoudl be correct to the model
| AS6 | AS_ITLB_UPDATE_PRIORITY | CEX | When IC req come first or at the same time, the itlb should be update first 
| AS7 | AS_DTLB_UPDATE | Modelling | When LS req come first, it should be update first
| AS8 | AS_IC_E2E_RSP_DATA_COLOR | Ind CEX | The rsp should only have IC color 
| AS9 | AS_LS_E2E_RSP_DATA_COLOR | Ind CEX | The rsp should only have LS color 
| AS10 | AS_DC_REQ_STABLE_UNTIL_GRANT | Running | The DC req should be stable until grant
| AS11 | AS_DC_REQ_DATA_STABLE_UNTIL_GRANT | Modelling |
| AS12 | AS_LSU_DTLB_HIT_IMPLY_VALID_RSP | Running | The DC rsp should be valid after lsu_dtlb_hit
