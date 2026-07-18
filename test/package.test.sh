#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

# Fixture mimics a REAL ET install: the C2 members PLUS bin/ and share/ that the ET install emits
# but must NOT be shipped, PLUS the .et_commit build-cache input (read, not shipped).
p="$(mktemp -d)/pfx"
mkdir -p "$p/lib/cmake/ExecuTorch" "$p/include" "$p/THIRD-PARTY-NOTICES" "$p/bin" "$p/share/cpuinfo"
: > "$p/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$p/include/et.h"
: > "$p/THIRD-PARTY-NOTICES/xnnpack_LICENSE"
: > "$p/LICENSE"
: > "$p/bin/pcre2-config"
: > "$p/share/cpuinfo/cpuinfo-config.cmake"
echo "deadbeef" > "$p/.et_commit"
echo "on" > "$p/.etnp_usdt"

out="$(mktemp -d)"
tb="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$out")"
stem="executorch-runtime-1.3.1-logging-linux-x86_64"
assert_eq "$(basename "$tb")" "$stem.tar.gz" "tarball name (C1)"
assert_eq "$([ -f "$tb.sha256" ] && echo y)" "y" "sha256 sibling exists"

members="$(tar -tzf "$tb")"
# EXACT C2 member set — catches any extra (bin/, share/) or .et_commit leaking into the tarball.
lvl2="$(printf '%s\n' "$members" | awk -F/ 'NF>=2 && $2!="" {print $2}' | LC_ALL=C sort -u | tr '\n' ',')"
assert_eq "$lvl2" "BUILDINFO,LICENSE,THIRD-PARTY-NOTICES,include,lib," "tarball contains EXACTLY the C2 members (no bin/share/.et_commit)"
assert_eq "$(cd "$out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 && echo ok)" "ok" "sha256 verifies"

# A missing .et_commit must be a HARD error (never silently ship et_commit=unknown).
p2="$(mktemp -d)/pfx2"
mkdir -p "$p2/lib/cmake/ExecuTorch" "$p2/include" "$p2/THIRD-PARTY-NOTICES"; : > "$p2/LICENSE"
bash "$here/../scripts/package.sh" --prefix "$p2" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "missing .et_commit is a hard error"

# A missing .etnp_usdt marker must also be a hard error (provenance completeness).
p3="$(mktemp -d)/pfx3"
mkdir -p "$p3/lib/cmake/ExecuTorch" "$p3/include" "$p3/THIRD-PARTY-NOTICES"; : > "$p3/LICENSE"
echo "deadbeef" > "$p3/.et_commit"   # present, so we fail specifically on .etnp_usdt
bash "$here/../scripts/package.sh" --prefix "$p3" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "missing .etnp_usdt is a hard error"

# --- provenance: --toolchain override + recorded preset (Windows-parity plumbing) ---
pw="$(mktemp -d)/pfxw"
mkdir -p "$pw/lib/cmake/ExecuTorch" "$pw/include" "$pw/THIRD-PARTY-NOTICES"
: > "$pw/lib/cmake/ExecuTorch/executorch-config.cmake"; : > "$pw/include/et.h"; : > "$pw/LICENSE"
: > "$pw/THIRD-PARTY-NOTICES/xnnpack_LICENSE"; echo deadbeef > "$pw/.et_commit"; echo "n/a" > "$pw/.etnp_usdt"
outw="$(mktemp -d)"
tbw="$(bash "$here/../scripts/package.sh" --prefix "$pw" --etver 1.3.1 --variant logging \
  --platform windows-x86_64 --package-tag v1.3.1-1 --outdir "$outw" --toolchain msvc-2022)"
bi="$(tar -xzOf "$tbw" executorch-runtime-1.3.1-logging-windows-x86_64/BUILDINFO)"
assert_contains "$bi" "toolchain=msvc-2022"                        "--toolchain override recorded"
assert_contains "$bi" "cmake_flags=-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release"     "windows flat configure base recorded (not a preset)"
assert_contains "$bi" "-DCMAKE_C_COMPILER=cl"                      "windows compiler pin recorded in provenance (C5)"
assert_contains "$bi" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"      "windows base flag recorded"
case "$bi" in *"cmake_flags="*"--preset"*) printf 'FAIL: windows provenance must not record a preset\n' >&2; exit 1 ;; esac
case "$bi" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: windows provenance must not record optimized/quantized kernels\n' >&2; exit 1 ;; esac
assert_contains "$bi" "usdt=n/a"                                   "core-only usdt sentinel recorded"
assert_contains "$bi" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL" "windows-x86_64 records the dynamic CRT in provenance (C5)"

# --- provenance: windows-x86_64-static records the STATIC CRT, distinctly from windows-x86_64 (C5) ---
outws="$(mktemp -d)"
tbws="$(bash "$here/../scripts/package.sh" --prefix "$pw" --etver 1.3.1 --variant logging \
  --platform windows-x86_64-static --package-tag v1.3.1-1 --outdir "$outws" --toolchain msvc-2022)"
bi_static="$(tar -xzOf "$tbws" executorch-runtime-1.3.1-logging-windows-x86_64-static/BUILDINFO)"
assert_contains "$bi_static" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded" "windows-x86_64-static records the static CRT in provenance (C5)"
# "MultiThreaded" is a strict PREFIX of "MultiThreadedDLL" — assert_contains alone would pass even if
# package.sh regressed to recording the dynamic CRT, so guard the substring explicitly.
case "$bi_static" in *MultiThreadedDLL*) printf 'FAIL: static provenance must not record the DLL runtime\n' >&2; exit 1 ;; esac

# Default toolchain preserved when --toolchain omitted (linux back-compat), and linux preset recorded.
outl="$(mktemp -d)"
tbl="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$outl")"
bil="$(tar -xzOf "$tbl" executorch-runtime-1.3.1-logging-linux-x86_64/BUILDINFO)"
assert_contains "$bil" "toolchain=manylinux_2_28 gcc-toolset-14" "default toolchain preserved"
assert_contains "$bil" "cmake_flags=--preset linux"              "linux preset recorded in provenance"

exit "$ASSERT_FAILS"
