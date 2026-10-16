# A clock graded at the default target

Places and routes `top.v` (the `setup-export` design) on an `xc7a100tfgg484`, then replays the
routed JSON with `NEXTPNR_TIMING_ONLY=1 --no-pack` and an XDC that carries no `create_clock`, so
nothing constrains `clk` and the analysis falls back to the 12 MHz default target.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| replay with no clock constraint | the `clk` Fmax line says `UNCONSTRAINED`, not PASS or FAIL |
| replay with --freq 100 | the same routed JSON replayed with `--freq 100` grades `clk` at 100 MHz, not at the 12 MHz default the first run stored |
| create_clock run | the full run, constrained by `clock.xdc`, still grades `clk` at 100 MHz |
| --freq run | a full run with no `create_clock` and `--freq 50` still grades `clk` at 50 MHz |
| replay of the --freq 50 run | that run's written JSON, replayed with no `--freq`, still grades `clk` at 50 MHz |
