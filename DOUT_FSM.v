`timescale 1ns/1ps
`default_nettype none

module DOUT_FSM (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_grant_vld,
    input  wire [7:0]  i_grant,

    // Source 0 occupies i_data[7:0], source 7 occupies i_data[63:56].
    input  wire [63:0] i_data,
    input  wire [7:0]  i_sop,
    input  wire [7:0]  i_eop,
    input  wire [7:0]  i_qos,
    input  wire [7:0]  i_data_vld,

    output wire        o_schedule_en,
    output reg  [7:0]  o_rd_en,

    output reg  [7:0]  o_pkt_data,
    output reg         o_pkt_sop,
    output reg         o_pkt_eop,
    output reg         o_pkt_qos,
    output reg  [2:0]  o_pkt_id,
    output reg         o_pkt_vld
);

    localparam DOUT_IDLE = 1'b0;
    localparam DOUT_SEND = 1'b1;

    reg       dout_state;
    reg [2:0] active_id;
    reg [2:0] grant_id;

    reg [2:0] selected_id;
    reg       selected_en;
    reg [7:0] selected_data;
    reg       selected_sop;
    reg       selected_eop;
    reg       selected_qos;
    reg       selected_vld;

    assign o_schedule_en = (dout_state == DOUT_IDLE);

    // ARB_RR guarantees one-hot grant. Exact decoding avoids a general-purpose
    // priority encoder on the registered active-source path.
    always @(*) begin
        case (i_grant)
            8'b0000_0001: grant_id = 3'd0;
            8'b0000_0010: grant_id = 3'd1;
            8'b0000_0100: grant_id = 3'd2;
            8'b0000_1000: grant_id = 3'd3;
            8'b0001_0000: grant_id = 3'd4;
            8'b0010_0000: grant_id = 3'd5;
            8'b0100_0000: grant_id = 3'd6;
            8'b1000_0000: grant_id = 3'd7;
            default:      grant_id = 3'd0;
        endcase
    end

    // A new grant is used combinationally on the SOP cycle. After that edge,
    // active_id holds the same source until its EOP is transferred.
    always @(*) begin
        if (dout_state == DOUT_SEND) begin
            selected_id = active_id;
            selected_en = 1'b1;
        end
        else begin
            selected_id = grant_id;
            selected_en = i_grant_vld;
        end
    end

    // Eight-to-one source mux.
    always @(*) begin
        selected_data = 8'd0;
        selected_sop  = 1'b0;
        selected_eop  = 1'b0;
        selected_qos  = 1'b0;
        selected_vld  = 1'b0;

        case (selected_id)
            3'd0: begin
                selected_data = i_data[7:0];
                selected_sop  = i_sop[0];
                selected_eop  = i_eop[0];
                selected_qos  = i_qos[0];
                selected_vld  = i_data_vld[0];
            end
            3'd1: begin
                selected_data = i_data[15:8];
                selected_sop  = i_sop[1];
                selected_eop  = i_eop[1];
                selected_qos  = i_qos[1];
                selected_vld  = i_data_vld[1];
            end
            3'd2: begin
                selected_data = i_data[23:16];
                selected_sop  = i_sop[2];
                selected_eop  = i_eop[2];
                selected_qos  = i_qos[2];
                selected_vld  = i_data_vld[2];
            end
            3'd3: begin
                selected_data = i_data[31:24];
                selected_sop  = i_sop[3];
                selected_eop  = i_eop[3];
                selected_qos  = i_qos[3];
                selected_vld  = i_data_vld[3];
            end
            3'd4: begin
                selected_data = i_data[39:32];
                selected_sop  = i_sop[4];
                selected_eop  = i_eop[4];
                selected_qos  = i_qos[4];
                selected_vld  = i_data_vld[4];
            end
            3'd5: begin
                selected_data = i_data[47:40];
                selected_sop  = i_sop[5];
                selected_eop  = i_eop[5];
                selected_qos  = i_qos[5];
                selected_vld  = i_data_vld[5];
            end
            3'd6: begin
                selected_data = i_data[55:48];
                selected_sop  = i_sop[6];
                selected_eop  = i_eop[6];
                selected_qos  = i_qos[6];
                selected_vld  = i_data_vld[6];
            end
            default: begin
                selected_data = i_data[63:56];
                selected_sop  = i_sop[7];
                selected_eop  = i_eop[7];
                selected_qos  = i_qos[7];
                selected_vld  = i_data_vld[7];
            end
        endcase
    end

    // Read authorization is asserted on the grant cycle itself and then held
    // for the complete packet. PKT_INGRESS converts this into fifo_pop.
    always @(*) begin
        if (dout_state == DOUT_SEND)
            o_rd_en = 8'b0000_0001 << active_id;
        else if (i_grant_vld)
            o_rd_en = i_grant;
        else
            o_rd_en = 8'd0;
    end

    always @(*) begin
        o_pkt_data = selected_en ? selected_data : 8'd0;
        o_pkt_sop  = selected_en && selected_sop;
        o_pkt_eop  = selected_en && selected_eop;
        o_pkt_qos  = selected_en && selected_qos;
        o_pkt_id   = selected_en ? selected_id : 3'd0;
        o_pkt_vld  = selected_en && selected_vld;
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            dout_state <= DOUT_IDLE;
        end
        else begin
            case (dout_state)
                DOUT_IDLE: begin
                    if (i_grant_vld && selected_vld) begin
                        if (!selected_eop)
                            dout_state <= DOUT_SEND;
                    end
                end

                DOUT_SEND: begin
                    if (selected_vld && selected_eop)
                        dout_state <= DOUT_IDLE;
                end

                default: begin
                    dout_state <= DOUT_IDLE;
                end
            endcase
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            active_id <= 3'd0;
        end
        else begin
            case (dout_state)
                DOUT_IDLE: begin
                    if (i_grant_vld && selected_vld)
                        active_id <= grant_id;
                end

                DOUT_SEND: begin
                    active_id <= active_id;
                end

                default: begin
                    active_id <= 3'd0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
