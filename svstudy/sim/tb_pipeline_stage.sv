`timescale 1ns/1ps

module tb_pipeline_stage;
    localparam int DATA_WIDTH = 32;

    logic clk;
    logic rst_n;

    stream_if #(DATA_WIDTH) in_if();
    stream_if #(DATA_WIDTH) out_if();

    pipeline_stage #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .in    (in_if),
        .out   (out_if)
    );

    logic [DATA_WIDTH-1:0] expected_q[$];
    logic [DATA_WIDTH-1:0] prev_out_data;
    logic                  prev_stalled;
    int                    error_count;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            error_count++;
            $error("%0t %s", $time, msg);
        end
    endtask

    task automatic push_word(input logic [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            in_if.valid <= 1'b1;
            in_if.data  <= data;

            do begin
                @(posedge clk);
            end while (!in_if.ready);

            expected_q.push_back(data);

            @(negedge clk);
            in_if.valid <= 1'b0;
            in_if.data  <= '0;
        end
    endtask

    task automatic push_word_no_gap(input logic [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            in_if.valid <= 1'b1;
            in_if.data  <= data;

            do begin
                @(posedge clk);
            end while (!in_if.ready);

            expected_q.push_back(data);
        end
    endtask

    task automatic finish_input_stream;
        begin
            @(negedge clk);
            in_if.valid <= 1'b0;
            in_if.data  <= '0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_stalled <= 1'b0;
            prev_out_data <= '0;
        end else begin
            if (prev_stalled) begin
                check(out_if.valid, "out.valid dropped while stalled");
                check(out_if.data == prev_out_data, "out.data changed while stalled");
            end

            prev_stalled <= out_if.valid && !out_if.ready;
            prev_out_data <= out_if.data;
        end
    end

    always @(posedge clk) begin
        if (rst_n && out_if.valid && out_if.ready) begin
            check(expected_q.size() > 0, "DUT produced unexpected output");

            if (expected_q.size() > 0) begin
                logic [DATA_WIDTH-1:0] expected;
                expected = expected_q.pop_front();
                check(out_if.data == expected, "DUT output data mismatch");
            end
        end
    end

    initial begin
        error_count = 0;
        rst_n = 1'b0;
        in_if.valid = 1'b0;
        in_if.data = '0;
        out_if.ready = 1'b0;

        repeat (3) @(posedge clk);
        check(out_if.valid == 1'b0, "out.valid should be 0 during reset");

        @(negedge clk);
        rst_n = 1'b1;
        out_if.ready = 1'b1;

        @(posedge clk);
        check(out_if.valid == 1'b0, "out.valid should be 0 after reset");

        $display("[%0t] Test 1: downstream always ready", $time);
        fork
            begin
                push_word_no_gap(32'h0000_00a1);
                push_word_no_gap(32'h0000_00b2);
                push_word_no_gap(32'h0000_00c3);
                finish_input_stream();
            end
        join

        repeat (4) @(posedge clk);
        check(expected_q.size() == 0, "not all always-ready outputs were received");

        $display("[%0t] Test 2: downstream backpressure", $time);
        out_if.ready = 1'b0;
        fork
            begin
                push_word(32'h1111_0001);
                push_word(32'h2222_0002);
            end
            begin
                repeat (4) @(posedge clk);
                @(negedge clk);
                out_if.ready = 1'b1;
            end
        join

        repeat (5) @(posedge clk);
        check(expected_q.size() == 0, "not all backpressure outputs were received");

        if (error_count == 0) begin
            $display("[%0t] PASS", $time);
        end else begin
            $display("[%0t] FAIL: %0d error(s)", $time, error_count);
        end

        $finish;
    end
endmodule
