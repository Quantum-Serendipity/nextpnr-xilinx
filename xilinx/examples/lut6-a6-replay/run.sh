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
PAIRS=4
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

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --no-route \
        --write "$OUT/placed.json" --log "$OUT/place.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL place: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi
if "$PYTHON" "$HERE/replay.py" grade "$OUT/placed.json" "$PAIRS" >"$OUT/placed.grade" 2>&1; then
    report "PASS placed: $(tail -1 "$OUT/placed.grade"), every LUT6 half carries the A6 tie"
else
    report "FAIL placed: $(tail -1 "$OUT/placed.grade"), first: $(head -1 "$OUT/placed.grade")"
fi

replay() {
    "$PYTHON" "$HERE/replay.py" "$1" "$OUT/placed.json" "$OUT/$1.json" >"$OUT/$1.make" 2>&1 || return 2
    "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/$1.json" --no-pack --no-route \
        --write "$OUT/$1.placed.json" --log "$OUT/$1.log" -q --seed 1 >/dev/null 2>&1
}

for mode in strip narrow labelled; do
    replay "$mode"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "FAIL replay-$mode: rc $rc: $(grep -m1 '^ERROR' "$OUT/$mode.log")"
        continue
    fi
    if "$PYTHON" "$HERE/replay.py" grade "$OUT/$mode.placed.json" "$PAIRS" >"$OUT/$mode.grade" 2>&1; then
        report "PASS replay-$mode: $(tail -1 "$OUT/$mode.grade")"
    else
        report "FAIL replay-$mode: $(tail -1 "$OUT/$mode.grade"), first: $(head -1 "$OUT/$mode.grade")"
    fi
    case $mode in narrow) continue ;; esac
    if "$PYTHON" "$HERE/replay.py" func "$OUT/$mode.json" "$OUT/$mode.placed.json" >"$OUT/$mode.func" 2>&1; then
        report "PASS replay-$mode-function: $(tail -1 "$OUT/$mode.func")"
    else
        report "FAIL replay-$mode-function: $(tail -1 "$OUT/$mode.func"), first: $(head -1 "$OUT/$mode.func")"
    fi
done

replay wide
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Unable to find legal placement' "$OUT/wide.log"; then
    report "PASS replay-wide: six distinct A1..A5 nets per pair are refused: $(grep -m1 '^ERROR' "$OUT/wide.log")"
else
    report "FAIL replay-wide: rc $rc, expected a refusal naming no legal placement"
fi

replay real6
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Unable to find legal placement' "$OUT/real6.log"; then
    report "PASS replay-real6: a LUT6 using A6 as a signal is not paired: $(grep -m1 '^ERROR' "$OUT/real6.log")"
else
    report "FAIL replay-real6: rc $rc, expected a refusal naming no legal placement"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
