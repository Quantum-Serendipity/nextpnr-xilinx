# Setup-slack export provenance

Places and routes `top.v`, an 8x8 LUT multiplier between two register banks on one clock, on an
`xc7a100tfgg484` and grades the `NEXTPNR_SETUP_EXPORT` file. `clock.xdc` constrains the BUFG output
net, so a `--no-pack` replay of the routed JSON grades against the same period as the full run.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| router2 export | a default (router2) run's export has a `delay_source` column and every row says `routed` |
| replay agreement | every row's slack in that export equals the `NEXTPNR_TIMING_ONLY` replay of the routed JSON |
| placement-only export | with `NEXTPNR_POST_ROUTE_TIMING=0` every row says `estimate` |
| unwritable export | an export path in a missing directory stops the run with an error naming `NEXTPNR_SETUP_EXPORT` |
