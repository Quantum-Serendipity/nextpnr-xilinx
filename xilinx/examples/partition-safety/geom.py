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
    site_xy = site_grid(grid)
    for name in sorted(cells):
        c = cells[name]
        if c["type"] != cell_type:
            continue
        bel = c["attributes"].get("NEXTPNR_BEL", "")
        x, y = site_xy.get(bel.split("/", 1)[0], (-1, -1))
        print(bel, x, y)


def site_grid(grid):
    site_xy = {}
    for t in grid.values():
        for site in t.get("sites", {}):
            site_xy[site] = (t["grid_x"], t["grid_y"])
    return site_xy


def cell_xy(cells, site_xy):
    out = {}
    for name, c in cells.items():
        bel = c.get("attributes", {}).get("NEXTPNR_BEL", "")
        if bel:
            xy = site_xy.get(bel.split("/", 1)[0])
            if xy is not None:
                out[name] = xy
    return out


def cell_bbox(grid, placed, cell_types):
    with open(placed) as f:
        cells = json.load(f)["modules"]["top"]["cells"]
    xy = cell_xy({n: c for n, c in cells.items() if c["type"] in cell_types}, site_grid(grid))
    if not xy:
        sys.exit("no placed cell of type " + ",".join(cell_types))
    xs = [p[0] for p in xy.values()]
    ys = [p[1] for p in xy.values()]
    print(min(xs), min(ys), max(xs), max(ys))


def net_cells(mod):
    bit_names = {}
    for name, nn in mod["netnames"].items():
        for b in nn["bits"]:
            if isinstance(b, int):
                bit_names.setdefault(b, set()).add(name)
    out = {}
    for cname, c in mod["cells"].items():
        for bits in c.get("connections", {}).values():
            for b in bits:
                for n in bit_names.get(b, ()):
                    out.setdefault(n, set()).add(cname)
    return out


def touching_nets(placed, cell_types):
    with open(placed) as f:
        mod = json.load(f)["modules"]["top"]
    for n, cs in sorted(net_cells(mod).items()):
        if n in CONST_NETS:
            continue
        if any(mod["cells"][c]["type"] in cell_types for c in cs):
            print(n)


def escaping(grid, placed, routes_path, x0, y0, x1, y1):
    with open(placed) as f:
        mod = json.load(f)["modules"]["top"]
    xy = cell_xy(mod["cells"], site_grid(grid))
    inside = lambda p: x0 <= p[0] <= x1 and y0 <= p[1] <= y1
    held = set()
    for n, cs in net_cells(mod).items():
        if n in CONST_NETS:
            continue
        if any(c in xy and inside(xy[c]) for c in cs):
            held.add(n)
    esc_nets = set()
    out_pips = 0
    for net, tile, x, y in read_routes(routes_path, grid):
        if net in held and not inside((x, y)):
            esc_nets.add(net)
            out_pips += 1
    print(len(held), len(esc_nets), out_pips)


def unplace(placed, out, cell_types):
    with open(placed) as f:
        d = json.load(f)
    for c in d["modules"]["top"]["cells"].values():
        if c["type"] in cell_types:
            c["attributes"].pop("NEXTPNR_BEL", None)
            c["attributes"].pop("BEL_STRENGTH", None)
    with open(out, "w") as f:
        json.dump(d, f)


def pin(placed, out, bel, strength):
    with open(placed) as f:
        d = json.load(f)
    hit = 0
    for c in d["modules"]["top"]["cells"].values():
        if c["attributes"].get("NEXTPNR_BEL") == bel:
            c["attributes"]["BEL_STRENGTH"] = format(strength, "032b")
            hit += 1
    if hit == 0:
        sys.exit("no cell sits on " + bel)
    with open(out, "w") as f:
        json.dump(d, f)


def lut_table(path):
    with open(path) as f:
        top = json.load(f)["modules"]["top"]
    names = {}
    for name, nn in top["netnames"].items():
        for b in nn["bits"]:
            if isinstance(b, int) and (b not in names or name < names[b]):
                names[b] = name
    out = {}
    for cname, c in top["cells"].items():
        if c["type"] != "SLICE_LUTX":
            continue
        init = c["parameters"].get("INIT", "")
        k = (len(init) - 1).bit_length()
        logical = {}
        for port, bits in c["connections"].items():
            orig = c["attributes"].get("X_ORIG_PORT_" + port, "")
            if not port.startswith("A") or not bits or not orig:
                continue
            b = bits[0]
            net = names.get(b, "const:%s" % b) if isinstance(b, int) else "const:%s" % b
            for lp in orig.split():
                logical.setdefault(lp, set()).add(net)
        out[cname] = (init, k, logical)
    return out


def lut_function(init, k, logical, nets):
    rows = []
    for assign in range(1 << len(nets)):
        val = {n: (assign >> i) & 1 for i, n in enumerate(nets)}
        for n in nets:
            if n.startswith("const:"):
                val[n] = int(n[6:]) if n[6:] in ("0", "1") else None
        idx = 0
        for i in range(k):
            src = logical.get("I%d" % i)
            if not src or len(src) != 1:
                rows.append(None)
                break
            v = val[next(iter(src))]
            if v is None:
                rows.append(None)
                break
            idx |= v << i
        else:
            rows.append(init[len(init) - 1 - idx] if idx < len(init) else None)
    return rows


def lut_functions(before, after):
    a, b = lut_table(before), lut_table(after)
    diffs, n = [], 0
    for cname in sorted(set(a) & set(b)):
        nets = sorted(set().union(*a[cname][2].values(), *b[cname][2].values()))
        if len(nets) > 12:
            print("lut-functions: %s reads %d nets, too many to tabulate" % (cname, len(nets)))
            sys.exit(2)
        n += 1
        if lut_function(*a[cname], nets) != lut_function(*b[cname], nets):
            diffs.append("%s: INIT %s %s before, INIT %s %s after" % (
                cname, a[cname][0], sorted((p, sorted(v)) for p, v in a[cname][2].items()), b[cname][0],
                sorted((p, sorted(v)) for p, v in b[cname][2].items())))
    print("lut-functions: %d LUT(s) in both netlists, %d with a different logical function%s" % (
        n, len(diffs), ("; first: " + diffs[0]) if diffs else ""))
    if n == 0:
        sys.exit(2)
    sys.exit(1 if diffs else 0)


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
    p = sub.add_parser("pin")
    p.add_argument("placed")
    p.add_argument("out")
    p.add_argument("bel")
    p.add_argument("strength", type=int)
    p = sub.add_parser("cell-bbox")
    p.add_argument("placed")
    p.add_argument("cell_types", nargs="+")
    p = sub.add_parser("touching-nets")
    p.add_argument("placed")
    p.add_argument("cell_types", nargs="+")
    p = sub.add_parser("lut-functions")
    p.add_argument("before")
    p.add_argument("after")
    p = sub.add_parser("escaping")
    p.add_argument("placed")
    p.add_argument("routes")
    for k in ("x0", "y0", "x1", "y1"):
        p.add_argument(k, type=int)
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
    elif a.cmd == "cell-bbox":
        cell_bbox(grid, a.placed, a.cell_types)
    elif a.cmd == "touching-nets":
        touching_nets(a.placed, a.cell_types)
    elif a.cmd == "escaping":
        escaping(grid, a.placed, a.routes, a.x0, a.y0, a.x1, a.y1)
    elif a.cmd == "unplace":
        unplace(a.placed, a.out, a.cell_types)
    elif a.cmd == "lut-functions":
        lut_functions(a.before, a.after)
    elif a.cmd == "pin":
        pin(a.placed, a.out, a.bel, a.strength)


if __name__ == "__main__":
    main()
