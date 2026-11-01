module top (
    input        clk,
    input        we,
    input  [4:0] a,
    output [1:0] qa,
    output [1:0] qb
);
    wire gclk;
    BUFG bg (.I(clk), .O(gclk));
    RAM32M #(
        .INIT_A(64'hFFFFFFFFFFFFFFFF), .INIT_B(64'h0123456789ABCDEF),
        .INIT_C(64'h0), .INIT_D(64'h0)
    ) ram (
        .WCLK(gclk), .WE(we),
        .ADDRA(a), .ADDRB(a), .ADDRC(a), .ADDRD(a),
        .DIA(2'b00), .DIB(2'b11), .DIC(2'b00), .DID(2'b00),
        .DOA(qa), .DOB(qb), .DOC(), .DOD()
    );
endmodule
