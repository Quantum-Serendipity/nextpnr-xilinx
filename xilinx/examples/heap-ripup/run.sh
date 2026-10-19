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
NPNR_TIMEOUT=${NPNR_TIMEOUT:-600}
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1
cd "$HERE" || exit 1

XDC=$HERE/../comb-loop/comb-loop.xdc

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

synth() {
    local out=$1 src=$2 param=$3
    "$YOSYS" -q -l "$out.yosys.log" \
        -p "read_verilog \"$src\"; $param synth_xilinx -flatten -abc9 -nodsp -arch xc7 -top top; write_json \"$out.json\"" \
        >/dev/null 2>&1
}

place() {
    local out=$1
    shift
    timeout "$NPNR_TIMEOUT" "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$XDC" --json "$out.json" --placer heap --no-route \
        --log "$out.log" -q --seed 1 "$@" >"$out.stdout" 2>&1
}

grade() {
    awk '
        /strict legalisation: [0-9]+ rip-up radius escalation\(s\), radius -?[0-9]+ of grid [0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "legalisation:") n = $(i + 1)
                if ($i == "radius" && $(i + 1) ~ /^-?[0-9]+$/) r = $(i + 1)
                if ($i == "grid") g = $(i + 1)
            }
            want = 2
            for (k = 0; k < n; k++) want = want * 2 > g ? g : want * 2
            lines++
            if (r != want) { bad++; if (!first) first = sprintf("%d escalation(s) left radius %d, want %d of grid %d", n, r, want, g) }
            if (n >= 2 && r < g) ramp++
            if (r == g && want == g) clamp++
            if (n > maxn) maxn = n
        }
        END {
            if (bad) { printf "off-ramp %d of %d: %s\n", bad, lines, first; exit }
            printf "lines=%d ramp=%d clamp=%d maxn=%d\n", lines + 0, ramp + 0, clamp + 0, maxn + 0
        }' "$1"
}

field() {
    printf '%s\n' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"
}

if ! synth "$OUT/comb" "$HERE/../comb-loop/top.v" ""; then
    report "FAIL comb-loop: yosys"
elif ! place "$OUT/comb"; then
    report "FAIL comb-loop: nextpnr: $(grep -m1 '^ERROR' "$OUT/comb.log")"
else
    g=$(grade "$OUT/comb.log")
    case $g in
        off-ramp*) report "FAIL comb-loop: $g" ;;
        *) if [ "$(field "$g" lines)" -ge 1 ]; then
               report "PASS comb-loop: $g, every line at min(grid, 2 << escalations)"
           else
               report "FAIL comb-loop: no strict-legalisation escalation line to grade"
           fi ;;
    esac
fi

ramp_pass="" ramp_seen=""
for K in 126 130 132 134 136 138; do
    if ! synth "$OUT/ramp-$K" "$HERE/dense.v" "chparam -set K $K top;"; then
        ramp_seen="$ramp_seen K=$K:yosys"
        continue
    fi
    if ! RIPUP_REGION=13,53,14,62 place "$OUT/ramp-$K" --pre-place "$HERE/region.py"; then
        ramp_seen="$ramp_seen K=$K:rc"
        continue
    fi
    g=$(grade "$OUT/ramp-$K.log")
    case $g in
        off-ramp*) report "FAIL ramp: K=$K $g"; ramp_pass=off; break ;;
    esac
    ramp_seen="$ramp_seen K=$K:ramp=$(field "$g" ramp)"
    if [ "$(field "$g" ramp)" -ge 1 ]; then
        ramp_pass="K=$K $g"
        break
    fi
done
case $ramp_pass in
    off) ;;
    "") report "FAIL ramp: no density in the sweep gave a line with two or more escalations below the grid:$ramp_seen" ;;
    *) report "PASS ramp: $ramp_pass, a line with two or more escalations still below the grid (sweep:$ramp_seen)" ;;
esac

if ! synth "$OUT/clamp" "$HERE/dense.v" "chparam -set K 16 top;"; then
    report "FAIL clamp: yosys"
else
    RIPUP_REGION=13,53,14,54 place "$OUT/clamp" --pre-place "$HERE/region.py"
    rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q '^ERROR: Unable to find legal placement for all cells' "$OUT/clamp.log"; then
        report "FAIL clamp: rc $rc, wanted the strict legaliser to give up on an over-full region: $(grep -m1 '^ERROR' "$OUT/clamp.log")"
    else
        g=$(grade "$OUT/clamp.log")
        case $g in
            off-ramp*) report "FAIL clamp: $g" ;;
            *) if [ "$(field "$g" clamp)" -ge 1 ]; then
                   report "PASS clamp: $g, the radius stops at the grid"
               else
                   report "FAIL clamp: $g, no line reached the grid"
               fi ;;
        esac
    fi
fi

exit $rc_total
