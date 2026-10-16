# Hard-block clock ties

`pack_constants` keeps a block-RAM or DSP clock pin on its net when the net has no driver, so that
an RM-only build can leave the region clock to the static design. A clock bit the netlist gives as
`x` or `z` is not such a net: the frontend records the value on the net (`NetInfo::undef_const`),
and the packer ties the pin and warns, naming the cell and pin. This regression packs four `RAMB18E1` designs with
`--pack-only` and reads the clock net of `CLKARDCLK` in the written JSON.

```
CHIPDB=/path/to/xc7a100tcsg324.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | netlist | passes when |
|---|---|---|
| `hier_x` | not flattened; the parent drives `1'bx` into a `keep_hierarchy` submodule's clock port | tied to a packer constant, with one warning |
| `hier_x_merge` | as `hier_x`, but the submodule also drives the clock out on an output port declared first, so the parent's `x` net is merged into the parent net on that port | tied, with one warning |
| `flat_x` | flattened; the clock is an undriven wire, which yosys writes as `x` | tied, with one warning |
| `flat_port_noport` | flattened with the clock as a top-level port, then the port removed from the JSON | kept on its own undriven net, and the `kept` line printed once |
