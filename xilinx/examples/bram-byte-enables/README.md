# Block RAM byte enables on the site pins

Places and routes `top.v` on an `xc7a100tfgg484`: one RAMB18E1 in true dual port at x18 on both
ports, each port's two byte enables driven by different nets (`we_a0`, `we_a1`, `we_b0`, `we_b1`).
A RAMB18E1 site takes each byte enable on two pins.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `WEA` | site pins `WEA0`-`WEA3` of the placed cell carry two distinct nets, one on pins 0 and 1 and the other on pins 2 and 3 |
| `WEBWE` | the same for `WEBWE0`-`WEBWE3`, the pairing Vivado uses; one-to-one mapping gives the two nets alternating |
