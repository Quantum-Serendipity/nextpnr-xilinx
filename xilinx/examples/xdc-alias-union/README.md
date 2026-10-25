# A create_clock target list naming two aliases of one net

`top.v` drives the flip-flops from `ddr_sys_clk`, the top-level wire on the output of
`u_ddr3`'s BUFG, which inside `u_ddr3` is called `sys_clk` and `o_sys_clk`. After `flatten`
the three names are aliases of one net, and nextpnr names the net `ddr_sys_clk`. `union.xdc`
constrains it as `[get_nets {u_ddr3.sys_clk ddr_sys_clk}]`.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| alias union on the synthesised netlist | the full run with `union.xdc` grades `ddr_sys_clk` at 100 MHz and refuses no member |
| written netlist names the net's aliases | the `ddr_sys_clk` entry of the written JSON carries `NEXTPNR_NET_ALIASES` naming `u_ddr3.sys_clk` and `u_ddr3.o_sys_clk` |
| create_clock on an alias absent from the written net names | a timing replay of the written JSON with `alias-only.xdc` (`[get_nets u_ddr3.sys_clk]`) grades the clock at 100 MHz with no dropped constraint |
| alias union on the written netlist | the same replay with `union.xdc` grades the clock and refuses no member |
| aliases survive a second write | the replay's own written JSON carries the same aliases and grades `alias-only.xdc` |
| misspelt union member on the synthesised netlist | `misspelt.xdc` (`{u_ddr3.sys_clk ddr_sys_clkx}`) stops the run, naming `ddr_sys_clkx` |
| misspelt union member on the written netlist | the same file stops the replay of the written JSON |
