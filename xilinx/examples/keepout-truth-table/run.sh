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
NEXTPNR=$(resolve_tool "${NEXTPNR:-$HERE/../../../build/nextpnr-xilinx}")
CHIPDB=$(abspath "${CHIPDB:?set CHIPDB to an xc7a100tfgg484.bin}")
OUT=$(abspath "${OUT:-$(mktemp -d)}")
mkdir -p "$OUT" || exit 1

timeout 600 "$NEXTPNR" --chipdb "$CHIPDB" --test-keepout >"$OUT/test.log" 2>&1
rc=$?
rc_total=0
while IFS= read -r line; do
    case $line in
        *"keepout-test: PASS "*) echo "PASS ${line#*keepout-test: PASS }" ;;
        *"keepout-test: FAIL "*) echo "FAIL ${line#*keepout-test: FAIL }"; rc_total=1 ;;
    esac
done <"$OUT/test.log"
summary=$(grep -m1 'keepout-test: [0-9]* passed, [0-9]* failed' "$OUT/test.log")
if [ "$rc" -ne 0 ] || [[ $summary != *" 0 failed" ]]; then
    echo "FAIL keepout unit tests: rc $rc, summary '${summary:-none}'"
    rc_total=1
fi
echo "artefacts kept in $OUT"
exit "$rc_total"
