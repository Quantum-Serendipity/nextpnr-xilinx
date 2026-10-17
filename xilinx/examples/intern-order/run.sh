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

for arm in base base_again inert mcp spare; do
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

if grep -q "set_multicycle_path: setup multicycle 1 tagged on 1 cells matching 'mcp_dst'" "$OUT/mcp.log"; then
    report "PASS mcp: the factor-1 set_multicycle_path tagged mcp_dst"
else
    report "FAIL mcp: the log does not show the set_multicycle_path tagging mcp_dst"
fi

if grep -q "2 XDC constraint target(s) reference ports or nets that are not in this design" "$OUT/spare.log" &&
        grep -q "set_false_path: -through matched no net" "$OUT/spare.log"; then
    report "PASS spare: the absent port, the absent clock net and the -through pattern were all read as matching nothing"
else
    report "FAIL spare: the log does not show the three absent targets refused"
fi

same_fasm() {
    local n
    n=$(diff "$OUT/base.fasm" "$OUT/$1.fasm" | grep -c '^[<>]')
    if [ "$n" -eq 0 ]; then
        report "PASS $1: $2 leaves the FASM unchanged"
    else
        report "FAIL $1: $2 changes $n FASM line(s)"
    fi
}
same_fasm inert "a set_false_path between two unconnected registers"
same_fasm mcp "a factor-1 set_multicycle_path"
same_fasm spare "constraints naming a port, a net and a net pattern absent from the design"

echo "artefacts kept in $OUT"
exit "$rc_total"
