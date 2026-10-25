# Generated clocks and IO delays

Places and routes `top.v` on an `xc7a100tfgg484`. `clk_i` is constrained at 100 MHz and buffered
onto `clk` by the BUFG `gsys`. A register `div` toggles on `clk`; its BUFG output `dclk` clocks a
second register stage fed from the `clk` domain. `div` also leaves the chip as `sd_clk`, and the
design has an input and an output timed against it, in the shape of an SPI interface whose clock is
forwarded from the fabric.

`gen.xdc` declares two generated clocks, each half of `gsys/O`: `div2` on the net `div` and `sck`
on the port `sd_clk`. `io.xdc` puts input delays on `din_a` (max 2.5, min 2 ns), `din_b` (max 10.5,
min -3 ns) and `sd_do` (max 3, min 0 ns after the falling edge of `sck`), and output delays on
`dout` (max 9, min -5 ns) and `sd_di` (max 6, min -2 ns against the rising edge of `sck`).

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

`run.sh` exits non-zero if any arm fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by
default). Every arm reads the `NEXTPNR_SETUP_EXPORT` table, the `NEXTPNR_HOLD_EXPORT` table or the
log.

| arm | passes when |
|---|---|
| `dclk -> dclk` | every row inside the divided domain has `period_ns` 20 |
| `clk -> dclk` | every row from the source domain into the divided one has `period_ns` 10 |
| divided-clock crossing verdict | the `clk -> dclk` max-delay line grades against a 10.00 ns edge separation related through `clk_i` |
| source latency | every `clk -> dclk` setup row has a capture clock delay more than 0.3 ns above its launch clock delay: the divided clock arrives through the divider's clock pin, its clock-to-out and the routing after it |
| hold source latency | every `clk -> dclk` hold row charges that later capture, and its slack is `driver_min_arrival + net_delay_min - hold - hold_req - capture + cppr` |
| hold pessimism inside the divided domain | every `dclk -> dclk` hold row removes more than 0.1 ns of shared source latency and passes |
| input max delay fails setup / control | `din_b` (10.5 ns) has negative setup slack, `din_a` (2.5 ns) positive, both graded `clk_i -> clk` against 10 ns |
| output max delay fails setup | the `dout` buffer input has a 9 ns setup term and negative slack |
| input delay on a falling generated clock | the `sd_do` row is graded `sd_clk -> clk` against 10 ns and starts at 3 ns after `sck`'s source latency |
| output max delay to a generated clock at a port | the `sd_di` row has a 6 ns setup term and a capture clock delay equal to `sck`'s source latency |
| input min delay control / fails hold | the `din_a` hold row starts at 2 ns and passes; the `din_b` hold row starts at -3 ns and fails |
| output min delay fails hold | the `dout` hold row has a 5 ns hold term (the negated -5 ns minimum) and fails |
| output min delay to a generated clock at a port | the `sd_di` hold row has a 2 ns hold term and charges `sck`'s source latency at capture |
| input delay verdict | the `clk_i (input delay) -> clk` max-delay line is a FAIL against the 10.00 ns separation |
| path report | the critical path report for `din_b` opens with its 10.5 ns input delay |
| insertion warning | an input delay against a primary clock is warned as omitting that clock's insertion delay |
| edges | `gen_edges.xdc`, which writes `div2` as `-edges {2 4 6}`, moves every `clk -> dclk` row to 5 ns |
| edges duty | `gen_duty.xdc`, `-edges {1 2 5}` on a half-high source, derives a 20 ns clock high for a quarter of its period |
| replay | under `--no-pack` on the routed netlist, with `clk` constrained directly, the input delays are timed and `sck` is related to `clk` |
| false path | `set_false_path -from [get_ports din_b]` and `-to [get_ports dout]` remove those setup and hold checks and leave `din_a` |
| strict | each file in `xdc/` is refused under `--xdc-strict` with the reason the arm names |
| lenient | without `--xdc-strict` the refused `set_input_delay` is a warning and is counted |
| same-clock input delay | with `clk` constrained directly, a 10.5 ns input delay relative to `clk` is its own `clk (input delay) -> clk` FAIL line and leaves the `clk` Fmax line at PASS |
| no endpoint | an input delay on `clk_i`, whose buffer feeds only the BUFG, is warned as timing nothing, and `din_a` beside it is timed |
| add_delay | `-add_delay` on the same clock edge keeps the larger max and the smaller min |

What these commands do and do not model:

- A generated clock's waveform follows UG903: `-edges {a b c}` names source edges, odd edges rising
  and even edges falling at the source's own duty cycle; `-divide_by N` is `-edges {1 N+1 2N+1}`;
  `-multiply_by M` keeps the source's duty cycle. `-divide_by` and `-multiply_by` together,
  `-invert`, `-duty_cycle`, `-edge_shift`, `-combinational`, `-master_clock` and `-add` are refused.
- A generated clock's source latency is traced through the netlist from the `-source` net to the
  target: the clock route to the first pin on the source net, then clock-to-out and combinational
  arcs and the routes between them. A cell on that path with no timing arc, such as an output
  buffer driving a forwarded clock's pad, is taken as zero and named in the log. Clocks without a
  generated clock above them keep the model they had: the route from their net's driver.
- Clock pessimism removal for hold follows the shared part of the two clock paths through any
  generated clocks: the route both share on their common net plus the whole source latency above it.
- An input delay starts at the latency of its clock at the clock's definition point, and an output
  delay is captured there. For a primary clock that latency is zero, while the register on the
  other end sees only the route from its clock net's driver, so the pad, input buffer and clock
  buffer insertion above that net is in neither: the hold check of an input delay and the setup check
  of an output delay against a primary clock are optimistic by it, and the log says so.
- The IO buffers have no timing arcs in this arch, so an input delay is the arrival time at the
  input buffer's output and an output delay is the setup term at the output buffer's input.
- An input whose buffer feeds only IO logic (ILOGIC, IDDR, IDELAY) reaches no timed endpoint, and is
  warned as timing nothing.
- A path that starts at an input delay or ends at an output delay is reported as its own `Max delay`
  line, marked `(input delay)` or `(output delay)`, even when both ends are the same clock, and is
  not part of that clock's Fmax figure.
- An IO delay names a clock that exists when its line is read: a `create_clock`, a
  `create_generated_clock`, or a net driven by a clock buffer (`BUFG*`, `BUFH*`, `BUFR`, `BUFIO`,
  `BUFMR*`), PLL or MMCM. Once clock constraints have propagated, a delay whose clock net carries no
  constraint is refused.
- `-rise`, `-fall`, `-reference_pin` and the latency-included options of the IO delay commands are
  refused, and so is a `-min` delay with no `-max` for the same port and clock edge. Without
  `-add_delay`, a new line replaces the earlier `-max` or `-min` values it sets on that port.
