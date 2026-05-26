// ============================================================
// File: apb_reg_block.v
// Topic: APB-like register block practice
// ============================================================
//
// Function:
//   Implement a small memory-mapped register block using apb_if.slave.
//
// Suggested module ports:
//   module apb_reg_block (
//       input  logic clk,
//       input  logic rst_n,
//       apb_if.slave apb
//   );
//
// Practice goals:
//   1. Use apb_if.slave modport.
//   2. Decode addresses.
//   3. Implement read/write registers.
//   4. Use always_ff for registers.
//   5. Use always_comb for read data and error decode.
//
// Register map:
//   0x00 CTRL   : read/write
//   0x04 STATUS : read-only
//   0x08 DATA   : read/write
//
// Functional requirements:
//   1. A transfer is active when apb.psel && apb.penable is true.
//   2. A write transfer is active when apb.psel && apb.penable && apb.pwrite.
//   3. A read transfer is active when apb.psel && apb.penable && !apb.pwrite.
//   4. Writes to CTRL should update ctrl_reg.
//   5. Writes to DATA should update data_reg.
//   6. Writes to STATUS should not change status_reg.
//   7. Reads from each valid address should return the corresponding register.
//   8. Invalid address should assert apb.pslverr.
//   9. apb.pready can be tied high for this simple version.
//
// Suggested internal registers:
//   logic [31:0] ctrl_reg;
//   logic [31:0] status_reg;
//   logic [31:0] data_reg;
//
// Optional enum practice:
//   typedef enum logic [1:0] {
//       REG_CTRL,
//       REG_STATUS,
//       REG_DATA,
//       REG_INVALID
//   } reg_sel_t;
//
// Optional assertions:
//   1. STATUS should not change due to APB write.
//   2. pslverr should be high only for invalid addresses during active transfer.
//
