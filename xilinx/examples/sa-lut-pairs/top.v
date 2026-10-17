module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    localparam N = 32;
    reg [7:0] s = 8'h1;
    always @(posedge clk_i)
        s <= {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[3] ^ btn};

    (* keep *) reg [N-1:0] f6 = 0, f5 = 0;
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g
            localparam [63:0] K6 = 64'h9E3779B97F4A7C15 * (2 * i + 1);
            localparam [31:0] K5 = 32'h85EBCA6B * (2 * i + 3);
            always @(posedge clk_i) begin
                f6[i] <= K6[s[5:0]];
                f5[i] <= K5[s[4:0]];
            end
        end
    endgenerate

    reg [7:0] acc = 0;
    always @(posedge clk_i)
        acc <= f6[7:0] ^ f6[15:8] ^ f6[23:16] ^ f6[31:24] ^ f5[7:0] ^ f5[15:8] ^ f5[23:16] ^ f5[31:24];
    assign led = acc;
endmodule
