module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk, fb, mo0, ck0;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg (.I(clk_ibuf), .O(clk));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(8.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(16.0),
        .CLKOUT0_DUTY_CYCLE(0.25)
    ) mmcm (
        .CLKIN1(clk_ibuf),
        .CLKFBIN(fb),
        .CLKFBOUT(fb),
        .CLKOUT0(mo0),
        .RST(1'b0),
        .PWRDWN(1'b0)
    );
    BUFG bg0 (.I(mo0), .O(ck0));

    reg [15:0] lfsr = 16'h1;
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] ^ btn};

    (* keep *) reg [7:0] a_q = 0;
    (* keep *) reg [7:0] c_q = 0;
    always @(posedge clk) begin
        a_q <= lfsr[7:0];
        c_q <= lfsr[15:8];
    end

    (* keep *) wire [7:0] sum = a_q + {a_q[3:0], a_q[7:4]};
    wire [7:0] b_q;
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : bff
            (* keep *) FDRE ff (.C(clk), .CE(1'b1), .R(1'b0), .D(sum[i]), .Q(b_q[i]));
        end
    endgenerate
    (* keep *) reg [7:0] d_q = 0;
    always @(posedge clk)
        d_q <= c_q ^ {c_q[6:0], c_q[7]};

    (* keep *) reg [7:0] n_q = 0;
    always @(negedge clk)
        n_q <= a_q ^ c_q;

    wire m7;
    MUXF7 mux7 (.I0(a_q[0] ^ c_q[1]), .I1(a_q[2] & c_q[3]), .S(lfsr[4]), .O(m7));
    (* keep *) reg m_q = 0;
    always @(posedge clk)
        m_q <= m7;

    wire lm_o;
    (* BEL = "SLICE_X42Y159/A6LUT" *) LUT3 #(.INIT(8'h96)) lm (.I0(a_q[1]), .I1(c_q[2]), .I2(lfsr[3]), .O(lm_o));
    (* keep *) reg l_q = 0;
    always @(posedge clk)
        l_q <= lm_o;

    wire srl_o;
    SRL16E #(.INIT(16'h0000)) sreg (
        .CLK(clk), .CE(lfsr[9]), .D(a_q[5]), .A0(1'b1), .A1(1'b1), .A2(1'b1), .A3(1'b0), .Q(srl_o)
    );
    (* keep *) reg s_q = 0;
    always @(posedge clk)
        s_q <= srl_o;

    (* keep *) reg [3:0] p0_q = 0;
    (* keep *) reg [3:0] p1_q = 0;
    always @(posedge ck0)
        p0_q <= p0_q + 1'b1;
    always @(negedge ck0)
        p1_q <= p0_q ^ {p0_q[2:0], p0_q[3]};

    assign led = b_q ^ d_q ^ n_q ^ {7'b0, m_q} ^ {5'b0, l_q, s_q, 1'b0} ^ {p1_q, p0_q};
endmodule
