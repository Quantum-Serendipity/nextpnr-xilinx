# Tied-low RAM32M/RAM64M address bits rewritten to tied-high

Packs `top.v` on an `xc7a100tfgg484` with `--pack-only` and grades the packed netlist against the
synthesised one. `top.v` holds five RAM32M and one RAM64M, each with a distinct non-zero `INIT_A`
to `INIT_D`:

| cell | address ties | bits the packer must rewrite |
|---|---|---|
| `r_both` | bits 4 and 3 tied to 0 on all four ports | 4, 3 |
| `r_mixed` | bit 3 tied to 0 on all four ports; bit 4 tied to 0 on B, C and D, driven on A | 3 |
| `r_vcc` | bit 4 tied to 0 on all four ports; bit 3 tied to 0 on A, C and D, to 1 on B | 4 |
| `r64` | bit 5 tied to 0 on all four ports | 5 |
| `r_free` | every address bit driven | none |
| `r_unread` | every address bit driven; `DIA` and `DIB` tied to 0, `DOA` read by nothing | none; `DIA` moves to VCC, `DIB` stays on GND |

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`NPNR_TIMEOUT` bounds the nextpnr run in seconds. `run.sh` exits non-zero if any arm fails and
leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| contents | for every packed RAMD32/RAMD64E subcell, every logical address its port can present reads the synthesised `INIT` bit through the subcell's `A` pins and packed `INIT`, and the same logical address on `ADDRD` lands on the same physical address through its `WA` pins |
| count | the pack log's transform line names the expected bit and cell counts, and the packed `A`/`WA` pins show exactly the bits in the table above moved from GND to VCC |
| unread-data | the pack log's data-input line counts the two `DIA` bits, and the packed `r_unread` port A subcells' `DI1`/`DI2` are on VCC while port B's stay on GND |
| mutant-no-permute | the contents check reds when `r_both`'s packed `INIT` is replaced by the unpermuted lanes |
| mutant-driven-bit | the contents check reds when `r_mixed`'s bit 4, which port A drives, is moved to VCC with its `INIT` permuted |
