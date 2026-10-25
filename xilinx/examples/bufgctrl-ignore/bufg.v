module top(input clk, input btn, output led_lock, output led_out);
  wire cm;
  BUFG g (.I(clk), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
