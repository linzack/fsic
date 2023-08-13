module axi_fifo#(WIDTH=8'h8, DEPTH=8'h8)(
    input wire clk,
    input wire rst_n,
    input wire wr_vld,
    input wire rd_rdy,
    input wire hack, // ???????????????
    input wire clear,
    input wire [WIDTH - 1:0] data_in,
    output logic [WIDTH - 1:0] data_out,
    output logic wr_rdy,
    output logic rd_vld,
    output logic last
);

    logic [WIDTH - 1:0] fifo [DEPTH - 1:0];
    logic [7:0] wr_pointer, rd_pointer;
    logic [7:0] wr_count, rd_count, wr_count_pre;
    logic empty, full, sync_rd_vld;

    // pointer and water level, use valid and ready to handshake
    always_ff@(posedge clk or negedge rst_n)begin
        if(~rst_n)begin
            wr_pointer <= 8'h0;
            rd_pointer <= 8'h0;
            wr_count <= 8'h0;
            rd_count <= 8'h0;
            wr_count_pre <= 8'h0;
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
        //wr_rdy = 1'b0;
        //rd_vld = 1'b0;

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