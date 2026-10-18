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
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -nodsp -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

"$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --router router1 \
    --post-route "$HERE/locked.py" --fasm "$OUT/clean.fasm" --log "$OUT/clean.log" -q --seed 1 >"$OUT/clean.stdout" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Info: Routing complete' "$OUT/clean.log" &&
        ! grep -q 'checkRoutedDesign FAIL' "$OUT/clean.log" && [ -s "$OUT/clean.fasm" ] &&
        grep -q "^Info:     routing clock 'clk'" "$OUT/clean.log" &&
        grep -qE '^locked.py: net clk locked [1-9][0-9]* wire' "$OUT/clean.stdout"; then
    report "PASS clean: router1 routes the design with routeClock's locked clock tree, the post-route check accepts it, rc 0"
else
    report "FAIL clean: rc $rc: $(grep -m1 -E '^ERROR|checkRoutedDesign FAIL' "$OUT/clean.log"), $(grep -m1 '^locked.py: net clk ' "$OUT/clean.stdout")"
fi

npnr_route() {
    local tag=$1
    shift
    "$NEXTPNR" --chipdb "$CHIPDB" --json "$OUT/placed.json" --no-pack --no-place --router router1 \
        --fasm "$OUT/$tag.fasm" --log "$OUT/$tag.log" -q --seed 1 "$@" >"$OUT/$tag.stdout" 2>&1
}

DRV_CHAIN=('lfsr[14] CLBLL_L_X2Y96/130.177' 'lfsr[14] CLBLL_L_X2Y96/340.130')

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --router router1 --no-route \
        --write "$OUT/placed.json" --log "$OUT/place.log" -q --seed 1 >/dev/null 2>&1; then
    report "FAIL replay: placement: $(grep -m1 '^ERROR' "$OUT/place.log")"
    report "FAIL fragment: no placement"
elif ! npnr_route ref --write-fixed-routes "$OUT/all.routes"; then
    report "FAIL replay: reference route: $(grep -m1 '^ERROR' "$OUT/ref.log")"
    report "FAIL fragment: no reference route"
else
    pips=$(grep -vc '^#' "$OUT/all.routes")
    npnr_route full --fixed-routes "$OUT/all.routes"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^Info: Router1 time' "$OUT/full.log" &&
            grep -q "fixed-routes: bound $pips/$pips pips" "$OUT/full.log" &&
            ! grep -q 'checkRoutedDesign FAIL' "$OUT/full.log" &&
            cmp -s <(sort "$OUT/ref.fasm") <(sort "$OUT/full.fasm"); then
        report "PASS replay: router1 under a lock of all $pips routed pips passes the post-route check and reproduces the FASM, rc 0"
    else
        report "FAIL replay: rc $rc: $(grep -m1 -E '^ERROR|checkRoutedDesign FAIL|fixed-routes: bound' "$OUT/full.log")"
    fi

    missing=0
    for l in "${DRV_CHAIN[@]}"; do
        grep -qxF -- "$l" "$OUT/all.routes" || missing=1
    done
    if [ "$missing" -ne 0 ]; then
        report "FAIL fragment: the reference route no longer drives lfsr[14] through ${DRV_CHAIN[*]}; re-derive the driver chain"
    else
        grep -vxF -e "${DRV_CHAIN[0]}" -e "${DRV_CHAIN[1]}" "$OUT/all.routes" >"$OUT/frag.routes"
        npnr_route frag --fixed-routes "$OUT/frag.routes"
        rc=$?
        if ! grep -q 'fixed-routes: .* locked nets contain their driver (1 driverless' "$OUT/frag.log"; then
            report "FAIL fragment: the lock did not leave lfsr[14] driverless: $(grep -m1 'contain their driver' "$OUT/frag.log")"
        elif [ "$rc" -ne 0 ] && grep -q 'checkRoutedDesign FAIL net lfsr\[14\]:' "$OUT/frag.log"; then
            report "PASS fragment: a locked fragment cut off from its driver is refused after routing, rc $rc"
        else
            report "FAIL fragment: rc $rc, the post-route check did not refuse the driverless lfsr[14]"
        fi
    fi
fi

"$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --router router1 \
    --pre-route "$HERE/stub.py" --fasm "$OUT/stub.fasm" --log "$OUT/stub.log" -q --seed 1 >"$OUT/stub.stdout" 2>&1
rc=$?
if ! grep -q '^stub.py: bound pip ' "$OUT/stub.stdout" "$OUT/stub.log"; then
    report "FAIL stub: stub.py did not bind its pip: $(grep -m1 -E 'Error|ERROR' "$OUT/stub.stdout" "$OUT/stub.log")"
elif [ "$rc" -ne 0 ] && grep -q 'checkRoutedDesign FAIL net .*dangling=1' "$OUT/stub.log" &&
        grep -q 'Routing design failed' "$OUT/stub.stdout"; then
    report "PASS stub: a locked pip left off the route tree is refused after routing, rc $rc"
else
    report "FAIL stub: rc $rc and the post-route check did not refuse the dangling pip"
fi

exit $rc_total
