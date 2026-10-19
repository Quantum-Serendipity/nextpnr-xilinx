#!/usr/bin/env python3
import argparse
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def site_tiles(grid):
    out = {}
    for name, t in grid.items():
        for site in t.get("sites", {}):
            out[site] = (name, t["grid_x"], t["grid_y"])
    return out


def top_of(path):
    return load(path)["modules"]["top"]


def net_names(mod):
    names = {}
    for n, v in sorted(mod["netnames"].items(), key=lambda kv: (kv[1].get("hide_name", 0), kv[0])):
        for b in v["bits"]:
            names.setdefault(b, n)
    return names


def port_net(mod, names, cell, port):
    bits = cell["connections"].get(port, [])
    if not bits or isinstance(bits[0], str):
        return ""
    return names.get(bits[0], str(bits[0]))


def ram_cells(mod):
    return {n: c for n, c in sorted(mod["cells"].items()) if c["attributes"].get("X_ORIG_TYPE", "") == "RAMD32"}


def ram(args):
    grid = load(args.tilegrid)
    st = site_tiles(grid)
    cells = ram_cells(top_of(args.placed))
    if len(cells) != 8:
        sys.exit("expected eight RAMD32 cells from one RAM32M, found %d" % len(cells))
    sites = {c["attributes"].get("NEXTPNR_BEL", "").split("/", 1)[0] for c in cells.values()}
    if len(sites) != 1:
        sys.exit("the RAMD32 cells sit in %d sites, expected one: %s" % (len(sites), sorted(sites)))
    site = sites.pop()
    if site not in st:
        sys.exit("site %s is not in the tilegrid" % site)
    tile, x, y = st[site]
    print(site, tile, x, y)


def ram_port(args):
    mod = top_of(args.placed)
    hits = []
    for n, c in ram_cells(mod).items():
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        if bel.endswith("/" + args.bel) and args.port in c["connections"]:
            hits.append(n)
    if len(hits) != 1:
        sys.exit("expected one RAMD32 cell at %s with port %s, found %d" % (args.bel, args.port, len(hits)))
    print(hits[0])


def gnd_block(args):
    grid = load(args.tilegrid)
    n = 0
    for tile in sorted(grid):
        kind = grid[tile]["type"]
        if kind in ("INT_L", "INT_R"):
            for dst in ("GFAN0", "GFAN1"):
                print("%s.%s.GND_WIRE" % (tile, dst))
                n += 1
        elif kind in ("CLBLL_L", "CLBLL_R", "CLBLM_L", "CLBLM_R"):
            print("%s.A.PSEUDO_GND_WIRE_ROW" % tile)
            n += 1
    if n == 0:
        sys.exit("no INT or CLB tile in the tilegrid")


def holdouts(args):
    grid = load(args.tilegrid)
    st = site_tiles(grid)
    for n, c in sorted(top_of(args.routed)["cells"].items()):
        if "$HOLDOUT$LUT$" not in n:
            continue
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        site = bel.split("/", 1)[0]
        _, x, y = st.get(site, ("", -1, -1))
        print(n, bel, x, y)


def shared_wire(args):
    mod = top_of(args.routed)
    names = net_names(mod)
    nets = {}
    for n, c in ram_cells(mod).items():
        bel = c["attributes"].get("NEXTPNR_BEL", "").split("/", 1)[-1]
        nets["%s.%s" % (n, args.wa)] = port_net(mod, names, c, args.wa)
        if bel in ("D6LUT", "D5LUT"):
            nets["%s.%s" % (n, args.a)] = port_net(mod, names, c, args.a)
    distinct = sorted(set(nets.values()))
    if len(nets) != 10:
        sys.exit("expected ten ports on the shared write-address wire, found %d" % len(nets))
    if len(distinct) != 1:
        sys.exit("the ports on one site wire are on %d nets: %s" %
                 (len(distinct), ", ".join("%s=%s" % kv for kv in sorted(nets.items()))))
    print(len(nets), distinct[0])


def rect(args):
    print(json.dumps({"info": {"GRID_X_MIN": args.x0, "GRID_X_MAX": args.x1, "GRID_Y_MIN": args.y0,
                               "GRID_Y_MAX": args.y1}}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tilegrid", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ram")
    p.add_argument("placed")
    p.set_defaults(fn=ram)
    p = sub.add_parser("ram-port")
    p.add_argument("placed")
    p.add_argument("bel")
    p.add_argument("port")
    p.set_defaults(fn=ram_port)
    p = sub.add_parser("gnd-block")
    p.set_defaults(fn=gnd_block)
    p = sub.add_parser("holdouts")
    p.add_argument("routed")
    p.set_defaults(fn=holdouts)
    p = sub.add_parser("shared-wire")
    p.add_argument("routed")
    p.add_argument("wa")
    p.add_argument("a")
    p.set_defaults(fn=shared_wire)
    p = sub.add_parser("rect")
    for k in ("x0", "y0", "x1", "y1"):
        p.add_argument(k, type=int)
    p.set_defaults(fn=rect)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
