module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, pll_fb, pll_out, clk_a, clk_b;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    PLLE2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT(10),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE(10)
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

    reg [23:0] lfsr_a = 24'h1, lfsr_b = 24'h1;
    always @(posedge clk_a)
        lfsr_a <= {lfsr_a[22:0], lfsr_a[23] ^ lfsr_a[22] ^ lfsr_a[21] ^ lfsr_a[16] ^ btn};
    always @(posedge clk_b)
        lfsr_b <= {lfsr_b[22:0], lfsr_b[23] ^ lfsr_b[22] ^ lfsr_b[21] ^ lfsr_b[16] ^ btn};

    (* keep *) reg [11:0] xa = 0, xb = 0, ya = 0, yb = 0;
    (* keep *) reg sa = 0, sb = 0;
    always @(posedge clk_a) begin
        xa <= lfsr_a[11:0];
        xb <= lfsr_a[23:12];
        sa <= lfsr_a[5];
    end
    always @(posedge clk_b) begin
        ya <= lfsr_b[11:0];
        yb <= lfsr_b[23:12];
        sb <= lfsr_b[5];
    end

    (* use_dsp = "no" *) wire [23:0] prod_a = xa * xb;
    (* use_dsp = "no" *) wire [23:0] prod_b = ya * yb;

    (* keep *) reg [7:0] x_q = 0, y_q = 0;
    always @(posedge clk_a)
        x_q <= prod_a[23:16] ^ {8{sb}};
    always @(posedge clk_b)
        y_q <= prod_b[23:16] ^ {8{sa}};

    assign led = x_q ^ y_q;
endmodule
