#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
BR="$here/../build-runtime.sh"
# --print-flags must print the EFFECTIVE set (configure base + variant + common), not just the
# variant flag, and must honor --platform — otherwise there is no way to inspect the CRT without a
# full build.
lin="$(bash "$BR" --print-flags --variant logging)"
assert_contains "$lin" "--preset linux"                  "print-flags: linux default includes the configure base"
assert_contains "$lin" "-DEXECUTORCH_ENABLE_LOGGING=ON"  "print-flags: includes the variant flag"
assert_contains "$lin" "-DEXECUTORCH_BUILD_XNNPACK=ON"   "print-flags: includes common flags"

bar="$(bash "$BR" --print-flags --variant bare)"
assert_contains "$bar" "-DEXECUTORCH_ENABLE_LOGGING=OFF" "print-flags bare: variant flag"

wmd="$(bash "$BR" --print-flags --variant logging --platform windows-x86_64)"
wmt="$(bash "$BR" --print-flags --variant logging --platform windows-x86_64-static)"
assert_contains "$wmd" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "print-flags: /MD platform shows the dynamic CRT"
assert_contains "$wmt" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"    "print-flags: /MT platform shows the static CRT"
case "$wmt" in *MultiThreadedDLL*) printf 'FAIL: static print-flags must not carry the DLL runtime\n' >&2; exit 1 ;; esac

# Deduped: the windows base overlaps common_cmake_flags, and a repeated flag must appear ONCE.
assert_eq "$(printf '%s\n' $wmd | grep -c -- '-DCMAKE_BUILD_TYPE=Release')" "1" "print-flags: duplicate flags collapsed"
assert_eq "$(printf '%s\n' $wmd | grep -c -- '-DEXECUTORCH_BUILD_XNNPACK=ON')" "1" "print-flags: duplicate xnnpack collapsed"

# An unknown platform must fail, not print a default set.
bash "$BR" --print-flags --variant logging --platform windows-arm64 >/dev/null 2>&1; assert_eq "$?" "2" "print-flags: unknown platform exits 2"
bash "$BR" --print-flags --variant bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant exits 2"
bash "$BR" --print-flags >/dev/null 2>&1;                 assert_eq "$?" "2" "missing variant exits 2"
bash "$BR" --variant logging >/dev/null 2>&1;             assert_eq "$?" "2" "missing prefix exits 2"
bash "$BR" --variant logging --prefix /tmp/nope-prefix >/dev/null 2>&1; assert_eq "$?" "2" "missing et-src exits 2"
SKIP_ET_BUILD=1 bash "$BR" --variant logging --prefix /tmp/nope-prefix >/dev/null 2>&1; assert_eq "$?" "1" "SKIP_ET_BUILD without a valid install exits 1"
exit "$ASSERT_FAILS"
