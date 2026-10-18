import json
import sys

mode = sys.argv[1]
if mode == "find":
    d = json.load(open(sys.argv[2]))
    names = sorted(n for n in d["modules"]["top"]["netnames"] if n.endswith("$legal$1") and not n.startswith("$PACKER_"))
    if len(names) != 1:
        sys.exit("expected one non-constant $legal$1 net, found %d" % len(names))
    print(names[0])
elif mode == "rename":
    src, victim, name, dst = sys.argv[2:6]
    d = json.load(open(src))
    nn = d["modules"]["top"]["netnames"]
    entry = nn.pop(victim)
    if len(entry["bits"]) != 1:
        sys.exit("%s is not a single-bit net" % victim)
    nn[name] = entry
    json.dump(d, open(dst, "w"))
elif mode == "grade":
    d = json.load(open(sys.argv[2]))
    name = sys.argv[3]
    m = d["modules"]["top"]
    nn = m["netnames"]
    if name not in nn:
        sys.exit("FAIL the imported net %s is gone" % name)
    bit = nn[name]["bits"]
    bufg = [c for c in m["cells"].values() if c["type"].startswith("BUFG")]
    if len(bufg) != 1 or bufg[0]["connections"].get("O") != bit:
        sys.exit("FAIL %s no longer carries the BUFG output" % name)
    base = name[: -len("$legal$1")]
    fresh = sorted(n for n in nn if n.startswith(base + "$legal$") and n != name)
    if len(fresh) != 1:
        sys.exit("FAIL expected one renamed feedthrough beside %s, found %d" % (name, len(fresh)))
    print("%s kept, feedthrough named %s" % (name, fresh[0]))
