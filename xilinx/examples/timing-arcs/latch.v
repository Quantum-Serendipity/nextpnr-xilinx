module top (
    input  wire       clk_i,
    input  wire       btn,
    output wire [7:0] led
);
    reg [7:0] a = 8'h1;
    always @(posedge clk_i)
        a <= {a[6:0], a[7] ^ a[5] ^ btn};

    reg [7:0] l;
    always @*
        if (clk_i)
            l = a + {a[3:0], a[7:4]};

    reg [7:0] q = 0;
    always @(posedge clk_i)
        q <= l ^ {l[0], l[7:1]};
    assign led = q;
endmodule
