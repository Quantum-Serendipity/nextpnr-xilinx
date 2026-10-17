module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk, sclk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG gs (.I(clk_ibuf), .O(clk));

    (* keep *) reg div = 0;
    always @(posedge clk)
        div <= ~div;
    BUFG gd (.I(div), .O(sclk));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [15:0] p = 0;
    always @(posedge sclk)
        p <= lfsr;

    (* keep *) reg [15:0] q = 0;
    always @(posedge clk)
        q <= p;

    assign led = q[15:8] ^ q[7:0];
endmodule
