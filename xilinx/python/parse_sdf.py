"""
Utilities for SDF file parsing to determine cell timings
"""
import sys
from collections import Counter


class SDFData:
    def __init__(self):
        self.cells = {}
        # SDF keyword -> number of entries this reader could not represent.
        # Empty for every file in prjxray-db as of 2026-09-01.
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
    # One TIMINGCHECK constraint, carrying exactly one value.  The SDF forms
    # that bundle two constraints into one entry (SETUPHOLD, RECREM) are split
    # into two of these, so a consumer never has to know which spelling the
    # file used.  That matters because prjxray-db uses only the separate
    # spelling -- artix7/timings holds 2348 SETUP + 2356 HOLD + 58 RECOVERY +
    # 50 REMOVAL and zero SETUPHOLD -- while the reader this replaced matched
    # SETUPHOLD alone and therefore emitted no check at all for that corpus.
    #
    # kind is the SDF keyword the value came from: SETUP, HOLD, RECOVERY,
    # REMOVAL, WIDTH or PERIOD.  pin_edge/clock_edge carry the edge identifier
    # of an edge-qualified port_spec, e.g. "posedge" from (posedge CLK), and
    # are None for a bare port name.
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


# IEEE 1497 edge_identifier. A port_spec is either a bare port name or one of
# these applied to it.
EDGE_IDENTIFIERS = ("posedge", "negedge", "01", "10", "0z", "z1", "1z", "z0")


def parse_port_spec(spec):
    """Return (port, edge) for an SDF port_spec; edge is None if unqualified.

    (posedge CLK) reaches here as ['posedge', 'CLK'].  Every TIMINGCHECK in
    prjxray-db qualifies its clock that way, and the previous reader passed the
    two-element list through as the clock name, so nothing downstream could
    resolve it to a constid.  Returns (None, None) for a spec this reader
    cannot reduce to a port -- a COND/SCOND-conditioned one -- so the caller
    can count it rather than fabricate a name.
    """
    if isinstance(spec, str):
        return spec, None
    if len(spec) == 2 and spec[0] in EDGE_IDENTIFIERS:
        return spec[1], spec[0]
    return None, None


def parse_delay(delay):
    """Parse an SDF rvalue/rtriple. Accepts the raw s-expr or its string."""
    if not isinstance(delay, str):
        # An rvalue arrives as a one-element list: (0.088::0.109).
        delay = delay[0]
    sp = [float(x) if x != '' else None for x in delay.split(":")]
    if len(sp) == 1:
        # A bare rvalue is min == typ == max, not a malformed rtriple.
        return Delay(sp[0], sp[0], sp[0])
    assert len(sp) == 3, "unexpected SDF rvalue '{}'".format(delay)
    return Delay(sp[0], sp[1], sp[2])


# (KEYWORD sig_port clock_port setup_value hold_value) -- one entry, two
# constraints. Absent from prjxray-db, legal SDF, and the only form the
# previous reader understood.
SPLIT_CHECKS = {
    "SETUPHOLD": ("SETUP", "HOLD"),
    "RECREM": ("RECOVERY", "REMOVAL"),
}

# (KEYWORD sig_port clock_port value)
SIGNAL_CHECKS = ("SETUP", "HOLD", "RECOVERY", "REMOVAL")

# (KEYWORD port value) -- the constrained port is its own reference.
PORT_CHECKS = ("WIDTH", "PERIOD")


def parse_timing_check(check, cell, unhandled):
    kw = check[0]
    if kw in SPLIT_CHECKS or kw in SIGNAL_CHECKS:
        pin, pin_edge = parse_port_spec(check[1])
        clock, clock_edge = parse_port_spec(check[2])
        if pin is None or clock is None:
            unhandled[kw + "/conditioned"] += 1
            return
        for i, kind in enumerate(SPLIT_CHECKS.get(kw, (kw,))):
            cell.entries.append(TimingCheck(kind, pin, clock, parse_delay(check[3 + i]), pin_edge, clock_edge))
    elif kw in PORT_CHECKS:
        pin, pin_edge = parse_port_spec(check[1])
        if pin is None:
            unhandled[kw + "/conditioned"] += 1
            return
        cell.entries.append(TimingCheck(kw, pin, pin, parse_delay(check[2]), pin_edge, pin_edge))
    else:
        # NOCHANGE, SKEW, PATHCONSTRAINT, ... : counted, not dropped in
        # silence. Zero occurrences across artix7, zynq7 and spartan7.
        unhandled[kw] += 1


def parse_sdf_file(filename):
    sdata = parse_sexpr_file(filename)
    assert sdata[0] == "DELAYFILE"
    sdf = SDFData()
    unhandled = sdf.unhandled
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
                for mode in subentry[1:]:
                    if mode[0] != "ABSOLUTE":
                        # INCREMENT and PATHPULSE are deltas against a baseline
                        # this reader does not carry; reading them as ABSOLUTE
                        # would replace every arc in the tile with its increment.
                        unhandled[mode[0]] += max(len(mode) - 1, 1)
                        continue
                    for delay in mode[1:]:
                        if delay[0] == "IOPATH":
                            from_pin, _ = parse_port_spec(delay[1])
                            to_pin, _ = parse_port_spec(delay[2])
                            if from_pin is None or to_pin is None:
                                unhandled["IOPATH/conditioned"] += 1
                                continue
                            rising = parse_delay(delay[3])
                            # One rvalue means rise and fall share it. Indexing
                            # delay[4] unconditionally raised IndexError there
                            # and aborted the whole chipdb build.
                            falling = parse_delay(delay[4]) if len(delay) > 4 else rising
                            cell.entries.append(IOPath(from_pin, to_pin, rising, falling))
                        elif delay[0] == "INTERCONNECT":
                            rising = parse_delay(delay[3])
                            falling = parse_delay(delay[4]) if len(delay) > 4 else rising
                            cell.interconnect[(delay[1], delay[2])] = Interconnect(delay[1], delay[2], rising, falling)
                        else:
                            unhandled[delay[0]] += 1
            elif subentry[0] == "TIMINGCHECK":
                for check in subentry[1:]:
                    parse_timing_check(check, cell, unhandled)
        sdf.cells[(celltype, inst)] = cell
    if unhandled:
        print("parse_sdf: {}: unrepresented SDF constructs: {}".format(
            filename, ", ".join("{} x{}".format(k, v) for k, v in sorted(unhandled.items()))), file=sys.stderr)
    return sdf
