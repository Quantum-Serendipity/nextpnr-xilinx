module top #(parameter K = 120) (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));
    reg [31:0] lfsr = 32'h1;
    always @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};
    reg [K-1:0] r = 0;
    genvar i;
    generate for (i = 0; i < K; i = i + 1) begin : g
        wire [5:0] s = {lfsr[(i * 5 + 0) % 32], lfsr[(i * 7 + 3) % 32], lfsr[(i * 11 + 5) % 32],
                        lfsr[(i * 13 + 9) % 32], lfsr[(i * 17 + 1) % 32], lfsr[(i * 3 + 7) % 32]};
        always @(posedge clk)
            r[i] <= ((s * (i + 3)) >> 2) % 2 == 1 ? ~^s[4:0] : (s[5] & s[i % 5]) | (s[0] ^ s[3]);
    end endgenerate
    assign led = {^r, r[6:0]};
endmodule
