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
| `dsp_pattern` | `PATTERN=48'h000000000001` and `MASK=48'hC00000000002` are written bit for bit, `MASK[47:46]` included |
| `dsp_default` | no `PATTERN` line, and `MASK[47:0]` is the primitive default `48'h3FFFFFFFFFFF` |
| `dsp_areg3`, `dsp_areg0_acascreg1`, `dsp_breg1_bcascreg2` | refused, naming the illegal `AREG`/`ACASCREG` or `BREG`/`BCASCREG` pair |
| `dsp_simd_bogus` | refused, naming `USE_SIMD` and its legal values |
| `bram_sdp` | no `EN_ECC` line |
| `bram_ecc` | `RAMB36.EN_ECC_READ` and `RAMB36.EN_ECC_WRITE` |
| `bram_w1` | `RAMB36.BRAM36_READ_WIDTH_A_1` written once |
| `bram_ext_lowercase`, `bram_collision_bogus` | refused, naming the parameter and its legal values |
