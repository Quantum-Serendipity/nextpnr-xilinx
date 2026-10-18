#!/usr/bin/env python3
import struct
import sys


def rel(buf, at):
    return at + struct.unpack_from("<i", buf, at)[0] * 4


def main():
    src, dst = sys.argv[1:3]
    mode = sys.argv[3] if len(sys.argv) > 3 else "checks"
    if mode not in ("checks", "min"):
        sys.exit("mutate_chipdb: mode %s is neither checks nor min" % mode)
    buf = bytearray(open(src, "rb").read())
    chip = rel(buf, 0)
    td = rel(buf, chip + 52)
    ntt = struct.unpack_from("<i", buf, td)[0]
    tct = rel(buf, td + 12)
    cleared = 0
    delays = 0
    for t in range(ntt):
        tt = tct + 12 * t
        ninst = struct.unpack_from("<i", buf, tt + 4)[0]
        insts = rel(buf, tt + 8)
        for i in range(ninst):
            inst = insts + 12 * i
            nct = struct.unpack_from("<i", buf, inst + 4)[0]
            cts = rel(buf, inst + 8)
            for v in range(nct):
                ct = cts + 20 * v
                nd, nc = struct.unpack_from("<ii", buf, ct + 4)
                delays += nd
                cleared += nc
                if mode == "checks":
                    struct.pack_into("<i", buf, ct + 8, 0)
                else:
                    ds = rel(buf, ct + 12)
                    for d in range(nd):
                        struct.pack_into("<i", buf, ds + 16 * d + 8, 0)
    if cleared == 0 or delays == 0:
        sys.exit("mutate_chipdb: found %d checks and %d delays; the walk did not reach the timing data" %
                 (cleared, delays))
    open(dst, "wb").write(buf)
    if mode == "checks":
        print("cleared %d timing checks, kept %d propagation delays" % (cleared, delays))
    else:
        print("zeroed the minimum of %d propagation delays, kept %d timing checks" % (delays, cleared))


main()
