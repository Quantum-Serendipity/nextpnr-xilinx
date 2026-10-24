module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));

    reg [23:0] lfsr = 24'h1;
    always @(posedge clk)
        lfsr <= {lfsr[22:0], lfsr[23] ^ lfsr[22] ^ lfsr[21] ^ lfsr[16] ^ btn};

    (* keep *) reg [11:0] na = 0, nb = 0;
    always @(negedge clk) begin
        na <= lfsr[11:0];
        nb <= lfsr[23:12];
    end

    (* use_dsp = "no" *) wire [23:0] prod = na * nb;

    (* keep *) reg [7:0] n_q = 0;
    always @(posedge clk)
        n_q <= prod[23:16];

    assign led = n_q;
endmodule
