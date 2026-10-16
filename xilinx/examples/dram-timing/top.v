module top (
    input  wire       clk_i,
    input  wire       btn,
    output wire [7:0] led
);
    reg [31:0] lfsr = 32'h1;
    reg [5:0] wa = 0, ra = 0;
    always @(posedge clk_i) begin
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};
        wa <= wa + 1;
        ra <= ra + lfsr[3];
    end

    reg [31:0] mem0 [0:63];
    reg [31:0] mem1 [0:63];
    reg [31:0] q0, q1;
    always @(posedge clk_i) begin
        if (lfsr[7])
            mem0[wa] <= lfsr;
        if (lfsr[9])
            mem1[wa ^ 6'h2a] <= ~lfsr;
        q0 <= mem0[ra];
        q1 <= mem1[ra ^ lfsr[5:0]];
    end

    reg [7:0] acc = 0;
    always @(posedge clk_i)
        acc <= acc ^ q0[7:0] ^ q0[15:8] ^ q1[23:16] ^ q1[31:24] ^ q0[31:24] ^ q1[7:0];
    assign led = acc;
endmodule
