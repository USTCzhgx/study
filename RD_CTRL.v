`timescale 1ns/1ps

`default_nettype none

module RD_CTRL (
    input  wire       clk,                    ///< Working clock
    input  wire       rst_n,                  ///< Active-low asynchronous reset

    input  wire       force_drain,            ///< Select old-window fetch boundaries
    input  wire       jump_pulse,             ///< One-cycle address-jump event
    input  wire       ptr_reset,              ///< Reset read pointers when RAM is empty

    input  wire       fetch_en,               ///< Request one RAM read and pointer advance
    input  wire       fetch_qos,              ///< Selected queue: 1-high QoS, 0-low QoS

    input  wire [9:0] wr_addr_last_h,         ///< Live high-QoS committed boundary
    input  wire [9:0] wr_addr_last_l,         ///< Live low-QoS committed boundary
    input  wire [9:0] old_end_addr_h,         ///< Old-window high-QoS fetch boundary
    input  wire [9:0] old_end_addr_l,         ///< Old-window low-QoS fetch boundary

    input  wire [9:0] tp_s_addr_h,            ///< High-QoS jump source address
    input  wire [9:0] tp_s_addr_l,            ///< Low-QoS jump source address
    input  wire [9:0] tp_e_addr_h,            ///< High-QoS jump destination address
    input  wire [9:0] tp_e_addr_l,            ///< Low-QoS jump destination address

    output reg  [9:0] rd_addr_h,              ///< High-QoS RAM fetch pointer
    output reg  [9:0] rd_addr_l,              ///< Low-QoS RAM fetch pointer

    output wire       ram_rd_en,              ///< RAM read enable
    output wire [9:0] ram_rd_addr,            ///< Actual RAM read address

    output wire       fetch_vld_h,            ///< High-QoS data are available to fetch
    output wire       fetch_vld_l,            ///< Low-QoS data are available to fetch
    output wire       jump_busy,              ///< At least one QoS read jump is pending
    output wire       old_fetch_done,         ///< All old-window data have been fetched
    output wire       rd_mem_empty             ///< No committed RAM data remain to fetch
);

    reg rd_jump_pending_h;                    ///< High-QoS read jump is pending
    reg rd_jump_pending_l;                    ///< Low-QoS read jump is pending

    wire [9:0] selected_end_addr_h;
    wire [9:0] selected_end_addr_l;

    wire       selected_fetch_vld;
    wire       fetch_fire;
    wire       jump_valid_h;
    wire       jump_valid_l;
    wire       jump_take_h;
    wire       jump_take_l;
    wire       jump_skip_h;
    wire       jump_skip_l;

    // Force-drain mode only exposes data belonging to the old window.
    assign selected_end_addr_h = force_drain ? old_end_addr_h :
                                                wr_addr_last_h;
    assign selected_end_addr_l = force_drain ? old_end_addr_l :
                                                wr_addr_last_l;

    // Consume a jump only after jump_pulse has registered the new tp_s/tp_e
    // metadata. This avoids using the previous mapping on the jump cycle.
    assign jump_valid_h = rd_jump_pending_h;
    assign jump_valid_l = rd_jump_pending_l;

    // If tp_e itself is the selected committed boundary, there is no word at
    // tp_e. Normalize the pointer without issuing a spurious RAM read. This is
    // the usual case for a QoS queue that was empty at the window switch.
    assign jump_skip_h = jump_valid_h                  &&
                         (rd_addr_h == tp_s_addr_h)    &&
                         (tp_e_addr_h == selected_end_addr_h);

    assign jump_skip_l = jump_valid_l                  &&
                         (rd_addr_l == tp_s_addr_l)    &&
                         (tp_e_addr_l == selected_end_addr_l);

    assign fetch_vld_h = (rd_addr_h != selected_end_addr_h) &&
                         !jump_skip_h;
    assign fetch_vld_l = (rd_addr_l != selected_end_addr_l) &&
                         !jump_skip_l;

    assign selected_fetch_vld = fetch_qos ? fetch_vld_h : fetch_vld_l;

    // A request is accepted only when the selected queue has committed data.
    assign fetch_fire = fetch_en && selected_fetch_vld;
    assign ram_rd_en  = fetch_fire;

    assign jump_take_h = fetch_fire                 &&
                         fetch_qos                  &&
                         jump_valid_h               &&
                         (rd_addr_h == tp_s_addr_h);

    assign jump_take_l = fetch_fire                 &&
                         !fetch_qos                 &&
                         jump_valid_l               &&
                         (rd_addr_l == tp_s_addr_l);

    // tp_s is a physical discontinuity and must not be accessed. When a jump
    // is taken, RAM reads tp_e directly on the same accepted fetch request.
    assign ram_rd_addr = fetch_qos ?
                         (jump_take_h ? tp_e_addr_h : rd_addr_h) :
                         (jump_take_l ? tp_e_addr_l : rd_addr_l);

    // Read pointers represent the next RAM locations to be prefetched. They
    // advance on ram_rd_en/fetch_fire, not on an egress-buffer consume event.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_h <= 10'd1023;
            rd_addr_l <= 10'd0;
        end
        else if (ptr_reset) begin
            rd_addr_h <= 10'd1023;
            rd_addr_l <= 10'd0;
        end
        else begin
            if (jump_skip_h) begin
                rd_addr_h <= tp_e_addr_h;
            end
            else if (fetch_fire && fetch_qos) begin
                if (jump_take_h)
                    rd_addr_h <= tp_e_addr_h - 10'd1;
                else
                    rd_addr_h <= rd_addr_h - 10'd1;
            end

            if (jump_skip_l) begin
                rd_addr_l <= tp_e_addr_l;
            end
            else if (fetch_fire && !fetch_qos) begin
                if (jump_take_l)
                    rd_addr_l <= tp_e_addr_l + 10'd1;
                else
                    rd_addr_l <= rd_addr_l + 10'd1;
            end
        end
    end

    // Each queue keeps an independent read-side jump-valid flag. One global
    // jump creates discontinuities for both QoS regions. A flag is cleared only
    // when the corresponding RAM fetch actually traverses tp_s -> tp_e.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_jump_pending_h <= 1'b0;
            rd_jump_pending_l <= 1'b0;
        end
        else if (ptr_reset) begin
            rd_jump_pending_h <= 1'b0;
            rd_jump_pending_l <= 1'b0;
        end
        else begin
            case ({jump_pulse, (jump_take_h || jump_skip_h)})
                2'b10:   rd_jump_pending_h <= 1'b1;
                2'b01,
                2'b11:   rd_jump_pending_h <= 1'b0;
                default: rd_jump_pending_h <= rd_jump_pending_h;
            endcase

            case ({jump_pulse, (jump_take_l || jump_skip_l)})
                2'b10:   rd_jump_pending_l <= 1'b1;
                2'b01,
                2'b11:   rd_jump_pending_l <= 1'b0;
                default: rd_jump_pending_l <= rd_jump_pending_l;
            endcase
        end
    end

    // These are pointer-side status signals only. PKT_INGRESS must additionally
    // check its prefetch FIFO, outstanding RAM response and active packet before
    // generating the final force_drain_done and rd_empty signals.
    assign old_fetch_done = force_drain                    &&
                            (rd_addr_h == old_end_addr_h)   &&
                            (rd_addr_l == old_end_addr_l);

    assign rd_mem_empty = (rd_addr_h == wr_addr_last_h) &&
                          (rd_addr_l == wr_addr_last_l);

    // The owner must not create another physical discontinuity while either
    // QoS queue still depends on the current tp_s/tp_e mapping.
    assign jump_busy = rd_jump_pending_h || rd_jump_pending_l;

endmodule

`default_nettype wire
