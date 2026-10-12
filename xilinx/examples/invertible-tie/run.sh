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

FAMILIES=(
    "pll_rst       PLLE2_ADV.ZINV_RST         1 0 yes"
    "pll_pwrdwn    PLLE2_ADV.ZINV_PWRDWN      1 0 yes"
    "mmcm_rst      MMCME2_ADV.ZINV_RST        1 0 yes"
    "mmcm_pwrdwn   MMCME2_ADV.ZINV_PWRDWN     1 0 yes"
    "bram_rstreg   ZINV_RSTREGARSTREG         0 1 yes"
    "bufgctrl_ce1  ZINV_CE1                   0 1 yes"
    "dsp_alumode0  ZIS_ALUMODE_INVERTED[0]    0 1 yes"
    "oddr_d1       IS_D1_INVERTED             1 0 no"
)

rc_total=0
built=()

build() {
    local v=$1 b
    for b in "${built[@]+"${built[@]}"}"; do [ "$b" = "$v" ] && return 0; done
    if ! "$YOSYS" -q -l "$OUT/$v.yosys.log" \
            -p "read_verilog \"$HERE/$v.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
            >/dev/null 2>&1; then
        echo "FAIL $v: yosys"
        return 1
    fi
    if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/invertible-tie.xdc" --json "$OUT/$v.json" \
            --fasm "$OUT/$v.fasm" --log "$OUT/$v.npnr.log" -q --seed 1 >/dev/null 2>&1; then
        echo "FAIL $v: nextpnr"
        return 1
    fi
    built+=("$v")
}

count() {
    grep -cF -- "$2" "$OUT/$1.fasm"
}

same_fasm() {
    if cmp -s "$OUT/$1.fasm" "$OUT/$2.fasm"; then
        echo "whole FASM"
    elif diff -q <(sort "$OUT/$1.fasm") <(sort "$OUT/$2.fasm") >/dev/null; then
        echo "sorted FASM"
    else
        return 1
    fi
}

report() {
    local verdict=$1
    shift
    if [ "$verdict" = PASS ]; then
        echo "PASS $*"
    else
        echo "FAIL $*"
        rc_total=1
    fi
}

for fam in "${FAMILIES[@]}"; do
    read -r f bit w0 w1 absent <<<"$fam"
    cases=(tie0 tie1 tie0isinv)
    [ "$absent" = yes ] && cases+=(absentisinv)
    ok=1
    for c in "${cases[@]}"; do build "${f}_$c" || ok=0; done
    if [ "$ok" -ne 1 ]; then rc_total=1; continue; fi

    g0=$(count "${f}_tie0" "$bit")
    g1=$(count "${f}_tie1" "$bit")
    [ "$g0" = "$w0" ] && v=PASS || v=FAIL
    report "$v" "${f}_tie0: $bit count $g0, want $w0"
    [ "$g1" = "$w1" ] && v=PASS || v=FAIL
    report "$v" "${f}_tie1: $bit count $g1, want $w1"

    for c in "${cases[@]}"; do
        case $c in tie0isinv|absentisinv) ;; *) continue ;; esac
        if how=$(same_fasm "${f}_$c" "${f}_tie1"); then
            report PASS "${f}_$c == ${f}_tie1 ($how)"
        else
            report FAIL "${f}_$c != ${f}_tie1"
        fi
    done
done

if build bufgmux_undrv; then
    s0=$(count bufgmux_undrv ZINV_S0)
    s1=$(count bufgmux_undrv ZINV_S1)
    [ "$s0" = 2 ] && [ "$s1" = 0 ] && v=PASS || v=FAIL
    report "$v" "bufgmux_undrv: ZINV_S0 count $s0 want 2, ZINV_S1 count $s1 want 0 (I0 selected)"
else
    rc_total=1
fi

if build pllbase_pwrdwn_tie0 && build pllbase_pwrdwn_tie1; then
    g0=$(count pllbase_pwrdwn_tie0 PLLE2_ADV.ZINV_PWRDWN)
    g1=$(count pllbase_pwrdwn_tie1 PLLE2_ADV.ZINV_PWRDWN)
    [ "$g0" = 1 ] && [ "$g1" = 0 ] && v=PASS || v=FAIL
    report "$v" "pllbase_pwrdwn: ZINV_PWRDWN count tie0 $g0 want 1, tie1 $g1 want 0"
else
    rc_total=1
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
