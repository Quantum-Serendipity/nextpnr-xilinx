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

    (* keep *) wire we_a0 = lfsr[2], we_a1 = lfsr[5], we_b0 = lfsr[11], we_b1 = lfsr[19];
    wire [15:0] a, b;

    RAMB18E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(18), .WRITE_WIDTH_A(18), .READ_WIDTH_B(18), .WRITE_WIDTH_B(18))
    r18 (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({we_a1, we_a0}), .ADDRARDADDR({lfsr[9:0], 4'd0}), .DIADI(lfsr[15:0]), .DIPADIP(2'd0), .DOADO(a),
        .CLKBWRCLK(clk), .ENBWREN(1'b1), .REGCEB(1'b0), .RSTRAMB(1'b0), .RSTREGB(1'b0),
        .WEBWE({2'b00, we_b1, we_b0}), .ADDRBWRADDR({lfsr[21:12], 4'd0}), .DIBDI(lfsr[23:8]), .DIPBDIP(2'd0),
        .DOBDO(b));

    (* keep *) reg [7:0] q = 0;
    always @(posedge clk)
        q <= a[7:0] ^ a[15:8] ^ b[7:0] ^ b[15:8];
    assign led = q;
endmodule
