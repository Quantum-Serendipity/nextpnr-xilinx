# Partition safety

Places `top.v` once on an `xc7a100tfgg484`, with its inputs on the left edge and its outputs on the
right, routes it, and then runs each arm below against that placement. Every arm is a way a
partition rectangle used to be escaped, or a partition output used to be lost, at rc 0.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

The rectangles are chosen from the base route, so `run.sh` reads prjxray-db's
`artix7/xc7a100t/tilegrid.json` to turn tile names into grid coordinates. `PRJXRAY_DB` names the
database root; the default is this fork's `xilinx/external/prjxray-db` submodule. `geom.py` does the
lookups. The pre-place arms need a nextpnr built with Python. `NPNR_TIMEOUT` bounds each nextpnr run in seconds (default 600). `run.sh` exits non-zero if any arm
fails and leaves its outputs in `$OUT` (a fresh `mktemp -d` by default). `CHIPDB_OTHER` names a second
chipdb whose pip naming differs from `CHIPDB`'s (another chipdb revision); unset, the arm that needs it
prints `SKIP` and does not count.

| arm | passes when |
|---|---|
| `--region-only` without a rectangle | `--write-fixed-routes` is refused, and the file it names is byte-identical afterwards |
| `--fixed-routes` precedence | a netlist written by a run with `--fixed-routes A` stores A in its settings, and reloading it with `--fixed-routes B` applies B and never A |
| router1 under a rectangle | a netlist placed with `--router router1`, which stores that router in its settings, is refused when it is routed with `NEXTPNR_PARTITION_ROI` set; with `NEXTPNR_PARTITION_CLAMP=off` and `NEXTPNR_PARTITION_KEEPOUT=off` as well it routes at rc 0 |
| static keepout, router2 control | a one-tile rectangle on an INT tile the longest static net crosses is routed around by router2 at rc 0, and the keepout gate's census reads 0 unlicensed |
| static keepout, `--fixed-routes` | the base route replayed with `--fixed-routes` under that rectangle is refused by the keepout gate |
| static keepout, imported routing | the routed netlist, kept as-is with `NEXTPNR_ROUTE_FIXED_ONLY=1` under that rectangle, is refused by the keepout gate |
| static keepout, keepout off | the `--fixed-routes` replay with `NEXTPNR_PARTITION_KEEPOUT=off` exits rc 0 and the gate's report-only census names the unlicensed pips |
| constant containment, imported | a one-tile rectangle on the INT tile carrying the most constant pips of the base route, whose sinks are all outside it, is refused by the keepout gate when the routed netlist is kept as-is |
| constant containment, fresh bridge | routing the placed netlist under that rectangle either ties every constant sink without a pip inside it, or refuses because no tie avoids it; rc 0 with a constant pip inside fails |
| constant containment, keepout off | routing the placed netlist under that rectangle with `NEXTPNR_PARTITION_KEEPOUT=off` exits rc 0 and the gate's report-only census counts the constant pips; the keepout switch turns off the constant confinement as well |
| constant containment, router1 escape | the router1 netlist routed under that rectangle with `NEXTPNR_PARTITION_CLAMP=off` and `NEXTPNR_PARTITION_KEEPOUT=off` exits rc 0 |
| frozen cell not moved | under a rectangle elsewhere on the die, a placement of the placed netlist with `NEXTPNR_BEL_BLACKLIST` naming the bel a static LUT sits on is refused by the post-place repair, not relocated |
| pinned cell not moved, no rectangle | with no rectangle, a placement of the placed netlist with one LUT pinned at `BEL_STRENGTH` 3 and its bel in `NEXTPNR_BEL_BLACKLIST` is refused by the post-place repair, which calls the cell pinned and names no rectangle |
| pre-place region inside the rectangle | with the fixture's LUTs and FF unplaced (so they are RM) under a rectangle at (20,120)-(120,200), a `--pre-place` hook that confines them to (100,180)-(120,200) is honoured: every one lands inside it |
| constant ties inside the rectangle | the netlist that hook placed, routed under the same rectangle, exits rc 0 with constant pips inside the rectangle, and the gate's constant census reads 0 crossings |
| pre-place region reaching outside | the same hook with a region at (0,100)-(30,130), partly outside the rectangle, is refused |
| `--region-only` over a placed netlist | with a rectangle around the placed logic and `--no-place`, `--region-only` is refused before routing and both outputs are left as they were; `geom.py escaping` reads the netlist and an unfiltered route under the same rectangle and must find nets with a cell inside that bind pips outside, which is what a region-only emission would have cut; that unfiltered route, which has no `--region-only`, is accepted with a warning naming the empty RM cell set |
| `--region-only` with every RM net exempt | the unplaced logic placed and routed under a rectangle with `NEXTPNR_PARTITION_EXEMPT_NETS` naming every net `geom.py touching-nets` finds on an RM cell is refused at `--fasm` and at `--write-fixed-routes`, each output left as it was |
| bel blacklist | a file naming one real bel reserves it at rc 0; a path that does not exist is refused in a run that places and in one that does not; a file with a name matching no bel is refused; a directory is refused in a run that places and in one that does not |
| `NEXTPNR_SKIP_FAILED_ARCS` | routes at rc 0 without a rectangle and is refused under one, with router2 and with router1 (clamp and keepout off); a `router1/skipFailedArcs` setting stored in the input netlist routes at rc 0 without a rectangle and is refused under one |
| partition modes | a netlist written under a rectangle with `NEXTPNR_PARTITION_CLAMP=off` records the rectangle file's content digest, the rectangle and `clamp=off` in its `partition_modes` setting, and a later run with no partition setting in its environment removes it; the same rectangle under another path and directory gives the same setting and a byte-identical netlist; `NEXTPNR_PARTITION_KEEPOUT_LICENCE`, `NEXTPNR_PARTITION_KEEPOUT_EXEMPT` and `NEXTPNR_EXCLUDE_STAMPED_BBOX` are recorded |
| `NEXTPNR_LUT_PERM_DROP` | on `lpd.v`, whose two LUT2s and flip-flop are instantiated with fixed INIT, fixed pins and fixed bels so the synthesiser cannot change the LUT the arm needs, a `--pre-route` hook binds `u_x`'s A2 net onto the permutation pip from site pin A5 to the free logical A3, which drops that input in the rewrite: unset, the run warns at rc 0; `=fatal`, it is refused and no netlist is written; `=fatal` on the route without the hook is rc 0; a value other than `fatal` or `warn` is refused |
| weak static cell beside an RM cell | `m8w.v`'s static LUT2 `u_s`, imported placed at WEAK strength with no BEL attribute, shares a one-tile rectangle with the unplaced RM LUT2 `u_r`; over `--placer heap` and `sa` at seeds 1 to 4 `u_s` ends at its imported bel at rc 0 |
| LUT permutation rewrite keeps each LUT's function | every SLICE_LUTX's logical function (INIT over the nets its `X_ORIG_PORT_*` pins carry, tabulated by `geom.py lut-functions`) is the same in the placed and routed netlist of `top.v`; on `lpd.v`'s hooked route the comparison sees the change the drop counter counts; and the same first-LUT hook on `top.v` either changes no function or changes one the counter reports |
| fixed-routes chipdb identity | `--write-fixed-routes` writes a `# nextpnr-xilinx chipdb:` line; a file naming another identity is refused with or without a rectangle, both a doctored one and one written by `CHIPDB_OTHER`; a file with index-form lines and no identity line is refused under a rectangle and loads without one |
| CARRY4 tree pinned on a blacklisted bel | `carry.v`, a 16-bit counter, is placed; its first CARRY4 is pinned at strength 3 on its own bel and that bel is blacklisted; re-placing it must stop with the post-place check naming that CARRY4, which the repair pass skips because it is a carry tree |
