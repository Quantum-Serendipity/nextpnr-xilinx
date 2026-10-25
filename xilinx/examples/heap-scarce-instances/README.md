# Two HeAP placers in one process

`top.v` is placed once, its LUTs and flip-flops are unplaced, and the result is placed twice in
one `nextpnr-xilinx --run two_placers.py` process: first `ctx.place()` under the partition
rectangle (100,180)-(120,200), then a second context made with `load_design` and placed with no
rectangle. Each HeAP legaliser logs its own classification of SLICE_LUTX the first time it
legalises that type.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| two HeAP placers in one process both complete | the script runs to its end at rc 0 |
| first placer, under a rectangle, counts its own candidates | the first classification line gives at most 4096 candidates of more than 4096 device bels and says scarce |
| second placer, with no rectangle, counts its own candidates rather than the first placer's | there are exactly two classification lines and the second gives more than 4096 candidates and says abundant |
