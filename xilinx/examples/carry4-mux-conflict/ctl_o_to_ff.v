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
