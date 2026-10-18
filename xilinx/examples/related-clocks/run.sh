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

build() {
    local name=$1 xdc=${2:-related-clocks.xdc} tag=${3:-$1} expect_rc=${4:-0} router=${5:-} allow=${6:-} def=${7:-} rc
    if ! "$YOSYS" -q -l "$OUT/$tag.yosys.log" \
            -p "read_verilog ${def:+-D$def} \"$HERE/$name.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$tag.json\"" \
            >/dev/null 2>&1; then
        echo "FAIL yosys $tag"
        exit 1
    fi
    NEXTPNR_SETUP_EXPORT="$OUT/$tag.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/$xdc" \
        --json "$OUT/$tag.json" --fasm "$OUT/$tag.fasm" --log "$OUT/$tag.log" -q --seed 1 \
        ${router:+--router "$router"} ${allow:+--timing-allow-fail} >/dev/null 2>&1
    rc=$?
    echo "$rc" > "$OUT/$tag.rc"
    if [ "$expect_rc" = 0 ] && [ "$rc" != 0 ]; then
        echo "FAIL nextpnr place and route $tag: $(grep -m1 '^ERROR' "$OUT/$tag.log")"
        exit 1
    fi
}

periods() {
    awk -F'\t' -v l="$2" -v c="$3" 'NR > 1 && $9 == l && $10 == c { print $8 }' "$OUT/$1.tsv" | sort -u | tr '\n' ' '
}

build top
build coincident
build three three.xdc
build unrelated unrelated.xdc
build top top-exc.xdc top-exc
build three three-mismatch.xdc three-mismatch
build three three-pad.xdc three-pad
build unrelated unrelated-tight.xdc unrelated-tight 1 router1
build unrelated unrelated-tight.xdc unrelated-tight-allow 0 router1 allow
build order order-pad.xdc order-pad-last 0 "" "" MMCM_NAME=mmcm
build order order-pad.xdc order-pad-first 0 "" "" MMCM_NAME=a_mmcm

pair_arm() {
    local launch=$1 capture=$2 want=$3 design=${4:-top} got
    got=$(periods "$design" "$launch" "$capture")
    if [ "$got" = "$want " ]; then
        report "PASS $design $launch -> $capture: every row graded against $want ns"
    else
        report "FAIL $design $launch -> $capture: rows graded against [${got% }] ns, expected $want ns"
    fi
}

verdict_arm() {
    local design=$1 launch=$2 capture=$3 want=$4 lines n bad
    lines=$(grep -E "Max delay posedge $launch +-> posedge $capture *:" "$OUT/$design.log")
    n=$(printf '%s' "$lines" | grep -c .)
    bad=$(printf '%s\n' "$lines" | grep -v -F -- "$want" | head -n1)
    if [ "$n" -gt 0 ] && [ -z "$bad" ]; then
        report "PASS $design verdict, all $n reports: $(printf '%s\n' "$lines" | tail -n1 | sed 's/^[A-Za-z]*: //')"
    elif [ "$n" -eq 0 ]; then
        report "FAIL $design verdict: no '$launch -> $capture' max-delay line"
    else
        report "FAIL $design verdict: '$(printf '%s' "$bad" | sed 's/^[A-Za-z]*: //')' does not carry '$want'"
    fi
}

pair_arm b0 b1 5
pair_arm b0 b2 10
pair_arm b0 b0 10

line=$(grep -m1 'Max delay posedge b0 -> posedge b1:' "$OUT/top.log")
case $line in
    *"against a 5.00 ns edge separation"*) report "PASS cross-domain verdict: ${line#*Info: }" ;;
    *) report "FAIL cross-domain verdict: '${line#*Info: }' carries no verdict against the 5.00 ns edge separation" ;;
esac

line=$(grep -m1 "derived .* for net 'fb'" "$OUT/top.log")
case $line in
    *"derived 100.0 MHz for net 'fb'"*) report "PASS feedback clock: ${line#*Info: }" ;;
    *) report "FAIL feedback clock: '${line#*Info: }', expected 100.0 MHz (CLKFBOUT runs at the input rate over DIVCLK_DIVIDE)" ;;
esac

got=$(periods coincident b1 b0)
if [ "$got" = "4.166 " ]; then
    report "PASS coincident b1 -> b0: every row graded against one 240 MHz period, 4.166 ns"
else
    report "FAIL coincident b1 -> b0: rows graded against [${got% }] ns, expected 4.166 ns (b1's 180 degree edges land on b0 edges)"
fi

line=$(grep -m1 'Max delay posedge b1 -> posedge b0:' "$OUT/coincident.log")
case $line in
    *"against a 4.17 ns edge separation"*) report "PASS coincident cross-domain verdict: ${line#*Info: }" ;;
    *) report "FAIL coincident cross-domain verdict: '${line#*Info: }', expected a 4.17 ns edge separation" ;;
esac

pair_arm clk pix_clk 5 three
pair_arm pix_clk clk 5 three
verdict_arm three clk pix_clk "against a 5.00 ns edge separation; related through 'clk'"
verdict_arm three pix_clk clk "against a 5.00 ns edge separation; related through 'clk'"

line=$(grep -m1 'Clock domain grading:' "$OUT/three.log")
case $line in
    *"grading: 3 constrained, "*"; 0 graded and 0 ungraded with no create_clock"*)
        report "PASS three population: ${line#*Info: }" ;;
    *) report "FAIL three population: '${line#*Info: }', expected only the three create_clock nets constrained" ;;
esac

pair_arm clk sclk 10 unrelated
pair_arm sclk clk 10 unrelated
verdict_arm unrelated clk sclk "against a 10.00 ns shorter of the two periods; no derived relation"

verdict_arm top-exc b0 b1 "against a 5.00 ns requirement set by a timing exception; related through 'clk_i'"

line=$(grep -m1 "carries the .* XDC constraint of net 'pix_clk'" "$OUT/three-mismatch.log")
case $line in
    *"net 'o0' carries the 41.7 MHz XDC constraint of net 'pix_clk'; the 40.0 MHz derived through 'mmcm' is not applied"*)
        report "PASS three-mismatch warning: ${line#*Warning: }" ;;
    *) report "FAIL three-mismatch warning: '${line#*Warning: }', expected o0 to refuse the 40.0 MHz derivation" ;;
esac
pair_arm clk pix_clk 10 three-mismatch
verdict_arm three-mismatch clk pix_clk "against a 10.00 ns shorter of the two periods; no derived relation"

line=$(grep -m1 "net 'clk' is constrained to .* by the XDC; the .* derived through" "$OUT/three-pad.log")
case $line in
    *"net 'clk' is constrained to 100.0 MHz by the XDC; the 125.0 MHz derived through 'gs' is not applied"*)
        report "PASS three-pad warning: ${line#*Warning: }" ;;
    *) report "FAIL three-pad warning: '${line#*Warning: }', expected clk to refuse the 125.0 MHz derivation from the pad" ;;
esac
pair_arm clk pix_clk 10 three-pad
pair_arm pix_clk clk 10 three-pad
verdict_arm three-pad clk pix_clk "against a 10.00 ns shorter of the two periods; no derived relation"
verdict_arm three-pad pix_clk clk "against a 10.00 ns shorter of the two periods; no derived relation"

order_arm() {
    local design=$1 cell=$2 want=$3 line
    line=$(grep -m1 "MMCME2_BASE '$cell': input " "$OUT/$design.log")
    case $line in
        *"input $want MHz"*) report "PASS $design order: the first propagation through '$cell' saw ${line#*input }" ;;
        *) report "FAIL $design order: '${line#*Info: }', expected the first propagation through '$cell' to see $want MHz" ;;
    esac
}
order_arm order-pad-last mmcm 125.0
order_arm order-pad-first a_mmcm 100.0
pair_arm pix_clk_g aux_clk 4 order-pad-last
pair_arm pix_clk_g aux_clk 4 order-pad-first
verdict_arm order-pad-last pix_clk_g aux_clk "against a 4.00 ns edge separation; related through 'clk_i'"
verdict_arm order-pad-first pix_clk_g aux_clk "against a 4.00 ns edge separation; related through 'clk_i'"

rc=$(cat "$OUT/unrelated-tight.rc")
line=$(grep -m1 -E '^ERROR: Max delay posedge clk +-> posedge sclk *:' "$OUT/unrelated-tight.log")
others=$(grep '^ERROR: ' "$OUT/unrelated-tight.log" | grep -v '^ERROR: Max delay ' | head -n1)
case "$rc|$line|$others" in
    "1|"*"FAIL against a 0.80 ns shorter of the two periods; no derived relation"*"|")
        report "PASS unrelated-tight: rc 1, ${line#ERROR: }" ;;
    *) report "FAIL unrelated-tight: rc $rc, max-delay error '$line', other error '$others'; expected rc 1 from a FAIL against 0.80 ns alone" ;;
esac

rc=$(cat "$OUT/unrelated-tight-allow.rc")
line=$(grep -m1 -E '^Warning: Max delay posedge clk +-> posedge sclk *:' "$OUT/unrelated-tight-allow.log")
errs=$(grep -c '^ERROR: ' "$OUT/unrelated-tight-allow.log")
case "$rc|$line|$errs" in
    "0|"*"FAIL against a 0.80 ns shorter of the two periods; no derived relation"*"|0")
        report "PASS unrelated-tight-allow: rc 0 under --timing-allow-fail, ${line#Warning: }" ;;
    *) report "FAIL unrelated-tight-allow: rc $rc, max-delay warning '$line', $errs ERROR line(s); expected rc 0 and the FAIL as a Warning" ;;
esac

echo "artefacts kept in $OUT"
exit "$rc_total"
