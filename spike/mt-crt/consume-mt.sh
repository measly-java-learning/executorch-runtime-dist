#!/usr/bin/env bash
# SPIKE (throwaway). End-to-end confirmation: link the existing test/consumer SHARED probe against
# the /MT install *with a matching-/MT consumer*. If any ET static lib was really /MD, MSVC aborts the
# link with LNK4098 (defaultlib 'MSVCRT' conflicts) / LNK2005 (duplicate CRT symbols). A clean link is
# the "a JNI DLL built /MT against this artifact actually links" proof the dumpbin scan predicts.
#
# Run inside Git-Bash from an activated VS dev shell.
# Usage: consume-mt.sh <install-prefix> [MultiThreaded|MultiThreadedDLL]
set -euo pipefail
PREFIX="${1:?usage: consume-mt.sh <install-prefix> [MultiThreaded|MultiThreadedDLL]}"
CRT="${2:-MultiThreaded}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
for tool in cmake ninja cl; do command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: '$tool' not on PATH — activate a VS dev shell" >&2; exit 1; }; done
winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }

SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
echo "== linking test/consumer (SHARED) against $PREFIX with CRT=$CRT =="
cmake -S "$(winpath "$REPO/test/consumer")" -B "$(winpath "$SCRATCH/build")" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY="$CRT" \
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
  -DCMAKE_PREFIX_PATH="$(winpath "$PREFIX")"
cmake --build "$(winpath "$SCRATCH/build")"
echo "CONSUME CHECK: PASS — /$([ "$CRT" = MultiThreaded ] && echo MT || echo MD) consumer links cleanly against the artifact."
