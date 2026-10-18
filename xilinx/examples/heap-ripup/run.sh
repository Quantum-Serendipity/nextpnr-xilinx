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

DESIGN=$HERE/../comb-loop
if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$DESIGN/top.v\"; synth_xilinx -flatten -abc9 -nodsp -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$DESIGN/comb-loop.xdc" --json "$OUT/top.json" --placer heap --no-route \
        --log "$OUT/place.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL place: nextpnr: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi

awk '
    /strict legalisation: [0-9]+ rip-up radius escalation\(s\), radius [0-9]+ of grid [0-9]+/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "legalisation:") n = $(i + 1)
            if ($i == "radius" && $(i + 1) ~ /^[0-9]+$/) r = $(i + 1)
            if ($i == "grid") g = $(i + 1)
        }
        want = 2
        for (k = 0; k < n; k++) want = want * 2 > g ? g : want * 2
        lines++
        if (r != want) { bad++; if (!first) first = sprintf("%d escalation(s) left radius %d, want %d of grid %d", n, r, want, g) }
    }
    END {
        if (lines == 0) { print "FAIL ripup: no strict-legalisation escalation line to grade"; exit 1 }
        if (bad) { printf "FAIL ripup: %d of %d escalation line(s) off the doubling ramp; first: %s\n", bad, lines, first; exit 1 }
        printf "PASS ripup: %d escalation line(s), each radius min(grid, 2 << escalations)\n", lines
    }' "$OUT/place.log"
