module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire s_undrv;
  wire cm;
  BUFGMUX m(.I0(clk), .I1(btn), .S(s_undrv), .O(cm));
  reg t = 1'b0;
  always @(posedge cm) t <= ~t;
  assign led_out = t;
  assign led_lock = q;
endmodule
