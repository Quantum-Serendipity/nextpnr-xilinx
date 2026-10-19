module top (
    input  clk,
    input  a,
    input  b,
    output y,
    output z
);
    wire d, nz, q;
    (* keep, dont_touch, BEL = "SLICE_X86Y149/A6LUT" *) LUT2 #(.INIT(4'h6)) u_x (.I0(a), .I1(b), .O(d));
    (* keep, dont_touch, BEL = "SLICE_X86Y149/AFF" *) FDRE #(.INIT(1'b0)) u_q (.C(clk), .CE(1'b1), .R(1'b0), .D(d), .Q(q));
    (* keep, dont_touch, BEL = "SLICE_X86Y149/B6LUT" *) LUT2 #(.INIT(4'h1)) u_z (.I0(a), .I1(b), .O(nz));
    assign y = q;
    assign z = nz;
endmodule
