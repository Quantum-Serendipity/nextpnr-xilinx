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
| srl | posedge flops, a LUT multiplier, an inferred 8-deep `SRL16E` bus, another multiplier, posedge flops; a 64-deep `SRLC32E` cascade | every SRL has a `DI` row, every flop pin in the combinational cone of an SRL output has a row, and an SRL `DI1` fed by an `MC31` has a row |
| undriven-clock | a counter addressing a block-RAM ROM with a registered read, and an adder into flops, all on `clk`; `run.sh` deletes the `clk` port and its `IBUF` from the netlist, leaving the net `rmclk` with no driver, as in a reconfigurable-module-only build | the block RAM has rows, every flop pin in the cone of a block-RAM output has a row, and the log names `rmclk` as a clock net with no driver |
| off-slicem | one `SRL16E` pinned by a `BEL` attribute to `SLICE_X43Y159/A6LUT`, the SLICEL half of `CLBLM_L_X26Y159`, then to `SLICE_X42Y159/A6LUT`, its SLICEM half; placed only (`--no-route`) | the SLICEL placement logs exactly one warning that names the bel as not a SLICEM LUT bel, and the SLICEM placement logs none |
