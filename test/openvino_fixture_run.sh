#!/usr/bin/env bash
# End-to-end gate: run the published OpenVINO fixture .pte through the ExecuTorch runtime,
# against the vendored OpenVINO runtime bundle, and compare the delegated result to the eager
# golden. Three stages, all required:
#
#   1. NEGATIVE CONTROL — run with OPENVINO_LIB_PATH unset. This MUST fail. It proves the
#      delegate is actually linked in and that the env var is load-bearing; without it the whole
#      gate could pass vacuously on a .pte that never reached OpenVINO at all.
#   2. EXECUTION — run with OPENVINO_LIB_PATH pointing into the bundle and LD_LIBRARY_PATH
#      explicitly unset, so the bundle must self-resolve via $ORIGIN exactly as a consumer's will.
#   3. CORRECTNESS — compare against the fixture's out.bin at 1e-4.
#
# Stages 1 and 2 are separate PROCESSES, which is a requirement rather than a style choice: the
# delegate resolves libopenvino_c.so behind a std::call_once with no retry, so a failed resolution
# is permanent for the life of the process.
#
# This complements test/openvino_smoke.sh, which gates the bundle at the OpenVINO C API. Neither
# subsumes the other: the smoke gate never loads a .pte, and this gate never enumerates devices.
#
# Usage: openvino_fixture_run.sh <et-prefix> <bundle-dir> <fixture-dir>
# Runs inside manylinux_2_28 against a prefix built by build-runtime.sh. Needs cmake + a compiler
# and python3 (stdlib only — the comparison deliberately does not need numpy or torch).
set -euo pipefail
PREFIX="${1:?usage: openvino_fixture_run.sh <et-prefix> <bundle-dir> <fixture-dir>}"
BUNDLE="${2:?usage: openvino_fixture_run.sh <et-prefix> <bundle-dir> <fixture-dir>}"
FIXTURES="${3:?usage: openvino_fixture_run.sh <et-prefix> <bundle-dir> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# `if`, not `[ -f ... ] && source`: under `set -e` a false `&&` list at statement level aborts the
# script, so the short form would exit 0-ish before validation anywhere the toolset is absent.
if [ -f /opt/rh/gcc-toolset-14/enable ]; then
  source /opt/rh/gcc-toolset-14/enable
fi

# Resolve to absolute paths: the runner is invoked from a build dir, and CMAKE_PREFIX_PATH must
# not be relative either.
PREFIX="$(cd "$PREFIX" && pwd)"
BUNDLE="$(cd "$BUNDLE" && pwd)"
FIXTURES="$(cd "$FIXTURES" && pwd)"

lib="$BUNDLE/lib/libopenvino_c.so"
pte="$FIXTURES/openvino_tiny.pte"
inbin="$FIXTURES/in.bin"
refbin="$FIXTURES/out.bin"
shapefile="$FIXTURES/shape"
for f in "$lib" "$pte" "$inbin" "$refbin" "$shapefile"; do
  [ -e "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# Read the dims the fixture emitter recorded. Parsed, not sourced: `shape` is a published fixture
# member, and sourcing a shipped file to get two integers is a habit worth not forming.
ov_in="$(sed -n 's/^OV_IN=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
ov_out="$(sed -n 's/^OV_OUT=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
if [ -z "$ov_in" ] || [ -z "$ov_out" ]; then
  echo "FAIL: could not read OV_IN/OV_OUT from $shapefile" >&2
  cat "$shapefile" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
echo "== Building ov_runner against $PREFIX =="
gen=()
if command -v ninja >/dev/null 2>&1; then gen=(-G Ninja); fi
cmake -B "$SCRATCH/build" -S "$HERE/openvino" "${gen[@]}" -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$SCRATCH/build" --target ov_runner
runner="$SCRATCH/build/ov_runner"

export OV_IN="$ov_in" OV_OUT="$ov_out"

echo "== Stage 1: negative control — no OPENVINO_LIB_PATH (must FAIL) =="
if env -u OPENVINO_LIB_PATH "$runner" "$pte" "$inbin" "$SCRATCH/neg.bin" 2>"$SCRATCH/neg.err"; then
  echo "FAIL: the fixture ran WITHOUT OPENVINO_LIB_PATH — it is not reaching the OpenVINO" >&2
  echo "  delegate at all, so stage 2 would pass vacuously. Check that the .pte still embeds" >&2
  echo "  OpenvinoBackend and that ov_runner links executorch_backends." >&2
  exit 1
fi
sed 's/^/  /' "$SCRATCH/neg.err" >&2 || true
echo "ok: load fails without OPENVINO_LIB_PATH, as documented"

echo "== Stage 2: execute against the bundle, LD_LIBRARY_PATH UNSET =="
env -u LD_LIBRARY_PATH OPENVINO_LIB_PATH="$lib" \
  "$runner" "$pte" "$inbin" "$SCRATCH/got.bin" || {
  echo "FAIL: the fixture failed to run against the bundle" >&2
  echo "  If the failure is at method init, suspect the bundle member list before the .pte:" >&2
  echo "  a bundle missing libopenvino_ir_frontend enumerates CPU but imports no model." >&2
  exit 1; }
echo "ok: fixture executed through the OpenVINO delegate"

echo "== Stage 3: compare delegated output to the eager golden =="
# NOTE: this feeds the fixture's own in.bin. ExecuTorch's executor_runner synthesizes its inputs
# (ones) instead of reading a file, so comparing ITS output against out.bin reports a spurious
# mismatch — the reason this gate uses a purpose-built runner.
python3 "$HERE/openvino/compare.py" "$SCRATCH/got.bin" "$refbin"

echo "GATE PASS: fixture .pte runs on the vendored bundle and matches the eager golden"
