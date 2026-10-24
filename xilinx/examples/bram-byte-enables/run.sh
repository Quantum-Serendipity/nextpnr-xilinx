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
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed.json" --fasm "$OUT/top.fasm" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/pnr.log")"
    exit 1
fi

"$PYTHON" "$HERE/grade.py" "$OUT/routed.json"
rc=$?
echo "artefacts kept in $OUT"
exit "$rc"
