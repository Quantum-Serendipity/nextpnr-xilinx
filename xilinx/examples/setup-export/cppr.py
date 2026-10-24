#!/usr/bin/env python3
import csv
import json
import re
import sys

TOL = 0.0015
LEAF_TAIL_SPREAD = 0.031
LEAF_TAIL = [r"^SITEPIP/[^/]+/CLKINV/CLK$", r"->SITEWIRE/[^/]+/CLK$", r"/CLK_?L?[01]->", r"/GCLK_\w+->[^/]+/CLK"]


def main():
    routed, setup_tsv, hold_tsv = sys.argv[1:4]
    top = json.load(open(routed))["modules"]["top"]
    routing = top["netnames"]["clk"]["attributes"]["ROUTING"].split(";")
    pip_of = {routing[i]: routing[i + 1] for i in range(0, len(routing) - 2, 3)}

    def src_of(pip):
        if "->" in pip:
            return pip.split("->")[0]
        parts = pip.split("/")
        return "SITEWIRE/%s/%s" % (parts[1], parts[3])

    def path(site):
        wire = "SITEWIRE/%s/CLKINV_OUT" % site
        out = []
        while wire in pip_of and len(out) <= len(pip_of):
            out.append((wire, pip_of[wire]))
            if not pip_of[wire]:
                break
            wire = src_of(pip_of[wire])
        return out

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
    setup = {(r["cell"], r["port"]): r for r in csv.DictReader(open(setup_tsv), delimiter="\t")}
    counts = {"same-site": 0, "leaf": 0, "higher": 0}
    worst_ratio = [1.0, 0.0]
    for h in csv.DictReader(open(hold_tsv), delimiter="\t"):
        launch = net_driver.get(h["net"])
        s = setup.get((h["cell"], h["port"]))
        if launch is None or h["cell"] not in ff or s is None or h["delay_source"] != "routed":
            continue
        lmax, lmin = float(s["launch_clk_delay_ns"]), float(h["launch_clk_delay_ns"])
        spread, cppr = lmax - lmin, float(h["cppr_ns"])
        ratio = spread / lmax
        worst_ratio = [min(worst_ratio[0], ratio), max(worst_ratio[1], ratio)]
        if not 0.08 <= ratio <= 0.11:
            print("FAIL hold CPPR: %s launch clock spread %.3f of %.3f ns (ratio %.3f) is not the clock-network "
                  "figure (0.9 of the slow corner on every hop)" % (launch, spread, lmax, ratio))
            return 1
        lp, cp = path(site_of[launch]), path(site_of[h["cell"]])
        if not lp or not cp or lp[-1][1] or cp[-1][1]:
            print("FAIL hold CPPR: no complete clock route from %s or %s to the clock source" % (launch, h["cell"]))
            return 1
        cwires = {w for w, _ in cp}
        div = next(i for i, (w, _) in enumerate(lp) if w in cwires)
        if site_of[launch] == site_of[h["cell"]]:
            old = (float(h["driver_min_arrival_ns"]) - lmin + lmax + float(h["net_delay_min_ns"]) - float(h["hold_ns"])
                   - float(h["hold_req_ns"]) - float(h["capture_clk_delay_ns"]))
            if abs(cppr - spread) > TOL or abs(float(h["hold_slack_ns"]) - old) > TOL:
                print("FAIL hold CPPR: same-site pair %s -> %s: cppr %.3f against spread %.3f, slack %s against the "
                      "slow-launch slack %.3f" % (launch, h["cell"], cppr, spread, h["hold_slack_ns"], old))
                return 1
            counts["same-site"] += 1
        elif div == 4 and all(re.search(p, lp[i][1]) for i, p in enumerate(LEAF_TAIL)):
            want = spread - LEAF_TAIL_SPREAD
            if abs(cppr - want) > TOL:
                print("FAIL hold CPPR: %s -> %s diverge at %s: cppr %.3f, hand-computed %.3f (launch spread %.3f less "
                      "the %.3f ns leaf tail)" % (launch, h["cell"], lp[div][0], cppr, want, spread, LEAF_TAIL_SPREAD))
                return 1
            counts["leaf"] += 1
        else:
            if cppr > spread - LEAF_TAIL_SPREAD + TOL:
                print("FAIL hold CPPR: %s -> %s diverge %d hop(s) above the launch pin at %s, yet cppr %.3f is not "
                      "below the launch spread %.3f by the %.3f ns leaf tail" % (launch, h["cell"], div, lp[div][0],
                                                                                cppr, spread, LEAF_TAIL_SPREAD))
                return 1
            counts["higher"] += 1
    if counts["same-site"] == 0 or counts["leaf"] == 0:
        print("FAIL hold CPPR: pairs graded %s; the arm needs at least one same-site and one leaf pair" % counts)
        return 1
    print("PASS hold CPPR: %d same-site pair(s) with cppr equal to the launch spread and the slow-launch slack, %d "
          "pair(s) diverging at an INT-tile clock leaf with cppr equal to the launch spread less the hand-computed "
          "%.3f ns tail, %d diverging higher with cppr below that; launch spread / launch delay %.3f-%.3f"
          % (counts["same-site"], counts["leaf"], LEAF_TAIL_SPREAD, counts["higher"], worst_ratio[0], worst_ratio[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
