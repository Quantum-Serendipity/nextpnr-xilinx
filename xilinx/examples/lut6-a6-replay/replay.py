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


def init_bit(c, i):
    s = c["parameters"]["INIT"]
    return s[len(s) - 1 - i] == "1" if i < len(s) else False


def labels(c, pin):
    return [t for t in str(c["attributes"].get("X_ORIG_PORT_" + pin, "")).split(" ") if t]


def net_names(m):
    out = {"1": VCC, "0": "$PACKER_GND_NET"}
    for name, ni in m["netnames"].items():
        for b in ni["bits"]:
            if isinstance(b, int):
                out.setdefault(b, name)
    return out


def pin_net(c, pin, names):
    b = (c["connections"].get(pin) or [None])[0]
    return None if b is None else names[b]


def pin_value(c, pin, env, names):
    n = pin_net(c, pin, names)
    if n is None or n == VCC:
        return 1
    if n == "$PACKER_GND_NET":
        return 0
    return env[n]


def logical(c, env, names):
    idx = 0
    for k in range(1, 7):
        if pin_value(c, "A%d" % k, env, names):
            for t in labels(c, "A%d" % k):
                idx |= 1 << int(t[1:])
    return init_bit(c, idx)


def physical_word(c6, c5):
    bits = [False] * 64
    for i, c in ((0, c6), (1, c5)):
        lo, hi = (32 * (1 - i), 32 * (2 - i)) if c6 is not None and c5 is not None else (0, 64)
        for j in range(lo, hi):
            idx = 0
            for k in range(6):
                if j & (1 << k):
                    for t in labels(c, "A%d" % (k + 1)):
                        idx |= 1 << int(t[1:])
            bits[j] = init_bit(c, idx)
    return bits


def func(src, dst):
    ms, md = top(json.load(open(src))), top(json.load(open(dst)))
    ns, nd = net_names(ms), net_names(md)
    consts = (None, VCC, "$PACKER_GND_NET")
    bad, checked = [], 0
    for n6, n5 in pairs(md):
        c6, c5 = md["cells"][n6], md["cells"][n5]
        word = physical_word(c6, c5)
        for name, c, five in ((n6, c6, False), (n5, c5, True)):
            s = ms["cells"][name]
            pins = ["A%d" % k for k in range(1, 7)]
            nets = sorted((set(pin_net(s, p, ns) for p in pins) | set(pin_net(c, p, nd) for p in pins))
                          - set(consts))
            for v in range(1 << len(nets)):
                env = dict((n, (v >> i) & 1) for i, n in enumerate(nets))
                addr = sum(pin_value(c, "A%d" % k, env, nd) << (k - 1) for k in range(1, 6))
                if not five:
                    addr |= pin_value(c, "A6", env, nd) << 5
                if word[addr] != logical(s, env, ns):
                    bad.append("%s computes a different function after the replay" % name)
                    break
            checked += 1
    for b in bad:
        print(b)
    print("cells %d differ %d" % (checked, len(bad)))
    return 0 if checked and not bad else 1


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
    if mode in ("labelled", "real6"):
        for k, (n6, n5) in enumerate(ps):
            c6 = m["cells"][n6]
            half = c6["parameters"]["INIT"].rjust(32, "0")
            c6["parameters"]["INIT"] = half + "".join("1" if b == "0" else "0" for b in half)
            c6["attributes"]["X_ORIG_TYPE"] = "LUT6"
            c6["attributes"]["X_ORIG_PORT_A6"] = "I5"
            if mode == "real6":
                other = m["cells"][ps[(k + 1) % len(ps)][0]]
                own = set(inputs(c6, ["A1", "A2", "A3", "A4", "A5"]))
                spare = [b for b in inputs(other, ["A1", "A2", "A3", "A4", "A5"]) if b not in own]
                if not spare:
                    sys.exit("real6: no net outside pair %s to borrow" % n6)
                c6["connections"]["A6"] = [spare[0]]
    json.dump(doc, open(dst, "w"))
    print("%s: %d pair(s)" % (mode, len(ps)))
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "grade":
        sys.exit(grade(sys.argv[2], int(sys.argv[3])))
    if sys.argv[1] == "func":
        sys.exit(func(sys.argv[2], sys.argv[3]))
    sys.exit(make(sys.argv[1], sys.argv[2], sys.argv[3]))
