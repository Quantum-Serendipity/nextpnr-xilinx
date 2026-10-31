module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    reg [31:0] lfsr = 32'h1;
    reg [5:0] wa = 0, ra = 0;
    reg [7:0] mem [0:63];
    reg [7:0] q = 0;
    reg [31:0] sh = 0;
    reg sq = 0;
    always @(posedge clk_i) begin
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};
        wa <= lfsr[5:0];
        ra <= lfsr[11:6];
        if (lfsr[13])
            mem[wa] <= lfsr[23:16];
        q <= mem[ra];
        if (lfsr[17])
            sh <= {sh[30:0], lfsr[29]};
        sq <= sh[ra[4:0]];
    end
    assign led = q ^ {7'b0, sq};
endmodule
