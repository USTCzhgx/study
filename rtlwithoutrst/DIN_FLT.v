`timescale 1ns/1ps

module DIN_FLT (
    input  wire clk,
    input  wire rst_n,

    input  wire din_sop,
    input  wire din_eop,

    output reg  wr_en,
    output reg  pkt_commit,
    output reg  pkt_error,
    output wire packet_active
);

    localparam IDLE = 1'b0;
    localparam RECV = 1'b1;

    reg [6:0] byte_cnt;
    reg       flt_state;

    assign packet_active = flt_state;


    //----------------------------------------------------------------------
    // State
    //----------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flt_state <= IDLE;
        end
        else begin
            case (flt_state)

                IDLE: begin
                    if (din_sop && !din_eop) begin
                        // Receive the first byte
                        flt_state <= RECV;
                    end
                    else begin
                        flt_state <= IDLE;
                    end
                end


                RECV: begin
                    if (din_sop && din_eop) begin
                        // SOP and EOP asserted together
                        flt_state <= IDLE;
                    end

                    else if (din_sop) begin
                        // Repeated SOP:
                        // discard old packet and start a new packet
                        flt_state <= RECV;
                    end

                    else if (din_eop) begin
                        // Current packet ends
                        flt_state <= IDLE;
                    end

                    else if (byte_cnt == 7'd127) begin
                        // The 128th byte arrives without EOP
                        flt_state <= IDLE;
                    end

                    else begin
                        flt_state <= RECV;
                    end
                end


                default: begin
                    flt_state <= IDLE;
                end

            endcase
        end
    end


    //----------------------------------------------------------------------
    // Byte counter
    //
    // flt_state is reset to IDLE.  byte_cnt is initialized before every
    // transition into RECV and is therefore never consumed before being
    // written; it does not require a resettable storage cell.
    //----------------------------------------------------------------------

    always @(posedge clk) begin
        case (flt_state)
            IDLE: begin
                if (din_sop && !din_eop)
                    byte_cnt <= 7'd1;
                else
                    byte_cnt <= 7'd0;
            end

            RECV: begin
                if (din_sop && din_eop)
                    byte_cnt <= 7'd0;
                else if (din_sop)
                    byte_cnt <= 7'd1;
                else if (din_eop)
                    byte_cnt <= 7'd0;
                else if (byte_cnt == 7'd127)
                    byte_cnt <= 7'd0;
                else
                    byte_cnt <= byte_cnt + 7'd1;
            end

            default: byte_cnt <= 7'd0;
        endcase
    end


    //----------------------------------------------------------------------
    // Combinational output logic
    //----------------------------------------------------------------------

    always @(*) begin
        // Default outputs
        wr_en      = 1'b0;
        pkt_commit = 1'b0;
        pkt_error  = 1'b0;

        case (flt_state)

            //--------------------------------------------------------------
            // IDLE state
            //--------------------------------------------------------------

            IDLE: begin
                if (din_sop && !din_eop) begin
                    // First byte of a new packet
                    wr_en = 1'b1;
                end
                else if (din_eop) begin
                    // EOP without SOP, including SOP/EOP together
                    pkt_error = 1'b1;
                end
            end


            //--------------------------------------------------------------
            // RECV state
            //--------------------------------------------------------------

            RECV: begin
                if (din_sop && din_eop) begin
                    // SOP and EOP asserted together
                    wr_en     = 1'b0;
                    pkt_error = 1'b1;
                end

                else if (din_sop) begin
                    // Repeated SOP:
                    // current beat is the first byte of the new packet
                    wr_en     = 1'b1;
                    pkt_error = 1'b1;
                end

                else if (din_eop) begin
                    // byte_cnt is the number of bytes before current beat
                    if (byte_cnt >= 7'd3) begin
                        // Legal packet length: 4 to 128 bytes
                        wr_en      = 1'b1;
                        pkt_commit = 1'b1;
                    end
                    else begin
                        // Short packet
                        wr_en     = 1'b0;
                        pkt_error = 1'b1;
                    end
                end

                else if (byte_cnt == 7'd127) begin
                    // Current beat is byte 128 without EOP
                    wr_en     = 1'b0;
                    pkt_error = 1'b1;
                end

                else begin
                    // Normal packet data
                    wr_en = 1'b1;
                end
            end


            default: begin
                wr_en      = 1'b0;
                pkt_commit = 1'b0;
                pkt_error  = 1'b0;
            end

        endcase
    end

endmodule
