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

Four more runs reuse those designs with other XDCs, and `order.v` adds a fifth design:

- `top-exc.xdc` adds `set_max_delay 5 -to [get_cells p_shift*]` to `top.v`. The exception equals the
  `b0 -> b1` edge separation, so only a label taken from the exception itself, not from comparing the
  two numbers, can say the requirement came from the exception.
- `three-mismatch.xdc` sets `pix_clk` to 24 ns, which disagrees with the 25 ns the MMCM derives. The
  derivation is refused with a warning and the crossing falls back to the shorter period, 10 ns.
- `three-pad.xdc` is `three.xdc` plus an 8 ns `create_clock` on the `clk_i` pad, which disagrees with the
  10 ns on `clk` and the 25 ns on `pix_clk`. Both derivations from the pad are refused, so `clk` and
  `pix_clk` must not be related through `clk_i`, even where an earlier pass matched before the pad's own
  derivation arrived.
- `order-pad.xdc` runs `order.v`, whose `create_clock` on `pix_clk` (20 ns) sits on the MMCM output itself,
  ahead of its BUFG, with 10 ns on `clk`, 8 ns on `aux_clk` and 8 ns on the `clk_i` pad. Derived from the
  pad, the MMCM gives `pix_clk` 20 ns and `aux_clk` 8 ns, so both agree and `pix_clk_g -> aux_clk` is related
  through `clk_i` with a 4 ns edge separation; the shorter period would be 8 ns. Propagation visits cells in
  IdString order, the order their names were first interned while the netlist was read, not
  alphabetical order. For this netlist yosys writes the cells in an order that puts `a_mmcm` ahead of
  `ib` and `mmcm` behind it, and the order arm checks the outcome rather than assuming it. The MMCM
  is built as `mmcm` (`order-pad-last`, reached after the pad's IBUF) and as `a_mmcm`
  (`order-pad-first`, reached first, while its input still holds the 10 ns carried back from `clk`).
  The 25 ns that carried value yields for `pix_clk` disagrees and must not block the agreeing
  derivation that follows.
- `unrelated-tight.xdc` sets `sclk` to 0.8 ns and runs under `--router router1`, whose post-route report
  turns a failing verdict into an `ERROR:` line. `sclk` has no path of its own, so the only errors are the
  two crossings and nextpnr exits 1. The same run with `--timing-allow-fail` is `unrelated-tight-allow`.

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
| three verdict | every max-delay line for each direction grades against a 5.00 ns edge separation, related through `clk` |
| three population | the grading line counts only the `create_clock` nets as constrained, none of the nets the constraints were carried back to |
| unrelated `clk <-> sclk` | every row for each direction has `period_ns` 10 |
| unrelated verdict | every `clk -> sclk` max-delay line grades against the 10.00 ns shorter period, with no derived relation |
| top-exc verdict | every `b0 -> b1` max-delay line names the 5.00 ns requirement as set by a timing exception |
| three-mismatch warning | `o0` refuses the 40.0 MHz derivation because it carries the 41.7 MHz constraint of `pix_clk` |
| three-mismatch `clk -> pix_clk` | every row has `period_ns` 10, and every max-delay line says no derived relation |
| three-pad warning | `clk` refuses the 125.0 MHz derived from the 8 ns pad through `gs` |
| three-pad `clk <-> pix_clk` | every row for each direction has `period_ns` 10, and every max-delay line says no derived relation |
| order-pad-last / order-pad-first order | the first MMCM input line reads 125.0 MHz for `mmcm` and 100.0 MHz for `a_mmcm`, so each run took the order it names; `order-pad-first` carries exactly one warning that the 40.0 MHz derived for `pix_clk` from the carried constraint on `clk_ibuf` is not applied, and `order-pad-last` carries none |
| order-pad-last / order-pad-first `pix_clk_g -> aux_clk` | every row has `period_ns` 4, and every max-delay line is related through `clk_i` |
| unrelated-tight | nextpnr exits 1, the `clk -> sclk` line is an `ERROR:` FAIL against 0.80 ns, and no other `ERROR:` line exists |
| unrelated-tight-allow | with `--timing-allow-fail` nextpnr exits 0, the same FAIL prints as a `Warning:` line, and no `ERROR:` line exists |

Every verdict arm reads all the max-delay reports in the log, the post-place one and the post-route one.
