module top (
    input        clk,
    input        we,
    input  [5:0] wa,
    input  [5:0] ra,
    input  [7:0] d,
    output       q
);
    wire [1:0] b_a, b_b, b_c, b_d;
    RAM32M #(
        .INIT_A(64'h0123456789ABCDEF), .INIT_B(64'hF0E1D2C3B4A59687),
        .INIT_C(64'hDEADBEEF8BADF00D), .INIT_D(64'h13579BDF2468ACE0)
    ) r_both (
        .WCLK(clk), .WE(we),
        .ADDRA({2'b00, ra[2:0]}), .ADDRB({2'b00, ra[0], ra[2], ra[1]}),
        .ADDRC({2'b00, ra[1], ra[0], ra[2]}), .ADDRD({2'b00, wa[2:0]}),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(b_a), .DOB(b_b), .DOC(b_c), .DOD(b_d)
    );

    wire [1:0] m_a, m_b, m_c, m_d;
    RAM32M #(
        .INIT_A(64'hA5A5_0F0F_3C3C_9669), .INIT_B(64'h1122_3344_5566_7788),
        .INIT_C(64'h8001_4002_2004_1008), .INIT_D(64'hFEDC_BA98_7654_3210)
    ) r_mixed (
        .WCLK(clk), .WE(we),
        .ADDRA({ra[4], 1'b0, ra[2:0]}), .ADDRB({2'b00, ra[2:0]}),
        .ADDRC({2'b00, ra[2:0]}), .ADDRD({2'b00, wa[2:0]}),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(m_a), .DOB(m_b), .DOC(m_c), .DOD(m_d)
    );

    wire [1:0] v_a, v_b, v_c, v_d;
    RAM32M #(
        .INIT_A(64'h6A09E667F3BCC908), .INIT_B(64'hBB67AE8584CAA73B),
        .INIT_C(64'h3C6EF372FE94F82B), .INIT_D(64'hA54FF53A5F1D36F1)
    ) r_vcc (
        .WCLK(clk), .WE(we),
        .ADDRA({2'b00, ra[2:0]}), .ADDRB({1'b0, 1'b1, ra[2:0]}),
        .ADDRC({2'b00, ra[2:0]}), .ADDRD({2'b00, wa[2:0]}),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(v_a), .DOB(v_b), .DOC(v_c), .DOD(v_d)
    );

    wire s_a, s_b, s_c, s_d;
    RAM64M #(
        .INIT_A(64'h510E527FADE682D1), .INIT_B(64'h9B05688C2B3E6C1F),
        .INIT_C(64'h1F83D9ABFB41BD6B), .INIT_D(64'h5BE0CD19137E2179)
    ) r64 (
        .WCLK(clk), .WE(we),
        .ADDRA({1'b0, ra[4:0]}), .ADDRB({1'b0, ra[4:0]}),
        .ADDRC({1'b0, ra[4:0]}), .ADDRD({1'b0, wa[4:0]}),
        .DIA(d[0]), .DIB(d[1]), .DIC(d[2]), .DID(d[3]),
        .DOA(s_a), .DOB(s_b), .DOC(s_c), .DOD(s_d)
    );

    wire [1:0] f_a, f_b, f_c, f_d;
    RAM32M #(
        .INIT_A(64'hC0FFEE00DEADBEEF), .INIT_B(64'h0BADCAFE12345678),
        .INIT_C(64'h0F1E2D3C4B5A6978), .INIT_D(64'h8796A5B4C3D2E1F0)
    ) r_free (
        .WCLK(clk), .WE(we),
        .ADDRA(ra[4:0]), .ADDRB(ra[5:1]), .ADDRC(ra[4:0]), .ADDRD(wa[4:0]),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(f_a), .DOB(f_b), .DOC(f_c), .DOD(f_d)
    );

    wire [1:0] u_a, u_b, u_c, u_d;
    RAM32M #(
        .INIT_A(64'h243F6A8885A308D3), .INIT_B(64'h13198A2E03707344),
        .INIT_C(64'hA4093822299F31D0), .INIT_D(64'h082EFA98EC4E6C89)
    ) r_unread (
        .WCLK(clk), .WE(we),
        .ADDRA(ra[4:0]), .ADDRB(ra[5:1]), .ADDRC(ra[4:0]), .ADDRD(wa[4:0]),
        .DIA(2'b00), .DIB(2'b00), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(u_a), .DOB(u_b), .DOC(u_c), .DOD(u_d)
    );

    wire [1:0] e_a, e_b, e_c, e_d;
    RAM32M #(
        .INIT_A(64'hB5C0FBCFEC4D3B2F), .INIT_B(64'hE9B5DBA58189DBBC),
        .INIT_C(64'h3956C25BF348B538), .INIT_D(64'h59F111F1923F82A4)
    ) r_dfree (
        .WCLK(clk), .WE(we),
        .ADDRA({1'b0, ra[3:0]}), .ADDRB({1'b0, ra[3:0]}),
        .ADDRC({1'b0, ra[3:0]}), .ADDRD(wa[4:0]),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(e_a), .DOB(e_b), .DOC(e_c), .DOD(e_d)
    );

    wire [1:0] n_a, n_b, n_c, n_d;
    RAM32M #(
        .INIT_A(64'hAB1C5ED5DA6D8118), .INIT_B(64'hD807AA98A3030242),
        .INIT_C(64'h12835B0145706FBE), .INIT_D(64'h243185BE4EE4B28C)
    ) r_dunread (
        .WCLK(clk), .WE(we),
        .ADDRA(ra[4:0]), .ADDRB(ra[5:1]), .ADDRC(ra[4:0]), .ADDRD(wa[4:0]),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(2'b00), .DID(2'b00),
        .DOA(n_a), .DOB(n_b), .DOC(n_c), .DOD(n_d)
    );

    wire t_a, t_b, t_c, t_d;
    RAM64M #(
        .INIT_A(64'h550C7DC3D5FFB4E2), .INIT_B(64'h72BE5D74F27B896F),
        .INIT_C(64'h80DEB1FE3B1696B1), .INIT_D(64'h9BDC06A725C71235)
    ) r64u (
        .WCLK(clk), .WE(we),
        .ADDRA(ra), .ADDRB(ra), .ADDRC(ra), .ADDRD(wa),
        .DIA(1'b0), .DIB(1'b0), .DIC(d[2]), .DID(d[3]),
        .DOA(t_a), .DOB(t_b), .DOC(t_c), .DOD(t_d)
    );

    wire [1:0] w_a, w_b, w_c, w_d;
    RAM32M #(
        .INIT_A(64'hC19BF174CF692694), .INIT_B(64'hE49B69C19EF14AD2),
        .INIT_C(64'hEFBE4786384F25E3), .INIT_D(64'h0FC19DC68B8CD5B5)
    ) r_wide (
        .WCLK(clk), .WE(we),
        .ADDRA({2'b00, ra[2:0]}), .ADDRB({2'b00, ra[2:0]}),
        .ADDRC({2'b00, ra[2:0]}), .ADDRD({2'b00, wa[2:0]}),
        .DIA(d[1:0]), .DIB(d[3:2]), .DIC(d[5:4]), .DID(d[7:6]),
        .DOA(w_a), .DOB(w_b), .DOC(w_c), .DOD(w_d)
    );

    wire g_a, g_b, g_c, g_d;
    RAM64M #(
        .INIT_A(64'h240CA1CC77AC9C65), .INIT_B(64'h2DE92C6F592B0275),
        .INIT_C(64'h4A7484AA6EA6E483), .INIT_D(64'h5CB0A9DCBD41FBD4)
    ) r64s (
        .WCLK(clk), .WE(we),
        .ADDRA({1'b0, ra[4:0]}), .ADDRB({1'b0, ra[4:0]}),
        .ADDRC({1'b0, ra[4:0]}), .ADDRD({1'b0, wa[4:0]}),
        .DIA(d[0]), .DIB(d[1]), .DIC(d[2]), .DID(d[3]),
        .DOA(g_a), .DOB(g_b), .DOC(g_c), .DOD(g_d)
    );

    assign q = ^{b_a, b_b, b_c, b_d, m_a, m_b, m_c, m_d, v_a, v_b, v_c, v_d, s_a, s_b, s_c, s_d,
                 f_a, f_b, f_c, f_d, u_b, u_c, u_d, e_a, e_b, e_c, e_d, n_a, n_b, n_c, t_b, t_c, t_d,
                 w_a, w_b, w_c, w_d, g_a, g_b, g_c, g_d};
endmodule
