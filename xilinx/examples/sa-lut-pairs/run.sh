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
OUT=$(abspath "${OUT:-$(mktemp -d)}")
SEEDS=${SEEDS:-1 2 3}
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

for placer in sa heap; do
    for seed in $SEEDS; do
        arm=$placer-seed$seed
        "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/sa-lut-pairs.xdc" --json "$OUT/top.json" --placer "$placer" \
            --no-route --write "$OUT/$arm.placed.json" --log "$OUT/$arm.log" -q --seed "$seed" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            report "FAIL $arm: place rc $rc: $(grep -m1 '^ERROR' "$OUT/$arm.log")"
            continue
        fi
        if ! "$PYTHON" "$HERE/grade.py" "$OUT/$arm.placed.json" >"$OUT/$arm.grade" 2>&1; then
            report "FAIL $arm: grader: $(tail -1 "$OUT/$arm.grade")"
            continue
        fi
        summary=$(tail -1 "$OUT/$arm.grade")
        case $summary in
            "pairs "*" illegal 0") report "PASS $arm: $summary" ;;
            *) report "FAIL $arm: $summary, first: $(head -1 "$OUT/$arm.grade")" ;;
        esac
    done
done

if ! "$YOSYS" -q -l "$OUT/control-yosys.log" \
        -p "read_verilog \"$HERE/control.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/control.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys control"
    exit 1
fi

for placer in sa heap; do
    arm=control-$placer
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/sa-lut-pairs.xdc" --json "$OUT/control.json" --placer "$placer" \
        --no-route --write "$OUT/$arm.placed.json" --log "$OUT/$arm.log" -q --seed 1 >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "FAIL $arm: place rc $rc: $(grep -m1 '^ERROR' "$OUT/$arm.log")"
        continue
    fi
    summary=$("$PYTHON" "$HERE/grade.py" "$OUT/$arm.placed.json" 2>&1 | tail -1)
    if [ "$summary" = "pairs 4 illegal 0" ]; then
        report "PASS $arm: the grader reads the four LUT6_2 halves as four legal pairs"
    else
        report "FAIL $arm: expected 'pairs 4 illegal 0' from four LUT6_2 cells, got '$summary'"
    fi
done

echo "artefacts kept in $OUT"
exit "$rc_total"
