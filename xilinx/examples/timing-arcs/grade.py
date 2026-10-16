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


def is_srl(c):
    return c["type"] == "SLICE_LUTX" and "X_LUT_AS_SRL" in c.get("attributes", {})


def is_dram(c):
    return c["type"] == "SLICE_LUTX" and "X_LUT_AS_DRAM" in c.get("attributes", {})


def is_latch(c):
    return c["type"] == "SLICE_FFX" and "X_FF_AS_LATCH" in c.get("attributes", {})


def clk_inverted(c):
    return as_int(c.get("parameters", {}).get("IS_CLK_INVERTED", 0)) == 1


def is_comb(c):
    if c["type"] == "SLICE_LUTX":
        return not is_srl(c) and not is_dram(c)
    return c["type"] in ("CARRY4", "F7MUX", "F8MUX", "SELMUX2_1")


def cone_sinks(cells, drivers, users, sources):
    seen, sinks = set(), set()
    frontier = []
    for name, ports in sources:
        for p in ports:
            frontier.extend(b for b in cells[name]["connections"].get(p, []) if isinstance(b, int))
    while frontier:
        b = frontier.pop()
        if b in seen:
            continue
        seen.add(b)
        for name, port in users.get(b, []):
            c = cells[name]
            if c["type"] == "SLICE_FFX" and port in ("D", "CE", "SR"):
                sinks.add((name, port))
            elif is_comb(c):
                for p, d in c.get("port_directions", {}).items():
                    if d == "output":
                        frontier.extend(x for x in c["connections"].get(p, []) if isinstance(x, int))
    return sinks


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
    elif arm == "srl":
        srls = [n for n, c in cells.items() if is_srl(c)]
        write = [r for r in rows if r["cell"] in srls and r["port"] in ("DI1", "DI2", "WE")]
        report(bool(srls) and len({r["cell"] for r in write if r["port"] in ("DI1", "DI2")}) == len(srls),
               "%d SRL cell(s), %d with a DI row, %d WE row(s)"
               % (len(srls), len({r["cell"] for r in write if r["port"] in ("DI1", "DI2")}),
                  sum(r["port"] == "WE" for r in write)))
        sinks = cone_sinks(cells, drivers, users, [(n, ("O5", "O6", "MC31")) for n in srls])
        have = {(r["cell"], r["port"]) for r in rows}
        missing = sorted(sinks - have)
        report(bool(sinks) and not missing,
               "%d flop pin(s) fed by an SRL output, %d without a row%s"
               % (len(sinks), len(missing), (" e.g. %s.%s" % missing[0]) if missing else ""))
        mc31 = [n for n in srls if any(isinstance(b, int) and b in users
                                       for b in cells[n]["connections"].get("MC31", []))]
        casc = [r for r in rows if r["cell"] in srls and r["port"] == "DI1"
                and any(drivers.get(b, (None, None))[1] == "MC31"
                        for b in cells[r["cell"]]["connections"].get("DI1", []) if isinstance(b, int))]
        report(bool(mc31) and bool(casc), "%d SRL(s) drive MC31, %d DI1 row(s) launched from MC31"
               % (len(mc31), len(casc)))
    else:
        report(False, "unknown arm")
    print("\n".join(out))


if __name__ == "__main__":
    main()
