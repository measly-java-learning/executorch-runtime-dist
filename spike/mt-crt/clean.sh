#!/usr/bin/env bash
# SPIKE cleanup. Removes the state poisoned by the x86 misconfigure so a retry is actually valid.
# Deliberately NARROW: it touches only the spike build dir and flatcc's in-source output dirs. It
# prints every path before removing it, and does nothing without --yes.
#
# Why both are required:
#  - The outer build dir holds a CMakeCache.txt pinning the x86 compiler. CMake does NOT re-detect a
#    compiler once cached, so re-running configure over it silently keeps the 32-bit toolchain.
#  - flatcc builds IN-SOURCE (writes into <et-src>/third-party/flatcc/{lib,bin}), so its x86 debris
#    survives a fresh build dir and gets picked up again.
#
# Usage: clean.sh --et-src <dir> --build-dir <dir> [--yes]
set -euo pipefail
ET_SRC=""; BUILD_DIR=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --et-src)    ET_SRC="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --yes)       YES=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ET_SRC" ] && [ -n "$BUILD_DIR" ] || { echo "usage: clean.sh --et-src <dir> --build-dir <dir> [--yes]" >&2; exit 2; }

targets=("$BUILD_DIR" "$ET_SRC/third-party/flatcc/lib" "$ET_SRC/third-party/flatcc/bin")

echo "== will remove =="
for t in "${targets[@]}"; do
  if [ -e "$t" ]; then printf '  %s\n' "$t"; ls -la "$t" 2>/dev/null | sed 's/^/      /' | head -6
  else printf '  %s  <absent, skipping>\n' "$t"; fi
done

if [ "$YES" -ne 1 ]; then
  echo
  echo "Dry run only. Re-run with --yes to actually delete."
  exit 0
fi

for t in "${targets[@]}"; do
  [ -e "$t" ] || continue
  echo ">> removing $t"
  rm -rf "$t"
done

# The recipe's flatc .exe byproduct patch shows as a local modification to the ET tree; that one is
# INTENTIONAL (build-mt.sh reapplies it idempotently), so we leave it alone and just report it.
echo
echo "== ET tree local modifications (expected: only third-party/CMakeLists.txt, the flatc patch) =="
git -C "$ET_SRC" status --porcelain 2>/dev/null | sed 's/^/  /' || true
echo "CLEAN OK — safe to re-run run-all.sh"
