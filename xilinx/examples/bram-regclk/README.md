# Block RAM output-register clocks

Places and routes `top.v` on an `xc7a100tfgg484`: a RAMB18E1 in true dual port with `DOA_REG` and
`DOB_REG` set (`r18`), a RAMB36E1 in true dual port with `DOB_REG` set (`r36t`), and a RAMB36E1 in
simple dual port at x72 with both set (`r36s`). An output register loads on the site pins
`REGCLKARDRCLK` and `REGCLKB` (L and U on a RAMB36), which the primitive has no port for.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `r18`, `r36t`, `r36s` | in the routed netlist the output-register clock pin of each registered port is on the port clock, and `REGCLKB` has no net in simple dual port, as Vivado leaves it |
| clock routing | the clock net's routing reaches at least six output-register clock site wires |
| `ZINV_REGCLKB` | the FASM carries three `ZINV_REGCLKB` lines: `r18` and both halves of `r36t`, and none for `r36s` |
