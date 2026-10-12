module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire fb, c0, c0b, locked;
  PLLE2_BASE #( .CLKFBOUT_MULT(10), .CLKOUT0_DIVIDE(10), .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1)) cmt (
    .CLKIN1(clk_b), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(c0), .LOCKED(locked), .RST(q), .PWRDWN(1'b0));
  BUFG ob(.I(c0), .O(c0b));
  reg t = 1'b0;
  always @(posedge c0b) t <= ~t;
  assign led_out = t;
  assign led_lock = locked;
endmodule
