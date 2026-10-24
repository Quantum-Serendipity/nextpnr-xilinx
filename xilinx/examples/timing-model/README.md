# Timing model

Places and routes `top.v` on an `xc7a100tfgg484` with a 10 ns clock, places `duty.v`, replays timing
on the routed netlist under the files in `xdc/`, and grades the exports with `grade.py`. The SDF
values are read from `$PRJXRAY_DB/artix7/timings` and the site types from
`$PRJXRAY_DB/artix7/xc7a100t/tilegrid.json`, not from the chipdb.

```
CHIPDB=/path/to/xc7a100tfgg484.bin PRJXRAY_DB=/path/to/prjxray-db YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

`NEXTPNR_SETUP_EXPORT` is the setup table. `NEXTPNR_HOLD_EXPORT` writes one
row per hold check: `cell`, `port`, `hold_slack_ns`, `net`, `net_delay_min_ns`,
`driver_min_arrival_ns`, `hold_ns`, `hold_req_ns`, `capture_clk_delay_ns`, `launch_clk`,
`capture_clk`, `delay_source`. `NEXTPNR_ARC_EXPORT` writes every cell arc of every placed cell:
`cell`, `type`, `bel`, `from`, `to`, `max_ns`, `min_ns`, with `min_ns` the value the hold pass adds.

| arm | design or replay | passes when |
|---|---|---|
| `arcs` | `top.v` routed | every LUT5, LUT6, CARRY4 and SELMUX2_1 arc has the SDF fast-corner minimum and slow-corner maximum of its site and variant, a SLICEM LUT is among them, and every used LUT input has an arc to every used output |
| `hold_export` | `top.v` routed | every hold row's slack is its minimum arrival plus net delay, less hold, hold requirement and capture clock-pin delay |
| `skew` | `top.v` routed | on every `lfsr` and `k_q` flop-to-flop row, the setup arrival is an SDF clk->Q maximum plus the launch flop's clock-pin delay, the hold arrival an SDF clk->Q minimum plus the launch flop's fast-corner clock-pin delay (the hold row's `launch_clk_delay_ns`, which must be positive and at most the SDF's slow-corner `INTERCONNECT` value, since the SDF carries one corner), and both slacks take the capture flop's slow-corner clock-pin delay (hold also adding back the row's `cppr_ns`), each pin's delay read from the `INTERCONNECT` entries of the `--sdf` file; the `k` flops are placed so that at least one row's capture clock is later than its launch clock and at least one earlier |
| `srl_launch` | `top.v` routed | the row on the net the SRL16E `sreg`'s output drives (found from the cell, because synthesis may rename `srl_o`), launched through the clocked combinational-output start point rather than a flop's register output, has a setup arrival equal to the SDF `LUT_OR_MEM{5,6}SHFREG` CLK->O maximum for `sreg`'s bel plus its clock-pin delay, and a hold arrival equal to that arc's minimum plus its fast-corner clock-pin delay, read and bounded the same way; removing the launch delay at that start point turns it red while `skew` stays green |
| `duty_mmcm` | `top.v` routed | `CLKOUT0_DUTY_CYCLE=0.25` on a 20 ns output gives a 5 ns posedge-to-negedge requirement |
| `duty_mmcm_b` | `duty.v` placed | a `CLKOUT0` to `CLKOUT0B` path is required in 5 ns, the inverted output rising where `CLKOUT0` falls |
| `replay_base`, `srl_base` | replay | the replay grades `b_q` at 10 ns and grades the SRL |
| `waveform` | `-waveform {0 3}` on a 10 ns clock | posedge-to-negedge rows have a 3 ns requirement |
| `mcp_from_to` | `set_multicycle_path 2 -setup -from a_q -to {bff d_q}` | `b_q` from `a_q` is required in 20 ns, `d_q`, launched from `c_q`, in 10 ns, and the `b_q` hold requirement moves to 10 ns |
| `mcp_from_other` | the same from `c_q` to `bff` | `b_q` stays at 10 ns |
| `mcp_noname` | `-to [get_cells d_q*]` with no `-filter` | `d_q` is required in 20 ns |
| `mcp_hold` | `mcp_from_to` plus `set_multicycle_path 1 -hold` | the `b_q` hold requirement is back at 0 |
| `srl_fp` | `set_false_path -to [get_cells sreg]` | the replay grades no SRL row |
| `strict_*` | `--xdc-strict` | an unsupported command, a virtual clock, an unreadable `-waveform`, a `-waveform` whose rising edge is not at 0, a multicycle path with no multiplier and one with `-setup -hold` are each refused, naming why |
| `lenient_*` | no `--xdc-strict` | the unsupported command, the unreadable `-waveform`, the `-waveform {2 5}` and the `-setup -hold` multicycle are accepted; `{2 5}` warns that the offset is not read and keeps its 3 ns high time, and the `-setup -hold` multicycle warns and is dropped, leaving `d_q` at 10 ns |
| `zero_checks` | `mutate_chipdb.py` clears every timing check in a copy of the chipdb | nextpnr refuses the copy |
| `zero_min` | `mutate_chipdb.py ... min` zeroes every propagation delay's minimum in a copy | every LUT, CARRY4 and SELMUX2_1 arc of `top.v` placed on the copy exports a zero minimum, not its maximum |
