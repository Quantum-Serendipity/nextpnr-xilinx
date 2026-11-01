# Knob registry

`../counter25/top.json` is placed once on xc7a100tfgg484 with `counter25-a100t.xdc` and re-routed
at that placement for each arm.

```
CHIPDB=/path/to/xc7a100tfgg484.bin NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `--list-knobs` | rc 0; `knob/hold_export` is listed as not read from the environment, `placerHeap/beta` as the `NEXTPNR_PLACER_BETA` alias, `knob/carry_omit_gnd_di` and `knob/async_groups` as removed, `knob/setup_export_start` with no environment name |
| `--set knob/crit_export` takes effect | the criticality export is written, `knob knob/crit_export=... (from --set)` is logged and the key is in the written netlist's settings; without the option there is no export, no knob line and no `knob/` setting |
| environment refusal | `NEXTPNR_CRIT_EXPORT` in the environment is refused at a non-zero rc with a message naming `--set knob/crit_export` |
| removed knob | `NEXTPNR_CARRY_OMIT_GND_DI` is refused from the environment and `knob/carry_omit_gnd_di` from `--set`, each naming the removal |
| environment alias | `NEXTPNR_PLACER_BETA=0.3` is logged as a deprecated alias of `placerHeap/beta`, HeAP runs at beta 0.300, the written netlist records `placerHeap/beta=0.3`, and the FASM equals the `--set placerHeap/beta=0.3` run's |
| router2 options | router2 with no option routes at rc 0 with no `router2:` mode line and no `tmgfail=` iteration; with `router2/critWeight=1`, `router2/tmgRipupIters=2` and `router2/revisitLowerDelay=1` it routes at rc 0, logs the mode line and runs the timing-driven ripup iterations |
| carried settings | a netlist carrying `router2/critWeight`, `router2/tmgRipupIters`, `router2/revisitLowerDelay`, `router/estimateNearestWire` and `knob/no_longlines` is re-routed with every one of them named in the strip line, none acting and none written back; the same netlist with `--set router2/critWeight=1` runs weighted |
