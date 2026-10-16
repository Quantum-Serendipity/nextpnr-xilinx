module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, fb, o0, o1, o2, b0, b1, b2;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(10.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(10.0),
        .CLKOUT1_DIVIDE(40),
        .CLKOUT1_PHASE(45.0),
        .CLKOUT2_DIVIDE(40)
    ) mmcm (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(o0),
        .CLKOUT1(o1),
        .CLKOUT2(o2),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG g0 (.I(o0), .O(b0));
    BUFG g1 (.I(o1), .O(b1));
    BUFG g2 (.I(o2), .O(b2));

    reg [31:0] lfsr = 32'h1;
    always @(posedge b0)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    (* keep *) reg [15:0] x = 0, y = 0;
    always @(posedge b0) begin
        x <= lfsr[15:0];
        y <= lfsr[31:16];
    end

    (* use_dsp = "no" *) wire [31:0] prod = x * y;

    (* keep *) reg [31:0] p_shift = 0;
    (* keep *) reg [31:0] p_zero = 0;
    always @(posedge b1)
        p_shift <= prod;
    always @(posedge b2)
        p_zero <= prod;

    assign led = p_shift[31:24] ^ p_shift[7:0] ^ p_zero[31:24] ^ p_zero[7:0];
endmodule
