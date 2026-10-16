import csv
import json
import sys


def as_int(v):
    if isinstance(v, int):
        return v
    s = str(v).strip()
    if s and set(s) <= set("01"):
        return int(s, 2)
    return int(s)


def load(routed, tsv):
    with open(routed) as f:
        top = next(m for m in json.load(f)["modules"].values() if m.get("cells"))
    cells = top["cells"]
    drivers, users = {}, {}
    for name, c in cells.items():
        dirs = c.get("port_directions", {})
        for port, bits in c.get("connections", {}).items():
            for b in bits:
                if not isinstance(b, int):
                    continue
                if dirs.get(port) == "output":
                    drivers[b] = (name, port)
                else:
                    users.setdefault(b, []).append((name, port))
    with open(tsv) as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    return cells, drivers, users, rows


def is_latch(c):
    return c["type"] == "SLICE_FFX" and "X_FF_AS_LATCH" in c.get("attributes", {})


def clk_inverted(c):
    return as_int(c.get("parameters", {}).get("IS_CLK_INVERTED", 0)) == 1


def row_periods(rows, pred):
    return [float(r["period_ns"]) for r in rows if pred(r)]


def main():
    routed, tsv, arm = sys.argv[1:4]
    cells, drivers, users, rows = load(routed, tsv)
    out = []

    def report(ok, msg):
        out.append(("PASS " if ok else "FAIL ") + arm + ": " + msg)

    def cell_of(r):
        return cells.get(r["cell"])

    if arm == "negedge":
        neg = row_periods(rows, lambda r: cell_of(r) and cell_of(r)["type"] == "SLICE_FFX" and r["port"] == "D"
                          and clk_inverted(cell_of(r)) and not is_latch(cell_of(r)))
        report(bool(neg) and all(p == 5.0 for p in neg),
               "%d negedge D row(s), periods %s (need 5)" % (len(neg), sorted(set(neg))))
        pos = row_periods(rows, lambda r: cell_of(r) and cell_of(r)["type"] == "SLICE_FFX" and r["port"] == "D"
                          and not clk_inverted(cell_of(r)) and not is_latch(cell_of(r)))
        report(5.0 in pos, "posedge D rows with a half-period (negedge launch): %d" % pos.count(5.0))
    elif arm == "latch":
        lat = row_periods(rows, lambda r: cell_of(r) and is_latch(cell_of(r)) and r["port"] == "D")
        report(bool(lat) and all(p == 5.0 for p in lat),
               "%d latch D row(s), periods %s (need 5, closing edge)" % (len(lat), sorted(set(lat))))
        pos = row_periods(rows, lambda r: cell_of(r) and cell_of(r)["type"] == "SLICE_FFX" and r["port"] == "D"
                          and not clk_inverted(cell_of(r)) and not is_latch(cell_of(r)))
        report(5.0 in pos and 10.0 in pos,
               "flop D rows after the latch: %d half-period (closing launch), %d full-period (opening launch)"
               % (pos.count(5.0), pos.count(10.0)))
    else:
        report(False, "unknown arm")
    print("\n".join(out))


if __name__ == "__main__":
    main()
