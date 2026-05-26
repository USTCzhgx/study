// ============================================================
// File: alu.v
// Topic: package / enum / struct / unique case practice
// ============================================================
//
// Function:
//   Implement a simple 32-bit ALU.
//
// Dependency:
//   This module should use types from core_pkg.v.
//
// Suggested module ports:
//   module alu (
//       input  core_pkg::alu_req_t req,
//       output core_pkg::alu_rsp_t rsp
//   );
//
// Practice goals:
//   1. Import or reference types from core_pkg.
//   2. Use alu_op_t enum values in a case statement.
//   3. Use always_comb.
//   4. Use unique case.
//   5. Drive every output in all branches.
//
// Functional requirements:
//   1. ALU_ADD  : src0 + src1
//   2. ALU_SUB  : src0 - src1
//   3. ALU_AND  : src0 & src1
//   4. ALU_OR   : src0 | src1
//   5. ALU_XOR  : src0 ^ src1
//   6. ALU_SLL  : src0 << src1[4:0]
//   7. ALU_SRL  : src0 >> src1[4:0]
//   8. ALU_SRA  : signed arithmetic right shift
//   9. ALU_SLT  : signed less-than
//   10. ALU_SLTU: unsigned less-than
//
// Output requirements:
//   1. rsp.result should contain the operation result.
//   2. rsp.zero should be 1 when rsp.result == 0.
//
// Notes:
//   For signed compare or arithmetic shift, use signed casting carefully.
//
// ============================================================
// File: alu.v
// Topic: package / enum / struct / unique case practice
// ============================================================

import core_pkg::*;

module alu (
    input  core_pkg::alu_req_t req,
    output core_pkg::alu_rsp_t rsp
);

always_comb begin
    rsp.result = 32'b0;
    rsp.zero   = 1'b0;

    unique case (req.op)
        ALU_ADD: begin
            rsp.result = req.src0 + req.src1;
        end

        ALU_SUB: begin
            rsp.result = req.src0 - req.src1;
        end

        ALU_AND: begin
            rsp.result = req.src0 & req.src1;
        end

        ALU_OR: begin
            rsp.result = req.src0 | req.src1;
        end

        ALU_XOR: begin
            rsp.result = req.src0 ^ req.src1;
        end

        ALU_SLL: begin
            rsp.result = req.src0 << req.src1[4:0];
        end

        ALU_SRL: begin
            rsp.result = req.src0 >> req.src1[4:0];
        end

        ALU_SRA: begin
            rsp.result = $signed(req.src0) >>> req.src1[4:0];
        end

        ALU_SLT: begin
            rsp.result = ($signed(req.src0) < $signed(req.src1)) ? 32'd1 : 32'd0;
        end

        ALU_SLTU: begin
            rsp.result = (req.src0 < req.src1) ? 32'd1 : 32'd0;
        end

        default: begin
            rsp.result = 32'b0;
        end
    endcase

    rsp.zero = (rsp.result == 32'b0);
end

endmodule