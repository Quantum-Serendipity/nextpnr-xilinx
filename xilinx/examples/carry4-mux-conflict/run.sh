#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1

NEXTPNR=${NEXTPNR:-../../../build/nextpnr-xilinx}
CHIPDB=${CHIPDB:?set CHIPDB to an xc7a35tcsg324.bin}

ARMS=(
    "conflict        route  1 1 1 0 0 O1"
    "ctl_co_unused   route  1 1 1 0 0 O3"
    "ctl_o_to_ff     route  1 1 1 0 0 O1"
    "ctl_sum_only    route  0 0 1 0 0 -"
    "ctl_pinned      place  0 0 1 1 0 -"
)

rc_total=0
for arm in "${ARMS[@]}"; do
    read -r v mode w_sum w_split w_chain w_pchain w_pcell w_bits <<<"$arm"
    extra=""
    [ "$mode" = "place" ] && extra="--no-route"

    yosys -q -p "synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json $v.json" "$v.v"
    rc=$?
    if [ $rc -ne 0 ]; then echo "FAIL $v: yosys rc=$rc"; rc_total=1; continue; fi

    # shellcheck disable=SC2086
    DBG_CARRYO=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc carry4.xdc --json "$v.json" $extra \
               --write "$v.routed.json" > "$v.log" 2>&1
    rc=$?

    summary=$(sed -nE 's/^Info: +Carry-O relocation: ([0-9]+) sum\(s\) duplicated, ([0-9]+) CARRY4 split\(s\) over ([0-9]+) chain\(s\); ([0-9]+) BEL-pinned chain\(s\), ([0-9]+) BEL-pinned cell\(s\).*/\1 \2 \3 \4 \5/p' "$v.log" | tail -1)
    if [ -z "$summary" ]; then
        echo "FAIL $v: packer emitted no carry-O relocation summary (did the pass run?)"
        rc_total=1
        continue
    fi
    read -r g_sum g_split g_chain g_pchain g_pcell <<<"$summary"

    g_bits=$(grep -oE '^Info: CARRO [^ ]+\.O[0-9]+' "$v.log" | sed 's/.*\.//' | sort -u | paste -sd, -)
    [ -z "$g_bits" ] && g_bits="-"

    status=ok
    [ "$rc" -eq 0 ] || status=bad
    [ "$g_sum" = "$w_sum" ] && [ "$g_split" = "$w_split" ] && [ "$g_chain" = "$w_chain" ] &&
        [ "$g_pchain" = "$w_pchain" ] && [ "$g_pcell" = "$w_pcell" ] && [ "$g_bits" = "$w_bits" ] || status=bad
    [ "$status" = ok ] || rc_total=1
    printf '%-4s %-15s rc=%-3s sums=%s/%s splits=%s/%s chains=%s/%s pinned=%s/%s,%s/%s bits=%s/%s\n' \
        "$( [ $status = ok ] && echo PASS || echo FAIL )" \
        "$v" "$rc" "$g_sum" "$w_sum" "$g_split" "$w_split" "$g_chain" "$w_chain" \
        "$g_pchain" "$w_pchain" "$g_pcell" "$w_pcell" "$g_bits" "$w_bits"
done

for v in conflict ctl_pinned; do
    extra=""
    [ "$v" = ctl_pinned ] && extra="--no-route"
    # shellcheck disable=SC2086
    DBG_CARRYO=1 DBG_SFEED=1 DBG_BIND=1 NEXTPNR_DBG_LUTGATE=1 "$NEXTPNR" --chipdb "$CHIPDB" --xdc carry4.xdc \
        --json "$v.json" $extra --write "$v.dbg.routed.json" > "$v.dbg.log" 2>&1
    rc=$?
    residue=$(grep -cE '^Info: (SFEED|FEEDPOS|BINDCH|BIND-OK|BIND-FAIL|LUTGATE)' "$v.dbg.log")
    if [ "$rc" -eq 0 ] && [ "$residue" -eq 0 ] && cmp -s "$v.routed.json" "$v.dbg.routed.json"; then
        echo "PASS $v debug-env: DBG_SFEED, DBG_BIND and NEXTPNR_DBG_LUTGATE print nothing and change nothing"
    else
        echo "FAIL $v debug-env: rc=$rc, $residue debug line(s), output $(cmp -s "$v.routed.json" "$v.dbg.routed.json" && echo same || echo different)"
        rc_total=1
    fi
done
exit $rc_total
