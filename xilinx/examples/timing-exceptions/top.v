module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk_a, pll_fb, pll_out0, clk_b;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg_a (.I(clk_ibuf), .O(clk_a));
    PLLE2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT(10),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE(4)
    ) pll (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(pll_fb),
        .CLKFBOUT(pll_fb),
        .CLKOUT0(pll_out0),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG bg_b (.I(pll_out0), .O(clk_b));

    reg [31:0] lfsr = 32'h1;
    always @(posedge clk_a)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    (* keep *) reg [15:0] src_slow = 0;
    (* keep *) reg [15:0] src_fast = 0;
    always @(posedge clk_a) begin
        src_slow <= ~lfsr[15:0];
        src_fast <= lfsr[31:16] ^ lfsr[15:0];
    end

    (* keep *) wire [15:0] slow_a = src_slow + {src_slow[7:0], src_slow[15:8]};
    (* keep *) wire [15:0] slow_b = slow_a + {slow_a[3:0], slow_a[15:4]};
    (* keep *) wire [15:0] slow_c = slow_b + {slow_b[11:0], slow_b[15:12]};
    (* keep *) wire mid = src_fast[0] & src_fast[1] & src_fast[2];

    (* keep *) reg [15:0] dst_slow = 0;
    (* keep *) reg [15:0] dst_fast = 0;
    (* keep *) reg dst_mid = 0;
    always @(posedge clk_a) begin
        dst_slow <= slow_c ^ src_fast;
        dst_fast <= src_fast ^ {src_fast[0], src_fast[15:1]};
        dst_mid <= mid;
    end

    (* keep *) reg [7:0] dst_ce = 0;
    always @(posedge clk_a)
        if (src_fast[4] ^ src_fast[3])
            dst_ce <= src_fast[7:0] + src_fast[15:8];

    (* keep *) reg [15:0] dst_b = 0;
    always @(posedge clk_b)
        dst_b <= slow_c;

    assign led = dst_slow[7:0] ^ dst_slow[15:8] ^ dst_fast[7:0] ^ dst_fast[15:8] ^ dst_b[7:0] ^ dst_b[15:8] ^ dst_ce ^ {7'b0, dst_mid};
endmodule
