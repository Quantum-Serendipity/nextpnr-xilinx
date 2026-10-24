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

    wire [15:0] addr = lfsr[15:0];
    wire cas_a;
    wire [31:0] do_lower, do_upper, do_ref;

    RAMB36E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(1), .WRITE_WIDTH_A(1), .READ_WIDTH_B(0), .WRITE_WIDTH_B(0),
               .RAM_EXTENSION_A("LOWER"), .DOA_REG(0)) ram_lower (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({4{lfsr[20]}}), .ADDRARDADDR(addr), .DIADI({31'd0, lfsr[16]}), .DIPADIP(4'd0),
        .CASCADEINA(1'b0), .CASCADEOUTA(cas_a), .DOADO(do_lower),
        .CLKBWRCLK(1'b0), .ENBWREN(1'b0), .REGCEB(1'b0), .RSTRAMB(1'b0), .RSTREGB(1'b0), .WEBWE(8'd0),
        .ADDRBWRADDR(16'hffff), .DIBDI(32'd0), .DIPBDIP(4'd0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0));

    RAMB36E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(1), .WRITE_WIDTH_A(1), .READ_WIDTH_B(0), .WRITE_WIDTH_B(0),
               .RAM_EXTENSION_A("UPPER"), .DOA_REG(0)) ram_upper (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({4{lfsr[20]}}), .ADDRARDADDR(addr), .DIADI({31'd0, lfsr[16]}), .DIPADIP(4'd0),
        .CASCADEINA(cas_a), .DOADO(do_upper),
        .CLKBWRCLK(1'b0), .ENBWREN(1'b0), .REGCEB(1'b0), .RSTRAMB(1'b0), .RSTREGB(1'b0), .WEBWE(8'd0),
        .ADDRBWRADDR(16'hffff), .DIBDI(32'd0), .DIPBDIP(4'd0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0));

    RAMB36E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(1), .WRITE_WIDTH_A(1), .READ_WIDTH_B(0), .WRITE_WIDTH_B(0),
               .DOA_REG(0)) ram_ref (
        .CLKARDCLK(clk), .ENARDEN(1'b1), .REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
        .WEA({4{lfsr[21]}}), .ADDRARDADDR(addr), .DIADI({31'd0, lfsr[17]}), .DIPADIP(4'd0),
        .CASCADEINA(1'b0), .DOADO(do_ref),
        .CLKBWRCLK(1'b0), .ENBWREN(1'b0), .REGCEB(1'b0), .RSTRAMB(1'b0), .RSTREGB(1'b0), .WEBWE(8'd0),
        .ADDRBWRADDR(16'hffff), .DIBDI(32'd0), .DIPBDIP(4'd0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0));

    (* keep *) reg q_cas = 0, q_ref = 0;
    always @(posedge clk) begin
        q_cas <= do_upper[0];
        q_ref <= do_ref[0];
    end

    assign led = {6'd0, q_cas, q_ref};
endmodule
