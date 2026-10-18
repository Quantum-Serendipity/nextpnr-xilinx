module top (
    input clk_i,
    output [7:0] led
);
    wire clk_ibuf, fb, mo0, mo0b, ck0, ck0b;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(8.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(16.0),
        .CLKOUT0_DUTY_CYCLE(0.25)
    ) mmcm (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(mo0),
        .CLKOUT0B(mo0b),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG bg0 (.I(mo0), .O(ck0));
    BUFG bg0b (.I(mo0b), .O(ck0b));

    (* keep *) reg [3:0] p0_q = 0;
    (* keep *) reg [3:0] pb_q = 0;
    always @(posedge ck0)
        p0_q <= p0_q + 1'b1;
    always @(posedge ck0b)
        pb_q <= p0_q + {p0_q[1:0], p0_q[3:2]};

    assign led = {p0_q, pb_q};
endmodule
