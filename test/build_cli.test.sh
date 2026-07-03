#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
BR="$here/../build-runtime.sh"
assert_eq "$(bash "$BR" --print-flags --variant logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON" "print-flags logging"
assert_eq "$(bash "$BR" --print-flags --variant bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "print-flags bare"
bash "$BR" --print-flags --variant bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant exits 2"
bash "$BR" --print-flags >/dev/null 2>&1;                 assert_eq "$?" "2" "missing variant exits 2"
bash "$BR" --variant logging >/dev/null 2>&1;             assert_eq "$?" "2" "missing prefix exits 2"
bash "$BR" --variant logging --prefix /tmp/nope-prefix >/dev/null 2>&1; assert_eq "$?" "2" "missing et-src exits 2"
SKIP_ET_BUILD=1 bash "$BR" --variant logging --prefix /tmp/nope-prefix >/dev/null 2>&1; assert_eq "$?" "1" "SKIP_ET_BUILD without a valid install exits 1"
exit "$ASSERT_FAILS"
