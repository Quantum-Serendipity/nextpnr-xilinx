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


def by_xy(grid):
    return {(t["grid_x"], t["grid_y"]): name for name, t in grid.items()}


def int_column(name, x):
    side = name.split("_")[1]
    return x + 1 if side == "L" else x - 1


def window_luts(args):
    grid = load(args.tilegrid)
    at = by_xy(grid)
    bound = {c["attributes"].get("NEXTPNR_BEL", "") for c in cells_of(args.placed).values()}
    inside = lambda x, y: args.rx0 <= x <= args.rx1 and args.ry0 <= y <= args.ry1
    for name in sorted(grid):
        t = grid[name]
        if not name.startswith("CLBL"):
            continue
        x, y = t["grid_x"], t["grid_y"]
        if max(abs(x - args.x), abs(y - args.y)) > args.radius:
            continue
        if inside(x - 1, y) and inside(x, y) and inside(x + 1, y):
            cls = "interior"
        elif inside(x - 1, y) or inside(x, y) or inside(x + 1, y):
            ix = int_column(name, x)
            unsafe = at.get((ix, y), "").startswith("INT_") and inside(ix, y)
            cls = "adjacent-int-inside" if unsafe else "adjacent-int-outside"
        else:
            cls = "outside"
        for site in sorted(t.get("sites", {})):
            if not site.startswith("SLICE_"):
                continue
            for z in "ABCD":
                bel = "%s/%s6LUT" % (site, z)
                if bel not in bound:
                    yield cls, bel


def lut_blacklist(args):
    for cls, bel in window_luts(args):
        if cls not in args.keep:
            print(bel)


def lut_count(args):
    print(sum(1 for cls, _ in window_luts(args) if cls in args.keep))


def adjacent_rect(args):
    grid = load(args.tilegrid)
    at = by_xy(grid)
    width = 1 + max(t["grid_x"] for t in grid.values())
    for d in range(2, args.span):
        for rx0, rx1, clb_x in ((args.x + d, args.x + d + args.span, args.x + d - 1),
                                (args.x - d - args.span, args.x - d, args.x - d + 1)):
            if rx0 < 0 or rx1 >= width:
                continue
            clb = at.get((clb_x, args.y), "")
            if not clb.startswith("CLBL"):
                continue
            ix = int_column(clb, clb_x)
            if rx0 <= ix <= rx1 and at.get((ix, args.y), "").startswith("INT_"):
                print(rx0, args.y - args.half_h, rx1, args.y + args.half_h, clb)
                return
    sys.exit("no logic tile beside a rectangle edge has its INT tile inside it")


def unplace(args):
    doc = load(args.placed)
    n = 0
    for c in doc["modules"]["top"]["cells"].values():
        if c["attributes"].get("X_ORIG_TYPE", "") == args.orig_type:
            c["attributes"].pop("NEXTPNR_BEL", None)
            n += 1
    if n == 0:
        sys.exit("no %s cell to unplace" % args.orig_type)
    with open(args.out, "w") as f:
        json.dump(doc, f)
    print(n)


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
    for cmd, fn in (("lut-blacklist", lut_blacklist), ("lut-count", lut_count)):
        p = sub.add_parser(cmd)
        p.add_argument("placed")
        for k in ("x", "y", "radius", "rx0", "ry0", "rx1", "ry1"):
            p.add_argument(k, type=int)
        p.add_argument("--keep", action="append", required=True,
                       choices=("interior", "adjacent-int-inside", "adjacent-int-outside", "outside"))
        p.set_defaults(fn=fn)
    p = sub.add_parser("adjacent-rect")
    for k in ("x", "y", "span", "half_h"):
        p.add_argument(k, type=int)
    p.set_defaults(fn=adjacent_rect)
    p = sub.add_parser("unplace")
    p.add_argument("placed")
    p.add_argument("orig_type")
    p.add_argument("out")
    p.set_defaults(fn=unplace)
    p = sub.add_parser("holdouts")
    p.add_argument("routed")
    p.set_defaults(fn=holdouts)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
