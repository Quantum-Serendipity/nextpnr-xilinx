module top (
    input  clk,
    input  a,
    input  b,
    output y,
    output z
);
    (* keep, dont_touch, BEL = "SLICE_X86Y149/A6LUT" *) LUT2 #(.INIT(4'h6)) u_s (.I0(a), .I1(b), .O(y));
    (* keep, dont_touch, BEL = "SLICE_X86Y149/B6LUT" *) LUT2 #(.INIT(4'h1)) u_r (.I0(a), .I1(b), .O(z));
endmodule
