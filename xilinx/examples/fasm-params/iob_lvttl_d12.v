module top(input btn, output led_out);
  assign led_out = ~btn;
endmodule
