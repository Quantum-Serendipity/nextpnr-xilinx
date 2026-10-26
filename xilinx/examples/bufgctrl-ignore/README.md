# BUFGCTRL IGNORE polarity

Places and routes one clock buffer per arm on an `xc7a100tcsg324` and checks the
`BUFGCTRL_X0Yn.IS_IGNORE0_INVERTED` and `IS_IGNORE1_INVERTED` bits. Despite their prjxray names
these bits behave like the `ZINV_*` bits of the same site: set, the pin's value passes; clear, the
site inverter is on. prjcombine lists `IGNORE0` and `IGNORE1` with the same inverted-sense
polarity bit (`@!MAIN`) as `S0`, `S1`, `CE0` and `CE1`, at the coordinates prjxray gives.

```
CHIPDB=/path/to/xc7a100tcsg324.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `bufg`, `bufgce` | only `IS_IGNORE1_INVERTED`: `IGNORE0` low, `IGNORE1` high |
| `bufgmux_sel` | neither bit, and no `GFAN.GND_WIRE` pip: both `IGNORE` pins tied low as VCC through the site inverter |
| `bufgctrl_tie0` | neither bit: `IGNORE0`/`IGNORE1` tied to 0 |
| `bufgctrl_tie1` | both bits: tied to 1 |
| `bufgctrl_tie1inv` | neither bit: tied to 1 with `IS_IGNORE*_INVERTED = 1` |
| `bufgctrl_sig` | both bits: a live signal, not inverted |
| `bufgctrl_siginv` | neither bit: a live signal with `IS_IGNORE*_INVERTED = 1` |

Every arm also requires exactly one `BUFGCTRL` `IN_USE` line.
