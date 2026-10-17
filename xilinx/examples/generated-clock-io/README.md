# Generated clocks and IO delays

Places and routes `top.v` on an `xc7a100tfgg484`. `clk_i` is constrained at 100 MHz and buffered
onto `clk` by the BUFG `gsys`. A register `div` toggles on `clk`; its BUFG output `dclk` clocks a
second register stage fed from the `clk` domain. `div` also leaves the chip as `sd_clk`, and the
design has an input and an output timed against it, in the shape of an SPI interface whose clock is
forwarded from the fabric.

`gen.xdc` declares two generated clocks, each half of `gsys/O`: `div2` on the net `div` and `sck`
on the port `sd_clk`. `io.xdc` puts input delays on `din_a` (1 ns), `din_b` (9.5 ns) and `sd_do`
(3 ns after the falling edge of `sck`), and output delays on `dout` (4 ns) and `sd_di` (6 ns before
the rising edge of `sck`).

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default). Every arm reads either the `NEXTPNR_SETUP_EXPORT` table or the log.

| arm | passes when |
|---|---|
| `dclk -> dclk` | every row inside the divided domain has `period_ns` 20 |
| `clk -> dclk` | every row from the source domain into the divided one has `period_ns` 10 |
| divided-clock crossing verdict | the `clk -> dclk` max-delay line grades against a 10.00 ns edge separation related through `clk_i` |
| input delay fails | the `din_b` row starts at 9.5 ns, is graded `clk_i -> clk` against 10 ns, and has negative slack |
| input delay control | the `din_a` row starts at 1 ns and has positive slack |
| output delay | the `dout` buffer input has a row graded `clk -> clk_i` against 10 ns with a 4 ns setup term |
| input delay on a falling generated clock | the `sd_do` row is graded `sd_clk -> clk` against 10 ns, the gap from a falling `sck` edge to the next `clk` edge |
| output delay to a generated clock at a port | the `sd_di` buffer input is graded `clk -> sd_clk` against 10 ns with a 6 ns setup term |
| input delay verdict | the `clk_i (input delay) -> clk` max-delay line is a FAIL against the 10.00 ns separation |
| path report | the critical path report for `din_b` opens with its 9.5 ns input delay |
| edges | `gen_edges.xdc`, which writes `div2` as `-edges {2 4 6}`, moves every `clk -> dclk` row to 5 ns |
| replay | under `--no-pack` on the routed netlist, with `clk` constrained directly, the input delays are timed and `sck` is related to `clk` |
| false path | `set_false_path -from [get_ports din_b]` and `-to [get_ports dout]` remove those two checks and leave `din_a` |
| strict | each file in `xdc/` is refused under `--xdc-strict` with the reason the arm names, including a `-clock` naming a data pad and one naming a buffered net no clock constraint reaches |
| lenient | without `--xdc-strict` the refused `set_input_delay` is a warning and is counted |
| same-clock input delay | with `clk` constrained directly, a 9.5 ns input delay relative to `clk` is its own `clk (input delay) -> clk` FAIL line and leaves the `clk` Fmax line at PASS |
| no endpoint | an input delay on `clk_i`, whose buffer feeds only the BUFG, is warned as timing nothing, and `din_a` beside it is timed |
| add_delay | `-add_delay` on the same clock edge keeps the larger max and the smaller min |

What these commands do and do not model:

- Clocks are ideal. A generated clock at an output port is graded as if it left the pad at its
  source edge, with no clock-to-out, routing or buffer delay on the forwarded clock.
- The IO buffers have no timing arcs in this arch, so an input delay is the arrival time at the
  input buffer's output and an output delay is the setup term at the output buffer's input.
- An input whose buffer feeds only IO logic (ILOGIC, IDDR, IDELAY) reaches no timed endpoint, and is
  warned as timing nothing.
- A path that starts at an input delay or ends at an output delay is reported as its own `Max delay`
  line, marked `(input delay)` or `(output delay)`, even when both ends are the same clock, and is
  not part of that clock's Fmax figure.
- A generated clock's waveform is always half high: `-edges` must describe a half-period duty
  cycle, and `-invert`, `-duty_cycle`, `-edge_shift`, `-combinational`, `-master_clock` and `-add`
  are refused.
- An IO delay names a clock that exists when its line is read: a `create_clock`, a
  `create_generated_clock`, or a net driven by a clock buffer (`BUFG*`, `BUFH*`, `BUFR`, `BUFIO`,
  `BUFMR*`), PLL or MMCM. Once clock constraints have propagated, a delay whose clock net carries no
  constraint is refused.
- `-rise`, `-fall`, `-reference_pin` and the latency-included options of the IO delay commands are
  refused, and so is a `-min` delay with no `-max` for the same port and clock edge.
