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

    assign enough_ls_data = fifo_ls_rd_vld;
    assign enough_ss_data = fifo_ss_rd_vld;

    always_ff@(posedge axi_aclk or negedge axi_aresetn)begin
        if(~axi_aresetn)begin
...
        end
        else begin
                // decide next transaction is LS / SS by round robin
                next_ls <= enough_ls_data & (~enough_ss_data | (last_trans == TRANS_SS));
                next_ss <= enough_ss_data & (~enough_ls_data | (last_trans == TRANS_LS));
                
...
                last_trans <= next_trans;
...
        end
    end
    
    // list of control signals
    // wr_mb: write mailbox register
    
    // rd_mb: read  mailbox register
    
    // wr_aa: write AA register
    
    // rd_aa: read  AA register
    
    // rd_unsupp: read but addr do not meet our supported addr range, return 0xFFFF_FFFF
    
    // rd_ss_complete: read user project wrapper, data go back from CC through axis (tuser 11)
    
    // trig_sm_wr: trigger SM write (tuser 01)
    
    // trig_sm_rd: trigger SM read (tuser 10)
    
    // do_nothing: write but addr do not meet our supported addr range, go back to wait state
    
    // trig_int: trigger interrupt
    
    // trig_lm_wr: trigger LM write to CC
    
    // trig_lm_rd: trigger LM read to CC
    
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


// IO
module axi_ctrl_logic(
    input wire axi_aclk,
    input wire axi_aresetn,
    output logic axi_interrupt,

    // backend interface, axilite_master (LM)
    output logic bk_lm_wstart,
    output logic [31:0] bk_lm_waddr,
    output logic [31:0] bk_lm_wdata,
    output logic [3:0]  bk_lm_wstrb,
    input wire bk_lm_wdone,
    output logic bk_lm_rstart,
    output logic [31:0] bk_lm_raddr,
    input wire [31:0] bk_lm_rdata,
    input wire bk_lm_rdone,

    // backend interface, axilite_slave (LS)
    input wire bk_ls_wstart,
    input wire [14:0] bk_ls_waddr,
    input wire [31:0] bk_ls_wdata,
    input wire [3:0]  bk_ls_wstrb,
    input wire bk_ls_rstart,
    input wire [14:0] bk_ls_raddr,
    output logic [31:0] bk_ls_rdata,
    output logic bk_ls_rdone,

    // backend interface, axis_master (SM)
    output logic bk_sm_start,
    output logic [31:0] bk_sm_data,
    output logic [3:0] bk_sm_tstrb,
    output logic [3:0] bk_sm_tkeep,
    //output logic [1:0] bk_sm_tid,
    output logic [1:0] bk_sm_user,
    input wire bk_sm_nordy,
    input wire bk_sm_done,

    // backend interface, axis_slave (SS)
    input wire [31:0] bk_ss_data,
    input wire [3:0] bk_ss_tstrb,
    input wire [3:0] bk_ss_tkeep,
    //input wire [1:0] bk_ss_tid,
    input wire [1:0] bk_ss_user,
    input wire bk_ss_tlast,
    output logic bk_ss_ready,
    input wire bk_ss_valid
);

// fifo size
    parameter FIFO_LS_WIDTH = 8'd52, FIFO_LS_DEPTH = 8'd8;
    parameter FIFO_SS_WIDTH = 8'd34, FIFO_SS_DEPTH = 8'd8;
    logic [FIFO_LS_WIDTH-1:0] fifo_ls_data_in, fifo_ls_data_out;
    logic [FIFO_SS_WIDTH-1:0] fifo_ss_data_in, fifo_ss_data_out;

// fifo instance
    // data format:
    // if write: {rd_wr_1bit, waddr_15bit, wdata_32bit, wstrb_4bit}, total 52bit
    // if read:  {rd_wr_1bit, raddr_15bit, padding_zero_36bit},      total 52bit
    axi_fifo #(.WIDTH(FIFO_LS_WIDTH), .DEPTH(FIFO_LS_DEPTH)) fifo_ls(
        .clk(axi_aclk),
        .rst_n(axi_aresetn),
        .wr_vld(fifo_ls_wr_vld),
        .rd_rdy(fifo_ls_rd_rdy),
        .hack(1'b0),
        .data_in(fifo_ls_data_in),
        .data_out(fifo_ls_data_out),
        .wr_rdy(fifo_ls_wr_rdy),
        .rd_vld(fifo_ls_rd_vld),
        .last(fifo_ls_last),
        .clear(fifo_ls_clear));

    // data format:
    // {data_32bit, user_2bit}, total 34bit
    axi_fifo #(.WIDTH(FIFO_SS_WIDTH), .DEPTH(FIFO_SS_DEPTH)) fifo_ss(
        .clk(axi_aclk),
        .rst_n(axi_aresetn),
        .wr_vld(fifo_ss_wr_vld),
        .rd_rdy(fifo_ss_rd_rdy),
        .hack(1'b0),
        .data_in(fifo_ss_data_in),
        .data_out(fifo_ss_data_out),
        .wr_rdy(fifo_ss_wr_rdy),
        .rd_vld(fifo_ss_rd_vld),
        .last(fifo_ss_last),
        .clear(fifo_ss_clear));

// state and selection
    enum logic [2:0] {AXI_WAIT_DATA, AXI_DECIDE_DEST, AXI_MOVE_DATA, AXI_SEND_BKEND, AXI_TRIG_INT} axi_state, axi_next_state;
    enum logic {AXI_WR, AXI_RD} fifo_out_trans_typ;
    enum logic {TRANS_LS, TRANS_SS} next_trans, last_trans;


    // send backend data to LS fifo
    always_comb begin
        // note: potential bug if bk_ls_wstart && bk_ls_rstart both 1, but this case will not happen if config_ctrl use cc_aa_enable for read/write exclusively
        if(bk_ls_wstart)begin
            fifo_ls_data_in = {AXI_WR, bk_ls_waddr, bk_ls_wdata, bk_ls_wstrb};
            fifo_ls_wr_vld = 1'b1;
        end
        else if(bk_ls_rstart)begin
            fifo_ls_data_in = {AXI_RD, bk_ls_raddr, read_padding_zero};
            fifo_ls_wr_vld = 1'b1;
        end
        else begin
            fifo_ls_data_in = '0;
            fifo_ls_wr_vld = 1'b0;
        end
    end

    // send backend data to SS fifo
    always_comb begin
        if(bk_ss_valid)begin
            fifo_ss_data_in = {bk_ss_data, bk_ss_user};
            fifo_ss_wr_vld = 1'b1;
        end
        else begin
            fifo_ss_data_in = '0;
            fifo_ss_wr_vld = 1'b0;
        end

        if(fifo_ss_wr_rdy == 1'b0)begin // fifo full, tell SS do not receive new data
            bk_ss_ready = 1'b0;
        end
        else
            bk_ss_ready = 1'b1;
    end
    
    // get data from LS fifo
    always_comb begin
        if(fifo_ls_data_out[FIFO_LS_WIDTH-1] == AXI_WR)
            {fifo_out_trans_typ, fifo_out_waddr, fifo_out_wdata, fifo_out_wstrb} = fifo_ls_data_out;
        else if(fifo_ls_data_out[FIFO_LS_WIDTH-1] == AXI_RD)
            {fifo_out_trans_typ, fifo_out_raddr} = fifo_ls_data_out[FIFO_LS_WIDTH-1:36]; // wdata + wstrb total 36bit
        else
            {fifo_out_trans_typ, fifo_out_waddr, fifo_out_raddr, fifo_out_wdata, fifo_out_wstrb} = '0;

        if((axi_state != AXI_WAIT_DATA) && (axi_next_state == AXI_WAIT_DATA) && (next_trans == TRANS_LS))begin // can send next data
            fifo_ls_rd_rdy = 1'b1;
        end
        else
            fifo_ls_rd_rdy = 1'b0;
    end

    // get data from SS fifo

    assign fifo_ss_clear = 1'b0;

    always_comb begin
        //{fifo_out_tdata, fifo_out_tuser} = '0;
        //fifo_ss_rd_rdy = 1'b0;
        //fifo_ss_clear = 1'b0;

        if(axi_state != AXI_WAIT_DATA)begin
            {fifo_out_tdata, fifo_out_tuser} = fifo_ss_data_out;
        end
        else
            {fifo_out_tdata, fifo_out_tuser} = '0;

        if((axi_state != AXI_WAIT_DATA) && (axi_next_state == AXI_WAIT_DATA) && (next_trans == TRANS_SS))begin
            fifo_ss_rd_rdy = 1'b1;
        end
        else if(get_next_data_ss)begin // if tuser in SS is 1, AXI_WR need nex trans data
            fifo_ss_rd_rdy = 1'b1;
        end
        else
            fifo_ss_rd_rdy = 1'b0;
    end
    
    // SS write transaction need to read two cycle of data
    always_ff@(posedge axi_aclk or negedge axi_aresetn) // keep old data from SS
        if(~axi_aresetn)
            fifo_out_tdata_old <= 32'b0;
        else
            fifo_out_tdata_old <= fifo_out_tdata;

    parameter MB_SUPP_LOW = 15'h2000, MB_SUPP_HIGH = 15'h201F;
    parameter AA_SUPP_LOW = 15'h2100, AA_SUPP_HIGH = 15'h2107, AA_UNSUPP_HIGH = 15'h2FFF;
    parameter FPGA_USER_WP_0 = 15'h0000, FPGA_USER_WP_1 = 15'h1FFF, FPGA_USER_WP_2 = 15'h3000, FPGA_USER_WP_3 = 15'h4FFF, CARAVEL_BASE= 32'h30000000;

    // compute control signals according to source (LS / SS) and address range
    // note this is combinational, so the signals can only exist when state is AXI_DECIDE_DEST, 
    // if the signal need to be used in two clock cycles after the state, have to make a register for it
    always_comb begin
        if(axi_state == AXI_DECIDE_DEST)begin
            case(next_trans)
                TRANS_LS: begin // request come from left side - axilite_slave
                    case(fifo_out_trans_typ)
                        AXI_WR: begin
                            if( (fifo_out_waddr >= MB_SUPP_LOW) &&
                                (fifo_out_waddr <= MB_SUPP_HIGH))begin // local access MB_reg
                                wr_mb = 1'b1;
                                trig_sm_wr = 1'b1;
                                // compute related index for dw address
                                mb_index = fifo_out_waddr[11:2] - MB_SUPP_LOW[11:2];
                            end
                            else if((fifo_out_waddr >= AA_SUPP_LOW) &&
                                    (fifo_out_waddr <= AA_SUPP_HIGH))begin // local access AA_reg
                                wr_aa = 1'b1;
                                // compute related index for dw address
                                aa_index = fifo_out_waddr[11:2] - AA_SUPP_LOW[11:2];
                            end
                            else if((fifo_out_waddr >= MB_SUPP_LOW) &&
                                    (fifo_out_waddr <= AA_UNSUPP_HIGH))begin // in MB AA range but is unsupported, ignored
                                do_nothing = 1'b1;
                            end
                            else if(((fifo_out_waddr >= FPGA_USER_WP_0) &&
                                     (fifo_out_waddr <= FPGA_USER_WP_1)) ||
                                    ((fifo_out_waddr >= FPGA_USER_WP_2) &&
                                     (fifo_out_waddr <= FPGA_USER_WP_3)))begin // fpga side access caravel usesr project wrapper, this do not fire in caravel side
                                trig_sm_wr = 1'b1;
                            end
                            else
                                do_nothing = 1'b1;
                        end
                        AXI_RD: begin
                            if( (fifo_out_raddr >= MB_SUPP_LOW) &&
                                (fifo_out_raddr <= MB_SUPP_HIGH))begin // local access MB_reg
                                rd_mb = 1'b1;
                                // compute related index for dw address
                                mb_index = fifo_out_raddr[11:2] - MB_SUPP_LOW[11:2];
                            end
                            else if((fifo_out_raddr >= AA_SUPP_LOW) &&
                                    (fifo_out_raddr <= AA_SUPP_HIGH))begin // local access AA_reg
                                rd_aa = 1'b1;
                                // compute related index for dw address
                                aa_index = fifo_out_raddr[11:2] - AA_SUPP_LOW[11:2];
                            end
                            else if((fifo_out_raddr >= MB_SUPP_LOW) &&
                                    (fifo_out_raddr <= AA_UNSUPP_HIGH))begin // in MB AA range but is unsupported
                                rd_unsupp = 1'b1;
                            end
                            else if(((fifo_out_raddr >= FPGA_USER_WP_0) &&
                                     (fifo_out_raddr <= FPGA_USER_WP_1)) ||
                                    ((fifo_out_raddr >= FPGA_USER_WP_2) &&
                                     (fifo_out_raddr <= FPGA_USER_WP_3)))begin // fpga side access caravel usesr project wrapper, this do not fire in caravel side
                                trig_sm_rd = 1'b1;
                            end
                            else
                                //do_nothing = 1'b1;
                                // should not happen, return all 1 for unsupported address request.
                                // ex: AA support local AA + MB + remote caravel MMIO resource = 20K.
                                // but user define AA MMIO resource = 24K, and send 24-1K address to AA.
                                rd_unsupp = 1'b1;
                        end
                    endcase
                end
                TRANS_SS: begin // request come from right side - axis_slave
                    case(fifo_out_tuser)
                        2'b01: begin // axis slave two-cycle data with tuser = 2'b01, can be converted to axilite write address / write data
                            if(ss_data_cnt == 2'b0)begin
                                get_next_data_ss = 1'b1;
                            end
                            else if(ss_data_cnt == 2'b1)begin
                                wstrb_ss = fifo_out_tdata_old[31:28];
                                addr_ss = fifo_out_tdata_old[27:0];
                                data_ss = fifo_out_tdata;
                                get_next_data_ss = 1'b0;

                                if( (addr_ss >= {13'b0, MB_SUPP_LOW}) &&
                                    (addr_ss <= {13'b0, MB_SUPP_HIGH}))begin // remote access MB_reg, write
                                    wr_mb = 1'b1;
                                    trig_int = 1'b1;
                                    // compute related index for dw address
                                    mb_index = addr_ss[11:2] - MB_SUPP_LOW[11:2];
                                end
                                else if((addr_ss >= {13'b0, FPGA_USER_WP_0}) &&
                                        (addr_ss <= {13'b0, FPGA_USER_WP_3}))begin
                                    trig_lm_wr = 1'b1;
                                end
                                else
                                    do_nothing = 1'b1; // ???????
                            end
                        end
                        2'b10: begin // axis slave one-cycle data with tuser = 2'b10, can be converted to axilite read address
                            addr_ss = fifo_out_tdata[27:0];
                            if((addr_ss >= {13'b0, FPGA_USER_WP_0}) &&
                               (addr_ss <= {13'b0, FPGA_USER_WP_3}))begin
                                    trig_lm_rd = 1'b1;
                                end
                            else
                                do_nothing = 1'b1;
                        end
                        2'b11: begin // read user project wrapper, data go back from CC through axis
                            data_ss = fifo_out_tdata;
                            rd_ss_complete = 1'b1;
                        end
                        default: do_nothing = 1'b1;
                    endcase
                end
            endcase
        end
        
        
        
    always_ff@(posedge axi_aclk or negedge axi_aresetn)begin
        if(~axi_aresetn)begin
...

        end
        else begin
            if(axi_next_state == AXI_MOVE_DATA)begin
                if(wr_mb)begin
                    // write MB_reg
                    case(next_trans)
                        TRANS_LS: begin
                            if(fifo_out_wstrb[0]) mb_regs[mb_index][7: 0] <= fifo_out_wdata[7:0];
                            if(fifo_out_wstrb[1]) mb_regs[mb_index][15:8] <= fifo_out_wdata[15:8];
                            if(fifo_out_wstrb[2]) mb_regs[mb_index][23:16] <= fifo_out_wdata[23:16];
                            if(fifo_out_wstrb[3]) mb_regs[mb_index][31:24] <= fifo_out_wdata[31:24];
                            ls_wr_data_done <= 1'b1;
                        end
                        TRANS_SS: begin
                            if(wstrb_ss[0]) mb_regs[mb_index][7: 0] <= data_ss[7:0];
                            if(wstrb_ss[1]) mb_regs[mb_index][15:8] <= data_ss[15:8];
                            if(wstrb_ss[2]) mb_regs[mb_index][23:16] <= data_ss[23:16];
                            if(wstrb_ss[3]) mb_regs[mb_index][31:24] <= data_ss[31:24];
                            ss_wr_data_done <= 1'b1;
                        end
                    endcase
                end
                else if(rd_mb)begin
                    // read MB_reg
                    case(next_trans)
                        TRANS_LS: begin
                            data_return <= mb_regs[mb_index];
                            ls_rd_data_bk <= 1'b1;
                        end
                        TRANS_SS: begin
                            // should not happen. remote MB/AA register read is not supported
                        end
                    endcase
                end
                else if(wr_aa)begin
                    // write AA_reg
                    case(next_trans)
                        TRANS_LS: begin
                            // offset 0
                            if(aa_index == 10'b0)begin
                                // bit 0 RW, other bits RO
                                if(fifo_out_wstrb[0]) aa_regs[aa_index][0] <= fifo_out_wdata[0];
                            end
                            // offset 4
                            else if(aa_index == 10'b1)begin
                                // bit 0 RW1C, other bits RO
                                if(fifo_out_wstrb[0]) aa_regs[aa_index][0] <= aa_regs[aa_index][0] & ~fifo_out_wdata[0];
                            end
                            // other offset registers, should not come here due to we only support aa_regs[1:0]
                            else begin
                                if(fifo_out_wstrb[0]) aa_regs[aa_index][7: 0] <= fifo_out_wdata[7:0];
                                if(fifo_out_wstrb[1]) aa_regs[aa_index][15:8] <= fifo_out_wdata[15:8];
                                if(fifo_out_wstrb[2]) aa_regs[aa_index][23:16] <= fifo_out_wdata[23:16];
                                if(fifo_out_wstrb[3]) aa_regs[aa_index][31:24] <= fifo_out_wdata[31:24];
                            end
                            ls_wr_data_done <= 1'b1;
                        end
                        TRANS_SS: begin // ?????????????
                            // should not happen. remote MB/AA register write is not supported
                            ss_wr_data_done <= 1'b1;
                        end
                    endcase
                end
                else if(rd_aa)begin
                    // read AA_reg
                    case(next_trans)
                        TRANS_LS: begin
                            data_return <= aa_regs[aa_index];
                            ls_rd_data_bk <= 1'b1;
                        end
                        TRANS_SS: begin
                            // should not happen. Remote MB/AA register read is not supported
                        end
                    endcase
                end
                else if(rd_unsupp)begin
                    // read MB_reg / AA_reg unsupported range
                    // Return 0xFFFFFFFF when the register is not supported
                    data_return <= 32'hFFFFFFFF;
                    case(next_trans)
                        TRANS_LS:
                            ls_rd_data_bk <= 1'b1;
                        //TRANS_SS:
                            // this path will not fire, because only wr_mb or fpga write caravel side can go through axis
                            //ss_rd_data_bk <= 1'b1;
                    endcase
                end
                else if(rd_ss_complete)begin
                    // read data from user project wrapper come back to fpga
                    case(next_trans)
                        //TRANS_LS: begin
                        //end
                        TRANS_SS: begin
                            data_return <= data_ss;
                            ls_rd_data_bk <= 1'b1;
                        end
                    endcase
                end
            end
            else if(axi_next_state == AXI_SEND_BKEND)begin
                if(sync_trig_sm_rd)begin
                    bk_sm_start <= 1'b1;
                    bk_sm_data <= {17'b0, fifo_out_raddr};
                    bk_sm_user <= 2'b10;
                    send_bk_done <= 1'b1;
                end
                else if(ls_rd_data_bk)begin
                    bk_ls_rdata <= data_return;
                    bk_ls_rdone <= 1'b1;
                    send_bk_done <= 1'b1;
                end
                else if(trig_sm_wr || sync_trig_sm_wr)begin
                    if(ss_data_cnt == 2'b0)begin
                        bk_sm_start <= 1'b1;
                        bk_sm_data <= {fifo_out_wstrb, 13'b0, fifo_out_waddr};
                        bk_sm_user <= 2'b01;
                    end
                    else if(ss_data_cnt == 2'b1)begin
                        bk_sm_start <= 1'b1;
                        bk_sm_data <= fifo_out_wdata;
                        bk_sm_user <= 2'b01;
                        send_bk_done <= 1'b1;
                    end
                end
                else if(trig_lm_wr)begin
                    bk_lm_wstart <= 1'b1;
                    bk_lm_waddr <= {4'b0, addr_ss} + CARAVEL_BASE;
                    bk_lm_wdata <= data_ss;
                    bk_lm_wstrb <= wstrb_ss;
                    send_bk_done <= 1'b1;
                end
                else if(trig_lm_rd || sync_trig_lm_rd)begin
                    if(~lm_rd_bk_sent)begin
                        if(lm_rd_cnt == 2'b0)begin
                            bk_lm_rstart <= 1'b1;
                            bk_lm_raddr <= {4'b0, addr_ss} + CARAVEL_BASE;
                        end
                        else if(lm_rd_cnt == 2'b01)begin
                            bk_lm_rstart <= 1'b0;
                            bk_lm_raddr <= 32'b0;
                            lm_rd_bk_sent <= 1'b1;
                        end
                    end

                    if(bk_lm_rdone)begin // data return from config_ctrl axilite slave
                        // trigger axis master send data to fpga
                        bk_sm_start <= 1'b1;
                        bk_sm_data <= bk_lm_rdata;
                        bk_sm_user <= 2'b11; // return data
                        send_bk_done <= 1'b1;
                    end
                end
            end
            else if(axi_next_state == AXI_TRIG_INT)begin
                // edge trigger interrupt signal, will be de-assert in next posedge
                if(mb_int_en)begin
                    axi_interrupt <= 1'b1;
                    // update interrupt status, offset 4 bit 0
                    aa_regs[1][0] <= 1'b1;
                end
                axi_interrupt_done <= 1'b1;
            end