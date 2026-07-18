#!/usr/bin/env bash
# SPIKE (throwaway — not part of the product). De-risks the static-CRT (/MT) Windows artifact:
# does -DCMAKE_MSVC_RUNTIME_LIBRARY propagate through ET *and every third-party subproject*
# (XNNPACK, pthreadpool, cpuinfo, flatcc/flatc, pcre2, tokenizers) to yield a coherent all-/MT
# install? This is the ONE unknown that gates the whole "-static platform suffix" design.
#
# It is deliberately faithful to build-runtime.sh's configure line — it sources the SAME flag SSOT
# (scripts/lib/*.sh) and only APPENDS the CRT knob — so a clean result here previews the real build.
#
# Run inside Git-Bash from an activated VS dev shell:
#   Launch-VsDevShell.ps1 -Arch amd64 -SkipAutomaticLocation
#   "$env:ProgramFiles\Git\bin\bash.exe" spike/mt-crt/build-mt.sh --et-src C:/path/executorch --prefix C:/tmp/out-mt
#
# Usage: build-mt.sh --et-src <ET-checkout> --prefix <install-dir> [--build-dir <dir>]
#                    [--crt MultiThreaded|MultiThreadedDLL] [--variant logging]
set -euo pipefail

CRT="MultiThreaded"          # /MT (static CRT) — the thing under test. MultiThreadedDLL = /MD (today's default).
VARIANT="logging"
ET_SRC=""; PREFIX=""; BUILD_DIR=""; PYTHON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --et-src)    ET_SRC="${2:?}"; shift 2 ;;
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --crt)       CRT="${2:?}"; shift 2 ;;
    --variant)   VARIANT="${2:?}"; shift 2 ;;
    --python)    PYTHON="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ET_SRC" ] && [ -n "$PREFIX" ] || { echo "usage: build-mt.sh --et-src <dir> --prefix <dir> [--crt MultiThreaded]" >&2; exit 2; }
case "$CRT" in MultiThreaded|MultiThreadedDLL) ;; *) echo "FAIL: --crt must be MultiThreaded or MultiThreadedDLL" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# Reuse the REAL flag SSOT so the spike can't drift from the shipping recipe.
# shellcheck source=/dev/null
. "$REPO/scripts/lib/configure-base.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/lib/cmakeflags.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/lib/variants.sh"

for tool in cmake ninja cl dumpbin; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: '$tool' not on PATH — run inside an activated VS dev shell (Launch-VsDevShell.ps1 -Arch amd64)" >&2; exit 1; }
done

# --- Target-architecture guard -------------------------------------------------------------------
# We produce a windows-x86_64 artifact; a 32-bit configure must fail at second zero, not 20 minutes
# in with 54 unresolved externals. Two independent checks, because they catch different faults:
#   (a) the dev shell's own declared target arch (VsDevCmd sets VSCMD_ARG_TGT_ARCH), and
#   (b) the actual cl.exe banner — catches a shell whose PATH was reordered after activation.
if [ "${VSCMD_ARG_TGT_ARCH:-}" != "x64" ]; then
  echo "FAIL: VS dev shell target arch is '${VSCMD_ARG_TGT_ARCH:-<unset>}', expected 'x64'." >&2
  echo "      Re-activate with: Launch-VsDevShell.ps1 -Arch amd64 -HostArch amd64 -SkipAutomaticLocation" >&2
  exit 1
fi
cl 2>&1 | head -1 | grep -q 'for x64' || { echo "FAIL: cl.exe on PATH is not the x64 compiler: $(cl 2>&1 | head -1)" >&2; exit 1; }
# --------------------------------------------------------------------------------------------------

winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }
ET_BUILD="${BUILD_DIR:-$(dirname "$PREFIX")/et-build-mt-$VARIANT}"

CONFIGURE_BASE="$(et_configure_base windows-x86_64)"   # exact validated Windows flat base (minus CRT)
VARIANT_FLAGS="$(variant_flags "$VARIANT")"

# flatc_ep byproduct bug (spike finding 2): on Ninja/WIN32 the byproduct path lacks .exe. The shipping
# recipe patches third-party/CMakeLists.txt; apply the SAME idempotent sed so this standalone spike
# doesn't require build-runtime.sh to have run first.
echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — idempotent"
sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' "$ET_SRC/third-party/CMakeLists.txt" || true

# Pin cmake's Python to the interpreter that actually has torch/pyyaml (build-runtime.sh does the same
# on Windows). Prefer an EXPLICIT --python: it makes the spike independent of PATH ordering between the
# VS dev shell and any venv activation, so neither can shadow the other. Falls back to PATH `python`.
pysrc="--python"
if [ -z "$PYTHON" ]; then PYTHON="python"; pysrc="PATH"; fi
command -v "$PYTHON" >/dev/null 2>&1 || [ -x "$PYTHON" ] || { echo "FAIL: python '$PYTHON' not found — pass --python C:/path/.venv/Scripts/python.exe" >&2; exit 1; }
py="$("$PYTHON" -c 'import sys; print(sys.executable.replace(chr(92), "/"))')"
echo ">> cmake Python pinned to $py (from $pysrc)"
"$PYTHON" -c 'import yaml' 2>/dev/null || echo ">> WARNING: pyyaml not importable from $py — ET codegen (gen_oplist.py) will fail"
PYTHON_PIN="-DPYTHON_EXECUTABLE=$py -DPython_EXECUTABLE=$py -DPython3_EXECUTABLE=$py"

echo ">> Toolchain"; cmake --version | head -1; cl 2>&1 | head -1 || true; "$PYTHON" -V
echo ">> configuring ($VARIANT, windows-x86_64, CRT=$CRT)"
# CMAKE_{C,CXX}_COMPILER=cl is LOAD-BEARING, not cosmetic. Without it, cmake runs its own MSVC
# discovery instead of taking `cl` from the dev-shell PATH, and the VS-BUNDLED cmake (the one you get
# when no standalone cmake is installed, e.g. any normal VS workstation) silently defaults to the
# Hostx86/x86 toolchain -> a 32-bit configure that only explodes later inside flatcc_ep with
# "unresolved external __aulldiv / _mainCRTStartup" + LNK4272 x64-vs-x86 warnings. CI never hit this
# because the GitHub runner ships a standalone cmake that wins PATH precedence.
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$(winpath "$ET_BUILD")" -S "$(winpath "$ET_SRC")" -G Ninja $CONFIGURE_BASE \
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl \
  -DCMAKE_INSTALL_PREFIX="$(winpath "$PREFIX")" \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
  $PYTHON_PIN \
  $VARIANT_FLAGS $(common_cmake_flags)

# Post-configure assertion: prove the cache actually got the x64 toolchain. This is the regression
# test for the bug above — it fails on the broken config and passes on the fixed one, independent of
# WHICH discovery mechanism cmake used.
if grep -qi 'Hostx86/x86' "$ET_BUILD/CMakeCache.txt" 2>/dev/null; then
  echo "FAIL: configure selected the x86 toolchain despite an x64 dev shell:" >&2
  grep -i '^CMAKE_\(C\|CXX\)_COMPILER:' "$ET_BUILD/CMakeCache.txt" >&2
  echo "      Wipe the build dir and re-run; a stale cache is not re-detected." >&2
  exit 1
fi
echo ">> ok: x64 toolchain confirmed in cache"

# Belt-and-suspenders for the flatc byproduct: materialize flatc.exe first so the main build finds it
# as an existing input regardless of the byproduct-path patch above.
echo ">> pre-building flatbuffers_ep (flatc.exe)"
cmake --build "$(winpath "$ET_BUILD")" --target flatbuffers_ep || true

echo ">> building"
cmake --build "$(winpath "$ET_BUILD")" -j"${NUMBER_OF_PROCESSORS:-4}"
echo ">> installing to $PREFIX"
mkdir -p "$PREFIX"
cmake --install "$(winpath "$ET_BUILD")" --prefix "$(winpath "$PREFIX")"

echo "BUILD+INSTALL OK (CRT=$CRT). Next: spike/mt-crt/check-crt.sh \"$PREFIX\" $CRT"
