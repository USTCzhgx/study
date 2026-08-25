`timescale 1ns/1ps
`default_nettype none

module WR_CTRL (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       wr_en,
    input  wire       pkt_commit,
    input  wire       pkt_error,
    input  wire       qos,

    // One-cycle event generated centrally by RAM_CTRL.
    input  wire       jump_pulse,

    // ptr_reset is only legal when there is no RAM write and no half packet.
    input  wire       ptr_reset,

    input  wire [9:0] tp_e_addr_h,
    input  wire [9:0] tp_e_addr_l,

    output wire [9:0] mem_wr_addr,

    // Live committed boundaries. New-window commits may keep moving them.
    output reg  [9:0] wr_addr_last_h,
    output reg  [9:0] wr_addr_last_l,

    // Physical discontinuity created by the latest window jump.
    output reg  [9:0] tp_s_addr_h,
    output reg  [9:0] tp_s_addr_l,

    // Frozen boundaries of the old generation being force-drained.
    output reg  [9:0] old_end_addr_h,
    output reg  [9:0] old_end_addr_l
);

    localparam [1:0] WR_IDLE = 2'b00;
    localparam [1:0] WR_LOW  = 2'b01;
    localparam [1:0] WR_HIGH = 2'b10;

    reg [1:0] wr_state;
    reg [1:0] wr_state_next;

    // Next free physical addresses. These are deliberately internal because
    // mem_wr_addr is the only write address consumed by RF_MEM.
    reg [9:0] wr_addr_h;
    reg [9:0] wr_addr_l;
    reg [9:0] wr_addr_h_next;
    reg [9:0] wr_addr_l_next;

    reg [9:0] wr_addr_last_h_next;
    reg [9:0] wr_addr_last_l_next;
    reg [9:0] tp_s_addr_h_next;
    reg [9:0] tp_s_addr_l_next;
    reg [9:0] old_end_addr_h_next;
    reg [9:0] old_end_addr_l_next;

    // Only tracks whether the currently uncommitted packet spans tp_s->tp_e.
    // It is cleared on commit/error and is not the RD-side jump-valid state.
    reg cross_jump;
    reg cross_jump_next;

    wire packet_active;
    wire packet_qos;
    wire write_qos;

    assign packet_active = (wr_state != WR_IDLE);
    assign packet_qos    = (wr_state == WR_HIGH);

    // A repeated SOP aborts the old packet and starts a new one on the same
    // beat, so that beat uses the external QoS. All other active-packet beats
    // use the QoS captured in wr_state.
    assign write_qos = (!packet_active || (pkt_error && wr_en)) ?
                       qos : packet_qos;

    // The jump has highest priority: a valid beat on the jump cycle belongs to
    // the new physical region and is written directly at tp_e.
    assign mem_wr_addr = jump_pulse ?
                         (write_qos ? tp_e_addr_h : tp_e_addr_l) :
                         ((pkt_error && wr_en) ?
                          ((cross_jump && (write_qos == packet_qos)) ?
                           (write_qos ? tp_e_addr_h : tp_e_addr_l) :
                           (write_qos ? wr_addr_last_h :
                                        wr_addr_last_l)) :
                          (write_qos ? wr_addr_h : wr_addr_l));

    always @(*) begin
        wr_state_next          = wr_state;
        wr_addr_h_next         = wr_addr_h;
        wr_addr_l_next         = wr_addr_l;
        wr_addr_last_h_next    = wr_addr_last_h;
        wr_addr_last_l_next    = wr_addr_last_l;
        tp_s_addr_h_next       = tp_s_addr_h;
        tp_s_addr_l_next       = tp_s_addr_l;
        old_end_addr_h_next    = old_end_addr_h;
        old_end_addr_l_next    = old_end_addr_l;
        cross_jump_next        = cross_jump;

        if (jump_pulse) begin
            // The current valid beat is written at tp_e. Therefore tp_s is the
            // old-region next-free address before processing this beat.
            tp_s_addr_h_next    = wr_addr_h;
            tp_s_addr_l_next    = wr_addr_l;

            // Freeze the old generation. A crossing packet may extend one of
            // these boundaries into the new region only when it later commits.
            old_end_addr_h_next = wr_addr_last_h;
            old_end_addr_l_next = wr_addr_last_l;

            // Both new-generation queues start empty at the selected pair.
            wr_addr_h_next      = tp_e_addr_h;
            wr_addr_l_next      = tp_e_addr_l;
            wr_addr_last_h_next = tp_e_addr_h;
            wr_addr_last_l_next = tp_e_addr_l;
            wr_state_next       = WR_IDLE;
            cross_jump_next     = 1'b0;

            if (pkt_error) begin
                // The old half packet is invalid. Move its old-window end back
                // to its committed boundary; a repeated SOP starts a completely
                // new packet at tp_e on this same cycle.
                if (wr_state == WR_LOW)
                    tp_s_addr_l_next = wr_addr_last_l;
                else if (wr_state == WR_HIGH)
                    tp_s_addr_h_next = wr_addr_last_h;

                if (wr_en) begin
                    if (qos) begin
                        wr_addr_h_next = tp_e_addr_h - 10'd1;
                        wr_state_next  = WR_HIGH;
                    end
                    else begin
                        wr_addr_l_next = tp_e_addr_l + 10'd1;
                        wr_state_next  = WR_LOW;
                    end
                end
            end
            else if (wr_state == WR_LOW) begin
                // The old low-QoS packet crosses the physical discontinuity.
                // Keep its old committed boundary as the rollback anchor until
                // a legal EOP arrives.
                wr_addr_last_l_next = wr_addr_last_l;
                wr_addr_l_next      = wr_en ?
                                      (tp_e_addr_l + 10'd1) : tp_e_addr_l;

                if (pkt_commit && wr_en) begin
                    wr_addr_last_l_next = tp_e_addr_l + 10'd1;
                    old_end_addr_l_next = tp_e_addr_l + 10'd1;
                    wr_state_next       = WR_IDLE;
                    cross_jump_next     = 1'b0;
                end
                else begin
                    wr_state_next   = WR_LOW;
                    cross_jump_next = 1'b1;
                end
            end
            else if (wr_state == WR_HIGH) begin
                // High-QoS case is symmetrical to low QoS.
                wr_addr_last_h_next = wr_addr_last_h;
                wr_addr_h_next      = wr_en ?
                                      (tp_e_addr_h - 10'd1) : tp_e_addr_h;

                if (pkt_commit && wr_en) begin
                    wr_addr_last_h_next = tp_e_addr_h - 10'd1;
                    old_end_addr_h_next = tp_e_addr_h - 10'd1;
                    wr_state_next       = WR_IDLE;
                    cross_jump_next     = 1'b0;
                end
                else begin
                    wr_state_next   = WR_HIGH;
                    cross_jump_next = 1'b1;
                end
            end
            else if (wr_en) begin
                // IDLE plus SOP on the jump cycle: the complete new packet is
                // in the new generation and is not a crossing packet.
                if (qos) begin
                    wr_addr_h_next = tp_e_addr_h - 10'd1;
                    wr_state_next  = WR_HIGH;
                end
                else begin
                    wr_addr_l_next = tp_e_addr_l + 10'd1;
                    wr_state_next  = WR_LOW;
                end
            end
        end
        else if (pkt_error) begin
            // Roll back the old invalid packet using its captured QoS.
            if (wr_state == WR_LOW) begin
                if (cross_jump) begin
                    tp_s_addr_l_next    = old_end_addr_l;
                    wr_addr_l_next      = tp_e_addr_l;
                    wr_addr_last_l_next = tp_e_addr_l;
                end
                else begin
                    wr_addr_l_next = wr_addr_last_l;
                end
            end
            else if (wr_state == WR_HIGH) begin
                if (cross_jump) begin
                    tp_s_addr_h_next    = old_end_addr_h;
                    wr_addr_h_next      = tp_e_addr_h;
                    wr_addr_last_h_next = tp_e_addr_h;
                end
                else begin
                    wr_addr_h_next = wr_addr_last_h;
                end
            end

            wr_state_next   = WR_IDLE;
            cross_jump_next = 1'b0;

            // Repeated SOP: the current beat is the first byte of the new
            // packet. mem_wr_addr already selects its rollback/new-region base.
            if (wr_en) begin
                if (qos) begin
                    wr_addr_h_next = mem_wr_addr - 10'd1;
                    wr_state_next  = WR_HIGH;
                end
                else begin
                    wr_addr_l_next = mem_wr_addr + 10'd1;
                    wr_state_next  = WR_LOW;
                end
            end
        end
        else if (pkt_commit && wr_en) begin
            // Legal EOP always advances the pointer selected by the stored
            // packet state, not by a potentially changing external QoS signal.
            if (wr_state == WR_HIGH) begin
                wr_addr_h_next      = wr_addr_h - 10'd1;
                wr_addr_last_h_next = wr_addr_h - 10'd1;

                if (cross_jump)
                    old_end_addr_h_next = wr_addr_h - 10'd1;
            end
            else begin
                wr_addr_l_next      = wr_addr_l + 10'd1;
                wr_addr_last_l_next = wr_addr_l + 10'd1;

                if (cross_jump)
                    old_end_addr_l_next = wr_addr_l + 10'd1;
            end

            wr_state_next   = WR_IDLE;
            cross_jump_next = 1'b0;
        end
        else if (wr_en) begin
            if (wr_state == WR_HIGH) begin
                wr_addr_h_next = wr_addr_h - 10'd1;
            end
            else if (wr_state == WR_LOW) begin
                wr_addr_l_next = wr_addr_l + 10'd1;
            end
            else if (qos) begin
                wr_addr_h_next = wr_addr_h - 10'd1;
                wr_state_next  = WR_HIGH;
            end
            else begin
                wr_addr_l_next = wr_addr_l + 10'd1;
                wr_state_next  = WR_LOW;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state       <= WR_IDLE;
            wr_addr_h      <= 10'd1023;
            wr_addr_l      <= 10'd0;
            wr_addr_last_h <= 10'd1023;
            wr_addr_last_l <= 10'd0;
            tp_s_addr_h    <= 10'd1023;
            tp_s_addr_l    <= 10'd0;
            old_end_addr_h <= 10'd1023;
            old_end_addr_l <= 10'd0;
            cross_jump     <= 1'b0;
        end
        else if (ptr_reset) begin
            wr_state       <= WR_IDLE;
            wr_addr_h      <= 10'd1023;
            wr_addr_l      <= 10'd0;
            wr_addr_last_h <= 10'd1023;
            wr_addr_last_l <= 10'd0;
            tp_s_addr_h    <= 10'd1023;
            tp_s_addr_l    <= 10'd0;
            old_end_addr_h <= 10'd1023;
            old_end_addr_l <= 10'd0;
            cross_jump     <= 1'b0;
        end
        else begin
            wr_state       <= wr_state_next;
            wr_addr_h      <= wr_addr_h_next;
            wr_addr_l      <= wr_addr_l_next;
            wr_addr_last_h <= wr_addr_last_h_next;
            wr_addr_last_l <= wr_addr_last_l_next;
            tp_s_addr_h    <= tp_s_addr_h_next;
            tp_s_addr_l    <= tp_s_addr_l_next;
            old_end_addr_h <= old_end_addr_h_next;
            old_end_addr_l <= old_end_addr_l_next;
            cross_jump     <= cross_jump_next;
        end
    end

endmodule

`default_nettype wire
