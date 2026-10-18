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


def cells_of(path):
    return load(path)["modules"]["top"]["cells"]


def srl(args):
    grid = load(args.tilegrid)
    st = site_tiles(grid)
    hits = []
    for name, c in sorted(cells_of(args.placed).items()):
        if c["attributes"].get("X_ORIG_TYPE", "") != "SRL16E":
            continue
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        site = bel.split("/", 1)[0]
        if site not in st:
            sys.exit("SRL cell %s has no placed site" % name)
        tile, x, y = st[site]
        hits.append((name, bel, tile, x, y))
    if len(hits) != 1:
        sys.exit("expected one SRL16E cell, found %d" % len(hits))
    print(*hits[0])


def int_tile_of(clb):
    side = clb.split("_")[1]
    coord = clb.rsplit("_", 1)[1]
    return "INT_%s" % side, coord


def vcc_block(args):
    grid = load(args.tilegrid)
    kind, coord = int_tile_of(args.clb)
    x = int(coord[1:coord.index("Y")])
    dsts = []
    with open("%s/ppips_%s.db" % (args.db, kind.lower())) as f:
        for ln in f:
            pip = ln.split()[0]
            _, dst, src = pip.split(".")
            if src == "VCC_WIRE":
                dsts.append(dst)
    if not dsts:
        sys.exit("no VCC_WIRE pip in ppips_%s.db" % kind.lower())
    n = 0
    for tile in sorted(grid):
        if not tile.startswith("%s_X%dY" % (kind, x)):
            continue
        for dst in dsts:
            print("%s.%s.VCC_WIRE" % (tile, dst))
            n += 1
    if n == 0:
        sys.exit("no INT tile in the column of %s" % args.clb)


def window_luts(args):
    grid = load(args.tilegrid)
    bound = {c["attributes"].get("NEXTPNR_BEL", "") for c in cells_of(args.placed).values()}
    inside = lambda x, y: args.rx0 <= x <= args.rx1 and args.ry0 <= y <= args.ry1
    for name in sorted(grid):
        t = grid[name]
        if not name.startswith("CLBL"):
            continue
        x, y = t["grid_x"], t["grid_y"]
        if max(abs(x - args.x), abs(y - args.y)) > args.radius:
            continue
        interior = inside(x - 1, y) and inside(x, y) and inside(x + 1, y)
        for site in sorted(t.get("sites", {})):
            if not site.startswith("SLICE_"):
                continue
            for z in "ABCD":
                bel = "%s/%s6LUT" % (site, z)
                if bel not in bound:
                    yield interior, bel


def lut_blacklist(args):
    for interior, bel in window_luts(args):
        if not interior:
            print(bel)


def lut_interior(args):
    print(sum(1 for interior, _ in window_luts(args) if interior))


def holdouts(args):
    grid = load(args.tilegrid)
    st = site_tiles(grid)
    for name, c in sorted(cells_of(args.routed).items()):
        if "$HOLDOUT$LUT$" not in name:
            continue
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        _, x, y = st.get(bel.split("/", 1)[0], ("", -1, -1))
        print(name, bel, x, y)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tilegrid", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("srl")
    p.add_argument("placed")
    p.set_defaults(fn=srl)
    p = sub.add_parser("vcc-block")
    p.add_argument("db")
    p.add_argument("clb")
    p.set_defaults(fn=vcc_block)
    for cmd, fn in (("lut-blacklist", lut_blacklist), ("lut-interior", lut_interior)):
        p = sub.add_parser(cmd)
        p.add_argument("placed")
        for k in ("x", "y", "radius", "rx0", "ry0", "rx1", "ry1"):
            p.add_argument(k, type=int)
        p.set_defaults(fn=fn)
    p = sub.add_parser("holdouts")
    p.add_argument("routed")
    p.set_defaults(fn=holdouts)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
