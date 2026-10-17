# Clock groups through a clock mux

Places and routes `top.v` on an `xc7a100tfgg484`. `clk_a` is a BUFG of the 100 MHz input, `clk_b` a
BUFG of a PLL output, and `clk_m` a BUFGMUX with the input on `I0` and the PLL output on `I1`.
`clock-mux-groups.xdc` declares `sysclk` and `pll_out` asynchronous with `set_clock_groups`.

`undriven-mux.v` adds three BUFGMUXes with the PLL output on `I0` and, on `I1`, an `x` constant
(`clk_x`), an input whose IBUF `run.sh` strips after synthesis so the net has no driver (`clk_w`), and
a second stripped input that `undriven-mux.xdc` constrains with `create_clock` (`clk_c`), as a
reconfigurable-module-only build leaves a clock from the static design. It is placed with
`--no-route` and the same groups.

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
| `clk_x -> clk_a` | no row: an `x` on `I1` is a constant, so the mux output carries only `pll_out` |
| `clk_w -> clk_a` | no row: an `I1` with no driver and no `create_clock` brings no declared clock |
| `clk_c -> clk_a` | a row: an `I1` with no driver but a `create_clock` brings `extclk`, which is in neither group |
