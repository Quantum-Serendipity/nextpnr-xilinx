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
    NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" NEXTPNR_HOLD_EXPORT="$OUT/$name.hold.tsv" "$NEXTPNR" --chipdb "$CHIPDB" \
        "$@" --log "$OUT/$name.log" -q --seed 1 >/dev/null 2>&1
}

if ! NEXTPNR_CRIT_PATH_REPORT=1 pnr full --xdc "$HERE/base.xdc" --xdc "$HERE/gen.xdc" --xdc "$HERE/io.xdc" \
        --json "$OUT/top.json" --write "$OUT/routed.json" --fasm "$OUT/full.fasm" --timing-allow-fail; then
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

n=$(awk -F'\t' 'NR > 1 && $9 == "clk" && $10 == "dclk"' "$OUT/full.tsv" | wc -l)
late=$(awk -F'\t' 'NR > 1 && $9 == "clk" && $10 == "dclk" && $14 - $13 > 0.3' "$OUT/full.tsv" | wc -l)
if [ "$n" -gt 0 ] && [ "$late" -eq "$n" ]; then
    report "PASS source latency: all $n clk -> dclk setup rows capture more than 0.3 ns after launch, the divider's clock-to-out and routing"
else
    report "FAIL source latency: $late of $n clk -> dclk setup rows capture more than 0.3 ns after launch"
fi

hold_identity() {
    awk -F'\t' -v l="$2" -v c="$3" 'NR > 1 && $10 == l && $11 == c {
            n++; d = $6 + $5 - $7 - $8 - $9 + $15 - $3; if (d < 0) d = -d; if (d < 0.002) ok++ }
        END { printf "%d %d\n", n, ok }' "$OUT/$1.hold.tsv"
}

read -r n ok < <(hold_identity full clk dclk)
late=$(awk -F'\t' 'NR > 1 && $10 == "clk" && $11 == "dclk" && $9 - $13 > 0.3' "$OUT/full.hold.tsv" | wc -l)
if [ "$n" -gt 0 ] && [ "$ok" -eq "$n" ] && [ "$late" -eq "$n" ]; then
    report "PASS hold source latency: all $n clk -> dclk hold rows charge the divided clock's later capture and add up"
else
    report "FAIL hold source latency: $n clk -> dclk hold rows, $ok add up, $late capture more than 0.3 ns after launch"
fi

read -r n ok < <(hold_identity full dclk dclk)
shared=$(awk -F'\t' 'NR > 1 && $10 == "dclk" && $11 == "dclk" && $15 > 0.1 && $3 > 0' "$OUT/full.hold.tsv" | wc -l)
if [ "$n" -gt 0 ] && [ "$ok" -eq "$n" ] && [ "$shared" -eq "$n" ]; then
    report "PASS hold pessimism inside the divided domain: all $n dclk -> dclk hold rows remove more than 0.1 ns of shared source latency and pass"
else
    report "FAIL hold pessimism inside the divided domain: $n rows, $ok add up, $shared remove shared latency and pass"
fi

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
            { v = (f == 6) ? $6 - $13 : $f; d = v - w; if (d < 0) d = -d
              ok = ($9 == l && $10 == c && $8 == 10 && d < 0.0005) }
            ok && s == "neg" { ok = ($3 + 0 < 0) }
            ok && s == "pos" { ok = ($3 + 0 > 0) }
            ok && s == "lat" { ok = ($13 + 0 > 0.3 || $14 + 0 > 0.3) }
            END { exit ok ? 0 : 1 }'; then
        report "PASS $name: $(printf '%s\n' "$r" | awk -F'\t' '{ printf "%s -> %s, slack %s ns against %s ns, clock delays %s/%s ns", $9, $10, $3, $8, $13, $14 }')"
    else
        report "FAIL $name: row is '$(printf '%s\n' "$r" | tr '\t' ' ')'"
    fi
}

io_row_arm "input max delay fails setup" full 4 'iopadmap$din_b' clk_i clk 6 10.5 neg
io_row_arm "input max delay control" full 4 'iopadmap$din_a' clk_i clk 6 2.5 pos
io_row_arm "output max delay fails setup" full 1 'dout$intcell$OBUF' clk clk_i 7 9 neg
io_row_arm "input delay on a falling generated clock" full 4 'iopadmap$sd_do' sd_clk clk 6 3 lat
io_row_arm "output max delay to a generated clock at a port" full 1 'sd_di$intcell$OBUF' clk sd_clk 7 6 lat

hold_row_arm() {
    local name=$1 col=$2 pat=$3 launch=$4 capture=$5 field=$6 want=$7 slack=$8 r
    r=$(awk -F'\t' -v col="$col" -v pat="$pat" 'NR > 1 && index($col, pat) > 0' "$OUT/full.hold.tsv")
    if [ -z "$r" ] || [ "$(printf '%s\n' "$r" | wc -l)" -ne 1 ]; then
        report "FAIL $name: $(printf '%s\n' "$r" | grep -c .) hold row(s) for '$pat', expected one"
        return
    fi
    if printf '%s\n' "$r" | awk -F'\t' -v l="$launch" -v c="$capture" -v f="$field" -v w="$want" -v s="$slack" '
            { v = (f == 6) ? $6 - $13 : $f; d = v - w; if (d < 0) d = -d
              e = $6 + $5 - $7 - $8 - $9 + $15 - $3; if (e < 0) e = -e
              ok = ($10 == l && $11 == c && d < 0.0005 && e < 0.002) }
            ok && s == "neg" { ok = ($3 + 0 < 0) }
            ok && s == "pos" { ok = ($3 + 0 > 0) }
            ok && s == "lat" { ok = ($9 + 0 > 0.3) }
            END { exit ok ? 0 : 1 }'; then
        report "PASS $name: $(printf '%s\n' "$r" | awk -F'\t' '{ printf "%s -> %s, hold slack %s ns, hold term %s ns, capture clock %s ns", $10, $11, $3, $7, $9 }')"
    else
        report "FAIL $name: hold row is '$(printf '%s\n' "$r" | tr '\t' ' ')'"
    fi
}

hold_row_arm "input min delay control" 4 'iopadmap$din_a' clk_i clk 6 2 pos
hold_row_arm "input min delay fails hold" 4 'iopadmap$din_b' clk_i clk 6 -3 neg
hold_row_arm "output min delay fails hold" 1 'dout$intcell$OBUF' clk clk_i 7 5 neg
hold_row_arm "output min delay to a generated clock at a port" 1 'sd_di$intcell$OBUF' clk sd_clk 7 2 lat

line=$(grep -m1 'Max delay posedge clk_i (input delay) *-> posedge clk *:' "$OUT/full.log")
case $line in
    *"FAIL against a 10.00 ns edge separation"*) report "PASS input delay verdict: ${line#*Info: }" ;;
    *) report "FAIL input delay verdict: '${line#*Info: }' is not a FAIL against the 10.00 ns separation" ;;
esac

if grep -q 'Input delay .*din_b.*IBUF.OUT' "$OUT/full.log" && grep -q '^Info: 10.5 10.5  Input delay' "$OUT/full.log"; then
    report "PASS path report: the din_b path starts with its 10.5 ns input delay"
else
    report "FAIL path report: no 10.5 ns input delay line opens the din_b path"
fi

if grep -q "set_input_delay on port 'din_a' (.*): clock 'clk_i' is not a generated clock, and the insertion delay .* the hold check of this delay is optimistic" "$OUT/full.log"; then
    report "PASS insertion warning: an input delay against a primary clock says its hold check omits the clock's insertion delay"
else
    report "FAIL insertion warning: no warning that din_a's hold check omits the insertion delay of clk_i"
fi

if grep -q "create_generated_clock 'sck' (.*): the source latency of net 'sd_clk' passes .*, which has no timing arc here and is counted as zero, so the latency is understated by that cell delay: hold checks from the source clock's domain into this one, setup checks from this domain into the source's" "$OUT/full.log"; then
    report "PASS latency warning: the forwarded clock's arc-less output buffer is a warning naming the checks it makes optimistic"
else
    report "FAIL latency warning: no warning that sck's source latency counts its output buffer as zero"
fi

if grep -q "set_input_delay on port 'din_a' (.*): the input buffer has no timing arc in this arch, so the path starts at .* without the buffer's own delay, and its setup check is optimistic" "$OUT/full.log" &&
        grep -q "set_output_delay on port 'dout' (.*): the output buffer has no timing arc in this arch, so the path ends at .* without the buffer's own delay, and its setup check is optimistic" "$OUT/full.log"; then
    report "PASS IO buffer warning: each input and output delay names the buffer delay it omits and the direction"
else
    report "FAIL IO buffer warning: no per-port warning for the arc-less input or output buffer"
fi

if pnr edges --xdc "$HERE/base.xdc" --xdc "$HERE/gen_edges.xdc" --xdc "$HERE/io.xdc" --json "$OUT/top.json" \
        --fasm "$OUT/edges.fasm" --timing-allow-fail; then
    pair_arm edges clk dclk 5
else
    report "FAIL edges: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/edges.log")"
fi

if pnr duty --xdc "$HERE/base.xdc" --xdc "$HERE/gen_duty.xdc" --json "$OUT/top.json" --pack-only; then
    if grep -q "derived 50.0 MHz, high 1/4 of the period, for net 'div' (create_generated_clock from net 'clk')" \
            "$OUT/duty.log"; then
        report "PASS edges duty: -edges {1 2 5} on a half-high source is a 20 ns clock high for its first quarter"
    else
        report "FAIL edges duty: $(grep -m1 "for net 'div'" "$OUT/duty.log")"
    fi
else
    report "FAIL edges duty: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/duty.log")"
fi

if NEXTPNR_TIMING_ONLY=1 pnr replay --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" --xdc "$HERE/gen.xdc" \
        --xdc "$HERE/io.xdc" --json "$OUT/routed.json" --no-pack --no-place --no-route; then
    r=$(rows replay 4 'iopadmap$din_b' | awk -F'\t' '$6 + 0 == 10.5 && $9 == "clk_i" && $10 == "clk"')
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
        --xdc "$HERE/xdc/ports_false_path.xdc" --json "$OUT/top.json" --fasm "$OUT/false_path.fasm" --timing-allow-fail; then
    b=$(rows false_path 4 'iopadmap$din_b')
    o=$(rows false_path 1 'dout$intcell$OBUF')
    a=$(rows false_path 4 'iopadmap$din_a')
    hb=$(awk -F'\t' 'NR > 1 && (index($4, "iopadmap$din_b") || index($1, "dout$intcell$OBUF"))' "$OUT/false_path.hold.tsv")
    if [ -z "$b" ] && [ -z "$o" ] && [ -z "$hb" ] && [ -n "$a" ]; then
        report "PASS false path: set_false_path -from/-to [get_ports ...] removes the din_b and dout setup and hold checks and keeps din_a"
    else
        report "FAIL false path: din_b row [$b], dout row [$o], hold rows [$hb], din_a row [$a]"
    fi
else
    report "FAIL false path: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/false_path.log")"
fi

strict_arm() {
    local name=$1 why=$2 gen=(--xdc "$HERE/gen.xdc")
    [ "${3:-}" = nogen ] && gen=()
    if pnr "strict_$name" --xdc "$HERE/base.xdc" "${gen[@]}" --xdc "$HERE/xdc/$name.xdc" --xdc-strict \
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
strict_arm divide_multiply "-divide_by and -multiply_by together are not read"
strict_arm clock_typo "clock 'no_such_clk' matched no clock"
strict_arm min_only "has a -min delay and no -max delay"
strict_arm no_source "-source: get_pins 'no_such_cell/O' matched 0 cells"
strict_arm clock_data_pad "clock 'dout' matched no clock"
strict_arm clock_unconstrained "no clock constraint reaches net 'dclk', which its -clock names" nogen

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

if NEXTPNR_TIMING_ONLY=1 pnr same_clock --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" --xdc "$HERE/same_clock.xdc" \
        --json "$OUT/routed.json" --no-pack --no-place --no-route --timing-allow-fail; then
    io=$(grep -m1 'Max delay posedge clk (input delay) *-> posedge clk *:' "$OUT/same_clock.log")
    fm=$(grep -m1 "Max frequency for clock *'clk':" "$OUT/same_clock.log")
    case "$io|$fm" in
        *"FAIL against a 10.00 ns period of the clock"*"|"*PASS*)
            report "PASS same-clock input delay: graded as its own check (${io#*Info: }), not folded into the Fmax figure (${fm#*Info: })" ;;
        *) report "FAIL same-clock input delay: IO line '${io#*Info: }', Fmax line '${fm#*Info: }'" ;;
    esac
else
    report "FAIL same-clock input delay: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/same_clock.log")"
fi

if NEXTPNR_TIMING_ONLY=1 pnr no_endpoint --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" --xdc "$HERE/no_endpoint.xdc" \
        --json "$OUT/routed.json" --no-pack --no-place --no-route; then
    if grep -q "set_input_delay on port 'clk_i' (.*) times nothing: no timed endpoint is reachable" \
            "$OUT/no_endpoint.log" && grep -q "set_input_delay on port 'din_a': max 1.000 ns, .* timed at" \
            "$OUT/no_endpoint.log"; then
        report "PASS no endpoint: an input delay that reaches no timed endpoint is warned, din_a beside it is timed"
    else
        report "FAIL no endpoint: no 'times nothing' warning for clk_i, or din_a is not timed"
    fi
else
    report "FAIL no endpoint: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/no_endpoint.log")"
fi

if NEXTPNR_TIMING_ONLY=1 pnr add_delay --xdc "$HERE/base.xdc" --xdc "$HERE/replay.xdc" --xdc "$HERE/add_delay.xdc" \
        --json "$OUT/routed.json" --no-pack --no-place --no-route; then
    if grep -q "set_input_delay on port 'din_b': max 9.500 ns, min 0.500 ns," "$OUT/add_delay.log"; then
        report "PASS add_delay: on the same clock edge -add_delay keeps the larger max and the smaller min"
    else
        report "FAIL add_delay: $(grep -m1 "set_input_delay on port 'din_b'" "$OUT/add_delay.log")"
    fi
else
    report "FAIL add_delay: nextpnr exited non-zero: $(grep -m1 '^ERROR' "$OUT/add_delay.log")"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
