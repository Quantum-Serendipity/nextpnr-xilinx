module top (
    input        clk,
    input        we,
    input  [3:0] a,
    input  [4:0] d,
    output       q
);
    wire [1:0] doa, dob, doc, dod;
    RAM32M #(.INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0)) ram (
        .WCLK(clk),
        .WE(we),
        .ADDRA({1'b0, a}),
        .ADDRB({1'b0, a}),
        .ADDRC({1'b0, a}),
        .ADDRD({1'b0, a}),
        .DIA(2'b00),
        .DIB(d[1:0]),
        .DIC(d[3:2]),
        .DID({d[0], d[4]}),
        .DOA(doa),
        .DOB(dob),
        .DOC(doc),
        .DOD(dod)
    );
    assign q = ^{doa, dob, doc, dod};
endmodule
