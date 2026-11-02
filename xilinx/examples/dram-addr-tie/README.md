# Tied-low RAM32M/RAM64M address bits rewritten to tied-high

Packs `top.v` on an `xc7a100tfgg484` with `--pack-only` with `knob/dram_tie_unread_di` unset, `off` and
`on`, and grades each packed netlist against the synthesised one. `check.py edit` first
widens `r_wide`'s `INIT_A` to 65 bits and makes `r64s`'s a string, the two shapes the packer must
skip. Every cell has a distinct non-zero `INIT_A` to `INIT_D`:

| cell | ties | what the packer must do |
|---|---|---|
| `r_both` | address bits 4 and 3 tied to 0 on all four ports | rewrite 4 and 3 |
| `r_mixed` | bit 3 tied to 0 on all four ports; bit 4 tied to 0 on B, C and D, driven on A | rewrite 3 |
| `r_vcc` | bit 4 tied to 0 on all four ports; bit 3 tied to 0 on A, C and D, to 1 on B | rewrite 4 |
| `r64` | bit 5 tied to 0 on all four ports | rewrite 5 |
| `r_dfree` | bit 4 tied to 0 on A, B and C, driven on D (the write address) | nothing |
| `r_free` | every address bit driven | nothing |
| `r_wide` | bits 4 and 3 tied to 0 on all four ports, `INIT_A` 65 bits wide | skip the cell |
| `r64s` | bit 5 tied to 0 on all four ports, `INIT_A` a string | skip the cell |
| `r_unread` | `DIA` and `DIB` tied to 0, `DOA` read by nothing | knob on: `DIA` to VCC; `DIB` stays on GND |
| `r_dunread` | `DIC` and `DID` tied to 0, `DOD` read by nothing | knob on: `DID` to VCC; `DIC` stays on GND |
| `r64u` | `DIA` and `DIB` tied to 0, `DOA` read by nothing | knob on: `DIA` to VCC; `DIB` stays on GND |

`stripped.v` is a RAM32M with `INIT_A` all ones, `DIA` tied to 0 and `DOA` on a top output,
synthesised with `-noiopad -noclkbuf`; `check.py strip` then empties the module's ports, which is what
a port-stripped region netlist looks like. `DOA` is read in the design but has no reader in that
netlist, so with the knob on the netlist is refused.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`NPNR_TIMEOUT` bounds each nextpnr run in seconds. `run.sh` exits non-zero if any arm fails and
leaves its outputs in `$OUT` (a fresh `mktemp -d` by default).

| arm | passes when |
|---|---|
| contents | knob unset: for every packed subcell of a cell with a binary `INIT`, every logical address its port can present reads the synthesised `INIT` bit through its `A` pins and packed `INIT`, the same address on `ADDRD` lands on the same physical word through its `WA` pins, and no two `ADDRD` addresses land on one word |
| count | knob unset: the transform line names the expected bit and cell counts, and the packed `A`/`WA` pins show exactly the bits in the table above moved from GND to VCC |
| skip-init | knob unset: `r_wide` and `r64s` keep their tied-low address bits on GND |
| unread-data-off | knob unset: no data-input tie line, and every tied-low data input is still on GND |
| knob-off-explicit | `--set knob/dram_tie_unread_di=off`: no data-input tie line, and the packed netlist equals the unset run's once the one echoed setting is set aside |
| contents-knob-on, count-knob-on | as contents and count, over the knob-on run |
| unread-data-on | knob on: the tie line counts five, and exactly the data inputs the table moves are on VCC |
| stripped-knob-off | knob unset: `stripped.v` packs at rc 0 and its port A `DI1`/`DI2` stay on GND |
| stripped-knob-on-refused | knob on: the `stripped.v` netlist is refused, and packing stops with `knob/dram_tie_unread_di=on is refused: the netlist has no top-level ports` |
| roi-knob-on-refused | knob on with the rectangle given through the environment alias `NEXTPNR_PARTITION_ROI`: the netlist is refused, and packing stops with `knob/dram_tie_unread_di=on is refused: NEXTPNR_PARTITION_ROI is set` |
| roi-set-knob-on-refused | knob on with the rectangle given as `--set knob/partition_roi`: the netlist is refused, and packing stops with `knob/dram_tie_unread_di=on is refused: knob/partition_roi is set` |
| roi-knob-unset-packs | with the rectangle given through `NEXTPNR_PARTITION_ROI`, the knob unset and `=off` each pack at rc 0, the log names the ROI as read from that environment alias and shows it active, and there is no tie line, so the ROI refusal turns on the knob and not on the ROI alone |
| roi-set-knob-unset-packs | as roi-knob-unset-packs, with the rectangle given as `--set knob/partition_roi` and the log naming it as from `--set` |
| roi-file-refused | a rectangle file that does not exist, given through `NEXTPNR_PARTITION_ROI`, stops the run with `NEXTPNR_PARTITION_ROI: cannot open` |
| roi-set-file-refused | the same file given as `--set knob/partition_roi` stops the run with `knob/partition_roi: cannot open` |
| roi-key-refused | a rectangle file with a top-level key `bogus`, given through `NEXTPNR_PARTITION_ROI`, stops the run with `NEXTPNR_PARTITION_ROI: '<file>' carries key "bogus"` |
| roi-set-key-refused | the same file given as `--set knob/partition_roi` stops the run with `knob/partition_roi: '<file>' carries key "bogus"` |
| roi-grid-refused | a rectangle with `GRID_X_MAX` 9999, given through `NEXTPNR_PARTITION_ROI`, stops the run with `NEXTPNR_PARTITION_ROI: '<file>' rectangle grid (10,105)-(9999,155) does not fit the device grid` |
| roi-set-grid-refused | the same file given as `--set knob/partition_roi` stops the run with the same refusal naming `knob/partition_roi` |

Every run that passes the rectangle as `--set knob/partition_roi` runs with `NEXTPNR_PARTITION_ROI` removed from its
environment, so it reads the rectangle through the knob or not at all.
| mutant-no-permute | the contents check reds when `r_both`'s packed `INIT` is replaced by the unpermuted lanes |
| mutant-driven-bit | the contents check reds when `r_mixed`'s bit 4, which port A drives, is moved to VCC with its `INIT` permuted |
| mutant-skip-port-d | the contents check reds when `r_dfree`'s bit 4, which only `ADDRD` drives, is moved to VCC with its `INIT` permuted, as a packer that tested ports A to C alone would |
| knob-value-refused | each of `maybe`, `0`, `1`, `ON`, `Off` and `on1` stops the run with `is neither on nor off`; the value is matched as lowercase `on` or `off` and nothing else |
| knob-value-refused-no-pack | the same value stops a `--no-pack --no-place --no-route` run over the packed netlist |
