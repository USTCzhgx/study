`timescale 1ns/1ps
`default_nettype none

// RF memory look-ahead and packet scheduling control.
//
// RD_CTRL owns only the physical read pointers.  PF_CTRL owns the RF response
// holding register, the three explicit look-ahead entries, destination-ID
// reconstruction and the request/consume protocol toward PKT_EGRESS.
module PF_CTRL (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ptr_reset,
    input  wire       jump_pulse,

    input  wire       fetch_vld_h,
    input  wire       fetch_vld_l,
    output wire       fetch_en,
    output wire       fetch_qos,

    input  wire       ram_rd_en,
    input  wire [8:0] ram_rd_data,

    input  wire [7:0] rd_en_from_egress,

    output wire [7:0] ready_to_egress,
    output wire [7:0] data_to_egress,
    output wire       sop_to_egress,
    output wire       eop_to_egress,
    output wire       qos_to_egress,
    output wire       data_vld_to_egress,

    output wire       pf_empty
);

    localparam [1:0] INFO_ID2 = 2'd0;
    localparam [1:0] INFO_ID1 = 2'd1;
    localparam [1:0] INFO_ID0 = 2'd2;
    localparam [1:0] INFO_EOP = 2'd3;

    // ------------------------------------------------------------------
    // One RF-response holding entry
    // ------------------------------------------------------------------

    reg  ram_rd_pending; //ram_rd_data has a valid data
    wire response_push;
    wire response_slot_available;

/*
response_slot = {
    ram_rd_pending,
    ram_rd_data[8:0]
};
*/

    assign response_slot_available = !ram_rd_pending || response_push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_rd_pending <= 1'b0;
        end
        else if (ptr_reset) begin
            ram_rd_pending <= 1'b0;
        end
        else begin
            case ({ram_rd_en, response_push})
                2'b10,
                2'b11:   ram_rd_pending <= 1'b1;
                2'b01:   ram_rd_pending <= 1'b0;
                default: ram_rd_pending <= ram_rd_pending;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Three explicit look-ahead entries
    // ------------------------------------------------------------------

    reg [8:0] data_fifo [0:2];

    reg [1:0] fifo_wr_ptr;
    reg [1:0] fifo_rd_ptr;
    reg [1:0] fifo_count;

    wire [1:0] fifo_wr_ptr_inc;
    wire [1:0] fifo_rd_ptr_inc;
    wire       fifo_empty;
    wire       fifo_pop;
    wire       fifo_pop_eop;
    wire       fifo_space_for_response;
    reg  [8:0] fifo_head_data;

    assign fifo_wr_ptr_inc = (fifo_wr_ptr == 2'd2) ?
                             2'd0 : fifo_wr_ptr + 2'd1;
    assign fifo_rd_ptr_inc = (fifo_rd_ptr == 2'd2) ?
                             2'd0 : fifo_rd_ptr + 2'd1;

    assign fifo_empty = (fifo_count == 2'd0);

    always @(*) begin
        case (fifo_rd_ptr)
            2'd0:    fifo_head_data = data_fifo[0];
            2'd1:    fifo_head_data = data_fifo[1];
            2'd2:    fifo_head_data = data_fifo[2];
            default: fifo_head_data = 9'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // RF information-bit decoding and queue selection
    // ------------------------------------------------------------------

    reg  [1:0] fetch_info_pos;
    // Only the first two destination bits need storage.  The third bit is
    // consumed directly from the current RF response.
    reg  [1:0] assembling_id;
    wire       fetch_packet_active;
    reg        fetch_qos_lock;

    reg        fetch_qos_comb;
    reg        fetch_candidate_vld;

    wire       response_eop;
    wire       response_id_complete;
    wire       fetch_packet_start;
    wire [2:0] completed_id;
    wire       completed_qos;

    assign response_eop = response_push &&
                          (fetch_info_pos == INFO_EOP) &&
                          ram_rd_data[8];
    assign response_id_complete = response_push &&
                                  (fetch_info_pos == INFO_ID0);
    assign completed_id = {assembling_id, ram_rd_data[8]};
    assign completed_qos = fetch_qos_lock;

    // Before the first response is pushed, ram_rd_pending identifies the
    // outstanding first word.  Afterwards fetch_info_pos identifies that the
    // parser is inside the packet.  No separate active-state register is
    // required.
    assign fetch_packet_active = (fetch_info_pos != INFO_ID2) ||
                                 ram_rd_pending;

    assign fetch_packet_start = ram_rd_en &&
                                (!fetch_packet_active || response_eop);

    // QoS is chosen only at a packet boundary.  Once a low-QoS packet has
    // started prefetching, a later high-QoS commit cannot preempt it.
    always @(*) begin
        fetch_qos_comb      = fetch_qos_lock;
        fetch_candidate_vld = 1'b0;

        if (fetch_packet_active && !response_eop) begin
            fetch_qos_comb      = fetch_qos_lock;
            fetch_candidate_vld = fetch_qos_lock ? fetch_vld_h :
                                                   fetch_vld_l;
        end
        else if (fetch_vld_h) begin
            fetch_qos_comb      = 1'b1;
            fetch_candidate_vld = 1'b1;
        end
        else if (fetch_vld_l) begin
            fetch_qos_comb      = 1'b0;
            fetch_candidate_vld = 1'b1;
        end
    end

    assign fetch_qos = fetch_qos_comb;

    // No request is launched on a jump cycle.  RD_CTRL registers tp_s/tp_e
    // on that edge and uses the new mapping beginning on the following cycle.
    assign fetch_en = rst_n                   &&
                      !ptr_reset              &&
                      !jump_pulse             &&
                      response_slot_available &&
                      fetch_candidate_vld;

    // Data context is overwritten before it becomes valid, so it does not
    // need a resettable storage cell.
    always @(posedge clk) begin
        if (fetch_packet_start) begin
            fetch_qos_lock <= fetch_qos;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_info_pos <= INFO_ID2;
        end
        else if (ptr_reset) begin
            fetch_info_pos <= INFO_ID2;
        end
        else if (response_push) begin
            case (fetch_info_pos)
                INFO_ID2: begin
                    fetch_info_pos <= INFO_ID1;
                end
                INFO_ID1: begin
                    fetch_info_pos <= INFO_ID0;
                end
                INFO_ID0: begin
                    fetch_info_pos <= INFO_EOP;
                end
                default: begin
                    if (ram_rd_data[8]) begin
                        fetch_info_pos <= INFO_ID2;
                    end
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (response_push) begin
            case (fetch_info_pos)
                INFO_ID2: begin
                    assembling_id[1] <= ram_rd_data[8];
                end
                INFO_ID1: begin
                    assembling_id[0] <= ram_rd_data[8];
                end
                default: assembling_id <= assembling_id;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Packet destination contexts and combinational-RR interface
    // ------------------------------------------------------------------

    reg [2:0] current_pkt_id;
    reg       current_pkt_qos;
    reg       current_pkt_valid;
    reg [1:0] output_info_pos;

    wire [7:0] current_pkt_onehot;
    wire       current_grant;
    wire       fifo_head_eop;

    assign current_pkt_onehot = 8'b0000_0001 << current_pkt_id;

    assign current_grant = |(rd_en_from_egress & current_pkt_onehot);
    assign fifo_pop = current_pkt_valid && current_grant && !fifo_empty;
    assign fifo_head_eop = (output_info_pos == INFO_EOP) &&
                           fifo_head_data[8];
    assign fifo_pop_eop = fifo_pop && fifo_head_eop;

    //avoid comb loop
    assign ready_to_egress = (current_pkt_valid &&
                              (output_info_pos == INFO_ID2)) ?
                             current_pkt_onehot : 8'd0;

    always @(posedge clk) begin
        if (response_id_complete) begin
            current_pkt_id  <= completed_id;
            current_pkt_qos <= completed_qos;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pkt_valid <= 1'b0;
        end
        else if (ptr_reset) begin
            current_pkt_valid <= 1'b0;
        end
        else if (response_id_complete) begin
            current_pkt_valid <= 1'b1;
        end
        else if (fifo_pop_eop) begin
            current_pkt_valid <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // FIFO update and output
    // ------------------------------------------------------------------

    assign fifo_space_for_response = (fifo_count < 2'd3) || fifo_pop;
    assign response_push = ram_rd_pending && fifo_space_for_response;

    always @(posedge clk) begin
        if (!ptr_reset && response_push) begin
            data_fifo[fifo_wr_ptr] <= ram_rd_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= 2'd0;
        end
        else if (ptr_reset) begin
            fifo_wr_ptr <= 2'd0;
        end
        else if (response_push) begin
            fifo_wr_ptr <= fifo_wr_ptr_inc;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_ptr <= 2'd0;
        end
        else if (ptr_reset) begin
            fifo_rd_ptr <= 2'd0;
        end
        else if (fifo_pop) begin
            fifo_rd_ptr <= fifo_rd_ptr_inc;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_info_pos <= INFO_ID2;
        end
        else if (ptr_reset) begin
            output_info_pos <= INFO_ID2;
        end
        else if (fifo_pop) begin
            case (output_info_pos)
                INFO_ID2: output_info_pos <= INFO_ID1;
                INFO_ID1: output_info_pos <= INFO_ID0;
                INFO_ID0: output_info_pos <= INFO_EOP;
                default: begin
                    if (fifo_head_data[8]) begin
                        output_info_pos <= INFO_ID2;
                    end
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_count <= 2'd0;
        end
        else if (ptr_reset) begin
            fifo_count <= 2'd0;
        end
        else begin
            case ({response_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 2'd1;
                2'b01:   fifo_count <= fifo_count - 2'd1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    assign data_to_egress     = fifo_empty ? 8'd0 :
                                             fifo_head_data[7:0];
    assign sop_to_egress      = !fifo_empty &&
                                (output_info_pos == INFO_ID2);
    assign eop_to_egress      = !fifo_empty && fifo_head_eop;
    assign qos_to_egress      = !fifo_empty && current_pkt_qos;
    assign data_vld_to_egress = fifo_pop;

    assign pf_empty = fifo_empty             &&
                      !ram_rd_pending         &&
                      !current_pkt_valid;

endmodule

`default_nettype wire
