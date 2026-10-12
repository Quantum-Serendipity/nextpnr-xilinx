module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  wire q;
  (* BEL = "SLICE_X88Y100/AFF" *)
  FDRE #(.INIT(1'b0)) qff (.C(clk_b), .CE(1'b1), .R(1'b0), .D(btn), .Q(q));
  ODDR #( .DDR_CLK_EDGE("SAME_EDGE")) o (.C(clk_b), .CE(1'b1), .D1(1'b1), .D2(q), .R(1'b0), .S(1'b0), .Q(led_out));
  assign led_lock = q;
endmodule
