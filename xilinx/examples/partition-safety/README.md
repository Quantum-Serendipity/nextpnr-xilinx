# Partition safety

Places `top.v` once on an `xc7a100tfgg484`, with its inputs on the left edge and its outputs on the
right, routes it, and then runs each arm below against that placement. Every arm is a way a
partition rectangle used to be escaped, or a partition output used to be lost, at rc 0.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`NPNR_TIMEOUT` bounds each nextpnr run in seconds (default 600). `run.sh` exits non-zero if any arm
fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| `--region-only` without a rectangle | `--write-fixed-routes` is refused, and the file it names is byte-identical afterwards |
