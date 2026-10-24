module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk;
    IBUF ib (.I(clk_i), .O(clk));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [7:0] a = 0, b = 0;
    always @(posedge clk) begin
        a <= lfsr[7:0];
        b <= a ^ lfsr[15:8];
    end

    assign led = b;
endmodule
