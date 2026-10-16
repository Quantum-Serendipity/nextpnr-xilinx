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
NPNR_TIMEOUT=${NPNR_TIMEOUT:-600}
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

npnr() {
    local log=$1
    shift
    timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q "$@" >/dev/null 2>&1
}

if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! npnr "$OUT/place.log" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --write "$OUT/placed.json" --no-route \
        --seed 1; then
    echo "FAIL base placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi
if ! npnr "$OUT/route.log" --json "$OUT/placed.json" --no-pack --no-place --write "$OUT/routed.json" \
        --write-fixed-routes "$OUT/all.routes"; then
    echo "FAIL base route: $(grep -m1 '^ERROR' "$OUT/route.log")"
    exit 1
fi

arm_region_only_keeps_output() {
    local f=$OUT/l29.routes
    printf 'sentinel-net TILE/0.0\n' >"$f"
    local want
    want=$(cksum <"$f")
    env -u NEXTPNR_PARTITION_ROI timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/routed.json" \
        --no-pack --no-place --no-route --write-fixed-routes "$f" --region-only --log "$OUT/l29.log" -q \
        >/dev/null 2>&1
    local rc=$?
    local refused
    refused=$(grep -c 'region-only needs a partition rectangle' "$OUT/l29.log")
    if [ "$rc" -ne 0 ] && [ "$refused" -gt 0 ] && [ "$(cksum <"$f")" = "$want" ]; then
        report "PASS write-fixed-routes --region-only without a rectangle: refused at rc $rc, output left as it was"
    else
        report "FAIL write-fixed-routes --region-only without a rectangle: rc $rc, $refused refusal line(s), output now $(wc -c <"$f") byte(s)"
    fi
}

arm_region_only_keeps_output

echo "artefacts kept in $OUT"
exit "$rc_total"
