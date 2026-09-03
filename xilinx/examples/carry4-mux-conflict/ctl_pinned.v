// Positive control for the BEL-pinned branch, which is the DFX case: partial
// reconfiguration pins BELs, and a stamped placement came from a tool that had
// muxing arch_place.cc does not model.  Same lane-1 conflict as conflict.v, but
// the CARRY4 carries a BEL attribute, so the packer must NOT split it -- the
// import's placement wins and the cell name survives.
//
// Expected: 0 chains fall back, 1 conflicting chain reported BEL-pinned.
// The site is the one nextpnr itself chose for ctl_o_to_ff.v on
// xc7a35tcsg324 with this ballout, so it is known routable here.
module top (
    input  wire       clk_i,
    input  wire [3:0] s_i,
    input  wire [3:0] di_i,
    output wire       o1_o,
    output wire       co1_o,
    output wire       sum3_o
);
    wire [3:0] O, CO;
    (* BEL = "SLICE_X4Y126/CARRY4" *)
    CARRY4 c4 (
        .CO(CO), .O(O),
        .CI(1'b0), .CYINIT(1'b0),
        .DI(di_i), .S(s_i)
    );
    reg sum3_q;
    always @(posedge clk_i) sum3_q <= O[3];
    assign sum3_o = sum3_q;
    assign o1_o   = O[1];
    assign co1_o  = CO[1];
endmodule
