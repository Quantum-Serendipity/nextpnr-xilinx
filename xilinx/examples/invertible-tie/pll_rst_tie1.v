module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire fb, c0, c0b, locked;
  PLLE2_ADV #( .CLKFBOUT_MULT(10), .CLKOUT0_DIVIDE(10), .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .BANDWIDTH("OPTIMIZED")) cmt (
    .CLKIN1(clk_b), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(c0),
    .LOCKED(locked), .RST(1'b1), .PWRDWN(1'b0),
    .DCLK(1'b0), .DEN(1'b0), .DWE(1'b0), .DADDR(7'd0), .DI(16'd0));
  BUFG ob(.I(c0), .O(c0b));
  reg t = 1'b0;
  always @(posedge c0b) t <= ~t;
  assign led_out = t;
  assign led_lock = locked;
endmodule
