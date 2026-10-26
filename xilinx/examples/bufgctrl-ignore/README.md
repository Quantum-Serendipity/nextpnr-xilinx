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
| `bufgmux_sel` site bits | `ZINV_CE1 ZINV_S0 ZINV_S1`: a BUFGMUX switches on the clock enables, `CE1 = S` and `CE0 = S` through the inverter, with both selects high |
| `bufgmux_async` | both `IGNORE` bits, with the same enables and selects: `CLK_SEL_TYPE = "ASYNC"` ties both `IGNORE` pins high |
| `bufgmux_1` | neither `IGNORE` bit, `INIT_OUT`, and the BUFGMUX enables and selects: a BUFGMUX_1 idles high |
| `bufgmux_ctrl` | `ZINV_CE0 ZINV_CE1 ZINV_S1`: a BUFGMUX_CTRL switches on the selects, `S1 = S` and `S0 = S` through the inverter, with both enables high |
| `bufgmux_ctrl_async` | refused: `CLK_SEL_TYPE` added to the `bufgmux_ctrl` netlist with `$PYTHON` (yosys gives a BUFGMUX_CTRL no such parameter, and UG953 lists none), naming it a BUFGMUX and BUFGMUX_1 parameter |
| `bufgmux_nos`, `bufgmux_ctrl_nos` | refused, naming the cell: the mux has no `S` connection at all |
| `bufgmux_undrv`, `bufgmux_selx` | built, with a warning naming the cell and its `S`: yosys turns both the undriven wire and `1'bx` into an `x` bit, which the JSON frontend reads as the undriven net `g.S$const`, so the select never switches |
| `bufgmux_clksel_bogus` | refused, naming `CLK_SEL_TYPE` and its two legal values |
| `bufgctrl_clksel` | refused: `CLK_SEL_TYPE` added to the `bufgctrl_tie0` netlist the same way, and a BUFGCTRL has no such parameter |
| `bufgctrl_tie0` | neither bit: `IGNORE0`/`IGNORE1` tied to 0 |
| `bufgctrl_tie1` | both bits: tied to 1 |
| `bufgctrl_tie1inv` | neither bit: tied to 1 with `IS_IGNORE*_INVERTED = 1` |
| `bufgctrl_sig` | both bits: a live signal, not inverted |
| `bufgctrl_siginv` | neither bit: a live signal with `IS_IGNORE*_INVERTED = 1` |

Every arm also requires exactly one `BUFGCTRL` `IN_USE` line.
