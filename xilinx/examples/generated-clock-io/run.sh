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

pnr() {
    local name=$1
    shift
    NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" "$NEXTPNR" --chipdb "$CHIPDB" "$@" --log "$OUT/$name.log" -q --seed 1 \
        >/dev/null 2>&1
}

if ! NEXTPNR_CRIT_PATH_REPORT=1 pnr full --xdc "$HERE/base.xdc" --xdc "$HERE/gen.xdc" --xdc "$HERE/io.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed.json" --fasm "$OUT/full.fasm"; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/full.log")"
    exit 1
fi

periods() {
    awk -F'\t' -v l="$2" -v c="$3" 'NR > 1 && $9 == l && $10 == c { print $8 }' "$OUT/$1.tsv" | sort -u | tr '\n' ' '
}

rows() {
    awk -F'\t' -v col="$2" -v pat="$3" 'NR > 1 && index($col, pat) > 0' "$OUT/$1.tsv"
}

pair_arm() {
    local run=$1 launch=$2 capture=$3 want=$4 got
    got=$(periods "$run" "$launch" "$capture")
    if [ "$got" = "$want " ]; then
        report "PASS $run $launch -> $capture: every row graded against $want ns"
    else
        report "FAIL $run $launch -> $capture: rows graded against [${got% }] ns, expected $want ns"
    fi
}

pair_arm full dclk dclk 20
pair_arm full clk dclk 10

line=$(grep -m1 'Max delay posedge clk *-> posedge dclk *:' "$OUT/full.log")
case $line in
    *"against a 10.00 ns edge separation; related through 'clk_i'"*)
        report "PASS divided-clock crossing verdict: ${line#*Info: }" ;;
    *) report "FAIL divided-clock crossing verdict: '${line#*Info: }' is not graded against the 10.00 ns separation" ;;
esac

io_row_arm() {
    local name=$1 run=$2 col=$3 pat=$4 launch=$5 capture=$6 field=$7 want=$8 slack=$9 r
    r=$(rows "$run" "$col" "$pat")
    if [ -z "$r" ]; then
        report "FAIL $name: no setup row for '$pat' (the constraint is not timed)"
        return
    fi
    if [ "$(printf '%s\n' "$r" | wc -l)" -ne 1 ]; then
        report "FAIL $name: more than one setup row for '$pat'"
        return
    fi
    if printf '%s\n' "$r" | awk -F'\t' -v l="$launch" -v c="$capture" -v f="$field" -v w="$want" -v s="$slack" '
            { ok = ($9 == l && $10 == c && $8 == 10 && $f + 0 == w + 0) }
            ok && s == "neg" { ok = ($3 + 0 < 0) }
            ok && s == "pos" { ok = ($3 + 0 > 0) }
            END { exit ok ? 0 : 1 }'; then
        report "PASS $name: $(printf '%s\n' "$r" | awk -F'\t' '{ printf "%s -> %s, slack %s ns against %s ns", $9, $10, $3, $8 }')"
    else
        report "FAIL $name: row is '$(printf '%s\n' "$r" | tr '\t' ' ')'"
    fi
}

io_row_arm "input delay fails" full 4 'iopadmap$din_b' clk_i clk 6 9.5 neg
io_row_arm "input delay control" full 4 'iopadmap$din_a' clk_i clk 6 1 pos
io_row_arm "output delay" full 1 'dout$intcell$OBUF' clk clk_i 7 4 pos
io_row_arm "input delay on a falling generated clock" full 4 'iopadmap$sd_do' sd_clk clk 6 3 pos
io_row_arm "output delay to a generated clock at a port" full 1 'sd_di$intcell$OBUF' clk sd_clk 7 6 any

line=$(grep -m1 'Max delay posedge clk_i *-> posedge clk *:' "$OUT/full.log")
case $line in
    *"FAIL against a 10.00 ns edge separation"*) report "PASS input delay verdict: ${line#*Info: }" ;;
    *) report "FAIL input delay verdict: '${line#*Info: }' is not a FAIL against the 10.00 ns separation" ;;
esac

if grep -q 'Input delay .*din_b.*IBUF.OUT' "$OUT/full.log" && grep -q '^Info:  9.5  9.5  Input delay' "$OUT/full.log"; then
    report "PASS path report: the din_b path starts with its 9.5 ns input delay"
else
    report "FAIL path report: no 9.5 ns input delay line opens the din_b path"
fi

if pnr edges --xdc "$HERE/base.xdc" --xdc "$HERE/gen_edges.xdc" --xdc "$HERE/io.xdc" --json "$OUT/top.json" \
        --fasm "$OUT/edges.fasm"; then
    pair_arm edges clk dclk 5
else
    report "FAIL edges: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/edges.log")"
fi

if NEXTPNR_TIMING_ONLY=1 pnr replay --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" --xdc "$HERE/gen.xdc" \
        --xdc "$HERE/io.xdc" --json "$OUT/routed.json" --no-pack --no-place --no-route; then
    r=$(rows replay 4 'iopadmap$din_b' | awk -F'\t' '$6 + 0 == 9.5 && $9 == "clk_i" && $10 == "clk"')
    s=$(rows replay 4 'iopadmap$sd_do' | awk -F'\t' '$9 == "sd_clk" && $10 == "clk" && $8 == 10')
    if [ -n "$r" ] && [ -n "$s" ]; then
        report "PASS replay: under --no-pack the input delays are timed and the generated clock is related to clk"
    else
        report "FAIL replay: din_b row [$r], sd_do row [$s]"
    fi
else
    report "FAIL replay: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/replay.log")"
fi

if pnr false_path --xdc "$HERE/base.xdc" --xdc "$HERE/gen.xdc" --xdc "$HERE/io.xdc" \
        --xdc "$HERE/xdc/ports_false_path.xdc" --json "$OUT/top.json" --fasm "$OUT/false_path.fasm"; then
    b=$(rows false_path 4 'iopadmap$din_b')
    o=$(rows false_path 1 'dout$intcell$OBUF')
    a=$(rows false_path 4 'iopadmap$din_a')
    if [ -z "$b" ] && [ -z "$o" ] && [ -n "$a" ]; then
        report "PASS false path: set_false_path -from/-to [get_ports ...] removes the din_b and dout checks and keeps din_a"
    else
        report "FAIL false path: din_b row [$b], dout row [$o], din_a row [$a]"
    fi
else
    report "FAIL false path: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/false_path.log")"
fi

strict_arm() {
    local name=$1 why=$2
    if pnr "strict_$name" --xdc "$HERE/base.xdc" --xdc "$HERE/gen.xdc" --xdc "$HERE/xdc/$name.xdc" --xdc-strict \
            --json "$OUT/top.json" --pack-only; then
        report "FAIL strict $name: --xdc-strict accepted xdc/$name.xdc"
    elif grep -q -F -- "$why" "$OUT/strict_$name.log"; then
        report "PASS strict $name: refused under --xdc-strict ($why)"
    else
        report "FAIL strict $name: refused, but the log does not say '$why'"
    fi
}

strict_arm reference_pin "unsupported argument '-reference_pin'"
strict_arm data_edge "unsupported argument '-rise'"
strict_arm invert "unsupported argument '-invert'"
strict_arm duty "duty cycle other than half the period"
strict_arm clock_typo "clock 'no_such_clk' matched no clock"
strict_arm min_only "has a -min delay and no -max delay"
strict_arm no_source "-source: get_pins 'no_such_cell/O' matched 0 cells"

if NEXTPNR_TIMING_ONLY=1 pnr lenient --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" \
        --xdc "$HERE/xdc/reference_pin.xdc" --json "$OUT/routed.json" --no-pack --no-place --no-route; then
    if grep -q "set_input_delay: unsupported argument '-reference_pin', constraint not applied" "$OUT/lenient.log" &&
            grep -q "1 XDC constraint(s) in '.*reference_pin.xdc' were refused" "$OUT/lenient.log"; then
        report "PASS lenient: without --xdc-strict the refusal is warned and counted"
    else
        report "FAIL lenient: no warning or no count for the refused set_input_delay"
    fi
else
    report "FAIL lenient: nextpnr exited non-zero without --xdc-strict"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
