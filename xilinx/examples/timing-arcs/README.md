# Timing arcs

Places and routes one small design per arm on an `xc7a100tfgg484` with a 10 ns clock, and grades the
`NEXTPNR_SETUP_EXPORT` rows against the routed netlist with `grade.py`.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`ARMS` overrides the arm list. `run.sh` exits non-zero if any arm fails and leaves its outputs in
`$OUT` (a fresh `mktemp -d` by default).

| arm | design | passes when |
|---|---|---|
| negedge | posedge flops, a LUT multiplier, `FDRE_1` flops, posedge flops | every `D` row of a flop with `IS_CLK_INVERTED=1` has a 5 ns period, and a posedge flop has a 5 ns row |
| latch | posedge flops, an adder, `LDCE` latches gated by the clock, posedge flops | every latch `D` row has a 5 ns period, and the flops after the latch have both a 5 ns and a 10 ns row |
