# Per-net criticality across clock domains

Places and routes `top.v` on an `xc7a100tfgg484` and grades the criticality export. Two registers,
`x_q` on `clk_a` and `y_q` on `clk_b`, each capture the top byte of a 12x12 LUT multiplier from
their own domain XORed with one register from the other domain. So each D net is reached from two
start domains: its own, where it ends the longest path, and the other, where it ends a single LUT.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`FLOOR` sets the threshold (default 0.5). `run.sh` exits non-zero if an arm fails and leaves its
outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| `x_q`, `y_q` | the `NEXTPNR_CRIT_EXPORT` criticality of the cell driving each of the eight D nets is at least `FLOOR` |
