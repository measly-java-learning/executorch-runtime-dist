#!/usr/bin/env bash
# Behavioural gate for the workspace-size backend option. Builds a consumer-shaped probe against a
# built prefix and runs it over an XNNPACK-delegated fixture, asserting the option reads 0 before
# any model loads and > 0 after.
#
# This is the check that protects the consumer contract on a future ET bump. The nm guard in
# build-runtime.sh proves the symbol exists; only this proves the value is reachable and real.
#
# Usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>
set -euo pipefail
PREFIX="${1:?usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>}"
FIXTURES="${2:?usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# `if`, not `[ -f ... ] && source`: under `set -e` a false `&&` list at statement level aborts the
# script, so the short form would exit before validation anywhere the toolset is absent.
if [ -f /opt/rh/gcc-toolset-14/enable ]; then
  source /opt/rh/gcc-toolset-14/enable
fi

PREFIX="$(cd "$PREFIX" && pwd)"
FIXTURES="$(cd "$FIXTURES" && pwd)"

pte="$FIXTURES/xnnpack_tiny.pte"
inbin="$FIXTURES/in.bin"
shapefile="$FIXTURES/shape"
for f in "$pte" "$inbin" "$shapefile"; do
  [ -e "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# Parsed, not sourced: `shape` is a generated fixture member, and sourcing a file to get one integer
# is a habit worth not forming.
xnn_in="$(sed -n 's/^XNN_IN=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
if [ -z "$xnn_in" ]; then
  echo "FAIL: could not read XNN_IN from $shapefile" >&2
  cat "$shapefile" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
echo "== Building workspace_probe against $PREFIX =="
gen=()
if command -v ninja >/dev/null 2>&1; then gen=(-G Ninja); fi
cmake -B "$SCRATCH/build" -S "$HERE/xnnpack_workspace" "${gen[@]}" -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$SCRATCH/build" --target workspace_probe

echo "== Running the probe =="
XNN_IN="$xnn_in" "$SCRATCH/build/workspace_probe" "$pte" "$inbin"

echo "GATE PASS: workspace_size_bytes is reachable and reports a live arena"
