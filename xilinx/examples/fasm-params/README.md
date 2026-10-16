# FASM parameter encoding

Builds one small design per arm on an `xc7a100tcsg324` and checks how the FASM writer encodes a
primitive parameter: the exact feature line it emits, or the refusal it stops with when the value
cannot be programmed.

```
CHIPDB=/path/to/xc7a100tcsg324.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

| arm | passes when |
|---|---|
| `mmcm_d128_p90` | `CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'b100000` |
| `pll_d100_p90` | `CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'b011001` |
| `mmcm_d128_p180`, `mmcm_d100_p270`, `pll_d100_p270` | refused with `PHASE_OUT_OF_RANGE`: the delay needs more than the six bits of `DELAY_TIME` |
