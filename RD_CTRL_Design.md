# RD_CTRL 详细设计说明

> 对应当前源码：[`rtl/RD_CTRL.v`](rtl/RD_CTRL.v)。本文只说明 RD_CTRL 的职责、接口、指针语义和跳转行为。报文 ID 解析、数据前瞻、QoS 选包和出口握手由 PF_CTRL 完成。

## 1. 模块定位

`RD_CTRL` 是 RF 存储器的物理读地址控制器。它只回答三个问题：

1. 高、低优先级队列是否还有已提交数据可以读取？
2. PF_CTRL 发起一次预取请求时，RF 应读取哪个物理地址？
3. 读指针遇到窗口跳转产生的物理断点时，如何从 `tp_s` 跳到 `tp_e`？

结构关系如下：

```text
WR_CTRL
  ├── wr_addr_last_h/l：实时提交边界
  ├── old_end_addr_h/l：旧窗口冻结边界
  └── tp_s_addr_h/l：物理断点
             │
             v
PF_CTRL ── fetch_en/qos ──> RD_CTRL ── ram_rd_en/addr ──> RF_MEM
   ^                           │
   └──── fetch_vld_h/l ───────┘
```

`RD_CTRL` 不缓存 RF 数据，不解析第 9 位，不知道目的出口 ID，也不直接接收出口 grant。

## 2. 高低优先级地址方向

一块 1024×9 RF 被分成两个相向增长的逻辑队列：

```text
低优先级：地址 0 -> 1 -> 2 -> ...
高优先级：地址 1023 -> 1022 -> 1021 -> ...
```

复位或 `ptr_reset` 后：

```text
rd_addr_l = 0
rd_addr_h = 1023
```

普通预取成功后：

```text
低优先级 rd_addr_l = rd_addr_l + 1
高优先级 rd_addr_h = rd_addr_h - 1
```

## 3. rd_addr 的准确含义

`rd_addr_h/l` 表示各队列“下一次要向 RF 发起预取的物理地址”，不是出口当前消费地址。

这两个位置可能不同：

```text
RF 读指针 rd_addr ──已经提前读出数个字──> PF 前瞻 FIFO ──> 出口当前消费位置
```

因此：

- `rd_addr` 在 RF 读请求被接受时移动。
- 出口从 PF FIFO 消费一个字节不会直接移动 `rd_addr`。
- `rd_addr` 最多会领先出口若干字，领先量由 PF 的前瞻容量限制。

如果把 `rd_addr` 当成出口消费指针，就会错误判断 RAM 为空或提前复位指针。

## 4. 端口说明

### 4.1 时钟与控制

| 端口 | 方向 | 含义 |
|---|---|---|
| `clk` | 输入 | 工作时钟 |
| `rst_n` | 输入 | 低有效异步复位 |
| `force_drain` | 输入 | 1 时只读取跳转前的旧窗口 |
| `jump_pulse` | 输入 | PKT_INGRESS 统一产生的单拍跳转事件 |
| `ptr_reset` | 输入 | RAM 和 PF 都完全空闲时恢复初始读指针 |

### 4.2 PF_CTRL 请求接口

| 端口 | 方向 | 含义 |
|---|---|---|
| `fetch_en` | 输入 | PF 请求读取一个 9 bit 存储字 |
| `fetch_qos` | 输入 | 1 选择高队列，0 选择低队列 |
| `fetch_vld_h` | 输出 | 高队列当前存在已提交数据可预取 |
| `fetch_vld_l` | 输出 | 低队列当前存在已提交数据可预取 |

`fetch_en` 只是请求。真正接受条件为：

```verilog
fetch_fire = fetch_en && selected_fetch_vld;
```

只有 `fetch_fire=1` 才会产生 `ram_rd_en` 并推进读指针。

### 4.3 写侧边界接口

| 端口 | 方向 | 含义 |
|---|---|---|
| `wr_addr_last_h/l` | 输入 | 当前实时的已提交边界 |
| `old_end_addr_h/l` | 输入 | 跳转时冻结的旧窗口读取边界 |
| `tp_s_addr_h/l` | 输入 | 跳转前旧区域的下一可写地址，即物理断点 |
| `tp_e_addr_h/l` | 输入 | 跳转后新区域起点 |

`wr_addr_last` 只在合法 EOP 时更新，所以 RD 通过它天然屏蔽未提交半包。

### 4.4 RF 接口与状态输出

| 端口 | 方向 | 含义 |
|---|---|---|
| `ram_rd_en` | 输出 | RF 同步读使能，等于 `fetch_fire` |
| `ram_rd_addr` | 输出 | 本次实际访问的物理地址 |
| `rd_addr_h/l` | 输出 | 下一预取地址，也供跳转目标选择逻辑观察 |
| `jump_busy` | 输出 | 任一 QoS 仍未完成当前断点跨越 |
| `old_fetch_done` | 输出 | 旧窗口数据已全部发起 RF 读取 |
| `rd_mem_empty` | 输出 | 实时提交范围内没有尚未预取的数据 |

## 5. 提交边界与可读判断

### 5.1 正常模式

`force_drain=0` 时，读取实时提交边界：

```verilog
selected_end_addr_h = wr_addr_last_h;
selected_end_addr_l = wr_addr_last_l;
```

### 5.2 旧窗口强排模式

`force_drain=1` 时，读取跳转时冻结的旧窗口边界：

```verilog
selected_end_addr_h = old_end_addr_h;
selected_end_addr_l = old_end_addr_l;
```

新窗口报文即使已经提交并推动 `wr_addr_last`，强排期间也不可见，因此不会混入旧窗口。

### 5.3 队列可读条件

不考虑断点空跳时，判断非常直接：

```text
rd_addr != selected_end_addr：还有已提交字可读
rd_addr == selected_end_addr：已追上边界
```

所以第一个报文必须完整提交后，RD 才会向 RF 读取其前三个 ID 字节。当前设计不预读未提交半包。

## 6. 普通读取流程

假设 PF 选择低优先级：

```text
fetch_qos = 0
fetch_vld_l = (rd_addr_l != selected_end_addr_l)
fetch_fire = fetch_en && fetch_vld_l
```

若 `fetch_fire=1`：

```text
ram_rd_en   = 1
ram_rd_addr = rd_addr_l
时钟沿后 rd_addr_l = rd_addr_l + 1
```

高优先级完全对称，只是地址递减。

伪代码如下：

```text
if fetch_en and selected queue has committed data:
    issue RF read at selected rd_addr

    if high queue:
        rd_addr_h--
    else:
        rd_addr_l++
```

## 7. 为什么必须有独立的 rd_jump_pending

`jump_pulse` 只有一个周期，而读指针可能几百拍以后才到达断点。RD 必须把事件保存为持久状态：

```text
rd_jump_pending_h
rd_jump_pending_l
```

生命周期为：

```text
jump_pulse                        -> 两个 pending 置 1
高队列实际跨越自己的断点         -> pending_h 清 0
低队列实际跨越自己的断点         -> pending_l 清 0
ptr_reset                         -> 两个 pending 清 0
```

高低队列读取速度和数据量可能完全不同，因此必须各自保留一个 pending。不能让高队列完成跳转时顺带清掉低队列的断点信息。

`WR_CTRL.cross_jump` 也不能代替这些标志：

- `cross_jump` 跟踪当前未提交报文是否跨界，提交或报错就结束。
- `rd_jump_pending` 跟踪物理读指针是否已经跨界，可能持续到很久以后。

## 8. tp_s 为什么不能直接读取

跳转当拍写侧执行：

```text
tp_s = 跳转前的下一可写地址
当前有效字节直接写入 tp_e
```

因此 `tp_s` 是旧区域与新区域之间的逻辑断点，不是跳转后当前字节的存储位置。当读指针走到 `tp_s` 时，必须跳到 `tp_e`。

如果仍然读取 `tp_s`，可能读到未写旧值或其他代数据，破坏报文连续性。

## 9. jump_take：跳转并读取

当下面条件同时成立时触发 `jump_take`：

```text
对应 rd_jump_pending = 1
所选 rd_addr == 对应 tp_s
PF 发起了有效 fetch
tp_e 处确实有已提交数据
```

本次请求不读取 `tp_s`，而是直接读取 `tp_e`：

```verilog
ram_rd_addr = tp_e;
```

时钟沿后，下一预取位置越过已经读取的 `tp_e`：

```text
高队列：rd_addr_h = tp_e_addr_h - 1
低队列：rd_addr_l = tp_e_addr_l + 1
```

同时清除对应的 `rd_jump_pending`。

这等价于把“指针跳转”和“读取新区域第一个字”合并在同一次 fetch 中，不增加额外空拍。

## 10. jump_skip：空队列断点归一化

若读指针已经到达 `tp_s`，但：

```text
tp_e == selected_end_addr
```

说明该 QoS 队列在新区域没有可读字，`tp_e` 本身只是空队列边界。此时不能产生 RF 读取，否则会把无效内容送入 PF。

RD 执行 `jump_skip`：

```text
ram_rd_en = 0
rd_addr   = tp_e
清除对应 rd_jump_pending
```

`jump_skip` 不依赖 PF 再发一次有效 fetch，它会在条件满足时自行把物理指针归一到新区域边界。

`fetch_vld_h/l` 在 `jump_skip` 周期被压低，防止同一拍产生伪读请求。

## 11. 跳转流程示例

以低优先级地址递增为例：

```text
跳转前：rd_addr_l = 100，wr_addr_l 的下一地址为 tp_s_l = 140
跳转目标：tp_e_l = 512
旧包物理分布：100 ... 139，512 ... 519
旧窗口边界：old_end_l = 520
```

读取过程：

```text
读 100, 101, ... , 139
下一 rd_addr_l 变为 140，即 tp_s_l
rd_jump_pending_l 仍为 1
下一次 fetch 的 ram_rd_addr 直接等于 512
时钟沿后 rd_addr_l 变为 513，pending_l 清零
继续读 513 ... 519
rd_addr_l 到 520，与 old_end_l 相等
```

注意：物理地址 140 没有被读取。

## 12. old_fetch_done、rd_mem_empty 与真正全空

### 12.1 old_fetch_done

当前实现为：

```verilog
old_fetch_done = force_drain &&
                 (rd_addr_h == old_end_addr_h) &&
                 (rd_addr_l == old_end_addr_l);
```

它只表示旧窗口所有字都已经发起 RF 预取，并不表示这些数据已从出口发送。

RF 输出寄存器或 PF FIFO 中仍可能有旧数据。因此 `PKT_INGRESS` 还要等待 `pf_empty`，并确认跨界半包已经提交或报错，才能结束 `force_drain`。

### 12.2 rd_mem_empty

当前实现为：

```verilog
rd_mem_empty = (rd_addr_h == wr_addr_last_h) &&
               (rd_addr_l == wr_addr_last_l);
```

它表示 RF 的实时已提交数据已经全部被预取，不代表 PF 为空。入口真正全空定义为：

```text
rd_empty = rd_mem_empty && pf_empty
```

### 12.3 jump_busy

```verilog
jump_busy = rd_jump_pending_h || rd_jump_pending_l;
```

只要任一 QoS 队列仍依赖当前 `tp_s/tp_e`，`PKT_INGRESS` 就不能产生第二个物理断点，否则唯一一组断点地址会被覆盖。

## 13. RD_CTRL 没有状态机

当前 `RD_CTRL` 不需要 `RD_IDLE/RD_HIGH/RD_LOW` 状态机。原因是：

- 高低队列选择由 PF 的 `fetch_qos` 给出。
- 一个报文内 QoS 锁定由 PF 负责。
- RD 只需对本次 fetch 所选指针执行一次原子更新。
- 两套 `rd_addr` 和两套 `rd_jump_pending` 已经完整保存物理状态。

如果在 RD 中再加入包级状态机，就会与 PF 的 QoS 锁定重复，增加耦合并产生两处状态不同步的风险。

## 14. 一拍同步 RF 时序

一次普通预取的时序为：

```text
周期 N：
  PF 给出 fetch_en/fetch_qos
  RD 组合产生 ram_rd_en/ram_rd_addr

N -> N+1 时钟沿：
  RF 把 mem[ram_rd_addr] 装入 ram_rd_data
  RD 推进所选 rd_addr
  PF 记录这次 RF 请求及其 QoS

周期 N+1：
  ram_rd_data 是周期 N 请求的响应
  PF 在有空间时把响应压入显式 FIFO
```

RD 不需要自己增加响应状态，因为响应数据和 QoS 标签由 PF 管理。

## 15. 复位、优先级与接口约束

时序寄存器优先级为：

```text
rst_n 无效 > ptr_reset > 正常指针/跳转更新
```

外部应保证：

1. `ptr_reset` 只在 RF 已提交数据和 PF 状态都空、没有半包、当前拍无写入时产生。
2. `jump_pulse` 由 PKT_INGRESS 统一产生，并同时送给 WR、RD 和 PF。
3. `tp_s/tp_e` 在 pending 清除前保持稳定。
4. `jump_busy=1` 时不得产生下一次跳转。
5. `fetch_qos` 在每次有效 fetch 上必须与 PF 记录的报文队列一致。
6. `old_end_addr` 在整个强排期间保持旧窗口语义。

## 16. 核心伪代码

```text
selected_end_h = force_drain ? old_end_h : wr_addr_last_h
selected_end_l = force_drain ? old_end_l : wr_addr_last_l

if pending_h and rd_addr_h == tp_s_h and tp_e_h == selected_end_h:
    rd_addr_h = tp_e_h
    pending_h = 0

if pending_l and rd_addr_l == tp_s_l and tp_e_l == selected_end_l:
    rd_addr_l = tp_e_l
    pending_l = 0

if fetch_en and selected rd_addr != selected_end:
    if selected pending and rd_addr == tp_s:
        RF_read(tp_e)
        rd_addr = tp_e ± 1
        selected pending = 0
    else:
        RF_read(rd_addr)
        rd_addr = rd_addr ± 1

if jump_pulse:
    pending_h = 1
    pending_l = 1
```

其中高队列使用减号，低队列使用加号。

## 17. 关键不变量

后续修改 `RD_CTRL` 时必须保持：

1. 未提交数据永远不可预取。
2. `rd_addr` 只因 RF fetch 或 `jump_skip` 改变。
3. `tp_s` 永远不作为普通 RF 数据地址访问。
4. `jump_take` 必须在同一次 fetch 中直接读取 `tp_e`。
5. 空的新区域必须使用 `jump_skip`，不能伪读 `tp_e`。
6. 高低 pending 独立保存、独立清除。
7. 指针侧 empty 与 PF/出口侧 empty 必须分开。
8. RD 不承担包解析和出口调度功能。
