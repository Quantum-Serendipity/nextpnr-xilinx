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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
FLOOR=${FLOOR:-0.5}
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! NEXTPNR_CRIT_EXPORT="$OUT/crit.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/crit-domains.xdc" \
        --json "$OUT/top.json" --write "$OUT/routed.json" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/pnr.log")"
    exit 1
fi

"$PYTHON" "$HERE/grade.py" "$OUT/routed.json" "$OUT/crit.tsv" "$FLOOR"
rc=$?

if ! "$YOSYS" -q -l "$OUT/negedge-yosys.log" \
        -p "read_verilog \"$HERE/negedge.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/negedge.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL negedge yosys"
    rc=1
elif ! NEXTPNR_CRIT_EXPORT="$OUT/negedge-crit.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/negedge.xdc" \
        --json "$OUT/negedge.json" --write "$OUT/negedge-routed.json" --log "$OUT/negedge-pnr.log" -q --seed 1 \
        >/dev/null 2>&1; then
    echo "FAIL negedge nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/negedge-pnr.log")"
    rc=1
else
    "$PYTHON" "$HERE/grade.py" "$OUT/negedge-routed.json" "$OUT/negedge-crit.tsv" "$FLOOR" n_q || rc=1
fi
echo "artefacts kept in $OUT"
exit "$rc"
