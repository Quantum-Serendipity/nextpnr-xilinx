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

if ! NEXTPNR_SETUP_EXPORT="$OUT/setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/clock-mux-groups.xdc" \
        --json "$OUT/top.json" --fasm "$OUT/top.fasm" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/pnr.log")"
    exit 1
fi

EXPORT="$OUT/setup.tsv"
rows() {
    awk -F'\t' -v l="$1" -v c="$2" 'NR > 1 && $9 == l && $10 == c' "$EXPORT" | wc -l
}

timed() {
    local n
    n=$(rows "$1" "$2")
    if [ "$n" -gt 0 ]; then
        report "PASS $1 -> $2: timed ($n row(s)) because $3"
    else
        report "FAIL $1 -> $2: excluded, although $3"
    fi
}

excluded() {
    local n
    n=$(rows "$1" "$2")
    if [ "$n" -eq 0 ]; then
        report "PASS $1 -> $2: excluded because $3"
    else
        report "FAIL $1 -> $2: $n row(s), although $3"
    fi
}

excluded clk_a clk_b "the two clocks are in different asynchronous groups"
timed clk_m clk_b "the mux output is clk_b's own clock whenever the mux selects I1"
timed clk_m clk_a "the mux output is clk_a's own clock whenever the mux selects I0"

if ! "$YOSYS" -q -l "$OUT/undriven-mux.yosys.log" \
        -p "read_verilog \"$HERE/undriven-mux.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/undriven-mux.synth.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys undriven-mux"
    exit 1
fi

if ! "$PYTHON" - "$OUT/undriven-mux.synth.json" "$OUT/undriven-mux.json" 2>"$OUT/undriven-mux.strip.log" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
m = j["modules"]["top"]
for port, net in (("ext", "ext_rm"), ("ext_nc", "nc_rm")):
    bits = m["ports"].pop(port)["bits"]
    pads = [n for n, c in m["cells"].items() if c["type"] == "IBUF" and c["connections"]["I"] == bits]
    if len(pads) != 1:
        sys.exit("expected one IBUF on %s, found %d" % (port, len(pads)))
    o = m["cells"].pop(pads[0])["connections"]["O"]
    m["netnames"] = {n: v for n, v in m["netnames"].items() if v["bits"] != bits and v["bits"] != o}
    m["netnames"][net] = {"hide_name": 0, "bits": o, "attributes": {}}
json.dump(j, open(sys.argv[2], "w"))
EOF
then
    echo "FAIL undriven-mux strip: $(cat "$OUT/undriven-mux.strip.log")"
    exit 1
fi

EXPORT="$OUT/undriven-mux.setup.tsv"
if ! NEXTPNR_SETUP_EXPORT="$EXPORT" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/undriven-mux.xdc" \
        --json "$OUT/undriven-mux.json" --log "$OUT/undriven-mux.log" -q --seed 1 --no-route >/dev/null 2>&1; then
    echo "FAIL nextpnr undriven-mux: $(grep -m1 '^ERROR' "$OUT/undriven-mux.log")"
    exit 1
fi

excluded clk_x clk_a "an x on I1 carries no clock, so the mux output is only pll_out"
excluded clk_w clk_a "I1 has no driver and no create_clock, so no declared clock reaches it"
timed clk_c clk_a "I1 has no driver but carries create_clock extclk, which is in neither group"

echo "artefacts kept in $OUT"
exit "$rc_total"
