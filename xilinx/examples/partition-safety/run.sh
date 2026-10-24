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

    local bufs consts total nbuf nconst
    bufs=$(sed -n 's/^Info: partition static keepout: exempt by global clock buffer driver: //p' "$OUT/m10-router2.log" | sort | paste -sd' ' -)
    consts=$(sed -n 's/^Info: partition static keepout: exempt constant net, held by the constant-path gate instead: //p' "$OUT/m10-router2.log" | sort | paste -sd' ' -)
    read -r total nbuf nconst < <(sed -n 's/^Info: partition static keepout: \([0-9]*\) net(s) exempt (\([0-9]*\) by global clock buffer driver, \([0-9]*\) constant,.*/\1 \2 \3/p' "$OUT/m10-router2.log")
    if [ "$consts" = '$PACKER_GND_NET $PACKER_VCC_NET' ] && [[ " $bufs " != *' $PACKER_'* ]] && [ -n "$bufs" ] \
            && [ "${nconst:-x}" = 2 ] && [ "${nbuf:-x}" = "$(wc -w <<<"$bufs")" ]; then
        report "PASS keepout census: the constant nets are counted and listed as constant ($consts), the clock-buffer list is [$bufs]"
    else
        report "FAIL keepout census: clock-buffer list [$bufs], constant list [$consts], counts total=${total:-?} buffer=${nbuf:-?} constant=${nconst:-?}"
    printf 'no_such_net_stale_a\nno_such_net_stale_b\n' >"$OUT/m10-stale.nets"
    NEXTPNR_PARTITION_ROI=$r NEXTPNR_PARTITION_KEEPOUT_EXEMPT=$OUT/m10-stale.nets \
        NEXTPNR_PARTITION_EXEMPT_NETS=$OUT/m10-stale.nets npnr "$OUT/m10-stale.log" --json "$OUT/placed.json" \
        --no-pack --no-place --write-fixed-routes "$OUT/m10-stale.routes"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '0 from .*m10-stale.nets, 2 unresolved)' "$OUT/m10-stale.log" \
            && cmp -s <(grep -v '^#' "$OUT/m10-router2.routes") <(grep -v '^#' "$OUT/m10-stale.routes"); then
        report "PASS stale exemption names: two names matching no net are counted unresolved and the routes equal the run without them"
    else
        report "FAIL stale exemption names: rc $rc, $(grep -m1 'partition keepout exemptions' "$OUT/m10-stale.log"), routes $(cmp -s <(grep -v '^#' "$OUT/m10-router2.routes") <(grep -v '^#' "$OUT/m10-stale.routes") && echo equal || echo differ)"
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

    NEXTPNR_PARTITION_ROI=$r NEXTPNR_PARTITION_KEEPOUT=off npnr "$OUT/m12-off.log" --json "$OUT/placed.json" \
        --no-pack --no-place
    rc=$?
    local census
    census=$(grep -c 'partition keepout gate \[report only, keepout DISABLED\]: [0-9]* constant pip' "$OUT/m12-off.log")
    if [ "$rc" -eq 0 ] && [ "$census" -eq 1 ]; then
        report "PASS constant containment with NEXTPNR_PARTITION_KEEPOUT=off: tile ($cx,$cy) does not confine the ties, rc 0, report-only census"
    else
        report "FAIL constant containment with NEXTPNR_PARTITION_KEEPOUT=off: rc $rc, $census report-only constant census line(s): $(grep -m1 '^ERROR' "$OUT/m12-off.log")"
    fi

    NEXTPNR_PARTITION_ROI=$r NEXTPNR_PARTITION_CLAMP=off NEXTPNR_PARTITION_KEEPOUT=off npnr "$OUT/m12-r1.log" \
        --json "$OUT/placed-router1.json" --no-pack --no-place
    rc=$?
    if [ "$rc" -eq 0 ]; then
        report "PASS constant containment, router1 with the clamp and the keepout both off over tile ($cx,$cy): rc 0"
    else
        report "FAIL constant containment, router1 with the clamp and the keepout both off over tile ($cx,$cy): rc $rc: $(grep -m1 '^ERROR' "$OUT/m12-r1.log")"
    fi
}

arm_weak_static_cell_not_moved() {
    local name="weak static cell beside an RM cell under a rectangle"
    if ! "$YOSYS" -q -l "$OUT/m8w-yosys.log" \
            -p "read_verilog \"$HERE/m8w.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/m8w.json\"" \
            >/dev/null 2>&1; then
        report "FAIL $name: yosys on m8w.v"
        return
    fi
    if ! npnr "$OUT/m8w-place.log" --xdc "$HERE/top.xdc" --json "$OUT/m8w.json" --write "$OUT/m8w-placed.json" \
            --no-route --seed 1; then
        report "FAIL $name: placing m8w.v: $(grep -m1 '^ERROR' "$OUT/m8w-place.log")"
        return
    fi
    local sbel tx ty
    if ! read -r sbel tx ty < <("$PYTHON" - "$OUT/m8w-placed.json" "$OUT/m8w-in.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["modules"]["top"]["cells"]
s = c["u_s"]["attributes"]
s.pop("BEL", None)
s["BEL_STRENGTH"] = format(1, "032b")
r = c["u_r"]["attributes"]
for k in ("BEL", "NEXTPNR_BEL", "BEL_STRENGTH"):
    r.pop(k, None)
json.dump(d, open(sys.argv[2], "w"))
print(s["NEXTPNR_BEL"])
EOF
    ) || [ -z "$sbel" ]; then
        report "FAIL $name: could not mark u_s weak and unplace u_r"
        return
    fi
    read -r _ tx ty < <(geom cell-tiles "$OUT/m8w-placed.json" SLICE_LUTX | awk -v b="$sbel" '$1 == b')
    roi "$OUT/m8w.roi.json" "$tx" "$ty" "$tx" "$ty"
    local pl sd rc now bad="" runs=0
    for pl in heap sa; do
        for sd in 1 2 3 4; do
            rm -f "$OUT/m8w-$pl-$sd.json"
            NEXTPNR_PARTITION_NETS=warn NEXTPNR_PARTITION_ROI=$OUT/m8w.roi.json npnr "$OUT/m8w-$pl-$sd.log" \
                --json "$OUT/m8w-in.json" --no-pack --no-route --placer "$pl" --seed "$sd" --write "$OUT/m8w-$pl-$sd.json"
            rc=$?
            runs=$((runs + 1))
            now=$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"]["top"]["cells"]["u_s"]["attributes"].get("NEXTPNR_BEL","-"))' \
                "$OUT/m8w-$pl-$sd.json" 2>/dev/null)
            if [ "$rc" -ne 0 ] || [ "$now" != "$sbel" ]; then
                [ -n "$bad" ] || bad="--placer $pl --seed $sd: rc $rc, u_s at ${now:--} where it was imported at $sbel: $(grep -m1 '^ERROR' "$OUT/m8w-$pl-$sd.log")"
            fi
        done
    done
    if [ -n "$bad" ]; then
        report "FAIL $name: $bad"
    else
        report "PASS $name: u_s (weak, placed) stays at $sbel in tile ($tx,$ty) over $runs heap and sa placements of the RM LUT u_r inside that one tile"
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

sub_region_hook() {
    cat >"$1" <<EOF
ctx.createRectangularRegion("sub", $2, $3, $4, $5)
for name, cell in ctx.cells:
    if cell.type in ("SLICE_LUTX", "SLICE_FFX"):
        ctx.constrainCellToRegion(name, "sub")
EOF
}

arm_pinned_cell_not_moved_without_a_rectangle() {
    local bel
    bel=$(geom cell-tiles "$OUT/placed.json" SLICE_LUTX | awk 'NR == 1 { print $1 }')
    printf '%s\n' "$bel" >"$OUT/m8-pin.bel"
    geom pin "$OUT/placed.json" "$OUT/m8-pin.json" "$bel" 3 || {
        report "FAIL pinned cell on a blacklisted bel without a rectangle: could not pin the cell on $bel"
        return
    }
    env -u NEXTPNR_PARTITION_ROI NEXTPNR_BEL_BLACKLIST=$OUT/m8-pin.bel timeout "$NPNR_TIMEOUT" "$NEXTPNR" \
        --chipdb "$CHIPDB" --log "$OUT/m8-pin.log" -q --json "$OUT/m8-pin.json" --no-pack --no-route \
        --write "$OUT/m8-pin-out.json" >/dev/null 2>&1
    local rc=$?
    local err
    err=$(grep -m1 '^ERROR: post-place repair:' "$OUT/m8-pin.log")
    if [ "$rc" -ne 0 ] && grep -q 'a fixed or locked member are invalid at their own bels' <<<"$err" &&
            ! grep -q 'rectangle' <<<"$err" && grep -q "(pinned, strength 3) is invalid at its own bel" "$OUT/m8-pin.log"; then
        report "PASS pinned cell on a blacklisted bel without a rectangle: refused at rc $rc, no rectangle named"
    else
        report "FAIL pinned cell on a blacklisted bel without a rectangle: rc $rc: ${err:-no post-place repair error}"
    fi
}

arm_pre_place_region_kept() {
    geom unplace "$OUT/placed.json" "$OUT/rm.json" SLICE_LUTX SLICE_FFX
    roi "$OUT/part.roi.json" 20 120 120 200

    sub_region_hook "$OUT/sub-in.py" 100 180 120 200
    NEXTPNR_PARTITION_ROI=$OUT/part.roi.json NEXTPNR_PARTITION_NETS=warn npnr "$OUT/l6-in.log" --json "$OUT/rm.json" \
        --no-pack --no-route --pre-place "$OUT/sub-in.py" --write "$OUT/l6-in.json"
    local rc=$?
    local placed='' outside=0
    if [ "$rc" -eq 0 ]; then
        placed=$( { geom cell-tiles "$OUT/l6-in.json" SLICE_LUTX; geom cell-tiles "$OUT/l6-in.json" SLICE_FFX; } )
        outside=$(awk '!($2 >= 100 && $2 <= 120 && $3 >= 180 && $3 <= 200)' <<<"$placed" | wc -l)
    fi
    if [ "$rc" -eq 0 ] && [ -n "$placed" ] && [ "$outside" -eq 0 ]; then
        report "PASS pre-place region inside the rectangle: every RM cell placed inside (100,180)-(120,200)"
    else
        report "FAIL pre-place region inside the rectangle: rc $rc, $outside RM cell(s) outside (100,180)-(120,200): $(tr '\n' ';' <<<"$placed")"
    fi

    if [ "$rc" -eq 0 ]; then
        NEXTPNR_PARTITION_ROI=$OUT/part.roi.json NEXTPNR_PARTITION_NETS=warn npnr "$OUT/l6-route.log" \
            --json "$OUT/l6-in.json" --no-pack --no-place --write-fixed-routes "$OUT/l6-route.routes"
        local rrc=$?
        local inside_const='-' clean
        [ -f "$OUT/l6-route.routes" ] && inside_const=$(geom count "$OUT/l6-route.routes" const 20 120 120 200)
        clean=$(grep -c 'partition keepout gate \[fatal\]: [0-9]* constant pip(s), 0 on a path' "$OUT/l6-route.log")
        if [ "$rrc" -eq 0 ] && [ "$inside_const" != '-' ] && [ "$inside_const" -gt 0 ] && [ "$clean" -eq 1 ]; then
            report "PASS constant ties for RM sinks inside the rectangle: rc 0, $inside_const constant pip(s) inside, gate census clean"
        else
            report "FAIL constant ties for RM sinks inside the rectangle: rc $rrc, $inside_const constant pip(s) inside, $clean clean constant census line(s)"
        fi
    fi

    sub_region_hook "$OUT/sub-out.py" 0 100 30 130
    NEXTPNR_PARTITION_ROI=$OUT/part.roi.json NEXTPNR_PARTITION_NETS=warn npnr "$OUT/l6-out.log" --json "$OUT/rm.json" \
        --no-pack --no-route --pre-place "$OUT/sub-out.py" --write "$OUT/l6-out.json"
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q "^ERROR: partition region: RM cell .* is not a non-empty set of bels inside" "$OUT/l6-out.log"; then
        report "PASS pre-place region reaching outside the rectangle: refused at rc $rc"
    else
        report "FAIL pre-place region reaching outside the rectangle: rc $rc, no refusal"
    fi
}

arm_heap_scarce_by_device() {
    geom unplace "$OUT/placed.json" "$OUT/rm-scarce.json" SLICE_LUTX SLICE_FFX
    roi "$OUT/scarce.roi.json" 100 180 120 200
    NEXTPNR_PARTITION_ROI=$OUT/scarce.roi.json NEXTPNR_PARTITION_NETS=warn npnr "$OUT/l30.log" \
        --json "$OUT/rm-scarce.json" --no-pack --no-route --placer heap --write "$OUT/l30.json"
    local rc=$? line dev cand
    line=$(grep -m1 'HeAP legaliser: SLICE_LUTX has' "$OUT/l30.log")
    dev=$(sed -n 's/.* has \([0-9]*\) bel(s) on the device and \([0-9]*\) placement.*/\1/p' <<<"$line")
    cand=$(sed -n 's/.* has \([0-9]*\) bel(s) on the device and \([0-9]*\) placement.*/\2/p' <<<"$line")
    if [ "$rc" -eq 0 ] && [ -n "$dev" ] && [ "$cand" -le 4096 ] && [ "$dev" -gt 4096 ] && [[ $line == *"; abundant" ]]; then
        report "PASS HeAP scarcity by device population: under a rectangle with $cand SLICE_LUTX candidate(s) of $dev on the device, SLICE_LUTX is abundant"
    else
        report "FAIL HeAP scarcity by device population: rc $rc, classification line '${line:-none}'"
arm_routing_cycle_refused() {
    local net
    net=$("$PYTHON" - "$OUT/routed.json" "$OUT/cycle.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
top = d["modules"]["top"]
lv, lh = "INT_L_X0Y190/LV_L0", "INT_L_X0Y190/LH12"
for name in sorted(top["netnames"]):
    attrs = top["netnames"][name].get("attributes", {})
    r = attrs.get("ROUTING", "")
    if name.startswith("$PACKER") or r.count(";") < 9:
        continue
    attrs["ROUTING"] = r + ";%s;%s->%s;1;%s;%s->%s;1" % (lh, lv, lh, lv, lh, lv)
    json.dump(d, open(sys.argv[2], "w"))
    print(name)
    break
PY
)
    if [ -z "$net" ]; then
        report "FAIL routing cycle in an imported ROUTING attribute: no routed net to edit"
    else
        npnr "$OUT/l31-import.log" --json "$OUT/cycle.json" --no-pack --no-place --no-route
        local rc=$?
        if [ "$rc" -ne 0 ] && grep -q "ROUTING import on net .*: the bound pips form a cycle" "$OUT/l31-import.log"; then
            report "PASS routing cycle in an imported ROUTING attribute: refused at rc $rc"
        else
            report "FAIL routing cycle in an imported ROUTING attribute: rc $rc, no cycle refusal"
        fi
        printf '%s INT_L_X0Y190/LV_L0->INT_L_X0Y190/LH12\n%s INT_L_X0Y190/LH12->INT_L_X0Y190/LV_L0\n' "$net" "$net" \
            >"$OUT/cycle.routes"
        npnr "$OUT/l31-fixed.log" --json "$OUT/placed.json" --no-pack --no-place --fixed-routes "$OUT/cycle.routes"
        rc=$?
        if [ "$rc" -eq 0 ] && grep -q "fixed-routes: pip .* would drive the source of net .* or close a routing cycle; not bound" "$OUT/l31-fixed.log" \
                && grep -q 'fixed-routes: bound 1/2 pips' "$OUT/l31-fixed.log"; then
            report "PASS routing cycle in a fixed-routes file: the cycle-closing pip is refused and the run routes at rc 0"
        else
            report "FAIL routing cycle in a fixed-routes file: rc $rc, $(grep -m1 'fixed-routes: bound' "$OUT/l31-fixed.log")"
        fi
arm_carry_tree_on_a_blacklisted_bel() {
    printf 'set_property -dict {PACKAGE_PIN %s IOSTANDARD LVCMOS33} [get_ports %s]\n' W19 clk N15 en P19 '{q[0]}' \
        P20 '{q[1]}' T21 '{q[2]}' R19 '{q[3]}' >"$OUT/carry.xdc"
    if ! "$YOSYS" -q -l "$OUT/carry-yosys.log" \
            -p "read_verilog \"$HERE/carry.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/carry.json\"" \
            >/dev/null 2>&1; then
        report "FAIL CARRY4 tree pinned on a blacklisted bel: yosys"
        return
    fi
    if ! npnr "$OUT/carry-place.log" --xdc "$OUT/carry.xdc" --json "$OUT/carry.json" --write "$OUT/carry-placed.json" \
            --no-route --seed 1; then
        report "FAIL CARRY4 tree pinned on a blacklisted bel: base placement: $(grep -m1 '^ERROR' "$OUT/carry-place.log")"
        return
    fi
    local bel
    bel=$(geom cell-tiles "$OUT/carry-placed.json" CARRY4 | awk 'NR == 1 { print $1 }')
    if [ -z "$bel" ] || ! geom pin "$OUT/carry-placed.json" "$OUT/carry-pin.json" "$bel" 3; then
        report "FAIL CARRY4 tree pinned on a blacklisted bel: no CARRY4 to pin"
        return
    fi
    printf '%s\n' "$bel" >"$OUT/carry-pin.bel"
    env -u NEXTPNR_PARTITION_ROI NEXTPNR_BEL_BLACKLIST=$OUT/carry-pin.bel timeout "$NPNR_TIMEOUT" "$NEXTPNR" \
        --chipdb "$CHIPDB" --log "$OUT/carry-pin.log" -q --json "$OUT/carry-pin.json" --no-pack --no-route \
        --write "$OUT/carry-pin-out.json" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^ERROR: post-place check: [1-9][0-9]* cell(s) without a BEL attribute sit on a blacklisted' "$OUT/carry-pin.log" \
            && grep -q "post-place check: .* (CARRY4) is on a forbidden bel $bel" "$OUT/carry-pin.log"; then
        report "PASS CARRY4 tree pinned on a blacklisted bel: refused at rc $rc, the CARRY4 on $bel named"
    else
        report "FAIL CARRY4 tree pinned on a blacklisted bel: rc $rc: $(grep -m1 '^ERROR' "$OUT/carry-pin.log" || echo 'no error; the placement was accepted')"
    fi
}

sentinel_files() {
    local f
    for f in "$@"; do printf 'sentinel\n' >"$f"; done
}

sentinels_kept() {
    local f
    for f in "$@"; do [ "$(cat "$f" 2>/dev/null)" = sentinel ] || return 1; done
}

arm_region_only_placed_input_refused() {
    local x0 y0 x1 y1
    read -r x0 y0 x1 y1 < <(geom cell-bbox "$OUT/placed.json" SLICE_LUTX SLICE_FFX) || {
        report "FAIL region-only over a placed netlist: no placed logic cell to put a rectangle on"
        return
    }
    local r=$OUT/e.roi.json
    roi "$r" "$x0" "$y0" "$x1" "$y1"
    NEXTPNR_PARTITION_ROI=$r npnr "$OUT/e-full.log" --json "$OUT/placed.json" --no-pack --no-place \
        --write-fixed-routes "$OUT/e-full.routes"
    local frc=$?
    local held esc outp
    read -r held esc outp < <(geom escaping "$OUT/placed.json" "$OUT/e-full.routes" "$x0" "$y0" "$x1" "$y1" 2>/dev/null) ||
        held='?'
    if [ "$frc" -ne 0 ] || [ "$held" = '?' ] || [ "$esc" -eq 0 ]; then
        report "FAIL region-only over a placed netlist: the unfiltered route under ($x0,$y0)-($x1,$y1) gives no net to cut (rc $frc, ${held:-?} net(s) with a cell inside, ${esc:-?} leaving)"
        return
    fi
    if grep -q '^Warning: partition rectangle: the RM cell set snapshotted at import is empty (--no-place with a placed input netlist)' "$OUT/e-full.log"; then
        report "PASS rectangle over a placed netlist without --region-only: accepted at rc $frc with a warning naming the empty RM cell set"
    else
        report "FAIL rectangle over a placed netlist without --region-only: rc $frc and no warning naming the empty RM cell set; $esc of $held net(s) with a cell inside bind $outp pip(s) outside it, governed by nothing"
    fi
    sentinel_files "$OUT/e.fasm" "$OUT/e.routes"
    NEXTPNR_PARTITION_ROI=$r npnr "$OUT/e.log" --json "$OUT/placed.json" --no-pack --no-place \
        --fasm "$OUT/e.fasm" --write-fixed-routes "$OUT/e.routes" --region-only
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^ERROR: --region-only: the RM cell set snapshotted at import is empty' "$OUT/e.log" &&
            sentinels_kept "$OUT/e.fasm" "$OUT/e.routes"; then
        report "PASS region-only over a placed netlist: refused at rc $rc, outputs left as they were; geometry: $esc of $held net(s) with a cell inside ($x0,$y0)-($x1,$y1) bind $outp pip(s) outside it"
    else
        report "FAIL region-only over a placed netlist: rc $rc; geometry: $esc of $held net(s) with a cell inside ($x0,$y0)-($x1,$y1) bind $outp pip(s) outside it, which the region-only outputs cut"
    fi
}

arm_region_only_all_exempt_refused() {
    [ -f "$OUT/rm.json" ] || geom unplace "$OUT/placed.json" "$OUT/rm.json" SLICE_LUTX SLICE_FFX
    roi "$OUT/part.roi.json" 20 120 120 200
    geom touching-nets "$OUT/rm.json" SLICE_LUTX SLICE_FFX >"$OUT/ex.nets"
    local nn
    nn=$(wc -l <"$OUT/ex.nets")
    if [ "$nn" -eq 0 ]; then
        report "FAIL region-only with every RM net exempt: geometry finds no net touching an RM cell"
        return
    fi
    local which
    for which in fasm routes; do
        local o=$OUT/ex.$which flag
        [ "$which" = fasm ] && flag=--fasm || flag=--write-fixed-routes
        sentinel_files "$o"
        NEXTPNR_PARTITION_ROI=$OUT/part.roi.json NEXTPNR_PARTITION_NETS=warn NEXTPNR_PARTITION_EXEMPT_NETS=$OUT/ex.nets \
            npnr "$OUT/ex-$which.log" --json "$OUT/rm.json" --no-pack "$flag" "$o" --region-only
        local rc=$?
        if [ "$rc" -ne 0 ] && grep -q '^ERROR: --region-only: the partition rectangle governs no nets' "$OUT/ex-$which.log" &&
                sentinels_kept "$o"; then
            report "PASS region-only $flag with all $nn net(s) touching an RM cell exempt: refused at rc $rc, output left as it was"
        else
            report "FAIL region-only $flag with all $nn net(s) touching an RM cell exempt: rc $rc: $(grep -m1 '^ERROR' "$OUT/ex-$which.log")"
        fi
    done
}

arm_bel_blacklist_fails_closed() {
    local good
    good=$(geom cell-tiles "$OUT/placed.json" SLICE_LUTX | awk 'NR == 1 { print $1 }')
    printf '%s\n' "$good" >"$OUT/bl-ok.bel"
    printf '%s\nSLICE_X9999Y9999/A6LUT\n' "$good" >"$OUT/bl-miss.bel"
    local tag f
    mkdir -p "$OUT/bl-dir.bel"
    for tag in ok missing-file unresolved directory; do
        case $tag in
            ok) f=$OUT/bl-ok.bel ;;
            missing-file) f=$OUT/bl-absent.bel ;;
            unresolved) f=$OUT/bl-miss.bel ;;
            directory) f=$OUT/bl-dir.bel ;;
        esac
        rm -f "$OUT/bl-absent.bel"
        NEXTPNR_BEL_BLACKLIST=$f npnr "$OUT/bl-$tag.log" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --no-route --seed 1
        local rc=$?
        case $tag in
            ok)
                if [ "$rc" -eq 0 ] && grep -q 'bel blacklist: reserved 1 bel(s) .* (0 unresolved)' "$OUT/bl-$tag.log"; then
                    report "PASS bel blacklist naming one real bel: rc 0, reserved"
                else
                    report "FAIL bel blacklist naming one real bel: rc $rc: $(grep -m1 '^ERROR' "$OUT/bl-$tag.log")"
                fi ;;
            missing-file)
                if [ "$rc" -ne 0 ] && grep -q "^ERROR: NEXTPNR_BEL_BLACKLIST: cannot open" "$OUT/bl-$tag.log"; then
                    report "PASS bel blacklist naming a file that does not exist: refused at rc $rc"
                else
                    report "FAIL bel blacklist naming a file that does not exist: rc $rc, no refusal"
                fi
                NEXTPNR_BEL_BLACKLIST=$f npnr "$OUT/bl-$tag-route.log" --json "$OUT/placed.json" --no-pack --no-place
                rc=$?
                if [ "$rc" -ne 0 ] && grep -q "^ERROR: NEXTPNR_BEL_BLACKLIST: cannot open" "$OUT/bl-$tag-route.log"; then
                    report "PASS bel blacklist naming a file that does not exist, in a run that does not place: refused at rc $rc"
                else
                    report "FAIL bel blacklist naming a file that does not exist, in a run that does not place: rc $rc, no refusal"
                fi ;;
            unresolved)
                if [ "$rc" -ne 0 ] && grep -q "^ERROR: NEXTPNR_BEL_BLACKLIST: 1 name(s) .* name no bel" "$OUT/bl-$tag.log"; then
                    report "PASS bel blacklist with one name matching no bel: refused at rc $rc"
                else
                    report "FAIL bel blacklist with one name matching no bel: rc $rc, $(grep -o 'reserved .*' "$OUT/bl-$tag.log" | head -1)"
                fi ;;
            directory)
                if [ "$rc" -ne 0 ] && grep -q "^ERROR: NEXTPNR_BEL_BLACKLIST: '.*' is a directory" "$OUT/bl-$tag.log"; then
                    report "PASS bel blacklist naming a directory: refused at rc $rc"
                else
                    report "FAIL bel blacklist naming a directory: rc $rc, $(grep -o 'reserved .*' "$OUT/bl-$tag.log" | head -1)"
                fi
                NEXTPNR_BEL_BLACKLIST=$f npnr "$OUT/bl-$tag-route.log" --json "$OUT/placed.json" --no-pack --no-place
                rc=$?
                if [ "$rc" -ne 0 ] && grep -q "^ERROR: NEXTPNR_BEL_BLACKLIST: '.*' is a directory" "$OUT/bl-$tag-route.log"; then
                    report "PASS bel blacklist naming a directory, in a run that does not place: refused at rc $rc"
                else
                    report "FAIL bel blacklist naming a directory, in a run that does not place: rc $rc, no refusal"
                fi ;;
        esac
    done
}

arm_skip_failed_arcs_under_a_rectangle() {
    roi "$OUT/far.roi.json" 40 180 44 190
    NEXTPNR_SKIP_FAILED_ARCS=1 npnr "$OUT/sfa-noroi.log" --json "$OUT/placed.json" --no-pack --no-place
    local rc0=$?
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_SKIP_FAILED_ARCS=1 npnr "$OUT/sfa.log" --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/sfa.json"
    local rc=$?
    if [ "$rc0" -eq 0 ] && [ "$rc" -ne 0 ] && grep -q '^ERROR: NEXTPNR_SKIP_FAILED_ARCS or the router1/skipFailedArcs setting is set and NEXTPNR_PARTITION_ROI is set' "$OUT/sfa.log"; then
        report "PASS NEXTPNR_SKIP_FAILED_ARCS: rc 0 without a rectangle, refused at rc $rc under one"
    else
        report "FAIL NEXTPNR_SKIP_FAILED_ARCS: rc $rc0 without a rectangle, rc $rc under one: $(grep -m1 '^ERROR' "$OUT/sfa.log")"
    fi
    if [ ! -f "$OUT/placed-router1.json" ] &&
            ! npnr "$OUT/sfa-r1-place.log" --xdc "$HERE/top.xdc" --json "$OUT/top.json" \
                --write "$OUT/placed-router1.json" --no-route --router router1 --seed 1; then
        report "FAIL NEXTPNR_SKIP_FAILED_ARCS with router1: placement failed: $(grep -m1 '^ERROR' "$OUT/sfa-r1-place.log")"
        return
    fi
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_PARTITION_CLAMP=off NEXTPNR_PARTITION_KEEPOUT=off \
        NEXTPNR_SKIP_FAILED_ARCS=1 npnr "$OUT/sfa-r1.log" --json "$OUT/placed-router1.json" --no-pack --no-place
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^ERROR: NEXTPNR_SKIP_FAILED_ARCS or the router1/skipFailedArcs setting is set and NEXTPNR_PARTITION_ROI is set' "$OUT/sfa-r1.log"; then
        report "PASS NEXTPNR_SKIP_FAILED_ARCS with router1 under a rectangle, clamp and keepout off: refused at rc $rc"
    else
        report "FAIL NEXTPNR_SKIP_FAILED_ARCS with router1 under a rectangle, clamp and keepout off: rc $rc: $(grep -m1 '^ERROR' "$OUT/sfa-r1.log")"
    fi
    "$PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); d["modules"]["top"]["settings"]["router1/skipFailedArcs"]="1"; json.dump(d, open(sys.argv[2], "w"))' \
        "$OUT/placed-router1.json" "$OUT/placed-router1-skip.json"
    (unset NEXTPNR_SKIP_FAILED_ARCS
        npnr "$OUT/sfa-r1s-noroi.log" --json "$OUT/placed-router1-skip.json" --no-pack --no-place)
    rc0=$?
    (unset NEXTPNR_SKIP_FAILED_ARCS
        NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_PARTITION_CLAMP=off NEXTPNR_PARTITION_KEEPOUT=off \
            npnr "$OUT/sfa-r1s.log" --json "$OUT/placed-router1-skip.json" --no-pack --no-place)
    rc=$?
    if [ "$rc0" -eq 0 ] && [ "$rc" -ne 0 ] && grep -q '^ERROR: NEXTPNR_SKIP_FAILED_ARCS or the router1/skipFailedArcs setting is set' "$OUT/sfa-r1s.log"; then
        report "PASS router1/skipFailedArcs stored in the input netlist: rc 0 without a rectangle, refused at rc $rc under one"
    else
        report "FAIL router1/skipFailedArcs stored in the input netlist: rc $rc0 without a rectangle, rc $rc under one: $(grep -m1 '^ERROR' "$OUT/sfa-r1s.log")"
    fi
}

modes_of() {
    "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"]["top"]["settings"].get("partition_modes", "ABSENT"))' "$1" 2>/dev/null ||
        echo UNREADABLE
}

modes_field() {
    printf '%s\n' "$1" | tr ';' '\n' | sed -n "s/^$2=//p"
}

arm_partition_modes_recorded() {
    roi "$OUT/far.roi.json" 40 180 44 190
    mkdir -p "$OUT/pm-elsewhere"
    cp "$OUT/far.roi.json" "$OUT/pm-elsewhere/other-name.roi.json"
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_PARTITION_CLAMP=off npnr "$OUT/pm-off.log" --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/pm-off.json"
    local rc1=$?
    NEXTPNR_PARTITION_ROI=$OUT/pm-elsewhere/other-name.roi.json NEXTPNR_PARTITION_CLAMP=off \
        npnr "$OUT/pm-elsewhere/pm-off.log" --json "$OUT/placed.json" --no-pack --no-place \
        --write "$OUT/pm-elsewhere/pm-off.json"
    local rc1b=$?
    printf 'no_such_net_in_this_design\n' >"$OUT/pm-keepout-exempt.nets"
    : >"$OUT/pm-licence.routes"
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json NEXTPNR_PARTITION_KEEPOUT_EXEMPT=$OUT/pm-keepout-exempt.nets \
        NEXTPNR_PARTITION_KEEPOUT_LICENCE=$OUT/pm-licence.routes NEXTPNR_EXCLUDE_STAMPED_BBOX=1 \
        npnr "$OUT/pm-ko.log" --json "$OUT/placed.json" --no-pack --no-place --write "$OUT/pm-ko.json"
    local rc3=$?
    (unset NEXTPNR_PARTITION_ROI NEXTPNR_PARTITION_CLAMP NEXTPNR_PARTITION_KEEPOUT NEXTPNR_PARTITION_KEEPOUT_NARROW \
        NEXTPNR_PARTITION_KEEPOUT_LICENCE NEXTPNR_PARTITION_KEEPOUT_EXEMPT NEXTPNR_PARTITION_NETS \
        NEXTPNR_PARTITION_EXEMPT_NETS NEXTPNR_BEL_BLACKLIST NEXTPNR_PIP_BLACKLIST NEXTPNR_PIP_BLACKLIST_TILE \
        NEXTPNR_EXCLUDE_STAMPED_BBOX NEXTPNR_SKIP_FAILED_ARCS NEXTPNR_LUT_PERM_DROP
        npnr "$OUT/pm-none.log" --json "$OUT/pm-off.json" --no-pack --no-place --no-route \
            --write "$OUT/pm-none.json")
    local rc2=$?
    local m1 m1b m2 m3
    m1=$(modes_of "$OUT/pm-off.json")
    m1b=$(modes_of "$OUT/pm-elsewhere/pm-off.json")
    m2=$(modes_of "$OUT/pm-none.json")
    m3=$(modes_of "$OUT/pm-ko.json")
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [[ $m1 == "roi=fnv64:"*";rect0=40,180-44,190;active=1;clamp=off;keepout=on;"* ]] &&
            [ "$m2" = ABSENT ]; then
        report "PASS partition modes recorded in the written netlist: '$m1', and removed by a later run with no partition setting"
    else
        report "FAIL partition modes recorded in the written netlist: rc $rc1/$rc2, '$m1', then '$m2'"
    fi
    local s1 s1b
    s1=$(sha256sum <"$OUT/pm-off.json")
    s1b=$(sha256sum <"$OUT/pm-elsewhere/pm-off.json")
    if [ "$rc1b" -eq 0 ] && [[ $m1 == roi=fnv64:* ]] && [ "$m1" = "$m1b" ] && [[ $m1 != */* ]] && [ "$s1" = "$s1b" ]; then
        report "PASS partition modes name the rectangle by content: the same rectangle under another path and directory gives the same modes and a byte-identical netlist"
    else
        report "FAIL partition modes name the rectangle by content: rc $rc1b, '$m1' against '$m1b', netlists ${s1%% *} and ${s1b%% *}"
    fi
    local lic ex sb
    lic=$(modes_field "$m3" keepout_licence)
    ex=$(modes_field "$m3" keepout_exempt)
    sb=$(modes_field "$m3" exclude_stamped_bbox)
    if [ "$rc3" -eq 0 ] && [[ $lic == fnv64:* ]] && [[ $ex == fnv64:* ]] && [ "$lic" != "$ex" ] && [ "$sb" = set ] &&
            [ "$(modes_field "$m1" keepout_licence)" = none ] && [ "$(modes_field "$m1" keepout_exempt)" = none ] &&
            [ "$(modes_field "$m1" exclude_stamped_bbox)" = unset ]; then
        report "PASS partition modes record the keepout licence, the keepout exemptions and the stamped-bbox exclusion: licence $lic, exempt $ex, bbox $sb; none of them set gives none/none/unset"
    else
        report "FAIL partition modes record the keepout licence, the keepout exemptions and the stamped-bbox exclusion: rc $rc3, licence '$lic', exempt '$ex', bbox '$sb': $(grep -m1 '^ERROR' "$OUT/pm-ko.log")"
    fi
}

perm_drop_hook() {
    cat >"$1" <<'EOF'
ci = ctx.cells["u_x"]
a2 = ci.ports["A2"].net if "A2" in ci.ports else None
a3 = ci.ports["A3"].net if "A3" in ci.ports else None
if a2 is None or a3 is not None:
    raise Exception("u_x does not have A2 connected and A3 free")
bound = None
for pip in ctx.getPipsUphill(ctx.getBelPinWire(ci.bel, "A3")):
    if str(ctx.getPipSrcWire(pip)).endswith("_A5"):
        ctx.bindPip(pip, a2, STRENGTH_LOCKED)
        bound = pip
        break
if bound is None:
    raise Exception("no _A5 permutation pip into u_x.A3")
print("lpd.py: bound %s for u_x on %s" % (bound, a2.name))
EOF
}

arm_lut_perm_drop_mode() {
    if ! "$YOSYS" -q -l "$OUT/lpd-yosys.log" \
            -p "read_verilog \"$HERE/lpd.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/lpd.json\"" \
            >/dev/null 2>&1; then
        report "FAIL NEXTPNR_LUT_PERM_DROP: yosys on lpd.v"
        return
    fi
    if ! npnr "$OUT/lpd-place.log" --xdc "$HERE/top.xdc" --json "$OUT/lpd.json" --write "$OUT/lpd-placed.json" --no-route \
            --seed 1; then
        report "FAIL NEXTPNR_LUT_PERM_DROP: placing lpd.v: $(grep -m1 '^ERROR' "$OUT/lpd-place.log")"
        return
    fi
    perm_drop_hook "$OUT/lpd.py"
    npnr "$OUT/lpd-warn.log" --json "$OUT/lpd-placed.json" --no-pack --no-place --pre-route "$OUT/lpd.py"
    local rc0=$?
    local drops
    drops=$(grep -o 'rewrite DROPPED [0-9]*' "$OUT/lpd-warn.log" | grep -o '[0-9]*$')
    if [ "$rc0" -ne 0 ] || [ -z "$drops" ]; then
        report "FAIL NEXTPNR_LUT_PERM_DROP: the hook that binds a stray permutation pip into lpd.v's u_x drops nothing (rc $rc0): $(grep -m1 '^ERROR' "$OUT/lpd-warn.log")"
        return
    fi
    NEXTPNR_LUT_PERM_DROP=fatal npnr "$OUT/lpd-fatal.log" --json "$OUT/lpd-placed.json" --no-pack --no-place \
        --pre-route "$OUT/lpd.py" --write "$OUT/lpd-fatal.json"
    local rc1=$?
    NEXTPNR_LUT_PERM_DROP=fatal npnr "$OUT/lpd-clean.log" --json "$OUT/lpd-placed.json" --no-pack --no-place
    local rc2=$?
    NEXTPNR_LUT_PERM_DROP=FATAL npnr "$OUT/lpd-bad.log" --json "$OUT/lpd-placed.json" --no-pack --no-place
    local rc3=$?
    if [ "$rc1" -ne 0 ] && grep -q '^ERROR: LUT permutation rewrite DROPPED' "$OUT/lpd-fatal.log" && [ ! -e "$OUT/lpd-fatal.json" ]; then
        report "PASS NEXTPNR_LUT_PERM_DROP=fatal with $drops dropped LUT input(s): refused at rc $rc1, no netlist written; unset it warns at rc $rc0"
    else
        report "FAIL NEXTPNR_LUT_PERM_DROP=fatal with $drops dropped LUT input(s): rc $rc1; unset it warns at rc $rc0"
    fi
    if [ "$rc2" -eq 0 ] && ! grep -q 'rewrite DROPPED' "$OUT/lpd-clean.log"; then
        report "PASS NEXTPNR_LUT_PERM_DROP=fatal on a route that drops nothing: rc 0"
    else
        report "FAIL NEXTPNR_LUT_PERM_DROP=fatal on a route that drops nothing: rc $rc2"
    fi
    if [ "$rc3" -ne 0 ] && grep -q "^ERROR: NEXTPNR_LUT_PERM_DROP='FATAL' is neither 'fatal' nor 'warn'" "$OUT/lpd-bad.log"; then
        report "PASS NEXTPNR_LUT_PERM_DROP with an unknown value: refused at rc $rc3"
    else
        report "FAIL NEXTPNR_LUT_PERM_DROP with an unknown value: rc $rc3"
    fi
}

first_lut_hook() {
    cat >"$1" <<'EOF'
done = False
for name in sorted(n for n, ci in ctx.cells if ci.type == "SLICE_LUTX"):
    ci = ctx.cells[name]
    nets = {p: ci.ports[p].net for p in ("A2", "A3") if p in ci.ports}
    if nets.get("A2") is None or nets.get("A3") is not None:
        continue
    for pip in ctx.getPipsUphill(ctx.getBelPinWire(ci.bel, "A3")):
        if str(ctx.getPipSrcWire(pip)).endswith("_A5"):
            ctx.bindPip(pip, nets["A2"], STRENGTH_LOCKED)
            print("lpf.py: bound %s for %s" % (pip, name))
            done = True
            break
    if done:
        break
if not done:
    raise Exception("no LUT with A2 connected, A3 free and an _A5 permutation pip into A3")
EOF
}

arm_lut_perm_function() {
    local out rc drops
    out=$(geom lut-functions "$OUT/placed.json" "$OUT/routed.json")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: the plain route of top.v changes one ($out)"
        return
    fi
    if [ ! -s "$OUT/lpd-placed.json" ] || [ ! -s "$OUT/lpd.py" ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: the NEXTPNR_LUT_PERM_DROP arm left no lpd.v placement or hook"
        return
    fi
    npnr "$OUT/lpf-lpd.log" --json "$OUT/lpd-placed.json" --no-pack --no-place --pre-route "$OUT/lpd.py" \
        --write "$OUT/lpf-lpd.json"
    drops=$(grep -o 'rewrite DROPPED [0-9]*' "$OUT/lpf-lpd.log" | grep -o '[0-9]*$')
    if geom lut-functions "$OUT/lpd-placed.json" "$OUT/lpf-lpd.json" >/dev/null || [ -z "$drops" ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: on lpd.v's hooked route the comparison and the drop counter disagree (drops ${drops:-none}): $(geom lut-functions "$OUT/lpd-placed.json" "$OUT/lpf-lpd.json")"
        return
    fi
    first_lut_hook "$OUT/lpf.py"
    npnr "$OUT/lpf-top.log" --json "$OUT/placed.json" --no-pack --no-place --pre-route "$OUT/lpf.py" \
        --write "$OUT/lpf-top.json"
    rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$OUT/lpf-top.json" ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: the hooked route of top.v did not complete (rc $rc): $(grep -m1 '^ERROR' "$OUT/lpf-top.log")"
        return
    fi
    drops=$(grep -o 'rewrite DROPPED [0-9]*' "$OUT/lpf-top.log" | grep -o '[0-9]*$')
    out=$(geom lut-functions "$OUT/placed.json" "$OUT/lpf-top.json")
    rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$drops" ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: the hooked route of top.v changes a LUT's function and the drop counter reports nothing ($out)"
    elif [ "$rc" -eq 2 ]; then
        report "FAIL LUT permutation rewrite keeps each LUT's function: no verdict on the hooked route of top.v ($out)"
    else
        local what="changes no LUT function"
        [ -n "$drops" ] && what="drops $drops input(s) and the counter reports them"
        report "PASS LUT permutation rewrite keeps each LUT's function: the plain route keeps every one, lpd.v's dropped input is seen by both the comparison and the counter, and top.v's hooked route $what ($out)"
    fi
}

arm_fixed_routes_chipdb_identity() {
    local idl
    idl=$(grep -m1 '^# nextpnr-xilinx chipdb: ' "$OUT/all.routes")
    if [ -z "$idl" ]; then
        report "FAIL fixed-routes chipdb identity: the base route's --write-fixed-routes file carries no chipdb line"
    else
        report "PASS fixed-routes chipdb identity: the base route's file carries '${idl#\# nextpnr-xilinx chipdb: }'"
    fi
    grep -v '^# nextpnr-xilinx chipdb: ' "$OUT/all.routes" >"$OUT/id-none.routes"
    { printf '# nextpnr-xilinx chipdb: xc7a100t 0000000000000000\n'; cat "$OUT/id-none.routes"; } >"$OUT/id-other.routes"
    roi "$OUT/far.roi.json" 40 180 44 190
    npnr "$OUT/id-other.log" --json "$OUT/placed.json" --no-pack --no-place --fixed-routes "$OUT/id-other.routes"
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -q "^ERROR: fixed-routes: .* was written against chipdb 'xc7a100t 0000000000000000'" "$OUT/id-other.log"; then
        report "PASS fixed-routes from another chipdb, no rectangle: refused at rc $rc"
    else
        report "FAIL fixed-routes from another chipdb, no rectangle: rc $rc, $(grep -o 'bound [0-9]*/[0-9]* pips' "$OUT/id-other.log" | head -1)"
    fi
    NEXTPNR_PARTITION_ROI=$OUT/far.roi.json npnr "$OUT/id-none-roi.log" --json "$OUT/placed.json" --no-pack --no-place \
        --fixed-routes "$OUT/id-none.routes"
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q "^ERROR: fixed-routes: .* index-form pip line(s) and no '# nextpnr-xilinx chipdb:' line" "$OUT/id-none-roi.log"; then
        report "PASS fixed-routes with no chipdb line under a rectangle: refused at rc $rc"
    else
        report "FAIL fixed-routes with no chipdb line under a rectangle: rc $rc, $(grep -o 'bound [0-9]*/[0-9]* pips' "$OUT/id-none-roi.log" | head -1)"
    fi
    if [ -n "${CHIPDB_OTHER:-}" ]; then
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB_OTHER" --log "$OUT/id-real-stamp.log" -q \
            --json "$OUT/placed.json" --no-pack --no-place --no-route \
            --write-fixed-routes "$OUT/id-real-stamp.routes" >/dev/null 2>&1
        local other
        other=$(grep -m1 '^# nextpnr-xilinx chipdb: ' "$OUT/id-real-stamp.routes" 2>/dev/null)
        { printf '%s\n' "$other"; cat "$OUT/id-none.routes"; } >"$OUT/id-real.routes"
        npnr "$OUT/id-real.log" --json "$OUT/placed.json" --no-pack --no-place --fixed-routes "$OUT/id-real.routes"
        rc=$?
        if [ -n "$other" ] && [ "$other" != "$idl" ] && [ "$rc" -ne 0 ] &&
                grep -q "^ERROR: fixed-routes: .* was written against chipdb '${other#\# nextpnr-xilinx chipdb: }'" "$OUT/id-real.log"; then
            report "PASS fixed-routes stamped by a real other chipdb ($CHIPDB_OTHER): '${other#\# nextpnr-xilinx chipdb: }' against '${idl#\# nextpnr-xilinx chipdb: }', refused at rc $rc"
        else
            report "FAIL fixed-routes stamped by a real other chipdb ($CHIPDB_OTHER): '${other:-no identity line}' against '${idl:-none}', rc $rc"
        fi
    else
        echo "SKIP fixed-routes stamped by a real other chipdb: CHIPDB_OTHER is not set"
    fi
    (unset NEXTPNR_PARTITION_ROI
        npnr "$OUT/id-none.log" --json "$OUT/placed.json" --no-pack --no-place --fixed-routes "$OUT/id-none.routes")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        report "PASS fixed-routes with no chipdb line and no rectangle: rc 0"
    else
        report "FAIL fixed-routes with no chipdb line and no rectangle: rc $rc: $(grep -m1 '^ERROR' "$OUT/id-none.log")"
    fi
}

arm_region_only_keeps_output
arm_fixed_routes_command_line_wins
arm_router1_refused_under_a_rectangle
arm_static_keepout
arm_const_containment
arm_frozen_cell_not_moved
arm_weak_static_cell_not_moved
arm_pinned_cell_not_moved_without_a_rectangle
arm_pre_place_region_kept
arm_region_only_placed_input_refused
arm_region_only_all_exempt_refused
arm_bel_blacklist_fails_closed
arm_skip_failed_arcs_under_a_rectangle
arm_partition_modes_recorded
arm_lut_perm_drop_mode
arm_lut_perm_function
arm_fixed_routes_chipdb_identity
arm_heap_scarce_by_device
arm_routing_cycle_refused
arm_carry_tree_on_a_blacklisted_bel

echo "artefacts kept in $OUT"
exit "$rc_total"
