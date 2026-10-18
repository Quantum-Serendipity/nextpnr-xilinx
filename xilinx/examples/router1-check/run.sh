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
    --fasm "$OUT/clean.fasm" --log "$OUT/clean.log" -q --seed 1 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Info: Routing complete' "$OUT/clean.log" &&
        ! grep -q 'checkRoutedDesign FAIL' "$OUT/clean.log" && [ -s "$OUT/clean.fasm" ]; then
    report "PASS clean: router1 routes the design, the post-route check accepts it, rc 0"
else
    report "FAIL clean: rc $rc: $(grep -m1 -E '^ERROR|checkRoutedDesign FAIL' "$OUT/clean.log")"
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
