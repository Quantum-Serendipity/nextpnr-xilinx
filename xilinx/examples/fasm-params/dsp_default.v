module top(input clk, input btn, output led_lock, output led_out);
  wire [47:0] p;
  wire pd;
  DSP48E1 #(.AREG(1), .ACASCREG(1), .BREG(1), .BCASCREG(1), .MREG(0), .PREG(1)) d (
    .CLK(clk), .A({29'd0, btn}), .B(18'd1), .C(48'd0), .D(25'd0), .PCIN(48'd0), .ACIN(30'd0), .BCIN(18'd0),
    .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .CARRYIN(1'b0), .CARRYINSEL(3'd0), .ALUMODE(4'd0), .INMODE(5'd0),
    .OPMODE(7'b0000101), .CEA1(1'b1), .CEA2(1'b1), .CEAD(1'b1), .CEALUMODE(1'b1), .CEB1(1'b1), .CEB2(1'b1),
    .CEC(1'b1), .CECARRYIN(1'b1), .CECTRL(1'b1), .CED(1'b1), .CEINMODE(1'b1), .CEM(1'b1), .CEP(1'b1),
    .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0),
    .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(1'b0), .P(p), .PATTERNDETECT(pd));
  assign led_out = pd;
  assign led_lock = p[0];
endmodule
