module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));

    reg [31:0] lfsr = 32'h1;
    always @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    (* keep *) reg [15:0] a = 0;
    always @(posedge clk)
        a <= lfsr[15:0];

    wire l1, l2, l3, l4, l5;
`ifdef RING
    (* keep *) LUT2 #(.INIT(4'b0110)) r1 (.I0(l2), .I1(btn), .O(l1));
    (* keep *) LUT2 #(.INIT(4'b1001)) r2 (.I0(l1), .I1(lfsr[31]), .O(l2));
    wire l4_in = l4;
`else
    (* keep *) reg l1_q = 0, l4_q = 0;
    always @(posedge clk) begin
        l1_q <= l2;
        l4_q <= l4;
    end
    (* keep *) LUT2 #(.INIT(4'b0110)) r1 (.I0(l1_q), .I1(btn), .O(l1));
    (* keep *) LUT2 #(.INIT(4'b1001)) r2 (.I0(l1), .I1(lfsr[31]), .O(l2));
    wire l4_in = l4_q;
`endif
    (* keep *) LUT2 #(.INIT(4'b0110)) r3 (.I0(l4_in), .I1(btn), .O(l3));
    (* keep *) LUT3 #(.INIT(8'b10010110)) r4 (.I0(l3), .I1(l5), .I2(lfsr[30]), .O(l4));
    (* keep *) LUT2 #(.INIT(4'b1001)) r5 (.I0(l4_in), .I1(lfsr[29]), .O(l5));

    (* use_dsp = "no" *) wire [31:0] sq = a * a;

    (* keep *) reg [31:0] p = 0;
    always @(posedge clk)
        p <= sq ^ {32{l1}} ^ {32{l3}};

    assign led = p[31:24] ^ p[7:0];
endmodule
