# Related clocks from one MMCM

Places and routes `top.v` on an `xc7a100tfgg484`. One MMCM on the 100 MHz input makes `b0` at
100 MHz, `b1` at 25 MHz with `CLKOUT1_PHASE` 45 (its rising edge 5 ns after the input's), and `b2`
at 25 MHz with no phase. A 16x16 LUT multiplier on `b0` is captured on `b1` and on `b2`. The real
setup budget of `b0 -> b1` is the smallest positive gap from a `b0` edge to the next `b1` edge,
5 ns, which is tighter than either clock's period; `b0 -> b2` has 10 ns.

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
| feedback clock | `fb`, the MMCM's `CLKFBOUT`, is derived at 100 MHz (input / `DIVCLK_DIVIDE`), not the VCO rate |
