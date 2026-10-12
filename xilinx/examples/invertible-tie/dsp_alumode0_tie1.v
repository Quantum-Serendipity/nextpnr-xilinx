module top(input clk, input btn, output led_lock, output led_out);
  wire clk_b;
  BUFG ib(.I(clk), .O(clk_b));
  reg q = 1'b0;
  always @(posedge clk_b) q <= btn;
  wire [47:0] p;
  DSP48E1 #( .AREG(1), .BREG(1), .CREG(1), .MREG(0), .PREG(1), .USE_MULT("NONE"), .OPMODEREG(1), .ALUMODEREG(1)) d (
    .CLK(clk_b), .A({29'd0, btn}), .B(18'd0), .C({47'd0, q}), .D(25'd0), .ALUMODE(4'b0001), .OPMODE(7'b0110011), .INMODE(5'd0),
    .CARRYIN(1'b0), .CARRYINSEL(3'd0), .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1), .CEC(1'b1), .CEM(1'b1), .CEP(1'b1),
    .CEAD(1'b1), .CED(1'b1), .CECTRL(1'b1), .CEALUMODE(1'b1), .CEINMODE(1'b1), .CECARRYIN(1'b1),
    .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTM(1'b0), .RSTP(1'b0), .RSTD(1'b0), .RSTCTRL(1'b0), .RSTALUMODE(1'b0), .RSTINMODE(1'b0), .RSTALLCARRYIN(1'b0),
    .P(p));
  assign led_out = p[0];
  assign led_lock = p[1];
endmodule
