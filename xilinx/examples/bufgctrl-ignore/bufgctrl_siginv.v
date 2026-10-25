module top(input clk, input btn, output led_lock, output led_out);
  wire cm;
  BUFGCTRL #(.IS_IGNORE0_INVERTED(1'b1), .IS_IGNORE1_INVERTED(1'b1)) g (.I0(clk), .I1(btn), .CE0(1'b1), .CE1(1'b1), .S0(btn), .S1(~btn), .IGNORE0(btn), .IGNORE1(btn), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
