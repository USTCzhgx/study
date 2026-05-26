// ============================================================
// File: sync_fifo.v
// Topic: parameterized synchronous FIFO practice
// ============================================================
//
// Function:
//   Implement a synchronous FIFO using stream_if on both sides.
//
// Suggested module ports:
//   module sync_fifo #(
//       parameter int DATA_WIDTH = 32,
//       parameter int DEPTH      = 8
//   ) (
//       input  logic clk,
//       input  logic rst_n,
//       stream_if.slave  in,
//       stream_if.master out
//   );
//
// Practice goals:
//   1. Use parameter and localparam.
//   2. Use $clog2 to calculate pointer width.
//   3. Use always_ff for memory write, read pointer, write pointer, and count.
//   4. Use stream_if with modport.
//   5. Optionally use struct packed to group FIFO state.
//
// Functional requirements:
//   1. Write data when in.valid && in.ready is true.
//   2. Read data when out.valid && out.ready is true.
//   3. in.ready should be high when FIFO is not full.
//   4. out.valid should be high when FIFO is not empty.
//   5. full should mean count == DEPTH.
//   6. empty should mean count == 0.
//   7. Reset should clear pointers, count, and output valid state.
//
// Suggested internal signals:
//   localparam int PTR_WIDTH = $clog2(DEPTH);
//   logic [DATA_WIDTH-1:0] mem [DEPTH];
//   logic [PTR_WIDTH-1:0] rd_ptr;
//   logic [PTR_WIDTH-1:0] wr_ptr;
//   logic [PTR_WIDTH:0]   count;
//
// Optional struct practice:
//   typedef struct packed {
//       logic [PTR_WIDTH-1:0] rd_ptr;
//       logic [PTR_WIDTH-1:0] wr_ptr;
//       logic [PTR_WIDTH:0]   count;
//   } fifo_state_t;
//
// Optional assertions:
//   1. count should never be greater than DEPTH.
//   2. full and empty should not both be true.
//   3. If out.valid && !out.ready, out.data should remain stable.
//
