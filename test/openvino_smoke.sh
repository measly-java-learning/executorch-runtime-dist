#!/usr/bin/env bash
# Runtime acceptance gate for the C10 bundle. TWO stages, both required:
#
#   1. RESOLUTION — dlopen the bundle's libopenvino_c.so by absolute path with LD_LIBRARY_PATH
#      explicitly UNSET, then enumerate devices. Proves the flat bundle self-resolves via $ORIGIN
#      and that the CPU plugin loads.
#   2. BLOB IMPORT — deserialize a precompiled blob through ov_core_import_model, the same call
#      the ExecuTorch delegate makes when initializing a method.
#
# Stage 2 exists because stage 1 ALONE IS NOT SUFFICIENT, and that is not hypothetical: a bundle
# missing libopenvino_ir_frontend enumerates CPU perfectly and then fails every delegated .pte at
# model load with `failed to import model for device 'CPU' (status=-1)`. Device enumeration never
# touches the deserialization path. Do not weaken stage 2 to a warning.
#
# Usage: openvino_smoke.sh <bundle-dir>
# Runs inside manylinux_2_28 (needs a C compiler); self-provisions gcc-toolset like
# test/relocatability.sh does. Stage 2 additionally needs the `openvino` PYTHON package to mint a
# blob -- torch-free, and it should be the same version the bundle pins.
set -euo pipefail
BUNDLE="${1:?usage: openvino_smoke.sh <bundle-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f /opt/rh/gcc-toolset-14/enable ] && source /opt/rh/gcc-toolset-14/enable

lib="$BUNDLE/lib/libopenvino_c.so"
[ -e "$lib" ] || { echo "FAIL: $lib missing" >&2; exit 1; }

SCRATCH="$(mktemp -d)"

echo "== Stage 1: dlopen with LD_LIBRARY_PATH UNSET (proves \$ORIGIN self-resolution) =="
gcc "$HERE/openvino/devices_probe.c" -o "$SCRATCH/devices_probe" -ldl
# `env -u` is the point of the test: if the bundle needed LD_LIBRARY_PATH, this fails.
out="$(env -u LD_LIBRARY_PATH "$SCRATCH/devices_probe" "$lib")" || {
  echo "FAIL: devices probe exited non-zero" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"
case "$out" in
  *"DEVICE CPU"*) echo "ok: bundle self-resolves and enumerates CPU" ;;
  *) echo "FAIL: CPU device not enumerated (plugin or TBB missing from the bundle?)" >&2; exit 1 ;;
esac

echo "== Stage 2: import a precompiled blob (ov_core_import_model) =="
# Fail loudly rather than skipping: a silent skip here is exactly how a bundle that cannot load
# any model reaches a release with a green gate.
command -v python >/dev/null 2>&1 \
  || { echo "FAIL: python not on PATH; stage 2 needs the openvino python package" >&2; exit 1; }
python -c 'import openvino' 2>/dev/null \
  || { echo "FAIL: the 'openvino' python package is required to mint a blob for stage 2" >&2
       echo "  install the SAME version the bundle pins: pip install openvino==<OV_VERSION>" >&2
       exit 1; }

python "$HERE/openvino/make_blob.py" "$SCRATCH/smoke.blob"
gcc "$HERE/openvino/blob_probe.c" -o "$SCRATCH/blob_probe" -ldl
out2="$(env -u LD_LIBRARY_PATH "$SCRATCH/blob_probe" "$lib" "$SCRATCH/smoke.blob")" || {
  echo "FAIL: blob import failed against the bundle" >&2
  printf '%s\n' "$out2" >&2
  echo "  A bundle can enumerate CPU and still fail here — the usual cause is a missing" >&2
  echo "  libopenvino_ir_frontend, which deserializes the IR embedded in the blob." >&2
  exit 1; }
printf '%s\n' "$out2"

echo "GATE PASS: bundle self-resolves, enumerates CPU, and imports a compiled blob"
