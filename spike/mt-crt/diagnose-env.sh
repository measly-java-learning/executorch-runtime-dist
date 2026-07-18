#!/usr/bin/env bash
# SPIKE diagnostic (read-only). Collects the evidence needed to explain the x86-vs-x64 flatcc_ep
# failure. Changes NOTHING. Run inside the SAME Git-Bash/VS-dev-shell you used for run-all.sh —
# the whole point is to capture that environment, so a fresh shell would invalidate the answer.
#
# Usage: diagnose-env.sh [--et-src <dir>] [--build-dir <dir>]
set -uo pipefail   # NOT -e: this is a probe; every section must run even if one errors.

ET_SRC=""; BUILD_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --et-src)    ET_SRC="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

hr() { printf '\n===== %s =====\n' "$1"; }

hr "1. VS dev shell arch (AUTHORITATIVE — set by VsDevCmd.bat)"
# If TGT_ARCH is not x64, the dev shell is targeting 32-bit and that alone explains /machine:X86.
for v in VSCMD_ARG_TGT_ARCH VSCMD_ARG_HOST_ARCH VSCMD_VER VSINSTALLDIR VCINSTALLDIR Platform; do
  printf '%-22s = %s\n' "$v" "${!v:-<unset>}"
done

hr "2. Which tools are actually selected (PATH resolution)"
# Expect Hostx64\x64 for cl/link. Hostx86\x86 here is the smoking gun.
for t in cl link lib cmake ninja dumpbin; do
  printf '%-8s -> %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo '<not found>')"
done
printf '\ncl banner: '; cl 2>&1 | head -1

hr "3. Arch-relevant env vars (LIB/INCLUDE should match the target arch)"
# The failure signature was: LIB points at x64 while the compiler emitted x86.
printf 'LIB entries:\n';     printf '%s\n' "${LIB:-<unset>}"     | tr ';' '\n' | sed 's/^/  /'
printf 'LIBPATH entries:\n'; printf '%s\n' "${LIBPATH:-<unset>}" | tr ';' '\n' | sed 's/^/  /' | head -8

hr "4. OUTER ET build cache — what arch/CRT did OUR configure actually pick?"
if [ -n "$BUILD_DIR" ] && [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
  grep -E '^(CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_LINKER|CMAKE_BUILD_TYPE|CMAKE_MSVC_RUNTIME_LIBRARY|CMAKE_GENERATOR|CMAKE_GENERATOR_PLATFORM|CMAKE_SIZEOF_VOID_P):' \
    "$BUILD_DIR/CMakeCache.txt" | sed 's/^/  /'
  echo "  (CMAKE_SIZEOF_VOID_P=8 means x64; =4 means x86)"
else
  echo "  <no CMakeCache.txt — pass --build-dir C:/Users/cored/et-build-mt-logging>"
fi

hr "5. INNER flatcc_ep sub-build cache — the component that FAILED"
if [ -n "$BUILD_DIR" ] && [ -f "$BUILD_DIR/third-party/flatcc_ep/src/build/CMakeCache.txt" ]; then
  grep -E '^(CMAKE_C_COMPILER|CMAKE_LINKER|CMAKE_BUILD_TYPE|CMAKE_MSVC_RUNTIME_LIBRARY|CMAKE_GENERATOR|CMAKE_SIZEOF_VOID_P):' \
    "$BUILD_DIR/third-party/flatcc_ep/src/build/CMakeCache.txt" | sed 's/^/  /'
  echo "  ^ compare against section 4. A DIFFERENT compiler/arch here localizes the fault to the ExternalProject boundary."
else
  echo "  <not found — expected under $BUILD_DIR/third-party/flatcc_ep/src/build/>"
fi

hr "6. Is the ET SOURCE tree dirty? (flatcc builds IN-SOURCE)"
if [ -n "$ET_SRC" ]; then
  echo "-- stray flatcc artifacts in the source tree (should be empty on a clean checkout):"
  ls -la "$ET_SRC/third-party/flatcc/lib" 2>/dev/null | sed 's/^/  /' || echo "  <no lib dir>"
  ls -la "$ET_SRC/third-party/flatcc/bin" 2>/dev/null | sed 's/^/  /' || echo "  <no bin dir>"
  echo "-- git status (truncated):"
  git -C "$ET_SRC" status --porcelain 2>/dev/null | head -20 | sed 's/^/  /' || echo "  <not a git tree>"
else
  echo "  <pass --et-src C:/Users/cored/workspace/executorch>"
fi

hr "DONE"
echo "Send sections 1, 2, 4, 5 — those discriminate between the hypotheses."
