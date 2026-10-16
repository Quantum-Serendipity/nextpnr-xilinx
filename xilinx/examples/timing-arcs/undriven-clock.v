module top (
    input  wire       clk,
    input  wire       btn,
    output wire [7:0] led
);

    reg [9:0] addr = 0;
    always @(posedge clk)
        addr <= addr + {9'b0, btn};

    reg [15:0] rom [0:1023];
    integer i;
    initial
        for (i = 0; i < 1024; i = i + 1)
            rom[i] = i * 16'h9e37 + 16'h1234;

    reg [15:0] d = 0;
    always @(posedge clk)
        d <= rom[addr];

    reg [7:0] q = 0;
    always @(posedge clk)
        q <= d[7:0] + d[15:8];
    assign led = q;
endmodule
