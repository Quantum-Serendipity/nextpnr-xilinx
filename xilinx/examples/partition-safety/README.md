# Partition safety

Places `top.v` once on an `xc7a100tfgg484`, with its inputs on the left edge and its outputs on the
right, routes it, and then runs each arm below against that placement. Every arm is a way a
partition rectangle used to be escaped, or a partition output used to be lost, at rc 0.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

The rectangles are chosen from the base route, so `run.sh` reads prjxray-db's
`artix7/xc7a100t/tilegrid.json` to turn tile names into grid coordinates. `PRJXRAY_DB` names the
database root; the default is this fork's `xilinx/external/prjxray-db` submodule. `geom.py` does the
lookups. `NPNR_TIMEOUT` bounds each nextpnr run in seconds (default 600). `run.sh` exits non-zero if any arm
fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| `--region-only` without a rectangle | `--write-fixed-routes` is refused, and the file it names is byte-identical afterwards |
| `--fixed-routes` precedence | a netlist written by a run with `--fixed-routes A` stores A in its settings, and reloading it with `--fixed-routes B` applies B and never A |
| router1 under a rectangle | a netlist placed with `--router router1`, which stores that router in its settings, is refused when it is routed with `NEXTPNR_PARTITION_ROI` set; with `NEXTPNR_PARTITION_CLAMP=off` and `NEXTPNR_PARTITION_KEEPOUT=off` as well it routes at rc 0 |
| static keepout, router2 control | a one-tile rectangle on an INT tile the longest static net crosses is routed around by router2 at rc 0, and the keepout gate's census reads 0 unlicensed |
| static keepout, `--fixed-routes` | the base route replayed with `--fixed-routes` under that rectangle is refused by the keepout gate |
| static keepout, imported routing | the routed netlist, kept as-is with `NEXTPNR_ROUTE_FIXED_ONLY=1` under that rectangle, is refused by the keepout gate |
| static keepout, keepout off | the `--fixed-routes` replay with `NEXTPNR_PARTITION_KEEPOUT=off` exits rc 0 and the gate's report-only census names the unlicensed pips |
