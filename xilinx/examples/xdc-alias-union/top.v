module sub (
    input clk_in,
    output o_sys_clk
);
    wire sys_clk;
    BUFG bg (.I(clk_in), .O(sys_clk));
    assign o_sys_clk = sys_clk;
endmodule

module top (
    input clk_i,
    input btn,
    output [3:0] led
);
    wire clk_ibuf, ddr_sys_clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    sub u_ddr3 (.clk_in(clk_ibuf), .o_sys_clk(ddr_sys_clk));

    reg [3:0] r = 4'h1;
    always @(posedge ddr_sys_clk)
        r <= {r[2:0], r[3] ^ btn};
    assign led = r;
endmodule
