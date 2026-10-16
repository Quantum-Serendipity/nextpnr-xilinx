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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

VARIANTS=(
    groups groups_single fp_clocks fp_clocks_reversed fp_from_to fp_from fp_to fp_pins
    fp_setup_only fp_through fp_nomatch maxdelay_cdc maxdelay_tight precedence
    fp_pins_ce fp_pins_bogus fp_pins_q fp_clock_typo groups_typo fp_from_comb
)

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

if ! NEXTPNR_CRIT_EXPORT="$OUT/base_crit.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" \
        --json "$OUT/top.json" --write "$OUT/routed.json" --fasm "$OUT/base.fasm" --log "$OUT/pnr.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route"
    exit 1
fi

replay() {
    local name=$1
    shift
    NEXTPNR_TIMING_ONLY=1 NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" \
        "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" "$@" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --log "$OUT/$name.log" -q >/dev/null 2>&1
}

if ! replay base; then
    echo "FAIL replay base"
    exit 1
fi
report "$("$PYTHON" "$HERE/grade.py" "$OUT/routed.json" "$OUT/base.tsv" "$OUT/base.tsv" "$OUT/base.log" base)"

for v in "${VARIANTS[@]}"; do
    if ! replay "$v" --xdc "$HERE/xdc/$v.xdc"; then
        report "FAIL $v: replay exited non-zero"
        continue
    fi
    report "$("$PYTHON" "$HERE/grade.py" "$OUT/routed.json" "$OUT/base.tsv" "$OUT/$v.tsv" "$OUT/$v.log" "$v")"
done

strict_arm() {
    local name=$1 xdc=$2 why=$3
    if replay "$name" --xdc "$HERE/xdc/$xdc.xdc" --xdc-strict; then
        report "FAIL $name: --xdc-strict accepted $xdc.xdc"
    elif grep -q -- "$why" "$OUT/$name.log"; then
        report "PASS $name: refused under --xdc-strict ($why)"
    else
        report "FAIL $name: refused, but the log does not say '$why'"
    fi
}

strict_arm strict_nomatch fp_nomatch 'matched nothing'
strict_arm strict_pins_bogus fp_pins_bogus '-to matched nothing'
strict_arm strict_pins_q fp_pins_q 'is not a timed data pin'
strict_arm strict_clock_typo fp_clock_typo "clock 'no_such_clk' matched no clock"
strict_arm strict_groups_typo groups_typo "clock 'clkb_typo' matched no clock"
strict_arm strict_from_comb fp_from_comb 'matched no timing startpoint'

if ! NEXTPNR_SETUP_EXPORT="$OUT/pnr_groups.tsv" NEXTPNR_CRIT_EXPORT="$OUT/pnr_groups_crit.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/base.xdc" \
        --xdc "$HERE/xdc/groups.xdc" --xdc "$HERE/xdc/fp_from_to.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed_groups.json" --log "$OUT/pnr_groups.log" -q --seed 1 >/dev/null 2>&1; then
    report "FAIL pnr_groups: place and route with exceptions exited non-zero"
else
    n=$(cd "$HERE" && "$PYTHON" -B -c '
import sys
import grade
g = grade.groups_of(sys.argv[1])
r = grade.rows_of(sys.argv[2], g)
print(len(r.get("dst_b", [])), len(r.get("dst_slow", [])))
' "$OUT/routed_groups.json" "$OUT/pnr_groups.tsv")
    case $n in
        "0 "[1-9]*) report "PASS pnr_groups: placed and routed under exceptions; dst_b rows, dst_slow rows: $n" ;;
        *) report "FAIL pnr_groups: dst_b rows, dst_slow rows: $n" ;;
    esac
    c=$(cd "$HERE" && "$PYTHON" -B -c '
import sys
import grade
def crit(routed, tsv):
    g = grade.groups_of(routed)
    out = {}
    with open(tsv) as f:
        for line in f:
            cell, value = line.rstrip("\n").split("\t")
            out.setdefault(g.get(cell, "?"), []).append(float(value))
    return out
b = crit(sys.argv[1], sys.argv[2])
v = crit(sys.argv[3], sys.argv[4])
print(len(b.get("src_slow", [])), len(v.get("src_slow", [])), sum(len(x) for x in v.values()))
' "$OUT/routed.json" "$OUT/base_crit.tsv" "$OUT/routed_groups.json" "$OUT/pnr_groups_crit.tsv")
    case $c in
        [1-9]*" 0 "[1-9]*) report "PASS pnr_crit: src_slow critical in the base, not under exceptions; base src_slow, excepted src_slow, excepted total: $c" ;;
        *) report "FAIL pnr_crit: base src_slow, excepted src_slow, excepted total: $c" ;;
    esac
fi

if ! "$YOSYS" -q -l "$OUT/dram.yosys.log" \
        -p "read_verilog \"$HERE/dram.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/dram.json\"" \
        >/dev/null 2>&1; then
    report "FAIL dram: yosys"
else
    dram_rows() {
        "$PYTHON" -B -c '
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter="\t") if r["cell"].startswith("mem")]
print(len(rows), len([r for r in rows if abs(float(r["period_ns"]) - 30.0) < 1e-6]))
' "$1"
    }
    dram_pnr() {
        local name=$1
        shift
        NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/dram.xdc" "$@" \
            --json "$OUT/dram.json" --write "$OUT/$name.routed.json" --log "$OUT/$name.log" -q --seed 1 \
            >/dev/null 2>&1
    }
    if dram_pnr dram_base; then
        base=$(dram_rows "$OUT/dram_base.tsv")
        case $base in
            [1-9]*" 0") report "PASS dram_base: distributed-RAM rows, rows at 30 ns: $base" ;;
            *) report "FAIL dram_base: distributed-RAM rows, rows at 30 ns: $base" ;;
        esac
        if dram_pnr dram_fp --xdc "$HERE/xdc/dram_fp_to.xdc" --xdc-strict; then
            n=$(dram_rows "$OUT/dram_fp.tsv")
            [ "$n" = "0 0" ] && report "PASS dram_fp: no distributed-RAM row under set_false_path -to" ||
                report "FAIL dram_fp: distributed-RAM rows, rows at 30 ns: $n, want 0 0"
            if NEXTPNR_TIMING_ONLY=1 NEXTPNR_SETUP_EXPORT="$OUT/dram_fp_replay.tsv" "$NEXTPNR" --chipdb "$CHIPDB" \
                    --xdc "$HERE/dram.xdc" --xdc "$HERE/dram_replay.xdc" --xdc "$HERE/xdc/dram_fp_to.xdc" --xdc-strict \
                    --json "$OUT/dram_fp.routed.json" --no-pack --no-place --no-route --log "$OUT/dram_fp_replay.log" \
                    -q >/dev/null 2>&1; then
                n=$(dram_rows "$OUT/dram_fp_replay.tsv")
                [ "$n" = "0 0" ] && report "PASS dram_fp_replay: the replay accepts the exception and grades no distributed-RAM row" ||
                    report "FAIL dram_fp_replay: distributed-RAM rows, rows at 30 ns: $n, want 0 0"
            else
                report "FAIL dram_fp_replay: the replay refused the exception under --xdc-strict"
            fi
        else
            report "FAIL dram_fp: place and route exited non-zero"
        fi
        if dram_pnr dram_maxdelay --xdc "$HERE/xdc/dram_maxdelay.xdc" --xdc-strict; then
            n=$(dram_rows "$OUT/dram_maxdelay.tsv")
            case $n in
                "${base%% *} ${base%% *}") report "PASS dram_maxdelay: every distributed-RAM row graded against 30 ns: $n" ;;
                *) report "FAIL dram_maxdelay: distributed-RAM rows, rows at 30 ns: $n, want ${base%% *} ${base%% *}" ;;
            esac
        else
            report "FAIL dram_maxdelay: place and route exited non-zero"
        fi
    else
        report "FAIL dram_base: place and route exited non-zero"
    fi
fi

echo "outputs in $OUT"
exit $rc_total
