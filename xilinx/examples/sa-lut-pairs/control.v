module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    reg [7:0] s = 8'h1;
    always @(posedge clk_i)
        s <= {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[3] ^ btn};

    wire [3:0] o5, o6;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g
            LUT6_2 #(.INIT(64'h9E3779B97F4A7C15 * (2 * i + 1))) pair (
                .I0(s[i]), .I1(s[i + 1]), .I2(s[i + 2]), .I3(s[i + 3]), .I4(s[i + 4]), .I5(1'b1),
                .O5(o5[i]), .O6(o6[i]));
        end
    endgenerate

    reg [7:0] r = 0;
    always @(posedge clk_i)
        r <= {o6, o5};
    assign led = r;
endmodule
