module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    wire clk_ibuf, clk_a;
    IBUF ib (.I(clk_i), .O(clk_ibuf));
    BUFG bg_a (.I(clk_ibuf), .O(clk_a));

    reg [31:0] lfsr = 32'h1;
    always @(posedge clk_a)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    wire spo, dpo;
    RAM64X1D mem_reg (
        .WCLK(clk_a), .WE(lfsr[0]), .D(lfsr[1]),
        .A0(lfsr[2]), .A1(lfsr[3]), .A2(lfsr[4]), .A3(lfsr[5]), .A4(lfsr[6]), .A5(lfsr[7]),
        .DPRA0(lfsr[8]), .DPRA1(lfsr[9]), .DPRA2(lfsr[10]), .DPRA3(lfsr[11]), .DPRA4(lfsr[12]), .DPRA5(lfsr[13]),
        .SPO(spo), .DPO(dpo));

    wire [1:0] doa, dob, doc, dod;
    RAM32M mem32_reg (
        .WCLK(clk_a), .WE(lfsr[14]),
        .ADDRA(lfsr[19:15]), .ADDRB(lfsr[24:20]), .ADDRC(lfsr[29:25]), .ADDRD(lfsr[19:15]),
        .DIA(lfsr[1:0]), .DIB(lfsr[3:2]), .DIC(lfsr[5:4]), .DID(lfsr[7:6]),
        .DOA(doa), .DOB(dob), .DOC(doc), .DOD(dod));

    (* keep *) reg [9:0] dst_ram = 0;
    always @(posedge clk_a)
        dst_ram <= {spo, dpo, doa, dob, doc, dod};

    assign led = dst_ram[7:0] ^ {6'b0, dst_ram[9:8]};
endmodule
