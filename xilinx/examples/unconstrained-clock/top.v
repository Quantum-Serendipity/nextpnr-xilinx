module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [7:0] a = 0, b = 0;
    always @(posedge clk) begin
        a <= lfsr[7:0];
        b <= lfsr[15:8];
    end

    (* use_dsp = "no" *) wire [15:0] prod = a * b;

    (* keep *) reg [15:0] p = 0;
    always @(posedge clk)
        p <= prod;

    assign led = p[15:8] ^ p[7:0];
endmodule
