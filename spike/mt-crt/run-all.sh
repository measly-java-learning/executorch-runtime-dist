#!/usr/bin/env bash
# SPIKE (throwaway) orchestrator: build (/MT) -> CRT directive scan -> matching-/MT consumer link.
# Prints a single GO / NO-GO verdict for the static-CRT ("-static" platform suffix) design.
#
# Run inside Git-Bash from an activated VS dev shell (Launch-VsDevShell.ps1 -Arch amd64).
# Usage: run-all.sh --et-src <ET-checkout> --prefix <install-dir> [--build-dir <dir>] [--crt MultiThreaded]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CRT="MultiThreaded"; ET_SRC=""; PREFIX=""; BUILD_DIR=""; PYTHON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --et-src)    ET_SRC="${2:?}"; shift 2 ;;
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --crt)       CRT="${2:?}"; shift 2 ;;
    --python)    PYTHON="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ET_SRC" ] && [ -n "$PREFIX" ] || { echo "usage: run-all.sh --et-src <dir> --prefix <dir> [--crt MultiThreaded] [--python <exe>]" >&2; exit 2; }

bd=(); [ -n "$BUILD_DIR" ] && bd=(--build-dir "$BUILD_DIR")
pyarg=(); [ -n "$PYTHON" ] && pyarg=(--python "$PYTHON")
"$HERE/build-mt.sh"   --et-src "$ET_SRC" --prefix "$PREFIX" --crt "$CRT" "${bd[@]}" "${pyarg[@]}"
"$HERE/check-crt.sh"  "$PREFIX" "$CRT"
"$HERE/consume-mt.sh" "$PREFIX" "$CRT"
echo
echo "==================================================================="
echo " GO: static-CRT ($CRT) build is coherent and links. The '-static'"
echo " platform-suffix design is viable — proceed to the spec."
echo "==================================================================="
