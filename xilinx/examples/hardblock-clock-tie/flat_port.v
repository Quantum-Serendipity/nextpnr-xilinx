module top(input c, input [9:0] a, output [15:0] q);
  RAMB18E1 #(.READ_WIDTH_A(18), .WRITE_WIDTH_A(18)) r (
    .CLKARDCLK(c), .CLKBWRCLK(1'b0), .ENARDEN(1'b1), .ENBWREN(1'b0), .REGCEAREGCE(1'b0), .REGCEB(1'b0),
    .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
    .ADDRARDADDR({a, 4'd0}), .ADDRBWRADDR(14'd0), .DIADI(16'd0), .DIBDI(16'd0), .DIPADIP(2'd0), .DIPBDIP(2'd0),
    .WEA(2'd0), .WEBWE(4'd0), .DOADO(q));
endmodule
