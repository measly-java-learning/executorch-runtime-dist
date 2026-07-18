#!/usr/bin/env bash
# SPIKE (throwaway) — OPTIONAL, SEPARATE QUESTION (edge 2, deferred). Near-zero-marginal-cost probe to
# run in the SAME winbox session: does clang-cl compile the optimized/quantized kernels that `cl`
# rejects? The `cl` failures were (a) C7555 designated-initializers-need-C++20 and (b) a c10 template
# overload mismatch — both the kind Clang tolerates/handles like GCC, and c10 is written against Clang.
# If this configures+builds clean, edge 2 flips from "wait for upstream" to "fixable here via clang-cl".
#
# This is NOT the CRT spike and does NOT gate the CRT design. Ignore unless you want the extra datapoint.
# NOTE: drives clang-cl on *Ninja* directly (CMAKE_*_COMPILER=clang-cl) — NOT the ET `windows` preset,
# which pins toolset ClangCL + the VS generator (the thing the original spike rejected).
#
# Run inside Git-Bash from an activated VS dev shell; clang-cl comes from VS's "C++ Clang tools" or LLVM.
# Usage: probe-clangcl-optimized.sh --et-src <ET-checkout> --build-dir <scratch-build>
set -euo pipefail
ET_SRC=""; BUILD_DIR=""; PYTHON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --et-src)    ET_SRC="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --python)    PYTHON="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ET_SRC" ] && [ -n "$BUILD_DIR" ] || { echo "usage: probe-clangcl-optimized.sh --et-src <dir> --build-dir <dir> [--python <exe>]" >&2; exit 2; }
[ -n "$PYTHON" ] || PYTHON="python"
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/scripts/lib/configure-base.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/lib/cmakeflags.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/lib/variants.sh"
command -v clang-cl >/dev/null 2>&1 || { echo "FAIL: clang-cl not on PATH (install VS 'C++ Clang tools for Windows' or LLVM)" >&2; exit 1; }
winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }
py="$("$PYTHON" -c 'import sys; print(sys.executable.replace(chr(92), "/"))')"

echo ">> configuring optimized+quantized kernels under clang-cl (Ninja)"
# shellcheck disable=SC2086
cmake -B "$(winpath "$BUILD_DIR")" -S "$(winpath "$ET_SRC")" -G Ninja \
  -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl \
  $(et_configure_base windows-x86_64) \
  -DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON \
  -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON \
  -DPYTHON_EXECUTABLE="$py" -DPython3_EXECUTABLE="$py" \
  $(variant_flags logging) $(common_cmake_flags)

echo ">> building the kernel targets that break under cl (optimized_* / quantized_*)"
if cmake --build "$(winpath "$BUILD_DIR")" -j"${NUMBER_OF_PROCESSORS:-4}"; then
  echo "CLANG-CL PROBE: PASS — optimized/quantized kernels compile under clang-cl. Edge 2 is fixable here."
else
  echo "CLANG-CL PROBE: FAIL — clang-cl also rejects them; edge 2 stays upstream. Capture the errors above." >&2
  exit 1
fi
