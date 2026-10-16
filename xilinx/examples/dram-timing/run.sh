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
PLACERS=${PLACERS:-heap sa}
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

for placer in $PLACERS; do
for s in $SEEDS; do
    tag="$placer seed $s"
    base="$OUT/$placer.s$s"
    if [ "$placer" = sa ]; then
        NEXTPNR_SETUP_EXPORT="$base.setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/dram-timing.xdc" \
            --json "$OUT/top.json" --write "$base.placed.json" --log "$base.log" \
            --placer sa --no-route -q --seed "$s" >/dev/null 2>&1
    else
        NEXTPNR_SETUP_EXPORT="$base.setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/dram-timing.xdc" \
            --json "$OUT/top.json" --write "$base.routed.json" --fasm "$base.fasm" --log "$base.log" \
            --placer "$placer" -q --seed "$s" >/dev/null 2>&1
    fi
    rc=$?
    guess=$(grep -c 'against a guess' "$base.log")
    if [ "$rc" -eq 0 ] && [ "$guess" -eq 0 ]; then
        report "PASS $tag: rc 0"
    else
        report "FAIL $tag: rc $rc, $guess timed-against-a-guess error(s): $(grep -m1 '^ERROR' "$base.log")"
        continue
    fi
    offm=$(grep -c 'which is not a SLICEM LUT bel' "$base.log")
    if [ "$offm" -eq 0 ]; then
        report "PASS $tag: no distributed-RAM cell timed on a bel outside a SLICEM"
    else
        report "FAIL $tag: $offm distributed-RAM cell(s) timed on a bel outside a SLICEM, first: $(grep -m1 'which is not a SLICEM LUT bel' "$base.log")"
    fi
    if [ "$placer" = sa ]; then
        rows=$(awk -F'\t' 'NR > 1 && $1 ~ /\/DPR[0-9]*$|\/SP[0-9]*$/ && $2 ~ /^(WE|WA[1-8]|DI[12])$/' \
            "$base.setup.tsv" | wc -l)
        if [ "$rows" -gt 0 ]; then
            report "PASS $tag: $rows distributed-RAM write-pin setup row(s) exported after placement"
        else
            report "FAIL $tag: no distributed-RAM write-pin setup row exported after placement"
        fi
        continue
    fi

    ll=$(grep -cE '^(CLBLL_[LR]_X[0-9]+Y[0-9]+\.SLICE[LM]_X[01]|CLBLM_[LR]_X[0-9]+Y[0-9]+\.SLICEL_X1)\.[A-D]LUT\.(RAM|SMALL|SRL)' "$base.fasm")
    lm=$(grep -cE '^CLBLM_[LR]_X[0-9]+Y[0-9]+\.SLICEM_X0\.[A-D]LUT\.RAM' "$base.fasm")
    if [ "$ll" -eq 0 ] && [ "$lm" -gt 0 ]; then
        report "PASS $tag: $lm SLICEM LUT RAM feature line(s), none in a SLICEL"
    else
        report "FAIL $tag: $lm SLICEM LUT RAM feature line(s), $ll RAM/SRL feature line(s) in a SLICEL"
    fi

    rows=$(awk -F'\t' 'NR > 1 && $1 ~ /\/DPR[0-9]*$|\/SP[0-9]*$/ && $2 ~ /^(WE|WA[1-8]|DI[12])$/' \
        "$base.setup.tsv" | wc -l)
    if [ "$rows" -gt 0 ]; then
        report "PASS $tag: $rows distributed-RAM write-pin setup row(s) exported"
    else
        report "FAIL $tag: no distributed-RAM write-pin setup row exported"
    fi
done
done

echo "artefacts kept in $OUT"
exit "$rc_total"
