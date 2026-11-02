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
for run in off on offx; do
    knob=()
    [ "$run" = on ] && knob=("${KNOB_ON[@]}")
    [ "$run" = offx ] && knob=(--set knob/dram_tie_unread_di=off)
    if ! pack "$OUT/top.json" "$OUT/packed-$run" --xdc "$HERE/top.xdc" ${knob[@]+"${knob[@]}"}; then
        echo "FAIL pack knob $run: $(grep -m1 '^ERROR' "$OUT/packed-$run.log")"
        exit 1
    fi
done
stripped_rc=0
pack "$OUT/stripped.json" "$OUT/stripped-off" || stripped_rc=$?

check() {
    local arm=$1 mode=$2 pre=$3 run=$4 knob=$5 out
    if out=$("$PYTHON" "$HERE/check.py" "$mode" "$OUT/$pre.json" "$OUT/$run.json" --log "$OUT/$run.log" \
            --knob "$knob" 2>&1); then
        report "PASS $arm: $(printf '%s\n' "$out" | tail -1)"
    else
        report "FAIL $arm: $(printf '%s\n' "$out" | tr '\n' ' ')"
    fi
}

refused() {
    local arm=$1 base=$2 want=$3
    shift 3
    local rc
    pack "$@"
    rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "ERROR: $want" "$base.log"; then
        report "PASS $arm: rc $rc, $want"
    else
        report "FAIL $arm: rc $rc: $(grep -m1 '^ERROR' "$base.log")"
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
if [ "$stripped_rc" -eq 0 ]; then
    check stripped-knob-off stripped stripped stripped-off off
else
    report "FAIL stripped-knob-off: the knob-unset pack stopped at rc $stripped_rc: $(grep -m1 '^ERROR' "$OUT/stripped-off.log")"
fi
check mutant-no-permute mutant-no-permute top packed-off off
check mutant-driven-bit mutant-driven-bit top packed-off off
check mutant-skip-port-d mutant-skip-port-d top packed-off off

refused stripped-knob-on-refused "$OUT/stripped-on" \
    "knob/dram_tie_unread_di=on is refused: the netlist has no top-level ports" \
    "$OUT/stripped.json" "$OUT/stripped-on" "${KNOB_ON[@]}"
printf '{"info": {"GRID_X_MIN": 10, "GRID_X_MAX": 28, "GRID_Y_MIN": 105, "GRID_Y_MAX": 155}}\n' >"$OUT/roi.json"
NEXTPNR_PARTITION_ROI="$OUT/roi.json" refused roi-knob-on-refused "$OUT/packed-roi" \
    "knob/dram_tie_unread_di=on is refused: NEXTPNR_PARTITION_ROI is set" \
    "$OUT/top.json" "$OUT/packed-roi" --xdc "$HERE/top.xdc" "${KNOB_ON[@]}"
refused roi-set-knob-on-refused "$OUT/packed-roi-set" \
    "knob/dram_tie_unread_di=on is refused: knob/partition_roi is set" \
    "$OUT/top.json" "$OUT/packed-roi-set" --xdc "$HERE/top.xdc" --set knob/partition_roi="$OUT/roi.json" \
    "${KNOB_ON[@]}"
TIE_RE='Tied [0-9]+ tied-low RAM32M/RAM64M data inputs high'
roi_unset_packs() {
    local arm=$1 via=$2 run knob roi=() from base rc why=""
    if [ "$via" = env ]; then
        from="environment NEXTPNR_PARTITION_ROI"
    else
        from="--set"
        roi=(--set knob/partition_roi="$OUT/roi.json")
    fi
    for run in unset off; do
        knob=()
        [ "$run" = off ] && knob=(--set knob/dram_tie_unread_di=off)
        base="$OUT/packed-roi-$via-$run"
        (
            [ "$via" = env ] && export NEXTPNR_PARTITION_ROI="$OUT/roi.json"
            pack "$OUT/top.json" "$base" --xdc "$HERE/top.xdc" ${roi[@]+"${roi[@]}"} ${knob[@]+"${knob[@]}"}
        )
        rc=$?
        if [ "$rc" -ne 0 ]; then
            why="$why knob $run: rc $rc: $(grep -m1 '^ERROR' "$base.log");"
        elif ! grep -qF "knob knob/partition_roi=$OUT/roi.json (from $from" "$base.log"; then
            why="$why knob $run: the log does not name the partition ROI from $from;"
        elif ! grep -qF "partition ROI: grid (10,105)-(28,155)" "$base.log"; then
            why="$why knob $run: the log shows no active partition ROI;"
        elif grep -qE "$TIE_RE" "$base.log"; then
            why="$why knob $run: a data-input tie line;"
        fi
    done
    if [ -z "$why" ]; then
        report "PASS $arm: with the ROI from $from, the knob unset and =off each pack at rc 0 with no tie line"
    else
        report "FAIL $arm:$why"
    fi
}
roi_unset_packs roi-knob-unset-packs env
roi_unset_packs roi-set-knob-unset-packs set
NEXTPNR_PARTITION_ROI="$OUT/absent.roi.json" refused roi-file-refused "$OUT/roi-absent-env" \
    "NEXTPNR_PARTITION_ROI: cannot open '$OUT/absent.roi.json'" "$OUT/top.json" "$OUT/roi-absent-env"
refused roi-set-file-refused "$OUT/roi-absent-set" "knob/partition_roi: cannot open '$OUT/absent.roi.json'" \
    "$OUT/top.json" "$OUT/roi-absent-set" --set knob/partition_roi="$OUT/absent.roi.json"

value_refused() {
    local v rc why="" n=0
    for v in maybe 0 1 ON Off on1; do
        pack "$OUT/top.json" "$OUT/packed-bad-$v" --xdc "$HERE/top.xdc" --set knob/dram_tie_unread_di="$v"
        rc=$?
        n=$((n + 1))
        if [ "$rc" -eq 0 ] || ! grep -qF "ERROR: knob/dram_tie_unread_di=$v is refused: the value is neither on nor off" \
                "$OUT/packed-bad-$v.log"; then
            why="$why =$v: rc $rc: $(grep -m1 '^ERROR' "$OUT/packed-bad-$v.log");"
        fi
    done
    if [ -z "$why" ]; then
        report "PASS knob-value-refused: each of $n value(s) (maybe 0 1 ON Off on1) stops the run and is named neither on nor off"
    else
        report "FAIL knob-value-refused:$why"
    fi
}
value_refused
rc=0
timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/packed-off.json" --no-pack --no-place --no-route \
    --set knob/dram_tie_unread_di=maybe --log "$OUT/nopack-bad.log" -q >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -qF "ERROR: knob/dram_tie_unread_di=maybe is refused: the value is neither on nor off" "$OUT/nopack-bad.log"; then
    report "PASS knob-value-refused-no-pack: --no-pack --no-place --no-route with =maybe stops at rc $rc"
else
    report "FAIL knob-value-refused-no-pack: rc $rc: $(grep -m1 '^ERROR' "$OUT/nopack-bad.log")"
fi

echo "outputs in $OUT"
exit "$rc_total"
