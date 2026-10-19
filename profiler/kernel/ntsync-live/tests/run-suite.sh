#!/usr/bin/env bash
# run-suite.sh [LABEL]: ntsync-live's native suite against whatever ntsync is loaded (stock, or live-* with its current
# parameters): upstream's v7.2.11 selftest, ntsl_stress torture (5 workers) and pingpong (NTSL_ROUNDS each, default
# 10^6), then the kernel log since the start is searched for WARN, BUG, lockdep, soft-lockup and hung-task lines.
# Binaries from NTSL_TESTS (default ~/.local/opt/ntsync-live/tests, see build.sh). Exit 0 when everything passed.
# With NTSL_SELFTEST_FAILURES=FILE the selftest is not judged here: its failing tests go to FILE, and ntsync-live verify
# compares them with the stock module's (E1: the same results as stock). Upstream's v7.2.11 wake_all fails on every
# kernel (line 971 checks EXPECT_EQ(0, fd) where EXPECT_LE is meant).
set -u
dir=${NTSL_TESTS:-$HOME/.local/opt/ntsync-live/tests}
rounds=${NTSL_ROUNDS:-1000000}
label=${1:-$(cat /sys/module/ntsync/version 2>/dev/null || echo stock)}
log=$(mktemp)
n0=$(sudo -n dmesg | wc -l)
fail=0
params=$(for p in spin_ns spin_comm spin_rt; do [ -r /sys/module/ntsync/parameters/$p ] && printf '%s=%s ' $p "$(cat /sys/module/ntsync/parameters/$p)"; done)
echo "== suite: $label${params:+ ($params)}"
"$dir/ntsync_selftest" > "$log" 2>&1; rc=$?
failing=$(grep -E '^not ok' "$log" | sed 's/^not ok [0-9]* //' | sort | tr '\n' ' ')
echo "selftest: rc=$rc $(grep -E '^# Totals' "$log") failing: ${failing:-none}"
grep -E '^# .*:[0-9]+:.*Expected' "$log" | head -n 5
if [ -n "${NTSL_SELFTEST_FAILURES:-}" ]; then echo "$failing" > "$NTSL_SELFTEST_FAILURES"
elif [ "$rc" != 0 ]; then fail=1; fi
"$dir/ntsl_stress" torture 5 "$rounds" || fail=1
"$dir/ntsl_stress" pingpong "$rounds" || fail=1
new=$(sudo -n dmesg | tail -n +$((n0 + 1)) | grep -E 'WARNING|BUG|lockdep|soft lockup|hung_task|blocked for more than|ntsync')
if [ -n "$new" ]; then
    echo "kernel log:"; echo "$new" | head -n 20
    echo "$new" | grep -qE 'WARNING|BUG|lockdep|soft lockup|hung_task|blocked for more than' && fail=1
fi
rm -f "$log"
echo "== suite $label: $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
