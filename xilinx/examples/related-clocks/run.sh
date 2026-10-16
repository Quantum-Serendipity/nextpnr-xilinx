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

build() {
    local name=$1
    if ! "$YOSYS" -q -l "$OUT/$name.yosys.log" \
            -p "read_verilog \"$HERE/$name.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$name.json\"" \
            >/dev/null 2>&1; then
        echo "FAIL yosys $name"
        exit 1
    fi
    if ! NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/related-clocks.xdc" \
            --json "$OUT/$name.json" --fasm "$OUT/$name.fasm" --log "$OUT/$name.log" -q --seed 1 >/dev/null 2>&1; then
        echo "FAIL nextpnr place and route $name: $(grep -m1 '^ERROR' "$OUT/$name.log")"
        exit 1
    fi
}

periods() {
    awk -F'\t' -v l="$2" -v c="$3" 'NR > 1 && $9 == l && $10 == c { print $8 }' "$OUT/$1.tsv" | sort -u | tr '\n' ' '
}

build top
build coincident

pair_arm() {
    local launch=$1 capture=$2 want=$3 got
    got=$(periods top "$launch" "$capture")
    if [ "$got" = "$want " ]; then
        report "PASS $launch -> $capture: every row graded against $want ns"
    else
        report "FAIL $launch -> $capture: rows graded against [${got% }] ns, expected $want ns"
    fi
}

pair_arm b0 b1 5
pair_arm b0 b2 10
pair_arm b0 b0 10

line=$(grep -m1 'Max delay posedge b0 -> posedge b1:' "$OUT/top.log")
case $line in
    *"against a 5.00 ns edge separation"*) report "PASS cross-domain verdict: ${line#*Info: }" ;;
    *) report "FAIL cross-domain verdict: '${line#*Info: }' carries no verdict against the 5.00 ns edge separation" ;;
esac

line=$(grep -m1 "derived .* for net 'fb'" "$OUT/top.log")
case $line in
    *"derived 100.0 MHz for net 'fb'"*) report "PASS feedback clock: ${line#*Info: }" ;;
    *) report "FAIL feedback clock: '${line#*Info: }', expected 100.0 MHz (CLKFBOUT runs at the input rate over DIVCLK_DIVIDE)" ;;
esac

got=$(periods coincident b1 b0)
if [ "$got" = "4.166 " ]; then
    report "PASS coincident b1 -> b0: every row graded against one 240 MHz period, 4.166 ns"
else
    report "FAIL coincident b1 -> b0: rows graded against [${got% }] ns, expected 4.166 ns (b1's 180 degree edges land on b0 edges)"
fi

line=$(grep -m1 'Max delay posedge b1 -> posedge b0:' "$OUT/coincident.log")
case $line in
    *"against a 4.17 ns edge separation"*) report "PASS coincident cross-domain verdict: ${line#*Info: }" ;;
    *) report "FAIL coincident cross-domain verdict: '${line#*Info: }', expected a 4.17 ns edge separation" ;;
esac

echo "artefacts kept in $OUT"
exit "$rc_total"
