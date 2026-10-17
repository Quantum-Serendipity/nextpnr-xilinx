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
| `pll_d27_p185` | `CLKOUT1_CLKOUT1_PHASE_MUX[2:0] = 3'b111` and `CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'b001101`: 185 degrees at divide 27 is 111 eighths |
| `mmcm_d1_p90` | a divide-1 output keeps `NO_COUNT` and still gets `PHASE_MUX[2:0] = 3'b010`, `DELAY_TIME[5:0] = 6'b000000` and `POWER_REG = 16'h9900` |
| `mmcm_mult_default`, `pll_mult_default` | an unset `CLKFBOUT_MULT_F`/`CLKFBOUT_MULT` is 5: `CLKFBOUT` high 2, low 3, no `NO_COUNT`, and the log's VCO is five times the input |
| `dsp_pattern` | `PATTERN=48'h000000000001` and `MASK=48'hC00000000002` are written bit for bit, `MASK[47:46]` included |
| `dsp_default` | no `PATTERN` line, and `MASK[47:0]` is the primitive default `48'h3FFFFFFFFFFF` |
| `dsp_areg3`, `dsp_areg0_acascreg1`, `dsp_breg1_bcascreg2` | refused, naming the illegal `AREG`/`ACASCREG` or `BREG`/`BCASCREG` pair |
| `dsp_simd_bogus` | refused, naming `USE_SIMD` and its legal values |
| `dsp_simd_four12` | `USE_SIMD_FOUR12` and `USE_SIMD_FOUR12_TWO24` |
| `dsp_sel_pattern_c` | refused, naming `SEL_PATTERN=C` |
| `bram_sdp` | no `EN_ECC` line |
| `bram_ecc` | `RAMB36.EN_ECC_READ` and `RAMB36.EN_ECC_WRITE` |
| `bram_w1` | `RAMB36.BRAM36_READ_WIDTH_A_1` written once |
| `bram_ext_lowercase`, `bram_collision_bogus` | refused, naming the parameter and its legal values |
| `oddr_t_tie0` | an ODDR on a tristate input with `D1` tied to 0 builds, with `ZINV_T2` and no `ZINV_T1` |
| `iob_lvcmos33_d16`, `iob_lvcmos33_d12`, `iob_lvttl_d12`, `iob_lvttl_d16` | the IOB33 `DRIVE` pattern: `LVCMOS33.DRIVE.I16`, `LVCMOS33_LVTTL.DRIVE.I12_I16`, `LVCMOS33_LVTTL.DRIVE.I12_I8`, `LVCMOS33_LVTTL.DRIVE.I12_I16` |

An arm named `<arm>` reads `<arm>.xdc` instead of `fasm-params.xdc` when that file exists.
