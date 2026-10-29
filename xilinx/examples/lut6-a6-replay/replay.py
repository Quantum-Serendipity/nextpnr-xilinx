import json
import re
import sys

VCC = "$PACKER_VCC_NET"
LUT_BEL = re.compile(r"(.*)/([A-D])([56])LUT")


def top(doc):
    return doc["modules"]["top"]


def vcc_bits(m):
    return set(b for b in m["netnames"].get(VCC, {}).get("bits", []) if isinstance(b, int))


def pairs(m):
    out = []
    for name, c in sorted(m["cells"].items()):
        if c["type"] == "SLICE_LUTX" and name.endswith("$LUT6"):
            mate = name[: -len("$LUT6")] + "$LUT5"
            if mate in m["cells"]:
                out.append((name, mate))
    return out


def inputs(c, ports):
    return [c["connections"][p][0] for p in ports if c["connections"].get(p)]


def drop(c, port):
    c["connections"].pop(port, None)
    c["port_directions"].pop(port, None)


def grade(path, want_pairs):
    m = top(json.load(open(path)))
    vcc = vcc_bits(m)
    ps = pairs(m)
    bad = []
    for n6, n5 in ps:
        c6, c5 = m["cells"][n6], m["cells"][n5]
        b6 = LUT_BEL.fullmatch(c6["attributes"].get("NEXTPNR_BEL", ""))
        b5 = LUT_BEL.fullmatch(c5["attributes"].get("NEXTPNR_BEL", ""))
        if not b6 or not b5 or b6.group(3) != "6" or b5.group(3) != "5" or b6.group(1, 2) != b5.group(1, 2):
            bad.append("%s/%s not one slot: %s %s" % (n6, n5, c6["attributes"].get("NEXTPNR_BEL"),
                                                      c5["attributes"].get("NEXTPNR_BEL")))
            continue
        a6 = c6["connections"].get("A6") or [None]
        if a6[0] not in vcc:
            bad.append("%s A6 is not on %s" % (n6, VCC))
        low = set(inputs(c6, ["A1", "A2", "A3", "A4", "A5"]))
        if low & vcc:
            bad.append("%s carries %s on an A1..A5 pin" % (n6, VCC))
        if len(low | set(inputs(c5, ["A1", "A2", "A3", "A4", "A5"]))) > 5:
            bad.append("%s/%s use more than five A1..A5 nets" % (n6, n5))
    for b in bad:
        print(b)
    print("pairs %d bad %d" % (len(ps), len(bad)))
    return 0 if len(ps) == want_pairs and not bad else 1


def make(mode, src, dst):
    doc = json.load(open(src))
    m = top(doc)
    for c in m["cells"].values():
        if c["type"] == "SLICE_LUTX":
            c["attributes"].pop("NEXTPNR_BEL", None)
            c["attributes"].pop("BEL_STRENGTH", None)
    for ni in m["netnames"].values():
        ni.get("attributes", {}).pop("ROUTING", None)
    ps = pairs(m)
    if mode in ("narrow", "wide"):
        for k, (n6, n5) in enumerate(ps):
            c6, c5 = m["cells"][n6], m["cells"][n5]
            drop(c6, "A4")
            drop(c6, "A5")
            drop(c5, "A1")
            drop(c5, "A2")
            if mode == "wide":
                other = m["cells"][ps[(k + 1) % len(ps)][1]]
                own = set(inputs(c6, ["A1", "A2", "A3"])) | set(inputs(c5, ["A3", "A4", "A5"]))
                spare = [b for b in inputs(other, ["A1", "A2", "A3", "A4", "A5"]) if b not in own]
                if not spare:
                    sys.exit("wide: no net outside pair %s to borrow" % n6)
                c5["connections"]["A1"] = [spare[0]]
                c5["port_directions"]["A1"] = "input"
    json.dump(doc, open(dst, "w"))
    print("%s: %d pair(s)" % (mode, len(ps)))
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "grade":
        sys.exit(grade(sys.argv[2], int(sys.argv[3])))
    sys.exit(make(sys.argv[1], sys.argv[2], sys.argv[3]))
