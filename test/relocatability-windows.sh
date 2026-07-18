#!/usr/bin/env bash
# Windows relocatability acceptance smoke (the go/no-go for the windows-x86_64 and
# windows-x86_64-static artifacts).
# Proves an extracted Windows prefix is relocatable: its exported lib/cmake configs carry no
# absolute build path, and a DIFFERENT-directory copy resolves via find_package(executorch) and
# LINKS under MSVC. This is the artifact-level check to run BEFORE any JVM/JNI integration — a
# failure here is unambiguously an artifact problem, not glue.
#
# Windows-specific vs the Linux sibling (test/relocatability.sh):
#   - No PIC concern. On Windows all code is position-independent; the SHARED consumer target
#     (test/consumer) is reused only because it still exercises a real link against ET's static
#     archives. The value proven here is "find_package resolves + MSVC links from a moved prefix",
#     not PIC.
#   - No gcc-toolset / no pip-installed ninja. The toolchain (cmake, ninja, cl.exe) comes from an
#     activated Visual Studio developer shell; this script verifies they are on PATH rather than
#     provisioning them.
#   - cmake paths are handed over in `cygpath -m` mixed form (C:/...), which native Windows cmake
#     accepts and which avoids backslash-escaping in -D arguments.
#
# Run inside Git-Bash from an activated VS dev shell (Launch-VsDevShell.ps1 -Arch amd64).
# Usage: relocatability-windows.sh <extracted-prefix-dir | *.tar.gz> <platform>
set -euo pipefail
# bash's ${x:?} exits 1 on a missing argument; repo convention reserves 2 for usage errors (matches
# build-runtime.sh/package.sh/gen-pin.sh), so usage is checked explicitly instead.
usage_err() { echo "usage: relocatability-windows.sh <extracted-prefix-dir | *.tar.gz> <platform>" >&2; exit 2; }
IN="${1:-}"; [ -n "$IN" ] || usage_err
PLATFORM="${2:-}"; [ -n "$PLATFORM" ] || usage_err
HERE="$(cd "$(dirname "$0")" && pwd)"

# The consumer probe MUST be built with the same CRT as the artifact. A CRT mismatch is NOT reliably
# caught at link time — measured on a real /MT prefix, a /MD probe linked cleanly against it with no
# LNK2005 and not even an LNK4098 warning. A probe that silently used the wrong CRT would therefore
# certify an artifact it never actually tested; the real hazard is at runtime (two CRTs, two heaps,
# corruption when an allocation crosses the boundary). This is exactly why the platform argument is
# REQUIRED above rather than defaulting: a silent default here would reintroduce that fail-open gap.
# The mapping lives in scripts/lib/configure-base.sh; do NOT re-derive it here.
# shellcheck source=../scripts/lib/configure-base.sh
. "$HERE/../scripts/lib/configure-base.sh"
CRT="$(crt_for_platform "$PLATFORM")" || {
  echo "FAIL: no CRT for platform '$PLATFORM'" >&2; exit 2; }
echo ">> platform under test: $PLATFORM (CRT=$CRT)"

# This gate compiles+links, so it needs the MSVC toolchain on PATH. ninja + cl.exe ship with VS and
# are only visible after Launch-VsDevShell; fail early with an actionable message if they are not.
for tool in cmake ninja cl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FAIL: '$tool' not on PATH — run inside an activated VS dev shell (Launch-VsDevShell.ps1 -Arch amd64)" >&2
    exit 1
  }
done

# cygpath -m => mixed form (drive-letter + forward slashes), the shape native cmake likes.
# Fallback to passthrough on the off chance this runs outside Git-Bash.
winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }

# Temp dirs for extraction + the moved-prefix consume; cleaned up on any exit.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Resolve the input to a prefix dir. A .tar.gz is extracted here; its single top-level dir ($STEM,
# per scripts/package.sh) is the prefix. A directory argument is used as the prefix as-is.
if [ -f "$IN" ] && [[ "$IN" == *.tar.gz ]]; then
  echo "== extracting $IN =="
  mkdir -p "$SCRATCH/extract"
  tar -C "$SCRATCH/extract" -xzf "$IN"
  # the tarball has exactly one top-level dir ($STEM, per scripts/package.sh) — that's the prefix
  SRC="$(find "$SCRATCH/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$SRC" ] || { echo "FAIL: no top-level dir inside $IN" >&2; exit 1; }
else
  SRC="$(cd "$IN" && pwd)"
fi
[ -d "$SRC/lib/cmake" ] || { echo "FAIL: '$SRC' is not an ET prefix (no lib/cmake)" >&2; exit 1; }
echo ">> prefix under test: $SRC"

echo "== Step 1: measure — no absolute build path in cmake configs =="
# A relocatable config references ${PACKAGE_PREFIX_DIR}, never a literal drive path. Grep for the
# Windows drive-absolute form of the prefix's own location: cmake writes paths in mixed form
# (C:/...), so we must compare against the SAME form — matching a backslash path against forward-
# slash config contents silently misses real leaks (the bug that made this scan inert in the build
# recipe until PREFIX was forward-slash-normalized). `|| true`: grep exits 1 on no match.
SRC_WIN="$(winpath "$SRC")"
leaked="$(grep -rn -F "$SRC_WIN" "$SRC/lib/cmake" 2>/dev/null || true)"
if [ -n "$leaked" ]; then
  echo "FAIL: absolute prefix leaked into cmake configs:" >&2
  printf '%s\n' "$leaked" >&2
  exit 1
fi
echo "ok: relocatable"

echo "== Step 2: consume from a DIFFERENT directory + link under MSVC =="
RELO="$SCRATCH/et-install"
cp -a "$SRC" "$RELO"
BUILD="$SCRATCH/consumer-build"
cmake -S "$(winpath "$HERE/consumer")" -B "$(winpath "$BUILD")" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_PREFIX_PATH="$(winpath "$RELO")"
cmake --build "$(winpath "$BUILD")"
echo "GATE PASS: $PLATFORM artifact is relocatable AND links under MSVC with CRT=$CRT"
