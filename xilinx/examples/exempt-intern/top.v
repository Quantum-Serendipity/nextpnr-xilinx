module top (
    input  clk,
    input  a,
    input  b,
    output y,
    output z
);
    reg q = 1'b0;
    always @(posedge clk)
        q <= a ^ b;
    assign y = q;
    assign z = ~(a | b);
endmodule
