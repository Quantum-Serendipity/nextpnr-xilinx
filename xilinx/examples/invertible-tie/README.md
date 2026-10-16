# Invertible pins tied to a constant

`pack_constants` moves an invertible pin that is tied to 0, or left unconnected, onto VCC and inverts it. This regression pins the case where the netlist already carries `IS_<pin>_INVERTED=1`. Each such design must come out the same as the matching design tied to 1. It also pins a BUFGMUX with an undriven `S`, which must select `I0`.

```
CHIPDB=/path/to/xc7a100tcsg324.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails. It writes its JSON, FASM and logs to `$OUT`. By default that is a fresh `mktemp -d` directory, which is kept (about 330 MB) and printed at the end.

| family | pin | `tie0` must emit | `tie0isinv`, `absentisinv` must equal |
|---|---|---|---|
| `pll_rst`, `pll_pwrdwn` | PLLE2_ADV RST, PWRDWN | `ZINV_<pin>` | `tie1` |
| `mmcm_rst`, `mmcm_pwrdwn` | MMCME2_ADV RST, PWRDWN | `ZINV_<pin>` | `tie1` |
| `bram_rstreg` | RAMB18E1 RSTREGARSTREG | no `ZINV_RSTREGARSTREG` | `tie1` |
| `bufgctrl_ce1` | BUFGCTRL CE1 | no `ZINV_CE1` | `tie1` |
| `bufgce_ce` | BUFGCE CE, renamed CE0 on the BUFGCTRL it becomes | `ZINV_CE0` only on the fabric BUFG | `tie1` (`tie0isinv` only) |
| `dsp_alumode0` | DSP48E1 ALUMODE[0] | no `ZIS_ALUMODE_INVERTED[0]` | `tie1` |
| `dsp_inmode1` | DSP48E1 INMODE[1], tied in the DSP tile | no `DSP_0_INMODE1.DSP_VCC_*` | `tie1` |
| `oddr_d1` | ODDR D1 | `IS_D1_INVERTED` | `tie1` (`tie0isinv` only) |

Two comparisons are used:

- **Whole FASM, byte for byte.** This is tried first.
- **Sorted whole FASM, line for line.** This is the fallback. It is only order-insensitive; every feature line, routing included, must match.

The ODDR designs pin their one fabric register with a `BEL` attribute, so that placement does not move between them.

`bufgce_i_isinv` sets `IS_I_INVERTED` on a BUFGCE. BUFGCTRL has no I0 or I1 inversion bit in the database, so the build must stop rather than drop the inversion.

`pllbase_pwrdwn_tie0` and `pllbase_pwrdwn_tie1` check that `PLLE2_BASE` still gets `ZINV_PWRDWN` only when PWRDWN is tied to 0.

`dsp_inmode1_tie0` and `dsp_inmode1_tie1` check the three bits of a pin the DSP tile ties itself: the tieoff of the pin's logical value, and `ZIS_INMODE_INVERTED[1]` set (site inverter off), as Vivado writes them.
