module top (
    input  wire       clk_i,
    input  wire       btn,
    output wire [7:0] led
);
    reg [3:0] a = 0;
    always @(posedge clk_i)
        a <= a + 1'b1;
    wire q;
`ifdef ON_SLICEM
    (* BEL = "SLICE_X42Y159/A6LUT" *)
`else
    (* BEL = "SLICE_X43Y159/A6LUT" *)
`endif
    SRL16E #(.INIT(16'h0)) u_srl (
        .CLK(clk_i), .CE(1'b1), .D(btn),
        .A0(a[0]), .A1(a[1]), .A2(a[2]), .A3(a[3]), .Q(q)
    );
    reg r = 0;
    always @(posedge clk_i)
        r <= q;
    assign led = {7'b0, r};
endmodule
