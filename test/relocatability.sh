#!/usr/bin/env bash
# Relocatability + PIC acceptance gate (the go/no-go). Proves a built et-install is BOTH
# relocatable (no absolute build-prefix baked into lib/cmake) AND position-independent (its static
# libs link into a SHARED library — an executable would not catch a PIC regression, a .so does).
# Runs inside manylinux_2_28. Usage: relocatability.sh <et-install-prefix>
set -euo pipefail
SRC="${1:?usage: relocatability.sh <et-install-prefix>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# This gate compiles+links, so it needs ninja and a C++ compiler. In manylinux ninja is pip-only and
# the gcc-toolset must be enabled; provision them if absent (both are no-ops outside the container).
#
# manylinux ships NO system pip — the CPython builds live under /opt/python/<tag>/bin, which is not
# on the default PATH. Every by-hand invocation in our docs prepends it, but the release workflow's
# gate step did not, so `pip install ninja` died with "pip: command not found" (rc 127) and the gate
# failed on a perfectly good prefix. Self-provision here rather than relying on the caller.
if ! command -v pip >/dev/null 2>&1; then
  for _py in /opt/python/cp312-cp312/bin /opt/python/cp3*/bin; do
    if [ -x "$_py/pip" ]; then export PATH="$_py:$PATH"; break; fi
  done
fi
command -v ninja >/dev/null 2>&1 || pip install -q ninja
[ -f /opt/rh/gcc-toolset-14/enable ] && source /opt/rh/gcc-toolset-14/enable

echo "== Step 1: measure — no absolute build-prefix in cmake configs =="
if grep -rn "$SRC" "$SRC/lib/cmake"; then
  echo "FAIL: absolute prefix leaked into cmake configs" >&2; exit 1
fi
echo "ok: relocatable"

echo "== Step 2: consume from a DIFFERENT directory + link a SHARED lib (PIC) =="
RELO="$(mktemp -d)/et-install"
cp -a "$SRC" "$RELO"
BUILD="$(mktemp -d)/consumer-build"
cmake -S "$HERE/consumer" -B "$BUILD" -G Ninja -DCMAKE_PREFIX_PATH="$RELO"
cmake --build "$BUILD"
echo "GATE PASS: relocatable AND position-independent"
