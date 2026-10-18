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
        -p "read_verilog \"$HERE/top.v\"; synth_xilinx -flatten -abc9 -nodsp -arch xc7 -top top; write_json \"$OUT/top.json\"" \
        >/dev/null 2>&1; then
    echo "FAIL yosys"
    exit 1
fi

if ! "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/top.json" --pack-only \
        --write "$OUT/plain.json" --log "$OUT/plain.log" -q >/dev/null 2>&1; then
    echo "FAIL plain: nextpnr: $(grep -m1 '^ERROR' "$OUT/plain.log")"
    exit 1
fi
if ! name=$("$PYTHON" "$HERE/collide.py" find "$OUT/plain.json" 2>&1); then
    echo "FAIL plain: $name"
    exit 1
fi
report "PASS plain: the packer names its first feedthrough $name"

"$PYTHON" "$HERE/collide.py" rename "$OUT/top.json" clk "$name" "$OUT/collide.json" || exit 1
"$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/top.xdc" --json "$OUT/collide.json" --pack-only \
    --write "$OUT/collide.packed.json" --log "$OUT/collide.log" -q >"$OUT/collide.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    report "FAIL collide: rc $rc: $(grep -m1 -E 'ERROR|Assertion' "$OUT/collide.out" "$OUT/collide.log")"
elif msg=$("$PYTHON" "$HERE/collide.py" grade "$OUT/collide.packed.json" "$name" 2>&1); then
    report "PASS collide: $msg"
else
    report "$msg"
fi

exit $rc_total
