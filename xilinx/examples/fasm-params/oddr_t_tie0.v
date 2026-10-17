module top(input clk, input btn, output led_lock, output led_out);
  wire t;
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("SYNC")) o (.C(clk), .CE(1'b1), .D1(1'b0), .D2(btn), .R(1'b0), .S(1'b0), .Q(t));
  OBUFT ob (.I(1'b1), .T(t), .O(led_out));
  assign led_lock = btn;
endmodule
