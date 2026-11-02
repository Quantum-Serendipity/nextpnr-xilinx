#!/usr/bin/env python3
import argparse
import copy
import json
import re
import sys

GND = "$PACKER_GND_NET"
VCC = "$PACKER_VCC_NET"
EXPECTED_MASKS = {"r_both": 0b11000, "r_mixed": 0b01000, "r_vcc": 0b10000, "r64": 0b100000, "r_free": 0,
                  "r_unread": 0, "r_dfree": 0, "r_dunread": 0, "r64u": 0, "r_wide": 0, "r64s": 0}
SKIPPED = {"r_wide": "INIT_A one bit wider than the RAM", "r64s": "INIT_A a string"}
TIED_DI_WHEN_ON = {
    ("r_unread/DPR0_0", "DI1"): VCC, ("r_unread/DPR0_1", "DI2"): VCC,
    ("r_unread/DPR1_0", "DI1"): GND, ("r_unread/DPR1_1", "DI2"): GND,
    ("r_dunread/DPR2_0", "DI1"): GND, ("r_dunread/DPR2_1", "DI2"): GND,
    ("r_dunread/DPR3_0", "DI1"): VCC, ("r_dunread/DPR3_1", "DI2"): VCC,
    ("r64u/DPR0", "DI1"): VCC, ("r64u/DPR1", "DI1"): GND,
}
STRIPPED_PORT_A = [("ram/DPR0_0", "DI1"), ("ram/DPR0_1", "DI2")]
KNOB_KEY = "knob/dram_tie_unread_di"
TIE_LINE = r"Tied (\d+) tied-low RAM32M/RAM64M data inputs high whose outputs nothing reads"


def top_module(doc):
    for name, mod in doc["modules"].items():
        if "top" in mod.get("attributes", {}):
            return mod
    return doc["modules"]["top"]


def bits_lsb(value, width):
    if isinstance(value, int):
        return [(value >> i) & 1 for i in range(width)]
    s = str(value)
    if not s or not set(s) <= set("01xz"):
        raise ValueError("non-binary parameter %r" % s)
    s = s.rjust(width, "0")[-width:] if len(s) < width else s[-width:]
    return [1 if c == "1" else 0 for c in reversed(s)]


def bit_names(mod):
    names = {}
    for name, nn in mod["netnames"].items():
        offset = nn.get("offset", 0)
        for idx, b in enumerate(nn["bits"]):
            if isinstance(b, int):
                names.setdefault(b, set()).add(name if len(nn["bits"]) == 1 else "%s[%d]" % (name, idx + offset))
    return names


def net_names(mod):
    out = {}
    for name, nn in mod["netnames"].items():
        for b in nn["bits"]:
            if isinstance(b, int):
                out[b] = name
    return out


def pin_net(names, cell, pin):
    conn = cell["connections"].get(pin)
    if not conn:
        return None
    b = conn[0]
    if isinstance(b, int):
        return names.get(b, "#%d" % b)
    return {"0": GND, "1": VCC}.get(b, b)


class Design:
    def __init__(self, pre, packed):
        self.pre = top_module(pre)
        self.packed = top_module(packed)
        self.pre_names = bit_names(self.pre)
        self.packed_names = net_names(self.packed)

    def rams(self):
        return [(n, c) for n, c in sorted(self.pre["cells"].items()) if c["type"] in ("RAM32M", "RAM64M")]

    def pin_net(self, cell, pin):
        return pin_net(self.packed_names, cell, pin)

    def net_bit(self, name):
        return self.packed["netnames"][name]["bits"][0]


def role(design, pre_bit, net):
    if net == VCC:
        return ("const", 1)
    if net == GND:
        return ("const", 0)
    if isinstance(pre_bit, int) and net in design.pre_names.get(pre_bit, set()):
        return ("var", None)
    return ("bad", net)


def reachable(addr, abits):
    return [la for la in range(1 << abits)
            if not any(addr[i] in ("0", "1") and ((la >> i) & 1) != int(addr[i]) for i in range(abits))]


def physical(roles, la):
    phys = 0
    for i, (kind, val) in enumerate(roles):
        phys |= (val if kind == "const" else (la >> i) & 1) << i
    return phys


def grade(design, packed_cells=None):
    cells = design.packed["cells"] if packed_cells is None else packed_cells
    errors = []
    reads = 0
    subcells = 0
    masks = {}
    skipped = []
    for name, cell in design.rams():
        is64 = cell["type"] == "RAM64M"
        abits = 6 if is64 else 5
        width = 1 if is64 else 2
        addr = {p: cell["connections"]["ADDR%s" % p] for p in "ABCD"}
        try:
            inits = {p: bits_lsb(cell["parameters"].get("INIT_%s" % p, 0), 64) for p in "ABCD"}
        except ValueError:
            inits = None
            skipped.append(name)
        flipped = 0
        for p_idx, p in enumerate("ABCD"):
            for j in range(width):
                sub = "%s/DPR%d" % (name, p_idx) if is64 else "%s/DPR%d_%d" % (name, p_idx, j)
                if sub not in cells:
                    errors.append("%s: no packed subcell" % sub)
                    continue
                sc = cells[sub]
                rroles, wroles = [], []
                for i in range(abits):
                    rnet = design.pin_net(sc, "A%d" % (i + 1))
                    wnet = design.pin_net(sc, "WA%d" % (i + 1))
                    rroles.append(role(design, addr[p][i], rnet))
                    wroles.append(role(design, addr["D"][i], wnet))
                    if (addr[p][i] == "0" and rnet == VCC) or (addr["D"][i] == "0" and wnet == VCC):
                        flipped |= 1 << i
                bad = [r for r in rroles + wroles if r[0] == "bad"]
                if bad:
                    errors.append("%s: address pin on unexpected net %s" % (sub, bad[0][1]))
                    continue
                if inits is None:
                    continue
                subcells += 1
                sinit = bits_lsb(sc["parameters"].get("INIT", 0), 64 if is64 else 32)
                written = {}
                for la in reachable(addr["D"], abits):
                    wphys = physical(wroles, la)
                    if wphys in written:
                        errors.append("%s: logical write addresses %d and %d land on physical %d"
                                      % (sub, written[wphys], la, wphys))
                        break
                    written[wphys] = la
                for la in reachable(addr[p], abits):
                    phys = physical(rroles, la)
                    reads += 1
                    want = inits[p][la * width + j]
                    if sinit[phys] != want:
                        errors.append("%s: logical address %d reads physical %d = %d, want %d"
                                      % (sub, la, phys, sinit[phys], want))
                        break
                    if la in reachable(addr["D"], abits) and physical(wroles, la) != phys:
                        errors.append("%s: logical address %d is written at physical %d but read at %d"
                                      % (sub, la, physical(wroles, la), phys))
                        break
        masks[name] = flipped
    return errors, reads, subcells, masks, skipped


def permute(init_str, width, words, mask):
    old = bits_lsb(init_str, words * width)
    new = [0] * (words * width)
    for a in range(words):
        for j in range(width):
            new[(a ^ mask) * width + j] = old[a * width + j]
    return "".join(str(b) for b in reversed(new))


def mutate_no_permute(design, target):
    cells = copy.deepcopy(design.packed["cells"])
    cell = design.pre["cells"][target]
    for p_idx, p in enumerate("ABCD"):
        init = bits_lsb(cell["parameters"]["INIT_%s" % p], 64)
        for j in range(2):
            sub = cells["%s/DPR%d_%d" % (target, p_idx, j)]
            lane = [init[k * 2 + j] for k in range(32)]
            sub["parameters"]["INIT"] = "".join(str(b) for b in reversed(lane))
    return cells


def mutate_flip_bit(design, target, bit):
    cells = copy.deepcopy(design.packed["cells"])
    vcc_bit = design.net_bit(VCC)
    for p_idx in range(4):
        for j in range(2):
            sub = cells["%s/DPR%d_%d" % (target, p_idx, j)]
            sub["connections"]["A%d" % (bit + 1)] = [vcc_bit]
            sub["connections"]["WA%d" % (bit + 1)] = [vcc_bit]
            sub["parameters"]["INIT"] = permute(sub["parameters"]["INIT"], 1, 32, 1 << bit)
    return cells


def data_pins(design):
    out = {}
    for name, cell in design.rams():
        is64 = cell["type"] == "RAM64M"
        for p_idx, p in enumerate("ABCD"):
            di = cell["connections"].get("DI%s" % p, [])
            for j, b in enumerate(di):
                if b != "0":
                    continue
                sub = "%s/DPR%d" % (name, p_idx) if is64 else "%s/DPR%d_%d" % (name, p_idx, j)
                pin = "DI1" if is64 or j == 0 else "DI2"
                sc = design.packed["cells"].get(sub)
                out[(sub, pin)] = design.pin_net(sc, pin) if sc else None
    return out


def tie_count(log):
    m = re.search(TIE_LINE, open(log).read())
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["edit", "strip", "contents", "count", "skip-init", "data", "stripped",
                                     "same-as-unset", "mutant-no-permute", "mutant-driven-bit",
                                     "mutant-skip-port-d"])
    ap.add_argument("pre")
    ap.add_argument("packed")
    ap.add_argument("--log")
    ap.add_argument("--knob", choices=["on", "off"], default="off")
    a = ap.parse_args()

    if a.mode in ("edit", "strip"):
        doc = json.load(open(a.pre))
        mod = top_module(doc)
        if a.mode == "edit":
            mod["cells"]["r_wide"]["parameters"]["INIT_A"] = "1" + mod["cells"]["r_wide"]["parameters"]["INIT_A"]
            mod["cells"]["r64s"]["parameters"]["INIT_A"] = "NOT_BINARY"
            print("r_wide INIT_A widened to %d bits, r64s INIT_A made a string"
                  % len(mod["cells"]["r_wide"]["parameters"]["INIT_A"]))
        else:
            print("emptied %d top port(s): %s" % (len(mod["ports"]), " ".join(sorted(mod["ports"]))))
            mod["ports"] = {}
        json.dump(doc, open(a.packed, "w"))
        return 0

    if a.mode == "same-as-unset":
        unset = json.load(open(a.pre))
        explicit = json.load(open(a.packed))
        removed = []

        def drop(node, path):
            if isinstance(node, dict):
                for k in list(node):
                    if k == KNOB_KEY:
                        removed.append("%s=%s" % ("/".join(path + [k]), node.pop(k)))
                    else:
                        drop(node[k], path + [k])
            elif isinstance(node, list):
                for i, v in enumerate(node):
                    drop(v, path + [str(i)])

        drop(explicit, [])
        n = tie_count(a.log)
        values = [r.rsplit("=", 1)[1] for r in removed]
        if n is not None or values != ["off"] or explicit != unset:
            print("tie line count %s; echoed key(s) %s; packed netlists %s apart from them"
                  % (n, removed or "none", "equal" if explicit == unset else "DIFFER"))
            return 1
        print("--set %s=off: no tie line, and the packed netlist equals the unset run's once the one echoed "
              "setting (%s) is set aside" % (KNOB_KEY, removed[0]))
        return 0

    if a.mode == "stripped":
        pre = top_module(json.load(open(a.pre)))
        packed = top_module(json.load(open(a.packed)))
        names = net_names(packed)
        got = {sp: pin_net(names, packed["cells"].get(sp[0], {"connections": {}}), sp[1]) for sp in STRIPPED_PORT_A}
        doa = set(pre["cells"]["ram"]["connections"]["DOA"])
        users = sum(1 for c in pre["cells"].values() for p, bits in c["connections"].items()
                    if c.get("port_directions", {}).get(p) == "input" and set(bits) & doa)
        n = tie_count(a.log)
        want = VCC if a.knob == "on" else GND
        if pre["ports"] or users or set(got.values()) != {want} or (n is None) != (a.knob == "off"):
            print("ports %s, DOA readers %d, port A data pins %s, want all on %s; tie line count %s"
                  % (sorted(pre["ports"]), users, got, want, n))
            return 1
        if a.knob == "off":
            print("knob off: in the port-stripped netlist DOA has no reader and port A's tied-low DI1/DI2 stay on %s, "
                  "so a write stores the 0 the design writes over INIT_A's ones" % GND)
        else:
            print("knob on: the same netlist ties port A's DI1/DI2 to %s (tie line count %d), so a write stores 1 "
                  "where the design writes 0; the knob is unsafe wherever an unread DO is read outside the netlist"
                  % (VCC, n))
        return 0

    design = Design(json.load(open(a.pre)), json.load(open(a.packed)))

    if a.mode == "contents":
        errors, reads, subcells, _, skipped = grade(design)
        if errors or reads == 0:
            print("first: %s" % (errors[0] if errors else "no reads"))
            print("%d error(s) over %d subcell(s), %d logical read(s)" % (len(errors), subcells, reads))
            return 1
        print("%d RAM32M/RAM64M cell(s), %d subcell(s) graded, %d logical read(s) and their writes agree with the "
              "synthesised INIT, every write address map is one-to-one; not graded (string INIT): %s"
              % (len(design.rams()), subcells, reads, " ".join(skipped) or "none"))
        return 0

    if a.mode == "count":
        text = open(a.log).read()
        m = re.search(r"Transformed (\d+) tied-low DRAM address inputs to be tied-high "
                      r"\((\d+) address bit\(s\) of (\d+) RAM32M/RAM64M cell\(s\)\)", text)
        if not m:
            print("no transform count line in %s" % a.log)
            return 1
        total, nbits, ncells = (int(x) for x in m.groups())
        _, _, _, masks, _ = grade(design)
        want_bits = sum(bin(v).count("1") for v in EXPECTED_MASKS.values())
        want_cells = sum(1 for v in EXPECTED_MASKS.values() if v)
        wrong = {k: (bin(masks.get(k, 0)), bin(v)) for k, v in EXPECTED_MASKS.items() if masks.get(k, 0) != v}
        if wrong or nbits != want_bits or ncells != want_cells or total != nbits or nbits == 0:
            print("log total=%d bits=%d cells=%d, want bits=%d cells=%d; packed masks differing (got, want): %s"
                  % (total, nbits, ncells, want_bits, want_cells, wrong or "none"))
            return 1
        print("log total=%d bits=%d cells=%d, and the packed pins show the same flips: %s"
              % (total, nbits, ncells, " ".join("%s=%s" % (k, bin(masks[k])) for k in sorted(masks))))
        return 0

    if a.mode == "skip-init":
        _, _, _, masks, _ = grade(design)
        params = {n: design.pre["cells"][n]["parameters"]["INIT_A"] for n in SKIPPED}
        tied = {n: [i for i, b in enumerate(design.pre["cells"][n]["connections"]["ADDRA"]) if b == "0"]
                for n in SKIPPED}
        if any(masks.get(n, -1) != 0 or not tied[n] for n in SKIPPED) \
                or len(params["r_wide"]) != 65 or set(params["r64s"]) <= set("01xz"):
            print("masks %s, tied bits %s, INIT_A widths %s" % ({n: masks.get(n) for n in SKIPPED}, tied,
                                                                {n: len(v) for n, v in params.items()}))
            return 1
        print("%s: address bits %s tied low on every port and left on GND, the cells skipped"
              % ("; ".join("%s (%s)" % (n, SKIPPED[n]) for n in sorted(SKIPPED)),
                 " / ".join("%s=%s" % (n, tied[n]) for n in sorted(SKIPPED))))
        return 0

    if a.mode == "data":
        got = data_pins(design)
        n = tie_count(a.log)
        if a.knob == "off":
            want = {k: GND for k in got}
            ok = n is None and got == want and set(TIED_DI_WHEN_ON) <= set(got)
        else:
            want = {k: TIED_DI_WHEN_ON.get(k, GND) for k in got}
            ok = n == sum(1 for v in TIED_DI_WHEN_ON.values() if v == VCC) and got == want \
                and set(TIED_DI_WHEN_ON) <= set(got)
        if not ok:
            diff = {"%s.%s" % k: (got.get(k), want.get(k)) for k in sorted(set(got) | set(want))
                    if got.get(k) != want.get(k)}
            print("knob %s: tie line count %s; tied-low data pins differing (got, want): %s"
                  % (a.knob, n, diff or "none"))
            return 1
        vcc = sorted("%s.%s" % k for k, v in got.items() if v == VCC)
        if a.knob == "off":
            print("knob off: no tie line, all %d tied-low data input(s) still on %s" % (len(got), GND))
        else:
            print("knob on: tie line count %d; on %s: %s; the other %d tied-low data input(s), whose outputs are "
                  "read, still on %s" % (n, VCC, " ".join(vcc), len(got) - len(vcc), GND))
        return 0

    if a.mode == "mutant-no-permute":
        errors = grade(design, mutate_no_permute(design, "r_both"))[0]
    elif a.mode == "mutant-driven-bit":
        errors = grade(design, mutate_flip_bit(design, "r_mixed", 4))[0]
    else:
        errors = grade(design, mutate_flip_bit(design, "r_dfree", 4))[0]
    clean = grade(design)[0]
    if clean:
        print("the unmutated netlist is already red: %s" % clean[0])
        return 1
    hits = [e for e in errors if "reads physical" in e or "land on physical" in e]
    if hits:
        print("red as wanted: %s" % hits[0])
        return 0
    print("the mutant graded green" if not errors else "red for another reason: %s" % errors[0])
    return 1


if __name__ == "__main__":
    sys.exit(main())
