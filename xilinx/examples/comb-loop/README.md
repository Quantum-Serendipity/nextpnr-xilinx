# Combinational loops

Builds `top.v` twice on an `xc7a100tfgg484`. With `-DRING` it carries two combinational loops: a
two-LUT ring (`r1`, `r2`) and a three-LUT component with two cycles (`r3`, `r4`, `r5`), and every
bit of the register `p` reads a 16x16 LUT multiplier XORed with one output of each. The control
build breaks both loops with a register, so it has the same `p` cone and no loop.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| control, ring | all 32 `p` registers have a row in the `NEXTPNR_SETUP_EXPORT` file |
| control | the log reports no combinational loop |
| ring | the log reports 2 loops cut at 3 output ports |
| strict | `--no-ignore-loops` stops the run with an error naming 2 loops through 5 output ports |
