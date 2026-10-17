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
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -nodsp -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

for arm in base base_again inert; do
    xdc=$arm
    [ "$arm" = base_again ] && xdc=base
    if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/$xdc.xdc" --json "$OUT/top.json" --fasm "$OUT/$arm.fasm" \
            --log "$OUT/$arm.log" -q --seed 1 >/dev/null 2>&1; then
        echo "FAIL $arm: nextpnr: $(grep -m1 '^ERROR' "$OUT/$arm.log")"
        exit 1
    fi
done

if cmp -s "$OUT/base.fasm" "$OUT/base_again.fasm"; then
    report "PASS base_again: two runs of the same inputs write the same FASM"
else
    report "FAIL base_again: two runs of the same inputs write different FASM, so the comparison below means nothing"
fi

if grep -q "set_false_path: exception #0, from 1 cell(s) 0 clock pattern(s), to 8 cell(s)" "$OUT/inert.log"; then
    report "PASS inert: the set_false_path was read, from inert_a to the eight inert_b registers"
else
    report "FAIL inert: the log does not show the set_false_path matching inert_a and inert_b"
fi

n=$(diff "$OUT/base.fasm" "$OUT/inert.fasm" | grep -c '^[<>]')
if [ "$n" -eq 0 ]; then
    report "PASS inert: a set_false_path between two unconnected registers leaves the FASM unchanged"
else
    report "FAIL inert: a set_false_path between two unconnected registers changes $n FASM line(s)"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
