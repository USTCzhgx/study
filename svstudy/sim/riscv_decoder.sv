// ============================================================
// File: riscv_decoder.v
// Topic: mini RISC-V decoder practice
// ============================================================
//
// Function:
//   Decode a small subset of RV32I instructions into control signals.
//
// Dependency:
//   This module can use alu_op_t and decode_t from core_pkg.v.
//
// Suggested module ports:
//   module riscv_decoder (
//       input  logic [31:0] instr,
//       output core_pkg::decode_t dec
//   );
//
// Practice goals:
//   1. Extract instruction fields.
//   2. Decode opcode, funct3, and funct7.
//   3. Generate immediate values.
//   4. Use enum ALU operations from core_pkg.
//   5. Use always_comb.
//   6. Use case or casez carefully.
//
// Instruction fields:
//   opcode = instr[6:0]
//   rd     = instr[11:7]
//   funct3 = instr[14:12]
//   rs1    = instr[19:15]
//   rs2    = instr[24:20]
//   funct7 = instr[31:25]
//
// Required instruction subset:
//   add
//   sub
//   and
//   or
//   xor
//   addi
//   lw
//   sw
//   beq
//   jal
//   lui
//
// Immediate formats to practice:
//   I-type immediate for addi and lw
//   S-type immediate for sw
//   B-type immediate for beq
//   J-type immediate for jal
//   U-type immediate for lui
//
// Suggested decode outputs:
//   dec.reg_write
//   dec.mem_read
//   dec.mem_write
//   dec.branch
//   dec.jump
//   dec.alu_op
//   dec.rs1
//   dec.rs2
//   dec.rd
//   dec.imm
//
// Functional requirements:
//   1. Give every output a safe default value at the start of always_comb.
//   2. x-type fields should still be assigned from instr where useful.
//   3. Unsupported instructions should produce safe control defaults.
//   4. add/sub should differ by funct7.
//   5. lw should assert mem_read and reg_write.
//   6. sw should assert mem_write and not reg_write.
//   7. beq should assert branch.
//   8. jal should assert jump and reg_write.
//   9. lui should write the U-type immediate to rd.
//
// Optional assertions:
//   1. mem_read and mem_write should not both be true.
//   2. branch and jump should not both be true for this simple subset.
//
