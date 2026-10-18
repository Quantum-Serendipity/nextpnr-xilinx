module top (
    input  wire       clk_i,
    input  wire [3:0] s_i,
    input  wire [3:0] di_i,
    output wire       o1_o,
    output wire       co1_o,
    output wire       sum3_o
);
    wire [3:0] Oa, COa, Ob, COb;
    CARRY4 c4a (
        .CO(COa), .O(Oa),
        .CI(1'b0), .CYINIT(1'b0),
        .DI(di_i), .S(s_i)
    );
    CARRY4 c4b (
        .CO(COb), .O(Ob),
        .CI(COa[3]), .CYINIT(1'b0),
        .DI(di_i), .S(s_i)
    );
    reg sum3_q;
    always @(posedge clk_i) sum3_q <= Ob[3];
    assign sum3_o = sum3_q;
    assign o1_o   = Oa[1];
    assign co1_o  = Ob[0];
endmodule
