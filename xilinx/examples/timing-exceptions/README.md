# Timing exceptions

Regression for `set_false_path`, `set_max_delay` and `set_clock_groups` in the XDC reader and the
timing analyser. It places and routes one small two-clock design on an `xc7a100tfgg484`, then
re-analyses the routed JSON once per file in `xdc/` the way a timing-only replay does
(`NEXTPNR_TIMING_ONLY=1 --no-pack --no-place --no-route`, with `replay.xdc` constraining both
BUFG outputs to 2 ns because a replay does not propagate clock constraints) and grades the
`NEXTPNR_SETUP_EXPORT` rows against the replay with no exception.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default).

The design has two clocks: `clk_a`, a BUFG of the `clk_i` pad, constrained with
`create_clock -name sysclk`, and `clk_b`, a PLL output through a second BUFG. Register groups are
named by their Q nets: `src_slow` feeds a three-adder chain into `dst_slow` (clk_a) and `dst_b`
(clk_b); `src_fast` feeds `dst_slow`, `dst_fast` and, through the net `mid`, `dst_mid`.

| file | expectation |
|---|---|
| `groups`, `groups_single`, `fp_clocks` | no `dst_b` row; every other row unchanged |
| `fp_clocks_reversed`, `fp_nomatch` | every row unchanged |
| `fp_from_to` | `dst_slow` keeps every endpoint, no slack worse, some better; the rest unchanged |
| `fp_from` | no `dst_b` row; `dst_slow` as in `fp_from_to` |
| `fp_to`, `precedence` | no `dst_slow` row; the rest unchanged |
| `fp_setup_only` | no `dst_slow` row; the summary line counts setup exclusions and no hold exclusion |
| `fp_pins` | no `dst_fast` row; the rest unchanged |
| `fp_through` | no `dst_mid` row; the rest unchanged |
| `maxdelay_cdc` | every `dst_b` row graded against 30 ns with positive slack |
| `maxdelay_tight` | every `dst_slow` endpoint has a 0.5 ns row, and the worst slack is worse |

Two further arms: `fp_nomatch` under `--xdc-strict` must be refused, and a full place and route
with `groups` and `fp_from_to` applied must finish with no `dst_b` row in its export.

## What the reader accepts

- `set_false_path [-setup|-hold] [-from <objs>] [-to <objs>]`
- `set_false_path -through [get_nets ...]`, alone: the nets carry no timing at all
- `set_max_delay <ns> [-datapath_only] [-from <objs>] [-to <objs>]`
- `set_clock_groups [-asynchronous|-physically_exclusive|-logically_exclusive]
  [-include_generated_clocks] -group <clocks> ...`

`<objs>` is `get_cells`, `get_pins` (the pin is dropped, the cell is kept), `get_ports` (the pad and
its buffer cells) or `get_clocks`, optionally inside `list`/`concat`. `get_cells` and `get_pins`
take `-hier` and `-filter {NAME =~ <glob>}`. A yosys register keeps a generated name, so a cell
whose name starts with `$` is also matched by the name of its Q net. A Vivado `_reg` suffix is not
synthesised.

A clock is matched by the name of the clock net at the register, by the name of every net reached
backwards through clock buffers, and by a `create_clock -name`. The walk stops at a PLL or MMCM and
at a dividing BUFR, which is where Vivado starts a generated clock; `-include_generated_clocks`
continues through them.

An exception whose `-from` or `-to` matches nothing is dropped with a warning, and refused under
`--xdc-strict`. A false path wins over a max delay, and a max delay over a multicycle path.
