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
PYTHON=$(resolve_tool "${PYTHON:-python3}")
ARMS=${ARMS:-negedge latch srl undriven-clock}
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

undrive_clock() {
    "$PYTHON" - "$1" "$2" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
m = j["modules"]["top"]
clk = m["ports"].pop("clk")["bits"]
pads = [n for n, c in m["cells"].items() if c["type"] == "IBUF" and c["connections"]["I"] == clk]
if len(pads) != 1:
    sys.exit("expected one IBUF on clk, found %d" % len(pads))
o = m["cells"].pop(pads[0])["connections"]["O"]
m["netnames"] = {n: v for n, v in m["netnames"].items() if v["bits"] != clk}
m["netnames"]["rmclk"] = {"hide_name": 0, "bits": o, "attributes": {}}
json.dump(j, open(sys.argv[2], "w"))
EOF
}

for arm in $ARMS; do
    xdc="$HERE/timing-arcs.xdc"
    flags="-abc9 -nodsp"
    json="$OUT/$arm.json"
    if [ "$arm" = undriven-clock ]; then
        xdc="$HERE/undriven-clock.xdc"
        flags="-abc9 -noclkbuf"
        json="$OUT/$arm.synth.json"
    fi
    if ! "$YOSYS" -q -l "$OUT/$arm.yosys.log" \
            -p "read_verilog \"$HERE/$arm.v\"; synth_xilinx -flatten $flags -arch xc7 -top top; write_json \"$json\"" \
            >/dev/null 2>&1; then
        report "FAIL $arm: yosys"
        continue
    fi
    if [ "$arm" = undriven-clock ]; then
        if ! undrive_clock "$json" "$OUT/$arm.json" 2>"$OUT/$arm.undrive.log"; then
            report "FAIL $arm: $(cat "$OUT/$arm.undrive.log")"
            continue
        fi
    fi
    NEXTPNR_SETUP_EXPORT="$OUT/$arm.setup.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$xdc" \
        --json "$OUT/$arm.json" --write "$OUT/$arm.routed.json" --fasm "$OUT/$arm.fasm" --log "$OUT/$arm.log" \
        -q --seed 1 >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "FAIL $arm: place and route rc $rc: $(grep -m1 '^ERROR' "$OUT/$arm.log")"
        continue
    fi
    while IFS= read -r line; do
        report "$line"
    done < <("$PYTHON" "$HERE/grade.py" "$OUT/$arm.routed.json" "$OUT/$arm.setup.tsv" "$arm" 2>&1)
    if [ "$arm" = undriven-clock ]; then
        if grep -q "clock net 'rmclk' has no driver" "$OUT/$arm.log"; then
            report "PASS $arm: the log names the undriven clock rmclk"
        else
            report "FAIL $arm: no log line names the undriven clock rmclk"
        fi
    fi
done

echo "artefacts kept in $OUT"
exit "$rc_total"
