#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"
assert_eq "$(variant_flags bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "bare flags"
assert_eq "$(variant_flags logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON"  "logging flags"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_BUILD_DEVTOOLS=ON"     "devtools has devtools"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_EVENT_TRACER=ON" "devtools has event tracer"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_LOGGING=OFF"      "devtools logging off"
variant_flags bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant returns 2"
exit "$ASSERT_FAILS"
