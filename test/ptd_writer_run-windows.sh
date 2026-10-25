#!/usr/bin/env bash
# Windows end-to-end gate -- sibling of test/ptd_writer_run.sh. Same stages: build the consumer
# against the INSTALLED prefix, then run the round trip and the dtype sweep.
#
# Windows-specific: the prefix is self-describing (BUILDINFO carries platform=), so the CRT is read
# from the artifact under test via crt_for_platform rather than passed in and possibly disagreeing
# with it. Both flags below fix DIFFERENT failures -- see openvino_fixture_run-windows.sh for the
# measured reasoning; keep them in step:
#   CMAKE_BUILD_TYPE=Release       stops CMake defaulting to the debug runtime
#   CMAKE_MSVC_RUNTIME_LIBRARY     makes the DLL (/MD) and static (/MT) tarballs both correct
#
# This is also the only gate that can catch the text-mode .ptd corruption: the two overloads are
# compared byte for byte, and MSVC's text mode rewrites every 0x0A.
#
# Usage: ptd_writer_run-windows.sh <et-prefix> <fixture-dir>
# Must run under the VS dev shell via build-runtime.ps1.
set -euo pipefail
PREFIX="${1:?usage: ptd_writer_run-windows.sh <et-prefix> <fixture-dir>}"
FIXTURES="${2:?usage: ptd_writer_run-windows.sh <et-prefix> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v cygpath >/dev/null 2>&1 \
  || { echo "FAIL: cygpath not on PATH -- run me under Git-Bash via build-runtime.ps1" >&2; exit 1; }
PREFIX="$(cd "$PREFIX" && pwd)"
FIXTURES="$(cd "$FIXTURES" && pwd)"

for f in linear.pte linear.ptd linear_x2.ptd in.bin out_base.bin out_x2.bin; do
  [ -e "$FIXTURES/$f" ] || { echo "FAIL: $FIXTURES/$f missing" >&2; exit 1; }
done

[ -f "$PREFIX/BUILDINFO" ] \
  || { echo "FAIL: $PREFIX/BUILDINFO missing; is this an unpacked tarball?" >&2; exit 1; }
PLATFORM="$(sed -n 's/^platform=\(.*\)$/\1/p' "$PREFIX/BUILDINFO")"
[ -n "$PLATFORM" ] || { echo "FAIL: no platform= line in $PREFIX/BUILDINFO" >&2; exit 1; }
# shellcheck source=../scripts/lib/configure-base.sh
. "$HERE/../scripts/lib/configure-base.sh"
CRT="$(crt_for_platform "$PLATFORM")" || { echo "FAIL: no CRT for platform '$PLATFORM'" >&2; exit 2; }
echo ">> prefix platform: $PLATFORM (CRT=$CRT)"

SCRATCH="$(mktemp -d)"
echo "== Building the .ptd writer consumer against $PREFIX =="
cmake -B "$SCRATCH/build" -S "$HERE/ptd_writer" -G Ninja \
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_PREFIX_PATH="$(cygpath -m "$PREFIX")"
cmake --build "$SCRATCH/build" --target ptd_roundtrip ptd_dtype_sweep

# Convert before use: the executables are MSVC binaries, so every path argument is a Windows path.
fixtures_win="$(cygpath -w "$FIXTURES")"
roundtrip_out="$(cygpath -w "$SCRATCH/roundtrip")"
dtypes_out="$(cygpath -w "$SCRATCH/dtypes")"

echo "== Running the round trip =="
"$SCRATCH/build/ptd_roundtrip.exe" "$fixtures_win" "$roundtrip_out"

echo "== Running the dtype sweep =="
"$SCRATCH/build/ptd_dtype_sweep.exe" "$dtypes_out"

echo "GATE PASS: .ptd writer round-trips"
