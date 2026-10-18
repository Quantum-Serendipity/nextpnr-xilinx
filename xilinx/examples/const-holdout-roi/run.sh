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
RADIUS_SRC=$HERE/../../route_const.cc
if [ -r "$RADIUS_SRC" ]; then
    RADIUS_FROM=$RADIUS_SRC
    RADIUS=${RADIUS:-$(sed -n 's/^const int const_lut_search_radius = \([0-9][0-9]*\);$/\1/p' "$RADIUS_SRC")}
else
    RADIUS_FROM=literal
    RADIUS=${RADIUS:-24}
fi
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

if [ -z "$RADIUS" ]; then
    echo "FAIL no const_lut_search_radius in $RADIUS_SRC; set RADIUS"
    exit 1
fi
echo "INFO search radius $RADIUS from $RADIUS_FROM"

if [ ! -r "$TILEGRID" ]; then
    echo "FAIL no tilegrid at $TILEGRID; set PRJXRAY_DB"
    exit 1
fi

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

geom() {
    "$PYTHON" "$HERE/geom.py" --tilegrid "$TILEGRID" "$@"
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

if ! read -r SRL SRL_BEL CLB SX SY < <(geom srl "$OUT/placed.json"); then
    echo "FAIL no SRL16E cell in the placement"
    exit 1
fi
echo "INFO SRL $SRL at $SRL_BEL, tile $CLB, grid ($SX,$SY)"

if ! geom vcc-block "$PRJXRAY_DB/artix7" "$CLB" >"$OUT/vcc-block.pips"; then
    echo "FAIL could not list the VCC_WIRE pips around $CLB"
    exit 1
fi

GRID_W=$("$PYTHON" -c 'import json,sys; print(1 + max(t["grid_x"] for t in json.load(open(sys.argv[1])).values()))' "$TILEGRID")
if [ $((SX + 16)) -lt "$GRID_W" ]; then
    RX0=$((SX + 4)) RX1=$((SX + 16))
else
    RX0=$((SX - 16)) RX1=$((SX - 4))
fi
RY0=$((SY - 4)) RY1=$((SY + 4))
roi "$OUT/rect.json" "$RX0" "$RY0" "$RX1" "$RY1"

logged_radius() {
    sed -n 's/.*no free LUT bel within \([0-9][0-9]*\) tiles of .*/\1/p' "$1" | head -1
}

blacklist_count() {
    sed -n 's/^Info: pip blacklist (per-tile-instance): \([0-9]*\) pips.*/\1/p' "$1" | head -1
}

holdout_bels_clear_of_rect() {
    local n=0 name bel x y
    while read -r name bel x y; do
        n=$((n + 1))
        if [ "$x" -ge $((RX0 - 1)) ] && [ "$x" -le $((RX1 + 1)) ] && [ "$y" -ge "$RY0" ] && [ "$y" -le "$RY1" ]; then
            echo "holdout $name at $bel ($x,$y) touches the rectangle"
            return 1
        fi
    done < <(geom holdouts "$1")
    [ "$n" -gt 0 ] || { echo "no holdout LUT in $1"; return 1; }
    return 0
}

arm_no_rect() {
    local log=$OUT/norect.log
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips env -u NEXTPNR_PARTITION_ROI \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/norect.json" >/dev/null 2>&1
    local rc=$?
    local n
    n=$(blacklist_count "$log")
    if [ "$rc" -ne 0 ]; then
        report "FAIL no rectangle: rc $rc: $(grep -m1 '^ERROR' "$log")"
    elif [ "${n:-0}" -eq 0 ]; then
        report "FAIL no rectangle: the VCC_WIRE blacklist resolved no pip"
    elif ! grep -qF "$SRL.WE <- \$PACKER_VCC_NET\$holdout\$" "$log"; then
        report "FAIL no rectangle: $SRL.WE was not handed to a holdout LUT, so the fixture never made routeVcc miss it"
    elif [ -z "$(geom holdouts "$OUT/norect.json")" ]; then
        report "FAIL no rectangle: no holdout LUT in the routed netlist"
    else
        report "PASS no rectangle: $SRL.WE driven from a holdout LUT, $n VCC_WIRE pip(s) withheld"
    fi
}

arm_rect_clear_of_sink() {
    local log=$OUT/rect.log
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips NEXTPNR_PARTITION_ROI=$OUT/rect.json \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/rect-routed.json" >/dev/null 2>&1
    local rc=$?
    local why
    if [ "$rc" -ne 0 ]; then
        report "FAIL rectangle clear of the sink: rc $rc: $(grep -m1 '^ERROR' "$log")"
    elif ! grep -qF "$SRL.WE <- \$PACKER_VCC_NET\$holdout\$" "$log"; then
        report "FAIL rectangle clear of the sink: $SRL.WE was not handed to a holdout LUT"
    elif ! why=$(holdout_bels_clear_of_rect "$OUT/rect-routed.json"); then
        report "FAIL rectangle clear of the sink: $why"
    else
        report "PASS rectangle clear of the sink: rc 0 under ($RX0,$RY0)-($RX1,$RY1), the holdout LUT outside it"
    fi
}

arm_only_driver_inside_rect() {
    local log=$OUT/inside.log
    if ! geom lut-blacklist "$OUT/placed.json" "$SX" "$SY" "$RADIUS" "$RX0" "$RY0" "$RX1" "$RY1" --keep interior \
            >"$OUT/outside-luts.bels"; then
        report "FAIL only driver inside a rectangle: could not list the LUT bels"
        return
    fi
    local interior
    interior=$(geom lut-count "$OUT/placed.json" "$SX" "$SY" "$RADIUS" "$RX0" "$RY0" "$RX1" "$RY1" --keep interior)
    if [ "${interior:-0}" -eq 0 ]; then
        report "FAIL only driver inside a rectangle: the rectangle holds no free LUT bel, so the arm cannot fail"
        return
    fi
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips NEXTPNR_PARTITION_ROI=$OUT/rect.json \
        NEXTPNR_BEL_BLACKLIST=$OUT/outside-luts.bels \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/inside-routed.json" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        report "FAIL only driver inside a rectangle: rc 0 ($(geom holdouts "$OUT/inside-routed.json" | head -1))"
    elif [ -n "$(logged_radius "$log")" ] && [ "$(logged_radius "$log")" != "$RADIUS" ]; then
        report "FAIL only driver inside a rectangle: the binary searched $(logged_radius "$log") tiles and the fixture withheld bels within $RADIUS ($RADIUS_FROM)"
    elif ! grep -q "no free LUT bel within $RADIUS tiles of $SRL_BEL for a VCC driver outside every partition rectangle" "$log"; then
        report "FAIL only driver inside a rectangle: rc $rc without the outside-every-rectangle refusal: $(grep -m1 '^ERROR' "$log")"
    elif ! grep -qF "constant VCC not delivered to $SRL.WE" "$log"; then
        report "FAIL only driver inside a rectangle: rc $rc but $SRL.WE is not the refused sink"
    else
        report "PASS only driver inside a rectangle: refused with $interior free LUT bel(s) inside it, $(wc -l <"$OUT/outside-luts.bels") outside withheld"
    fi
}

arm_sink_inside_rect() {
    local log=$OUT/sink-inside.log
    roi "$OUT/sink-rect.json" $((SX - 2)) $((SY - 2)) $((SX + 2)) $((SY + 2))
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips NEXTPNR_PARTITION_ROI=$OUT/sink-rect.json \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/sink-inside-routed.json" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        report "FAIL sink inside a rectangle: rc 0 ($(geom holdouts "$OUT/sink-inside-routed.json" | head -1))"
    elif ! grep -qF "constant VCC not delivered to $SRL.WE" "$log"; then
        report "FAIL sink inside a rectangle: rc $rc but $SRL.WE is not the refused sink: $(grep -m1 '^ERROR' "$log")"
    elif ! grep -q "not delivered to $SRL.WE .*constant LUT drivers disabled for a sink inside a partition rectangle" "$log"; then
        report "FAIL sink inside a rectangle: rc $rc for another reason: $(grep -m1 "not delivered to $SRL.WE" "$log")"
    else
        report "PASS sink inside a rectangle: refused, no driver for a sink inside it"
    fi
}

arm_only_driver_beside_rect() {
    local log=$OUT/beside.log ax0 ay0 ax1 ay1 clb
    if ! read -r ax0 ay0 ax1 ay1 clb < <(geom adjacent-rect "$SX" "$SY" 12 4); then
        report "FAIL only driver beside a rectangle: no rectangle has a logic tile beside its edge with that tile's INT inside it"
        return
    fi
    roi "$OUT/beside-rect.json" "$ax0" "$ay0" "$ax1" "$ay1"
    if ! geom lut-blacklist "$OUT/placed.json" "$SX" "$SY" "$RADIUS" "$ax0" "$ay0" "$ax1" "$ay1" \
            --keep adjacent-int-inside --keep adjacent-int-outside >"$OUT/beside-luts.bels"; then
        report "FAIL only driver beside a rectangle: could not list the LUT bels"
        return
    fi
    local unsafe kept
    unsafe=$(geom lut-count "$OUT/placed.json" "$SX" "$SY" "$RADIUS" "$ax0" "$ay0" "$ax1" "$ay1" --keep adjacent-int-inside)
    kept=$(geom lut-count "$OUT/placed.json" "$SX" "$SY" "$RADIUS" "$ax0" "$ay0" "$ax1" "$ay1" \
        --keep adjacent-int-inside --keep adjacent-int-outside)
    if [ "${unsafe:-0}" -eq 0 ]; then
        report "FAIL only driver beside a rectangle: no free LUT bel beside ($ax0,$ay0)-($ax1,$ay1) has its INT inside it, so the arm cannot fail"
        return
    fi
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips NEXTPNR_PARTITION_ROI=$OUT/beside-rect.json \
        NEXTPNR_BEL_BLACKLIST=$OUT/beside-luts.bels \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/beside-routed.json" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        report "FAIL only driver beside a rectangle: rc 0 ($(geom holdouts "$OUT/beside-routed.json" | head -1))"
    elif [ -n "$(logged_radius "$log")" ] && [ "$(logged_radius "$log")" != "$RADIUS" ]; then
        report "FAIL only driver beside a rectangle: the binary searched $(logged_radius "$log") tiles and the fixture withheld bels within $RADIUS ($RADIUS_FROM)"
    elif ! grep -q "no free LUT bel within $RADIUS tiles of $SRL_BEL for a VCC driver outside every partition rectangle" "$log"; then
        report "FAIL only driver beside a rectangle: rc $rc without the outside-every-rectangle refusal: $(grep -m1 '^ERROR' "$log")"
    elif ! grep -qF "constant VCC not delivered to $SRL.WE" "$log"; then
        report "FAIL only driver beside a rectangle: rc $rc but $SRL.WE is not the refused sink"
    else
        report "PASS only driver beside a rectangle: refused under ($ax0,$ay0)-($ax1,$ay1) with $kept free LUT bel(s) beside it ($unsafe whose INT is inside, beside $clb), $(wc -l <"$OUT/beside-luts.bels") others withheld"
    fi
}

arm_reconfigurable_cells() {
    local log=$OUT/rm.log
    if ! "$YOSYS" -q -l "$OUT/yosys-rm.log" \
            -p "read_verilog \"$HERE/top-rm.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top-rm.json\"" \
            >/dev/null 2>&1; then
        report "FAIL reconfigurable cells: yosys"
        return
    fi
    if ! npnr "$OUT/place-rm.log" --xdc "$HERE/top-rm.xdc" --json "$OUT/top-rm.json" --write "$OUT/placed-rm.json" \
            --no-route --seed 1; then
        report "FAIL reconfigurable cells: placement: $(grep -m1 '^ERROR' "$OUT/place-rm.log")"
        return
    fi
    local srl srl_bel clb sx sy
    if ! read -r srl srl_bel clb sx sy < <(geom srl "$OUT/placed-rm.json"); then
        report "FAIL reconfigurable cells: no SRL16E cell in the placement"
        return
    fi
    if ! geom vcc-block "$PRJXRAY_DB/artix7" "$clb" >"$OUT/vcc-block-rm.pips"; then
        report "FAIL reconfigurable cells: could not list the VCC_WIRE pips around $clb"
        return
    fi
    if ! geom unplace "$OUT/placed-rm.json" FDRE "$OUT/rm-input.json" >/dev/null; then
        report "FAIL reconfigurable cells: no FDRE to leave unplaced"
        return
    fi
    local mx0 mx1
    if [ $((sx + 16)) -lt "$GRID_W" ]; then
        mx0=$((sx + 4)) mx1=$((sx + 16))
    else
        mx0=$((sx - 16)) mx1=$((sx - 4))
    fi
    roi "$OUT/rm-rect.json" "$mx0" $((sy - 4)) "$mx1" $((sy + 4))
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block-rm.pips NEXTPNR_PARTITION_ROI=$OUT/rm-rect.json NEXTPNR_PARTITION_NETS=warn \
        NEXTPNR_PARTITION_CLAMP=off \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/rm-input.json" \
        --no-pack --seed 1 --write "$OUT/rm-routed.json" >/dev/null 2>&1
    local rc=$?
    local n
    n=$(sed -n 's/^Info: partition RM set: \([0-9]*\) reconfigurable cell.*/\1/p' "$log" | head -1)
    if [ "${n:-0}" -eq 0 ]; then
        report "FAIL reconfigurable cells: the RM set is empty, so the arm tests a static build: $(grep -m1 '^ERROR' "$log")"
    elif [ "$rc" -eq 0 ]; then
        report "FAIL reconfigurable cells: rc 0 with $n RM cell(s) ($(geom holdouts "$OUT/rm-routed.json" | head -1))"
    elif ! grep -q "not delivered to $srl.WE .*constant LUT drivers disabled under NEXTPNR_PARTITION_ROI in a build with reconfigurable cells" "$log"; then
        report "FAIL reconfigurable cells: rc $rc for another reason: $(grep -m1 "not delivered to $srl.WE" "$log" || grep -m1 '^ERROR' "$log")"
    else
        report "PASS reconfigurable cells: $srl.WE refused at rc $rc with $n RM cell(s), no driver added"
    fi
}

arm_walk_budget_exhausted() {
    local log=$OUT/walk.log
    NEXTPNR_PIP_BLACKLIST_TILE=$OUT/vcc-block.pips NEXTPNR_PARTITION_ROI=$OUT/rect.json NEXTPNR_CONST_FENCE_WALK_BUDGET=0 \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$OUT/walk-routed.json" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        report "FAIL interconnect search out of budget: rc 0 ($(geom holdouts "$OUT/walk-routed.json" | head -1))"
    elif ! grep -q "not delivered to $SRL.WE .*interconnect search exhausted its budget" "$log"; then
        report "FAIL interconnect search out of budget: rc $rc for another reason: $(grep -m1 "not delivered to $SRL.WE" "$log" || grep -m1 '^ERROR' "$log")"
    else
        report "PASS interconnect search out of budget: $SRL.WE refused as out of budget, not as fenced"
    fi
}

arm_no_rect
arm_rect_clear_of_sink
arm_only_driver_inside_rect
arm_sink_inside_rect
arm_only_driver_beside_rect
arm_reconfigurable_cells
arm_walk_budget_exhausted

echo "outputs in $OUT"
exit "$rc_total"
