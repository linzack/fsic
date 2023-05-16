///////////////////////////////////////////////////////////////////////////////////////////////////
//
//       MODULE: axi_lite_master
//       AUTHOR: zack
// ORGANIZATION: fsic
//      CREATED: 05/16/2023
///////////////////////////////////////////////////////////////////////////////////////////////////

module axi_lite_master(
    input axi_aclk,
    input axi_aresetn,
    output logic axi_awvalid,
    output logic [11:0] axi_awaddr,
    output logic axi_wvalid,
    output logic [31:0] axi_wdata,
    output logic [3:0] axi_wstrb,
    output logic axi_arvalid,
    output logic [11:0] axi_araddr,
    output logic axi_rready,
    input [31:0] axi_rdata,
    input axi_awready,
    input axi_wready,
    input axi_arready,
    input axi_rvalid
);

    ////////////////////////// modify these ////////////////////////////
    logic wr_addr_go = 0, wr_data_go = 0, rd_addr_go = 0, rd_data_go =0;
    logic [11:0] wr_addr_to_send = 0, rd_addr_to_send = 0;
    logic [31:0] wr_data_to_send = 0, rd_data_to_receive = 0;
    ////////////////////////// modify these ////////////////////////////

    // FSM state
    enum logic [2:0] {WR_WAIT_ADDR, WR_WRITE_ADDR, WR_WAIT_DATA, WR_WRITE_DATA} axi_wr_state, axi_wr_next_state;
    enum logic [2:0] {RD_WAIT_ADDR, RD_READ_ADDR, RD_WAIT_DATA, RD_DRIVE_RDY, RD_READ_DATA}   axi_rd_state, axi_rd_next_state;

    // FSM state, sequential logic
    always_ff@(posedge axi_aclk or negedge axi_aresetn)begin
        if(~axi_aresetn)begin
            axi_wr_state <= WR_WAIT_ADDR;
            axi_rd_state <= RD_WAIT_ADDR;
        end
        else begin
            axi_wr_state <= axi_wr_next_state;
            axi_rd_state <= axi_rd_next_state;
        end
    end

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
                    axi_wr_next_state = WR_WAIT_DATA;
                end
            WR_WAIT_DATA:
                if(wr_data_go)begin
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

    // FSM state, combinational logic, output control
    always_comb begin
        axi_awvalid = 1'b0;
        axi_awaddr = 12'b0;
        axi_wvalid = 1'b0;
        axi_wdata = 32'b0;
        axi_wstrb = 4'b0;

        case(axi_wr_state)
            //WR_WAIT_ADDR: // do nothing
            WR_WRITE_ADDR:begin
                axi_awvalid = 1'b1;
                axi_awaddr = wr_addr_to_send;
            end
            //WR_WAIT_DATA: // do nothing
            WR_WRITE_DATA:begin
                axi_wvalid = 1'b1;
                axi_wdata = wr_data_to_send;
                axi_wstrb = 4'hf;
            end
            //default:
        endcase
    end

    // FSM state, combinational logic
    always_comb begin
        axi_rd_next_state = axi_rd_state;

        case(axi_rd_state)
            RD_WAIT_ADDR:
                if(rd_addr_go)begin
                    axi_rd_next_state = RD_READ_ADDR;
                end
            RD_READ_ADDR:
                if(axi_arvalid && axi_arready)begin
                    axi_rd_next_state = RD_WAIT_DATA;
                end
            RD_WAIT_DATA:
                if(rd_data_go)begin
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

    // FSM state, combinational logic, output control
    always_comb begin
        axi_arvalid = 1'b0;
        axi_araddr = 12'b0;
        axi_rready = 1'b0;
        //rd_data_to_receive = 32'b0;

        case(axi_rd_state)
            //RD_WAIT_ADDR: // do nothing
            RD_READ_ADDR:begin
                axi_arvalid = 1'b1;
                axi_araddr = rd_addr_to_send;
            end
            //RD_WAIT_DATA: // do nothing
            RD_DRIVE_RDY:begin
                axi_rready = 1'b1;
            end
            RD_READ_DATA:begin
                axi_rready = 1'b0;
                //rd_data_to_receive = axi_rdata;
            end
            //default:
        endcase
    end

    // FSM state, sequential logic, input capture
    always_ff@(posedge axi_aclk or negedge axi_aresetn)begin
        if(~axi_aresetn)begin
            rd_data_to_receive <= 32'h0;
        end
        else if(axi_rd_next_state == RD_READ_DATA)begin
            rd_data_to_receive = axi_rdata;
        end
    end

endmodule


