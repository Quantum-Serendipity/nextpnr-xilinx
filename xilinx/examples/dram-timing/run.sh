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
SEEDS=${SEEDS:-1 2 3}
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

for s in $SEEDS; do
    NEXTPNR_SETUP_EXPORT="$OUT/s$s.setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/dram-timing.xdc" \
        --json "$OUT/top.json" --write "$OUT/s$s.routed.json" --fasm "$OUT/s$s.fasm" --log "$OUT/s$s.log" \
        -q --seed "$s" >/dev/null 2>&1
    rc=$?
    guess=$(grep -c 'against a guess' "$OUT/s$s.log")
    if [ "$rc" -eq 0 ] && [ "$guess" -eq 0 ]; then
        report "PASS seed $s: place and route rc 0"
    else
        report "FAIL seed $s: rc $rc, $guess timed-against-a-guess error(s): $(grep -m1 '^ERROR' "$OUT/s$s.log")"
        continue
    fi

    ll=$(grep -cE '^CLBLL_[LR]_X[0-9]+Y[0-9]+\.SLICE[LM]_X[01]\.[A-D]LUT\.(RAM|SMALL|SRL)' "$OUT/s$s.fasm")
    lm=$(grep -cE '^CLBLM_[LR]_X[0-9]+Y[0-9]+\.SLICEM_X0\.[A-D]LUT\.RAM' "$OUT/s$s.fasm")
    if [ "$ll" -eq 0 ] && [ "$lm" -gt 0 ]; then
        report "PASS seed $s: $lm SLICEM LUT RAM feature line(s), none in a CLBLL tile"
    else
        report "FAIL seed $s: $lm SLICEM LUT RAM feature line(s), $ll RAM/SRL feature line(s) in a CLBLL tile"
    fi

    rows=$(awk -F'\t' 'NR > 1 && $1 ~ /\/DPR[0-9]*$|\/SP[0-9]*$/ && $2 ~ /^(WE|WA[1-8]|DI[12])$/' \
        "$OUT/s$s.setup.tsv" | wc -l)
    if [ "$rows" -gt 0 ]; then
        report "PASS seed $s: $rows distributed-RAM write-pin setup row(s) exported"
    else
        report "FAIL seed $s: no distributed-RAM write-pin setup row exported"
    fi
done

echo "artefacts kept in $OUT"
exit "$rc_total"
