#!/usr/bin/env python3
import csv
import json
import os
import re
import sys

TOL = 0.0025

HOLD_COLUMNS = ["cell", "port", "hold_slack_ns", "net", "net_delay_min_ns", "driver_min_arrival_ns", "hold_ns",
                "hold_req_ns", "capture_clk_delay_ns", "launch_clk", "capture_clk", "delay_source"]


def read_tsv(path):
    if not os.path.exists(path):
        return None, []
    with open(path) as f:
        r = csv.DictReader(f, delimiter="\t")
        return r.fieldnames, list(r)


def netlist(routed):
    with open(routed) as f:
        top = json.load(f)["modules"]["top"]
    names = {}
    for name, nn in top["netnames"].items():
        for bit in nn["bits"]:
            if isinstance(bit, int):
                names.setdefault(bit, set()).add(name)
    group, q_of, bel = {}, {}, {}
    for cname, cell in top["cells"].items():
        bel[cname] = cell.get("attributes", {}).get("NEXTPNR_BEL", "")
        for port in ("Q", "OUT", "O6"):
            bits = cell["connections"].get(port, [])
            if bits and isinstance(bits[0], int):
                cand = sorted(n for n in names.get(bits[0], ()) if not n.startswith("$"))
                if cand:
                    group.setdefault(cname, re.sub(r"\[.*", "", cand[0]))
                    for n in cand:
                        q_of.setdefault(n, cname)
                break
        group.setdefault(cname, cname)
    return group, q_of, bel


class Sdf:
    def __init__(self, timings, tilegrid):
        self.timings = timings
        with open(tilegrid) as f:
            grid = json.load(f)
        self.site = {}
        for tile, info in grid.items():
            for site, stype in info.get("sites", {}).items():
                self.site[site] = (info["type"], stype)
        self.cache = {}

    def cells(self, tiletype):
        if tiletype not in self.cache:
            path = os.path.join(self.timings, tiletype + ".sdf")
            out = {}
            if os.path.exists(path):
                txt = open(path).read()
                for m in re.finditer(r'\(CELL\s*\(CELLTYPE "([^"]+)"\)\s*\(INSTANCE ([^)]*)\)(.*?)\n    \)', txt, re.S):
                    ct, inst, body = m.group(1), m.group(2).strip(), m.group(3)
                    arcs = {}
                    for io in re.finditer(r"IOPATH (\S+) (\S+) \(([^)]*)\)\(([^)]*)\)", body):
                        vals = []
                        for trip in (io.group(3), io.group(4)):
                            parts = [p for p in trip.split(":")]
                            nums = [float(p) for p in parts if p != ""]
                            vals.append((min(nums), max(nums)))
                        arcs[(io.group(1), io.group(2))] = (min(v[0] for v in vals), max(v[1] for v in vals))
                    out[(inst, ct)] = arcs
            self.cache[tiletype] = out
        return self.cache[tiletype]

    def locate(self, belname):
        site, _, b = belname.partition("/")
        return self.site.get(site, (None, None)) + (b,)


def grade_arcs(argv):
    routed, arcs_tsv, timings, tilegrid, name = argv
    cols, rows = read_tsv(arcs_tsv)
    if cols is None:
        return "FAIL %s: no NEXTPNR_ARC_EXPORT file was written" % name
    sdf = Sdf(timings, tilegrid)
    checked, kinds, bad = 0, set(), []
    for r in rows:
        if r["type"] not in ("SLICE_LUTX", "CARRY4", "SELMUX2_1"):
            continue
        tiletype, sitetype, b = sdf.locate(r["bel"])
        if tiletype is None:
            bad.append("%s: bel %s is in no tilegrid site" % (r["cell"], r["bel"]))
            continue
        frm, to = r["from"], r["to"]
        if r["type"] == "SLICE_LUTX":
            lut5 = b.endswith("5LUT")
            if sitetype == "SLICEM":
                variant = "LUT_OR_MEM5LRAM" if lut5 else "LUT_OR_MEM6LRAM"
            else:
                variant = "LUT5" if lut5 else "LUT6"
            inst = "%s/%s" % (sitetype, b)
            if lut5:
                frm = "A5" if frm == "A6" else frm
                to = "O5" if to == "O6" else to
        elif r["type"] == "CARRY4":
            variant, inst = "CARRY4", sitetype
        else:
            variant, inst = "SELMUX2_1", "%s/%s" % (sitetype, b)
        want = sdf.cells(tiletype).get((inst, variant), {}).get((frm, to))
        if want is None:
            bad.append("%s %s->%s: the SDF of %s has no %s %s arc" % (r["cell"], r["from"], r["to"], tiletype,
                                                                      inst, variant))
            continue
        got = (float(r["min_ns"]), float(r["max_ns"]))
        if abs(got[0] - want[0]) > TOL or abs(got[1] - want[1]) > TOL:
            bad.append("%s %s->%s at %s: min/max %.3f/%.3f ns where %s.sdf %s %s gives %.3f/%.3f" %
                       (r["cell"], r["from"], r["to"], r["bel"], got[0], got[1], tiletype, inst, variant,
                        want[0], want[1]))
            continue
        checked += 1
        kinds.add(variant if r["type"] != "SLICE_LUTX" else ("LUT5" if b.endswith("5LUT") else "LUT6"))
    have = {(r["cell"], r["from"], r["to"]) for r in rows}
    with open(routed) as f:
        cells = json.load(f)["modules"]["top"]["cells"]
    for cname, cell in sorted(cells.items()):
        attrs = cell.get("attributes", {})
        if cell["type"] != "SLICE_LUTX" or "X_LUT_AS_DRAM" in attrs or "X_LUT_AS_SRL" in attrs:
            continue
        conn = cell["connections"]
        outs = [o for o in ("O5", "O6") if conn.get(o) and attrs.get("X_ORIG_PORT_" + o)]
        for i in ("A1", "A2", "A3", "A4", "A5", "A6"):
            if not conn.get(i) or not isinstance(conn[i][0], int) or not attrs.get("X_ORIG_PORT_" + i):
                continue
            for o in outs:
                if (cname, i, o) not in have:
                    bad.append("%s at %s: no %s->%s arc although both pins are used" % (
                        cname, attrs.get("NEXTPNR_BEL", "?"), i, o))
        b = attrs.get("NEXTPNR_BEL", "")
        if sdf.locate(b)[1] == "SLICEM":
            kinds.add("SLICEM")
    missing = {"LUT5", "LUT6", "CARRY4", "SELMUX2_1", "SLICEM"} - kinds
    if bad:
        return "FAIL %s: %d of %d arc(s) disagree with the SDF; first: %s" % (name, len(bad), len(bad) + checked,
                                                                               bad[0])
    if missing:
        return "FAIL %s: no checked arc of kind %s" % (name, ", ".join(sorted(missing)))
    return "PASS %s: %d LUT5/LUT6/CARRY4/SELMUX2_1 arc(s), a SLICEM LUT among them, carry the SDF fast-corner " \
           "min and slow-corner max, and every used LUT input has an arc to every used output" % (name, checked)


def hold_rows(path):
    cols, rows = read_tsv(path)
    return cols, rows


def grade_hold(argv):
    hold_tsv, name = argv
    cols, rows = hold_rows(hold_tsv)
    if cols is None:
        return "FAIL %s: no NEXTPNR_HOLD_EXPORT file was written" % name
    if cols != HOLD_COLUMNS:
        return "FAIL %s: header %s" % (name, "/".join(cols or []))
    if not rows:
        return "FAIL %s: no hold row" % name
    for r in rows:
        f = {k: float(r[k]) for k in HOLD_COLUMNS[2:9] if k != "net"}
        want = (f["driver_min_arrival_ns"] + f["net_delay_min_ns"] - f["hold_ns"] - f["hold_req_ns"] -
                f["capture_clk_delay_ns"])
        if abs(want - f["hold_slack_ns"]) > TOL:
            return "FAIL %s: %s.%s hold slack %.3f where its columns give %.3f" % (name, r["cell"], r["port"],
                                                                                  f["hold_slack_ns"], want)
    return "PASS %s: %d hold row(s), each slack equal to its arrival, hold, requirement and clock columns" % (
        name, len(rows))


def grade_skew(argv):
    routed, setup_tsv, hold_tsv, timings, tilegrid, prefix, name = argv
    group, q_of, bel = netlist(routed)
    _, srows = read_tsv(setup_tsv)
    hcols, hrows = read_tsv(hold_tsv)
    if hcols is None:
        return "FAIL %s: no NEXTPNR_HOLD_EXPORT file was written" % name
    cap = {(r["cell"], r["port"]): float(r["capture_clk_delay_ns"]) for r in hrows}
    sdf = Sdf(timings, tilegrid)
    checked = 0
    for r in srows:
        if not re.fullmatch(re.escape(prefix) + r"\[\d+\]", r["net"]):
            continue
        drv = q_of.get(r["net"])
        if drv is None or (drv, "D") not in cap or (r["cell"], r["port"]) not in cap:
            return "FAIL %s: no hold row for the driver or the capture flop of net %s" % (name, r["net"])
        launch = cap[(drv, "D")]
        capture = cap[(r["cell"], r["port"])]
        if launch < 0.1 or capture < 0.1:
            return "FAIL %s: net %s has a clock-pin delay of %.3f/%.3f ns, so its clock is not routed" % (
                name, r["net"], launch, capture)
        tiletype, sitetype, _ = sdf.locate(bel.get(drv, ""))
        ctq = [arcs[("CLK", "Q")][1] for (inst, ct), arcs in sdf.cells(tiletype or "").items()
               if inst == sitetype and ("CLK", "Q") in arcs]
        arrival = float(r["driver_arrival_ns"])
        if not any(abs(arrival - launch - c) <= TOL for c in ctq):
            return "FAIL %s: %s drives %s at %.3f ns; less its %.3f ns clock-pin delay that is %.3f, no SDF clk->Q " \
                   "max of %s %s (%s)" % (name, drv, r["net"], arrival, launch, arrival - launch, tiletype, sitetype,
                                         ", ".join("%.3f" % c for c in sorted(ctq)))
        slack = float(r["period_ns"]) - (arrival + float(r["net_delay_ns"]) + float(r["setup_ns"]) - capture)
        if abs(slack - float(r["slack_ns"])) > TOL:
            return "FAIL %s: %s.%s setup slack %s where period, arrival, setup and the %.3f ns capture clock give " \
                   "%.3f" % (name, r["cell"], r["port"], r["slack_ns"], capture, slack)
        checked += 1
    if checked == 0:
        return "FAIL %s: no flop-to-flop row on a %s net" % (name, prefix)
    return "PASS %s: %d flop-to-flop row(s) add the launch clock-pin delay to the arrival and the capture " \
           "clock-pin delay to the requirement" % (name, checked)


def grade_period(argv):
    routed, tsv, grp, launch, capture, column, want, name = argv
    group, _, _ = netlist(routed)
    cols, rows = read_tsv(tsv)
    if cols is None:
        return "FAIL %s: no export %s" % (name, os.path.basename(tsv))
    got = sorted({float(r[column]) for r in rows if group.get(r["cell"]) == grp and r["launch_clk"] == launch
                  and r["capture_clk"] == capture})
    if not got:
        return "FAIL %s: no %s row for %s from %s to %s" % (name, column, grp, launch, capture)
    if any(abs(g - float(want)) > TOL for g in got):
        return "FAIL %s: %s rows of %s (%s -> %s) read %s, not %s" % (name, column, grp, launch, capture,
                                                                    "/".join("%g" % g for g in got), want)
    return "PASS %s: every %s row of %s (%s -> %s) reads %s" % (name, column, grp, launch, capture, want)


def grade_norow(argv):
    routed, tsv, grp, present, name = argv
    group, _, _ = netlist(routed)
    cols, rows = read_tsv(tsv)
    if cols is None:
        return "FAIL %s: no export %s" % (name, os.path.basename(tsv))
    n = sum(1 for r in rows if group.get(r["cell"]) == grp or r["cell"] == grp)
    if present == "1" and n == 0:
        return "FAIL %s: no row for %s" % (name, grp)
    if present == "0" and n != 0:
        return "FAIL %s: %d row(s) for %s, which the exception excludes" % (name, n, grp)
    return "PASS %s: %s %s" % (name, grp, "is graded" if present == "1" else "is not graded")


def main():
    cmd, argv = sys.argv[1], sys.argv[2:]
    print({"arcs": grade_arcs, "hold": grade_hold, "skew": grade_skew, "period": grade_period,
           "norow": grade_norow}[cmd](argv))


main()
