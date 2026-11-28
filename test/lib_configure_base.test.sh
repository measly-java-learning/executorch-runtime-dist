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

# --- macOS: flat list, Linux feature parity, Apple target from the SSOT.
assert_eq "$(macos_deployment_target macos-arm64)" "14.0"  "macos-arm64 -> minimum macOS 14.0"
assert_eq "$(macos_arch macos-arm64)"              "arm64" "macos-arm64 -> arm64"
macos_deployment_target macos-x86_64 >/dev/null 2>&1; assert_eq "$?" "2" "unknown macos platform has no deployment target -> 2"
macos_arch linux-x86_64 >/dev/null 2>&1;              assert_eq "$?" "2" "non-macos platform has no macos arch -> 2"

mac="$(et_configure_base macos-arm64)"
# Every feature the Linux preset enables is enabled on macOS: the parity promise (spec §2).
for f in $_ET_LINUX_PARITY_FEATURES; do
  assert_contains "$mac" "-DEXECUTORCH_BUILD_$f=ON" "macos base enables Linux-parity feature $f"
done
# The parity list itself must not quietly lose the features that make the build what it is. These
# are the ones that distinguish it from the Windows feature set, so pin them by name.
for f in XNNPACK KERNELS_OPTIMIZED KERNELS_QUANTIZED KERNELS_LLM EXTENSION_MODULE EXTENSION_FLAT_TENSOR EXTENSION_NAMED_DATA_MAP; do
  case " $_ET_LINUX_PARITY_FEATURES " in *" $f "*) printf 'ok: parity list includes %s\n' "$f" ;;
    *) printf 'FAIL: parity list lost %s\n' "$f" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
done
for f in COREML MLX KERNELS_TORCHAO; do
  assert_contains "$mac" "-DEXECUTORCH_BUILD_$f=OFF" "macos base pins Darwin-only $f OFF"
done
assert_contains "$mac" "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0" "macos base sets the deployment target from the SSOT"
assert_contains "$mac" "-DCMAKE_OSX_ARCHITECTURES=arm64"    "macos base sets the architecture from the SSOT"
assert_contains "$mac" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "macos base is PIC"
assert_contains "$mac" "-DCMAKE_BUILD_TYPE=Release"          "macos base is Release"
case "$mac" in *--preset*)        printf 'FAIL: macos base must not use a cmake preset\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
case "$mac" in *TOOLCHAIN_FILE*)  printf 'FAIL: macos base must not use the ios-cmake toolchain\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
# The event tracer is a VARIANT decision (devtools only); the base must never carry it.
case "$mac" in *EVENT_TRACER*)    printf 'FAIL: macos base must not touch the event tracer\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
case "$mac" in *MSVC*|*=cl\ *)    printf 'FAIL: macos base must not carry Windows flags\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
et_configure_base macos-x86_64 >/dev/null 2>&1; assert_eq "$?" "2" "unknown macos platform returns 2 (no silent arm64 build)"

# --- extras_cmake_flags: the extras phase gets the SAME Apple target as the ET build (spike finding 1).
assert_eq "$(extras_cmake_flags macos-arm64)" \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$(macos_deployment_target macos-arm64) -DCMAKE_OSX_ARCHITECTURES=$(macos_arch macos-arm64)" \
  "macos extras get the SSOT deployment target and arch"
case "$mac" in *"$(extras_cmake_flags macos-arm64)"*) printf 'ok: extras target flags are the ones the ET base uses\n' ;;
  *) printf 'FAIL: extras target flags differ from the ET base\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
for p in linux-x86_64 linux-aarch64 windows-x86_64 windows-x86_64-static; do
  assert_eq "$(extras_cmake_flags "$p")" "" "$p extras get no extra flags"
done
extras_cmake_flags bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "extras_cmake_flags: unknown platform returns 2"
extras_cmake_flags macos-x86_64 >/dev/null 2>&1; assert_eq "$?" "2" "extras_cmake_flags: unknown macos platform returns 2"

# --- platform_os / platform_matches_host: no building one OS's platform on another.
assert_eq "$(platform_os linux-aarch64)"         "linux"   "platform_os: linux"
assert_eq "$(platform_os macos-arm64)"           "macos"   "platform_os: macos"
assert_eq "$(platform_os windows-x86_64-static)" "windows" "platform_os: windows flavor"
platform_os bogus >/dev/null 2>&1; assert_eq "$?" "2" "platform_os: unknown platform returns 2"
for pair in linux-x86_64:linux linux-aarch64:linux macos-arm64:macos windows-x86_64:windows windows-x86_64-static:windows; do
  platform_matches_host "${pair%%:*}" "${pair#*:}" 2>/dev/null
  assert_eq "$?" "0" "platform_matches_host: ${pair%%:*} builds on ${pair#*:}"
done
msg="$(platform_matches_host linux-x86_64 macos 2>&1)"; rc=$?
assert_eq "$rc" "2" "platform_matches_host: the linux default on a Mac fails with 2"
assert_contains "$msg" "--platform macos-arm64" "mismatch message names the fix"
platform_matches_host macos-arm64 linux >/dev/null 2>&1;   assert_eq "$?" "2" "platform_matches_host: macos on linux fails"
platform_matches_host windows-x86_64 macos >/dev/null 2>&1; assert_eq "$?" "2" "platform_matches_host: windows on macos fails"
platform_matches_host bogus linux >/dev/null 2>&1;         assert_eq "$?" "2" "platform_matches_host: unknown platform fails"

et_configure_base bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
exit "$ASSERT_FAILS"
