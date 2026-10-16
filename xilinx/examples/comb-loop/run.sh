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
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

synth() {
    "$YOSYS" -q -l "$OUT/$1.yosys.log" \
        -p "read_verilog $2 \"$HERE/top.v\"; synth_xilinx -flatten -arch xc7 -top top; write_json \"$OUT/$1.json\"" \
        >/dev/null 2>&1
}

pnr() {
    local name=$1
    shift
    NEXTPNR_SETUP_EXPORT="$OUT/$name.tsv" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/comb-loop.xdc" \
        --json "$OUT/$name.json" --write "$OUT/$name.routed.json" --log "$OUT/$name.log" -q --seed 1 "$@" \
        >/dev/null 2>&1
}

p_rows() {
    "$PYTHON" - "$OUT/$1.routed.json" "$OUT/$1.tsv" <<'PY'
import csv, json, re, sys
top = json.load(open(sys.argv[1]))["modules"]["top"]
p_bits = set()
for name, nn in top["netnames"].items():
    if re.fullmatch(r"p(\[\d+\])?", name):
        p_bits.update(b for b in nn["bits"] if isinstance(b, int))
p_cells = {c for c, cell in top["cells"].items() if any(b in p_bits for b in cell["connections"].get("Q", []))}
rows = {(r["cell"], r["port"]) for r in csv.DictReader(open(sys.argv[2]), delimiter="\t") if r["cell"] in p_cells}
print(len(p_cells), len(rows))
PY
}

synth control "" || { echo "FAIL yosys control"; exit 1; }
synth ring "-DRING" || { echo "FAIL yosys ring"; exit 1; }
pnr control || { echo "FAIL nextpnr control: $(grep -m1 '^ERROR' "$OUT/control.log")"; exit 1; }
pnr ring || { echo "FAIL nextpnr ring: $(grep -m1 '^ERROR' "$OUT/ring.log")"; exit 1; }

for v in control ring; do
    read -r ncells nrows <<<"$(p_rows "$v")"
    if [ "$ncells" -eq 32 ] && [ "$nrows" -eq 32 ]; then
        report "PASS $v: all 32 p registers have a setup row"
    else
        report "FAIL $v: $nrows of $ncells p registers have a setup row"
    fi
done

if grep -q 'combinational loop' "$OUT/control.log"; then
    report "FAIL control: reports a combinational loop it does not have"
else
    report "PASS control: no combinational loop reported"
fi

line=$(grep -m1 'combinational loop' "$OUT/ring.log")
if printf '%s\n' "$line" | grep -q 'timing analysis: 2 combinational loop(s) cut at 3 output port(s)'; then
    report "PASS ring: ${line#*Warning: }"
else
    report "FAIL ring: loop report is '${line#*Warning: }'"
fi

cp "$OUT/ring.json" "$OUT/strict.json"
pnr strict --no-ignore-loops
rc=$?
if [ "$rc" -ne 0 ] && grep -q '^ERROR: timing analysis: 2 combinational loop(s) through 5 output port(s)' "$OUT/strict.log"; then
    report "PASS strict: --no-ignore-loops refuses the ring (rc $rc)"
else
    report "FAIL strict: --no-ignore-loops gave rc $rc, $(grep -m1 -E '^ERROR|combinational' "$OUT/strict.log" 2>/dev/null)"
fi

echo "artefacts kept in $OUT"
exit "$rc_total"
