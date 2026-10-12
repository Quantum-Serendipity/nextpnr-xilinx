module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire [15:0] doa;
  RAMB18E1 #(.IS_RSTREGARSTREG_INVERTED(1'b1), .READ_WIDTH_A(18), .WRITE_WIDTH_A(18), .DOA_REG(1), .INIT_00(256'h1234)) r (
    .CLKARDCLK(clk_b), .ENARDEN(1'b1), .REGCEAREGCE(1'b1), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
    .ADDRARDADDR({9'd0, btn, 4'd0}), .DIADI(16'd0), .DIPADIP(2'd0), .WEA(2'd0), .DOADO(doa));
  assign led_out = doa[0];
  assign led_lock = doa[1];
endmodule
