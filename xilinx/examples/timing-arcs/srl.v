module top (
    input  wire       clk_i,
    input  wire       btn,
    output wire [7:0] led
);
    reg [15:0] a = 16'h1, b = 16'h5;
    always @(posedge clk_i) begin
        a <= {a[14:0], a[15] ^ a[13] ^ btn};
        b <= {b[14:0], b[15] ^ b[11] ^ a[3]};
    end

    wire [15:0] m = a * b;
    reg [15:0] sr [0:7];
    integer i;
    always @(posedge clk_i)
        if (a[1]) begin
            sr[0] <= m;
            for (i = 1; i < 8; i = i + 1)
                sr[i] <= sr[i - 1];
        end

    reg [63:0] deep = 0;
    always @(posedge clk_i)
        deep <= {deep[62:0], a[2]};

    wire [15:0] t = sr[7] * {sr[7][7:0], sr[7][15:8]};
    reg [15:0] q = 0;
    always @(posedge clk_i)
        q <= t ^ {15'b0, deep[63]};
    assign led = q[7:0] ^ q[15:8];
endmodule
