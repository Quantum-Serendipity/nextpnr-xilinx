#!/usr/bin/env python3
import json
import sys

WANT = {
    "r18": ({"REGCLKARDRCLK", "REGCLKB"}, set()),
    "r36t": ({"REGCLKBL", "REGCLKBU"}, {"REGCLKARDRCLKL", "REGCLKARDRCLKU"}),
    "r36s": ({"REGCLKARDRCLKL", "REGCLKARDRCLKU"}, {"REGCLKBL", "REGCLKBU"}),
}


def main():
    routed, fasm = sys.argv[1:3]
    top = json.load(open(routed))["modules"]["top"]
    clk_bits = set()
    for name, nn in top["netnames"].items():
        if name == "clk":
            clk_bits = {b for b in nn["bits"] if isinstance(b, int)}
    rc = 0
    found = set()
    for cname, cell in top["cells"].items():
        key = next((k for k in WANT if cname == k or cname.endswith("." + k) or cname.endswith("/" + k)), None)
        if key is None or not cell["type"].startswith("RAMB"):
            continue
        found.add(key)
        conns = cell["connections"]
        on_clk = {p for p, bits in conns.items() if p.startswith("REGCLK") and bits and bits[0] in clk_bits}
        any_regclk = {p for p, bits in conns.items() if p.startswith("REGCLK") and bits and isinstance(bits[0], int)}
        want_on, want_off = WANT[key]
        if want_on <= on_clk and not (any_regclk & want_off):
            print("PASS %s: output-register clock pins %s on the port clock, %s without a net"
                  % (key, " ".join(sorted(want_on)), " ".join(sorted(want_off)) or "none required"))
        else:
            print("FAIL %s: on the clock %s, with any net %s; want %s on the clock and %s without a net"
                  % (key, sorted(on_clk), sorted(any_regclk), sorted(want_on), sorted(want_off)))
            rc = 1
    for k in sorted(set(WANT) - found):
        print("FAIL %s: no such block RAM cell in the routed netlist" % k)
        rc = 1
    routing = ""
    for name, nn in top["netnames"].items():
        if name == "clk":
            routing = nn.get("attributes", {}).get("ROUTING", "")
    n_regclk = sum(1 for w in routing.split(";") if w.endswith("REGCLKARDRCLK") or w.endswith("REGCLKB")
                   or w[-1:] in "LU" and ("REGCLKARDRCLK" in w or "REGCLKB" in w))
    if n_regclk >= 6:
        print("PASS clock routing: the clock net's routing reaches %d output-register clock site wire(s)" % n_regclk)
    else:
        print("FAIL clock routing: the clock net's routing reaches %d output-register clock site wire(s), want 6"
              % n_regclk)
        rc = 1
    zinv = [l for l in open(fasm) if "ZINV_REGCLKB" in l]
    print(("PASS" if len(zinv) == 3 else "FAIL")
          + " ZINV_REGCLKB: %d line(s) (r18 and both halves of r36t; none for the SDP r36s)" % len(zinv))
    if len(zinv) != 3:
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
