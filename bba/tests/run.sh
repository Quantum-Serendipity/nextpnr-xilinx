#!/usr/bin/env bash
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
BBASM=${BBASM:-$HERE/../../build/bbasm}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

write_case() {
    printf '%b' "$2" >"$OUT/$1.bba"
}

write_case extra-pop "push chip\nu32 7\npop\npop\n"
write_case good "push chip\nlabel root\nref data\nu32 7\nstr \"hi\"\npop\npush data\nlabel data\nu16 513\nu8 1\nalign\npop\n"
write_case misaligned-ref "push chip\nu8 1\nlabel x\nref x\npop\n"
write_case misaligned-u32 "push chip\nu8 1\nu32 7\npop\n"
write_case missing-operand "push chip\nu32\npop\n"
write_case no-stream "u32 7\n"
write_case unbalanced-push "push chip\nu32 7\n"
write_case undefined-label "push chip\nlabel root\nref nowhere\nu32 7\npop\n"
write_case unknown-directive "push chip\nlabel root\nbogus 1\nu32 7\npop\n"
write_case unterminated-str "push chip\nstr \"open\npop\n"

rc_total=0
report() {
    echo "$1"
    case $1 in PASS*) ;; *) rc_total=1 ;; esac
}

if "$BBASM" -l "$OUT/good.bba" "$OUT/good.bin" 2>"$OUT/good.err" &&
        [ "$(od -An -tx1 -v "$OUT/good.bin" | tr -d ' \n')" = 03000000070000000200000001020100686900 ]; then
    report "PASS good: assembled to the expected bytes"
else
    report "FAIL good: rc or bytes differ: $(cat "$OUT/good.err")"
fi

expect_refusal() {
    local name=$1 want=$2
    "$BBASM" -l "$OUT/$name.bba" "$OUT/$name.bin" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [ "$rc" -eq 1 ] && grep -qF -- "$want" "$OUT/$name.err"; then
        report "PASS $name: refused with rc 1 and '$want'"
    else
        report "FAIL $name: rc $rc, stderr: $(head -c 200 "$OUT/$name.err")"
    fi
}

expect_refusal undefined-label "label 'nowhere' is referenced but never defined"
expect_refusal unknown-directive "unknown-directive.bba:3: unknown directive 'bogus'"
expect_refusal misaligned-u32 "u32 in stream 'chip' at unaligned offset 1"
expect_refusal misaligned-ref "label 'x' at unaligned offset 1"
expect_refusal unbalanced-push "ends with stream 'chip' still pushed"
expect_refusal extra-pop "extra-pop.bba:4: 'pop' with no stream pushed"
expect_refusal no-stream "no-stream.bba:1: 'u32' outside any pushed stream"
expect_refusal unterminated-str "unterminated-str.bba:2: 'str' operand has no closing"
expect_refusal missing-operand "missing-operand.bba:2: 'u32' is missing its operand"

long=$(printf 'u32 1 %0600d' 0)
printf 'push chip\n%s\npop\n' "$long" >"$OUT/long-line.bba"
"$BBASM" -l "$OUT/long-line.bba" "$OUT/long-line.bin" 2>"$OUT/long-line.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "long-line.bba:2: line longer than 510 characters" "$OUT/long-line.err"; then
    report "PASS long-line: refused with rc 1"
else
    report "FAIL long-line: rc $rc, stderr: $(head -c 200 "$OUT/long-line.err")"
fi

if [ -w /dev/full ]; then
    "$BBASM" -l "$OUT/good.bba" /dev/full 2>"$OUT/full.err"
    rc=$?
    if [ "$rc" -eq 1 ] && grep -qF "write error on '/dev/full'" "$OUT/full.err"; then
        report "PASS full: a failed write is refused with rc 1"
    else
        report "FAIL full: rc $rc, stderr: $(head -c 200 "$OUT/full.err")"
    fi
fi

exit $rc_total
