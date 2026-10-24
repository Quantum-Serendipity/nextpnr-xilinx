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
(clk_b); `src_fast` feeds `dst_slow`, `dst_fast`, `dst_ce` (whose clock enable is timed as well as
its D input) and, through the net `mid`, `dst_mid`.

| file | expectation |
|---|---|
| `groups`, `groups_single`, `fp_clocks` | no `dst_b` row; every other row unchanged |
| `fp_clocks_reversed`, `fp_nomatch` | every row unchanged |
| `fp_pins_bogus`, `fp_pins_q`, `fp_clock_typo`, `groups_typo`, `fp_from_comb` | refused with a warning; every row unchanged |
| `fp_pins_ce` | no `dst_ce` CE row; its D rows and every other row unchanged |
| `fp_from_to` | `dst_slow` keeps every endpoint, no slack worse, some better; the rest unchanged |
| `fp_from` | no `dst_b` row; `dst_slow` as in `fp_from_to` |
| `fp_to`, `precedence` | no `dst_slow` row; the rest unchanged |
| `fp_setup_only` | no `dst_slow` row; the summary line counts setup exclusions and no hold exclusion |
| `fp_pins` | no `dst_fast` row; the rest unchanged |
| `fp_through` | no `dst_mid` row; the rest unchanged |
| `maxdelay_cdc` | every `dst_b` row graded against 30 ns with positive slack |
| `maxdelay_tight` | every `dst_slow` endpoint has a 0.5 ns row, and the worst slack is worse |

Every setup-export row names what set its requirement in `requirement_source` (`same`, `same-half`,
`related`, `unrelated-min`, `capture-only`, `default`, `max_delay#<n>` (with `-datapath_only` appended when
that flag is set) or `multicycle#<n>+<base>`,
where `<n>` is the exception number the reader logs). The `requirement_source` arm passes when the
`dst_b` crossing rows read `unrelated-min` in the base replay and `max_delay#<n>` under
`maxdelay_cdc`, with `<n>` taken from that replay's log, and the `dst_slow` same-clock rows read
`same`.

Under `--xdc-strict` each of `fp_nomatch`, `fp_pins_bogus`, `fp_pins_q`, `fp_clock_typo`,
`groups_typo`, `fp_from_comb` and `maxdelay_dp_nofrom` must be refused, for its own reason.

`set_max_delay -datapath_only` removes clock skew as well as hold: the `datapath_only` arm replays
`maxdelay_cdc` and `maxdelay_cdc_skew` (the same constraint without `-datapath_only`) and passes
when every `dst_b` crossing row under the first reads `30 - (driver_arrival_ns + net_delay_ns +
setup_ns)` with both clock-delay columns 0 and `requirement_source` `max_delay#<n>-datapath_only`,
and its slack differs from the same row under the second by exactly that row's
`launch_clk_delay_ns - capture_clk_delay_ns`. A full place and route with
`groups` and `fp_from_to` applied must finish with no `dst_b` row in its export (`pnr_groups`), and
its `NEXTPNR_CRIT_EXPORT` must give no `src_slow` register a criticality, where the base place and
route gives all of them one (`pnr_crit`). Every `src_slow` path is excepted there, so `pnr_crit` is
the arm that sees the placer and router criticality pass; `pnr_groups` grades only the final
analysis.

`dram.v` holds a `RAM64X1D` and a `RAM32M`, both named `mem*`, written and read by registers on one
clock. It is placed and routed three times with `dram.xdc`: with no exception, where some
distributed-RAM write pin is graded (`dram_base`); with `xdc/dram_fp_to.xdc` under `--xdc-strict`,
where none is (`dram_fp`); and with `xdc/dram_maxdelay.xdc`, where every one of them is graded
against 30 ns (`dram_maxdelay`). The routed JSON of `dram_fp` is then replayed with the same XDC
under `--xdc-strict`, which must accept it and grade no distributed-RAM row (`dram_fp_replay`).

`NEXTPNR_ASYNC_GROUPS`, the environment file that once excluded crossings from the setup report
only, is refused: the `async_groups_env` arm passes when a replay with it set stops with an error
naming `set_clock_groups`.

## What the reader accepts

- `set_false_path [-setup|-hold] [-from <objs>] [-to <objs>]`
- `set_false_path -through [get_nets ...]`, alone: the nets carry no timing at all
- `set_max_delay <ns> [-datapath_only] [-from <objs>] [-to <objs>]`; `-datapath_only` needs `-from`
- `set_clock_groups [-asynchronous|-physically_exclusive|-logically_exclusive]
  [-include_generated_clocks] -group <clocks> ...`

`<objs>` is `get_cells`, `get_pins`, `get_ports` (the pad and its buffer cells) or `get_clocks`,
optionally inside `list`/`concat`. `get_cells` on a register names every timed input of it.
`get_pins` is read only on flip-flop pins and keeps the pin: under `-to` it must be D, CE or
R/S/CLR/PRE and only that pin's check is excepted; under `-from` it must be C or Q. Any other pin of
a flip-flop, or a pin of any other cell, refuses the constraint. A pin the cell does not have is not
matched, so an unconnected pin, which the netlist does not carry, matches nothing. `get_cells` and `get_pins`
take `-hier` and `-filter {NAME =~ <glob>}`. A yosys register keeps a generated name, so a cell
whose name starts with `$` is also matched by the name of its Q net. A Vivado `_reg` suffix is not
synthesised.

A clock is matched by the name of the clock net at the register, by the name of every net reached
backwards through clock buffers, and by a `create_clock -name`. The walk stops at a PLL or MMCM and
at a dividing BUFR, which is where Vivado starts a generated clock; `-include_generated_clocks`
continues through them.

A clock pattern must match a clock that exists when the line is read: a `create_clock -name`, a net
with a `create_clock`, or a net driven by a buffer, PLL or MMCM. Combinational cells (LUTs, carry,
wide muxes, constant drivers) are dropped from a `-from` or `-to` cell list, since no check starts
or ends at them; a LUT used as distributed RAM is not combinational, and an exception on a RAM
macro applies to every LUT the packer splits it into. An exception or clock group in which any of these matches nothing is dropped with a
warning, and refused under `--xdc-strict`. A false path wins over a max delay, and a max delay over
a multicycle path.

A max-delay path enters the Fmax figures, in the text report and in `--report`, as a multicycle
factor of its requirement over the clock period, which may be below one: it reports the clock
frequency at which that path would just meet its requirement if the requirement scaled with the
clock.
