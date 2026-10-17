module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk, fb, o0, o1, pix_clk, pix5x_clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG gs (.I(clk_ibuf), .O(clk));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(10.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(25.0),
        .CLKOUT1_DIVIDE(5)
    ) mmcm (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(o0),
        .CLKOUT1(o1),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG gp (.I(o0), .O(pix_clk));
    BUFG g5 (.I(o1), .O(pix5x_clk));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [15:0] p = 0;
    always @(posedge pix_clk)
        p <= lfsr;

    (* keep *) reg [15:0] q = 0;
    always @(posedge clk)
        q <= p;

    (* keep *) reg [15:0] r = 0;
    always @(posedge pix5x_clk)
        r <= r + 1'b1;

    assign led = q[15:8] ^ q[7:0] ^ r[15:8];
endmodule
