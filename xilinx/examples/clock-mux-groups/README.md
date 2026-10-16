# Clock groups through a clock mux

Places and routes `top.v` on an `xc7a100tfgg484`. `clk_a` is a BUFG of the 100 MHz input, `clk_b` a
BUFG of a PLL output, and `clk_m` a BUFGMUX with the input on `I0` and the PLL output on `I1`.
`clock-mux-groups.xdc` declares `sysclk` and `pll_out` asynchronous with `set_clock_groups`.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| `clk_a -> clk_b` | the `NEXTPNR_SETUP_EXPORT` file has no row for the pair |
| `clk_m -> clk_b` | the export has a row for the pair: with `I1` selected the mux output is `clk_b`'s own clock |
| `clk_m -> clk_a` | the export has a row for the pair: with `I0` selected the mux output is `clk_a`'s own clock |
