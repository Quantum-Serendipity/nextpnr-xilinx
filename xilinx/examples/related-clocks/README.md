# Related clocks from one MMCM

Places and routes `top.v` on an `xc7a100tfgg484`. One MMCM on the 100 MHz input makes `b0` at
100 MHz, `b1` at 25 MHz with `CLKOUT1_PHASE` 45 (its rising edge 5 ns after the input's), and `b2`
at 25 MHz with no phase. A 16x16 LUT multiplier on `b0` is captured on `b1` and on `b2`. The real
setup budget of `b0 -> b1` is the smallest positive gap from a `b0` edge to the next `b1` edge,
5 ns, which is tighter than either clock's period; `b0 -> b2` has 10 ns.

`coincident.v` is a second design on the same pins: `b0` at 240 MHz and `b1` at 120 MHz with
`CLKOUT1_PHASE` 180, so every `b1` rising edge lands exactly on a `b0` rising edge. A register on
`b1` is captured on `b0`, and the budget of `b1 -> b0` is one full `b0` period, not zero.

`three.v` constrains no port. Its `create_clock` lines sit on `clk` (10 ns, a BUFG output), `pix_clk`
(25 ns) and `pix5x_clk` (5 ns), the BUFG outputs of an MMCM whose `CLKIN1` is the pre-BUFG input
net. The edges of a 10 ns and a 25 ns clock from one source are 5 ns apart at the closest, so both
directions of `clk <-> pix_clk` have a 5 ns budget.

`unrelated.v` has `clk` (10 ns) and `sclk` (25 ns), a BUFG fed by a register on `clk`, so no
derivation relates them. A crossing between them is graded against the shorter period, 10 ns.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| `b0 -> b1` | every `NEXTPNR_SETUP_EXPORT` row for the pair has `period_ns` 5 |
| `b0 -> b2` | every row for the pair has `period_ns` 10 |
| `b0 -> b0` | every intra-domain row has `period_ns` 10 |
| cross-domain verdict | the log's `b0 -> b1` max-delay line carries a verdict against the 5.00 ns edge separation |
| coincident `b1 -> b0` | every row of `coincident.v` for the pair has `period_ns` 4.166 |
| coincident cross-domain verdict | the `b1 -> b0` max-delay line grades against a 4.17 ns edge separation |
| feedback clock | `fb`, the MMCM's `CLKFBOUT`, is derived at 100 MHz (input / `DIVCLK_DIVIDE`), not the VCO rate |
| three `clk <-> pix_clk` | every row for each direction has `period_ns` 5 |
| three verdict | each direction's max-delay line grades against a 5.00 ns edge separation, related through `clk` |
| three population | the grading line counts only the `create_clock` nets as constrained, none of the nets the constraints were carried back to |
| unrelated `clk <-> sclk` | every row for each direction has `period_ns` 10 |
| unrelated verdict | the `clk -> sclk` max-delay line grades against the 10.00 ns shorter period |
