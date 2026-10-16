module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, fb, o0, o1, b0, b1;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(12.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),
        .CLKOUT1_DIVIDE(10),
        .CLKOUT1_PHASE(180.0)
    ) mmcm (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(o0),
        .CLKOUT1(o1),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG g0 (.I(o0), .O(b0));
    BUFG g1 (.I(o1), .O(b1));

    reg [15:0] lfsr = 16'h1;
    always @(posedge b1)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [15:0] p = 0;
    always @(posedge b0)
        p <= lfsr;

    assign led = p[15:8] ^ p[7:0];
endmodule
