
- [DIN_FLT.v]
  - byte_cnt[6:0] 拆成独立无复位时序块。
  - flt_state仍保留异步复位。
- [WR_CTRL.v]
  - tp_s_addr_h/l
  - old_end_addr_h/l
  - 共40位跳转元数据改成无复位寄存器。
  - 写状态、读写边界和 cross_jump 继续复位。
- [PKT_INGRESS.v]
  - window_base[12:0]改成无复位。
  - wr_packet_id[1:0]改成无复位。
  - 两个10位 tp_e_addr_h/l_hold 删除，改成1位无复位的 jump_outer_hold。
  - 跳转地址直接由目标组标志生成：
assign tp_e_addr_h = {jump_outer, 9'h1ff};
assign tp_e_addr_l = {!jump_outer, 9'h000};
- [DOUT_FSM.v]
  - active_id[2:0]改成无复位。
  - 只在进入 DOUT_SEND 前锁存有效的非EOP授权。
 
  - - 删除 ram_rd_qos_pending：直接使用包内锁定的 fetch_qos_lock，省1位寄存器。
- 删除 fetch_packet_active 寄存器：改为由 fetch_info_pos 和 ram_rd_pending 推导，省1位寄存器。
- 简化当前报文上下文更新：response_id_complete 时直接覆盖 current_pkt_id/qos，不再判断不可达组合。
另外把7位纯数据寄存器改成无复位：
- assembling_id[1:0]
- fetch_qos_lock
- current_pkt_id[2:0]
- current_pkt_qos
它们都会在对应 valid 生效前被完整写入，因此不需要复位。这样不减少位数，但可减轻复位树负载，并允许 DC 使用更小的普通 DFF。
