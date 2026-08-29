# cva6_cheri_sva
SBY friendly formal verification for cheri_cva6 works

This project is created as an attempt to verify [Cheri CVA6](https://github.com/Capabilities-Limited/cheri-cva6) in block level using SBY formal tools. 

1. Project AIM
   - This project is aimed to create an opensource formal verification testbench using SBY YOSYS to verify mutiple aspect of CVA6-CHERI chips. 
   - The priority will be memory management and coherency components since there has been already formal verification testbench on end-2-end. Therefore this testbench will be used for block-level verification, due to the limitation of open source formal tools, and focus on the part that is usually get blackbox or abstract. 
   - The project will provide formal environment that fully run on SBY YOSYS, including assumptions, assertions and covers. Moreover, the project aims to create invariants and various verification technique that facillitate the proof convergence of the TB. However, coverage metrics will be limited.
   - The expected blocks of verification are: 
     - MMU: focus on data translation, coherency and exceptions 
     - LSU
     - Cache subsystem 
2. Project Timeline 
   - 19/8/26: Creation and planning of the project 
   - 08/26 -> 12/26: 3 months : MMU
     - Verification plan: 1 week 
     - Implementation: 2 months 
     - Convergence & Coverage: 1 month
     - Sign-off metrics: No spurious failure, covers main functionality of the block 
   - 1/26 -> 4/27: 3 months : Cache Subsystem
   - 4/27 -> 9/27: 4 months : LSU 
3. Project Structure 
   - <block>  
     - sby 
     - scripts
     - verif-plan 
     - wrappers 
     - sva 
