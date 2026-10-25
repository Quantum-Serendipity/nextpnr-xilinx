module top(input clk, input btn, output led_lock, inout led_out);
  wire oq, tq;
  OSERDESE2 #(.DATA_RATE_OQ("SDR"), .DATA_RATE_TQ("BUF"), .DATA_WIDTH(2), .TRISTATE_WIDTH(1), .SERDES_MODE("MASTER")) s (
    .CLK(clk), .CLKDIV(clk), .D1(btn), .D2(btn), .D3(1'b0), .D4(1'b0), .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
    .OCE(1'b1), .RST(1'b0), .T1(1'b1), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b1), .TBYTEIN(1'b0),
    .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .OQ(oq), .TQ(tq));
  IOBUF io (.I(oq), .T(tq), .IO(led_out), .O(led_lock));
endmodule
