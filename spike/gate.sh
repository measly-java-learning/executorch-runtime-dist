#!/usr/bin/env bash
# Relocatability + PIC gate. Go/no-go for the whole repo.
# Usage: gate.sh <et-install-prefix>
set -euo pipefail
SRC="${1:?usage: gate.sh <prefix>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== Step 1: measure — no absolute build-prefix in cmake configs =="
if grep -rn "$SRC" "$SRC/lib/cmake"; then
  echo "FAIL: absolute prefix leaked into cmake configs" >&2; exit 1
fi
echo "ok: relocatable"

echo "== Step 3: consume from a DIFFERENT directory + link a SHARED lib (PIC) =="
RELO="$(mktemp -d)/et-install"
cp -a "$SRC" "$RELO"
BUILD="$(mktemp -d)/consumer-build"
cmake -S "$HERE/consumer" -B "$BUILD" -G Ninja -DCMAKE_PREFIX_PATH="$RELO"
cmake --build "$BUILD"
echo "GATE PASS: relocatable AND position-independent"
