#!/usr/bin/env bash
# Windows runtime acceptance gate for the C10 bundle -- sibling of test/openvino_smoke.sh.
#
# Windows-specific vs the Linux sibling:
#   - ONE probe binary, not two. win_origin_probe.c does resolve + enumerate + blob import in a
#     single process, so there is no separate devices_probe/blob_probe split.
#   - THREE cells, not two. The extra one is a NEGATIVE CONTROL that the Linux gate has no
#     equivalent of: Linux self-resolves via RPATH=$ORIGIN, which either works or does not, while
#     Windows will happily satisfy a load from PATH, the app directory or System32. Without the
#     `plain` cell a passing `dllload` cell could just mean some other OpenVINO was found, and the
#     gate would be measuring the runner's installed software rather than our bundle.
#   - No `env -u LD_LIBRARY_PATH`. The Windows analogue is stripping PATH, done below.
#
# Usage: openvino_smoke-windows.sh <bundle-dir>
# Must run under the VS dev shell: pwsh -File build-runtime.ps1 test/openvino_smoke-windows.sh <dir>
set -euo pipefail
BUNDLE="${1:?usage: openvino_smoke-windows.sh <bundle-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$BUNDLE" && pwd)"

lib="$BUNDLE/lib/openvino_c.dll"
[ -f "$lib" ] || { echo "FAIL: $lib missing" >&2; exit 1; }

command -v cl >/dev/null 2>&1 \
  || { echo "FAIL: cl not on PATH -- run me through build-runtime.ps1" >&2; exit 1; }
command -v python >/dev/null 2>&1 \
  || { echo "FAIL: python not on PATH; the blob cell needs the openvino python package" >&2; exit 1; }
python -c 'import openvino' 2>/dev/null \
  || { echo "FAIL: the 'openvino' python package is required to mint a blob" >&2
       echo "  install the SAME version the bundle pins: pip install openvino==<OV_VERSION>" >&2
       exit 1; }

SCRATCH="$(mktemp -d)"
python "$HERE/openvino/make_blob.py" "$SCRATCH/smoke.blob"

# Build in the scratch dir, NOT the bundle dir: LOAD_LIBRARY_SEARCH_DEFAULT_DIRS includes the
# application directory, so an exe sitting next to the DLLs would satisfy the negative control
# from its own directory and make the control vacuous.
( cd "$SCRATCH" && cl /nologo /W3 /O2 /D_CRT_SECURE_NO_WARNINGS \
    "$(cygpath -w "$HERE/openvino/win_origin_probe.c")" \
    /Fe:probe.exe psapi.lib >/dev/null )
probe="$SCRATCH/probe.exe"

winbundle="$(cygpath -w "$lib")"
winblob="$(cygpath -w "$SCRATCH/smoke.blob")"

# Strip PATH to the system directories for every cell. This is the Windows analogue of the Linux
# gate's `env -u LD_LIBRARY_PATH`, and it is what makes the negative control meaningful.
minpath="$(cygpath -w "$SYSTEMROOT")\\System32;$(cygpath -w "$SYSTEMROOT")"

echo "== Cell 1: NEGATIVE CONTROL -- plain LoadLibraryW (must FAIL) =="
if PATH="$minpath" "$probe" plain "$winbundle" "$winblob"; then
  echo "FAIL: the bundle loaded WITHOUT the search flags. Something else on this machine is" >&2
  echo "  satisfying the dependency graph (PATH, the app dir, or System32), so cell 2 would" >&2
  echo "  pass vacuously and prove nothing about the flat bundle." >&2
  exit 1
fi
echo "ok: plain load fails, as it must without \$ORIGIN"

echo "== Cell 2: resolve + enumerate + import via LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR =="
out="$(PATH="$minpath" "$probe" dllload "$winbundle" "$winblob")" || {
  echo "FAIL: the bundle did not fully load" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"
case "$out" in
  *"DEVICE CPU"*) ;;
  *) echo "FAIL: CPU device not enumerated (plugin or TBB missing from the bundle?)" >&2; exit 1 ;;
esac
case "$out" in
  *"IMPORT OK"*) ;;
  *) echo "FAIL: blob import failed. A bundle can enumerate CPU and still fail here -- the usual" >&2
     echo "  cause is a missing openvino_ir_frontend.dll, which deserializes the IR in the blob." >&2
     exit 1 ;;
esac
case "$out" in
  *OUTSIDE*) echo "FAIL: a module resolved from OUTSIDE the bundle; the gate measured the" >&2
             echo "  runner's installed OpenVINO, not ours." >&2; exit 1 ;;
  *) ;;
esac

echo "GATE PASS: flat bundle self-resolves, enumerates CPU, and imports a compiled blob"
