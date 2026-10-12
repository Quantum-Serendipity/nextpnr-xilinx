module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire cm;
  BUFGCTRL #(.IS_CE1_INVERTED(1'b1), .INIT_OUT(0)) g (.I0(clk), .I1(btn), .CE0(1'b1), .S0(1'b1), .S1(1'b0), .IGNORE0(1'b0), .IGNORE1(1'b0), .O(cm));
  reg t = 1'b0;
  always @(posedge cm) t <= ~t;
  assign led_out = t;
  assign led_lock = q;
endmodule
