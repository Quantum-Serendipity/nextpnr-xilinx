#!/usr/bin/env python3
import argparse
import copy
import json
import re
import sys

GND = "$PACKER_GND_NET"
VCC = "$PACKER_VCC_NET"
EXPECTED_MASKS = {"r_both": 0b11000, "r_mixed": 0b01000, "r_vcc": 0b10000, "r64": 0b100000, "r_free": 0}


def top_module(doc):
    for name, mod in doc["modules"].items():
        if "top" in mod.get("attributes", {}):
            return mod
    return doc["modules"]["top"]


def bits_lsb(value, width):
    if isinstance(value, int):
        return [(value >> i) & 1 for i in range(width)]
    s = str(value)
    if not set(s) <= set("01xz"):
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


class Design:
    def __init__(self, pre, packed):
        self.pre = top_module(pre)
        self.packed = top_module(packed)
        self.pre_names = bit_names(self.pre)
        self.packed_names = {}
        for name, nn in self.packed["netnames"].items():
            for b in nn["bits"]:
                if isinstance(b, int):
                    self.packed_names[b] = name

    def rams(self):
        out = []
        for name, cell in sorted(self.pre["cells"].items()):
            if cell["type"] in ("RAM32M", "RAM64M"):
                out.append((name, cell))
        return out

    def pin_net(self, cell, pin):
        conn = cell["connections"].get(pin)
        if not conn:
            return None
        b = conn[0]
        if isinstance(b, int):
            return self.packed_names.get(b, "#%d" % b)
        return {"0": GND, "1": VCC}.get(b, b)


def role(design, pre_bit, net):
    if net == VCC:
        return ("const", 1)
    if net == GND:
        return ("const", 0)
    if isinstance(pre_bit, int) and net in design.pre_names.get(pre_bit, set()):
        return ("var", None)
    return ("bad", net)


def grade(design, packed_cells=None):
    cells = design.packed["cells"] if packed_cells is None else packed_cells
    errors = []
    reads = 0
    subcells = 0
    masks = {}
    for name, cell in design.rams():
        is64 = cell["type"] == "RAM64M"
        abits = 6 if is64 else 5
        width = 1 if is64 else 2
        addr = {p: cell["connections"]["ADDR%s" % p] for p in "ABCD"}
        flipped = 0
        for p_idx, p in enumerate("ABCD"):
            init = bits_lsb(cell["parameters"].get("INIT_%s" % p, 0), 64)
            for j in range(width):
                sub = "%s/DPR%d" % (name, p_idx) if is64 else "%s/DPR%d_%d" % (name, p_idx, j)
                if sub not in cells:
                    errors.append("%s: no packed subcell" % sub)
                    continue
                subcells += 1
                sc = cells[sub]
                sinit = bits_lsb(sc["parameters"].get("INIT", 0), 64 if is64 else 32)
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
                for la in range(1 << abits):
                    if any(addr[p][i] in ("0", "1") and ((la >> i) & 1) != int(addr[p][i]) for i in range(abits)):
                        continue
                    phys = 0
                    for i, (kind, val) in enumerate(rroles):
                        phys |= (val if kind == "const" else (la >> i) & 1) << i
                    reads += 1
                    want = init[la * width + j]
                    if sinit[phys] != want:
                        errors.append("%s: logical address %d reads physical %d = %d, want %d"
                                      % (sub, la, phys, sinit[phys], want))
                        break
                    if any(addr["D"][i] in ("0", "1") and ((la >> i) & 1) != int(addr["D"][i])
                           for i in range(abits)):
                        continue
                    wphys = 0
                    for i, (kind, val) in enumerate(wroles):
                        wphys |= (val if kind == "const" else (la >> i) & 1) << i
                    if wphys != phys:
                        errors.append("%s: logical address %d is written at physical %d but read at %d"
                                      % (sub, la, wphys, phys))
                        break
        masks[name] = flipped
    return errors, reads, subcells, masks


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


def mutate_driven_bit(design, target, bit):
    cells = copy.deepcopy(design.packed["cells"])
    vcc_bit = None
    for name, nn in design.packed["netnames"].items():
        if name == VCC:
            vcc_bit = nn["bits"][0]
    for p_idx in range(4):
        for j in range(2):
            sub = cells["%s/DPR%d_%d" % (target, p_idx, j)]
            sub["connections"]["A%d" % (bit + 1)] = [vcc_bit]
            sub["connections"]["WA%d" % (bit + 1)] = [vcc_bit]
            old = bits_lsb(sub["parameters"]["INIT"], 32)
            new = [0] * 32
            for a in range(32):
                new[a ^ (1 << bit)] = old[a]
            sub["parameters"]["INIT"] = "".join(str(b) for b in reversed(new))
    return cells


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["contents", "count", "mutant-no-permute", "mutant-driven-bit"])
    ap.add_argument("pre")
    ap.add_argument("packed")
    ap.add_argument("--log")
    a = ap.parse_args()
    design = Design(json.load(open(a.pre)), json.load(open(a.packed)))

    if a.mode == "contents":
        errors, reads, subcells, _ = grade(design)
        if errors or reads == 0:
            print("first: %s" % (errors[0] if errors else "no reads"))
            print("%d error(s) over %d subcell(s), %d logical read(s)" % (len(errors), subcells, reads))
            return 1
        print("%d RAM32M/RAM64M cell(s), %d subcell(s), %d logical read(s) and their writes agree with the "
              "synthesised INIT" % (len(design.rams()), subcells, reads))
        return 0

    if a.mode == "count":
        text = open(a.log).read()
        m = re.search(r"Transformed (\d+) tied-low DRAM address inputs to be tied-high "
                      r"\((\d+) address bit\(s\) of (\d+) RAM32M/RAM64M cell\(s\)\)", text)
        if not m:
            print("no transform count line in %s" % a.log)
            return 1
        total, nbits, ncells = (int(x) for x in m.groups())
        _, _, _, masks = grade(design)
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

    if a.mode == "mutant-no-permute":
        errors, _, _, _ = grade(design, mutate_no_permute(design, "r_both"))
    else:
        errors, _, _, _ = grade(design, mutate_driven_bit(design, "r_mixed", 4))
    clean, _, _, _ = grade(design)
    if clean:
        print("the unmutated netlist is already red: %s" % clean[0])
        return 1
    hits = [e for e in errors if "reads physical" in e]
    if hits:
        print("red as wanted: %s" % hits[0])
        return 0
    print("the mutant graded green" if not errors else "red for another reason: %s" % errors[0])
    return 1


if __name__ == "__main__":
    sys.exit(main())
