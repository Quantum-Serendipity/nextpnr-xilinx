# Placement does not depend on a timing exception that matches no path

Places and routes `top.v` on an `xc7a100tfgg484` three times with seed 1: twice with `base.xdc`,
and once with `inert.xdc`, which adds `set_false_path -from [get_cells inert_a*] -to [get_cells
inert_b*]`. No path runs from `inert_a` to `inert_b`, so the exception cannot change any timing
figure.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `base_again` | the two `base.xdc` runs write the same FASM, so a difference below is not run-to-run noise |
| `inert` (log) | the log shows the exception read with one `from` cell and eight `to` cells |
| `inert` (FASM) | the `inert.xdc` FASM is byte-identical to the `base.xdc` FASM |
