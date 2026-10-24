#!/usr/bin/env python3
import csv
import json
import sys

TOL = 0.0015
CLOCK_INTENTS = {"GLOBAL", "BUFGROUT"}
GENERAL_INTENTS = {"SINGLE", "DOUBLE", "HQUAD", "VQUAD", "HLONG", "VLONG", "VLONG12", "BENTQUAD", "SLOWSINGLE",
                   "BOUNCEIN", "BOUNCEACROSS", "PINBOUNCE", "OUTBOUND", "LUTINPUT", "GENERIC"}


def main():
    routed, setup_tsv, hold_tsv, hops_tsv, mode = sys.argv[1:6]
    hop = {}
    for line in open(hops_tsv):
        w, pip, src, st, dt, mx, mn = line.rstrip("\n").split("\t")
        hop[w] = dict(pip=pip, src=src, types=(st, dt), max=int(mx), min=int(mn))
    top = json.load(open(routed))["modules"]["top"]
    drivers, site_of, ff = {}, {}, set()
    for cname, cell in top["cells"].items():
        site_of[cname] = cell.get("attributes", {}).get("NEXTPNR_BEL", "").split("/")[0]
        if cell["type"] == "SLICE_FFX":
            ff.add(cname)
            for b in cell["connections"].get("Q", []):
                if isinstance(b, int):
                    drivers[b] = cname
    net_driver = {}
    for name, nn in top["netnames"].items():
        bits = [b for b in nn["bits"] if isinstance(b, int)]
        if len(bits) == 1 and bits[0] in drivers:
            net_driver[name] = drivers[bits[0]]

    def path(site):
        w, out = "SITEWIRE/%s/CLKINV_OUT" % site, []
        while w in hop and len(out) <= len(hop):
            out.append(w)
            if not hop[w]["pip"]:
                return out
            w = hop[w]["src"]
        return None

    def profile(p):
        kinds, kind = [], 0
        for w in reversed(p):
            types = set(hop[w]["types"])
            k = 1 if types & GENERAL_INTENTS else 2 if types & CLOCK_INTENTS else 0
            kind = k or kind
            kinds.append(kind)
        kinds.reverse()
        up = {}
        mx = mn = 0
        for w, k in reversed(list(zip(p, kinds))):
            h = hop[w]
            mx += h["max"]
            mn += int(h["max"] * 0.9) if k == 2 else h["min"]
            up[w] = (mx, mn)
        return up, kinds

    setup = {(r["cell"], r["port"]): r for r in csv.DictReader(open(setup_tsv), delimiter="\t")}
    n = {"rows": 0, "same-site": 0, "shared": 0, "clock-hops": 0, "fabric-hops": 0}
    for h in csv.DictReader(open(hold_tsv), delimiter="\t"):
        launch = net_driver.get(h["net"])
        s = setup.get((h["cell"], h["port"]))
        if launch is None or h["cell"] not in ff or s is None or h["delay_source"] != "routed":
            continue
        lp, cp = path(site_of[launch]), path(site_of[h["cell"]])
        if lp is None or cp is None:
            print("FAIL hold CPPR " + mode + ": no complete clock route from %s or %s to the clock source" % (launch, h["cell"]))
            return 1
        lup, lkinds = profile(lp)
        cup, _ = profile(cp)
        lmax, lmin = lup[lp[0]]
        if abs(float(s["launch_clk_delay_ns"]) - lmax / 1000) > TOL or \
                abs(float(h["launch_clk_delay_ns"]) - lmin / 1000) > TOL:
            print("FAIL hold CPPR " + mode + ": %s launch clock %s / %s ns where its hops give %.3f / %.3f (clock-network hops at "
                  "0.9 of slow, general-interconnect hops at their own fast corner)"
                  % (launch, s["launch_clk_delay_ns"], h["launch_clk_delay_ns"], lmax / 1000, lmin / 1000))
            return 1
        div = next(w for w in lp if w in cup)
        want = (lup[div][0] - lup[div][1]) / 1000
        if abs(float(h["cppr_ns"]) - want) > TOL:
            print("FAIL hold CPPR " + mode + ": %s -> %s diverge at %s: cppr %s, its shared hops give %.3f" % (
                launch, h["cell"], div, h["cppr_ns"], want))
            return 1
        n["rows"] += 1
        n["clock-hops"] += sum(1 for w, k in zip(lp, lkinds) if k == 2 and hop[w]["pip"])
        n["fabric-hops"] += sum(1 for w, k in zip(lp, lkinds) if k != 2 and hop[w]["pip"])
        n["same-site" if site_of[launch] == site_of[h["cell"]] else "shared"] += 1
    if n["rows"] == 0:
        print("FAIL hold CPPR %s: no FF-to-FF hold row" % mode)
        return 1
    if mode == "bufg" and (n["clock-hops"] == 0 or n["same-site"] == 0 or n["shared"] == 0):
        print("FAIL hold CPPR bufg: %s; the arm needs clock-network hops, a same-site pair and a cross-site pair" % n)
        return 1
    if mode == "fabric" and n["clock-hops"] != 0:
        print("FAIL hold CPPR fabric: %d launch hop(s) classed as clock network on a clock with no BUFG" % n["clock-hops"])
        return 1
    print("PASS hold CPPR %s: %d FF-to-FF hold row(s) (%d same-site, %d cross-site): every launch clock min and every "
          "cppr equals the figure computed from the routed clock hops (%d clock-network hop(s) at 0.9 of slow, %d "
          "general-interconnect hop(s) at their own fast corner)"
          % (mode, n["rows"], n["same-site"], n["shared"], n["clock-hops"], n["fabric-hops"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
