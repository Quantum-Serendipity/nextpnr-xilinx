#!/usr/bin/env python3
import csv
import json
import re
import sys


def groups_of(routed):
    with open(routed) as f:
        top = json.load(f)["modules"]["top"]
    names = {}
    for name, nn in top["netnames"].items():
        if name.startswith("$"):
            continue
        for bit in nn["bits"]:
            if isinstance(bit, int):
                names.setdefault(bit, set()).add(name)
    group = {}
    for cname, cell in top["cells"].items():
        for port in ("Q",):
            bits = cell["connections"].get(port, [])
            if bits and isinstance(bits[0], int):
                cand = sorted(re.sub(r"\[.*", "", n) for n in names.get(bits[0], ()))
                if cand:
                    group[cname] = cand[0]
    return group


def rows_of(path, group):
    out = {}
    with open(path) as f:
        for r in csv.DictReader(f, delimiter="\t"):
            g = group.get(r["cell"], "?")
            out.setdefault(g, []).append(
                (r["cell"], r["port"], float(r["slack_ns"]), float(r["period_ns"]), r["launch_clk"], r["capture_clk"])
            )
    for g in out:
        out[g].sort()
    return out


def summary(log):
    with open(log) as f:
        for line in f:
            m = re.search(r"(\d+) endpoint check\(s\) excluded from setup, (\d+) from hold, (\d+) graded", line)
            if m:
                return tuple(int(x) for x in m.groups())
    return None


def main():
    routed, base_tsv, var_tsv, var_log, name = sys.argv[1:6]
    group = groups_of(routed)
    base = rows_of(base_tsv, group)
    var = rows_of(var_tsv, group)
    fails = []

    def count(rows, g):
        return len(rows.get(g, []))

    def same(*gs):
        for g in gs:
            if base.get(g, []) != var.get(g, []):
                fails.append("%s differs from the base analysis (%d rows -> %d)" % (g, count(base, g), count(var, g)))

    def gone(g):
        if count(var, g):
            fails.append("%s still has %d row(s)" % (g, count(var, g)))

    def relaxed(g):
        b = {(r[0], r[1]): r[2] for r in base.get(g, [])}
        v = {(r[0], r[1]): r[2] for r in var.get(g, [])}
        if set(b) != set(v):
            fails.append("%s endpoint set changed (%d -> %d)" % (g, len(b), len(v)))
            return
        if any(v[k] < b[k] for k in b):
            fails.append("%s: a slack got worse" % g)
        if not any(v[k] > b[k] for k in b):
            fails.append("%s: no slack improved, so the excluded launch was not the worst one" % g)

    everything = sorted(set(base) | set(var))
    if name == "base":
        for g in ("dst_slow", "dst_fast", "dst_mid", "dst_b"):
            if not count(base, g):
                fails.append("base analysis has no %s rows" % g)
        if not any(r[2] < 0 for r in base.get("dst_slow", [])):
            fails.append("base dst_slow has no negative slack, so the design does not exercise exclusion")
        if not any(r[2] < 0 for r in base.get("dst_b", [])):
            fails.append("base dst_b has no negative slack, so the design does not exercise exclusion")
        if not any(r[4] != r[5] for r in base.get("dst_b", [])):
            fails.append("base dst_b rows are not cross-clock")
    elif name in ("groups", "groups_single", "fp_clocks"):
        gone("dst_b")
        same(*[g for g in everything if g != "dst_b"])
    elif name in ("fp_clocks_reversed", "fp_nomatch"):
        same(*everything)
    elif name == "fp_from_to":
        relaxed("dst_slow")
        same(*[g for g in everything if g != "dst_slow"])
    elif name == "fp_from":
        gone("dst_b")
        relaxed("dst_slow")
        same(*[g for g in everything if g not in ("dst_b", "dst_slow")])
    elif name in ("fp_to", "precedence"):
        gone("dst_slow")
        same(*[g for g in everything if g != "dst_slow"])
    elif name == "fp_setup_only":
        gone("dst_slow")
        same(*[g for g in everything if g != "dst_slow"])
        s = summary(var_log)
        if s is None or s[0] == 0 or s[1] != 0:
            fails.append("summary line %r does not show setup-only exclusion" % (s,))
    elif name == "fp_pins":
        gone("dst_fast")
        same(*[g for g in everything if g != "dst_fast"])
    elif name == "fp_through":
        gone("dst_mid")
        same(*[g for g in everything if g != "dst_mid"])
    elif name == "maxdelay_cdc":
        rows = var.get("dst_b", [])
        if count(var, "dst_b") != count(base, "dst_b"):
            fails.append("dst_b row count changed")
        if not rows or any(abs(r[3] - 30.0) > 1e-3 for r in rows):
            fails.append("dst_b rows are not graded against 30 ns")
        if any(r[2] <= 0 for r in rows):
            fails.append("dst_b has a non-positive slack against 30 ns")
        same(*[g for g in everything if g != "dst_b"])
    elif name == "maxdelay_tight":
        rows = var.get("dst_slow", [])
        tight = [r for r in rows if abs(r[3] - 0.5) < 1e-3]
        ends = {(r[0], r[1]) for r in base.get("dst_slow", [])}
        if {(r[0], r[1]) for r in tight} != ends:
            fails.append("not every dst_slow endpoint has a 0.5 ns row")
        if not tight or min(r[2] for r in tight) >= min(r[2] for r in base["dst_slow"]):
            fails.append("the 0.5 ns requirement did not tighten the worst dst_slow slack")
        same(*[g for g in everything if g != "dst_slow"])
    else:
        fails.append("no rule for variant %s" % name)

    neg = sum(1 for g in var for r in var[g] if r[2] < 0)
    print("%s %s: %s; %d rows, %d negative" % (
        "FAIL" if fails else "PASS", name, "; ".join(fails) if fails else "as expected",
        sum(len(v) for v in var.values()), neg))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
