# OSERDESE2 tristate output to a pad

Places and routes an `OSERDESE2` whose `TQ` drives the `T` of an `IOBUF`, on an `xc7a100tcsg324`,
and checks the `ZINV_Tn` bits of its OLOGIC site. `sing.xdc` puts the pad in a top `RIOI3_SING`
tile (`OLOGIC_Y0`), `pair.xdc` in an ordinary `RIOI3` tile (`OLOGIC_Y1`).

```
CHIPDB=/path/to/xc7a100tcsg324.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

Every arm also requires exactly one `IOI_Tn.IOI_OLOGICn_TQ` pip, so `TQ` reaches the pad.

| arm | passes when |
|---|---|
| `t1_tie0` (both placements, and `--router router1`) | no `ZINV_Tn`: `T1` tied low arrives as VCC with `IS_T1_INVERTED`, so the site inverter stays on and the pad drives |
| `t1_tie1_isinv` | no `ZINV_Tn`: the same tie written as `T1 = 1` with `IS_T1_INVERTED = 1` |
| `t1_tie1` | `ZINV_T1`: `T1` tied high tristates the pad |
| `t1_signal` (both placements) | `ZINV_T1`: a live `T1` with no inversion |
