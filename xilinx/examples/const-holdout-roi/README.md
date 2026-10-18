# Constant holdouts under a partition rectangle

Places `top.v`, one `SRL16E` with `CE` tied high, on an `xc7a100tfgg484`, then routes it with every
`VCC_WIRE` pip of the SRL's INT column withheld through `NEXTPNR_PIP_BLACKLIST_TILE`. The constant
fill cannot reach the SRL's `WE`, so the sink becomes a holdout that only a constant LUT driver can
deliver. Each arm routes that placement under a different partition rectangle.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`PRJXRAY_DB` names the prjxray-db root (default: this fork's `xilinx/external/prjxray-db`
submodule); `run.sh` reads `artix7/xc7a100t/tilegrid.json` and `artix7/ppips_int_*.db` from it.
`RADIUS` must equal the holdout driver search radius in `xilinx/route_const.cc`
(`const_lut_search_radius`). `NPNR_TIMEOUT` bounds each nextpnr run in seconds. `run.sh` exits
non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| no rectangle | rc 0, the blacklist resolved pips, and the log hands `WE` to a `$PACKER_VCC_NET$holdout$` net |
| rectangle clear of the sink | under a rectangle beside the SRL, rc 0, `WE` is handed to a holdout net, and every holdout LUT sits in a tile whose own column and both neighbours are outside the rectangle |
| only driver inside a rectangle | with every free LUT bel within `RADIUS` of the SRL withheld by `NEXTPNR_BEL_BLACKLIST` except those inside the rectangle, the route is refused, the log names no free LUT bel outside every partition rectangle, and `WE` is a refused sink |
| sink inside a rectangle | under a rectangle containing the SRL, the route is refused and `WE` is refused as a sink inside a partition rectangle |
