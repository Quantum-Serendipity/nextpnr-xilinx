module top(input clk, input btn, output led_lock, output led_out);
  wire cm;
  BUFGMUX_1 g (.I0(clk), .I1(btn), .S(btn), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
