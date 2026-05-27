// ============================================================
// File: pipeline_stage.v
// Topic: valid-ready pipeline stage practice
// ============================================================
//
// Function:
//   Implement a one-entry pipeline stage between two stream_if ports.
//
// Suggested module ports:
//   module pipeline_stage #(
//       parameter int DATA_WIDTH = 32
//   ) (
//       input  logic clk,
//       input  logic rst_n,
//       stream_if.slave  in,
//       stream_if.master out
//   );
//
// Practice goals:
//   1. Use stream_if.slave for the input side.
//   2. Use stream_if.master for the output side.
//   3. Use always_ff for sequential logic.
//   4. Use always_comb or continuous assignment for ready/valid control.
//   5. Understand valid-ready backpressure.
//
// Functional requirements:
//   1. Accept input data when in.valid && in.ready is true.
//   2. Send output data when out.valid && out.ready is true.
//   3. If out.ready is low, hold out.valid and out.data stable.
//   4. Do not drop data when downstream is not ready.
//   5. After reset, out.valid should be 0.
//
// Suggested internal signals:
//   logic full;
//   logic [DATA_WIDTH-1:0] data_q;
//
// Suggested behavior:
//   in.ready  = !full || out.ready;
//   out.valid = full;
//   out.data  = data_q;
//
// Optional assertions:
//   1. If out.valid && !out.ready, out.valid should remain high next cycle.
//   2. If out.valid && !out.ready, out.data should remain stable next cycle.
//
module pipeline_stage #(
    parameter int DATA_WIDTH = 32
) (
    input logic clk,
    input logic rst_n,
    stream_if.slave in,
    stream_if.master out
);

logic full;
logic [DATA_WIDTH-1:0] data_q;

logic in_fire;
logic out_fire;

assign in_fire = in.valid && in.ready;
assign out_fire = out.valid && out.ready;


assign in.ready = !full || out.ready;
assign out.valid = full;
assign out.data = data_q;

always_ff @( posedge clk or negedge rst_n ) begin
    if(~rst_n) begin
        full <= 1'b0;
        data_q <= 'b0;
    end else begin
        if(in_fire) begin
            data_q <= in.data;
        end

        case ({in_fire,out_fire})
            2'b10: full <= 1'b1; // only input
            2'b01: full <= 1'b0; // only output
            2'b11: full <= 1'b1; // output old data, accept new data
            default: full <= full;
        endcase
    end
end



endmodule