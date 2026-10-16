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

rows() {
    awk -F'\t' -v l="$1" -v c="$2" 'NR > 1 && $9 == l && $10 == c' "$OUT/setup.tsv" | wc -l
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

echo "artefacts kept in $OUT"
exit "$rc_total"
