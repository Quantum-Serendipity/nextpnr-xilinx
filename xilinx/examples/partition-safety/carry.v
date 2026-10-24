module top (
    input clk,
    input en,
    output [3:0] q
);
    (* keep *) reg [15:0] count = 0;
    always @(posedge clk)
        if (en)
            count <= count + 16'd1;
    assign q = count[15:12];
endmodule
