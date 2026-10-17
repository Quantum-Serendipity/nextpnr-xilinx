module top (
    input clk_i,
    input ext,
    input ext_nc,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, pll_fb, pll_out, clk_a, clk_x, clk_w, clk_c;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    PLLE2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT(10),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE(20)
    ) pll (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(pll_fb),
        .CLKFBOUT(pll_fb),
        .CLKOUT0(pll_out),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG bg_a (.I(clk_ibuf), .O(clk_a));

    reg sel = 0;
    always @(posedge clk_a)
        sel <= btn;
    BUFGMUX bx (.I0(pll_out), .I1(1'bx), .S(sel), .O(clk_x));
    BUFGMUX bw (.I0(pll_out), .I1(ext_nc), .S(sel), .O(clk_w));
    BUFGMUX bc (.I0(pll_out), .I1(ext), .S(sel), .O(clk_c));

    reg [15:0] lfsr_x = 16'h1, lfsr_w = 16'h1, lfsr_c = 16'h1;
    always @(posedge clk_x)
        lfsr_x <= {lfsr_x[14:0], lfsr_x[15] ^ lfsr_x[13] ^ lfsr_x[12] ^ lfsr_x[10] ^ btn};
    always @(posedge clk_w)
        lfsr_w <= {lfsr_w[14:0], lfsr_w[15] ^ lfsr_w[13] ^ lfsr_w[12] ^ lfsr_w[10] ^ btn};
    always @(posedge clk_c)
        lfsr_c <= {lfsr_c[14:0], lfsr_c[15] ^ lfsr_c[13] ^ lfsr_c[12] ^ lfsr_c[10] ^ btn};

    (* keep *) reg [7:0] from_x = 0, from_w = 0, from_c = 0;
    always @(posedge clk_a) begin
        from_x <= lfsr_x[7:0] + lfsr_x[15:8];
        from_w <= lfsr_w[7:0] + lfsr_w[15:8];
        from_c <= lfsr_c[7:0] + lfsr_c[15:8];
    end

    assign led = from_x ^ from_w ^ from_c;
endmodule
