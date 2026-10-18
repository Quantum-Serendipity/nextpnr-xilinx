`ifndef MMCM_NAME
`define MMCM_NAME mmcm
`endif
module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk, fb, pix_clk, o1, pix_clk_g, aux_clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG gs (.I(clk_ibuf), .O(clk));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(10.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(25.0),
        .CLKOUT1_DIVIDE(10)
    ) `MMCM_NAME (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(pix_clk),
        .CLKOUT1(o1),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG gp (.I(pix_clk), .O(pix_clk_g));
    BUFG ga (.I(o1), .O(aux_clk));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [15:0] p = 0;
    always @(posedge pix_clk_g)
        p <= lfsr;

    (* keep *) reg [15:0] r = 0;
    always @(posedge aux_clk)
        r <= p;

    (* keep *) reg [15:0] q = 0;
    always @(posedge clk)
        q <= r;

    assign led = q[15:8] ^ q[7:0];
endmodule
