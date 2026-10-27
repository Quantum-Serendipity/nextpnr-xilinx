import json
import sys


def bit_names(netnames):
    names = {}
    for name, w in netnames.items():
        bits = w["bits"]
        if len(bits) == 1:
            names.setdefault(bits[0], []).append(name)
            continue
        offset = w.get("offset", 0)
        upto = w.get("upto", 0)
        for i, b in enumerate(bits):
            idx = offset + (len(bits) - 1 - i if upto else i)
            names.setdefault(b, []).append("%s[%d]" % (name, idx))
    return names


def main():
    path, ports = sys.argv[1], sys.argv[2:]
    with open(path) as f:
        top = json.load(f)["modules"]["top"]
    names = bit_names(top["netnames"])
    bad = []
    for port in ports:
        p = top["ports"].get(port)
        if p is None or len(p["bits"]) != 1:
            bad.append("%s is not a one-bit top-level port" % port)
            continue
        pad = p["bits"][0]
        if p["direction"] == "input":
            ty, pad_pin, fabric_pin = "IBUF", "I", "O"
        elif p["direction"] == "output":
            ty, pad_pin, fabric_pin = "OBUF", "O", "I"
        else:
            bad.append("%s is neither an input nor an output" % port)
            continue
        bufs = [c for c in top["cells"].values()
                if c["type"] == ty and c["connections"].get(pad_pin) == [pad]]
        if len(bufs) != 1:
            bad.append("%s has %d %s cells on its pad, expected one" % (port, len(bufs), ty))
            continue
        net = bufs[0]["connections"].get(fabric_pin, [])
        if len(net) != 1 or not isinstance(net[0], int) or net[0] not in names:
            bad.append("%s: the %s %s pin is on no named net" % (port, ty, fabric_pin))
            continue
        for n in names[net[0]]:
            print("%s\t%s" % (port, n))
    if bad:
        sys.stderr.write("; ".join(bad) + "\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
