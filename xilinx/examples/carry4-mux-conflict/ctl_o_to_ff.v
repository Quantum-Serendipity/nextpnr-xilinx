// Control: CO[1] still exports, but lane 1's sum now has a single sink that
// pack_carries_atomic() co-locates into the same lane's main FF.  O[1] then
// reaches that FF through xFFMUX.XOR and never touches the output mux, so
// CO[1] has it to itself.  This is the arm that shows the predicate is about
// mux CONTENTION and not about CO fanout on its own.
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
    reg sum3_q, o1_q;
    always @(posedge clk_i) begin
        sum3_q <= O[3];
        o1_q   <= O[1];
    end
    assign sum3_o = sum3_q;
    assign o1_o   = o1_q;
    assign co1_o  = CO[1];
endmodule
