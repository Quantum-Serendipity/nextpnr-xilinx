#!/usr/bin/env bash
# Five one-CARRY4 designs on an Arty A7-35T ballout, pinning upstream openXC7's
# relocate_carry_o_fabric() (c2c05095a + its 17-commit follow-up series,
# cherry-picked onto this fork).  Before it, conflict.v died with
#
#   ERROR: Unable to find legal placement for cell 'c4', check constraints and
#          utilisation.        (common/placer_heap.cc)
#
# at 12 cells of utilisation, and every one of the ~16700 candidate sites was
# refused by the same arm, xilinx/arch_place.cc's CO-vs-output-mux check.  Run
# with NEXTPNR_DUMP_INVALID_TILE=1 to see that histogram.
#
# Each arm asserts nextpnr's rc, the five quantities in the packer's own
# summary line, AND which carry bits were relocated (DBG_CARRYO=1).  The bit
# list is what separates conflict from ctl_co_unused: both relocate exactly one
# sum, but at different bits, and the summary alone cannot tell them apart.
#
# A failed cd is safe here: `set -e` is deliberately absent because the rc
# bookkeeping below needs non-zero exits to be survivable, and a wrong cwd makes
# every "$v.v" missing, so the script fails red rather than green.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

NEXTPNR=${NEXTPNR:-../../../build/nextpnr-xilinx}
CHIPDB=${CHIPDB:?set CHIPDB to an xc7a35tcsg324.bin}

# design         mode   sums splits chains pinned_chains pinned_cells bits
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

    # The authoritative line, emitted once per run whenever the design has any
    # CARRY4 chain at all -- including when the pass relocates nothing, so
    # "found nothing to do" and "the pass was removed" are distinguishable.
    summary=$(sed -nE 's/^Info: +Carry-O relocation: ([0-9]+) sum\(s\) duplicated, ([0-9]+) CARRY4 split\(s\) over ([0-9]+) chain\(s\); ([0-9]+) BEL-pinned chain\(s\), ([0-9]+) BEL-pinned cell\(s\).*/\1 \2 \3 \4 \5/p' "$v.log" | tail -1)
    if [ -z "$summary" ]; then
        echo "FAIL $v: packer emitted no carry-O relocation summary (did the pass run?)"
        rc_total=1
        continue
    fi
    read -r g_sum g_split g_chain g_pchain g_pcell <<<"$summary"

    # Which bits were relocated, in ascending order; "-" when none were.
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
exit $rc_total
