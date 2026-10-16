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

fmax_line() {
    grep "Max frequency for clock 'clk'" "$1" | tail -1 | sed 's/^Info: //'
}

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --xdc "$HERE/clock.xdc" --json "$OUT/top.json" \
        --write "$OUT/routed.json" --log "$OUT/full.log" -q --seed 1 >/dev/null 2>&1; then
    echo "FAIL nextpnr place and route: $(grep -m1 '^ERROR' "$OUT/full.log")"
    exit 1
fi

if ! NEXTPNR_TIMING_ONLY=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --log "$OUT/replay.log" -q >/dev/null 2>&1; then
    echo "FAIL replay: $(grep -m1 '^ERROR' "$OUT/replay.log")"
    exit 1
fi
line=$(fmax_line "$OUT/replay.log")
case $line in
    *UNCONSTRAINED*) report "PASS replay with no clock constraint: $line" ;;
    *) report "FAIL replay with no clock constraint: '$line'" ;;
esac

if ! NEXTPNR_TIMING_ONLY=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --freq 100 --log "$OUT/replay-freq.log" -q >/dev/null 2>&1; then
    report "FAIL replay with --freq 100: $(grep -m1 '^ERROR' "$OUT/replay-freq.log")"
else
    line=$(fmax_line "$OUT/replay-freq.log")
    case $line in
        *"PASS at 100.00 MHz"* | *"FAIL at 100.00 MHz"*) report "PASS replay with --freq 100: $line" ;;
        *) report "FAIL replay with --freq 100: '$line'" ;;
    esac
fi

line=$(fmax_line "$OUT/full.log")
case $line in
    *"PASS at 100.00 MHz"* | *"FAIL at 100.00 MHz"*) report "PASS create_clock run: $line" ;;
    *) report "FAIL create_clock run: '$line'" ;;
esac

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" --json "$OUT/top.json" --freq 50 \
        --write "$OUT/freq.json" --log "$OUT/freq.log" -q --seed 1 >/dev/null 2>&1; then
    report "FAIL --freq run: $(grep -m1 '^ERROR' "$OUT/freq.log")"
else
    line=$(fmax_line "$OUT/freq.log")
    case $line in
        *"PASS at 50.00 MHz"* | *"FAIL at 50.00 MHz"*) report "PASS --freq run: $line" ;;
        *) report "FAIL --freq run: '$line'" ;;
    esac
fi

if [ -s "$OUT/freq.json" ] && NEXTPNR_TIMING_ONLY=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/pins.xdc" \
        --json "$OUT/freq.json" --no-pack --no-place --no-route --log "$OUT/replay-50.log" -q >/dev/null 2>&1; then
    line=$(fmax_line "$OUT/replay-50.log")
    case $line in
        *"PASS at 50.00 MHz"* | *"FAIL at 50.00 MHz"*) report "PASS replay of the --freq 50 run: $line" ;;
        *) report "FAIL replay of the --freq 50 run: '$line'" ;;
    esac
else
    report "FAIL replay of the --freq 50 run: $(grep -m1 '^ERROR' "$OUT/replay-50.log" 2>/dev/null)"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
