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
| row identity | the export carries `launch_clk_delay_ns`, `capture_clk_delay_ns` and `requirement_source`; on every row `slack_ns` equals `period_ns - (driver_arrival_ns + net_delay_ns + setup_ns - capture_clk_delay_ns)` to 1.5 ps, both clock delays are positive, and every row's `requirement_source` is `same` |
| hold launch corner | the full run's `NEXTPNR_HOLD_EXPORT` has `launch_clk_delay_ns` and `cppr_ns`; on every routed row `hold_slack_ns` equals `driver_min_arrival_ns + net_delay_min_ns - hold_ns - hold_req_ns - capture_clk_delay_ns + cppr_ns` to 1.5 ps, the launch clock delay (fast corner) is below the capture clock delay (slow corner), and the pessimism credit is positive and below the capture delay |
| replay agreement | every row's slack in that export equals the `NEXTPNR_TIMING_ONLY` replay of the routed JSON |
| placement-only export | with `NEXTPNR_POST_ROUTE_TIMING=0` every row says `estimate` |
| unwritable export | an export path in a missing directory stops the run with an error naming `NEXTPNR_SETUP_EXPORT` |
