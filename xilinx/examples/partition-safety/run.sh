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

roi() {
    printf '{"info": {"GRID_X_MIN": %d, "GRID_X_MAX": %d, "GRID_Y_MIN": %d, "GRID_Y_MAX": %d}}\n' "$2" "$4" "$3" "$5" \
        >"$1"
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

arm_fixed_routes_command_line_wins() {
    local a=$OUT/m11-a.routes b=$OUT/m11-b.routes
    printf '# nextpnr-xilinx fixed-routes: <net> <tile>/<src_idx>.<dst_idx>\n' >"$a"
    cp "$a" "$b"
    if ! npnr "$OUT/m11-a.log" --json "$OUT/placed.json" --no-pack --no-place --no-route --fixed-routes "$a" \
            --write "$OUT/m11-a.json"; then
        report "FAIL fixed-routes precedence: the run that stores lock A failed: $(grep -m1 '^ERROR' "$OUT/m11-a.log")"
        return
    fi
    local stored
    stored=$(grep -c "\"fixed-routes\": \"$a\"" "$OUT/m11-a.json")
    npnr "$OUT/m11-b.log" --json "$OUT/m11-a.json" --no-pack --no-place --fixed-routes "$b"
    local rc=$?
    local used_a used_b
    used_a=$(grep -cF "Applying fixed routes from '$a'" "$OUT/m11-b.log")
    used_b=$(grep -cF "Applying fixed routes from '$b'" "$OUT/m11-b.log")
    if [ "$stored" -gt 0 ] && [ "$rc" -eq 0 ] && [ "$used_b" -eq 1 ] && [ "$used_a" -eq 0 ]; then
        report "PASS fixed-routes precedence: lock A stored in the netlist, --fixed-routes B applied"
    else
        report "FAIL fixed-routes precedence: lock A stored $stored time(s), rc $rc, applied A $used_a time(s), B $used_b time(s)"
    fi
}

arm_router1_refused_under_a_rectangle() {
    roi "$OUT/far.roi.json" 40 180 44 190
    if ! npnr "$OUT/l24-place.log" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --write "$OUT/placed-router1.json" \
            --no-route --router router1 --seed 1; then
        report "FAIL router1 under a rectangle: placement failed: $(grep -m1 '^ERROR' "$OUT/l24-place.log")"
        return
    fi
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json npnr "$OUT/l24.log" --json "$OUT/placed-router1.json" --no-pack \
        --no-place
    local rc=$?
    local refused
    refused=$(grep -c 'router1 has neither the partition route clamp nor the static keepout' "$OUT/l24.log")
    if [ "$rc" -ne 0 ] && [ "$refused" -eq 1 ]; then
        report "PASS router1 under a rectangle: refused at rc $rc"
    else
        report "FAIL router1 under a rectangle: rc $rc, $refused refusal line(s)"
    fi
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_PARTITION_CLAMP=off NEXTPNR_PARTITION_KEEPOUT=off \
        npnr "$OUT/l24-off.log" --json "$OUT/placed-router1.json" --no-pack --no-place
    rc=$?
    if [ "$rc" -eq 0 ]; then
        report "PASS router1 under a rectangle with the clamp and the keepout both off: rc 0"
    else
        report "FAIL router1 under a rectangle with the clamp and the keepout both off: rc $rc: $(grep -m1 '^ERROR' "$OUT/l24-off.log")"
    fi
}

arm_region_only_keeps_output
arm_fixed_routes_command_line_wins
arm_router1_refused_under_a_rectangle

echo "artefacts kept in $OUT"
exit "$rc_total"
