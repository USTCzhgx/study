// ============================================================
// File: core_pkg.v
// Topic: package / enum / struct packed practice
// ============================================================
//
// Function:
//   Define common types for ALU and mini RISC-V decoder exercises.
//
// Practice goals:
//   1. Create a SystemVerilog package named core_pkg.
//   2. Define an enum type for ALU operations.
//   3. Define packed structs for ALU request and ALU response.
//   4. Reuse these types in alu.v and riscv_decoder.v.
//
// Required package:
//   package core_pkg;
//       ...
//   endpackage
//
// Suggested enum:
//   typedef enum logic [3:0] {
//       ALU_ADD,
//       ALU_SUB,
//       ALU_AND,
//       ALU_OR,
//       ALU_XOR,
//       ALU_SLL,
//       ALU_SRL,
//       ALU_SRA,
//       ALU_SLT,
//       ALU_SLTU
//   } alu_op_t;
//
// Suggested struct:
//   typedef struct packed {
//       logic [31:0] src0;
//       logic [31:0] src1;
//       alu_op_t     op;
//   } alu_req_t;
//
//   typedef struct packed {
//       logic [31:0] result;
//       logic        zero;
//   } alu_rsp_t;
//
// Optional decoder struct:
//   typedef struct packed {
//       logic        reg_write;
//       logic        mem_read;
//       logic        mem_write;
//       logic        branch;
//       logic        jump;
//       alu_op_t     alu_op;
//       logic [4:0]  rs1;
//       logic [4:0]  rs2;
//       logic [4:0]  rd;
//       logic [31:0] imm;
//   } decode_t;
//
// Notes:
//   Put shared types here instead of redefining them in every module.
//
