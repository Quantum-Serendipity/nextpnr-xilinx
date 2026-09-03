# CARRY4 output-mux conflict

Twelve cells — one `CARRY4`, eight `IBUF`, three `OBUF`, one `FDRE` — that
could not be placed at 0.01% device utilisation, plus four controls.

## What the cell does that no site can host

A 7-series SLICE lane has one output mux (`xOUTMUX`). `xilinx/arch_place.cc`
charges it to both of a lane's carry outputs:

* the sum `O[z]`, whenever it has fabric fanout;
* the carry-out `CO[z]` whenever it has to reach the fabric. `CO0..CO2` have no
  other exit; `CO3` also leaves on the dedicated `COUT -> CIN` spine, so only
  its non-`CIN` users count.

`O[z]` and `CO[z]` are pins of the same cell in the same lane. When both need
the mux there is no valid site anywhere on the die, and the HeAP legaliser does
not say so — it exhausts its per-cell attempt budget and reports utilisation:

```
ERROR: Unable to find legal placement for cell 'c4', check constraints and utilisation.
```

`NEXTPNR_DUMP_INVALID_TILE=1` shows the real reason: every one of ~16 700
candidate sites is refused by the same arm, the `CO`-vs-output-mux check.

## The fix this pins

Upstream openXC7's `relocate_carry_o_fabric()` — Hans Baier, `c2c05095a`,
2026-08-07, plus its seventeen-commit follow-up series — cherry-picked onto this
fork. It splits the `CARRY4` at the contended bit and duplicates that one sum
into an unconstrained 2-input XOR LUT (`S ^ CIN`) which takes over the `O` net's
fabric users. The original cell keeps its name, so `json_to_loc_tcl` can still
pin it; the chain gains cells rather than losing them.

`NEXTPNR_NO_CARRY_O_RELOC=1` turns the pass off, which is how the reproducer's
red state is recovered without rebuilding.

## The five arms

| file | lane-1 sum `O[1]` | lane-1 carry `CO[1]` | `BEL`-pinned | expected: sums / splits / chains / pinned chains / pinned cells / bits |
|---|---|---|---|---|
| `conflict.v` | to fabric | to fabric | no | 1 / 1 / 1 / 0 / 0 / `O1` |
| `ctl_co_unused.v` | to fabric | unused (`CO[3]` exports) | no | 1 / 1 / 1 / 0 / 0 / `O3` |
| `ctl_o_to_ff.v` | to an FF | to fabric | no | 1 / 1 / 1 / 0 / 0 / `O1` |
| `ctl_sum_only.v` | to fabric | never leaves the cell | no | 0 / 0 / 1 / 0 / 0 / — |
| `ctl_pinned.v` | to fabric | to fabric | yes | 0 / 0 / 1 / 1 / 0 / — |

`ctl_co_unused` and `ctl_o_to_ff` relocate under this implementation where the
fork's earlier per-chain fallback left them alone. That is upstream's predicate
being deliberately more conservative, not a defect: it counts *any* `O` user,
including a sum FF, because after a split the placer is not obliged to keep that
FF in the carry's own subslice. The two arms still separate on **which bit**
moves — `O3` for `ctl_co_unused`, `O1` for the others — which is why the bit list
is asserted and not just the totals.

`ctl_sum_only.v` is the only arm whose expectation is zero, so it is the only
arm an over-firing predicate must fail. It is a two-cell chain on purpose: a
one-cell version was immune, because its root has no `CIN` net and its unused
`CO` nets do not exist, so the pass declined for reasons that had nothing to do
with the predicate under test.

`ctl_pinned.v` is the DFX arm. A conflicting chain whose `CARRY4` carries a
`BEL` attribute must be left alone — that placement came from a tool with muxing
`arch_place.cc` does not model, and relocating it would move the pin the import
exists for. It runs `--no-route`: what it asserts is the packer's branch and
that the imported placement is accepted, not the routability of a half-stamped
netlist (only the `CARRY4` is pinned here, its feeders are not).

## What each arm actually catches

Recall, re-proved by mutation against this build. **`rc` alone catches none of
the last two** — both mutants place and route to `rc` 0:

| mutation | arms that turn red | quantity that caught it |
|---|---|---|
| `NEXTPNR_NO_CARRY_O_RELOC=1` (whole pass off) | all five | summary line absent |
| `if (false && …BEL…)` — both pinned guards removed | `ctl_pinned` only | sums 1≠0, splits 1≠0, pinned chains 0≠1, bits `O1`≠— |
| `co_has_fabric`: `if (bit == 0) return true` — minimal over-fire | `ctl_sum_only` only | sums 1≠0, bits `O0`≠— |

With the pass off, `conflict.v` alone is `rc` 255 with the original placer
error; the four controls are `rc` 0. That is what makes `conflict.v` a
reproducer rather than a fifth example.

**What these five arms do not cover.** The pass-through lanes a split creates
have don't-care `DI` inputs. Upstream ties them to `$PACKER_GND_NET`; this fork
leaves them unconnected, because `routeVcc()` here refuses to write undriven
constant inputs and could not bridge them in a dense slice. Twelve cells is not
dense, so every arm here is green either way — that defect is caught by
UberDDR3 x8/x16 and the `nexys_video` demo in `docs/carry4-atomic-packer-fix-scope.md`,
not by this fixture.

## Running it

```sh
CHIPDB=/path/to/xc7a35tcsg324.bin ./run.sh
```

`run.sh` exits non-zero if any arm fails, and fails an arm by name if the
summary line is missing at all, so "the pass found nothing to do" and "the pass
was removed" cannot be confused.
