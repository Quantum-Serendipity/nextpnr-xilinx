module top (
    input clk_i,
    input btn,
    input din_a,
    input din_b,
    input sd_do,
    output dout,
    output sd_clk,
    output sd_di,
    output [3:0] led
);
    wire clk_ibuf, clk, dclk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG gsys (.I(clk_ibuf), .O(clk));

    (* keep *) reg div = 1'b0;
    always @(posedge clk)
        div <= ~div;
    BUFG gdiv (.I(div), .O(dclk));

    reg [31:0] lfsr = 32'h1;
    always @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    (* keep *) reg [15:0] x = 0, y = 0;
    always @(posedge clk) begin
        x <= lfsr[15:0];
        y <= lfsr[31:16];
    end

    (* keep *) reg [15:0] p_div = 0;
    (* keep *) reg [15:0] p_div2 = 0;
    always @(posedge dclk) begin
        p_div <= (x + y) ^ {y[7:0], x[15:8]};
        p_div2 <= p_div + {p_div[7:0], p_div[15:8]};
    end

    (* keep *) reg ra = 1'b0, rb = 1'b0, rs = 1'b0;
    always @(posedge clk) begin
        ra <= din_a;
        rb <= din_b;
        rs <= sd_do;
    end

    (* keep *) reg ro = 1'b0, rdi = 1'b0;
    always @(posedge clk) begin
        ro <= lfsr[3] ^ lfsr[9];
        rdi <= lfsr[5] ^ ra;
    end

    assign dout = ro;
    assign sd_clk = div;
    assign sd_di = rdi;
    assign led = p_div2[15:12] ^ p_div2[3:0] ^ {rb, rs, ra, 1'b0};
endmodule
