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
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tcsg324.bin}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

rc_total=0
report() {
    local verdict=$1
    shift
    echo "$verdict $*"
    [ "$verdict" = PASS ] || rc_total=1
}

pnr() {
    local v=$1
    if [ -f "$OUT/$v.json" ]; then
        :
    elif ! "$YOSYS" -q -l "$OUT/$v.yosys.log" \
            -p "read_verilog \"$HERE/$v.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
            >/dev/null 2>&1; then
        echo yosys
        return
    fi
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$HERE/bufgctrl-ignore.xdc" --json "$OUT/$v.json" \
        --fasm "$OUT/$v.fasm" --log "$OUT/$v.npnr.log" -q --seed 1 >/dev/null 2>&1
    echo $?
}

with_param() {
    local v=$1 base=$2 cell_type=$3 param=$4 value=$5
    "$PYTHON" - "$OUT/$base.json" "$OUT/$v.json" "$cell_type" "$param" "$value" <<'PY'
import json, sys
src, dst, cell_type, param, value = sys.argv[1:]
d = json.load(open(src))
hits = 0
for m in d["modules"].values():
    for c in m.get("cells", {}).values():
        if c["type"] == cell_type:
            c.setdefault("parameters", {})[param] = value
            hits += 1
if hits != 1:
    sys.exit("expected one %s cell in %s, found %d" % (cell_type, src, hits))
json.dump(d, open(dst, "w"))
PY
}

ignore_bits() {
    local v=$1 want=$2 rc got
    rc=$(pnr "$v")
    if [ "$rc" != 0 ]; then
        report FAIL "$v: build rc $rc, want 0"
        return 1
    fi
    if [ "$(grep -cE '\.BUFGCTRL\.BUFGCTRL_X0Y[0-9]+\.IN_USE$' "$OUT/$v.fasm")" != 1 ]; then
        report FAIL "$v: not exactly one BUFGCTRL IN_USE line"
        return 1
    fi
    got=$(grep -E '\.BUFGCTRL\.BUFGCTRL_X0Y[0-9]+\.IS_IGNORE[01]_INVERTED$' "$OUT/$v.fasm" | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        report PASS "$v: IGNORE bits '${got}'"
    else
        report FAIL "$v: IGNORE bits '$got', want '$want'"
    fi
}

site_bits() {
    local v=$1 want=$2 got
    got=$(grep -E '\.BUFGCTRL\.BUFGCTRL_X0Y[0-9]+\.(INIT_OUT|IS_IGNORE[01]_INVERTED|ZINV_(CE|S)[01])$' "$OUT/$v.fasm" | sed 's/.*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        report PASS "$v: site bits '${got}'"
    else
        report FAIL "$v: site bits '$got', want '$want'"
    fi
}

refuses() {
    local v=$1 want=$2 rc
    rc=$(pnr "$v")
    if [ "$rc" != 0 ] && [ "$rc" != yosys ] && grep -qF -- "$want" "$OUT/$v.npnr.log"; then
        report PASS "$v: refused (rc $rc) with '$want'"
    else
        report FAIL "$v: rc $rc, want a refusal naming '$want'"
    fi
}

ignore_bits bufg 'IS_IGNORE1_INVERTED'
ignore_bits bufgce 'IS_IGNORE1_INVERTED'
if ignore_bits bufgmux_sel ''; then
    n=$(grep -cE '\.GFAN[01]\.GND_WIRE$' "$OUT/bufgmux_sel.fasm")
    [ "$n" = 0 ] && report PASS "bufgmux_sel: IGNORE0/IGNORE1 tied low through VCC and the site inverter, no GND_WIRE route" ||
        report FAIL "bufgmux_sel: $n GFAN.GND_WIRE pip(s), want 0"
fi
site_bits bufgmux_sel 'ZINV_CE1 ZINV_S0 ZINV_S1'
ignore_bits bufgmux_async 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED' &&
    site_bits bufgmux_async 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED ZINV_CE1 ZINV_S0 ZINV_S1'
ignore_bits bufgmux_1 '' && site_bits bufgmux_1 'INIT_OUT ZINV_CE1 ZINV_S0 ZINV_S1'
ignore_bits bufgmux_ctrl '' && site_bits bufgmux_ctrl 'ZINV_CE0 ZINV_CE1 ZINV_S1'
refuses bufgmux_clksel_bogus 'CLK_SEL_TYPE must be "SYNC" or "ASYNC", not "SOMETIMES"'
if with_param bufgmux_ctrl_async bufgmux_ctrl BUFGMUX_CTRL CLK_SEL_TYPE ASYNC; then
    ignore_bits bufgmux_ctrl_async 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED' &&
        site_bits bufgmux_ctrl_async 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED ZINV_CE0 ZINV_CE1 ZINV_S1'
else
    report FAIL "bufgmux_ctrl_async: could not add CLK_SEL_TYPE to the bufgmux_ctrl netlist"
fi
ignore_bits bufgctrl_tie0 ''
if with_param bufgctrl_clksel bufgctrl_tie0 BUFGCTRL CLK_SEL_TYPE ASYNC; then
    refuses bufgctrl_clksel 'sets CLK_SEL_TYPE'
else
    report FAIL "bufgctrl_clksel: could not add CLK_SEL_TYPE to the bufgctrl_tie0 netlist"
fi
ignore_bits bufgctrl_tie1 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED'
ignore_bits bufgctrl_tie1inv ''
ignore_bits bufgctrl_sig 'IS_IGNORE0_INVERTED IS_IGNORE1_INVERTED'
ignore_bits bufgctrl_siginv ''

echo "artefacts kept in $OUT"
exit "$rc_total"
