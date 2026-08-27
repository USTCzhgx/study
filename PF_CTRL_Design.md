# PF_CTRL 详细设计说明

> 对应当前源码：[`rtl/PF_CTRL.v`](rtl/PF_CTRL.v)。本文说明 PF_CTRL 的 4×9 前瞻、同步 RF 响应管理、ID/EOP 解析、入口内部 QoS 选择以及与出口 RR/DOUT 的握手关系。

## 1. 模块定位

`PF_CTRL` 位于 `RD_CTRL/RF_MEM` 与 8 个出口之间，是入口侧的数据前瞻与调度前端：

```text
                 fetch_vld_h/l
RD_CTRL <──────────────────────── PF_CTRL
   ^          fetch_en/qos           │
   │                                 │ ready_to_egress[7:0]
   │ ram_rd_en/addr                  │ data/sop/eop/qos/vld
   v                                 v
RF_MEM ── 1拍同步读 ──> PF_CTRL <── 8个 PKT_EGRESS 的 rd_en
```

PF_CTRL 负责：

1. 选择下一次预取高优先级还是低优先级队列。
2. 管理 RF 一拍读延迟和有效 4×9 前瞻容量。
3. 解析 RF 第 9 位，恢复目的出口 ID 和 EOP。
4. 保存当前报文和下一报文的调度上下文。
5. 向唯一的目的出口发出 one-hot ready。
6. 收到正确出口授权后逐字节弹出数据。

PF_CTRL 不负责物理读指针、`tp_s/tp_e` 跳转或多个入口之间的 RR。物理地址由 RD_CTRL 管理，跨入口竞争由各 PKT_EGRESS 的 ARB_RR 管理。

## 2. RF 数据格式

每个 RF 字为 9 bit：

```text
ram_rd_data[8]   ：复用信息位
ram_rd_data[7:0] ：报文数据
```

信息位按报文字节位置解释：

| 报文字节 | bit[8] 含义 |
|---|---|
| 第 1 字节 | 目的 ID[2] |
| 第 2 字节 | 目的 ID[1] |
| 第 3 字节 | 目的 ID[0] |
| 第 4 字节及以后 | EOP |

报文最短为 4 byte，所以前三个 bit[8] 可以固定用于 ID，从第四字节开始再解释为 EOP，不会丢失包尾信息。

QoS 不存入 RF 数据字。PF 根据所选物理队列以及 RF 请求对应的 `ram_rd_qos_pending` 恢复该报文 QoS。

## 3. 端口说明

### 3.1 基本控制

| 端口 | 方向 | 含义 |
|---|---|---|
| `clk` | 输入 | 工作时钟 |
| `rst_n` | 输入 | 低有效异步复位 |
| `ptr_reset` | 输入 | 入口真正全空时清空全部前瞻和报文上下文 |
| `jump_pulse` | 输入 | 单拍地址跳转事件；该拍暂停新 RF 请求 |

### 3.2 与 RD_CTRL 的接口

| 端口 | 方向 | 含义 |
|---|---|---|
| `fetch_vld_h` | 输入 | 高队列存在已提交数据可预取 |
| `fetch_vld_l` | 输入 | 低队列存在已提交数据可预取 |
| `fetch_en` | 输出 | 请求 RD/RF 读取一个存储字 |
| `fetch_qos` | 输出 | 本次请求选择高队列 1 或低队列 0 |

### 3.3 与 RF_MEM 的响应接口

| 端口 | 方向 | 含义 |
|---|---|---|
| `ram_rd_en` | 输入 | RD 实际接受了当前 fetch |
| `ram_rd_data[8:0]` | 输入 | RF 一拍同步读输出 |

`ram_rd_en` 既是 RF 读使能，也是 PF 记录“下一拍会有响应”的依据。

### 3.4 与出口的接口

| 端口 | 方向 | 含义 |
|---|---|---|
| `ready_to_egress[7:0]` | 输出 | 当前队头报文对目的出口的 one-hot 请求 |
| `rd_en_from_egress[7:0]` | 输入 | 8 个出口返回给本入口的读取授权 |
| `data_to_egress[7:0]` | 输出 | FIFO 队头数据，广播到所有出口 |
| `sop_to_egress` | 输出 | 队头数据是报文首字节 |
| `eop_to_egress` | 输出 | 队头数据是报文末字节 |
| `qos_to_egress` | 输出 | 当前报文 QoS |
| `data_vld_to_egress` | 输出 | 当前字节确实被正确出口授权并消费 |
| `pf_empty` | 输出 | PF 内不再保存任何数据、响应或报文上下文 |

## 4. 为什么要做数据前瞻

RF 是一拍同步读。如果等出口 grant 到达后才发起 RF 读取，则至少会出现：

```text
grant 周期：只能给出地址
下一周期：数据才从 RF 返回
```

每次调度都会产生固定气泡，而且目的 ID 也要读前三个字节才能知道。PF_CTRL 因此在报文提交后主动预取：

- 提前把数据从 RF 移入小容量 FIFO。
- 提前恢复前三位目的 ID。
- 在出口仲裁前确保 SOP 数据已经位于 FIFO 队头。

当前实现不预读未提交半包。冷启动必须等待第一个报文合法 EOP 推进 `wr_addr_last`，随后再读取前三个字节恢复 ID。

## 5. 有效 4×9 前瞻结构

代码里只有 `data_fifo[0:2]` 三个数组项，但完整前瞻容量是四个 9 bit 字：

```text
第 1 个位置：RF 的 ram_rd_data 输出寄存器，由 ram_rd_pending 标记有效
第 2～4 个位置：PF 内部 data_fifo[0:2]
```

可视为：

```text
RF response holding      explicit FIFO
┌───────────┐          ┌─────┬─────┬─────┐
│ 1 × 9 bit │ ───────> │  0  │  1  │  2  │ ───────> 出口
└───────────┘          └─────┴─────┴─────┘
```

PF 没有再复制一个 9 bit 响应寄存器，因为 `RF_MEM.ram_rd_data` 本身已经是寄存输出。只需要保存它是否有效以及对应 QoS。

## 6. RF 响应 holding entry

### 6.1 ram_rd_pending

当 `ram_rd_en=1` 的时钟沿：

- RF 把指定地址内容装入 `ram_rd_data`。
- PF 将 `ram_rd_pending` 置 1。
- PF 将本次 `fetch_qos` 保存到 `ram_rd_qos_pending`。

下一周期，若显式 FIFO 有空间：

```verilog
response_push = ram_rd_pending && fifo_space_for_response;
```

`ram_rd_data` 与 `ram_rd_qos_pending` 一起被当前解析逻辑使用，数据字被写入显式 FIFO。

### 6.2 同拍搬运和替换

```verilog
response_slot_available = !ram_rd_pending || response_push;
```

如果旧响应在当前周期被压入 FIFO，那么同一个周期可以发起下一次 RF 读取。时钟沿后，旧响应已经离开 holding entry，新响应取代它，形成一字/拍的连续流水。

若显式 FIFO 已满且出口没有弹出数据，`response_push=0`，holding entry 保留当前响应，同时 `response_slot_available=0`，停止继续读取 RF，避免覆盖未搬运响应。

## 7. 三项显式 FIFO

显式 FIFO 使用：

```verilog
reg [8:0] data_fifo [0:2];
reg [1:0] fifo_wr_ptr;
reg [1:0] fifo_rd_ptr;
reg [2:0] fifo_count;
```

读写指针按 `0 -> 1 -> 2 -> 0` 循环。容量固定为 3，不能按照二进制 2 bit 指针自然回绕到 3。

空间判断为：

```verilog
fifo_space_for_response = (fifo_count < 3) || fifo_pop;
```

即使 FIFO 当前为满，只要同拍出口会弹出队头，RF 响应仍可同拍写入尾部。`response_push` 与 `fifo_pop` 同时发生时，`fifo_count` 保持不变。

队头使用显式三路 case 选择，而不是直接用可能为 X 或 3 的下标访问数组，避免仿真初始阶段出现越界索引告警。

## 8. 两套信息位置计数器

PF 同时维护预取侧和输出侧进度：

```text
fetch_info_pos  ：当前 RF 响应中的 bit[8] 应如何解释
output_info_pos ：当前 FIFO 队头中的 bit[8] 应如何解释
```

状态编码相同：

```text
INFO_ID2 -> INFO_ID1 -> INFO_ID0 -> INFO_EOP
```

但两者不能合并，因为 RF 预取可能领先出口消费最多 4 个字。

例如预取侧已经读到下一报文第三字节，输出侧可能仍停留在当前报文 EOP。若共用位置状态，EOP 会被误解释为 ID，或者 ID 位会被误解释为 EOP。

## 9. 预取侧 ID/EOP 解析

### 9.1 ID 重组

`assembling_id` 分三次收集 bit[8]：

```text
INFO_ID2 响应：assembling_id[2] = ram_rd_data[8]
INFO_ID1 响应：assembling_id[1] = ram_rd_data[8]
INFO_ID0 响应：完整 ID = {assembling_id[2:1], ram_rd_data[8]}
```

第三字节被成功 `response_push` 时，`response_id_complete=1`。完整 ID 随后写入 `current_pkt_id` 或 `next_pkt_id`。

### 9.2 EOP 识别

只有 `fetch_info_pos==INFO_EOP` 时，bit[8]=1 才表示 EOP：

```verilog
response_eop = response_push &&
               (fetch_info_pos == INFO_EOP) &&
               ram_rd_data[8];
```

检测到 EOP 后，预取侧位置回到 `INFO_ID2`，下一响应重新按新报文目的 ID 解释。

## 10. QoS 队列选择与锁定

PF 的优先级规则是：

```text
在新报文边界：高队列有数据就选高，否则选低
报文预取开始后：保持当前 QoS 直到该报文 EOP
```

相关状态：

- `fetch_packet_active`：当前正在从 RF 预取一个报文。
- `fetch_qos_lock`：当前报文来自高队列还是低队列。

组合选择逻辑可以概括为：

```text
if 当前报文仍未遇到 EOP:
    fetch_qos = fetch_qos_lock
    只查看这个队列的 fetch_vld
else if 高队列有数据:
    fetch_qos = HIGH
else if 低队列有数据:
    fetch_qos = LOW
else:
    不发起 fetch
```

所以若已经开始预取一个低优先级报文，随后又提交了高优先级报文，当前低优先级报文不会被打断。高优先级只在下一个包边界获得优先选择。

### 10.1 EOP 同拍启动下一报文

当旧报文 EOP 响应正在被压入 FIFO 时，`response_eop=1`。本周期的队列选择逻辑已经处于新包边界，因此可以同时选择下一个高或低队列并发出新的 `ram_rd_en`。

时钟沿后：

- 旧报文 EOP 已进入显式 FIFO。
- 新报文首字节进入 RF 输出流水。
- `fetch_qos_lock` 更新为新报文 QoS。

这样预取端在相邻报文间不需要停一拍。

## 11. jump_pulse 如何影响 PF

跳转当拍：

```verilog
fetch_en = ... && !jump_pulse && ...;
```

PF 暂停发起新的 RF 请求，让 RD_CTRL 先在时钟沿保存新的跳转 pending，并让 `tp_s/tp_e` 映射稳定。从下一周期开始，RD 才可能依据新映射执行 `jump_take` 或 `jump_skip`。

`jump_pulse` 不会清空显式 FIFO、holding 响应或 current/next 上下文。跳转前已经预取的旧窗口数据仍然必须正常送出；直接清空会丢包。

只有入口确认所有数据和上下文真正为空后产生的 `ptr_reset`，才会清空 PF 状态。

## 12. current 和 next 报文上下文

PF 保存两套调度上下文：

```text
current_pkt_id / current_pkt_qos / current_pkt_valid
next_pkt_id    / next_pkt_qos    / next_pkt_valid
```

### 12.1 current

`current` 描述 FIFO 队头所属报文：

- ID 决定向哪个出口发 ready。
- QoS 随数据输出。
- valid 表示前三个 ID 位已经解析完整。

### 12.2 next

当前报文尚未输出完时，预取可能已经读取到下一报文第三字节。此时将下一报文信息放入 `next`，不能覆盖正在使用的 `current`。

当前 EOP 被弹出时：

```text
若 next_valid：next 立即转为 current
若同拍刚好完成更后一个 ID：它补入新的 next
若没有 next 但同拍刚完成下一个 ID：该 ID 直接成为 current
```

这些同拍分支用于覆盖 EOP 消费、RF 响应推入和 ID 完成同时发生的边界情况。

## 13. ready_to_egress

当前目的 ID 被译码为 one-hot：

```verilog
current_pkt_onehot = 8'b0000_0001 << current_pkt_id;
```

ready 产生条件为：

```verilog
current_pkt_valid && output_info_pos == INFO_ID2
```

也就是说：

- 前三个 ID 字节已经预取并解析完成。
- FIFO 队头仍是该报文首字节，SOP 尚未被消费。
- 只向 `current_pkt_id` 指定的目的出口请求。

首字节获得授权并弹出后，`output_info_pos` 变为 `INFO_ID1`，ready 自动撤销。之后出口 DOUT_FSM 已锁定该入口，会持续返回 `rd_en` 到 EOP，不需要每字节重新参加 RR。

## 14. 出口授权与 FIFO 弹出

8 个出口的授权返回为 `rd_en_from_egress[7:0]`。PF 只接受目的出口对应的那一位：

```verilog
current_grant = |(rd_en_from_egress & current_pkt_onehot);
```

真正弹出条件：

```verilog
fifo_pop = current_pkt_valid && current_grant && !fifo_empty;
```

这可防止错误出口或其他出口的授权误消费当前报文。

PF 输出含义：

```text
data_to_egress     = FIFO 队头 data[7:0]
sop_to_egress      = 队头位于 INFO_ID2
eop_to_egress      = 队头位于 INFO_EOP 且 bit[8]=1
qos_to_egress      = current_pkt_qos
data_vld_to_egress = fifo_pop
```

未获得授权时，数据和 SOP 可以稳定呈现在组合输出上，但 `data_vld_to_egress=0`，不构成一次有效传输。

## 15. 为什么 ready 不依赖 grant

ready 只依赖寄存的 `current_pkt_id/current_pkt_valid` 和输出位置，不依赖同拍 `rd_en_from_egress`。

因此不存在：

```text
ready -> RR grant -> rd_en -> ready
```

的组合反馈环。实际当拍路径是单向的：

```text
寄存的 current ID
  -> ready
  -> 出口 ARB_RR 当拍 grant
  -> DOUT_FSM 当拍 rd_en
  -> current_grant/fifo_pop
  -> data_vld
```

这是出口 RR 可以使用纯组合当拍调度的必要条件。

## 16. 输出侧 SOP/EOP 状态

`output_info_pos` 仅在 `fifo_pop` 时更新：

```text
弹出第1字节：INFO_ID2 -> INFO_ID1
弹出第2字节：INFO_ID1 -> INFO_ID0
弹出第3字节：INFO_ID0 -> INFO_EOP
之后每弹出一个普通数据字：保持 INFO_EOP
弹出 bit[8]=1 的 EOP：INFO_EOP -> INFO_ID2
```

所以出口暂停时，SOP/EOP 位置也保持不变，不会因 RF 继续预取而改变。

## 17. 相邻报文无输出气泡

4×9 容量的核心目标不是缓存整个报文，而是覆盖同步 RF 延迟和下一个 ID 的三字节解析。

最紧张的边界状态可以是：

```text
显式 FIFO[队头]：当前报文 EOP
显式 FIFO 后两项：下一报文第1、2字节
RF holding entry：下一报文第3字节
```

当前 EOP 被出口消费的同一拍：

- FIFO 弹出 EOP。
- holding entry 的第三字节压入 FIFO。
- `response_id_complete=1`，下一报文 ID 完成。
- 下一报文上下文成为 current。

时序为：

```text
周期 N：当前 EOP 有效输出
时钟沿：DOUT 回到 IDLE；PF 切换 current 上下文
周期 N+1：新 ready -> RR 当拍 grant -> 新 SOP 有效输出
```

EOP 和下一 SOP 位于相邻周期，中间没有空白输出周期。

这只描述已经有足够前瞻数据的稳定状态。完全空闲后的第一个报文仍有提交和前三字节同步预取的冷启动延迟。

## 18. pf_empty 的完整定义

PF 真正为空必须同时满足：

```verilog
fifo_empty             &&
!ram_rd_pending        &&
!fetch_packet_active   &&
!current_pkt_valid     &&
!next_pkt_valid
```

每一项都不能省略：

- FIFO 空，但 RF 响应 pending：下一拍仍有数据要进入。
- FIFO 空，但 fetch packet active：报文预取状态尚未走到 EOP。
- FIFO 空，但 current/next valid：仍存在未释放的调度上下文，说明状态不完整。

`PKT_INGRESS` 使用：

```text
rd_empty = rd_mem_empty && pf_empty
```

只有此时才允许生成 `ptr_reset`。

## 19. 冷启动时序

以一个已经在周期 C 提交的报文为例，忽略跳转和 FIFO 阻塞，逻辑过程为：

```text
C 之后：RD 看到 wr_addr_last 前进，fetch_vld 有效
第1次 fetch：请求报文第1字节；下一拍 RF 输出 ID[2]
第2次 fetch：请求报文第2字节；下一拍 RF 输出 ID[1]
第3次 fetch：请求报文第3字节；下一拍 RF 输出 ID[0]
第三个响应成功压入 FIFO的时钟沿：current_pkt_id/valid 被寄存
随后：ready 对目的出口有效，RR 才能调度 SOP
```

所以“预读三拍”指需要取得前三个 RF 字来恢复 ID，不应理解成从输入 SOP 起固定三拍就能调度。读侧必须先看到合法提交边界，同时还受一拍 RF 响应流水和 FIFO 接收时序约束。

## 20. PF_CTRL 的分布式状态

PF 没有单一的大 FSM，而是把状态拆为四组：

| 状态组 | 作用 |
|---|---|
| `ram_rd_pending/qos_pending` | 同步 RF 响应 holding entry |
| `fifo_wr_ptr/rd_ptr/count` | 3×9 显式数据 FIFO |
| `fetch_info_pos/fetch_packet_active/fetch_qos_lock` | 预取侧包边界、ID/EOP 和 QoS |
| `output_info_pos/current/next` | 输出侧包边界和出口调度上下文 |

这些状态分别对应不同流水阶段。强行合并为一个大状态机会同时耦合 RF 请求、响应、FIFO、ID 解析和出口 grant，难以处理同拍 push/pop、EOP 与下一 ID 完成等并发事件。

## 21. 核心伪代码

```text
# 新 RF 请求
if not jump_pulse and response holding有空位:
    if 正在预取报文:
        继续锁定的QoS队列
    else if high可读:
        选择high
    else if low可读:
        选择low

    if 所选队列可读:
        fetch_en = 1

# RF响应进入显式FIFO
if ram_rd_pending and (FIFO未满 or 本拍会pop):
    FIFO.push(ram_rd_data)
    按fetch_info_pos解析ID或EOP

# 出口请求
if current ID有效 and FIFO队头是SOP:
    ready[current ID] = 1

# 数据消费
if rd_en_from_egress[current ID] and current ID有效 and FIFO非空:
    输出有效
    FIFO.pop()
    推进output_info_pos

    if 弹出EOP:
        next上下文转为current
```

## 22. 关键不变量

后续修改 PF_CTRL 时必须保持：

1. `ram_rd_data` 只有在 `ram_rd_pending` 有效时才能压入 FIFO。
2. holding entry 未被搬走时不能发起会覆盖它的新 RF 请求。
3. 显式 FIFO 满但同拍 pop 时允许 push，保证流水连续。
4. `fetch_info_pos` 与 `output_info_pos` 必须分离。
5. 一个报文预取开始后 QoS 不允许中途改变。
6. bit[8] 在前三字节解释为 ID，第四字节后才解释为 EOP。
7. ready 只能在完整 ID 已寄存且 SOP 尚未消费时有效。
8. ready 不能组合依赖同拍 grant，否则会形成反馈环。
9. 只有目的出口授权能弹出当前数据。
10. SOP 消费后由 DOUT_FSM 锁包，PF 不再持续请求 RR。
11. `jump_pulse` 只暂停新 fetch，不能清掉已经预取的旧窗口数据。
12. `ptr_reset` 才能在真正全空时统一清空 FIFO、响应和上下文。
13. `pf_empty` 必须覆盖 FIFO、RF pending、预取包状态和 current/next 上下文。

## 23. 与其他模块的职责边界

| 功能 | 负责模块 |
|---|---|
| 判断报文是否已经完整提交 | WR_CTRL 提交边界 |
| 计算下一 RF 物理地址 | RD_CTRL |
| 处理 `tp_s -> tp_e` | RD_CTRL |
| 管理 RF 一拍返回和数据前瞻 | PF_CTRL |
| 恢复目的出口 ID | PF_CTRL |
| 选择本入口高/低 QoS 报文 | PF_CTRL |
| 在多个入口之间轮询 | 目的 PKT_EGRESS 的 ARB_RR |
| 锁定源入口直到 EOP | DOUT_FSM |

PF_CTRL 的边界可以概括为：它不决定物理地址，也不决定多个入口谁获胜；它负责让一个入口的下一完整报文以“目的已知、数据已到、可被当拍授权”的形式呈现给出口。
