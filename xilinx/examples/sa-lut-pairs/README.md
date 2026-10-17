# LUT pairs under the simulated-annealing placer

`top.v` registers 32 six-input and 32 five-input functions of one 8-bit LFSR, so many 5-input LUTs
share inputs with 6-input ones. `run.sh` places it on an `xc7a100tfgg484` with `--placer sa` and with
the default `heap`, three seeds each, `--no-route`, and grades every slice slot in the written JSON
with `grade.py`.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

A slot whose 6LUT and 5LUT bels are both occupied is illegal when the 6LUT cell uses six input nets,
or when the two cells use more than five distinct input nets between them: a 5LUT shares the 6LUT's
A1..A5 and has no A6. Each arm passes when no slot is illegal.
