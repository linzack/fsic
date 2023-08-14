module axi_fifo#(WIDTH=8'h8, DEPTH=8'h8)(
    input wire clk,
    input wire rst_n,
    input wire wr_vld,
    input wire rd_rdy,
    input wire hack,
    input wire clear,
    input wire [WIDTH - 1:0] data_in,
    output logic [WIDTH - 1:0] data_out,
    output logic wr_rdy,
    output logic rd_vld,
    output logic last
);
...
    // pointer and water level, use valid and ready to handshake
    always_ff@(posedge clk or negedge rst_n)begin
        if(~rst_n)begin
...
        end
        else begin
            if(clear)begin
                wr_pointer <= 8'h0;
                rd_pointer <= 8'h0;
                wr_count <= 8'h0;
                rd_count <= 8'h0;
                wr_count_pre <= 8'h0;
            end
            if(rd_rdy && rd_vld && wr_rdy && wr_vld)begin // do read and write
                rd_pointer <= (rd_pointer == (DEPTH - 8'b1)) ? 8'h0 : rd_pointer + 8'b1;
                wr_pointer <= (wr_pointer == (DEPTH - 8'b1)) ? 8'h0 : wr_pointer + 8'b1;
                fifo[wr_pointer] <= data_in;
                wr_count <= wr_count + 8'b1;
                rd_count <= rd_count + 8'b1;
            end
            else if(rd_rdy && rd_vld)begin // do read
                rd_pointer <= (rd_pointer == (DEPTH - 8'b1)) ? 8'h0 : rd_pointer + 8'b1;
                rd_count <= rd_count + 8'b1;
            end
            else if(wr_rdy && wr_vld)begin // do write
                wr_pointer <= (wr_pointer == (DEPTH - 8'b1)) ? 8'h0 : wr_pointer + 8'b1;
                wr_count <= wr_count + 8'b1;
                fifo[wr_pointer] <= data_in;
            end

            wr_count_pre <= wr_count; // to fix bug in last transaction no ready
        end
    end

    // output current read data if fifo is not empty, data go first before pointer moving, to solve read fifo cost too many clock
    always_comb begin // use combinational so rd_pointer change reflect instantly
        //data_out = '0; // initialize packed array (as a vector) with all zero

        if(empty == 1'b0)begin
            data_out = fifo[rd_pointer];
        end
        else
            data_out = '0; // initialize packed array (as a vector) with all zero
    end

    // to fix bug in short transaction only have one clock data
    always_ff@(posedge clk or negedge rst_n)
        if(~rst_n)  sync_rd_vld <= 1'b0;
        else        sync_rd_vld <= rd_vld;

    // decide when this fifo can be read or wrote
    always_comb begin
        if(hack)begin // for axis_master
            if((wr_count_pre == wr_count) && (wr_count - rd_count) == 8'h2)begin // last data (n-1), raise last, axis_master can decide the bus behavior it should do
                rd_vld = 1'b1;
                last = 1'b1;
            end
            else if((wr_count_pre == wr_count) && (wr_count - rd_count) <= 8'h1)begin // last data (n)
                rd_vld = 1'b0;
                last = 1'b1;
            end
            else if((wr_count - rd_count) > 8'h1) // normal data, not last
                rd_vld = 1'b1;
            else if(wr_count == 8'h1 && rd_count == 8'h0 && ~sync_rd_vld)begin // for short transaction only have one clock data
                rd_vld = 1'b1;
                last = 1'b0;
            end
            else begin
                rd_vld = 1'b0;
                last = 1'b0;
            end
        end
        else begin // for control_logic
            if((wr_count - rd_count) > 8'h1)
                rd_vld = 1'b1;
            else if((wr_count - rd_count) == 8'h1)
                rd_vld = 1'b1;
            else begin
                rd_vld = 1'b0;
                last = 1'b0;
            end
        end

        if(full == 1'b0) // can be wrote
            wr_rdy = 1'b1;
        else
            wr_rdy = 1'b0;
    end

    always_comb begin
        empty = ((wr_count - rd_count) == 8'h0);
        full = ((wr_count - rd_count) == DEPTH - 8'h1); // reserve one if ready too late
    end

endmodule

///////////////////////////////////////////////////
// LM
///////////////////////////////////////////////////
    enum logic [2:0] {WR_WAIT_ADDR, WR_WRITE_ADDR, WR_WRITE_DATA} axi_wr_state, axi_wr_next_state;
    // FSM state, combinational logic
    always_comb begin
        axi_wr_next_state = axi_wr_state;

        case(axi_wr_state)
            WR_WAIT_ADDR:
                if(wr_addr_go)begin
                    axi_wr_next_state = WR_WRITE_ADDR;
                end
            WR_WRITE_ADDR:
                if(axi_awvalid && axi_awready)begin
                    axi_wr_next_state = WR_WRITE_DATA;
                end
            WR_WRITE_DATA:
                if(axi_wvalid && axi_wready)begin
                    axi_wr_next_state = WR_WAIT_ADDR;
                end
            default:
                axi_wr_next_state = WR_WAIT_ADDR;
        endcase
    end

    always_comb begin
        axi_rd_next_state = axi_rd_state;

        case(axi_rd_state)
            RD_WAIT_ADDR:
                if(rd_addr_go)begin
                    axi_rd_next_state = RD_READ_ADDR;
                end
            RD_READ_ADDR:
                if(axi_arvalid && axi_arready)begin
                    axi_rd_next_state = RD_DRIVE_RDY;
                end
            RD_DRIVE_RDY:
                if(axi_rvalid && axi_rready)begin
                    axi_rd_next_state = RD_READ_DATA;
                end
            RD_READ_DATA: axi_rd_next_state = RD_WAIT_ADDR;
            default:
                axi_rd_next_state = RD_WAIT_ADDR;
        endcase
    end

///////////////////////////////////////////////////
// SM
///////////////////////////////////////////////////

    always_comb begin
        axis_next_state = axis_state;

        case(axis_state)
            AXIS_WAIT_DATA:
                if(enough_data)begin
                    axis_next_state = AXIS_SEND_DATA;
                end
            AXIS_SEND_DATA:
                if(fifo_last && enough_data == 1'b0)begin // one cycle data
                    axis_next_state = AXIS_SEND_LAST;
                end
                else if(fifo_last && axis_tready)begin // last data
                    axis_next_state = AXIS_SEND_LAST;
                end
            AXIS_SEND_LAST:
                if(axis_tready)begin
                    axis_next_state = AXIS_WAIT_DATA;
                end
            default:
                axis_next_state = AXIS_WAIT_DATA;
        endcase
    end

    // FSM state, combinational logic, axis, output control
    always_comb begin
        //axis_tvalid = 1'b0;
        //axis_tdata = 32'h0;
        //axis_tstrb = 4'h0;
        //axis_tkeep = 4'h0;
        //axis_tuser = 2'h0;
        //next_data = 1'b0;

        if(axis_state == AXIS_SEND_DATA && axis_next_state == AXIS_SEND_LAST && enough_data == 1'b1)begin // workaround for two cycle data
            axis_tvalid = 1'b1;
            axis_tdata = fifo_out_tdata;
            axis_tstrb = fifo_out_tstrb;
            axis_tkeep = fifo_out_tkeep;
            axis_tuser = fifo_out_user;
            if(axis_tready)begin
                next_data = 1'b1;
            end
            else begin
                next_data = 1'b0;
            end
        end
        else if(axis_state == AXIS_SEND_DATA && axis_next_state == AXIS_SEND_LAST && enough_data == 1'b0)begin // workaround for one cycle data, do not drive bus
            if(axis_tready)begin
                next_data = 1'b1;
            end
            else begin
                next_data = 1'b0;
            end
        end
        else if(axis_state == AXIS_SEND_DATA)begin // normal data
            axis_tvalid = 1'b1;
            axis_tdata = fifo_out_tdata;
...
            axis_tuser = fifo_out_user;
            if(axis_tready)begin
                next_data = 1'b1;
            end
            else begin
                next_data = 1'b0;
            end
        end
        else if(axis_state == AXIS_SEND_LAST)begin // final data
            axis_tvalid = 1'b1;
            axis_tdata = fifo_out_tdata;
...
            next_data = 1'b0;
        end
        else begin
            axis_tvalid = 1'b0;
            axis_tdata = 32'h0;
            axis_tstrb = 4'h0;
            axis_tkeep = 4'h0;
            axis_tuser = 2'h0;
            next_data = 1'b0;
        end
    end

    axi_fifo #(.WIDTH(AXI_FIFO_WIDTH), .DEPTH(AXI_FIFO_DEPTH)) fifo(
        .clk(axi_aclk),
        .rst_n(axi_aresetn),
        .wr_vld(fifo_wr_vld),
        .rd_rdy(fifo_rd_rdy),
        .hack(1'b1),
        .data_in(fifo_data_in),
        .data_out(fifo_data_out),
        .wr_rdy(fifo_wr_rdy),
        .rd_vld(fifo_rd_vld),
        .last(fifo_last),
        .clear(fifo_clear));

    // send backend data to fifo
    always_comb begin
        //fifo_data_in = '0;
        //fifo_wr_vld = 1'b0;

        if(bk_start)begin
            fifo_data_in = {bk_data, bk_tstrb, bk_tkeep, bk_user};
            fifo_wr_vld = 1'b1;
        end
        else begin
            fifo_data_in = '0;
            fifo_wr_vld = 1'b0;
        end
    end

    // get data from fifo
    always_comb begin
        //{fifo_out_tdata, fifo_out_tstrb, fifo_out_tkeep, fifo_out_user} = '0;
        //fifo_rd_rdy = 1'b0;
        //fifo_clear = 1'b0;

        if(axis_state == AXIS_SEND_DATA || axis_state == AXIS_SEND_LAST)begin
            {fifo_out_tdata, fifo_out_tstrb, fifo_out_tkeep, fifo_out_user} = fifo_data_out;
        end
        else
            {fifo_out_tdata, fifo_out_tstrb, fifo_out_tkeep, fifo_out_user} = '0;

        if(next_data)begin // receive slave tready, can send next data
            fifo_rd_rdy = 1'b1;
        end
        else
            fifo_rd_rdy = 1'b0;

        if(bk_done)begin // clear fifo when transaction done to fix bug
            fifo_clear = 1'b1;
        end
        else
            fifo_clear = 1'b0;
    end

///////////////////////////////////////////////////
// SS
///////////////////////////////////////////////////

    always_comb begin
        axis_next_state = axis_state;

        case(axis_state)
            AXIS_WAIT_BACKEND:
                if(bk_ready && axis_tvalid)begin
                    axis_next_state = AXIS_OUTPUT_DATA;
                end
            AXIS_OUTPUT_DATA:
                if(axis_tvalid && bk_ready)begin
                    axis_next_state = AXIS_OUTPUT_DATA;
                end
                else begin
                    axis_next_state = AXIS_WAIT_BACKEND;
                end
            default:
                axis_next_state = AXIS_WAIT_BACKEND;
        endcase
    end

///////////////////////////////////////////////////
// CL
///////////////////////////////////////////////////


    always_ff@(posedge axi_aclk or negedge axi_aresetn)begin
        if(~axi_aresetn)begin
...
        end
        else begin
            if(axi_state == AXI_WAIT_DATA && axi_next_state == AXI_DECIDE_DEST)begin
                // decide next transaction is LS / SS by round robin
                next_ls <= enough_ls_data & (~enough_ss_data | (last_trans == TRANS_SS));
                next_ss <= enough_ss_data & (~enough_ls_data | (last_trans == TRANS_LS));
            end

            if(axi_state == AXI_DECIDE_DEST && axi_next_state != AXI_DECIDE_DEST)
                last_trans <= next_trans;
...
        end
    end
    
    // wr_mb: write mailbox register
    // rd_mb: read  mailbox register
    // wr_aa: write AA register
    // rd_aa: read  AA register
    // rd_unsupp: read but addr do not meet our supported addr range, return 0xFFFF_FFFF
    // trig_sm_wr: trigger SM write (tuser 01)
    // trig_sm_rd: trigger SM read (tuser 10)
    // do_nothing: write but addr do not meet our supported addr range, go back to wait state
    // trig_int: trigger interrupt
    // trig_lm_wr: trigger LM write to CC
    // trig_lm_rd: trigger LM read to CC
    
    // compute control signals according to source (LS / SS) and address range
    // note this is combinational, so the signals can only exist when state is AXI_DECIDE_DEST, 
    // if the signal need to be used in two clock cycles after the state, have to make a register for it
    always_comb begin
        ...
        next_trans = (next_ss) ? TRANS_SS : TRANS_LS;
        
        if(axi_state == AXI_DECIDE_DEST)begin
            case(next_trans)
                TRANS_LS: begin // request come from left side - axilite_slave
                    case(fifo_out_trans_typ)
                        AXI_WR: begin
                        end
                        AXI_RD: begin
                        end
                    endcase
                end
                TRANS_SS: begin // request come from right side - axis_slave
                    case(fifo_out_tuser)
                        2'b01: begin // axis slave two-cycle data with tuser = 2'b01, can be converted to axilite write address / write data
                        end
                        2'b10: begin // axis slave one-cycle data with tuser = 2'b10, can be converted to axilite read address
                        2'b11: begin // read user project wrapper, data go back from CC through axis
                            data_ss = fifo_out_tdata;
                            rd_ss_complete = 1'b1;
                        end
                        default: do_nothing = 1'b1;
                    endcase

    
    assign decide_done = wr_mb | rd_mb | wr_aa | rd_aa | rd_unsupp | rd_ss_complete;
