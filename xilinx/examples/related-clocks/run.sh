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

if ! NEXTPNR_SETUP_EXPORT="$OUT/setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/related-clocks.xdc" \
        --json "$OUT/top.json" --fasm "$OUT/top.fasm" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/pnr.log")"
    exit 1
fi

periods() {
    awk -F'\t' -v l="$1" -v c="$2" 'NR > 1 && $9 == l && $10 == c { print $8 }' "$OUT/setup.tsv" | sort -u | tr '\n' ' '
}

pair_arm() {
    local launch=$1 capture=$2 want=$3 got
    got=$(periods "$launch" "$capture")
    if [ "$got" = "$want " ]; then
        report "PASS $launch -> $capture: every row graded against $want ns"
    else
        report "FAIL $launch -> $capture: rows graded against [${got% }] ns, expected $want ns"
    fi
}

pair_arm b0 b1 5
pair_arm b0 b2 10
pair_arm b0 b0 10

line=$(grep -m1 'Max delay posedge b0 -> posedge b1:' "$OUT/pnr.log")
case $line in
    *"against a 5.00 ns edge separation"*) report "PASS cross-domain verdict: ${line#*Info: }" ;;
    *) report "FAIL cross-domain verdict: '${line#*Info: }' carries no verdict against the 5.00 ns edge separation" ;;
esac

line=$(grep -m1 "derived .* for net 'fb'" "$OUT/pnr.log")
case $line in
    *"derived 100.0 MHz for net 'fb'"*) report "PASS feedback clock: ${line#*Info: }" ;;
    *) report "FAIL feedback clock: '${line#*Info: }', expected 100.0 MHz (CLKFBOUT runs at the input rate over DIVCLK_DIVIDE)" ;;
esac

echo "artefacts kept in $OUT"
exit "$rc_total"
