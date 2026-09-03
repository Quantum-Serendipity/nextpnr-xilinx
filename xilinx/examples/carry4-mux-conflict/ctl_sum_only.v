// Control for the direction the other four arms cannot test: the predicate
// must DECLINE.  A two-cell chain whose sums reach the fabric and whose
// carries never do -- co1_o is driven by a SUM, and the only carry that leaves
// c4a is CO[3], which rides the dedicated COUT->CIN spine into c4b.  Every lane
// claims its output mux at most once, so relocate_carry_o_fabric() must
// relocate nothing.
//
// Without this arm a predicate that over-fires would be green everywhere here,
// because all three unpinned arms already relocate and ctl_pinned is skipped.
// It is two cells rather than one deliberately: c4b has a real CIN net, so the
// bit-0 relocation path is reachable and an over-fire there is observable.  A
// one-cell version was immune -- its root has no CIN and its unused CO nets do
// not exist, so the machinery declines for reasons unrelated to the predicate.
//
// Expected: 0 sums duplicated, 0 splits, 1 chain, 0 BEL-pinned.
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
