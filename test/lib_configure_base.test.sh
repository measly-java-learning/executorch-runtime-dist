#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
assert_eq "$(et_configure_base linux-x86_64)"  "--preset linux" "linux x86_64 -> linux preset"
assert_eq "$(et_configure_base linux-aarch64)" "--preset linux" "linux aarch64 -> linux preset"
# --- crt_for_platform: the ONE platform -> CRT mapping. Tasks 5/6 consume this; nothing re-derives it.
assert_eq "$(crt_for_platform windows-x86_64)"        "MultiThreadedDLL" "windows-x86_64 -> dynamic CRT"
assert_eq "$(crt_for_platform windows-x86_64-static)" "MultiThreaded"    "windows-x86_64-static -> static CRT"
crt_for_platform linux-x86_64 >/dev/null 2>&1; assert_eq "$?" "2" "non-windows platform has no CRT -> 2"
crt_for_platform windows-arm64 >/dev/null 2>&1; assert_eq "$?" "2" "unknown windows platform -> 2 (never a silent default)"

# --- Both Windows platforms share one flag set and differ ONLY in the CRT.
win="$(et_configure_base windows-x86_64)"
winst="$(et_configure_base windows-x86_64-static)"

for base_desc in "dynamic:$win" "static:$winst"; do
  desc="${base_desc%%:*}"; base="${base_desc#*:}"
  assert_contains "$base" "-DEXECUTORCH_BUILD_XNNPACK=ON"                  "$desc windows base enables xnnpack"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"          "$desc windows base enables executor_runner"
  assert_contains "$base" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "$desc windows base enables named_data_map (EXTENSION_MODULE dep)"
  assert_contains "$base" "-DCMAKE_C_COMPILER=cl"                          "$desc windows base pins the C compiler"
  assert_contains "$base" "-DCMAKE_CXX_COMPILER=cl"                        "$desc windows base pins the CXX compiler"
  case "$base" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: %s windows base must not enable optimized/quantized kernels\n' "$desc" >&2; exit 1 ;; esac
  case "$base" in *--preset*) printf 'FAIL: %s windows base must not use a cmake preset\n' "$desc" >&2; exit 1 ;; esac
  case "$base" in *CMP0091*) printf 'FAIL: %s windows base must not set CMP0091\n' "$desc" >&2; exit 1 ;; esac
done

assert_contains "$win"   "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "windows-x86_64 uses the dynamic CRT (/MD)"
assert_contains "$winst" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"    "windows-x86_64-static uses the static CRT (/MT)"
# assert_contains is a substring test and "MultiThreaded" is a PREFIX of "MultiThreadedDLL", so the
# static assertion above would also pass on a /MD base. This guard is what makes it meaningful.
case "$winst" in *MultiThreadedDLL*) printf 'FAIL: static base must not carry the DLL runtime\n' >&2; exit 1 ;; esac

# Strip each platform's OWN CRT flag, then assert the remainder is byte-identical, so the two bases
# can never drift in any other flag.
# ORDER MATTERS — do NOT factor these into one shared pattern. "MultiThreaded" is a strict prefix of
# "MultiThreadedDLL", so stripping the SHORT pattern from $win would match inside the long flag and
# leave a stray "DLL" behind ("COMMON DLL" vs "COMMON "). Each variable must be stripped with its
# own exact, full flag string.
assert_eq "${win/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL/}" \
          "${winst/-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded/}" \
          "windows platforms differ ONLY in the CRT flag"

et_configure_base bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
exit "$ASSERT_FAILS"
