#!/usr/bin/env python3
import argparse
import json
import sys

CONST_NETS = ("$PACKER_GND_NET", "$PACKER_VCC_NET")


def read_routes(path, grid):
    out = []
    with open(path) as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            net, pip = ln.rsplit(None, 1)
            tile = pip.split("/", 1)[0]
            g = grid[tile]
            out.append((net, tile, g["grid_x"], g["grid_y"]))
    return out


def pick_static(routes):
    by_net = {}
    for net, tile, x, y in routes:
        if net in CONST_NETS or not tile.startswith("INT_"):
            continue
        by_net.setdefault(net, set()).add((x, y))
    if not by_net:
        sys.exit("no static net crosses an INT tile")
    net = max(sorted(by_net), key=lambda n: len(by_net[n]))
    tiles = sorted(by_net[net])
    x, y = tiles[len(tiles) // 2]
    print(x, y)


def pick_const(routes):
    by_tile = {}
    for net, tile, x, y in routes:
        if net in CONST_NETS and tile.startswith("INT_"):
            by_tile[(x, y)] = by_tile.get((x, y), 0) + 1
    if not by_tile:
        sys.exit("no constant net binds a pip in an INT tile")
    x, y = min(by_tile, key=lambda t: (-by_tile[t], t))
    print(x, y)


def count(routes, x0, y0, x1, y1, which):
    n = 0
    for net, tile, x, y in routes:
        if not (x0 <= x <= x1 and y0 <= y <= y1):
            continue
        if (net in CONST_NETS) == (which == "const"):
            n += 1
    print(n)


def cell_tiles(grid, placed, cell_type):
    with open(placed) as f:
        cells = json.load(f)["modules"]["top"]["cells"]
    site_xy = {}
    for t in grid.values():
        for site in t.get("sites", {}):
            site_xy[site] = (t["grid_x"], t["grid_y"])
    for name in sorted(cells):
        c = cells[name]
        if c["type"] != cell_type:
            continue
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        x, y = site_xy.get(bel.split("/", 1)[0], (-1, -1))
        print(bel, x, y)


def unplace(placed, out, cell_types):
    with open(placed) as f:
        d = json.load(f)
    for c in d["modules"]["top"]["cells"].values():
        if c["type"] in cell_types:
            c["attributes"].pop("NEXTPNR_BEL", None)
            c["attributes"].pop("BEL_STRENGTH", None)
    with open(out, "w") as f:
        json.dump(d, f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tilegrid", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pick-static")
    p.add_argument("routes")
    p = sub.add_parser("pick-const")
    p.add_argument("routes")
    p = sub.add_parser("count")
    p.add_argument("routes")
    p.add_argument("which", choices=("static", "const"))
    for k in ("x0", "y0", "x1", "y1"):
        p.add_argument(k, type=int)
    p = sub.add_parser("cell-tiles")
    p.add_argument("placed")
    p.add_argument("cell_type")
    p = sub.add_parser("unplace")
    p.add_argument("placed")
    p.add_argument("out")
    p.add_argument("cell_types", nargs="+")
    a = ap.parse_args()
    with open(a.tilegrid) as f:
        grid = json.load(f)
    if a.cmd == "pick-static":
        pick_static(read_routes(a.routes, grid))
    elif a.cmd == "pick-const":
        pick_const(read_routes(a.routes, grid))
    elif a.cmd == "count":
        count(read_routes(a.routes, grid), a.x0, a.y0, a.x1, a.y1, a.which)
    elif a.cmd == "cell-tiles":
        cell_tiles(grid, a.placed, a.cell_type)
    elif a.cmd == "unplace":
        unplace(a.placed, a.out, a.cell_types)


if __name__ == "__main__":
    main()
