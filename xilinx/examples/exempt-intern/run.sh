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
if ! timeout 600 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --write "$OUT/placed.json" \
        --no-route --seed 1 --log "$OUT/place.log" -q >/dev/null 2>&1; then
    echo "FAIL base placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi
printf '{"info": {"GRID_X_MIN": 0, "GRID_X_MAX": 20, "GRID_Y_MIN": 0, "GRID_Y_MAX": 200}}\n' >"$OUT/roi.json"
printf 'no_such_net_stale_a\nno_such_net_stale_b\n' >"$OUT/stale.nets"

route() {
    local tag=$1
    shift
    env NEXTPNR_PARTITION_ROI="$OUT/roi.json" "$@" timeout 600 "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/$tag.json" --write-fixed-routes "$OUT/$tag.routes" --fasm "$OUT/$tag.fasm" \
        --log "$OUT/$tag.log" -q >/dev/null 2>&1
}

route clean
rc_clean=$?
route stale NEXTPNR_PARTITION_EXEMPT_NETS="$OUT/stale.nets" NEXTPNR_PARTITION_KEEPOUT_EXEMPT="$OUT/stale.nets"
rc_stale=$?
if [ "$rc_clean" -eq 0 ] && [ "$rc_stale" -eq 0 ] \
        && grep -q 'partition net exemptions: 0 net(s) exempt from invariant P, from .*stale.nets (2 unresolved)' "$OUT/stale.log"; then
    report "PASS stale exemption names are counted unresolved: both routes rc 0, 2 unresolved"
else
    report "FAIL stale exemption names are counted unresolved: rc $rc_clean and $rc_stale, $(grep -m1 -E '^ERROR|partition net exemptions' "$OUT/stale.log")"
fi
if cmp -s "$OUT/clean.fasm" "$OUT/stale.fasm" && cmp -s <(grep -v '^#' "$OUT/clean.routes") <(grep -v '^#' "$OUT/stale.routes"); then
    report "PASS stale exemption names leave the FASM and the routes unchanged"
else
    report "FAIL stale exemption names leave the FASM and the routes unchanged"
fi
if [ "$(grep -c '"partition_modes"' "$OUT/clean.json")" -eq 1 ] \
        && cmp -s <(grep -v '"partition_modes"' "$OUT/clean.json") <(grep -v '"partition_modes"' "$OUT/stale.json"); then
    report "PASS stale exemption names leave the written netlist unchanged outside the partition_modes record"
else
    report "FAIL stale exemption names leave the written netlist unchanged outside the partition_modes record: $(diff <(grep -v '"partition_modes"' "$OUT/clean.json") <(grep -v '"partition_modes"' "$OUT/stale.json") | grep -c '^[<>]') differing line(s)"
fi
echo "artefacts kept in $OUT"
exit "$rc_total"
