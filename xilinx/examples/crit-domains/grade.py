#!/usr/bin/env python3
import csv
import json
import re
import sys


def main():
    routed, crit_tsv, floor = sys.argv[1], sys.argv[2], float(sys.argv[3])
    regs = sys.argv[4].split(",") if len(sys.argv) > 4 else ["x_q", "y_q"]
    top = json.load(open(routed))["modules"]["top"]
    bit_reg = {}
    for name, nn in top["netnames"].items():
        m = re.fullmatch(r"([a-z]+_q)(\[\d+\])?", name)
        if m and m.group(1) in regs:
            for b in nn["bits"]:
                if isinstance(b, int):
                    bit_reg[b] = m.group(1)
    drivers = {}
    for cname, cell in top["cells"].items():
        dirs = cell.get("port_directions", {})
        for port, bits in cell["connections"].items():
            if dirs.get(port) == "output":
                for b in bits:
                    if isinstance(b, int):
                        drivers[b] = cname
    crit = {}
    with open(crit_tsv) as f:
        for row in csv.reader(f, delimiter="\t"):
            crit[row[0]] = float(row[1])
    seen = {r: [] for r in regs}
    for cname, cell in top["cells"].items():
        q = cell["connections"].get("Q", [])
        if not q or not isinstance(q[0], int) or q[0] not in bit_reg:
            continue
        d = cell["connections"].get("D", [])
        if not d or not isinstance(d[0], int) or d[0] not in drivers:
            continue
        seen[bit_reg[q[0]]].append(crit.get(drivers[d[0]], 0.0))
    rc = 0
    for reg, vals in sorted(seen.items()):
        vals.sort()
        if len(vals) != 8:
            print("FAIL %s: found %d of 8 capture registers" % (reg, len(vals)))
            rc = 1
        elif vals[0] < floor:
            print("FAIL %s: lowest D-net driver criticality %.3f is under %.2f (all: %s)"
                  % (reg, vals[0], floor, " ".join("%.3f" % v for v in vals)))
            rc = 1
        else:
            print("PASS %s: every D-net driver criticality is at least %.2f (lowest %.3f)" % (reg, floor, vals[0]))
    return rc


if __name__ == "__main__":
    sys.exit(main())
