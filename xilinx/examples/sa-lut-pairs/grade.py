import json
import re
import sys

m = json.load(open(sys.argv[1]))["modules"]["top"]
const = set()
for net, v in m["netnames"].items():
    if net in ("$PACKER_VCC_NET", "$PACKER_GND_NET"):
        const.update(b for b in v["bits"] if isinstance(b, int))
slots = {}
for name, c in m["cells"].items():
    if c["type"] != "SLICE_LUTX":
        continue
    bel = c["attributes"].get("NEXTPNR_BEL", "")
    hit = re.fullmatch(r"(.*)/([A-D])([56])LUT", bel)
    if hit is None:
        sys.exit("LUT %s has no LUT bel: %r" % (name, bel))
    ins = set()
    for port, bits in c["connections"].items():
        if c["port_directions"].get(port) == "input":
            ins.update(b for b in bits if isinstance(b, int) and b not in const)
    slots.setdefault((hit.group(1), hit.group(2)), {})[hit.group(3)] = (name, ins)

pairs = illegal = 0
for (site, lane), s in sorted(slots.items()):
    if "5" not in s or "6" not in s:
        continue
    pairs += 1
    n6, i6 = s["6"]
    n5, i5 = s["5"]
    if len(i6) == 6 or len(i6 | i5) > 5:
        illegal += 1
        print("illegal %s/%s: 6LUT %s uses %d input net(s), with the 5LUT %s %d distinct" %
              (site, lane, n6, len(i6), n5, len(i6 | i5)))
print("pairs %d illegal %d" % (pairs, illegal))
