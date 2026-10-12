"""
Utilities for SDF file parsing to determine cell timings
"""
import sys
from collections import Counter


class SDFData:
    def __init__(self):
        self.cells = {}
        self.unhandled = Counter()

class Delay:
    def __init__(self, minv, typv, maxv):
        self.minv = minv
        self.typv = typv
        self.maxv = maxv


class IOPath:
    def __init__(self, from_pin, to_pin, rising, falling):
        self.from_pin = from_pin
        self.to_pin = to_pin
        self.rising = rising
        self.falling = falling


class TimingCheck:
    def __init__(self, kind, pin, clock, value, pin_edge=None, clock_edge=None):
        self.kind = kind
        self.pin = pin
        self.clock = clock
        self.value = value
        self.pin_edge = pin_edge
        self.clock_edge = clock_edge


class Interconnect:
    def __init__(self, from_net, to_net, rising, falling):
        self.from_net = from_net
        self.to_net = to_net
        self.rising = rising
        self.falling = falling


class CellData:
    def __init__(self, celltype, inst):
        self.type = celltype
        self.inst = inst
        self.entries = []
        self.interconnect = {}


def parse_sexpr(stream):
    content = []
    buffer = ""
    instr = False
    while True:
        c = stream.read(1)
        assert c != "", "unexpected end of file"
        if instr:
            if c == '"':
                instr = False
            else:
                buffer += c
        else:
            if c == '(':
                content.append(parse_sexpr(stream))
            elif c == ')':
                if buffer != "":
                    content.append(buffer)
                return content
            elif c.isspace():
                if buffer != "":
                    content.append(buffer)
                buffer = ""
            elif c == '"':
                instr = True
            else:
                buffer += c


def parse_sexpr_file(filename):
    with open(filename, 'r') as f:
        c = f.read(1)
        while c != '(':
            assert c == ' ' or c == '\n' or c == '\t'
            c = f.read(1)
        return parse_sexpr(f)


def parse_delay(delay):
    sp = [float(x) if x != '' else None for x in delay.split(":")]
    if len(sp) == 1:
        return Delay(sp[0], sp[0], sp[0])
    assert len(sp) == 3
    return Delay(sp[0], sp[1], sp[2])


EDGE_IDENTIFIERS = ("posedge", "negedge", "01", "10", "0z", "z1", "1z", "z0")


def parse_port_spec(spec):
    if isinstance(spec, str):
        return spec, None
    if len(spec) == 2 and spec[0] in EDGE_IDENTIFIERS:
        return spec[1], spec[0]
    return None, None


PAIRED_CHECKS = {
    "SETUPHOLD": ("SETUP", "HOLD"),
    "RECREM": ("RECOVERY", "REMOVAL"),
}

SIGNAL_CHECKS = ("SETUP", "HOLD", "RECOVERY", "REMOVAL")

PORT_CHECKS = ("WIDTH", "PERIOD")


def parse_timing_check(check, cell, unhandled):
    kw = check[0]
    if kw in PAIRED_CHECKS or kw in SIGNAL_CHECKS:
        pin, pin_edge = parse_port_spec(check[1])
        clock, clock_edge = parse_port_spec(check[2])
        if pin is None or clock is None:
            unhandled[kw + "/conditioned"] += 1
            return
        kinds = PAIRED_CHECKS.get(kw, (kw, ))
        if len(check) != 3 + len(kinds):
            unhandled[kw + "/arity"] += 1
            return
        for i, kind in enumerate(kinds):
            if len(check[3 + i]) == 0:
                continue
            cell.entries.append(TimingCheck(kind, pin, clock, parse_delay(check[3 + i][0]), pin_edge, clock_edge))
    elif kw in PORT_CHECKS:
        pin, pin_edge = parse_port_spec(check[1])
        if pin is None:
            unhandled[kw + "/conditioned"] += 1
            return
        if len(check) != 3:
            unhandled[kw + "/arity"] += 1
            return
        cell.entries.append(TimingCheck(kw, pin, pin, parse_delay(check[2][0]), pin_edge, pin_edge))
    else:
        unhandled[kw] += 1


def parse_sdf_file(filename):
    sdata = parse_sexpr_file(filename)
    assert sdata[0] == "DELAYFILE"
    sdf = SDFData()
    for entry in sdata[1:]:
        if entry[0] != "CELL":
            continue
        assert entry[1][0] == "CELLTYPE"
        celltype = entry[1][1]
        assert entry[2][0] == "INSTANCE"
        if len(entry[2]) > 1:
            inst = entry[2][1]
        else:
            inst = "top"
        cell = CellData(celltype, inst)
        for subentry in entry[3:]:
            if subentry[0] == "DELAY":
                assert subentry[1][0] == "ABSOLUTE"
                for delay in subentry[1][1:]:
                    if delay[0] == "IOPATH":
                        cell.entries.append(
                            IOPath(delay[1], delay[2], parse_delay(delay[3][0]), parse_delay(delay[4][0])))
                    elif delay[0] == "INTERCONNECT":
                        cell.interconnect[(delay[1], delay[2])] = Interconnect(delay[1], delay[2],
                                                                               parse_delay(delay[3][0]),
                                                                               parse_delay(delay[4][0]))
            elif subentry[0] == "TIMINGCHECK":
                for check in subentry[1:]:
                    parse_timing_check(check, cell, sdf.unhandled)
        sdf.cells[(celltype, inst)] = cell
    if sdf.unhandled:
        print("parse_sdf: {}: SDF timing checks not represented: {}".format(
            filename, ", ".join("{} x{}".format(k, v) for k, v in sorted(sdf.unhandled.items()))), file=sys.stderr)
    return sdf
