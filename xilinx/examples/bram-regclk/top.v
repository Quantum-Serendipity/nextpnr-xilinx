module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));

    reg [23:0] lfsr = 24'h1;
    always @(posedge clk)
        lfsr <= {lfsr[22:0], lfsr[23] ^ lfsr[22] ^ lfsr[21] ^ lfsr[16] ^ btn};

    wire [31:0] a18, b18, b36t, a36s, b36s;

    RAMB18E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(18), .WRITE_WIDTH_A(18), .READ_WIDTH_B(18), .WRITE_WIDTH_B(18),
               .DOA_REG(1), .DOB_REG(1)) r18 (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b1), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({2{lfsr[20]}}), .ADDRARDADDR(lfsr[13:0]), .DIADI(lfsr[15:0]), .DIPADIP(2'd0), .DOADO(a18[15:0]),
        .CLKBWRCLK(clk), .ENBWREN(1'b1), .REGCEB(1'b1), .RSTRAMB(1'b0), .RSTREGB(1'b0),
        .WEBWE({4{lfsr[21]}}), .ADDRBWRADDR(lfsr[23:10]), .DIBDI(lfsr[23:8]), .DIPBDIP(2'd0), .DOBDO(b18[15:0]));

    RAMB36E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(36), .WRITE_WIDTH_A(36), .READ_WIDTH_B(36), .WRITE_WIDTH_B(36),
               .DOA_REG(0), .DOB_REG(1)) r36t (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({4{lfsr[20]}}), .ADDRARDADDR({1'b1, lfsr[14:0]}), .DIADI({8'd0, lfsr}), .DIPADIP(4'd0),
        .CLKBWRCLK(clk), .ENBWREN(1'b1), .REGCEB(1'b1), .RSTRAMB(1'b0), .RSTREGB(1'b0),
        .WEBWE({4'd0, {4{lfsr[21]}}}), .ADDRBWRADDR({1'b1, lfsr[22:8]}), .DIBDI({lfsr, 8'd0}), .DIPBDIP(4'd0),
        .DOBDO(b36t), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0));

    RAMB36E1 #(.RAM_MODE("SDP"), .READ_WIDTH_A(72), .WRITE_WIDTH_A(0), .READ_WIDTH_B(0), .WRITE_WIDTH_B(72),
               .DOA_REG(1), .DOB_REG(1)) r36s (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b1), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA(4'd0), .ADDRARDADDR({1'b1, lfsr[8:0], 6'd0}), .DIADI({8'd0, lfsr}), .DIPADIP(4'd0),
        .CLKBWRCLK(clk), .ENBWREN(1'b1), .REGCEB(1'b1), .RSTRAMB(1'b0), .RSTREGB(1'b0),
        .WEBWE({8{lfsr[21]}}), .ADDRBWRADDR({1'b1, lfsr[18:10], 6'd0}), .DIBDI({lfsr, 8'd0}), .DIPBDIP(4'd0),
        .DOADO(a36s), .DOBDO(b36s), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0),
        .INJECTSBITERR(1'b0));

    (* keep *) reg [7:0] q = 0;
    always @(posedge clk)
        q <= a18[7:0] ^ b18[7:0] ^ b36t[7:0] ^ a36s[7:0] ^ b36s[7:0];
    assign led = q;
endmodule
