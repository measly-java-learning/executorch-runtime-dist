#!/usr/bin/env bash
# Runtime acceptance gate for the C10 bundle. Proves the FLAT bundle self-resolves:
# dlopen by absolute path with LD_LIBRARY_PATH explicitly UNSET, then enumerate devices.
# Usage: openvino_smoke.sh <bundle-dir>
# Runs inside manylinux_2_28 (needs a C compiler); self-provisions gcc-toolset like
# test/relocatability.sh does.
set -euo pipefail
BUNDLE="${1:?usage: openvino_smoke.sh <bundle-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f /opt/rh/gcc-toolset-14/enable ] && source /opt/rh/gcc-toolset-14/enable

lib="$BUNDLE/lib/libopenvino_c.so"
[ -e "$lib" ] || { echo "FAIL: $lib missing" >&2; exit 1; }

BIN="$(mktemp -d)/devices_probe"
gcc "$HERE/openvino/devices_probe.c" -o "$BIN" -ldl

echo "== dlopen with LD_LIBRARY_PATH UNSET (proves \$ORIGIN self-resolution) =="
# `env -u` is the point of the test: if the bundle needed LD_LIBRARY_PATH, this fails.
out="$(env -u LD_LIBRARY_PATH "$BIN" "$lib")" || {
  echo "FAIL: probe exited non-zero" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"

case "$out" in
  *"DEVICE CPU"*) echo "GATE PASS: bundle self-resolves and enumerates CPU" ;;
  *) echo "FAIL: CPU device not enumerated (plugin or TBB missing from the bundle?)" >&2; exit 1 ;;
esac
