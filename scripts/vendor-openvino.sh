#!/usr/bin/env bash
# Assemble the C10 OpenVINO CPU runtime bundle from the Apache-2.0 PyPI wheel.
#
#   vendor-openvino.sh --out <dir> [--wheel <path>] [--hwloc-license <path>]
#
# Produces <dir>/openvino-runtime-<ovver>-linux-x86_64/{lib,licenses,BUILDINFO} and prints that
# directory. The layout is deliberately FLAT: every wheel lib carries RPATH=$ORIGIN, so one
# directory self-resolves the whole graph (libopenvino_c -> libopenvino -> tbb; tbb dlopens
# tbbbind -> hwloc) with NO LD_LIBRARY_PATH and NO patchelf — i.e. no modification of the
# redistributed binaries.
#
# We ADD the unversioned libopenvino_c.so symlink: the wheel ships only the SONAME-versioned file,
# so ExecuTorch's default dlopen("libopenvino_c.so") would fail against a bare wheel install.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/openvino.sh"

PLATFORM="linux-x86_64"
OUT=""; WHEEL=""; HWLOC_LICENSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)            OUT="$2"; shift 2 ;;
    --wheel)          WHEEL="$2"; shift 2 ;;
    --hwloc-license)  HWLOC_LICENSE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:?--out required}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- obtain the wheel ----
if [ -z "$WHEEL" ]; then
  echo ">> downloading openvino==$OV_VERSION wheel" >&2
  pip download "openvino==$OV_VERSION" --no-deps --only-binary :all: \
    --python-version "${OV_WHEEL_PYTAG#cp}" --platform manylinux2014_x86_64 -d "$WORK/dl" >&2
  WHEEL="$(ls "$WORK"/dl/openvino-*.whl)"
  # Verify the pin only for a downloaded wheel; a caller-supplied --wheel is trusted (tests use a
  # synthetic one). A mismatch here means the pinned version was re-uploaded or we resolved wrong.
  actual="$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  [ "$actual" = "$OV_WHEEL_SHA256" ] || {
    echo "vendor-openvino.sh: wheel sha256 mismatch" >&2
    echo "  expected: $OV_WHEEL_SHA256" >&2
    echo "  actual:   $actual" >&2
    exit 1
  }
fi
[ -f "$WHEEL" ] || { echo "vendor-openvino.sh: wheel '$WHEEL' not found" >&2; exit 1; }

# ---- obtain the hwloc notice (BSD-3-Clause; NOT bundled in the wheel) ----
if [ -z "$HWLOC_LICENSE" ]; then
  HWLOC_LICENSE="$WORK/hwloc-COPYING"
  echo ">> fetching hwloc $OV_HWLOC_VERSION COPYING" >&2
  curl -fsSL "$OV_HWLOC_LICENSE_URL" -o "$HWLOC_LICENSE" || {
    echo "vendor-openvino.sh: could not fetch hwloc license from $OV_HWLOC_LICENSE_URL" >&2
    echo "  Refusing to ship libhwloc.so.15 unattributed. Supply --hwloc-license, or drop" >&2
    echo "  libtbbbind/libhwloc from ov_lib_members (losing NUMA binding) — never ship without it." >&2
    exit 1
  }
fi
[ -s "$HWLOC_LICENSE" ] || {
  echo "vendor-openvino.sh: hwloc license '$HWLOC_LICENSE' missing or empty" >&2; exit 1; }

# ---- extract ----
unzip -q "$WHEEL" -d "$WORK/x"
STEM="$(ov_asset_stem "$PLATFORM")"
BUNDLE="$OUT/$STEM"
# Idempotent: a re-run replaces any previous bundle rather than merging into it.
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/lib" "$BUNDLE/licenses"

src="$WORK/x/openvino/libs"
while read -r m; do
  [ -f "$src/$m" ] || { echo "vendor-openvino.sh: wheel is missing expected lib '$m'" >&2; exit 1; }
  cp -a "$src/$m" "$BUNDLE/lib/$m"
done <<EOF
$(ov_lib_members)
EOF

# Relative symlink so the bundle stays relocatable.
ln -sfn "libopenvino_c.so.${OV_ABI}" "$BUNDLE/lib/libopenvino_c.so"

lic="$WORK/x/openvino-${OV_VERSION}.dist-info/licenses"
cp -a "$lic/LICENSE" "$BUNDLE/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  [ -f "$lic/licensing/$f" ] || { echo "vendor-openvino.sh: wheel is missing license '$f'" >&2; exit 1; }
  cp -a "$lic/licensing/$f" "$BUNDLE/licenses/$f"
done
cp -a "$HWLOC_LICENSE" "$BUNDLE/licenses/hwloc-COPYING"

# Hard gate: every declared license member must exist before we call this a bundle.
while read -r m; do
  [ -s "$BUNDLE/licenses/$m" ] || { echo "vendor-openvino.sh: license '$m' missing/empty" >&2; exit 1; }
done <<EOF
$(ov_license_members)
EOF

cat > "$BUNDLE/BUILDINFO" <<EOF
ov_version=$OV_VERSION
ov_abi=$OV_ABI
platform=$PLATFORM
hwloc_version=$OV_HWLOC_VERSION
source_wheel=$(basename "$WHEEL")
source_wheel_sha256=$(sha256sum "$WHEEL" | cut -d' ' -f1)
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

printf '%s\n' "$BUNDLE"
