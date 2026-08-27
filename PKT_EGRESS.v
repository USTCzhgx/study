`timescale 1ns/1ps
`default_nettype none

module PKT_EGRESS (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // One request bit and one data lane from each of the eight PKT_INGRESSes.
    input  wire [7:0]  i_ready,
    input  wire [63:0] i_data,
    input  wire [7:0]  i_sop,
    input  wire [7:0]  i_eop,
    input  wire [7:0]  i_qos,
    input  wire [7:0]  i_data_vld,

    // One-hot read authorization returned to the eight PKT_INGRESSes.
    output wire [7:0]  o_rd_en,

    output wire [7:0]  o_pkt_data,
    output wire        o_pkt_sop,
    output wire        o_pkt_eop,
    output wire        o_pkt_qos,
    output wire [2:0]  o_pkt_id,
    output wire        o_pkt_vld
);

    wire       schedule_en;
    wire       grant_vld;
    wire [7:0] grant;

    ARB_RR u_arb_rr (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_ready       (i_ready),
        .i_schedule_en (schedule_en),
        .o_grant_vld   (grant_vld),
        .o_grant       (grant)
    );

    DOUT_FSM u_dout_fsm (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_grant_vld  (grant_vld),
        .i_grant      (grant),
        .i_data       (i_data),
        .i_sop        (i_sop),
        .i_eop        (i_eop),
        .i_qos        (i_qos),
        .i_data_vld   (i_data_vld),
        .o_schedule_en(schedule_en),
        .o_rd_en      (o_rd_en),
        .o_pkt_data   (o_pkt_data),
        .o_pkt_sop    (o_pkt_sop),
        .o_pkt_eop    (o_pkt_eop),
        .o_pkt_qos    (o_pkt_qos),
        .o_pkt_id     (o_pkt_id),
        .o_pkt_vld    (o_pkt_vld)
    );

endmodule

`default_nettype wire
