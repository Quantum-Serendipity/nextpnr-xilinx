module top(input clk, input btn, output led_lock, output led_out);
  wire fb, co, cb, lk;
  PLLE2_BASE #(.CLKIN1_PERIOD(5.0), .CLKOUT1_DIVIDE(10)) m (.CLKIN1(clk), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT1(co), .RST(1'b0), .PWRDWN(1'b0), .LOCKED(lk));
  BUFG b (.I(co), .O(cb));
  reg t = 1'b0;
  always @(posedge cb) t <= ~t;
  assign led_out = t;
  assign led_lock = lk;
endmodule
