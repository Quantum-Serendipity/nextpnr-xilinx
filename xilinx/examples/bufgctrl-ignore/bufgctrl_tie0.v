module top(input clk, input btn, output led_lock, output led_out);
  wire cm;
  BUFGCTRL g (.I0(clk), .I1(btn), .CE0(1'b1), .CE1(1'b1), .S0(btn), .S1(~btn), .IGNORE0(1'b0), .IGNORE1(1'b0), .O(cm));
  reg q = 0;
  always @(posedge cm) q <= ~q;
  assign led_out = q;
  assign led_lock = btn;
endmodule
