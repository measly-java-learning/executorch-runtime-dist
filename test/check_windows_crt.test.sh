#!/usr/bin/env bash
# Hermetic tests for scripts/check-windows-crt.sh. No dumpbin/MSVC available on this machine, so this
# only exercises the argument-validation paths that run before the dumpbin lookup — it cannot
# exercise the actual /DEFAULTLIB scan (that needs Windows CI, see test/relocatability-windows.sh).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
script="$here/../scripts/check-windows-crt.sh"

# A bad CRT value must exit 2 (repo usage-error convention) — this check runs BEFORE the dumpbin
# lookup, so it is reachable on a machine with no dumpbin on PATH.
out="$(bash "$script" "$(mktemp -d)" NotARealCrt 2>&1)"; rc=$?
assert_eq "$rc" "2" "bad CRT value exits 2"
assert_contains "$out" "CRT must be MultiThreaded or MultiThreadedDLL" "bad CRT value reports actionable error"

# Missing argument(s) must exit 2 (usage error), not bash's default 1 from a bare \${x:?}.
bash "$script" >/dev/null 2>&1; assert_eq "$?" "2" "no arguments exits 2"
bash "$script" "$(mktemp -d)" >/dev/null 2>&1; assert_eq "$?" "2" "missing CRT argument exits 2"

# A valid CRT value against a missing/invalid prefix must exit non-zero. On this machine dumpbin is
# never on PATH, so this actually fails at the environment guard (rc=1) rather than the prefix check
# — either way, a bogus/missing prefix must never report success.
bash "$script" /no/such/prefix MultiThreaded >/dev/null 2>&1; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo y)" "y" "invalid prefix exits non-zero (rc=$rc)"

exit "$ASSERT_FAILS"
