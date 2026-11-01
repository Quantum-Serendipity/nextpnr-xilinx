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

NETLIST=$HERE/../counter25/top.json
XDC=$HERE/counter25-a100t.xdc

npnr() {
    local log=$1
    shift
    timeout 600 "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$XDC" --log "$log" -q "$@" >/dev/null 2>&1
}

settings_of() {
    "$PYTHON" -c 'import json,sys; s=json.load(open(sys.argv[1]))["modules"]["top"]["settings"]; print(" ".join(sorted(k + "=" + str(v).strip() for k, v in s.items() if k.startswith(sys.argv[2]))))' "$1" "$2" 2>/dev/null ||
        echo UNREADABLE
}

if ! npnr "$OUT/place.log" --json "$NETLIST" --write "$OUT/placed.json" --no-route --seed 1; then
    echo "FAIL base placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    exit 1
fi

timeout 60 "$NEXTPNR" --list-knobs >"$OUT/list.txt" 2>&1
rc=$?
row() { awk -F'\t' -v k="$1" '$1 == k { print $2 "|" $3 }' "$OUT/list.txt"; }
r_hold=$(row knob/hold_export)
r_beta=$(row placerHeap/beta)
r_omit=$(row knob/carry_omit_gnd_di)
r_async=$(row knob/async_groups)
r_start=$(row knob/setup_export_start)
if [ "$rc" -eq 0 ] && [ "$r_hold" = "NEXTPNR_HOLD_EXPORT|environment not read" ] &&
        [ "$r_beta" = "NEXTPNR_PLACER_BETA|environment alias read (deprecated)" ] &&
        [ "$r_omit" = "NEXTPNR_CARRY_OMIT_GND_DI|removed, refused from the environment and --set" ] &&
        [ "$r_async" = "NEXTPNR_ASYNC_GROUPS|removed, refused from the environment and --set" ] &&
        [ "$r_start" = "-|no environment name" ]; then
    report "PASS --list-knobs: rc 0, a refused knob, an alias, both removed names and a knob with no environment name are listed with their status"
else
    report "FAIL --list-knobs: rc $rc, hold_export '$r_hold', placerHeap/beta '$r_beta', carry_omit_gnd_di '$r_omit', async_groups '$r_async', setup_export_start '$r_start'"
fi

npnr "$OUT/set.log" --json "$OUT/placed.json" --no-pack --no-place --set knob/crit_export="$OUT/set-crit.tsv" \
    --write "$OUT/set.json"
rc=$?
npnr "$OUT/unset.log" --json "$OUT/placed.json" --no-pack --no-place --write "$OUT/unset.json"
rc0=$?
echoed=$(settings_of "$OUT/set.json" knob/)
echoed0=$(settings_of "$OUT/unset.json" knob/)
if [ "$rc" -eq 0 ] && [ "$rc0" -eq 0 ] && [ -s "$OUT/set-crit.tsv" ] && [ ! -e "$OUT/unset-crit.tsv" ] &&
        grep -q "^Info: knob knob/crit_export=$OUT/set-crit.tsv (from --set)" "$OUT/set.log" &&
        [ "$echoed" = "knob/crit_export=$OUT/set-crit.tsv" ] && [ -z "$echoed0" ] && ! grep -q '^Info: knob ' "$OUT/unset.log"; then
    report "PASS --set knob/crit_export takes effect: the export is written, the knob is logged and echoed into the written netlist; unset, none of the three"
else
    report "FAIL --set knob/crit_export takes effect: rc $rc/$rc0, export $([ -s "$OUT/set-crit.tsv" ] && echo written || echo missing), echoed '$echoed', unset run echoed '$echoed0'"
fi

NEXTPNR_CRIT_EXPORT="$OUT/env-crit.tsv" npnr "$OUT/env.log" --json "$OUT/placed.json" --no-pack --no-place
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$OUT/env-crit.tsv" ] &&
        grep -q "^ERROR: NEXTPNR_CRIT_EXPORT is no longer read from the environment; pass --set knob/crit_export=<value> instead" "$OUT/env.log"; then
    report "PASS environment refusal: NEXTPNR_CRIT_EXPORT is refused at rc $rc and the message names --set knob/crit_export"
else
    report "FAIL environment refusal: rc $rc, $(grep -m1 '^ERROR' "$OUT/env.log")"
fi

NEXTPNR_CARRY_OMIT_GND_DI=1 npnr "$OUT/omit.log" --json "$OUT/placed.json" --no-pack --no-place
rc=$?
npnr "$OUT/omit-set.log" --json "$OUT/placed.json" --no-pack --no-place --set knob/carry_omit_gnd_di=1
rc2=$?
if [ "$rc" -ne 0 ] && [ "$rc2" -ne 0 ] &&
        grep -q "^ERROR: NEXTPNR_CARRY_OMIT_GND_DI was removed and is refused: the mode was deleted" "$OUT/omit.log" &&
        grep -q "^ERROR: --set knob/carry_omit_gnd_di: NEXTPNR_CARRY_OMIT_GND_DI was removed and is refused" "$OUT/omit-set.log"; then
    report "PASS removed knob: NEXTPNR_CARRY_OMIT_GND_DI is refused from the environment (rc $rc) and from --set (rc $rc2), naming the removal"
else
    report "FAIL removed knob: rc $rc/$rc2, $(grep -m1 '^ERROR' "$OUT/omit.log"), $(grep -m1 '^ERROR' "$OUT/omit-set.log")"
fi

NEXTPNR_PLACER_BETA=0.3 npnr "$OUT/alias.log" --json "$NETLIST" --fasm "$OUT/alias.fasm" --write "$OUT/alias.json" --seed 1
rc=$?
npnr "$OUT/alias-set.log" --json "$NETLIST" --fasm "$OUT/alias-set.fasm" --set placerHeap/beta=0.3 --seed 1
rc2=$?
rec=$(settings_of "$OUT/alias.json" placerHeap/beta)
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] &&
        grep -q "^Info: knob placerHeap/beta=0.3 (from environment NEXTPNR_PLACER_BETA, a deprecated alias)" "$OUT/alias.log" &&
        grep -q "^Info: HeAP congestion knobs: beta=0.300 " "$OUT/alias.log" &&
        grep -q "^Info: HeAP congestion knobs: beta=0.300 " "$OUT/alias-set.log" &&
        cmp -s "$OUT/alias.fasm" "$OUT/alias-set.fasm" && [ "$rec" = "placerHeap/beta=0.3" ]; then
    report "PASS environment alias: NEXTPNR_PLACER_BETA=0.3 is read as placerHeap/beta, places with beta 0.300 and gives the FASM of --set placerHeap/beta=0.3"
else
    report "FAIL environment alias: rc $rc/$rc2, recorded '$rec', $(grep -m1 'HeAP congestion' "$OUT/alias.log"), FASM $(cmp -s "$OUT/alias.fasm" "$OUT/alias-set.fasm" && echo equal || echo differ)"
fi

R2_ON=(--set router2/critWeight=1 --set router2/tmgRipupIters=2 --set router2/revisitLowerDelay=1)
npnr "$OUT/r2-off.log" --json "$OUT/placed.json" --no-pack --no-place --router router2 --fasm "$OUT/r2-off.fasm" \
    --write "$OUT/r2-off.json"
rc0=$?
npnr "$OUT/r2-on.log" --json "$OUT/placed.json" --no-pack --no-place --router router2 --fasm "$OUT/r2-on.fasm" \
    --write "$OUT/r2-on.json" "${R2_ON[@]}"
rc=$?
on_line='^Info: router2: criticality weighting on, timing-driven ripup for 2 iteration(s), lower-delay revisit on$'
if [ "$rc0" -eq 0 ] && [ "$rc" -eq 0 ] && [ -s "$OUT/r2-off.fasm" ] && [ -s "$OUT/r2-on.fasm" ] &&
        grep -q "$on_line" "$OUT/r2-on.log" && grep -q 'tmgfail=' "$OUT/r2-on.log" &&
        ! grep -q '^Info: router2: ' "$OUT/r2-off.log" && ! grep -q 'tmgfail=' "$OUT/r2-off.log" &&
        ! grep -qE 'failed to route|[1-9][0-9]* unrouted' "$OUT/r2-on.log" "$OUT/r2-off.log"; then
    report "PASS router2 options on counter25: off routes at rc 0 with no weighting line; critWeight, tmgRipupIters=2 and revisitLowerDelay on route at rc 0, logging the mode and the timing-driven ripup iterations"
else
    report "FAIL router2 options on counter25: rc $rc0/$rc, on line $(grep -c "$on_line" "$OUT/r2-on.log"), tmgfail lines on $(grep -c 'tmgfail=' "$OUT/r2-on.log") off $(grep -c 'tmgfail=' "$OUT/r2-off.log")"
fi

"$PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["modules"]["top"]["settings"]; s["router/estimateNearestWire"]="1"; s["knob/no_longlines"]="1"; [n.get("attributes", {}).pop("ROUTING", None) for n in d["modules"]["top"]["netnames"].values()]; json.dump(d, open(sys.argv[2], "w"))' \
    "$OUT/r2-on.json" "$OUT/carried.json"
npnr "$OUT/carried.log" --json "$OUT/carried.json" --no-pack --no-place --router router2 --write "$OUT/carried-out.json"
rc=$?
npnr "$OUT/carried-set.log" --json "$OUT/carried.json" --no-pack --no-place --router router2 --set router2/critWeight=1
rc2=$?
strip_line=$(grep -m1 '^Info: settings carried by the input netlist under knob/, router2/ and router/ are stripped' "$OUT/carried.log")
carried_keys=(knob/no_longlines router/estimateNearestWire router2/critWeight router2/revisitLowerDelay router2/tmgRipupIters)
missing=
left=
for k in "${carried_keys[@]}"; do
    [[ $strip_line == *" $k"[,]* || $strip_line == *" $k" ]] || missing+=" $k"
    left+=$(settings_of "$OUT/carried-out.json" "$k")
done
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -n "$strip_line" ] && [ -z "$missing" ] &&
        ! grep -q '^Info: router2: ' "$OUT/carried.log" && ! grep -q '^Info: estimateDelay: a nodal source' "$OUT/carried.log" &&
        [ -z "$left" ] && grep -q '^Info: router2: criticality weighting on' "$OUT/carried-set.log" &&
        ! grep -m1 '^Info: settings carried' "$OUT/carried-set.log" | grep -q 'router2/critWeight'; then
    report "PASS re-route from a netlist carrying router2/*, router/estimateNearestWire and knob/*: all are stripped and logged, none acts and none is written back; --set router2/critWeight=1 on the same netlist acts"
else
    report "FAIL re-route from a netlist carrying router2/*, router/estimateNearestWire and knob/*: rc $rc/$rc2, not in the strip line:${missing:- none}, written back '$left'"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
