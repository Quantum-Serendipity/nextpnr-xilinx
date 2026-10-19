# Constant LUTRAM data inputs under a partition rectangle

Places `top.v`, one `RAM32M` with `DIA` tied to 0 and address bit 4 tied to 0 on every port, on an
`xc7a100tfgg484`, then routes it with every GND source pip withheld through
`NEXTPNR_PIP_BLACKLIST_TILE`: `GND_WIRE` to `GFAN0`/`GFAN1` in every INT tile and the row-GND pseudo
pip into each CLB tile's `A` LUT output. The constant fill cannot reach the A-LUT pair's `DI1`
(`AI`) and `DI2` (`AX`), or the `A5` and `WA5` inputs, so they become holdouts that only a constant
LUT driver can deliver. Each arm routes that placement under a different partition rectangle.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`PRJXRAY_DB` names the prjxray-db root (default: this fork's `xilinx/external/prjxray-db`
submodule); `run.sh` reads only `artix7/xc7a100t/tilegrid.json` from it and nothing else outside
this directory. `NPNR_TIMEOUT` bounds each nextpnr run in seconds. `run.sh` exits non-zero if any
arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| no rectangle | rc 0, the blacklist resolved pips, and the log hands both `DI2` and `DI1` to a `$PACKER_GND_NET$holdout$` net |
| rectangle clear of the sink | under a rectangle beside the RAM, rc 0, `DI2` and `DI1` are handed to a holdout net, every holdout LUT sits in a tile whose own column and both neighbours are outside the rectangle, and the eight `WA5` ports and the D-LUT pair's `A5` ports, which share one site wire, are all on one holdout net |
| sink inside a rectangle | under a rectangle containing the RAM, the route is refused and `DI2` is refused as a sink inside a partition rectangle |
