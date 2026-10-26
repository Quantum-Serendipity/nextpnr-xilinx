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
        --no-route --seed 1 --freq 100 --log "$OUT/place.log" -q >/dev/null 2>&1; then
    echo "FAIL base placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi
"$PYTHON" - "$OUT/placed.json" "$OUT/unplaced.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["modules"]["top"]["cells"].values():
    if c["type"] in ("SLICE_LUTX", "SLICE_FFX"):
        c["attributes"].pop("NEXTPNR_BEL", None)
        c["attributes"].pop("BEL_STRENGTH", None)
json.dump(d, open(sys.argv[2], "w"))
PY
printf '{"info": {"GRID_X_MIN": 100, "GRID_X_MAX": 120, "GRID_Y_MIN": 180, "GRID_Y_MAX": 200}}\n' >"$OUT/roi.json"

NEXTPNR_PARTITION_ROI=$OUT/roi.json NEXTPNR_PARTITION_NETS=warn TWO_PLACERS_CHIPDB=$CHIPDB \
    TWO_PLACERS_JSON=$OUT/unplaced.json timeout 900 "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/unplaced.json" \
    --placer heap --log "$OUT/two.log" --run "$HERE/two_placers.py" >"$OUT/two.out" 2>&1
rc=$?
mapfile -t lines < <(grep -o 'HeAP legaliser: SLICE_LUTX has .*' "$OUT/two.log")
cand() { sed -n 's/.* has \([0-9]*\) placement candidate(s) of \([0-9]*\) bel(s).*/\1/p' <<<"$1"; }
dev() { sed -n 's/.* has \([0-9]*\) placement candidate(s) of \([0-9]*\) bel(s).*/\2/p' <<<"$1"; }
if [ "$rc" -eq 0 ] && grep -q 'two-placers: second placement done' "$OUT/two.out"; then
    report "PASS two HeAP placers in one process both complete: rc 0"
else
    report "FAIL two HeAP placers in one process both complete: rc $rc, $(grep -m1 -E '^ERROR|Error|Traceback' "$OUT/two.out")"
fi
c1=$(cand "${lines[0]:-}")
d1=$(dev "${lines[0]:-}")
if [ "${#lines[@]}" -ge 1 ] && [ -n "$c1" ] && [ "$c1" -le 4096 ] && [ "$d1" -gt 4096 ] && [[ ${lines[0]} == *"; scarce, "* ]]; then
    report "PASS first placer, under a rectangle, counts its own candidates: $c1 of $d1 SLICE_LUTX bels, scarce"
else
    report "FAIL first placer, under a rectangle, counts its own candidates: '${lines[0]:-no classification line}'"
fi
c2=$(cand "${lines[1]:-}")
if [ "${#lines[@]}" -eq 2 ] && [ -n "$c2" ] && [ "$c2" -gt 4096 ] && [[ ${lines[1]} == *"; abundant" ]]; then
    report "PASS second placer, with no rectangle, counts its own candidates rather than the first placer's: $c2, abundant"
else
    report "FAIL second placer, with no rectangle, counts its own candidates rather than the first placer's: ${#lines[@]} classification line(s), second '${lines[1]:-none}'"
fi
echo "artefacts kept in $OUT"
exit "$rc_total"
