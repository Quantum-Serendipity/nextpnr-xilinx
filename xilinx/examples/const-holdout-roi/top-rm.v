module top (
    input        clk,
    input        d,
    input  [3:0] a,
    output       q,
    output reg   q2
);
    SRL16E #(.INIT(16'h0000)) srl (
        .CLK(clk),
        .CE(1'b1),
        .D(d),
        .A0(a[0]),
        .A1(a[1]),
        .A2(a[2]),
        .A3(a[3]),
        .Q(q)
    );
    always @(posedge clk) q2 <= d;
endmodule
