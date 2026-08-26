`timescale 1ns/1ps
`default_nettype none

module RD_CTRL (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       force_drain,
    input  wire       jump_pulse,
    input  wire       ptr_reset,
    input  wire       rd_en,

    // Used only when the committed RAM was completely empty before this EOP.
    input  wire       pkt_commit,
    input  wire       input_qos,
    input  wire [2:0] input_pkt_id,

    input  wire [9:0] wr_addr_last_h,
    input  wire [9:0] wr_addr_last_l,
    input  wire [9:0] old_end_addr_h,
    input  wire [9:0] old_end_addr_l,

    input  wire [9:0] tp_s_addr_h,
    input  wire [9:0] tp_s_addr_l,
    input  wire [9:0] tp_e_addr_h,
    input  wire [9:0] tp_e_addr_l,

    input  wire [8:0] ram_rdata,

    output reg  [9:0] rd_addr_h,
    output reg  [9:0] rd_addr_l,

    output wire       ram_rd_en,
    output wire [9:0] ram_rd_addr,

    output wire [7:0] ready_to_egress,
    output wire [7:0] pkt_data,
    output wire       pkt_sop,
    output wire       pkt_eop,
    output wire       pkt_data_vld,
    output wire       pkt_qos,

    output wire       force_drain_done,
    output wire       rd_empty
);

    localparam [1:0] RD_IDLE = 2'b00;
    localparam [1:0] RD_LOW  = 2'b01;
    localparam [1:0] RD_HIGH = 2'b10;

    localparam [1:0] PH_ID0  = 2'd0;
    localparam [1:0] PH_ID1  = 2'd1;
    localparam [1:0] PH_ID2  = 2'd2;
    localparam [1:0] PH_DATA = 2'd3;

    reg [1:0] rd_state;
    reg [1:0] out_phase;

    // Four-entry raw 9-bit look-ahead FIFO.
    reg [8:0] data_fifo [0:3];
    reg [1:0] data_wr_ptr;
    reg [1:0] data_rd_ptr;
    reg [2:0] data_count;

    wire [8:0] data_head;
    assign data_head = data_fifo[data_rd_ptr];

    // At most two packet descriptors can coexist in a four-byte FIFO because
    // the minimum legal packet length is four bytes.
    reg [3:0] desc_fifo [0:1]; // {qos, destination[2:0]}
    reg       desc_wr_ptr;
    reg       desc_rd_ptr;
    reg [1:0] desc_count;

    wire       desc_head_qos;
    wire [2:0] desc_head_dest;
    assign desc_head_qos  = desc_fifo[desc_rd_ptr][3];
    assign desc_head_dest = desc_fifo[desc_rd_ptr][2:0];

    // Speculative RF frontier and currently locked fetch packet.
    reg [9:0] pf_addr_h;
    reg [9:0] pf_addr_l;
    reg       fetch_active;
    reg       fetch_qos;
    reg [1:0] fetch_phase;
    reg       fetch_dest_preknown;

    // Cold-start input ID was already inserted into desc_fifo.  Do not insert
    // another descriptor when its RF header is fetched later.
    reg       preknown_pending;
    reg       preknown_qos;

    // Fetch and consumption cross the physical discontinuity independently.
    reg pf_jump_pending_h;
    reg pf_jump_pending_l;
    reg rd_jump_pending_h;
    reg rd_jump_pending_l;
    reg jump_init_pending;

    // Metadata aligned with the one-cycle synchronous RF response.
    reg       req_valid_d;
    reg       req_qos_d;
    reg [1:0] req_phase_d;
    reg       req_preknown_d;

    wire rsp_valid;
    wire rsp_id0;
    wire rsp_id1;
    wire rsp_id2;
    wire rsp_eop;

    assign rsp_valid = req_valid_d;
    assign rsp_id0   = rsp_valid && (req_phase_d == PH_ID0);
    assign rsp_id1   = rsp_valid && (req_phase_d == PH_ID1);
    assign rsp_id2   = rsp_valid && (req_phase_d == PH_ID2);
    assign rsp_eop   = rsp_valid && (req_phase_d == PH_DATA) &&
                       ram_rdata[8];

    // The third ID bit participates in ready/RR on its return cycle.
    reg [1:0] id_cache;
    wire [2:0] fast_dest;
    wire       fast_desc_valid;

    assign fast_dest       = {id_cache, ram_rdata[8]};
    assign fast_desc_valid = rsp_id2 && !req_preknown_d;

    // Normal mode follows the live commit boundary.  Force-drain mode cannot
    // prefetch into the new generation and therefore stops at old_end.
    wire [9:0] fetch_end_h;
    wire [9:0] fetch_end_l;
    wire       pf_high_nonempty;
    wire       pf_low_nonempty;

    assign fetch_end_h = force_drain ? old_end_addr_h : wr_addr_last_h;
    assign fetch_end_l = force_drain ? old_end_addr_l : wr_addr_last_l;
    assign pf_high_nonempty = (pf_addr_h != fetch_end_h);
    assign pf_low_nonempty  = (pf_addr_l != fetch_end_l);

    // Current descriptor or same-cycle third-ID fast path.
    wire       candidate_from_fifo;
    wire       candidate_valid;
    wire       candidate_qos;
    wire [2:0] candidate_dest;
    wire [3:0] buffered_or_returning;
    wire       candidate_data_ready;

    assign candidate_from_fifo = (desc_count != 2'd0);
    assign candidate_valid     = candidate_from_fifo || fast_desc_valid;
    assign candidate_qos       = candidate_from_fifo ?
                                 desc_head_qos : req_qos_d;
    assign candidate_dest      = candidate_from_fifo ?
                                 desc_head_dest : fast_dest;

    // Two stored words plus the returning third word are sufficient.  The RR
    // grant consumes byte 0 on the coming edge while byte 2 is pushed.
    assign buffered_or_returning = {1'b0, data_count} +
                                    (rsp_valid ? 4'd1 : 4'd0);
    assign candidate_data_ready = (buffered_or_returning >= 4'd3);

    assign ready_to_egress = ((rd_state == RD_IDLE) && candidate_valid &&
                              candidate_data_ready) ?
                             (8'b0000_0001 << candidate_dest) : 8'd0;

    // FIFO consumption.  rd_en schedules a byte and the registered packet
    // outputs below present it one cycle later.
    wire start_packet;
    wire data_pop;
    wire pop_qos;
    wire pop_sop;
    wire pop_eop;

    assign start_packet = (rd_state == RD_IDLE) && candidate_valid &&
                          candidate_data_ready && rd_en;
    assign data_pop = (data_count != 3'd0) &&
                      (((rd_state == RD_IDLE) && start_packet) ||
                       ((rd_state != RD_IDLE) && rd_en));
    assign pop_qos = (rd_state == RD_IDLE) ? candidate_qos :
                     (rd_state == RD_HIGH);
    assign pop_sop = data_pop && (out_phase == PH_ID0);
    assign pop_eop = data_pop && (out_phase == PH_DATA) && data_head[8];

    reg [7:0] pkt_data_r;
    reg       pkt_sop_r;
    reg       pkt_eop_r;
    reg       pkt_data_vld_r;
    reg       pkt_qos_r;

    assign pkt_data     = pkt_data_r;
    assign pkt_sop      = pkt_sop_r;
    assign pkt_eop      = pkt_eop_r;
    assign pkt_data_vld = pkt_data_vld_r;
    assign pkt_qos      = pkt_qos_r;

    // Non-preemptive fetch selection and RF request generation.
    reg       choose_valid;
    reg       choose_qos;
    reg       choose_preknown;
    reg       issue_valid;
    reg       issue_qos;
    reg [1:0] issue_phase;
    reg       issue_preknown;
    reg [9:0] issue_addr;
    reg [9:0] issue_addr_next;
    reg       issue_crosses_jump;

    wire [3:0] fifo_occupancy_after_edge;
    wire       fetch_room;
    wire       jump_hold;

    assign fifo_occupancy_after_edge = {1'b0, data_count} +
                                       (rsp_valid ? 4'd1 : 4'd0) -
                                       (data_pop ? 4'd1 : 4'd0);
    assign fetch_room = (fifo_occupancy_after_edge < 4'd4);
    assign jump_hold  = jump_pulse || jump_init_pending ||
                        force_drain_done;

    always @(*) begin
        choose_valid    = 1'b0;
        choose_qos      = 1'b0;
        choose_preknown = 1'b0;

        // Seeing EOP ends the current fetch packet during this cycle, so the
        // next packet can be selected and requested without an idle RF cycle.
        if (!fetch_active || rsp_eop) begin
            if (pf_high_nonempty) begin
                choose_valid = 1'b1;
                choose_qos   = 1'b1;
            end
            else if (pf_low_nonempty) begin
                choose_valid = 1'b1;
                choose_qos   = 1'b0;
            end

            if (choose_valid && preknown_pending &&
                (preknown_qos == choose_qos))
                choose_preknown = 1'b1;
        end
        else begin
            choose_valid    = 1'b1;
            choose_qos      = fetch_qos;
            choose_preknown = fetch_dest_preknown;
        end

        issue_valid        = choose_valid && fetch_room && !jump_hold;
        issue_qos          = choose_qos;
        issue_preknown     = choose_preknown;
        issue_phase        = (!fetch_active || rsp_eop) ?
                             PH_ID0 : fetch_phase;
        issue_addr         = 10'd0;
        issue_addr_next    = 10'd0;
        issue_crosses_jump = 1'b0;

        if (issue_qos) begin
            if (pf_jump_pending_h && (pf_addr_h == tp_s_addr_h)) begin
                issue_addr         = tp_e_addr_h;
                issue_addr_next    = tp_e_addr_h - 10'd1;
                issue_crosses_jump = 1'b1;
            end
            else begin
                issue_addr      = pf_addr_h;
                issue_addr_next = pf_addr_h - 10'd1;
            end
        end
        else begin
            if (pf_jump_pending_l && (pf_addr_l == tp_s_addr_l)) begin
                issue_addr         = tp_e_addr_l;
                issue_addr_next    = tp_e_addr_l + 10'd1;
                issue_crosses_jump = 1'b1;
            end
            else begin
                issue_addr      = pf_addr_l;
                issue_addr_next = pf_addr_l + 10'd1;
            end
        end
    end

    assign ram_rd_en   = issue_valid;
    assign ram_rd_addr = issue_addr;

    // Descriptor push/pop.
    wire committed_empty_before_eop;
    wire direct_desc_push;
    wire fast_desc_consumed;
    wire rf_desc_store;
    wire desc_push;
    wire desc_pop;
    wire [3:0] desc_push_data;

    assign committed_empty_before_eop =
        (rd_state == RD_IDLE) && (data_count == 3'd0) &&
        (desc_count == 2'd0) && !fetch_active && !rsp_valid &&
        (rd_addr_h == wr_addr_last_h) &&
        (rd_addr_l == wr_addr_last_l);

    assign direct_desc_push = pkt_commit && committed_empty_before_eop;
    assign fast_desc_consumed = start_packet && !candidate_from_fifo &&
                                fast_desc_valid;
    assign rf_desc_store = fast_desc_valid && !fast_desc_consumed;
    assign desc_push = direct_desc_push || rf_desc_store;
    assign desc_pop  = start_packet && candidate_from_fifo;
    assign desc_push_data = direct_desc_push ?
                            {input_qos, input_pkt_id} :
                            {req_qos_d, fast_dest};

    // Empty and force-drain completion.
    wire old_high_drained;
    wire old_low_drained;

    assign old_high_drained = (rd_addr_h == old_end_addr_h) &&
                              !rd_jump_pending_h;
    assign old_low_drained  = (rd_addr_l == old_end_addr_l) &&
                              !rd_jump_pending_l;

    assign force_drain_done = force_drain &&
                              (rd_state == RD_IDLE) &&
                              (data_count == 3'd0) &&
                              (desc_count == 2'd0) &&
                              !fetch_active && !rsp_valid &&
                              old_high_drained && old_low_drained;

    // RAM_CTRL must still combine rd_empty with WR-side idle before ptr_reset.
    assign rd_empty = (rd_state == RD_IDLE) &&
                      (data_count == 3'd0) &&
                      (desc_count == 2'd0) &&
                      !fetch_active && !rsp_valid &&
                      (rd_addr_h == wr_addr_last_h) &&
                      (rd_addr_l == wr_addr_last_l);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state             <= RD_IDLE;
            out_phase            <= PH_ID0;
            data_wr_ptr          <= 2'd0;
            data_rd_ptr          <= 2'd0;
            data_count           <= 3'd0;
            desc_wr_ptr          <= 1'b0;
            desc_rd_ptr          <= 1'b0;
            desc_count           <= 2'd0;
            rd_addr_h            <= 10'd1023;
            rd_addr_l            <= 10'd0;
            pf_addr_h            <= 10'd1023;
            pf_addr_l            <= 10'd0;
            fetch_active         <= 1'b0;
            fetch_qos            <= 1'b0;
            fetch_phase          <= PH_ID0;
            fetch_dest_preknown  <= 1'b0;
            preknown_pending     <= 1'b0;
            preknown_qos         <= 1'b0;
            pf_jump_pending_h    <= 1'b0;
            pf_jump_pending_l    <= 1'b0;
            rd_jump_pending_h    <= 1'b0;
            rd_jump_pending_l    <= 1'b0;
            jump_init_pending    <= 1'b0;
            req_valid_d          <= 1'b0;
            req_qos_d            <= 1'b0;
            req_phase_d          <= PH_ID0;
            req_preknown_d       <= 1'b0;
            id_cache             <= 2'b00;
            pkt_data_r           <= 8'd0;
            pkt_sop_r            <= 1'b0;
            pkt_eop_r            <= 1'b0;
            pkt_data_vld_r       <= 1'b0;
            pkt_qos_r            <= 1'b0;
        end
        else if (ptr_reset) begin
            rd_state             <= RD_IDLE;
            out_phase            <= PH_ID0;
            data_wr_ptr          <= 2'd0;
            data_rd_ptr          <= 2'd0;
            data_count           <= 3'd0;
            desc_wr_ptr          <= 1'b0;
            desc_rd_ptr          <= 1'b0;
            desc_count           <= 2'd0;
            rd_addr_h            <= 10'd1023;
            rd_addr_l            <= 10'd0;
            pf_addr_h            <= 10'd1023;
            pf_addr_l            <= 10'd0;
            fetch_active         <= 1'b0;
            fetch_qos            <= 1'b0;
            fetch_phase          <= PH_ID0;
            fetch_dest_preknown  <= 1'b0;
            preknown_pending     <= 1'b0;
            preknown_qos         <= 1'b0;
            pf_jump_pending_h    <= 1'b0;
            pf_jump_pending_l    <= 1'b0;
            rd_jump_pending_h    <= 1'b0;
            rd_jump_pending_l    <= 1'b0;
            jump_init_pending    <= 1'b0;
            req_valid_d          <= 1'b0;
            req_qos_d            <= 1'b0;
            req_phase_d          <= PH_ID0;
            req_preknown_d       <= 1'b0;
            id_cache             <= 2'b00;
            pkt_data_r           <= 8'd0;
            pkt_sop_r            <= 1'b0;
            pkt_eop_r            <= 1'b0;
            pkt_data_vld_r       <= 1'b0;
            pkt_qos_r            <= 1'b0;
        end
        else begin
            // One-cycle packet output defaults.
            pkt_data_vld_r <= 1'b0;
            pkt_sop_r      <= 1'b0;
            pkt_eop_r      <= 1'b0;

            if (data_pop) begin
                pkt_data_r     <= data_head[7:0];
                pkt_data_vld_r <= 1'b1;
                pkt_sop_r      <= pop_sop;
                pkt_eop_r      <= pop_eop;
                pkt_qos_r      <= pop_qos;

                if (pop_eop)
                    out_phase <= PH_ID0;
                else if (out_phase != PH_DATA)
                    out_phase <= out_phase + 2'd1;

                if (rd_state == RD_IDLE)
                    rd_state <= pop_qos ? RD_HIGH : RD_LOW;
                if (pop_eop)
                    rd_state <= RD_IDLE;
            end

            // Raw data FIFO.
            if (rsp_valid) begin
                data_fifo[data_wr_ptr] <= ram_rdata;
                data_wr_ptr <= data_wr_ptr + 2'd1;
            end
            if (data_pop)
                data_rd_ptr <= data_rd_ptr + 2'd1;

            case ({rsp_valid, data_pop})
                2'b10: data_count <= data_count + 3'd1;
                2'b01: data_count <= data_count - 3'd1;
                default: data_count <= data_count;
            endcase

            // Packet descriptor FIFO.
            if (desc_push) begin
                desc_fifo[desc_wr_ptr] <= desc_push_data;
                desc_wr_ptr <= ~desc_wr_ptr;
            end
            if (desc_pop)
                desc_rd_ptr <= ~desc_rd_ptr;

            case ({desc_push, desc_pop})
                2'b10: desc_count <= desc_count + 2'd1;
                2'b01: desc_count <= desc_count - 2'd1;
                default: desc_count <= desc_count;
            endcase

            if (direct_desc_push) begin
                preknown_pending <= 1'b1;
                preknown_qos     <= input_qos;
            end

            if (rsp_id0)
                id_cache[1] <= ram_rdata[8];
            if (rsp_id1)
                id_cache[0] <= ram_rdata[8];

            // RF request pipeline and speculative pointer.
            req_valid_d <= issue_valid;
            if (issue_valid) begin
                req_qos_d      <= issue_qos;
                req_phase_d    <= issue_phase;
                req_preknown_d <= issue_preknown;

                if (issue_qos) begin
                    pf_addr_h <= issue_addr_next;
                    if (issue_crosses_jump)
                        pf_jump_pending_h <= 1'b0;
                end
                else begin
                    pf_addr_l <= issue_addr_next;
                    if (issue_crosses_jump)
                        pf_jump_pending_l <= 1'b0;
                end
            end

            // Fetch QoS is locked until the fetched EOP returns.
            if (!fetch_active || rsp_eop) begin
                if (choose_valid) begin
                    fetch_active        <= 1'b1;
                    fetch_qos           <= choose_qos;
                    fetch_dest_preknown <= choose_preknown;
                    if (issue_valid)
                        fetch_phase <= PH_ID1;
                    else
                        fetch_phase <= PH_ID0;
                    if (choose_preknown)
                        preknown_pending <= 1'b0;
                end
                else begin
                    fetch_active        <= 1'b0;
                    fetch_phase         <= PH_ID0;
                    fetch_dest_preknown <= 1'b0;
                end
            end
            else if (issue_valid) begin
                if (fetch_phase != PH_DATA)
                    fetch_phase <= fetch_phase + 2'd1;
            end

            // Real consume pointer moves only when a FIFO byte is consumed.
            if (data_pop) begin
                if (pop_qos) begin
                    if (rd_jump_pending_h &&
                        ((rd_addr_h - 10'd1) == tp_s_addr_h)) begin
                        rd_addr_h         <= tp_e_addr_h;
                        rd_jump_pending_h <= 1'b0;
                    end
                    else begin
                        rd_addr_h <= rd_addr_h - 10'd1;
                    end
                end
                else begin
                    if (rd_jump_pending_l &&
                        ((rd_addr_l + 10'd1) == tp_s_addr_l)) begin
                        rd_addr_l         <= tp_e_addr_l;
                        rd_jump_pending_l <= 1'b0;
                    end
                    else begin
                        rd_addr_l <= rd_addr_l + 10'd1;
                    end
                end
            end

            // WR_CTRL updates tp_s/old_end on the jump edge.  Initialize the
            // two read-side discontinuity records one cycle later.
            if (jump_pulse) begin
                jump_init_pending <= 1'b1;
            end
            else if (jump_init_pending) begin
                jump_init_pending <= 1'b0;
                pf_jump_pending_h <= (tp_s_addr_h != old_end_addr_h);
                pf_jump_pending_l <= (tp_s_addr_l != old_end_addr_l);
                rd_jump_pending_h <= (tp_s_addr_h != old_end_addr_h);
                rd_jump_pending_l <= (tp_s_addr_l != old_end_addr_l);
            end

            // Rejected crossing packet: the discontinuity collapses.
            if (tp_s_addr_h == old_end_addr_h) begin
                pf_jump_pending_h <= 1'b0;
                rd_jump_pending_h <= 1'b0;
            end
            if (tp_s_addr_l == old_end_addr_l) begin
                pf_jump_pending_l <= 1'b0;
                rd_jump_pending_l <= 1'b0;
            end

            // Rebase queues which had no crossing packet after old drain.
            if (force_drain_done) begin
                if (rd_addr_h == tp_s_addr_h)
                    rd_addr_h <= tp_e_addr_h;
                if (rd_addr_l == tp_s_addr_l)
                    rd_addr_l <= tp_e_addr_l;
                if (pf_addr_h == tp_s_addr_h)
                    pf_addr_h <= tp_e_addr_h;
                if (pf_addr_l == tp_s_addr_l)
                    pf_addr_l <= tp_e_addr_l;

                pf_jump_pending_h <= 1'b0;
                pf_jump_pending_l <= 1'b0;
                rd_jump_pending_h <= 1'b0;
                rd_jump_pending_l <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire


1. 状态机
RD_IDLE:
    有锁定报文且获得rd_en:
        qos=1 → RD_HIGH
        qos=0 → RD_LOW

RD_HIGH/RD_LOW:
    rd_en时消费一个字节
    读到EOP → RD_IDLE

2. 真实读指针跳转
消费一个字节后:
    next_addr = rd_addr ± 1
    if jump_pending && next_addr == tp_s:
        rd_addr = tp_e
        清除jump_pending
    else:
        rd_addr = next_addr
预读跨越只清 pf_jump_pending，真实消费跨越只清 rd_jump_pending。


3. 强排结束
force_drain时:
    预读边界使用old_end
    先完成已锁定报文
    然后高优先级优先排空旧窗口

if 高低读指针都到old_end
   && FIFO为空
   && 当前没有报文:
    force_drain_done = 1

无跨界报文的队列:
    rd_addr从tp_s切换到tp_e


RAM全空首包：
commit时直接使用输入pkt_id
提交后从RF连续预读3拍
第三拍当拍产生ready

if 当前没有锁定预读报文:
    if 高优先级非空:
        锁定高优先级
    else if 低优先级非空:
        锁定低优先级

if FIFO未满 && 已锁定报文:
    if 预读指针 == tp_s && jump_pending:
        RF读地址 = tp_e
        预读指针 = tp_e ± 1
        清除jump_pending
    else:
        RF读地址 = 预读指针
        预读指针 += 低优先级 ? 1 : -1

RF数据返回时:
    完整9-bit压入4×9 FIFO

    第1字节:
        缓存ID[2]

    第2字节:
        缓存ID[1]

    第3字节:
        ID = {ID[2], ID[1], ram_rdata[8]}
        当拍产生ready

    第4字节以后:
        if ram_rdata[8] == 1:
            当前包预读结束
            下一包重新按高优先级优先选择