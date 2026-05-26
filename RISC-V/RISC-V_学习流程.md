# RISC-V 学习流程

适用对象：已经有 Verilog 基础，准备学习数字 IC 设计，希望通过 RISC-V 做一个有含金量的 RTL 项目。

目标不是只“看懂指令集”，而是最终能做出：

```text
一个可仿真、可验证、可扩展的 RV32I/RV32IM 小型 RISC-V CPU 或 SoC
```

建议主线：

```text
ISA 基础
→ 单周期 CPU
→ 五级流水 CPU
→ hazard / forwarding / flush
→ CSR / exception / interrupt
→ bus / memory / peripheral
→ SoC 集成
→ testbench / assertion / benchmark
```

---

## 1. 先理解 RISC-V 是什么

RISC-V 不是一种 HDL，也不是一个具体 CPU。

它是一个开放指令集架构，规定了：

- 有哪些指令
- 指令怎么编码
- 通用寄存器如何使用
- load/store 如何访问内存
- 分支和跳转如何工作
- CSR、异常、中断、特权级如何定义

实现 RISC-V 可以用：

- Verilog
- SystemVerilog
- VHDL
- Chisel
- SpinalHDL

对你来说，建议：

```text
学习和项目实现：Verilog 或 SystemVerilog
工程化风格：更推荐 SystemVerilog
```

---

## 2. 推荐学习目标

不要一开始就做很复杂的 Linux 级 CPU。

推荐目标分三档：

### 入门目标

```text
RV32I 单周期 CPU
支持基本整数指令
能跑简单汇编程序
```

### 进阶目标

```text
RV32I 五级流水 CPU
支持 hazard / forwarding / branch flush
能跑较完整的裸机 C 程序
```

### 简历项目目标

```text
RV32IM 五级流水 CPU
支持 CSR / timer interrupt
接入 AXI-lite 或 Wishbone 总线
集成 UART / GPIO / timer
写 testbench 和 assertion
能跑 benchmark 或简单 demo
```

---

## 3. 第 0 阶段：前置知识

你已经会 Verilog，所以重点补这些：

### 3.1 计算机组成

必须理解：

- PC
- 指令存储器
- 数据存储器
- register file
- ALU
- control unit
- immediate generation
- branch / jump
- load / store
- pipeline

### 3.2 数字设计基础

需要熟：

- 组合逻辑
- 时序逻辑
- FSM
- pipeline
- valid-ready
- SRAM 读写时序
- 同步复位 / 异步复位
- testbench

### 3.3 SystemVerilog 工程写法

建议会：

- `logic`
- `always_ff`
- `always_comb`
- `enum`
- `struct packed`
- `package`
- `parameter`
- `$clog2`
- `assert property`

---

## 4. 第 1 阶段：学习 RV32I 指令集

先学 RV32I，不要一上来学特权架构和 Linux。

RV32I 是 32 位基础整数指令集，是最适合做教学 CPU 的起点。

### 4.1 需要掌握的指令类型

RISC-V 指令主要分为：

```text
R-type：寄存器和寄存器运算
I-type：立即数运算 / load / jalr
S-type：store
B-type：branch
U-type：lui / auipc
J-type：jal
```

### 4.2 需要掌握的指令

R-type：

```text
add
sub
sll
slt
sltu
xor
srl
sra
or
and
```

I-type：

```text
addi
slti
sltiu
xori
ori
andi
slli
srli
srai
lb
lh
lw
lbu
lhu
jalr
```

S-type：

```text
sb
sh
sw
```

B-type：

```text
beq
bne
blt
bge
bltu
bgeu
```

U-type：

```text
lui
auipc
```

J-type：

```text
jal
```

### 4.3 第一阶段输出

完成一个指令解码表：

```text
opcode
funct3
funct7
rd
rs1
rs2
imm
控制信号
```

建议你自己整理一个表格，后面写 decoder 会非常顺。

---

## 5. 第 2 阶段：写 RV32I 单周期 CPU

单周期 CPU 是最好的入门项目。

虽然它性能差，但结构简单，适合理解 RISC-V 数据通路。

### 5.1 模块划分

建议模块：

```text
rv_core.sv
├── pc_reg.sv
├── instr_rom.sv
├── decoder.sv
├── regfile.sv
├── imm_gen.sv
├── alu.sv
├── branch_unit.sv
├── load_store_unit.sv
└── data_ram.sv
```

### 5.2 数据通路

核心路径：

```text
PC
→ instruction memory
→ decoder
→ register file
→ immediate generator
→ ALU
→ data memory
→ writeback
→ next PC
```

### 5.3 控制信号

decoder 至少输出：

```text
alu_op
alu_src_a_sel
alu_src_b_sel
reg_write_en
wb_sel
mem_read
mem_write
branch_type
jump_type
load_type
store_type
```

### 5.4 单周期 CPU 要支持的最小指令集

建议先支持：

```text
add
sub
and
or
xor
addi
andi
ori
xori
lw
sw
beq
bne
jal
jalr
lui
auipc
```

然后再补全 RV32I。

### 5.5 第一版验证方式

先用手写汇编：

```assembly
addi x1, x0, 5
addi x2, x0, 7
add  x3, x1, x2
sw   x3, 0(x0)
```

检查：

```text
x3 是否等于 12
data_ram[0] 是否等于 12
PC 是否正确跳转
寄存器 x0 是否永远为 0
```

### 5.6 单周期阶段目标

你要能做到：

```text
1. 指令能正确解码
2. ALU 能正确运算
3. load/store 能正确访问内存
4. branch/jump 能正确更新 PC
5. x0 保持为 0
6. 能跑 10 到 20 条自写测试程序
```

---

## 6. 第 3 阶段：升级为五级流水 CPU

经典五级流水：

```text
IF：Instruction Fetch
ID：Instruction Decode
EX：Execute
MEM：Memory Access
WB：Write Back
```

### 6.1 增加流水级寄存器

需要添加：

```text
if_id_reg
id_ex_reg
ex_mem_reg
mem_wb_reg
```

每一级之间传递：

- PC
- instruction
- immediate
- rs1 / rs2 value
- rd / rs1 / rs2 index
- control signals
- ALU result
- memory data

建议用 `struct packed` 管理流水级数据。

示例：

```systemverilog
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
} if_id_t;
```

### 6.2 数据冒险

必须处理：

```text
RAW hazard
load-use hazard
```

解决方式：

- forwarding
- stall

典型 forwarding 来源：

```text
EX/MEM → EX
MEM/WB → EX
```

load-use hazard：

```text
lw x1, 0(x0)
add x2, x1, x3
```

通常需要 stall 一个周期。

### 6.3 控制冒险

branch / jump 会导致错误取指。

需要处理：

- branch taken flush
- jal flush
- jalr flush

简单设计可以在 EX 阶段决定跳转，然后 flush 前面的错误指令。

### 6.4 结构冒险

如果指令存储器和数据存储器分开，结构冒险少。

建议一开始采用：

```text
Harvard 结构
instruction memory 和 data memory 分开
```

这样更容易做。

### 6.5 五级流水阶段目标

你要能做到：

```text
1. 支持基本 RV32I 指令
2. 正确处理 forwarding
3. 正确处理 load-use stall
4. 正确处理 branch/jump flush
5. 跑比单周期更长的汇编程序
6. 能统计 CPI
```

---

## 7. 第 4 阶段：加入 RV32M

RV32M 是乘除法扩展。

包括：

```text
mul
mulh
mulhsu
mulhu
div
divu
rem
remu
```

### 7.1 推荐实现方式

乘法：

```text
第一版：直接使用乘法运算符
第二版：多周期乘法器
第三版：流水乘法器
```

除法：

```text
第一版：多周期除法器
第二版：支持流水暂停
```

### 7.2 需要考虑

- M 扩展指令解码
- 多周期运算对流水线的影响
- busy / done
- stall 控制
- 除零行为
- 有符号和无符号处理

### 7.3 RV32M 阶段目标

```text
1. 支持乘法指令
2. 支持除法指令
3. 多周期执行期间流水线正确暂停
4. 能通过手写测试
```

---

## 8. 第 5 阶段：CSR / exception / interrupt

如果想让项目更像真正 CPU，需要学习 CSR。

### 8.1 先支持少量 CSR

建议先实现：

```text
mstatus
mtvec
mepc
mcause
mie
mip
cycle
instret
```

### 8.2 支持 CSR 指令

```text
csrrw
csrrs
csrrc
csrrwi
csrrsi
csrrci
```

### 8.3 异常

先支持：

```text
illegal instruction
ecall
instruction address misaligned
load/store address misaligned
```

### 8.4 中断

先支持：

```text
machine timer interrupt
machine external interrupt
```

### 8.5 这一阶段目标

```text
1. 能执行 CSR 指令
2. illegal instruction 能进入 trap
3. ecall 能进入 trap
4. timer interrupt 能跳转到 mtvec
5. mret 能返回 mepc
```

---

## 9. 第 6 阶段：接入总线和外设

裸 CPU 项目含金量有限，接总线和外设后更像 SoC。

### 9.1 推荐总线

学习难度从低到高：

```text
自定义简单总线
→ Wishbone
→ APB
→ AXI-lite
→ AXI4
```

建议你优先：

```text
APB 或 AXI-lite
```

### 9.2 推荐外设

先做：

```text
GPIO
UART
timer
simple SRAM controller
```

然后再考虑：

```text
SPI
I2C
DMA
interrupt controller
```

### 9.3 SoC 地址空间示例

```text
0x0000_0000 - 0x0000_FFFF : ROM / instruction memory
0x1000_0000 - 0x1000_FFFF : SRAM
0x2000_0000 - 0x2000_0FFF : GPIO
0x2000_1000 - 0x2000_1FFF : UART
0x2000_2000 - 0x2000_2FFF : TIMER
```

### 9.4 这一阶段目标

```text
1. CPU 通过总线访问 SRAM
2. CPU 能读写 GPIO
3. CPU 能通过 UART 输出字符
4. timer 能产生中断
5. 能跑一个简单裸机程序
```

---

## 10. 第 7 阶段：验证

RISC-V 项目不能只靠看波形。

### 10.1 基础 testbench

至少包括：

```text
clock / reset
instruction memory load
data memory monitor
timeout
pass/fail 检查
波形 dump
```

### 10.2 自检查测试

测试程序最后写一个固定地址：

```text
PASS：写 0x0000_0001
FAIL：写 0xffff_ffff
```

testbench 监控这个地址，自动判断仿真结果。

### 10.3 assertion

建议加：

```text
x0 永远为 0
PC 对齐
非法 opcode 检查
流水线 stall 时寄存器保持
flush 时错误指令不提交
load-use hazard 正确 stall
forwarding 选择正确
```

### 10.4 指令级对比

进阶验证方法：

```text
用 Spike / Sail / riscv-isa-sim 做 reference model
每条提交指令和参考模型比对
```

如果暂时不想接复杂环境，可以先用：

```text
手写汇编
自检查裸机 C 程序
riscv-tests
```

### 10.5 覆盖率

可以统计：

```text
每类指令是否测到
每个 ALU op 是否测到
branch taken / not taken 是否测到
forwarding path 是否测到
load-use stall 是否测到
exception 是否测到
interrupt 是否测到
```

---

## 11. 第 8 阶段：工具链

建议安装和学习：

```text
riscv64-unknown-elf-gcc
objdump
objcopy
readelf
spike
verilator
iverilog
gtkwave
```

### 11.1 常用流程

汇编或 C 程序：

```text
test.S / test.c
```

编译：

```text
riscv64-unknown-elf-gcc
```

反汇编：

```text
riscv64-unknown-elf-objdump
```

转成 memory hex：

```text
riscv64-unknown-elf-objcopy
```

仿真 RTL：

```text
iverilog / verilator / vcs / xrun
```

看波形：

```text
gtkwave / verdi
```

---

## 12. 推荐文件结构

可以这样组织项目：

```text
riscv_core/
├── rtl/
│   ├── core_pkg.sv
│   ├── rv_core.sv
│   ├── pc_reg.sv
│   ├── decoder.sv
│   ├── regfile.sv
│   ├── imm_gen.sv
│   ├── alu.sv
│   ├── branch_unit.sv
│   ├── lsu.sv
│   ├── csr_file.sv
│   └── pipeline_regs.sv
├── soc/
│   ├── soc_top.sv
│   ├── bus_interconnect.sv
│   ├── gpio.sv
│   ├── uart.sv
│   └── timer.sv
├── tb/
│   ├── tb_core.sv
│   ├── tb_soc.sv
│   └── mem_model.sv
├── tests/
│   ├── asm/
│   └── c/
├── scripts/
│   ├── build_sw.mk
│   └── run_sim.sh
└── docs/
    ├── isa_decode_table.md
    ├── pipeline_design.md
    └── verification_plan.md
```

---

## 13. 推荐时间安排

如果你每天能投入 2 到 4 小时，可以这样安排。

### 第 1 周：ISA 和单周期 CPU

任务：

- 学 RV32I 指令格式
- 整理 decode 表
- 写 ALU
- 写 regfile
- 写 imm_gen
- 写 decoder
- 跑通最小单周期 CPU

产出：

```text
RV32I 单周期 CPU 能跑 10 条左右测试程序
```

---

### 第 2 周：补全 RV32I

任务：

- 补全 R/I/S/B/U/J 指令
- 完善 load/store
- 完善 branch/jump
- 写更多手写汇编测试
- x0、PC、内存访问加 assertion

产出：

```text
单周期 CPU 支持大部分 RV32I
```

---

### 第 3 到 4 周：五级流水

任务：

- 拆成 IF/ID/EX/MEM/WB
- 增加流水级寄存器
- 实现 forwarding
- 实现 load-use stall
- 实现 branch flush
- 加 CPI 统计

产出：

```text
五级流水 RV32I CPU
```

---

### 第 5 周：验证增强

任务：

- 自检查 testbench
- 指令覆盖统计
- hazard 测试
- branch 测试
- load/store 测试
- assertion 检查关键行为

产出：

```text
有基本验证体系的 RV32I 流水 CPU
```

---

### 第 6 周：SoC 化

任务：

- 接 APB 或 AXI-lite
- 加 SRAM
- 加 GPIO
- 加 UART
- 加 timer
- 写裸机 C 程序

产出：

```text
能跑裸机程序的小型 RISC-V SoC
```

---

### 第 7 到 8 周：增强和包装

任务：

- 加 CSR
- 加 timer interrupt
- 可选加 RV32M
- 整理 README
- 整理架构图
- 整理验证报告
- 整理 demo

产出：

```text
可放简历和 GitHub 的 RISC-V 项目
```

---

## 14. 学习优先级

如果时间有限，优先级如下：

```text
最高优先级：
RV32I 指令格式
decoder
regfile
ALU
load/store
branch/jump
五级流水
hazard / forwarding / flush

中优先级：
CSR
interrupt
AXI-lite / APB
UART / GPIO / timer
assertion
self-checking testbench

后续优先级：
RV32M
cache
MMU
Linux
out-of-order
branch prediction
superscalar
```

---

## 15. 不建议一开始做的事

不要一上来就做：

```text
Linux 级 RISC-V
MMU
复杂 cache coherence
乱序执行
超标量
完整 AXI4
复杂分支预测
多核
```

这些方向很有价值，但不适合作为第一个 RISC-V 项目。

---

## 16. 简历项目描述模板

如果你完成了进阶版，可以这样描述：

```text
设计并实现基于 SystemVerilog 的 RV32I 五级流水 RISC-V CPU，
支持 R/I/S/B/U/J 类型指令，实现 forwarding、load-use stall、
branch flush 等流水线控制逻辑；构建自检查 testbench，
通过手写汇编和裸机 C 程序验证核心指令、访存和分支行为；
集成 APB/AXI-lite 总线、UART、GPIO、timer 等外设，
形成小型 RISC-V SoC，并支持仿真运行 demo 程序。
```

如果加了 CSR 和中断：

```text
进一步实现 machine mode 下的基础 CSR、exception 和 timer interrupt，
支持 trap 入口跳转与 mret 返回，增强处理器系统级行为完整性。
```

如果加了验证：

```text
使用 SystemVerilog assertion 检查 x0 恒零、PC 对齐、
流水线 stall/flush、valid-ready 协议等关键行为，
并通过功能覆盖统计指令类型、分支方向和 hazard 场景覆盖情况。
```

---

## 17. 推荐最终项目路线

最推荐你做这条：

```text
RV32I 单周期 CPU
→ RV32I 五级流水 CPU
→ 加 forwarding / stall / flush
→ 加自检查 testbench 和 assertion
→ 接 APB 或 AXI-lite
→ 加 UART / GPIO / timer
→ 加 CSR 和 timer interrupt
→ 整理成 GitHub 项目
```

这条路线对数字 IC 设计岗很有帮助，因为它覆盖了：

- RTL 设计
- 数据通路
- 控制逻辑
- pipeline
- hazard 处理
- 总线
- 外设
- 验证
- 系统集成

比单独写几个小模块更能体现工程能力。

---

## 18. 最小可行版本

如果你只想先快速做一个能跑的版本：

```text
1. RV32I 单周期
2. 支持 add/sub/and/or/xor/addi/lw/sw/beq/jal/lui
3. 写手动汇编测试
4. testbench 检查寄存器和内存结果
5. 再逐步补全其他指令
```

这个版本 1 到 2 周内就可以完成。

完成后再决定是否继续升级流水线。

---

## 19. 你应该真正掌握的能力

学 RISC-V 最终不是为了背指令，而是为了掌握 CPU 设计能力：

```text
1. 能从 ISA 推导数据通路
2. 能设计 decoder 和控制信号
3. 能实现 register file 和 ALU
4. 能处理 load/store 和地址对齐
5. 能处理 branch/jump 和 PC 更新
6. 能设计 pipeline register
7. 能解决数据冒险和控制冒险
8. 能写 testbench 自动检查行为
9. 能把 CPU 接到总线和外设
10. 能解释自己的架构取舍
```

如果你能把这些讲清楚，RISC-V 项目就不只是“我写过一个 CPU”，而是能体现你真的理解数字 IC 设计。
