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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
NEXTPNR=$(resolve_tool "${NEXTPNR:-$HERE/../../../build/nextpnr-xilinx}")
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tfgg484.bin}")
PRJXRAY_DB=$(abspath "${PRJXRAY_DB:-$HERE/../../external/prjxray-db}")
TILEGRID=$PRJXRAY_DB/artix7/xc7a100t/tilegrid.json
NPNR_TIMEOUT=${NPNR_TIMEOUT:-600}
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

if [ ! -r "$TILEGRID" ]; then
    echo "FAIL no tilegrid at $TILEGRID; set PRJXRAY_DB"
    exit 1
fi

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

roi() {
    printf '{"info": {"GRID_X_MIN": %d, "GRID_X_MAX": %d, "GRID_Y_MIN": %d, "GRID_Y_MAX": %d}}\n' "$2" "$4" "$3" "$5" \
        >"$1"
}

geom() {
    "$PYTHON" "$HERE/geom.py" --tilegrid "$TILEGRID" "$@"
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

refused_by_keepout_gate() {
    [ "$1" -ne 0 ] && grep -q '^ERROR: partition keepout gate:' "$2"
}

arm_static_keepout() {
    local sx sy
    read -r sx sy < <(geom pick-static "$OUT/all.routes") || {
        report "FAIL static keepout: no static INT pip to put a rectangle on"
        return
    }
    local r=$OUT/static.roi.json
    roi "$r" "$sx" "$sy" "$sx" "$sy"
    local base_in
    base_in=$(geom count "$OUT/all.routes" static "$sx" "$sy" "$sx" "$sy")

    NEXTPNR_PARTITION_ROI=$r npnr "$OUT/m10-router2.log" --json "$OUT/placed.json" --no-pack --no-place \
        --write-fixed-routes "$OUT/m10-router2.routes"
    local rc=$?
    local inside census
    inside=$(geom count "$OUT/m10-router2.routes" static "$sx" "$sy" "$sx" "$sy" 2>/dev/null || echo '?')
    census=$(grep -c 'partition keepout gate \[fatal\]:.* 0 unlicensed in 0 net' "$OUT/m10-router2.log")
    if [ "$rc" -eq 0 ] && [ "$inside" = 0 ] && [ "$census" -eq 1 ]; then
        report "PASS static keepout, router2 control: rc 0, 0 static pips in tile ($sx,$sy) against $base_in unconfined, gate census clean"
    else
        report "FAIL static keepout, router2 control: rc $rc, $inside static pip(s) in tile ($sx,$sy), $census clean gate census line(s)"
    fi

    NEXTPNR_PARTITION_ROI=$r npnr "$OUT/m10-fixed.log" --json "$OUT/placed.json" --no-pack --no-place \
        --fixed-routes "$OUT/all.routes" --write-fixed-routes "$OUT/m10-fixed.routes"
    rc=$?
    if refused_by_keepout_gate "$rc" "$OUT/m10-fixed.log"; then
        report "PASS static keepout, --fixed-routes through the rectangle: refused at rc $rc"
    else
        inside=$(geom count "$OUT/m10-fixed.routes" static "$sx" "$sy" "$sx" "$sy" 2>/dev/null || echo '?')
        report "FAIL static keepout, --fixed-routes through the rectangle: rc $rc, $inside static pip(s) left in tile ($sx,$sy)"
    fi

    NEXTPNR_PARTITION_ROI=$r NEXTPNR_ROUTE_FIXED_ONLY=1 npnr "$OUT/m10-import.log" --json "$OUT/routed.json" \
        --no-pack --no-place
    rc=$?
    if refused_by_keepout_gate "$rc" "$OUT/m10-import.log"; then
        report "PASS static keepout, imported routing through the rectangle: refused at rc $rc"
    else
        report "FAIL static keepout, imported routing through the rectangle: rc $rc, $base_in static pip(s) imported in tile ($sx,$sy)"
    fi

    NEXTPNR_PARTITION_ROI=$r NEXTPNR_PARTITION_KEEPOUT=off npnr "$OUT/m10-off.log" --json "$OUT/placed.json" \
        --no-pack --no-place --fixed-routes "$OUT/all.routes"
    rc=$?
    census=$(grep -c 'partition keepout gate \[report only, keepout DISABLED\]:.* [1-9][0-9]* unlicensed' "$OUT/m10-off.log")
    if [ "$rc" -eq 0 ] && [ "$census" -eq 1 ]; then
        report "PASS static keepout, the same --fixed-routes run with NEXTPNR_PARTITION_KEEPOUT=off: rc 0, unlicensed pips reported"
    else
        report "FAIL static keepout, the same --fixed-routes run with NEXTPNR_PARTITION_KEEPOUT=off: rc $rc, $census report-only census line(s) naming unlicensed pips"
    fi
}

arm_const_containment() {
    local cx cy
    read -r cx cy < <(geom pick-const "$OUT/all.routes") || {
        report "FAIL constant containment: no constant INT pip to put a rectangle on"
        return
    }
    local r=$OUT/const.roi.json
    roi "$r" "$cx" "$cy" "$cx" "$cy"
    local base_in
    base_in=$(geom count "$OUT/all.routes" const "$cx" "$cy" "$cx" "$cy")

    NEXTPNR_PARTITION_ROI=$r NEXTPNR_ROUTE_FIXED_ONLY=1 npnr "$OUT/m12-import.log" --json "$OUT/routed.json" \
        --no-pack --no-place
    local rc=$?
    if refused_by_keepout_gate "$rc" "$OUT/m12-import.log" &&
            grep -q "^Warning: partition keepout gate: constant net" "$OUT/m12-import.log"; then
        report "PASS constant containment, imported ties through tile ($cx,$cy) for sinks outside it: refused at rc $rc"
    else
        report "FAIL constant containment, imported ties through tile ($cx,$cy) for sinks outside it: rc $rc, $base_in constant pip(s) imported there"
    fi

    NEXTPNR_PARTITION_ROI=$r npnr "$OUT/m12-bridge.log" --json "$OUT/placed.json" --no-pack --no-place \
        --write-fixed-routes "$OUT/m12-bridge.routes"
    rc=$?
    local inside='-'
    [ -f "$OUT/m12-bridge.routes" ] && inside=$(geom count "$OUT/m12-bridge.routes" const "$cx" "$cy" "$cx" "$cy")
    if [ "$rc" -eq 0 ] && [ "$inside" = 0 ]; then
        report "PASS constant containment, fresh bridge: rc 0, no constant pip in tile ($cx,$cy) against $base_in unconfined"
    elif [ "$rc" -ne 0 ] && grep -q '^ERROR: routeVcc: .* constant sink(s) could not be bridged' "$OUT/m12-bridge.log"; then
        report "PASS constant containment, fresh bridge: the sinks outside tile ($cx,$cy) have no tie that avoids it, refused at rc $rc"
    else
        report "FAIL constant containment, fresh bridge: rc $rc, $inside constant pip(s) in tile ($cx,$cy)"
    fi
}

arm_frozen_cell_not_moved() {
    local bel
    bel=$(geom cell-tiles "$OUT/placed.json" SLICE_LUTX | awk 'NR == 1 { print $1 }')
    printf '%s\n' "$bel" >"$OUT/m8.bel"
    roi "$OUT/far.roi.json" 40 180 44 190
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_BEL_BLACKLIST=$OUT/m8.bel npnr "$OUT/m8.log" \
        --json "$OUT/placed.json" --no-pack --no-route --write "$OUT/m8.json"
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -q "^ERROR: post-place repair: .* invalid at their own bels" "$OUT/m8.log"; then
        report "PASS static cell on a blacklisted bel under a rectangle: refused at rc $rc, not moved"
    else
        local now='-'
        [ -f "$OUT/m8.json" ] && now=$(geom cell-tiles "$OUT/m8.json" SLICE_LUTX | awk 'NR == 1 { print $1 " at tile (" $2 "," $3 ")" }')
        report "FAIL static cell on a blacklisted bel under a rectangle: rc $rc, $bel now $now, rectangle (40,180)-(44,190)"
    fi
}

arm_region_only_keeps_output
arm_fixed_routes_command_line_wins
arm_router1_refused_under_a_rectangle
arm_static_keepout
arm_const_containment
arm_frozen_cell_not_moved

echo "artefacts kept in $OUT"
exit "$rc_total"
