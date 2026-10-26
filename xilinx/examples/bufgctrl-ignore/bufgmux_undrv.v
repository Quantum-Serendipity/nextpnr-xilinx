module top(input clk, input btn, output led_lock, output led_out);
  wire cm, s_undrv;
  BUFGMUX g (.I0(clk), .I1(btn), .S(s_undrv), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
