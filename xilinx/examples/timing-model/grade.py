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


def grade_zero_min(argv):
    arcs_tsv, name = argv
    cols, rows = read_tsv(arcs_tsv)
    if cols is None:
        return "FAIL %s: no NEXTPNR_ARC_EXPORT file was written" % name
    kinds, n = set(), 0
    for r in rows:
        if r["type"] not in ("SLICE_LUTX", "CARRY4", "SELMUX2_1"):
            continue
        if float(r["max_ns"]) <= 0:
            return "FAIL %s: %s %s->%s has a max of %s ns" % (name, r["cell"], r["from"], r["to"], r["max_ns"])
        if abs(float(r["min_ns"])) > TOL:
            return "FAIL %s: %s %s->%s reads min %s ns where the chipdb gives 0 (max %s)" % (
                name, r["cell"], r["from"], r["to"], r["min_ns"], r["max_ns"])
        kinds.add(r["type"])
        n += 1
    missing = {"SLICE_LUTX", "CARRY4", "SELMUX2_1"} - kinds
    if missing:
        return "FAIL %s: no arc of type %s" % (name, ", ".join(sorted(missing)))
    return "PASS %s: %d LUT/CARRY4/SELMUX2_1 arc(s) keep a zero fast-corner minimum" % (name, n)


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


def sdf_clock_pins(path):
    if not os.path.exists(path):
        return None
    unesc = lambda t: re.sub(r"\\(.)", r"\1", t)
    out = {}
    for m in re.finditer(r"\(INTERCONNECT (\S+) (\S+) \((\d+):(\d+):(\d+)\)", open(path).read()):
        cell, _, port = unesc(m.group(2)).rpartition("/")
        if port in ("CK", "C", "CLK"):
            out[cell] = int(m.group(5)) / 1000.0
    return out


def grade_skew(argv):
    routed, setup_tsv, hold_tsv, sdf_path, timings, tilegrid, prefixes, name = argv
    group, q_of, bel = netlist(routed)
    _, srows = read_tsv(setup_tsv)
    hcols, hrows = read_tsv(hold_tsv)
    if hcols is None:
        return "FAIL %s: no NEXTPNR_HOLD_EXPORT file was written" % name
    clk = sdf_clock_pins(sdf_path)
    if not clk:
        return "FAIL %s: no clock-pin INTERCONNECT in %s" % (name, os.path.basename(sdf_path))
    hold = {(r["cell"], r["port"]): r for r in hrows}
    sdf = Sdf(timings, tilegrid)
    net_re = re.compile("(%s)\\[\\d+\\]" % "|".join(re.escape(p) for p in prefixes.split(",")))
    checked, early, late = 0, 0, 0
    for r in srows:
        if not net_re.fullmatch(r["net"]):
            continue
        drv = q_of.get(r["net"])
        if drv is None or drv not in clk or r["cell"] not in clk:
            return "FAIL %s: the SDF gives no clock-pin delay for the driver or the capture flop of net %s" % (
                name, r["net"])
        launch, capture = clk[drv], clk[r["cell"]]
        if launch < 0.1 or capture < 0.1:
            return "FAIL %s: net %s has a clock-pin delay of %.3f/%.3f ns, so its clock is not routed" % (
                name, r["net"], launch, capture)
        tiletype, sitetype, _ = sdf.locate(bel.get(drv, ""))
        ctq = [arcs[("CLK", "Q")] for (inst, ct), arcs in sdf.cells(tiletype or "").items()
               if inst == sitetype and ("CLK", "Q") in arcs]
        arrival = float(r["driver_arrival_ns"])
        if not any(abs(arrival - launch - c[1]) <= TOL for c in ctq):
            return "FAIL %s: %s drives %s at %.3f ns; less its %.3f ns SDF clock-pin delay that is %.3f, no SDF " \
                   "clk->Q max of %s %s (%s)" % (name, drv, r["net"], arrival, launch, arrival - launch, tiletype,
                                                sitetype, ", ".join("%.3f" % c[1] for c in sorted(ctq)))
        slack = float(r["period_ns"]) - (arrival + float(r["net_delay_ns"]) + float(r["setup_ns"]) - capture)
        if abs(slack - float(r["slack_ns"])) > TOL:
            return "FAIL %s: %s.%s setup slack %s where period, arrival, setup and the %.3f ns SDF capture clock " \
                   "give %.3f" % (name, r["cell"], r["port"], r["slack_ns"], capture, slack)
        h = hold.get((r["cell"], r["port"]))
        if h is None:
            return "FAIL %s: no hold row for %s.%s" % (name, r["cell"], r["port"])
        if abs(float(h["capture_clk_delay_ns"]) - capture) > TOL:
            return "FAIL %s: %s.%s hold row takes a %s ns capture clock where the SDF gives %.3f" % (
                name, r["cell"], r["port"], h["capture_clk_delay_ns"], capture)
        min_arr = float(h["driver_min_arrival_ns"])
        if not any(abs(min_arr - launch - c[0]) <= TOL for c in ctq):
            return "FAIL %s: %s.%s hold arrival %.3f ns; less the %.3f ns SDF launch clock that is %.3f, no SDF " \
                   "clk->Q min (%s)" % (name, r["cell"], r["port"], min_arr, launch, min_arr - launch,
                                       ", ".join("%.3f" % c[0] for c in sorted(ctq)))
        hslack = min_arr + float(h["net_delay_min_ns"]) - float(h["hold_ns"]) - float(h["hold_req_ns"]) - capture
        if abs(hslack - float(h["hold_slack_ns"])) > TOL:
            return "FAIL %s: %s.%s hold slack %s where its arrival, hold and the %.3f ns SDF capture clock give " \
                   "%.3f" % (name, r["cell"], r["port"], h["hold_slack_ns"], capture, hslack)
        checked += 1
        early += capture - launch > 0.03
        late += capture - launch < -0.03
    if checked == 0:
        return "FAIL %s: no flop-to-flop row on a %s net" % (name, prefixes)
    if early == 0 or late == 0:
        return "FAIL %s: of %d flop-to-flop row(s), %d capture later and %d earlier than launch by 30 ps; the arm " \
               "needs both" % (name, checked, early, late)
    return "PASS %s: %d flop-to-flop row(s), %d with the capture clock later and %d earlier than the launch " \
           "clock, take the SDF launch clock-pin delay into the setup and hold arrival and the SDF capture " \
           "clock-pin delay into both requirements" % (name, checked, early, late)


def grade_srl_launch(argv):
    routed, setup_tsv, hold_tsv, sdf_path, timings, tilegrid, drv, name = argv
    group, q_of, bel = netlist(routed)
    with open(routed) as f:
        top = json.load(f)["modules"]["top"]
    cells = top["cells"]
    _, srows = read_tsv(setup_tsv)
    hcols, hrows = read_tsv(hold_tsv)
    if hcols is None:
        return "FAIL %s: no NEXTPNR_HOLD_EXPORT file was written" % name
    clk = sdf_clock_pins(sdf_path)
    if not clk:
        return "FAIL %s: no clock-pin INTERCONNECT in %s" % (name, os.path.basename(sdf_path))
    cell = cells.get(drv, {})
    attrs = cell.get("attributes", {})
    if cell.get("type") != "SLICE_LUTX" or not ("X_LUT_AS_SRL" in attrs or "X_LUT_AS_DRAM" in attrs):
        return "FAIL %s: cell %s is not an SRL or LUTRAM (type %s)" % (name, drv, cell.get("type"))
    if drv not in clk:
        return "FAIL %s: the SDF gives no clock-pin delay for %s" % (name, drv)
    launch = clk[drv]
    if launch < 0.1:
        return "FAIL %s: %s has a clock-pin delay of %.3f ns, so its clock is not routed" % (name, drv, launch)
    sdf = Sdf(timings, tilegrid)
    tiletype, sitetype, b = sdf.locate(bel.get(drv, ""))
    lut5 = (b or "").endswith("5LUT")
    variant = "LUT_OR_MEM%d%s" % (5 if lut5 else 6, "SHFREG" if "X_LUT_AS_SRL" in attrs else "LRAM")
    out = "O5" if lut5 else "O6"
    arc = sdf.cells(tiletype or "").get(("%s/%s" % (sitetype, b), variant), {}).get(("CLK", out))
    if arc is None:
        return "FAIL %s: the SDF of %s has no %s/%s %s CLK->%s arc" % (name, tiletype, sitetype, b, variant, out)
    obits = {b for b in cell["connections"].get(out, []) if isinstance(b, int)}
    nets = {n for n, nn in top["netnames"].items() if obits & {b for b in nn["bits"] if isinstance(b, int)}}
    rows = [r for r in srows if r["net"] in nets]
    if not rows:
        return "FAIL %s: no setup row on the %s output of %s (net %s)" % (name, out, drv,
                                                                       "/".join(sorted(nets)) or "none")
    netname = rows[0]["net"]
    hold = {(r["cell"], r["port"]): r for r in hrows}
    for r in rows:
        arrival = float(r["driver_arrival_ns"])
        if abs(arrival - launch - arc[1]) > TOL:
            return "FAIL %s: %s drives %s at %.3f ns where its %.3f ns SDF clock-pin delay and the %s CLK->%s " \
                   "max %.3f give %.3f" % (name, drv, netname, arrival, launch, variant, out, arc[1],
                                           launch + arc[1])
        capture = clk.get(r["cell"])
        if capture is None:
            return "FAIL %s: the SDF gives no clock-pin delay for the capture cell %s" % (name, r["cell"])
        slack = float(r["period_ns"]) - (arrival + float(r["net_delay_ns"]) + float(r["setup_ns"]) - capture)
        if abs(slack - float(r["slack_ns"])) > TOL:
            return "FAIL %s: %s.%s setup slack %s where period, arrival, setup and the %.3f ns SDF capture clock " \
                   "give %.3f" % (name, r["cell"], r["port"], r["slack_ns"], capture, slack)
        h = hold.get((r["cell"], r["port"]))
        if h is None:
            return "FAIL %s: no hold row for %s.%s" % (name, r["cell"], r["port"])
        min_arr = float(h["driver_min_arrival_ns"])
        if abs(min_arr - launch - arc[0]) > TOL:
            return "FAIL %s: %s.%s hold arrival %.3f ns where the %.3f ns SDF launch clock and the %s CLK->%s " \
                   "min %.3f give %.3f" % (name, r["cell"], r["port"], min_arr, launch, variant, out, arc[0],
                                           launch + arc[0])
    return "PASS %s: %d row(s) on %s take %s's %.3f ns SDF clock-pin delay plus the %s CLK->%s max %.3f and " \
           "min %.3f into the setup and hold arrival" % (name, len(rows), netname, drv, launch, variant, out, arc[1],
                                                          arc[0])


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
           "norow": grade_norow, "zero_min": grade_zero_min, "srl_launch": grade_srl_launch}[cmd](argv))


main()
