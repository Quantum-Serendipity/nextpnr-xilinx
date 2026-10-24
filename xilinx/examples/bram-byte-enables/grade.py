#!/usr/bin/env python3
import json
import sys


def main():
    top = json.load(open(sys.argv[1]))["modules"]["top"]
    cell = next((c for n, c in top["cells"].items() if c["type"] == "RAMB18E1_RAMB18E1"), None)
    if cell is None:
        print("FAIL no RAMB18E1 in the routed netlist")
        return 1

    def net_of(pin):
        bits = cell["connections"].get(pin, [])
        return bits[0] if bits and isinstance(bits[0], int) else "const"

    rc = 0
    for port in ("WEA", "WEBWE"):
        got = [net_of("%s%d" % (port, i)) for i in range(4)]
        shown = " ".join(str(g) for g in got)
        paired = got[0] == got[1] and got[2] == got[3] and got[0] != got[2] and "const" not in got
        if paired:
            print("PASS %s: site pins 0-3 carry two distinct enables in pairs (%s)" % (port, shown))
        else:
            print("FAIL %s: site pins 0-3 carry %s, want enable 0 on pins 0 and 1 and enable 1 on pins 2 and 3" % (
                port, shown))
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
