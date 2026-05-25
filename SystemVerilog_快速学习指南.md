# SystemVerilog 快速学习指南

适用对象：已经学过 Verilog，想快速掌握 SystemVerilog 在数字 IC 设计和验证中的实用部分。

目标不是重新学一遍 HDL，而是搞清楚：

- Verilog 到 SystemVerilog 增加了什么
- 哪些特性可以用于 RTL 设计
- 哪些特性主要用于验证
- 学到什么程度可以开始写项目

---

## 1. 先建立正确认识

SystemVerilog 不是单纯的验证语言。

它有两大部分：

```text
SystemVerilog
├── RTL 设计子集：可综合，用于写硬件电路
└── 验证子集：不可综合或主要用于仿真，用于 testbench / UVM
```

如果你已经会 Verilog，那么学习 SystemVerilog 不需要从零开始。你重点补的是：

- 更规范的 RTL 写法
- 更强的数据类型
- 更清晰的接口组织方式
- 更现代的 testbench 写法
- assertion 和 UVM 的基础

---

## 2. 最应该优先掌握的 RTL 子集

这部分是设计岗也应该会的 SystemVerilog。

### 2.1 logic

Verilog 中常见：

```verilog
reg  [7:0] data_r;
wire [7:0] data_w;
```

SystemVerilog 中常用：

```systemverilog
logic [7:0] data;
logic       valid;
```

`logic` 可以替代大部分 `reg` 和 `wire` 的使用场景，让代码更统一。

注意：

- `logic` 不是新的硬件结构
- 它只是更强的变量类型
- 多驱动信号仍然不能随便用 `logic`
- 连续赋值和过程赋值不要混着驱动同一个 `logic`

推荐规则：

```text
模块内部信号：优先 logic
多驱动网络：再考虑 wire / tri
```

---

### 2.2 always_ff

传统 Verilog：

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        q <= 1'b0;
    else
        q <= d;
end
```

SystemVerilog 推荐：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        q <= 1'b0;
    else
        q <= d;
end
```

作用：

- 明确表示这是时序逻辑
- 工具可以检查不规范写法
- 可读性更好

使用建议：

```text
所有寄存器逻辑优先用 always_ff
时序逻辑中使用非阻塞赋值 <=
```

---

### 2.3 always_comb

传统 Verilog：

```verilog
always @(*) begin
    y = a & b;
end
```

SystemVerilog 推荐：

```systemverilog
always_comb begin
    y = a & b;
end
```

作用：

- 自动推导敏感列表
- 表示组合逻辑意图更明确
- 工具更容易检查 latch、遗漏赋值等问题

使用建议：

```text
组合逻辑优先用 always_comb
组合逻辑中使用阻塞赋值 =
进入 always_comb 后先给默认值
```

示例：

```systemverilog
always_comb begin
    y = '0;

    if (valid)
        y = data;
end
```

---

### 2.4 typedef

`typedef` 用来给类型起名字，让代码更清晰。

```systemverilog
typedef logic [31:0] data_t;

data_t rdata;
data_t wdata;
```

适合用于：

- 数据宽度统一管理
- 总线类型定义
- 状态机类型定义
- packet 类型定义

---

### 2.5 enum

Verilog 状态机常见写法：

```verilog
localparam IDLE = 2'd0;
localparam READ = 2'd1;
localparam WORK = 2'd2;
localparam DONE = 2'd3;
```

SystemVerilog 推荐：

```systemverilog
typedef enum logic [1:0] {
    IDLE,
    READ,
    WORK,
    DONE
} state_t;

state_t state, next_state;
```

优点：

- 状态含义清楚
- 类型更明确
- 波形里更容易看状态名
- 状态机维护更方便

推荐状态机模板：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always_comb begin
    next_state = state;

    unique case (state)
        IDLE: begin
            if (start)
                next_state = READ;
        end

        READ: begin
            next_state = WORK;
        end

        WORK: begin
            if (finish)
                next_state = DONE;
        end

        DONE: begin
            next_state = IDLE;
        end

        default: begin
            next_state = IDLE;
        end
    endcase
end
```

---

### 2.6 struct packed

当一组信号总是一起出现时，可以用 `struct packed` 打包。

```systemverilog
typedef struct packed {
    logic        valid;
    logic [3:0]  id;
    logic [31:0] data;
} req_t;

req_t req;
```

访问方式：

```systemverilog
assign req.valid = in_valid;
assign req.id    = in_id;
assign req.data  = in_data;
```

适合用于：

- request / response
- pipeline stage data
- 总线 payload
- 指令字段
- cache tag 信息

注意：

- RTL 中一般使用 `struct packed`
- `struct unpacked` 更多用于仿真和验证

---

### 2.7 package

`package` 用来管理公共定义。

```systemverilog
package core_pkg;

    parameter int XLEN = 32;

    typedef enum logic [1:0] {
        ALU_ADD,
        ALU_SUB,
        ALU_AND,
        ALU_OR
    } alu_op_t;

    typedef struct packed {
        logic [XLEN-1:0] src0;
        logic [XLEN-1:0] src1;
        alu_op_t         op;
    } alu_req_t;

endpackage
```

使用：

```systemverilog
import core_pkg::*;
```

建议：

```text
公共 parameter 放 package
公共 typedef 放 package
接口协议相关定义放 package
不要在 package 里乱放模块内部细节
```

---

### 2.8 interface

`interface` 用来封装一组端口。

例如 valid-ready 数据流接口：

```systemverilog
interface stream_if #(parameter int DATA_WIDTH = 32);
    logic                  valid;
    logic                  ready;
    logic [DATA_WIDTH-1:0] data;
endinterface
```

模块使用：

```systemverilog
module producer (
    input  logic clk,
    input  logic rst_n,
    stream_if   out_if
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_if.valid <= 1'b0;
            out_if.data  <= '0;
        end else begin
            out_if.valid <= 1'b1;
            out_if.data  <= out_if.data + 1'b1;
        end
    end

endmodule
```

更规范的写法会加 `modport`：

```systemverilog
interface stream_if #(parameter int DATA_WIDTH = 32);
    logic                  valid;
    logic                  ready;
    logic [DATA_WIDTH-1:0] data;

    modport master (
        output valid,
        output data,
        input  ready
    );

    modport slave (
        input  valid,
        input  data,
        output ready
    );
endinterface
```

模块端口：

```systemverilog
module producer (
    input  logic         clk,
    input  logic         rst_n,
    stream_if.master     out_if
);
```

适合用于：

- AXI
- APB
- AHB
- valid-ready stream
- memory interface
- testbench 和 DUT 连接

注意：

```text
interface 很好用，但不同综合工具支持程度可能有差异。
正式项目中要遵守公司 coding guideline。
```

---

### 2.9 parameter / localparam / $clog2

这些你在 Verilog 里可能已经会，但 SystemVerilog 里写法更规范。

```systemverilog
module sync_fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 16,
    localparam int ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,
    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  full,
    output logic                  empty
);
```

建议：

```text
parameter 用于外部可配置参数
localparam 用于模块内部推导参数
宽度相关参数尽量使用 int
$clog2 注意 DEPTH 是否为 1 的特殊情况
```

---

### 2.10 generate

用于参数化生成重复硬件。

```systemverilog
genvar i;

generate
    for (i = 0; i < LANES; i++) begin : gen_lane
        lane_unit u_lane (
            .clk  (clk),
            .rst_n(rst_n),
            .din  (din[i]),
            .dout (dout[i])
        );
    end
endgenerate
```

适合用于：

- 多 lane 结构
- 多 bank SRAM
- 多通道 DMA
- 多个相同处理单元

---

## 3. 你应该快速补的验证特性

如果你偏设计，也不需要一开始把 UVM 全学完。但下面这些最好会。

### 3.1 task / function

写 testbench 很常用。

```systemverilog
task automatic send_data(input logic [31:0] data);
    @(posedge clk);
    valid <= 1'b1;
    wdata <= data;

    do begin
        @(posedge clk);
    end while (!ready);

    valid <= 1'b0;
endtask
```

---

### 3.2 dynamic array / queue

验证中常用 queue 做期望结果缓存。

```systemverilog
logic [31:0] exp_q[$];

exp_q.push_back(32'h1234_5678);

if (actual_data !== exp_q.pop_front()) begin
    $error("Data mismatch");
end
```

---

### 3.3 class

UVM 基于 class，所以要先理解面向对象基础。

```systemverilog
class packet;
    bit [31:0] data;
    bit [3:0]  id;

    function new(bit [31:0] data = 0, bit [3:0] id = 0);
        this.data = data;
        this.id   = id;
    endfunction

    function void print();
        $display("data=%h id=%0d", data, id);
    endfunction
endclass
```

使用：

```systemverilog
packet pkt;

initial begin
    pkt = new(32'hdead_beef, 4'd3);
    pkt.print();
end
```

---

### 3.4 randomize / constraint

验证中用于随机激励。

```systemverilog
class packet;
    rand bit [31:0] data;
    rand bit [3:0]  id;

    constraint c_id {
        id inside {[0:7]};
    }
endclass
```

使用：

```systemverilog
packet pkt;

initial begin
    pkt = new();

    repeat (100) begin
        assert(pkt.randomize());
        $display("data=%h id=%0d", pkt.data, pkt.id);
    end
end
```

---

### 3.5 assertion

SystemVerilog Assertion，简称 SVA。

设计岗也建议掌握基础，因为它非常适合检查协议。

valid-ready 规则：`valid` 拉高后，如果 `ready` 没有来，`valid` 必须保持。

```systemverilog
property p_valid_hold;
    @(posedge clk) disable iff (!rst_n)
    valid && !ready |=> valid;
endproperty

assert property (p_valid_hold)
else $error("valid dropped before ready");
```

常见适用场景：

- valid-ready 协议
- FIFO full/empty
- request/ack
- one-hot 状态
- 状态机非法跳转
- AXI/APB 协议局部检查

---

### 3.6 coverage

功能覆盖率用于回答：关键场景是否测到了。

```systemverilog
covergroup cg_cmd @(posedge clk);
    coverpoint cmd {
        bins read  = {2'b00};
        bins write = {2'b01};
        bins idle  = {2'b10};
    }
endgroup
```

设计岗了解即可，验证岗需要深入。

---

## 4. 可以暂时不急的内容

如果你目标是快速把 SystemVerilog 用起来，下面这些可以后置：

```text
UVM factory 深入机制
UVM config_db 复杂用法
sequence / sequencer 高级写法
DPI-C
program block
semaphore / mailbox 高级用法
coverage cross 高级建模
constraint solve order
```

这些不是不重要，而是不适合一开始占用太多时间。

---

## 5. Verilog 到 SystemVerilog 的迁移建议

### 5.1 模块端口

传统写法：

```verilog
module adder (
    input  [31:0] a,
    input  [31:0] b,
    output [31:0] y
);
```

推荐写法：

```systemverilog
module adder (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
```

---

### 5.2 组合逻辑

从：

```verilog
always @(*) begin
    y = a + b;
end
```

迁移到：

```systemverilog
always_comb begin
    y = a + b;
end
```

---

### 5.3 时序逻辑

从：

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        q <= 1'b0;
    else
        q <= d;
end
```

迁移到：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        q <= 1'b0;
    else
        q <= d;
end
```

---

### 5.4 状态机

从：

```verilog
localparam IDLE = 2'd0;
localparam BUSY = 2'd1;
localparam DONE = 2'd2;
```

迁移到：

```systemverilog
typedef enum logic [1:0] {
    IDLE,
    BUSY,
    DONE
} state_t;
```

---

### 5.5 总线信号

从一堆分散信号：

```systemverilog
logic        req_valid;
logic        req_ready;
logic [31:0] req_addr;
logic [31:0] req_data;
logic [3:0]  req_id;
```

迁移到结构体：

```systemverilog
typedef struct packed {
    logic        valid;
    logic [31:0] addr;
    logic [31:0] data;
    logic [3:0]  id;
} req_t;

req_t req;
logic req_ready;
```

或者进一步迁移到 interface。

---

## 6. 快速学习路线

你已经会 Verilog，不需要花很久。建议按这个节奏：

### 第 1 阶段：1 到 2 天

目标：把 RTL 写法换成 SystemVerilog 风格。

学习内容：

- `logic`
- `always_ff`
- `always_comb`
- `typedef`
- `enum`
- `struct packed`
- `parameter int`
- `$clog2`

练习：

- 用 SV 重写一个 counter
- 用 SV 重写一个 FSM
- 用 SV 写一个 valid-ready pipeline stage

---

### 第 2 阶段：2 到 4 天

目标：掌握工程化组织方式。

学习内容：

- `package`
- `import`
- `interface`
- `modport`
- `generate`
- `unique case`
- `priority case`

练习：

- 写一个 `common_pkg.sv`
- 写一个 `stream_if.sv`
- 写一个参数化 FIFO
- 写一个多 lane generate 示例

---

### 第 3 阶段：3 到 5 天

目标：能写更好的 testbench。

学习内容：

- `task automatic`
- `function`
- `queue`
- `dynamic array`
- `class` 基础
- `randomize`
- `constraint`

练习：

- 给 FIFO 写随机 testbench
- 用 queue 做 scoreboard
- 随机产生读写操作
- 自动检查输出正确性

---

### 第 4 阶段：3 到 7 天

目标：掌握基础断言和覆盖率。

学习内容：

- immediate assertion
- concurrent assertion
- `property`
- `assert property`
- `cover property`
- `covergroup` 基础

练习：

- 给 valid-ready 写 assertion
- 给 FIFO full/empty 写 assertion
- 给 FSM 状态跳转写 assertion
- 写简单 coverage

---

### 第 5 阶段：按方向选择

如果偏设计岗：

```text
SystemVerilog RTL 子集
AXI / APB
CDC
FIFO
pipeline
RISC-V / AI accelerator
综合和 STA
```

如果偏验证岗：

```text
SystemVerilog 验证子集
class / random / constraint
SVA
coverage
UVM
AXI VIP / protocol verification
formal verification
```

---

## 7. 建议做的练习项目

### 项目 1：valid-ready pipeline

要求：

- 使用 `logic`
- 使用 `always_ff`
- 使用 `always_comb`
- 支持 backpressure
- 加 assertion 检查 valid 保持

---

### 项目 2：同步 FIFO

要求：

- 参数化 `DATA_WIDTH`
- 参数化 `DEPTH`
- 使用 `$clog2`
- 使用 `struct packed` 组织状态信息
- 写随机 testbench
- 使用 queue 做 scoreboard
- 加 full/empty assertion

---

### 项目 3：异步 FIFO

要求：

- 双时钟域
- gray code 指针
- 两级同步器
- CDC 思想清楚
- 加基本 assertion

---

### 项目 4：AXI-lite slave

要求：

- 使用 interface 或结构化端口
- 实现寄存器读写
- 支持 backpressure
- 写 testbench 自动读写检查
- 加协议相关 assertion

---

### 项目 5：小型计算模块验证

例如：

- ALU
- MAC
- FIR filter
- matrix multiply block

要求：

- 使用 package 定义公共类型
- 使用 struct packed 定义 request/response
- 随机激励
- scoreboard 对比参考模型
- coverage 统计关键场景

---

## 8. 最小必会清单

如果时间有限，至少掌握这些：

```text
logic
always_ff
always_comb
typedef
enum
struct packed
package
import
interface
modport
parameter int
localparam int
$clog2
generate
unique case
task automatic
queue
class 基础
randomize
constraint
assert property 基础
```

---

## 9. 学习时要避免的误区

### 误区 1：把 SystemVerilog 当成只用于验证

不对。SystemVerilog 的 RTL 子集在现代数字设计里很常见。

---

### 误区 2：一上来就学 UVM

不建议。应该先掌握：

```text
class
randomize
constraint
interface
virtual interface
transaction
driver
monitor
scoreboard
```

再进入 UVM。

---

### 误区 3：所有 SV 语法都往 RTL 里写

不是所有 SV 特性都能综合。

RTL 中要谨慎使用：

```text
class
dynamic array
queue
mailbox
semaphore
randomize
constraint
covergroup
initial 中的复杂激励
```

这些主要用于验证。

---

### 误区 4：觉得 interface 一定能随便综合

`interface` 很有用，但不同公司、不同工具、不同流程对它的接受程度不完全一样。

建议：

```text
学习和个人项目可以用
正式项目遵守团队规范
如果工具不支持，退回普通端口或 struct 化端口
```

---

## 10. 推荐最终能力目标

学完这份指南后，你应该能做到：

```text
1. 用 SystemVerilog 写规范 RTL
2. 用 enum 写清晰状态机
3. 用 struct/package 管理复杂信号
4. 用 interface 封装常见协议端口
5. 写参数化模块
6. 写随机 testbench
7. 用 queue 做 scoreboard
8. 用 assertion 检查协议
9. 看懂 UVM 的基本结构
10. 能把 Verilog 项目迁移成更工程化的 SV 风格
```

---

## 11. 建议的短期安排

如果你已经 Verilog 比较熟，建议这样安排：

```text
第 1 天：
logic / always_ff / always_comb / enum

第 2 天：
typedef / struct packed / package / parameter int

第 3 天：
interface / modport / generate

第 4 天：
task / queue / class 基础 / randomize

第 5 天：
assertion / coverage 基础

第 6-10 天：
做一个同步 FIFO 或 AXI-lite slave，并写完整 testbench
```

真正重要的不是把语法看完，而是尽快写一个小项目。

推荐第一个完整练习：

```text
sync_fifo.sv
sync_fifo_tb.sv
common_pkg.sv
```

要求：

- RTL 使用 `logic / always_ff / always_comb`
- 参数化宽度和深度
- testbench 使用随机读写
- queue 做 scoreboard
- assertion 检查 full/empty 和读写规则

这个项目做完，你的 SystemVerilog 就不是“看过”，而是“能用了”。
