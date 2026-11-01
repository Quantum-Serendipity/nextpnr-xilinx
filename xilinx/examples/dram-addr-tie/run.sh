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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tfgg484.bin}")
NPNR_TIMEOUT=${NPNR_TIMEOUT:-600}
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

if ! timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --pack-only \
        --write "$OUT/packed.json" --log "$OUT/pack.log" -q >/dev/null 2>&1; then
    echo "FAIL pack: $(grep -m1 '^ERROR' "$OUT/pack.log")"
    exit 1
fi

check() {
    local arm=$1 mode=$2 out
    if out=$("$PYTHON" "$HERE/check.py" "$mode" "$OUT/top.json" "$OUT/packed.json" --log "$OUT/pack.log" 2>&1); then
        report "PASS $arm: $(printf '%s\n' "$out" | tail -1)"
    else
        report "FAIL $arm: $(printf '%s\n' "$out" | tr '\n' ' ')"
    fi
}

check contents contents
check count count
check unread-data unread-data
check mutant-no-permute mutant-no-permute
check mutant-driven-bit mutant-driven-bit

echo "outputs in $OUT"
exit "$rc_total"
