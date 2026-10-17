module top (
    input clk_i,
    input btn,
    output [7:0] led
);
    reg [31:0] lfsr = 32'h1;
    always @(posedge clk_i)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ btn};

    reg [15:0] acc = 0, prod = 0;
    always @(posedge clk_i) begin
        acc <= acc + lfsr[15:0] + {lfsr[7:0], lfsr[31:24]};
        prod <= lfsr[23:16] * lfsr[7:0];
    end

    (* keep *) reg inert_a = 0;
    (* keep *) reg [7:0] inert_b = 0;
    always @(posedge clk_i) begin
        inert_a <= btn;
        inert_b <= acc[7:0] ^ prod[15:8];
    end

    wire mcp_q;
    (* keep *) FDRE mcp_dst (.C(clk_i), .CE(1'b1), .R(1'b0), .D(lfsr[3] ^ lfsr[9]), .Q(mcp_q));

    assign led = inert_b ^ {6'b0, mcp_q, inert_a};
endmodule
