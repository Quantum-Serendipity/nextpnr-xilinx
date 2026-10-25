# Stale exemption names intern nothing

`top.v` is placed, then routed twice under the partition rectangle (0,0)-(20,200): once with no
exemption files, and once with `NEXTPNR_PARTITION_EXEMPT_NETS` and
`NEXTPNR_PARTITION_KEEPOUT_EXEMPT` both naming two nets the design does not have. A loader that
interns each name before looking it up adds IdStrings in the middle of the run; every name
interned after them gets a different index, and hash containers keyed by IdString then iterate in
another order. The written netlist shows it: a cell's attributes come out in a different order.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| stale exemption names are counted unresolved | both routes exit 0 and the stale run reports 0 exempt and 2 unresolved |
| stale exemption names leave the FASM and the routes unchanged | the two runs write the same FASM and the same routes |
| stale exemption names leave the written netlist unchanged outside the partition_modes record | the two written JSON files are byte-identical once the `partition_modes` setting, which records the exemption files' digests by design, is set aside |
