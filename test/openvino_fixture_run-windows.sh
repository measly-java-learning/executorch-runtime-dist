#!/usr/bin/env bash
# Windows end-to-end gate -- sibling of test/openvino_fixture_run.sh. Same three stages, same
# reasoning (see that file's header for why stages 1 and 2 must be separate PROCESSES: the
# delegate resolves the runtime behind a std::call_once with no retry).
#
# Windows-specific: OPENVINO_LIB_PATH points at openvino_c.dll and MUST be absolute -- the backend
# passes it to LoadLibraryExW with LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, which is only meaningful for
# an absolute path. PATH is stripped rather than LD_LIBRARY_PATH unset.
#
# The fixture .pte is the SAME Linux-exported artifact the Linux gate uses. That is not a
# shortcut: export_model() was shown to produce byte-identical blobs on Linux and Windows across
# different CPU vendors and capability sets, which is why ov_fixtures_name has no platform axis.
#
# Usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>
# Must run under the VS dev shell via build-runtime.ps1.
set -euo pipefail
PREFIX="${1:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
BUNDLE="${2:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
FIXTURES="${3:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$(cd "$PREFIX" && pwd)"; BUNDLE="$(cd "$BUNDLE" && pwd)"; FIXTURES="$(cd "$FIXTURES" && pwd)"

lib="$BUNDLE/lib/openvino_c.dll"
pte="$FIXTURES/openvino_tiny.pte"; inbin="$FIXTURES/in.bin"; refbin="$FIXTURES/out.bin"
shapefile="$FIXTURES/shape"
for f in "$lib" "$pte" "$inbin" "$refbin" "$shapefile"; do
  [ -e "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

ov_in="$(sed -n 's/^OV_IN=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
ov_out="$(sed -n 's/^OV_OUT=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
if [ -z "$ov_in" ] || [ -z "$ov_out" ]; then
  echo "FAIL: could not read OV_IN/OV_OUT from $shapefile" >&2; cat "$shapefile" >&2; exit 1
fi

# The prefix is self-describing: package.sh records the platform it was built for in BUILDINFO,
# so the CRT is read from the artifact under test rather than passed in and possibly disagreeing
# with it. Parsed, not sourced -- BUILDINFO is a shipped file, and sourcing one to get a field is
# a habit worth not forming (same reasoning as the `shape` file in the Linux sibling).
[ -f "$PREFIX/BUILDINFO" ] || { echo "FAIL: $PREFIX/BUILDINFO missing; is this an unpacked tarball?" >&2; exit 1; }
PLATFORM="$(sed -n 's/^platform=\(.*\)$/\1/p' "$PREFIX/BUILDINFO")"
[ -n "$PLATFORM" ] || { echo "FAIL: no platform= line in $PREFIX/BUILDINFO" >&2; exit 1; }
# shellcheck source=../scripts/lib/configure-base.sh
. "$HERE/../scripts/lib/configure-base.sh"
CRT="$(crt_for_platform "$PLATFORM")" || { echo "FAIL: no CRT for platform '$PLATFORM'" >&2; exit 2; }
echo ">> prefix platform: $PLATFORM (CRT=$CRT)"

SCRATCH="$(mktemp -d)"
echo "== Building ov_runner against $PREFIX =="
# Both flags are here, and they fix DIFFERENT failures -- measured, not assumed.
#
# MSVC stamps the CRT kind and _ITERATOR_DEBUG_LEVEL into every object and the linker rejects any
# mismatch (LNK2038, then a fatal LNK1319). With neither flag, ov_runner compiled as
# /MDd_DynamicDebug against a Release prefix: 476 mismatches, headlined by an LNK4098 that reads
# like a static-vs-dynamic problem but was actually Debug-vs-Release.
#
# BUILD_TYPE=Release fixes THAT case -- and so, on its own, does the runtime flag, because either
# one stops CMake defaulting to the debug runtime. Do not conclude the other is redundant:
# against the windows-x86_64-static prefix, BUILD_TYPE=Release alone still fails with
# `MT_StaticRelease doesn't match MD_DynamicRelease`, because CMake's default runtime is the DLL
# one regardless of config. Only the crt_for_platform value makes this script correct for BOTH
# tarballs. Verified against both artifacts before this comment was written.
#
# crt_for_platform is the SSOT the build itself uses; never hardcode /MD or /MT here.
cmake -B "$SCRATCH/build" -S "$HERE/openvino" -G Ninja \
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_PREFIX_PATH="$(cygpath -m "$PREFIX")"
cmake --build "$SCRATCH/build" --target ov_runner
runner="$SCRATCH/build/ov_runner.exe"

export OV_IN="$ov_in" OV_OUT="$ov_out"
minpath="$(cygpath -w "$SYSTEMROOT")\\System32;$(cygpath -w "$SYSTEMROOT")"

echo "== Stage 1: negative control -- no OPENVINO_LIB_PATH (must FAIL) =="
if env -u OPENVINO_LIB_PATH PATH="$minpath" "$runner" "$pte" "$inbin" "$SCRATCH/neg.bin" \
     2>"$SCRATCH/neg.err"; then
  echo "FAIL: the fixture ran WITHOUT OPENVINO_LIB_PATH -- it is not reaching the OpenVINO" >&2
  echo "  delegate at all, so stage 2 would pass vacuously." >&2
  exit 1
fi
sed 's/^/  /' "$SCRATCH/neg.err" >&2 || true
echo "ok: load fails without OPENVINO_LIB_PATH, as documented"

echo "== Stage 2: execute against the bundle, PATH stripped =="
PATH="$minpath" OPENVINO_LIB_PATH="$(cygpath -w "$lib")" \
  "$runner" "$pte" "$inbin" "$SCRATCH/got.bin" || {
  echo "FAIL: the fixture failed to run against the bundle" >&2
  echo "  If the failure is at method init, suspect the bundle member list before the .pte:" >&2
  echo "  a bundle missing openvino_ir_frontend.dll enumerates CPU but imports no model." >&2
  echo "  Error 126 with everything present means a MISSING DEPENDENCY -- most often the MSVC" >&2
  echo "  redistributable, which the wheel's /MD DLLs import from System32." >&2
  exit 1; }
echo "ok: fixture executed through the OpenVINO delegate"

echo "== Stage 3: compare delegated output to the eager golden =="
# Same 1e-2 tolerance and same reasoning as the Linux gate: OpenVINO picks inference precision
# from the CPU it lands on, and the runner pool is mixed. See openvino_fixture_run.sh.
python3 "$HERE/openvino/compare.py" "$SCRATCH/got.bin" "$refbin" 1e-2

echo "GATE PASS: fixture .pte runs on the vendored Windows bundle and matches the eager golden"
