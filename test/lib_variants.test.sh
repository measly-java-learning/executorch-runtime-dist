#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"
assert_eq "$(variant_flags bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "bare flags"
assert_eq "$(variant_flags logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON"  "logging flags"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_BUILD_DEVTOOLS=ON"     "devtools has devtools"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_EVENT_TRACER=ON" "devtools has event tracer"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_LOGGING=ON"      "devtools logging on"
# Anchored, because `=ON` is a substring of nothing here but `=OFF` is not a substring of `=ON`:
# without this, a regression back to OFF would leave the assertion above failing but say nothing
# about which value replaced it.
case "$(variant_flags devtools)" in
  *-DEXECUTORCH_ENABLE_LOGGING=OFF*) printf 'FAIL: devtools must not disable logging\n' >&2
                                     ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: devtools does not disable logging\n' ;;
esac
assert_eq "$(event_tracer_for_variant bare)"     "off" "bare event_tracer off"
assert_eq "$(event_tracer_for_variant logging)"  "off" "logging event_tracer off"
assert_eq "$(event_tracer_for_variant devtools)" "on"  "devtools event_tracer on"
event_tracer_for_variant bogus >/dev/null 2>&1
assert_eq "$?" "2" "event_tracer_for_variant: unknown variant returns 2"
variant_flags bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant returns 2"
exit "$ASSERT_FAILS"
