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

VARIANTS=(
    groups groups_single fp_clocks fp_clocks_reversed fp_from_to fp_from fp_to fp_pins
    fp_setup_only fp_through fp_nomatch maxdelay_cdc maxdelay_tight precedence
)

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

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --json "$OUT/top.json" --write "$OUT/routed.json" \
        --fasm "$OUT/base.fasm" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route"
    exit 1
fi

replay() {
    local name=$1
    shift
    NEXTPNR_TIMING_ONLY=1 NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" \
        "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" "$@" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --log "$OUT/$name.log" -q >/dev/null 2>&1
}

if ! replay base; then
    echo "FAIL replay base"
    exit 1
fi
report "$("$PYTHON" "$HERE/grade.py" "$OUT/routed.json" "$OUT/base.tsv" "$OUT/base.tsv" "$OUT/base.log" base)"

for v in "${VARIANTS[@]}"; do
    if ! replay "$v" --xdc "$HERE/xdc/$v.xdc"; then
        report "FAIL $v: replay exited non-zero"
        continue
    fi
    report "$("$PYTHON" "$HERE/grade.py" "$OUT/routed.json" "$OUT/base.tsv" "$OUT/$v.tsv" "$OUT/$v.log" "$v")"
done

if replay strict_nomatch --xdc "$HERE/xdc/fp_nomatch.xdc" --xdc-strict; then
    report "FAIL strict_nomatch: --xdc-strict accepted an exception that matched nothing"
else
    if grep -q 'matched nothing' "$OUT/strict_nomatch.log"; then
        report "PASS strict_nomatch: refused under --xdc-strict"
    else
        report "FAIL strict_nomatch: refused, but not for the unmatched -from"
    fi
fi

if ! NEXTPNR_SETUP_EXPORT="$OUT/pnr_groups.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" \
        --xdc "$HERE/xdc/groups.xdc" --xdc "$HERE/xdc/fp_from_to.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed_groups.json" --log "$OUT/pnr_groups.log" -q --seed 1 >/dev/null 2>&1; then
    report "FAIL pnr_groups: place and route with exceptions exited non-zero"
else
    n=$(cd "$HERE" && "$PYTHON" -B -c '
import sys
import grade
g = grade.groups_of(sys.argv[1])
r = grade.rows_of(sys.argv[2], g)
print(len(r.get("dst_b", [])), len(r.get("dst_slow", [])))
' "$OUT/routed_groups.json" "$OUT/pnr_groups.tsv")
    case $n in
        "0 "[1-9]*) report "PASS pnr_groups: placed and routed under exceptions; dst_b rows, dst_slow rows: $n" ;;
        *) report "FAIL pnr_groups: dst_b rows, dst_slow rows: $n" ;;
    esac
fi

echo "outputs in $OUT"
exit $rc_total
