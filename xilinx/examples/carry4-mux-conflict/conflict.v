// A 7-series SLICE lane has ONE output mux (xOUTMUX).  Lane 1 here needs it
// twice: for the sum O[1] and for the intermediate carry CO[1], both of which
// leave for the fabric.  No site on the die can host this cell.
module top (
    input  wire       clk_i,
    input  wire [3:0] s_i,
    input  wire [3:0] di_i,
    output wire       o1_o,
    output wire       co1_o,
    output wire       sum3_o
);
    wire [3:0] O, CO;
    CARRY4 c4 (
        .CO(CO), .O(O),
        .CI(1'b0), .CYINIT(1'b0),
        .DI(di_i), .S(s_i)
    );
    reg sum3_q;
    always @(posedge clk_i) sum3_q <= O[3];
    assign sum3_o = sum3_q;
    assign o1_o   = O[1];   // lane 1 sum  -> fabric : needs the output mux
    assign co1_o  = CO[1];  // lane 1 carry-> fabric : needs the output mux too
endmodule
