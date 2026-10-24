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
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc" --json "$OUT/top.json" \
        --log "$OUT/$name.log" -q --seed 1 "$@" >/dev/null 2>&1
}

replay() {
    local name=$1
    shift
    NEXTPNR_TIMING_ONLY=1 "$NEXTPNR" --chipdb "$CHIPDB" "$@" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --log "$OUT/$name.log" -q >/dev/null 2>&1
}

column_values() {
    awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "delay_source") c = i; next }
                c { print $c } END { if (!c) print "(no delay_source column)" }' "$1" | sort | uniq -c | tr -s ' \n' ' '
}

if ! NEXTPNR_SETUP_EXPORT="$OUT/routed.tsv" NEXTPNR_HOLD_EXPORT="$OUT/routed-hold.tsv" pnr full --write "$OUT/routed.json"; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/full.log")"
    exit 1
fi
if ! NEXTPNR_SETUP_EXPORT="$OUT/replay.tsv" replay replay --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc"; then
    echo "FAIL replay: $(grep -m1 '^ERROR' "$OUT/replay.log")"
    exit 1
fi

got=$(column_values "$OUT/routed.tsv")
case $got in
    *routed*estimate* | *estimate* | *"no delay_source"*) report "FAIL router2 export: delay_source values [$got]" ;;
    *routed*) report "PASS router2 export: delay_source values [$got]" ;;
    *) report "FAIL router2 export: delay_source values [$got]" ;;
esac

slack_of() {
    awk -F'\t' 'NR > 1 { print $1 "\t" $2 "\t" $9 "\t" $10 "\t" $3 }' "$1" | sort
}
if [ -s "$OUT/replay.tsv" ] && [ "$(slack_of "$OUT/routed.tsv")" = "$(slack_of "$OUT/replay.tsv")" ]; then
    report "PASS router2 export: every row's slack equals the routed-JSON replay's"
else
    n=$(diff <(slack_of "$OUT/routed.tsv") <(slack_of "$OUT/replay.tsv") | grep -c '^<')
    report "FAIL router2 export: $n row(s) differ from the routed-JSON replay"
fi

ident=$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i
                               if (!col["capture_clk_delay_ns"] || !col["launch_clk_delay_ns"] || !col["requirement_source"]) { print "missing-columns"; exit }
                               next }
                     { n++; r = $col["period_ns"] - $col["driver_arrival_ns"] - $col["net_delay_ns"] - $col["setup_ns"] + $col["capture_clk_delay_ns"] - $col["slack_ns"]
                       if (r < 0) r = -r
                       if (r > worst) worst = r
                       if ($col["launch_clk_delay_ns"] <= 0 || $col["capture_clk_delay_ns"] <= 0) nonpos++
                       src[$col["requirement_source"]]++ }
                     END { if (!col["requirement_source"]) exit
                           s = ""; for (k in src) s = s k ":" src[k] " "
                           printf "%d %.4f %d %s\n", n, worst, nonpos, s }' "$OUT/routed.tsv")
read -r id_n id_worst id_nonpos id_src <<<"$ident"
if [ "$ident" != missing-columns ] && [ "${id_n:-0}" -gt 0 ] && awk -v w="$id_worst" 'BEGIN { exit !(w <= 0.0015) }' \
        && [ "$id_nonpos" = 0 ] && [ "$id_src" = "same:$id_n" ]; then
    report "PASS row identity: slack = period - (driver_arrival + net_delay + setup - capture_clk_delay) on all $id_n rows (worst residual $id_worst ns), both clock delays positive, requirement_source [$id_src]"
else
    report "FAIL row identity: [$ident]"
fi

hident=$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i
                                if (!col["cppr_ns"] || !col["launch_clk_delay_ns"]) { print "missing-columns"; exit }
                                next }
                      $col["delay_source"] == "routed" {
                        n++; r = $col["driver_min_arrival_ns"] + $col["net_delay_min_ns"] - $col["hold_ns"] - $col["hold_req_ns"] - $col["capture_clk_delay_ns"] + $col["cppr_ns"] - $col["hold_slack_ns"]
                        if (r < 0) r = -r
                        if (r > worst) worst = r
                        if (!($col["cppr_ns"] > 0 && $col["cppr_ns"] < $col["capture_clk_delay_ns"])) bad++
                        if (!($col["launch_clk_delay_ns"] < $col["capture_clk_delay_ns"])) bad++ }
                      END { if (!col["cppr_ns"]) exit
                            printf "%d %.4f %d\n", n, worst, bad }' "$OUT/routed-hold.tsv")
read -r h_n h_worst h_bad <<<"$hident"
if [ "$hident" != missing-columns ] && [ "${h_n:-0}" -gt 0 ] && [ "$h_bad" = 0 ] \
        && awk -v w="$h_worst" 'BEGIN { exit !(w <= 0.0015) }'; then
    report "PASS hold launch corner: on all $h_n routed hold rows hold_slack = driver_min_arrival + net_delay_min - hold - hold_req - capture_clk_delay + cppr (worst residual $h_worst ns), the fast-corner launch delay is below the slow-corner capture delay, and 0 < cppr_ns < capture_clk_delay_ns"
else
    report "FAIL hold launch corner: [$hident]"
fi

hops() {
    CLOCKHOPS_OUT="$2" "$NEXTPNR" --chipdb "$CHIPDB" --json "$1" --run "$HERE/clockhops.py" \
        --log "$2.log" -q >/dev/null 2>&1
}
if hops "$OUT/routed.json" "$OUT/clockhops.tsv"; then
    "${PYTHON:-python3}" "$HERE/cppr.py" "$OUT/routed.json" "$OUT/routed.tsv" "$OUT/routed-hold.tsv" \
        "$OUT/clockhops.tsv" bufg > "$OUT/cppr.out" 2>&1
    report "$(tail -1 "$OUT/cppr.out")"
else
    report "FAIL hold CPPR bufg: the clock-hop dump failed: $(grep -m1 -E '^ERROR|Error' "$OUT/clockhops.tsv.log")"
fi

if ! "$YOSYS" -q -l "$OUT/fab-yosys.log" \
        -p "read_verilog \"$HERE/fabclk.v\"; synth_xilinx -flatten -abc9 -noclkbuf -arch xc7 -top top; write_json \"$OUT/fab.json\"" \
        >/dev/null 2>&1; then
    report "FAIL hold CPPR fabric: yosys"
elif ! NEXTPNR_SETUP_EXPORT="$OUT/fab.tsv" NEXTPNR_HOLD_EXPORT="$OUT/fab-hold.tsv" "$NEXTPNR" --chipdb "$CHIPDB" \
        --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc" --json "$OUT/fab.json" --write "$OUT/fab-routed.json" \
        --log "$OUT/fab.log" -q --seed 1 >/dev/null 2>&1; then
    report "FAIL hold CPPR fabric: nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/fab.log")"
elif ! hops "$OUT/fab-routed.json" "$OUT/fab-clockhops.tsv"; then
    report "FAIL hold CPPR fabric: the clock-hop dump failed: $(grep -m1 -E '^ERROR|Error' "$OUT/fab-clockhops.tsv.log")"
else
    "${PYTHON:-python3}" "$HERE/cppr.py" "$OUT/fab-routed.json" "$OUT/fab.tsv" "$OUT/fab-hold.tsv" \
        "$OUT/fab-clockhops.tsv" fabric > "$OUT/fab-cppr.out" 2>&1
    report "$(tail -1 "$OUT/fab-cppr.out")"
fi

if ! NEXTPNR_POST_ROUTE_TIMING=0 NEXTPNR_SETUP_EXPORT="$OUT/placed.tsv" pnr placed; then
    report "FAIL placement-only export: nextpnr exited non-zero"
else
    got=$(column_values "$OUT/placed.tsv")
    case $got in
        *routed*) report "FAIL placement-only export: delay_source values [$got]" ;;
        *estimate*) report "PASS placement-only export: delay_source values [$got]" ;;
        *) report "FAIL placement-only export: delay_source values [$got]" ;;
    esac
fi

NEXTPNR_SETUP_EXPORT="$OUT/no/such/dir/setup.tsv" replay unwritable --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "NEXTPNR_SETUP_EXPORT" "$OUT/unwritable.log"; then
    report "PASS unwritable export: refused (rc $rc): $(grep -m1 '^ERROR' "$OUT/unwritable.log")"
else
    report "FAIL unwritable export: rc $rc and no error naming NEXTPNR_SETUP_EXPORT"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
