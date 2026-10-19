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

geom() {
    "$PYTHON" "$HERE/geom.py" --tilegrid "$TILEGRID" "$@"
}

route() {
    local log=$1 out=$2
    shift 2
    env "$@" NEXTPNR_PIP_BLACKLIST_TILE="$OUT/gnd-block.pips" \
        timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$log" -q --json "$OUT/placed.json" \
        --no-pack --no-place --write "$out" >/dev/null 2>&1
}

if ! "$YOSYS" -q -l "$OUT/yosys.log" \
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --log "$OUT/place.log" -q --xdc "$HERE/top.xdc" \
        --json "$OUT/top.json" --write "$OUT/placed.json" --no-route --seed 1 >/dev/null 2>&1; then
    echo "FAIL base placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi

if ! read -r SITE CLB SX SY < <(geom ram "$OUT/placed.json"); then
    echo "FAIL the RAM32M did not place as eight RAMD32 cells in one slice"
    exit 1
fi
if ! DI2_CELL=$(geom ram-port "$OUT/placed.json" A6LUT DI2) || ! DI1_CELL=$(geom ram-port "$OUT/placed.json" A5LUT DI1); then
    echo "FAIL no RAMD32 at $SITE/A6LUT with DI2 and at $SITE/A5LUT with DI1"
    exit 1
fi
echo "INFO RAM32M at $SITE, tile $CLB, grid ($SX,$SY); DIA[1] is $DI2_CELL.DI2, DIA[0] is $DI1_CELL.DI1"

if ! geom gnd-block >"$OUT/gnd-block.pips"; then
    echo "FAIL could not list the GND source pips"
    exit 1
fi

GRID_W=$("$PYTHON" -c 'import json,sys; print(1 + max(t["grid_x"] for t in json.load(open(sys.argv[1])).values()))' "$TILEGRID")
if [ $((SX + 16)) -lt "$GRID_W" ]; then
    RX0=$((SX + 4)) RX1=$((SX + 16))
else
    RX0=$((SX - 16)) RX1=$((SX - 4))
fi
RY0=$((SY - 4)) RY1=$((SY + 4))
geom rect "$RX0" "$RY0" "$RX1" "$RY1" >"$OUT/rect.json"
geom rect $((SX - 2)) $((SY - 2)) $((SX + 2)) $((SY + 2)) >"$OUT/sink-rect.json"

blacklist_count() {
    sed -n 's/^Info: pip blacklist (per-tile-instance): \([0-9]*\) pips.*/\1/p' "$1" | head -1
}

handed() {
    grep -qF "$2 <- \$PACKER_GND_NET\$holdout\$" "$1"
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
    route "$log" "$OUT/norect.json" -u NEXTPNR_PARTITION_ROI
    local rc=$? n
    n=$(blacklist_count "$log")
    if [ "$rc" -ne 0 ]; then
        report "FAIL no rectangle: rc $rc: $(grep -m1 '^ERROR' "$log")"
    elif [ "${n:-0}" -eq 0 ]; then
        report "FAIL no rectangle: the GND source blacklist resolved no pip"
    elif ! handed "$log" "$DI2_CELL.DI2" || ! handed "$log" "$DI1_CELL.DI1"; then
        report "FAIL no rectangle: the LUTRAM data inputs were not handed to a holdout LUT, so the fixture never made routeVcc miss them"
    else
        report "PASS no rectangle: $DI2_CELL.DI2 and $DI1_CELL.DI1 driven from a holdout LUT, $n GND source pip(s) withheld"
    fi
}

arm_rect_clear_of_sink() {
    local log=$OUT/rect.log why shared
    route "$log" "$OUT/rect-routed.json" NEXTPNR_PARTITION_ROI="$OUT/rect.json"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        report "FAIL rectangle clear of the sink: rc $rc: $(grep -m1 '^ERROR' "$log")"
    elif ! handed "$log" "$DI2_CELL.DI2" || ! handed "$log" "$DI1_CELL.DI1"; then
        report "FAIL rectangle clear of the sink: the LUTRAM data inputs were not handed to a holdout LUT"
    elif ! why=$(holdout_bels_clear_of_rect "$OUT/rect-routed.json"); then
        report "FAIL rectangle clear of the sink: $why"
    elif ! shared=$(geom shared-wire "$OUT/rect-routed.json" WA5 A5 2>&1); then
        report "FAIL rectangle clear of the sink: $shared"
    elif [[ $shared != *'$PACKER_GND_NET$holdout$'* ]]; then
        report "FAIL rectangle clear of the sink: the shared write-address wire is on ${shared#* }, not a holdout net"
    else
        report "PASS rectangle clear of the sink: rc 0 under ($RX0,$RY0)-($RX1,$RY1), DI1 and DI2 on a holdout LUT outside it, ${shared%% *} ports on the shared WA5/A5 wire all on ${shared#* }"
    fi
}

arm_sink_inside_rect() {
    local log=$OUT/sink-inside.log
    route "$log" "$OUT/sink-inside-routed.json" NEXTPNR_PARTITION_ROI="$OUT/sink-rect.json"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        report "FAIL sink inside a rectangle: rc 0 ($(geom holdouts "$OUT/sink-inside-routed.json" | head -1))"
    elif ! grep -q "not delivered to $DI2_CELL.DI2 .*constant LUT drivers disabled for a sink inside a partition rectangle" "$log"; then
        report "FAIL sink inside a rectangle: rc $rc for another reason: $(grep -m1 "not delivered to $DI2_CELL.DI2" "$log" || grep -m1 '^ERROR' "$log")"
    else
        report "PASS sink inside a rectangle: $DI2_CELL.DI2 refused, no driver for a sink inside it"
    fi
}

arm_no_rect
arm_rect_clear_of_sink
arm_sink_inside_rect

echo "outputs in $OUT"
exit "$rc_total"
