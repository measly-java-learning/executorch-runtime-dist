#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
assert_eq "$(et_configure_base linux-x86_64)"  "--preset linux" "linux x86_64 -> linux preset"
assert_eq "$(et_configure_base linux-aarch64)" "--preset linux" "linux aarch64 -> linux preset"
win="$(et_configure_base windows-x86_64)"
assert_contains "$win" "-DEXECUTORCH_BUILD_XNNPACK=ON"                  "windows base enables xnnpack"
assert_contains "$win" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"          "windows base enables executor_runner"
assert_contains "$win" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "windows base enables named_data_map (EXTENSION_MODULE dep)"
# Must NOT enable the torch-header-pulling kernels, and must NOT use a preset.
case "$win" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: windows base must not enable optimized/quantized kernels\n' >&2; exit 1 ;; esac
case "$win" in *--preset*) printf 'FAIL: windows base must not use a cmake preset\n' >&2; exit 1 ;; esac
# Compiler pin (issue #10): without this, cmake's own MSVC discovery can select the Hostx86/x86
# toolchain and silently produce a 32-bit build on a workstation whose `cmake` is the VS-bundled one.
assert_contains "$win" "-DCMAKE_C_COMPILER=cl"   "windows base pins the C compiler"
assert_contains "$win" "-DCMAKE_CXX_COMPILER=cl" "windows base pins the CXX compiler"
et_configure_base bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
exit "$ASSERT_FAILS"
