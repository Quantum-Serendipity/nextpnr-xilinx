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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
NEXTPNR=$(resolve_tool "${NEXTPNR:-$HERE/../../../build/nextpnr-xilinx}")
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tfgg484.bin}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

graded() {
    grep -q "Max frequency for clock 'ddr_sys_clk': .* at 100.00 MHz" "$1" \
        && ! grep -q 'matched no net, constraint dropped' "$1" && ! grep -q 'names no net or port' "$1"
}

replay() {
    local json=$1 xdc=$2 log=$3
    shift 3
    NEXTPNR_TIMING_ONLY=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/$xdc" --json "$json" \
        --no-pack --no-place --no-route --log "$log" -q "$@" >/dev/null 2>&1
}

aliases_of() {
    "$PYTHON" - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d["modules"].values():
    a = m["netnames"].get("ddr_sys_clk", {}).get("attributes", {}).get("NEXTPNR_NET_ALIASES", "")
    print(" ".join(sorted(a.split())))
PY
}

if "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/union.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed.json" --log "$OUT/full.log" -q --seed 1 >/dev/null 2>&1 && graded "$OUT/full.log"; then
    report "PASS alias union on the synthesised netlist: ddr_sys_clk graded at 100 MHz, no member refused"
else
    report "FAIL alias union on the synthesised netlist: $(grep -m1 -E '^ERROR|Max frequency for clock .ddr_sys_clk' "$OUT/full.log")"
    echo "artefacts kept in $OUT"
    exit 1
fi

al=$(aliases_of "$OUT/routed.json")
if [[ " $al " == *" u_ddr3.sys_clk "* && " $al " == *" u_ddr3.o_sys_clk "* ]]; then
    report "PASS written netlist names the net's aliases: ddr_sys_clk carries NEXTPNR_NET_ALIASES '$al'"
else
    report "FAIL written netlist names the net's aliases: ddr_sys_clk carries '${al:-nothing}'"
fi

if replay "$OUT/routed.json" alias-only.xdc "$OUT/alias-only.log" && graded "$OUT/alias-only.log"; then
    report "PASS create_clock on an alias absent from the written net names: graded at 100 MHz"
else
    report "FAIL create_clock on an alias absent from the written net names: $(grep -m1 -E '^ERROR|dropped|Max frequency for clock .ddr_sys_clk' "$OUT/alias-only.log")"
fi

if replay "$OUT/routed.json" union.xdc "$OUT/union.log" && graded "$OUT/union.log"; then
    report "PASS alias union on the written netlist: graded at 100 MHz, no member refused"
else
    report "FAIL alias union on the written netlist: $(grep -m1 -E '^ERROR|dropped|Max frequency for clock .ddr_sys_clk' "$OUT/union.log")"
fi

if replay "$OUT/routed.json" union.xdc "$OUT/rewrite.log" --write "$OUT/rewritten.json" \
        && [ "$(aliases_of "$OUT/rewritten.json")" = "$al" ] \
        && replay "$OUT/rewritten.json" alias-only.xdc "$OUT/rewrite-alias.log" && graded "$OUT/rewrite-alias.log"; then
    report "PASS aliases survive a second write: the re-written netlist carries the same aliases and grades the alias-only clock"
else
    report "FAIL aliases survive a second write: '$(aliases_of "$OUT/rewritten.json" 2>/dev/null)', $(grep -m1 -E '^ERROR|dropped|Max frequency for clock .ddr_sys_clk' "$OUT/rewrite-alias.log" 2>/dev/null)"
fi

refused() {
    [ "$1" -ne 0 ] && grep -q "member 'ddr_sys_clkx' of '{u_ddr3.sys_clk ddr_sys_clkx}' names no net or port" "$2" \
        && grep -q '^ERROR: create_clock: 1 of the members' "$2"
}

"$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/misspelt.xdc" --json "$OUT/top.json" \
    --pack-only --log "$OUT/misspelt-synth.log" -q >/dev/null 2>&1
rc=$?
if refused "$rc" "$OUT/misspelt-synth.log"; then
    report "PASS misspelt union member on the synthesised netlist: refused at rc $rc, ddr_sys_clkx named"
else
    report "FAIL misspelt union member on the synthesised netlist: rc $rc, $(grep -m1 -E '^ERROR|ddr_sys_clkx' "$OUT/misspelt-synth.log")"
fi

replay "$OUT/routed.json" misspelt.xdc "$OUT/misspelt-written.log"
rc=$?
if refused "$rc" "$OUT/misspelt-written.log"; then
    report "PASS misspelt union member on the written netlist: refused at rc $rc, ddr_sys_clkx named"
else
    report "FAIL misspelt union member on the written netlist: rc $rc, $(grep -m1 -E '^ERROR|ddr_sys_clkx' "$OUT/misspelt-written.log")"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
