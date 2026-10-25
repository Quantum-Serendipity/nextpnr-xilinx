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
PRJXRAY_DB=$(abspath "${PRJXRAY_DB:?set PRJXRAY_DB to the prjxray-db the chipdb was built from}")
PYTHON=$(resolve_tool "${PYTHON:-python3}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

TIMINGS=$PRJXRAY_DB/artix7/timings
TILEGRID=$PRJXRAY_DB/artix7/xc7a100t/tilegrid.json
[ -d "$TIMINGS" ] && [ -f "$TILEGRID" ] || { echo "FAIL setup: no $TIMINGS or $TILEGRID"; exit 1; }

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}
grade() {
    report "$("$PYTHON" "$HERE/grade.py" "$@")"
}

synth() {
    "$YOSYS" -q -l "$OUT/$1.yosys.log" \
        -p "read_verilog \"$HERE/$1.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$1.json\"" \
        >/dev/null 2>&1
}

if ! synth top || ! synth duty; then
    echo "FAIL yosys"
    exit 1
fi

if ! NEXTPNR_SETUP_EXPORT="$OUT/full.tsv" NEXTPNR_HOLD_EXPORT="$OUT/full.hold.tsv" NEXTPNR_ARC_EXPORT="$OUT/arcs.tsv" \
        "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --json "$OUT/top.json" --write "$OUT/routed.json" --sdf "$OUT/full.sdf" \
        --log "$OUT/full.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/full.log")"
    exit 1
fi
R=$OUT/routed.json

grade arcs "$R" "$OUT/arcs.tsv" "$TIMINGS" "$TILEGRID" arcs
grade hold "$OUT/full.hold.tsv" hold_export
grade skew "$R" "$OUT/full.tsv" "$OUT/full.hold.tsv" "$OUT/full.sdf" "$TIMINGS" "$TILEGRID" lfsr,k_q skew
grade srl_launch "$R" "$OUT/full.tsv" "$OUT/full.hold.tsv" "$OUT/full.sdf" "$TIMINGS" "$TILEGRID" sreg srl_launch
grade period "$R" "$OUT/full.tsv" p1_q ck0 ck0 period_ns 5 duty_mmcm

if NEXTPNR_SETUP_EXPORT="$OUT/duty.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --json "$OUT/duty.json" \
        --write "$OUT/duty-placed.json" --no-route --log "$OUT/duty.log" -q --seed 1 >/dev/null 2>&1; then
    grade period "$OUT/duty-placed.json" "$OUT/duty.tsv" pb_q ck0 ck0b period_ns 5 duty_mmcm_b
else
    report "FAIL duty_mmcm_b: nextpnr: $(grep -m1 '^ERROR' "$OUT/duty.log")"
fi

replay() {
    local name=$1
    shift
    NEXTPNR_TIMING_ONLY=1 NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" NEXTPNR_HOLD_EXPORT="$OUT/$name.hold.tsv" \
        "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" "$@" --json "$R" \
        --no-pack --no-place --no-route --log "$OUT/$name.log" -q >/dev/null 2>&1
}

arm_replay() {
    local name=$1
    shift
    if replay "$name" "$@"; then
        return 0
    fi
    report "FAIL $name: replay exited non-zero: $(grep -m1 '^ERROR' "$OUT/$name.log")"
    return 1
}

if arm_replay replay_base; then
    grade period "$R" "$OUT/replay_base.tsv" b_q clk clk period_ns 10 replay_base
    grade norow "$R" "$OUT/replay_base.tsv" sreg 1 srl_base
fi
if arm_replay waveform --xdc "$HERE/xdc/waveform.xdc"; then
    grade period "$R" "$OUT/waveform.tsv" n_q clk clk period_ns 3 waveform
fi
if arm_replay mcp_from_to --xdc "$HERE/xdc/mcp_from_to.xdc"; then
    grade period "$R" "$OUT/mcp_from_to.tsv" b_q clk clk period_ns 20 mcp_from_to
    grade period "$R" "$OUT/mcp_from_to.tsv" d_q clk clk period_ns 10 mcp_from_to_other_source
    grade period "$R" "$OUT/mcp_from_to.hold.tsv" b_q clk clk hold_req_ns 10 mcp_hold_moves
fi
if arm_replay mcp_from_other --xdc "$HERE/xdc/mcp_from_other.xdc"; then
    grade period "$R" "$OUT/mcp_from_other.tsv" b_q clk clk period_ns 10 mcp_from_other
fi
if arm_replay mcp_noname --xdc "$HERE/xdc/mcp_noname.xdc"; then
    grade period "$R" "$OUT/mcp_noname.tsv" d_q clk clk period_ns 20 mcp_noname
fi
if arm_replay mcp_hold --xdc "$HERE/xdc/mcp_hold.xdc"; then
    grade period "$R" "$OUT/mcp_hold.hold.tsv" b_q clk clk hold_req_ns 0 mcp_hold
fi
if arm_replay srl_fp --xdc "$HERE/xdc/srl_fp.xdc"; then
    grade norow "$R" "$OUT/srl_fp.tsv" sreg 0 srl_fp
fi

strict_arm() {
    local name=$1 xdc=$2 why=$3
    if replay "$name" --xdc "$HERE/xdc/$xdc.xdc" --xdc-strict; then
        report "FAIL $name: --xdc-strict accepted $xdc.xdc"
    elif grep -qF -- "$why" "$OUT/$name.log"; then
        report "PASS $name: refused under --xdc-strict ($why)"
    else
        report "FAIL $name: --xdc-strict refused $xdc.xdc without naming '$why': $(grep -m1 '^ERROR' "$OUT/$name.log")"
    fi
}
lenient_arm() {
    local name=$1 xdc=$2
    if replay "$name" --xdc "$HERE/xdc/$xdc.xdc"; then
        report "PASS $name: accepted without --xdc-strict"
        return 0
    fi
    report "FAIL $name: refused without --xdc-strict: $(grep -m1 '^ERROR' "$OUT/$name.log")"
    return 1
}
strict_arm strict_unsupported unsupported "unsupported XDC command 'set_clock_uncertainty'"
lenient_arm lenient_unsupported unsupported
strict_arm strict_virtual virtual "a virtual clock has no target"
strict_arm strict_waveform waveform_bad "-waveform '{0}' is not two edge times"
lenient_arm lenient_waveform waveform_bad
strict_arm strict_mcp_nomult mcp_nomult "no path multiplier"
strict_arm strict_mcp_setup_hold mcp_setup_hold "-setup and -hold together"
strict_arm strict_waveform_offset waveform_offset "puts the rising edge at 2 ns"

if lenient_arm lenient_waveform_offset waveform_offset; then
    if grep -qF "the offset is not read" "$OUT/lenient_waveform_offset.log"; then
        grade period "$R" "$OUT/lenient_waveform_offset.tsv" n_q clk clk period_ns 3 lenient_waveform_offset_high
    else
        report "FAIL lenient_waveform_offset_high: no warning that the rising-edge offset is not read"
    fi
fi
if lenient_arm lenient_mcp_setup_hold mcp_setup_hold; then
    if grep -qF "constraint not applied" "$OUT/lenient_mcp_setup_hold.log"; then
        grade period "$R" "$OUT/lenient_mcp_setup_hold.tsv" d_q clk clk period_ns 10 lenient_mcp_setup_hold_dropped
    else
        report "FAIL lenient_mcp_setup_hold_dropped: no warning that the constraint is not applied"
    fi
fi

"$PYTHON" "$HERE/mutate_chipdb.py" "$CHIPDB" "$OUT/nochecks.bin" > "$OUT/nochecks.txt" 2>&1
if [ ! -s "$OUT/nochecks.bin" ]; then
    report "FAIL zero_checks: $(cat "$OUT/nochecks.txt")"
elif "$NEXTPNR" --chipdb "$OUT/nochecks.bin" --xdc "$HERE/base.xdc" --json "$OUT/top.json" --pack-only \
        --log "$OUT/zero_checks.log" -q >/dev/null 2>&1; then
    report "FAIL zero_checks: a chipdb with its timing checks cleared ($(cat "$OUT/nochecks.txt")) was accepted"
elif grep -q "SDF propagation delays and no cell timing checks" "$OUT/zero_checks.log"; then
    report "PASS zero_checks: a chipdb with its timing checks cleared is refused"
else
    report "FAIL zero_checks: refused, but not for its timing checks: $(grep -m1 '^ERROR' "$OUT/zero_checks.log")"
fi
rm -f "$OUT/nochecks.bin"

"$PYTHON" "$HERE/mutate_chipdb.py" "$CHIPDB" "$OUT/zeromin.bin" min > "$OUT/zeromin.txt" 2>&1
if [ ! -s "$OUT/zeromin.bin" ]; then
    report "FAIL zero_min: $(cat "$OUT/zeromin.txt")"
elif NEXTPNR_ARC_EXPORT="$OUT/zeromin.arcs.tsv" "$NEXTPNR" --chipdb "$OUT/zeromin.bin" --xdc "$HERE/base.xdc" \
        --json "$OUT/top.json" --no-route --log "$OUT/zero_min.log" -q --seed 1 >/dev/null 2>&1; then
    grade zero_min "$OUT/zeromin.arcs.tsv" zero_min
else
    report "FAIL zero_min: nextpnr: $(grep -m1 '^ERROR' "$OUT/zero_min.log")"
fi
rm -f "$OUT/zeromin.bin"

echo "artefacts kept in $OUT"
exit "$rc_total"
