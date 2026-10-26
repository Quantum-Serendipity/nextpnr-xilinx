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
    local v=$1 xdc=$2 tag=$3
    shift 3
    if [ ! -f "$OUT/$v.json" ] && ! "$YOSYS" -q -l "$OUT/$v.yosys.log" \
            -p "read_verilog \"$HERE/$v.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
            >/dev/null 2>&1; then
        echo yosys
        return
    fi
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/$xdc.xdc" --json "$OUT/$v.json" \
        --fasm "$OUT/$tag.fasm" --log "$OUT/$tag.npnr.log" -q --seed 1 "$@" >/dev/null 2>&1
    echo $?
}

zinv_t() {
    local v=$1 xdc=$2 want=$3 tag got rc
    shift 3
    tag=$v.$xdc${1:+.${1#--}${2:+-$2}}
    rc=$(pnr "$v" "$xdc" "$tag" "$@")
    if [ "$rc" != 0 ]; then
        report FAIL "$tag: build rc $rc, want 0"
        return
    fi
    if [ "$(grep -cE '\.[LR]?IOI_T[01]\.[LR]?IOI_OLOGIC[01]_TQ$' "$OUT/$tag.fasm")" != 1 ]; then
        report FAIL "$tag: TQ does not reach the pad tristate through one OLOGIC TQ pip"
        return
    fi
    got=$(grep -E '\.OLOGIC_Y[01]\.ZINV_T[1-4]$' "$OUT/$tag.fasm" | sed 's/^[^.]*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        report PASS "$tag: ZINV_Tn -> '${got}'"
    else
        report FAIL "$tag: ZINV_Tn -> '$got', want '$want'"
    fi
}

zinv_t t1_tie0 sing ''
zinv_t t1_tie0 sing '' --router router1
zinv_t t1_tie0 pair ''
zinv_t t1_tie1_isinv sing ''
zinv_t t1_tie1 sing 'OLOGIC_Y0.ZINV_T1'
zinv_t t1_signal sing 'OLOGIC_Y0.ZINV_T1'
zinv_t t1_signal pair 'OLOGIC_Y1.ZINV_T1'

echo "artefacts kept in $OUT"
exit "$rc_total"
