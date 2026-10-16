#!/usr/bin/env bash
set -uo pipefail

abspath() {
    case $1 in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

resolve_tool() {
    case $1 in
        */*) abspath "$1" ;;
        *) command -v -- "$1" || printf '%s\n' "$1" ;;
    esac
}

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
YOSYS=$(resolve_tool "${YOSYS:-yosys}")
NEXTPNR=$(resolve_tool "${NEXTPNR:-$HERE/../../../build/nextpnr-xilinx}")
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tcsg324.bin}")
PYTHON=$(resolve_tool "${PYTHON:-python3}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    local verdict=$1
    shift
    echo "$verdict $*"
    [ "$verdict" = PASS ] || rc_total=1
}

synth() {
    local v=$1 src=$2 flags=$3
    "$YOSYS" -q -l "$OUT/$v.yosys.log" \
        -p "read_verilog \"$HERE/$src.v\"; synth_xilinx $flags -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
        >/dev/null 2>&1
}

pack() {
    local v=$1
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/hardblock-clock-tie.xdc" --json "$OUT/$v.json" --pack-only --write "$OUT/$v.packed.json" \
        --log "$OUT/$v.npnr.log" -q >/dev/null 2>&1
}

clock_net() {
    "$PYTHON" - "$OUT/$1.packed.json" <<'PY'
import json
import sys
top = json.load(open(sys.argv[1]))["modules"]["top"]
bits = {}
for name, nn in top["netnames"].items():
    for b in nn["bits"]:
        bits.setdefault(b, name)
for cell in top["cells"].values():
    if cell["type"].startswith("RAMB18E1"):
        b = cell["connections"]["CLKARDCLK"][0]
        print(bits.get(b, "?"))
PY
}

grade() {
    local v=$1 want_tied=$2 want_warn=$3 want_kept=$4 net tied warn kept
    net=$(clock_net "$v")
    case $net in '$PACKER_VCC_NET' | '$PACKER_GND_NET') tied=1 ;; *) tied=0 ;; esac
    warn=$(grep -c "an undefined ('x') constant in the netlist; tying it" "$OUT/$v.npnr.log")
    kept=$(grep -c "kept 1 hard-block clock pin" "$OUT/$v.npnr.log")
    if [ "$tied $warn $kept" = "$want_tied $want_warn $want_kept" ]; then
        report PASS "$v: CLKARDCLK on '$net'; tied, warnings, kept lines $tied $warn $kept"
    else
        report FAIL "$v: CLKARDCLK on '$net'; tied, warnings, kept lines $tied $warn $kept, want $want_tied $want_warn $want_kept"
    fi
}

if synth hier_x hier_x "" && pack hier_x; then
    grade hier_x 1 1 0
else
    report FAIL "hier_x: synthesis or packing failed"
fi

if synth flat_x flat_x -flatten && pack flat_x; then
    grade flat_x 1 1 0
else
    report FAIL "flat_x: synthesis or packing failed"
fi

if synth flat_port flat_port "-flatten -noiopad -noclkbuf" &&
    "$PYTHON" - "$OUT/flat_port.json" "$OUT/flat_port_noport.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
del d["modules"]["top"]["ports"]["c"]
json.dump(d, open(sys.argv[2], "w"))
PY
then
    if pack flat_port_noport; then
        grade flat_port_noport 0 0 1
    else
        report FAIL "flat_port_noport: packing failed"
    fi
else
    report FAIL "flat_port: synthesis failed"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
