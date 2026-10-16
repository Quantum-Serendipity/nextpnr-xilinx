module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, pll_fb, pll_out, clk_a, clk_b, clk_m;
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
    BUFG bg_b (.I(pll_out), .O(clk_b));

    reg sel = 0;
    always @(posedge clk_a)
        sel <= btn;
    BUFGMUX bm (.I0(clk_ibuf), .I1(pll_out), .S(sel), .O(clk_m));

    reg [15:0] lfsr_a = 16'h1, lfsr_m = 16'h1;
    always @(posedge clk_a)
        lfsr_a <= {lfsr_a[14:0], lfsr_a[15] ^ lfsr_a[13] ^ lfsr_a[12] ^ lfsr_a[10] ^ btn};
    always @(posedge clk_m)
        lfsr_m <= {lfsr_m[14:0], lfsr_m[15] ^ lfsr_m[13] ^ lfsr_m[12] ^ lfsr_m[10] ^ btn};

    (* keep *) reg [7:0] from_a_to_b = 0, from_m_to_b = 0;
    (* keep *) reg [7:0] from_m_to_a = 0;
    always @(posedge clk_b) begin
        from_a_to_b <= lfsr_a[7:0] + lfsr_a[15:8];
        from_m_to_b <= lfsr_m[7:0] + lfsr_m[15:8];
    end
    always @(posedge clk_a)
        from_m_to_a <= lfsr_m[7:0] ^ lfsr_m[15:8];

    assign led = from_a_to_b ^ from_m_to_b ^ from_m_to_a;
endmodule
