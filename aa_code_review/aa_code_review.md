[[fsic]]

aa block diagram
![aa block diagram](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_block_diagram.png)

aa fsm lm01
![aa fsm LM01](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_01_lm1.png)

aa fsm lm02
![aa fsm lm02](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_02_lm2.png)

aa fsm ls01
![aa fsm ls01](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_05_ls1.png)

aa fsm ls02
![aa fsm ls02](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_06_ls2.png)

aa fsm sm
![aa fsm sm](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_03_sm.png)

aa fsm ss
![aa block diagram](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_fsm_04_ss.png)

aa fsm control_logic
```verilog
    always_comb begin
        axi_next_state = axi_state;

        case(axi_state)
            AXI_WAIT_DATA:
                if(enough_ls_data || enough_ss_data)begin
                    axi_next_state = AXI_DECIDE_DEST;
                end
            AXI_DECIDE_DEST:
                if(decide_done)begin
                    axi_next_state = AXI_MOVE_DATA;
                end
                else if(trig_sm_wr || trig_sm_rd || trig_lm_wr || trig_lm_rd)begin
                    axi_next_state = AXI_SEND_BKEND;
                end
                else if(do_nothing)begin
                    axi_next_state = AXI_WAIT_DATA;
                end
            AXI_MOVE_DATA:
                if(ls_rd_data_bk || sync_trig_sm_wr)
                    axi_next_state = AXI_SEND_BKEND;
                else if(ss_wr_data_done && sync_trig_int)
                    axi_next_state = AXI_TRIG_INT;
                else if(ls_wr_data_done || ss_wr_data_done)
                    axi_next_state = AXI_WAIT_DATA;
            AXI_SEND_BKEND:
                if(sync_trig_int)
                    axi_next_state = AXI_TRIG_INT;
                else if(send_bk_done)
                    axi_next_state = AXI_WAIT_DATA;
            AXI_TRIG_INT:
                if(axi_interrupt_done)
                    axi_next_state = AXI_WAIT_DATA;
            default:
                axi_next_state = AXI_WAIT_DATA;
        endcase
    end
```

aa datapath
![aa datapath](https://raw.githubusercontent.com/linzack/fsic/main/aa_code_review/code_review_aa_datapath.png)

