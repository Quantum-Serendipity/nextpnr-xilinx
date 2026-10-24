#!/usr/bin/env python3
import csv
import json
import sys


def main():
    routed, setup_tsv, log = sys.argv[1:4]
    top = json.load(open(routed))["modules"]["top"]
    q_net = {}
    for name, nn in top["netnames"].items():
        if name in ("q_cas", "q_ref"):
            for b in nn["bits"]:
                if isinstance(b, int):
                    q_net[b] = name
    ff_of = {}
    for cname, cell in top["cells"].items():
        q = cell["connections"].get("Q", [])
        if q and isinstance(q[0], int) and q[0] in q_net:
            ff_of[cname] = q_net[q[0]]
    arrival = {}
    for r in csv.DictReader(open(setup_tsv), delimiter="\t"):
        reg = ff_of.get(r["cell"])
        if reg is not None and r["port"] == "D":
            arrival[reg] = max(arrival.get(reg, -1e9), float(r["driver_arrival_ns"]))
    rc = 0
    if set(arrival) != {"q_cas", "q_ref"}:
        print("FAIL cascade clock-to-out: setup rows found for %s, want q_cas and q_ref" % sorted(arrival))
        rc = 1
    else:
        d = arrival["q_cas"] - arrival["q_ref"]
        if 0.65 <= d <= 0.85:
            print("PASS cascade clock-to-out: the cascade upper half's DO arrives %.3f ns after an unextended "
                  "RAMB36's (DS181 -2 TRCKO_DO_CASCOUT 2.88 - TRCKO_DO 2.13 = 0.75)" % d)
        else:
            print("FAIL cascade clock-to-out: the cascade upper half's DO arrives %.3f ns after an unextended "
                  "RAMB36's, want 0.75 +- 0.10" % d)
            rc = 1
    text = open(log).read()
    if "block RAM: clock-to-out, setup and hold are DS181 v1.25 Table 30 -2 literals" in text:
        print("PASS grade log: the run names the block RAM literals' data-sheet table and speed grade")
    else:
        print("FAIL grade log: no 'block RAM: ... DS181 v1.25 Table 30 -2' line in the nextpnr log")
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
