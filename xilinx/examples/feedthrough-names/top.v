module top (input clk_i, input btn, output [3:0] led);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));
    reg [23:0] ctr = 0;
    always @(posedge clk) ctr <= ctr + {23'b0, btn};
    assign led = ctr[23:20];
endmodule
