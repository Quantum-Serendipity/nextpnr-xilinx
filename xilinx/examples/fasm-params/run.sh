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
    local v=$1 xdc=$HERE/fasm-params.xdc
    [ -f "$HERE/$v.xdc" ] && xdc=$HERE/$v.xdc
    if ! "$YOSYS" -q -l "$OUT/$v.yosys.log" \
            -p "read_verilog \"$HERE/$v.v\"; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json \"$OUT/$v.json\"" \
            >/dev/null 2>&1; then
        echo yosys
        return
    fi
    "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$xdc" --json "$OUT/$v.json" \
        --fasm "$OUT/$v.fasm" --log "$OUT/$v.npnr.log" -q --seed 1 >/dev/null 2>&1
    echo $?
}

builds() {
    local v=$1 rc
    rc=$(pnr "$v")
    if [ "$rc" = 0 ]; then
        return 0
    fi
    report FAIL "$v: build rc $rc, want 0"
    return 1
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

feature() {
    local v=$1 pattern=$2 want=$3 got
    got=$(grep -E -- "$pattern" "$OUT/$v.fasm" | sed 's/^[^.]*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        report PASS "$v: $pattern -> $got"
    else
        report FAIL "$v: $pattern -> '$got', want '$want'"
    fi
}

log_has() {
    local v=$1 want=$2
    grep -qF -- "$want" "$OUT/$v.npnr.log" && report PASS "$v: log says '$want'" ||
        report FAIL "$v: log does not say '$want'"
}

lines() {
    local v=$1 pattern=$2 want=$3 got
    got=$(grep -cE -- "$pattern" "$OUT/$v.fasm")
    [ "$got" = "$want" ] && report PASS "$v: $got line(s) matching $pattern" ||
        report FAIL "$v: $got line(s) matching $pattern, want $want"
}

if builds mmcm_d128_p90; then
    feature mmcm_d128_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'MMCME2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b100000'
fi
refuses mmcm_d128_p180 'PHASE_OUT_OF_RANGE'
refuses mmcm_d100_p270 'PHASE_OUT_OF_RANGE'
if builds pll_d100_p90; then
    feature pll_d100_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'PLLE2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b011001'
fi
refuses pll_d100_p270 'PHASE_OUT_OF_RANGE'
if builds pll_d27_p185; then
    feature pll_d27_p185 'CLKOUT1_CLKOUT1_PHASE_MUX' 'PLLE2_ADV.CLKOUT1_CLKOUT1_PHASE_MUX[2:0] = 3'"'"'b111'
    feature pll_d27_p185 'CLKOUT1_CLKOUT2_DELAY_TIME' 'PLLE2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b001101'
fi
if builds mmcm_d1_p90; then
    feature mmcm_d1_p90 'CLKOUT1_CLKOUT2_NO_COUNT' 'MMCME2_ADV.CLKOUT1_CLKOUT2_NO_COUNT[0]'
    feature mmcm_d1_p90 'CLKOUT1_CLKOUT1_PHASE_MUX' 'MMCME2_ADV.CLKOUT1_CLKOUT1_PHASE_MUX[2:0] = 3'"'"'b010'
    feature mmcm_d1_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'MMCME2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b000000'
    feature mmcm_d1_p90 'POWER_REG' 'MMCME2_ADV.POWER_REG_POWER_REG_POWER_REG[15:0] = 16'"'"'b1001100100000000'
fi
for d in 0:000:0000000100000000 45:001:1001100100000000 180:100:0000000100000000; do
    a=mmcm_d1_p${d%%:*}
    m=${d#*:}
    if builds "$a"; then
        feature "$a" 'CLKOUT1_CLKOUT2_NO_COUNT' 'MMCME2_ADV.CLKOUT1_CLKOUT2_NO_COUNT[0]'
        feature "$a" 'CLKOUT1_CLKOUT1_PHASE_MUX' "MMCME2_ADV.CLKOUT1_CLKOUT1_PHASE_MUX[2:0] = 3'b${m%%:*}"
        feature "$a" 'POWER_REG' "MMCME2_ADV.POWER_REG_POWER_REG_POWER_REG[15:0] = 16'b${m#*:}"
    fi
done
if builds pll_d1_p90; then
    feature pll_d1_p90 'CLKOUT1_CLKOUT2_NO_COUNT' 'PLLE2_ADV.CLKOUT1_CLKOUT2_NO_COUNT[0]'
    feature pll_d1_p90 'CLKOUT1_CLKOUT1_PHASE_MUX' 'PLLE2_ADV.CLKOUT1_CLKOUT1_PHASE_MUX[2:0] = 3'"'"'b010'
    feature pll_d1_p90 'CLKOUT1_CLKOUT2_DELAY_TIME' 'PLLE2_ADV.CLKOUT1_CLKOUT2_DELAY_TIME[5:0] = 6'"'"'b000000'
fi
if builds mmcm_mult_default; then
    feature mmcm_mult_default 'CLKFBOUT_CLKOUT1_(HIGH|LOW)_TIME' 'MMCME2_ADV.CLKFBOUT_CLKOUT1_HIGH_TIME[5:0] = 6'"'"'b000010 MMCME2_ADV.CLKFBOUT_CLKOUT1_LOW_TIME[5:0] = 6'"'"'b000011'
    lines mmcm_mult_default 'CLKFBOUT_CLKOUT2_NO_COUNT' 0
    log_has mmcm_mult_default 'VCO 625.0 MHz'
fi
if builds pll_mult_default; then
    feature pll_mult_default 'CLKFBOUT_CLKOUT1_(HIGH|LOW)_TIME' 'PLLE2_ADV.CLKFBOUT_CLKOUT1_HIGH_TIME[5:0] = 6'"'"'b000010 PLLE2_ADV.CLKFBOUT_CLKOUT1_LOW_TIME[5:0] = 6'"'"'b000011'
    lines pll_mult_default 'CLKFBOUT_CLKOUT2_NO_COUNT' 0
    log_has pll_mult_default 'VCO 1000.0 MHz'
    feature pll_mult_default 'LKTABLE' 'PLLE2_ADV.LKTABLE[39:0] = 40'"'"'b0111001110111110100011111010010000000001'
    feature pll_mult_default '\.TABLE\[' 'PLLE2_ADV.TABLE[9:0] = 10'"'"'b0111101100'
fi

if builds dsp_pattern; then
    feature dsp_pattern '\.PATTERN\[' "DSP48.DSP_0.PATTERN[47:0] = 48'b$(printf '0%.0s' $(seq 47))1"
    feature dsp_pattern '\.MASK\[' "DSP48.DSP_0.MASK[47:0] = 48'b11$(printf '0%.0s' $(seq 44))10"
fi
if builds dsp_default; then
    lines dsp_default '\.PATTERN\[' 0
    feature dsp_default '\.MASK\[' "DSP48.DSP_0.MASK[47:0] = 48'b00$(printf '1%.0s' $(seq 46))"
fi
refuses dsp_areg3 'AREG=3 and ACASCREG=1'
refuses dsp_areg0_acascreg1 'AREG=0 and ACASCREG=1'
refuses dsp_breg1_bcascreg2 'BREG=1 and BCASCREG=2'
refuses dsp_simd_bogus 'USE_SIMD=FOUR'
if builds dsp_simd_four12; then
    feature dsp_simd_four12 'USE_SIMD' 'DSP48.DSP_0.USE_SIMD_FOUR12 DSP48.DSP_0.USE_SIMD_FOUR12_TWO24'
fi
refuses dsp_sel_pattern_c 'SEL_PATTERN=C. That is a legal DSP48E1 value'

if builds bram_sdp; then
    lines bram_sdp 'EN_ECC' 0
fi
if builds bram_ecc; then
    feature bram_ecc 'EN_ECC' 'RAMB36.EN_ECC_READ RAMB36.EN_ECC_WRITE'
fi
if builds bram_w1; then
    lines bram_w1 'BRAM36_READ_WIDTH_A_1' 1
fi
refuses bram_ext_lowercase 'RAM_EXTENSION_A=lower'
refuses bram_collision_bogus 'RDADDR_COLLISION_HWCONFIG=PERF'

if builds oddr_t_tie0; then
    feature oddr_t_tie0 'ZINV_T[12]$' 'OLOGIC_Y0.ZINV_T2'
fi
for d in lvcmos33_d16:LVCMOS33.DRIVE.I16 lvcmos33_d12:LVCMOS33_LVTTL.DRIVE.I12_I16 \
         lvttl_d12:LVCMOS33_LVTTL.DRIVE.I12_I8 lvttl_d16:LVCMOS33_LVTTL.DRIVE.I12_I16; do
    if builds "iob_${d%%:*}"; then
        feature "iob_${d%%:*}" '\.DRIVE\.' "IOB_Y0.${d#*:}"
    fi
done

echo "artefacts kept in $OUT"
exit "$rc_total"
