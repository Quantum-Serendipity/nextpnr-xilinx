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

synth() {
    local src=$1 out=$2 flags=$3
    "$YOSYS" -q -l "$out.yosys.log" \
        -p "read_verilog \"$HERE/$src\"; synth_xilinx -flatten -abc9 -arch xc7 $flags -top top; write_json \"$out\"" \
        >/dev/null 2>&1
}

pack() {
    local json=$1 base=$2
    shift 2
    timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" "$@" --json "$json" --pack-only \
        --write "$base.json" --log "$base.log" -q >/dev/null 2>&1
}

if ! synth top.v "$OUT/top-synth.json" "" || ! synth stripped.v "$OUT/stripped-synth.json" "-noiopad -noclkbuf"; then
    echo "FAIL yosys"
    exit 1
fi
"$PYTHON" "$HERE/check.py" edit "$OUT/top-synth.json" "$OUT/top.json" >"$OUT/edit.txt" 2>&1 || { echo "FAIL edit: $(cat "$OUT/edit.txt")"; exit 1; }
"$PYTHON" "$HERE/check.py" strip "$OUT/stripped-synth.json" "$OUT/stripped.json" >"$OUT/strip.txt" 2>&1 || { echo "FAIL strip: $(cat "$OUT/strip.txt")"; exit 1; }
echo "INFO $(cat "$OUT/edit.txt"); stripped.v: $(cat "$OUT/strip.txt")"

KNOB_ON=(--set knob/dram_tie_unread_di=on)
for run in off on; do
    knob=()
    [ "$run" = on ] && knob=("${KNOB_ON[@]}")
    if ! pack "$OUT/top.json" "$OUT/packed-$run" --xdc "$HERE/top.xdc" ${knob[@]+"${knob[@]}"}; then
        echo "FAIL pack knob $run: $(grep -m1 '^ERROR' "$OUT/packed-$run.log")"
        exit 1
    fi
    if ! pack "$OUT/stripped.json" "$OUT/stripped-$run" ${knob[@]+"${knob[@]}"}; then
        echo "FAIL pack stripped knob $run: $(grep -m1 '^ERROR' "$OUT/stripped-$run.log")"
        exit 1
    fi
done
if ! pack "$OUT/top.json" "$OUT/packed-offx" --xdc "$HERE/top.xdc" --set knob/dram_tie_unread_di=off; then
    echo "FAIL pack knob off explicit: $(grep -m1 '^ERROR' "$OUT/packed-offx.log")"
    exit 1
fi

check() {
    local arm=$1 mode=$2 pre=$3 run=$4 knob=$5 out
    if out=$("$PYTHON" "$HERE/check.py" "$mode" "$OUT/$pre.json" "$OUT/$run.json" --log "$OUT/$run.log" \
            --knob "$knob" 2>&1); then
        report "PASS $arm: $(printf '%s\n' "$out" | tail -1)"
    else
        report "FAIL $arm: $(printf '%s\n' "$out" | tr '\n' ' ')"
    fi
}

check contents contents top packed-off off
check count count top packed-off off
check skip-init skip-init top packed-off off
check unread-data-off data top packed-off off
check knob-off-explicit same-as-unset packed-off packed-offx off
check contents-knob-on contents top packed-on on
check count-knob-on count top packed-on on
check unread-data-on data top packed-on on
check stripped-knob-off stripped stripped stripped-off off
check stripped-knob-on stripped stripped stripped-on on
check mutant-no-permute mutant-no-permute top packed-off off
check mutant-driven-bit mutant-driven-bit top packed-off off
check mutant-skip-port-d mutant-skip-port-d top packed-off off

pack "$OUT/top.json" "$OUT/packed-bad" --xdc "$HERE/top.xdc" --set knob/dram_tie_unread_di=maybe
rc=$?
if [ "$rc" -ne 0 ] && grep -q '^ERROR: knob/dram_tie_unread_di=maybe is refused: the value is on or off' "$OUT/packed-bad.log"; then
    report "PASS knob-value-refused: --set knob/dram_tie_unread_di=maybe stops the run at rc $rc and names the two values"
else
    report "FAIL knob-value-refused: rc $rc: $(grep -m1 '^ERROR' "$OUT/packed-bad.log")"
fi

echo "outputs in $OUT"
exit "$rc_total"
