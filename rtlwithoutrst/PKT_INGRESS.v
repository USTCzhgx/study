`timescale 1ns/1ps
`default_nettype none

module PKT_INGRESS (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [12:0] global_timestamp,

    input  wire [7:0]  din_data,
    input  wire        din_sop,
    input  wire        din_eop,
    input  wire        din_qos,
    input  wire [2:0]  din_id,

    input  wire [7:0]  rd_en_from_egress,

    output wire [7:0]  ready_to_egress,
    output wire [7:0]  data_to_egress,
    output wire        sop_to_egress,
    output wire        eop_to_egress,
    output wire        qos_to_egress,
    output wire        data_vld_to_egress,

    output wire        pkt_error
);

    localparam [1:0] INFO_ID2 = 2'd0;
    localparam [1:0] INFO_ID1 = 2'd1;
    localparam [1:0] INFO_ID0 = 2'd2;
    localparam [1:0] INFO_EOP = 2'd3;

    // ------------------------------------------------------------------
    // Input filtering
    // ------------------------------------------------------------------

    wire wr_en;
    wire pkt_commit;
    wire wr_packet_active;

    DIN_FLT u_din_flt (
        .clk        (clk),
        .rst_n      (rst_n),
        .din_sop    (din_sop),
        .din_eop    (din_eop),
        .wr_en      (wr_en),
        .pkt_commit (pkt_commit),
        .pkt_error  (pkt_error),
        .packet_active (wr_packet_active)
    );

    // ------------------------------------------------------------------
    // Shared status and pointer signals
    // ------------------------------------------------------------------

    wire [9:0] rd_addr_h;
    wire [9:0] rd_addr_l;
    wire [9:0] wr_addr_last_h;
    wire [9:0] wr_addr_last_l;
    wire [9:0] tp_s_addr_h;
    wire [9:0] tp_s_addr_l;
    wire [9:0] old_end_addr_h;
    wire [9:0] old_end_addr_l;

    wire       jump_busy;
    wire       old_fetch_done;
    wire       rd_mem_empty;
    wire       pf_empty;
    wire       rd_empty;

    assign rd_empty = rd_mem_empty && pf_empty;

    // ------------------------------------------------------------------
    // Global 8192-cycle window and force-drain control
    // ------------------------------------------------------------------

    reg  [12:0] window_base;
    reg         window_active;
    reg         force_drain;
    reg         drain_wait_wr_packet;
    reg         empty_d1;

    wire window_tick;
    wire jump_pulse;
    wire ptr_reset;
    wire force_drain_done;

    // The timestamp is global and modulo 8192. Capturing its value on the
    // first accepted byte makes equality recur exactly 8192 clocks later.
    assign window_tick = window_active &&
                         (global_timestamp == window_base);

    assign jump_pulse = window_tick       &&
                        !force_drain       &&
                        !jump_busy         &&
                        (!rd_empty || wr_packet_active || wr_en);

    // Reset physical pointers only after all committed data and all prefetched
    // state are empty. Never reset on a write or during force drain.
    assign ptr_reset = rd_empty          &&
                       !force_drain       &&
                       !wr_packet_active &&
                       !wr_en            &&
                       !empty_d1;

    always @(posedge clk) begin
        if (!window_active && wr_en) begin
            window_base <= global_timestamp;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_active <= 1'b0;
        end
        else if (ptr_reset) begin
            window_active <= 1'b0;
        end
        else if (!window_active && wr_en) begin
            window_active <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            empty_d1 <= 1'b0;
        else
            empty_d1 <= rd_empty && !wr_packet_active;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            force_drain <= 1'b0;
        else if (ptr_reset)
            force_drain <= 1'b0;
        else if (jump_pulse)
            force_drain <= 1'b1;
        else if (force_drain_done)
            force_drain <= 1'b0;
    end

    // A packet already in progress at jump_pulse belongs to the old window,
    // including the portion written after the physical discontinuity.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drain_wait_wr_packet <= 1'b0;
        end
        else if (ptr_reset) begin
            drain_wait_wr_packet <= 1'b0;
        end
        else if (jump_pulse) begin
            drain_wait_wr_packet <= wr_packet_active &&
                                    !pkt_error &&
                                    !(pkt_commit && wr_en);
        end
        else if (pkt_error || (pkt_commit && wr_en)) begin
            drain_wait_wr_packet <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Fixed, far-side jump target
    // ------------------------------------------------------------------

    wire       rd_both_mid;
    reg        jump_outer_hold;
    wire       jump_outer;
    wire [9:0] tp_e_addr_h;
    wire [9:0] tp_e_addr_l;

    // XOR is one for address quadrants 01 and 10 (256 through 767). If both
    // read pointers are in that middle region, jump to the outer endpoints;
    // otherwise jump to the middle pair.
    assign rd_both_mid = (^rd_addr_h[9:8]) && (^rd_addr_l[9:8]);

    // WR_CTRL must see the newly selected target on the jump edge itself.
    // Afterwards the held values remain stable until the next jump, because
    // RD_CTRL may need them for many cycles while draining the old window.
    assign jump_outer = jump_pulse ? rd_both_mid : jump_outer_hold;
    assign tp_e_addr_h = {jump_outer, 9'h1ff};
    assign tp_e_addr_l = {!jump_outer, 9'h000};

    always @(posedge clk) begin
        if (jump_pulse) begin
            jump_outer_hold <= rd_both_mid;
        end
    end

    // ------------------------------------------------------------------
    // Write control and RF information-bit packing
    // ------------------------------------------------------------------

    wire [9:0] mem_wr_addr;
    reg  [1:0] wr_info_pos;
    reg  [1:0] wr_packet_id;
    reg        mem_wr_info;
    wire [8:0] mem_wr_data;

    // The first three bit[8] values contain destination ID[2:0]. Starting
    // with byte four, bit[8] is the packet EOP marker.
    always @(*) begin
        if (pkt_error && wr_en) begin
            mem_wr_info = din_id[2];
        end
        else begin
            case (wr_info_pos)
                INFO_ID2: mem_wr_info = din_id[2];
                INFO_ID1: mem_wr_info = wr_packet_id[1];
                INFO_ID0: mem_wr_info = wr_packet_id[0];
                default:  mem_wr_info = din_eop;
            endcase
        end
    end

    assign mem_wr_data = {mem_wr_info, din_data};

    always @(posedge clk) begin
        if (wr_en && din_sop) begin
            wr_packet_id <= din_id[1:0];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_info_pos <= INFO_ID2;
        end
        else if (ptr_reset) begin
            wr_info_pos <= INFO_ID2;
        end
        else if (pkt_error) begin
            wr_info_pos <= wr_en ? INFO_ID1 : INFO_ID2;
        end
        else if (pkt_commit && wr_en) begin
            wr_info_pos <= INFO_ID2;
        end
        else if (wr_en) begin
            case (wr_info_pos)
                INFO_ID2: wr_info_pos <= INFO_ID1;
                INFO_ID1: wr_info_pos <= INFO_ID0;
                default:  wr_info_pos <= INFO_EOP;
            endcase
        end
    end

    WR_CTRL u_wr_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .pkt_commit     (pkt_commit),
        .pkt_error      (pkt_error),
        .qos            (din_qos),
        .jump_pulse     (jump_pulse),
        .ptr_reset      (ptr_reset),
        .tp_e_addr_h    (tp_e_addr_h),
        .tp_e_addr_l    (tp_e_addr_l),
        .mem_wr_addr    (mem_wr_addr),
        .wr_addr_last_h (wr_addr_last_h),
        .wr_addr_last_l (wr_addr_last_l),
        .tp_s_addr_h    (tp_s_addr_h),
        .tp_s_addr_l    (tp_s_addr_l),
        .old_end_addr_h (old_end_addr_h),
        .old_end_addr_l (old_end_addr_l)
    );

    // ------------------------------------------------------------------
    // Read-pointer control
    // ------------------------------------------------------------------

    wire       fetch_en;
    wire       fetch_qos;
    wire       ram_rd_en;
    wire [9:0] ram_rd_addr;
    wire       fetch_vld_h;
    wire       fetch_vld_l;

    RD_CTRL u_rd_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .force_drain    (force_drain),
        .jump_pulse     (jump_pulse),
        .ptr_reset      (ptr_reset),
        .fetch_en       (fetch_en),
        .fetch_qos      (fetch_qos),
        .wr_addr_last_h (wr_addr_last_h),
        .wr_addr_last_l (wr_addr_last_l),
        .old_end_addr_h (old_end_addr_h),
        .old_end_addr_l (old_end_addr_l),
        .tp_s_addr_h    (tp_s_addr_h),
        .tp_s_addr_l    (tp_s_addr_l),
        .tp_e_addr_h    (tp_e_addr_h),
        .tp_e_addr_l    (tp_e_addr_l),
        .rd_addr_h      (rd_addr_h),
        .rd_addr_l      (rd_addr_l),
        .ram_rd_en      (ram_rd_en),
        .ram_rd_addr    (ram_rd_addr),
        .fetch_vld_h    (fetch_vld_h),
        .fetch_vld_l    (fetch_vld_l),
        .jump_busy      (jump_busy),
        .old_fetch_done (old_fetch_done),
        .rd_mem_empty   (rd_mem_empty)
    );

    // ------------------------------------------------------------------
    // One 1024 x 9 RF memory
    // ------------------------------------------------------------------

    wire [8:0] ram_rd_data;

    RF_MEM u_rf_mem (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_addr (mem_wr_addr),
        .wr_data (mem_wr_data),
        .wr_en   (wr_en),
        .rd_en   (ram_rd_en),
        .rd_addr (ram_rd_addr),
        .rd_data (ram_rd_data)
    );

    // ------------------------------------------------------------------
    // Four-word look-ahead and egress protocol
    // ------------------------------------------------------------------

    PF_CTRL u_pf_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),
        .ptr_reset          (ptr_reset),
        .jump_pulse         (jump_pulse),
        .fetch_vld_h        (fetch_vld_h),
        .fetch_vld_l        (fetch_vld_l),
        .fetch_en           (fetch_en),
        .fetch_qos          (fetch_qos),
        .ram_rd_en          (ram_rd_en),
        .ram_rd_data        (ram_rd_data),
        .rd_en_from_egress  (rd_en_from_egress),
        .ready_to_egress    (ready_to_egress),
        .data_to_egress     (data_to_egress),
        .sop_to_egress      (sop_to_egress),
        .eop_to_egress      (eop_to_egress),
        .qos_to_egress      (qos_to_egress),
        .data_vld_to_egress (data_vld_to_egress),
        .pf_empty           (pf_empty)
    );

    assign force_drain_done = force_drain           &&
                              old_fetch_done        &&
                              !drain_wait_wr_packet &&
                              pf_empty;

endmodule

`default_nettype wire
