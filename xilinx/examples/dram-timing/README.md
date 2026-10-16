# Distributed-RAM timing

Places and routes `top.v`, two 64x32 distributed RAMs with a registered read, on an
`xc7a100tfgg484` once per placer and seed, and grades each run. The `sa` runs stop after placement
(`--no-route`): `--placer sa` does not route this design at 135e8a04 either, which is a placer
legality matter outside this fixture.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`SEEDS` overrides the seed list and `PLACERS` the placer list (`heap sa` by default). `run.sh` exits
non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| place and route | rc 0, and no `timed against a guess` error in the log (`sa`: place only) |
| sites (`heap` only) | at least one SLICEM `LUT.RAM` FASM feature, and no RAM, SMALL or SRL feature in a SLICEL, of a CLBLL or a CLBLM tile |
| write pins | `NEXTPNR_SETUP_EXPORT` has a row for a `WE`, `WA*` or `DI*` pin of a distributed-RAM cell |
