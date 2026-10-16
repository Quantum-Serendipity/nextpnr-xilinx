module top(input clk, input btn, output led_lock, output led_out);
  wire [63:0] do;
  RAMB36E1 #(.RAM_MODE("SDP"), .READ_WIDTH_A(72), .WRITE_WIDTH_B(72), .EN_ECC_READ("TRUE"), .EN_ECC_WRITE("TRUE")) r (
    .CLKARDCLK(clk), .CLKBWRCLK(clk), .ENARDEN(1'b1), .ENBWREN(1'b1), .REGCEAREGCE(1'b0), .REGCEB(1'b0),
    .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
    .ADDRARDADDR({10'd0, btn, 5'd0}), .ADDRBWRADDR(16'd0), .DIADI(32'd0), .DIBDI({31'd0, btn}), .DIPADIP(4'd0), .DIPBDIP(4'd0),
    .WEA(4'd0), .WEBWE(8'hff), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
    .DOADO(do[31:0]), .DOBDO(do[63:32]));
  assign led_out = do[0];
  assign led_lock = do[32];
endmodule
