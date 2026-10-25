module top(input clk, input btn, output led_lock, output led_out);
  wire cm;
  BUFGCE g (.I(clk), .CE(btn), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
