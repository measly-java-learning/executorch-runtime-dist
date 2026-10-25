#!/usr/bin/env bash
# Behavioural gate for the .ptd writer. Builds the consumer project in test/ptd_writer against a
# BUILT PREFIX (installed target + headers only) and runs the round trip over a CI-minted fixture.
#
# This is the check that makes the writer a shipped feature rather than a compiled one: linking
# proves the exported target, the includes prove the headers, and the round trip proves save_ptd
# writes a file the runtime and Python both understand. It also catches the Windows text-mode
# corruption, because the two overloads are compared byte for byte.
#
# Usage: ptd_writer_run.sh <et-prefix> <fixture-dir>
set -euo pipefail
PREFIX="${1:?usage: ptd_writer_run.sh <et-prefix> <fixture-dir>}"
FIXTURES="${2:?usage: ptd_writer_run.sh <et-prefix> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# `if`, not `[ -f ... ] && source`: under `set -e` a false `&&` list at statement level aborts the
# script, so the short form would exit before validation anywhere the toolset is absent.
if [ -f /opt/rh/gcc-toolset-14/enable ]; then
  source /opt/rh/gcc-toolset-14/enable
fi

PREFIX="$(cd "$PREFIX" && pwd)"
FIXTURES="$(cd "$FIXTURES" && pwd)"

for f in linear.pte linear.ptd linear_x2.ptd in.bin out_base.bin out_x2.bin; do
  [ -e "$FIXTURES/$f" ] || { echo "FAIL: $FIXTURES/$f missing" >&2; exit 1; }
done

SCRATCH="$(mktemp -d)"
echo "== Building the .ptd writer consumer against $PREFIX =="
gen=()
if command -v ninja >/dev/null 2>&1; then gen=(-G Ninja); fi
cmake -B "$SCRATCH/build" -S "$HERE/ptd_writer" "${gen[@]}" -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$SCRATCH/build" --target ptd_roundtrip ptd_dtype_sweep

echo "== Running the round trip =="
"$SCRATCH/build/ptd_roundtrip" "$FIXTURES" "$SCRATCH/roundtrip"

echo "== Running the dtype sweep =="
"$SCRATCH/build/ptd_dtype_sweep" "$SCRATCH/dtypes"

echo "GATE PASS: .ptd writer round-trips"
