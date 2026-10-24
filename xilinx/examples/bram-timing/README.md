# Block RAM clock-to-out

Places and routes `top.v` on an `xc7a100tfgg484`: a 64Kx1 RAMB36E1 cascade pair (`ram_lower`
with `RAM_EXTENSION_A="LOWER"` driving `ram_upper`'s `CASCADEINA`) and an unextended RAMB36E1
(`ram_ref`), both unregistered on port A, each read into one flip-flop (`q_cas`, `q_ref`) on the
same clock. The `NEXTPNR_SETUP_EXPORT` rows of the two flip-flops' D pins are compared.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| cascade clock-to-out | `q_cas`'s driver arrival exceeds `q_ref`'s by 0.75 +- 0.10 ns, the DS181 v1.25 Table 30 -2 difference between TRCKO_DO_CASCOUT (2.88 ns) and TRCKO_DO (2.13 ns) |
| grade log | the nextpnr log names the data-sheet table and speed grade the block RAM literals come from |
