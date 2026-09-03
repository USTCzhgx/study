`timescale 1ns/1ps

module DIN_FLT (
    input  wire clk,
    input  wire rst_n,

    input  wire din_sop,
    input  wire din_eop,

    output reg  wr_en,
    output reg  pkt_commit,
    output reg  pkt_error,
    output wire packet_active
);

    localparam IDLE = 1'b0;
    localparam RECV = 1'b1;

    reg [6:0] byte_cnt;
    reg       flt_state;

    // Clock-gating enable for the receive state and byte counter.  While the
    // filter is idle, only a legal SOP can change these registers.
    wire flt_clk_en;

    assign flt_clk_en = (flt_state == RECV) ||
                        (din_sop && !din_eop);

    assign packet_active = flt_state;


    //----------------------------------------------------------------------
    // State and byte counter
    //----------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt  <= 7'd0;
            flt_state <= IDLE;
        end
        else if (flt_clk_en) begin
            case (flt_state)

                IDLE: begin
                    if (din_sop && !din_eop) begin
                        // Receive the first byte
                        byte_cnt  <= 7'd1;
                        flt_state <= RECV;
                    end
                    else begin
                        byte_cnt  <= 7'd0;
                        flt_state <= IDLE;
                    end
                end


                RECV: begin
                    if (din_sop && din_eop) begin
                        // SOP and EOP asserted together
                        byte_cnt  <= 7'd0;
                        flt_state <= IDLE;
                    end

                    else if (din_sop) begin
                        // Repeated SOP:
                        // discard old packet and start a new packet
                        byte_cnt  <= 7'd1;
                        flt_state <= RECV;
                    end

                    else if (din_eop) begin
                        // Current packet ends
                        byte_cnt  <= 7'd0;
                        flt_state <= IDLE;
                    end

                    else if (byte_cnt == 7'd127) begin
                        // The 128th byte arrives without EOP
                        byte_cnt  <= 7'd0;
                        flt_state <= IDLE;
                    end

                    else begin
                        byte_cnt  <= byte_cnt + 7'd1;
                        flt_state <= RECV;
                    end
                end


                default: begin
                    byte_cnt  <= 7'd0;
                    flt_state <= IDLE;
                end

            endcase
        end
    end


    //----------------------------------------------------------------------
    // Combinational output logic
    //----------------------------------------------------------------------

    always @(*) begin
        // Default outputs
        wr_en      = 1'b0;
        pkt_commit = 1'b0;
        pkt_error  = 1'b0;

        case (flt_state)

            //--------------------------------------------------------------
            // IDLE state
            //--------------------------------------------------------------

            IDLE: begin
                if (din_sop && !din_eop) begin
                    // First byte of a new packet
                    wr_en = 1'b1;
                end
                else if (din_eop) begin
                    // EOP without SOP, including SOP/EOP together
                    pkt_error = 1'b1;
                end
            end


            //--------------------------------------------------------------
            // RECV state
            //--------------------------------------------------------------

            RECV: begin
                if (din_sop && din_eop) begin
                    // SOP and EOP asserted together
                    wr_en     = 1'b0;
                    pkt_error = 1'b1;
                end

                else if (din_sop) begin
                    // Repeated SOP:
                    // current beat is the first byte of the new packet
                    wr_en     = 1'b1;
                    pkt_error = 1'b1;
                end

                else if (din_eop) begin
                    // byte_cnt is the number of bytes before current beat
                    if (byte_cnt >= 7'd3) begin
                        // Legal packet length: 4 to 128 bytes
                        wr_en      = 1'b1;
                        pkt_commit = 1'b1;
                    end
                    else begin
                        // Short packet
                        wr_en     = 1'b0;
                        pkt_error = 1'b1;
                    end
                end

                else if (byte_cnt == 7'd127) begin
                    // Current beat is byte 128 without EOP
                    wr_en     = 1'b0;
                    pkt_error = 1'b1;
                end

                else begin
                    // Normal packet data
                    wr_en = 1'b1;
                end
            end


            default: begin
                wr_en      = 1'b0;
                pkt_commit = 1'b0;
                pkt_error  = 1'b0;
            end

        endcase
    end

endmodule
`timescale 1ns/1ps
`default_nettype none

module WR_CTRL (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       wr_en,
    input  wire       pkt_commit,
    input  wire       pkt_error,
    input  wire       qos,

    // One-cycle event generated centrally by PKT_INGRESS.
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

    wire old_packet_qos;
    wire wr_ctrl_clk_en;

    // The input contract keeps qos stable throughout a packet. On a repeated
    // SOP, qos already belongs to the new packet, while old_packet_qos still
    // identifies the aborted packet for the cross-jump rollback decision.
    assign old_packet_qos = (wr_state == WR_HIGH);

    // Common enable for the complete write-control register bank.  Exposing
    // the hold condition explicitly allows DC to share one integrated clock
    // gate across the state and address registers.
    assign wr_ctrl_clk_en = ptr_reset  ||
                            jump_pulse ||
                            pkt_error  ||
                            wr_en;

    // The jump has highest priority: a valid beat on the jump cycle belongs to
    // the new physical region and is written directly at tp_e.
    assign mem_wr_addr = jump_pulse ?
                         (qos ? tp_e_addr_h : tp_e_addr_l) :
                         ((pkt_error && wr_en) ?
                          ((cross_jump && (qos == old_packet_qos)) ?
                           (qos ? tp_e_addr_h : tp_e_addr_l) :
                           (qos ? wr_addr_last_h : wr_addr_last_l)) :
                          (qos ? wr_addr_h : wr_addr_l));

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
        else if (wr_ctrl_clk_en) begin
            if (ptr_reset) begin
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
    end

endmodule

`default_nettype wire
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
    wire       rd_ptr_clk_en;
    wire       rd_jump_clk_en;

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

    // Separate enables retain fine-grain gating for the pointer bank and the
    // jump-pending flags.
    assign rd_ptr_clk_en = ptr_reset   ||
                           jump_skip_h ||
                           jump_skip_l ||
                           fetch_fire;

    assign rd_jump_clk_en = ptr_reset   ||
                            jump_pulse  ||
                            jump_take_h ||
                            jump_take_l ||
                            jump_skip_h ||
                            jump_skip_l;

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
        else if (rd_ptr_clk_en) begin
            if (ptr_reset) begin
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
    end

    // Each queue keeps an independent read-side jump-valid flag. One global
    // jump creates discontinuities for both QoS regions. A flag is cleared only
    // when the corresponding RAM fetch actually traverses tp_s -> tp_e.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_jump_pending_h <= 1'b0;
            rd_jump_pending_l <= 1'b0;
        end
        else if (rd_jump_clk_en) begin
            if (ptr_reset) begin
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
    reg  ram_rd_qos_pending;
    wire response_push;
    wire response_slot_available;
    wire pf_rsp_clk_en;
    wire pf_ctx_fifo_clk_en;

/*
response_slot = {
    ram_rd_pending,
    ram_rd_qos_pending,
    ram_rd_data[8:0]
};
*/

    assign response_slot_available = !ram_rd_pending || response_push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_rd_pending <= 1'b0;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
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
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_rd_qos_pending <= 1'b0;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
                ram_rd_qos_pending <= 1'b0;
            end
            else if (ram_rd_en) begin
                ram_rd_qos_pending <= fetch_qos; //ram read delay one beat
            end
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

    // Two coarse register-bank enables provide enough common bit width for
    // useful DC clock-gating while keeping the independent response and
    // consume paths from waking each other unnecessarily.
    assign pf_rsp_clk_en = ptr_reset   ||
                           ram_rd_en   ||
                           response_push;

    assign pf_ctx_fifo_clk_en = ptr_reset    ||
                                response_push ||
                                fifo_pop;

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
    reg        fetch_packet_active;
    reg        fetch_qos_lock;

    reg        fetch_qos_comb;
    reg        fetch_candidate_vld;

    wire       response_eop;
    wire       response_id_complete;
    wire [2:0] completed_id;
    wire       completed_qos;

    assign response_eop = response_push &&
                          (fetch_info_pos == INFO_EOP) &&
                          ram_rd_data[8];
    assign response_id_complete = response_push &&
                                  (fetch_info_pos == INFO_ID0);
    assign completed_id = {assembling_id, ram_rd_data[8]};
    assign completed_qos = ram_rd_qos_pending;

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_packet_active <= 1'b0;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
                fetch_packet_active <= 1'b0;
            end
            else if (response_eop) begin
                if (ram_rd_en) begin
                    fetch_packet_active <= 1'b1;
                end
                else begin
                    fetch_packet_active <= 1'b0;
                end
            end
            else if (!fetch_packet_active && ram_rd_en) begin
                fetch_packet_active <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_qos_lock <= 1'b0;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
                fetch_qos_lock <= 1'b0;
            end
            else if (response_eop) begin
                if (ram_rd_en) begin
                    fetch_qos_lock <= fetch_qos;
                end
            end
            else if (!fetch_packet_active && ram_rd_en) begin
                fetch_qos_lock <= fetch_qos;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_info_pos <= INFO_ID2;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
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
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assembling_id <= 2'd0;
        end
        else if (pf_rsp_clk_en) begin
            if (ptr_reset) begin
                assembling_id <= 2'd0;
            end
            else if (response_push) begin
                case (fetch_info_pos)
                    INFO_ID2: begin
                        assembling_id[1] <= ram_rd_data[8];
                    end
                    INFO_ID1: begin
                        assembling_id[0] <= ram_rd_data[8];
                    end
                    INFO_EOP: begin
                        if (ram_rd_data[8]) begin
                            assembling_id <= 2'd0;
                        end
                    end
                    default: assembling_id <= assembling_id;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Packet destination contexts and combinational-RR interface
    // ------------------------------------------------------------------

    reg [2:0] current_pkt_id;
    reg [2:0] next_pkt_id;
    reg       current_pkt_qos;
    reg       next_pkt_qos;
    reg       current_pkt_valid;
    reg       next_pkt_valid;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pkt_id  <= 3'd0;
            current_pkt_qos <= 1'b0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                current_pkt_id  <= 3'd0;
                current_pkt_qos <= 1'b0;
            end
            else if (fifo_pop_eop) begin
                if (next_pkt_valid) begin
                    current_pkt_id  <= next_pkt_id;
                    current_pkt_qos <= next_pkt_qos;
                end
                else if (response_id_complete) begin
                    current_pkt_id  <= completed_id;
                    current_pkt_qos <= completed_qos;
                end
            end
            else if (response_id_complete && !current_pkt_valid) begin
                current_pkt_id  <= completed_id;
                current_pkt_qos <= completed_qos;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pkt_valid <= 1'b0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                current_pkt_valid <= 1'b0;
            end
            else if (fifo_pop_eop) begin
                if (next_pkt_valid || response_id_complete) begin
                    current_pkt_valid <= 1'b1;
                end
                else begin
                    current_pkt_valid <= 1'b0;
                end
            end
            else if (response_id_complete && !current_pkt_valid) begin
                current_pkt_valid <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_pkt_id  <= 3'd0;
            next_pkt_qos <= 1'b0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                next_pkt_id  <= 3'd0;
                next_pkt_qos <= 1'b0;
            end
            else if (fifo_pop_eop) begin
                if (next_pkt_valid && response_id_complete) begin
                    next_pkt_id  <= completed_id;
                    next_pkt_qos <= completed_qos;
                end
            end
            else if (response_id_complete &&
                     current_pkt_valid &&
                     !next_pkt_valid) begin
                next_pkt_id  <= completed_id;
                next_pkt_qos <= completed_qos;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_pkt_valid <= 1'b0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                next_pkt_valid <= 1'b0;
            end
            else if (fifo_pop_eop) begin
                if (next_pkt_valid && response_id_complete) begin
                    next_pkt_valid <= 1'b1;
                end
                else begin
                    next_pkt_valid <= 1'b0;
                end
            end
            else if (response_id_complete &&
                     current_pkt_valid &&
                     !next_pkt_valid) begin
                next_pkt_valid <= 1'b1;
            end
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
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                fifo_wr_ptr <= 2'd0;
            end
            else if (response_push) begin
                fifo_wr_ptr <= fifo_wr_ptr_inc;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_ptr <= 2'd0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
                fifo_rd_ptr <= 2'd0;
            end
            else if (fifo_pop) begin
                fifo_rd_ptr <= fifo_rd_ptr_inc;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_info_pos <= INFO_ID2;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
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
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_count <= 2'd0;
        end
        else if (pf_ctx_fifo_clk_en) begin
            if (ptr_reset) begin
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
                      !fetch_packet_active    &&
                      !current_pkt_valid      &&
                      !next_pkt_valid;

endmodule

`default_nettype wire
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
    wire window_clk_en;
    wire force_drain_clk_en;
    wire drain_wait_clk_en;
    wire jump_target_clk_en;
    wire wr_id_clk_en;
    wire wr_info_clk_en;

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

    // Local control-register enables.  The complete PKT_INGRESS clock is not
    // gated because its child blocks have independent wake-up conditions.
    assign window_clk_en = ptr_reset ||
                           (!window_active && wr_en);

    assign force_drain_clk_en = ptr_reset       ||
                                jump_pulse      ||
                                force_drain_done;

    assign drain_wait_clk_en = ptr_reset  ||
                               jump_pulse ||
                               pkt_error  ||
                               (pkt_commit && wr_en);

    assign jump_target_clk_en = ptr_reset || jump_pulse;
    assign wr_id_clk_en = ptr_reset || (wr_en && din_sop);
    assign wr_info_clk_en = ptr_reset || pkt_error || wr_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_base   <= 13'd0;
            window_active <= 1'b0;
        end
        else if (window_clk_en) begin
            if (ptr_reset) begin
                window_base   <= 13'd0;
                window_active <= 1'b0;
            end
            else if (!window_active && wr_en) begin
                window_base   <= global_timestamp;
                window_active <= 1'b1;
            end
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
        else if (force_drain_clk_en) begin
            if (ptr_reset)
                force_drain <= 1'b0;
            else if (jump_pulse)
                force_drain <= 1'b1;
            else if (force_drain_done)
                force_drain <= 1'b0;
        end
    end

    // A packet already in progress at jump_pulse belongs to the old window,
    // including the portion written after the physical discontinuity.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drain_wait_wr_packet <= 1'b0;
        end
        else if (drain_wait_clk_en) begin
            if (ptr_reset) begin
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
    end

    // ------------------------------------------------------------------
    // Fixed, far-side jump target
    // ------------------------------------------------------------------

    wire       rd_both_mid;
    wire [9:0] jump_target_h;
    wire [9:0] jump_target_l;
    reg  [9:0] tp_e_addr_h_hold;
    reg  [9:0] tp_e_addr_l_hold;
    wire [9:0] tp_e_addr_h;
    wire [9:0] tp_e_addr_l;

    // XOR is one for address quadrants 01 and 10 (256 through 767). If both
    // read pointers are in that middle region, jump to the outer endpoints;
    // otherwise jump to the middle pair.
    assign rd_both_mid = (^rd_addr_h[9:8]) && (^rd_addr_l[9:8]);
    assign jump_target_h = rd_both_mid ? 10'd1023 : 10'd511;
    assign jump_target_l = rd_both_mid ? 10'd0    : 10'd512;

    // WR_CTRL must see the newly selected target on the jump edge itself.
    // Afterwards the held values remain stable until the next jump, because
    // RD_CTRL may need them for many cycles while draining the old window.
    assign tp_e_addr_h = jump_pulse ? jump_target_h : tp_e_addr_h_hold;
    assign tp_e_addr_l = jump_pulse ? jump_target_l : tp_e_addr_l_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tp_e_addr_h_hold <= 10'd511;
            tp_e_addr_l_hold <= 10'd512;
        end
        else if (jump_target_clk_en) begin
            if (ptr_reset) begin
                tp_e_addr_h_hold <= 10'd511;
                tp_e_addr_l_hold <= 10'd512;
            end
            else if (jump_pulse) begin
                tp_e_addr_h_hold <= jump_target_h;
                tp_e_addr_l_hold <= jump_target_l;
            end
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_packet_id <= 2'd0;
        end
        else if (wr_id_clk_en) begin
            if (ptr_reset) begin
                wr_packet_id <= 2'd0;
            end
            else if (wr_en && din_sop) begin
                wr_packet_id <= din_id[1:0];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_info_pos <= INFO_ID2;
        end
        else if (wr_info_clk_en) begin
            if (ptr_reset) begin
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

    wire      dout_clk_en;

    assign o_schedule_en = (dout_state == DOUT_IDLE);

    // Both sequential blocks share this enable so DC can gate the state and
    // active-source registers with one ICG cell.
    assign dout_clk_en = ((dout_state == DOUT_IDLE) &&
                          i_grant_vld && selected_vld) ||
                         ((dout_state == DOUT_SEND) &&
                          selected_vld && selected_eop);

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
        else if (dout_clk_en) begin
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
        else if (dout_clk_en) begin
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

