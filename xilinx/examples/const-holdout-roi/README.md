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
`RADIUS` defaults to `const_lut_search_radius` read from `xilinx/route_const.cc`; an override must
equal the radius of the binary under test. `NPNR_TIMEOUT` bounds each nextpnr run in seconds. `run.sh` exits
non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| no rectangle | rc 0, the blacklist resolved pips, and the log hands `WE` to a `$PACKER_VCC_NET$holdout$` net |
| rectangle clear of the sink | under a rectangle beside the SRL, rc 0, `WE` is handed to a holdout net, and every holdout LUT sits in a tile whose own column and both neighbours are outside the rectangle |
| only driver inside a rectangle | with every free LUT bel within `RADIUS` of the SRL withheld by `NEXTPNR_BEL_BLACKLIST` except those inside the rectangle, the route is refused, the log names no free LUT bel outside every partition rectangle, and `WE` is a refused sink |
| sink inside a rectangle | under a rectangle containing the SRL, the route is refused and `WE` is refused as a sink inside a partition rectangle |
| only driver beside a rectangle | under a rectangle placed so that a logic tile beside its edge has its INT tile inside it, with every free LUT bel within `RADIUS` withheld except those in tiles outside the rectangle with a neighbouring column inside it, the route is refused with the outside-every-rectangle reason |
| reconfigurable cells | `top-rm.v`, the SRL plus one flop, placed, then re-placed and routed with the flop left unplaced so it is snapshotted as an RM cell; `WE` is refused because constant LUT drivers are disabled in a build with reconfigurable cells. The partition net gate is downgraded and the route clamp is off so that routing reaches the constant router |
| interconnect search out of budget | the rectangle-clear-of-the-sink route with `NEXTPNR_CONST_FENCE_WALK_BUDGET=0`; `WE` is refused as out of budget, not as fenced |
