// Control: same cell, but only ONE of lane 1's outputs reaches the fabric.
// CO[1] is unused and the exported carry is CO[3], whose lane's sum O[3] goes
// to a co-locatable FF.  Every lane claims the output mux at most once.
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
    assign o1_o   = O[1];
    assign co1_o  = CO[3];
endmodule
