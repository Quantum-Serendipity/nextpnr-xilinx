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
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tcsg324.bin}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    local verdict=$1
    shift
    echo "$verdict $*"
    [ "$verdict" = PASS ] || rc_total=1
}

pnr() {
    local v=$1
    if ! "$YOSYS" -q -l "$OUT/$v.yosys.log" \
            -p "read_verilog \"$HERE/$v.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
            >/dev/null 2>&1; then
        echo yosys
        return
    fi
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/fasm-params.xdc" --json "$OUT/$v.json" \
        --fasm "$OUT/$v.fasm" --log "$OUT/$v.npnr.log" -q --seed 1 >/dev/null 2>&1
    echo $?
}

builds() {
    local v=$1 rc
    rc=$(pnr "$v")
    if [ "$rc" = 0 ]; then
        return 0
    fi
    report FAIL "$v: build rc $rc, want 0"
    return 1
}

refuses() {
    local v=$1 want=$2 rc
    rc=$(pnr "$v")
    if [ "$rc" != 0 ] && [ "$rc" != yosys ] && grep -qF -- "$want" "$OUT/$v.npnr.log"; then
        report PASS "$v: refused (rc $rc) with '$want'"
    else
        report FAIL "$v: rc $rc, want a refusal naming '$want'"
    fi
}

feature() {
    local v=$1 pattern=$2 want=$3 got
    got=$(grep -E -- "$pattern" "$OUT/$v.fasm" | sed 's/^[^.]*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        report PASS "$v: $pattern -> $got"
    else
        report FAIL "$v: $pattern -> '$got', want '$want'"
    fi
}

lines() {
    local v=$1 pattern=$2 want=$3 got
    got=$(grep -cE -- "$pattern" "$OUT/$v.fasm")
    [ "$got" = "$want" ] && report PASS "$v: $got line(s) matching $pattern" ||
        report FAIL "$v: $got line(s) matching $pattern, want $want"
}

if builds mmcm_d128_p90; then
    feature mmcm_d128_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'MMCME2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b100000'
fi
refuses mmcm_d128_p180 'PHASE_OUT_OF_RANGE'
refuses mmcm_d100_p270 'PHASE_OUT_OF_RANGE'
if builds pll_d100_p90; then
    feature pll_d100_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'PLLE2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b011001'
fi
refuses pll_d100_p270 'PHASE_OUT_OF_RANGE'

echo "artefacts kept in $OUT"
exit "$rc_total"
