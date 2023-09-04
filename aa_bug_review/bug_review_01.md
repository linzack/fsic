當 axi_state 從 AXI_WAIT_DATA -> AXI_DECIDE_DEST  
以及 fifo_out_tuser 從 0 -> 1  
這時 case(fifo_out_tuser)  
看到的 fifo_out_tuser 是 0 還是 1？  
會不會因此 trigger default case (如果看到 0) 造成 do_nothing = 1  
  
do_nothing = 1 的話 下個 state 回到 WAIT  
功能就會錯了  
  
目前做法是把case(fifo_out_tuser) 的 default case 拿掉  
  
```verilog
always_comb begin
    ...
    case(axi_state)
        AXI_WAIT_DATA:
            ...
        AXI_DECIDE_DEST: // axi_state: AXI_WAIT_DATA -> AXI_DECIDE_DEST
            ...
            else if(do_nothing)begin
                axi_next_state = AXI_WAIT_DATA;
            end

always_comb begin
    if(axi_state != AXI_WAIT_DATA)begin
        {fifo_out_tdata, fifo_out_tuser} = fifo_ss_data_out; // fifo_out_tuser: 0 -> 1
    end
    else
        {fifo_out_tdata, fifo_out_tuser} = '0;

always_comb begin
    next_trans = (next_ss) ? TRANS_SS : TRANS_LS;
    if(axi_state == AXI_DECIDE_DEST)begin
        case(next_trans) // next_trans: TRANS_LS -> TRANS_SS
            TRANS_LS: ...
            TRANS_SS: 
                case(fifo_out_tuser) // fifo_out_tuser: 0 (case default) -> 1
                    2'b01: begin     // should do_nothing -> 1 ???
                    2'b10: begin
                    2'b11: begin
                    default: // fifo_out_tuser == 0
                        do_nothing = 1'b1;
                endcase
```
  
![waveform](https://raw.githubusercontent.com/linzack/fsic/main/aa_bug_review/axi_ctrl_logic_bug_1.png)