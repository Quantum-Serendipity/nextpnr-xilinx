module top (
    input  wire       clk_i,
    input  wire       btn,
    output wire [7:0] led
);
    reg [15:0] a = 16'h1, b = 16'h3;
    always @(posedge clk_i) begin
        a <= {a[14:0], a[15] ^ a[13] ^ btn};
        b <= {b[14:0], b[15] ^ b[12] ^ a[0]};
    end

    wire [31:0] p = a * b;
    reg [15:0] n = 0;
    always @(negedge clk_i)
        n <= p[23:8];

    reg [7:0] q = 0;
    always @(posedge clk_i)
        q <= n[7:0] ^ n[15:8];
    assign led = q;
endmodule
