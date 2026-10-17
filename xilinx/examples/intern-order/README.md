# Placement does not depend on a constraint that cannot change timing

Places and routes `top.v` on an `xc7a100tfgg484` five times with seed 1: twice with `base.xdc`, and
once with each of three files that add constraints which cannot change any timing figure:

- `inert.xdc` adds `set_false_path -from [get_cells inert_a*] -to [get_cells inert_b*]`, and no path
  runs from `inert_a` to `inert_b`;
- `mcp.xdc` adds `set_multicycle_path 1 -setup` on `mcp_dst`, and a factor of 1 leaves the setup
  requirement as it was;
- `spare.xdc` adds a `set_property` on a port, a `create_clock` on a net and a `set_false_path
  -through` on a net pattern, none of which exist in the design, as a board-level XDC does.

```
CHIPDB=/path/to/xc7a100tfgg484.bin YOSYS=yosys NEXTPNR=/path/to/nextpnr-xilinx ./run.sh
```

| arm | passes when |
|---|---|
| `base_again` | the two `base.xdc` runs write the same FASM, so a difference below is not run-to-run noise |
| `inert` (log) | the log shows the exception read with one `from` cell and eight `to` cells |
| `mcp` (log) | the log shows the multicycle tag on `mcp_dst` |
| `spare` (log) | the log shows two absent targets ignored and the `-through` refused for matching no net |
| `inert`, `mcp`, `spare` (FASM) | that arm's FASM is byte-identical to the `base.xdc` FASM |
