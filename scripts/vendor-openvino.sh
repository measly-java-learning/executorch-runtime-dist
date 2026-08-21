#!/usr/bin/env bash
# Assemble the C10 OpenVINO CPU runtime bundle from the Apache-2.0 PyPI wheel.
#
#   vendor-openvino.sh --out <dir> [--platform <p>] [--wheel <path>] [--hwloc-license <path>]
#
# Produces <dir>/openvino-runtime-<ovver>-<platform>/{lib,licenses,BUILDINFO} and prints that
# directory. The layout is deliberately FLAT: every wheel lib carries RPATH=$ORIGIN, so one
# directory self-resolves the whole graph (libopenvino_c -> libopenvino -> tbb; tbb dlopens
# tbbbind -> hwloc) with NO LD_LIBRARY_PATH and NO patchelf — i.e. no modification of the
# redistributed binaries.
#
# We ADD the unversioned libopenvino_c.so symlink: the wheel ships only the SONAME-versioned file,
# so ExecuTorch's default dlopen("libopenvino_c.so") would fail against a bare wheel install.
#
# The Windows path skips both: DLLs are unversioned so there is no symlink to add, and hwloc is
# folded into tbbbind_2_5.dll so there is no notice to fetch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/openvino.sh"

PLATFORM="linux-x86_64"
OUT=""; WHEEL=""; HWLOC_LICENSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)            OUT="$2"; shift 2 ;;
    --platform)       PLATFORM="$2"; shift 2 ;;
    --wheel)          WHEEL="$2"; shift 2 ;;
    --hwloc-license)  HWLOC_LICENSE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:?--out required}"
# Fail here rather than at the first missing member: an unrecognised platform has no member list,
# no wheel pin and no tag, and the errors from those would each describe a symptom.
ov_wheel_sha256 "$PLATFORM" >/dev/null || exit 2

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- obtain the wheel ----
if [ -z "$WHEEL" ]; then
  echo ">> downloading openvino==$OV_VERSION wheel" >&2
  pip download "openvino==$OV_VERSION" --no-deps --only-binary :all: \
    --python-version "${OV_WHEEL_PYTAG#cp}" --platform "$(ov_wheel_platform_tag "$PLATFORM")" \
    -d "$WORK/dl" >&2
  WHEEL="$(ls "$WORK"/dl/openvino-*.whl)"
  actual="$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  expected="$(ov_wheel_sha256 "$PLATFORM")"
  [ "$actual" = "$expected" ] || {
    echo "vendor-openvino.sh: wheel sha256 mismatch for $PLATFORM" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  }
fi
[ -f "$WHEEL" ] || { echo "vendor-openvino.sh: wheel '$WHEEL' not found" >&2; exit 1; }

# ---- obtain the hwloc notice (BSD-3-Clause; NOT bundled in the wheel) ----
# Linux only: on Windows hwloc is folded into tbbbind_2_5.dll, so there is no separate binary to
# attribute and nothing to fetch. ov_uses_hwloc is the one predicate for this, shared with
# ov_license_members so the fetch and the licence gate cannot disagree about what is expected.
if ov_uses_hwloc "$PLATFORM"; then
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
fi

# ---- extract ----
# python, not unzip: Git for Windows does not ship unzip, and this script must run on the Windows
# gate runner as well as in the manylinux container. python is already a hard dependency (pip
# download above), so this removes a dependency rather than adding one.
python -m zipfile -e "$WHEEL" "$WORK/x"
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
$(ov_lib_members "$PLATFORM")
EOF

# The wheel ships only the SONAME-versioned file, so ExecuTorch's default dlopen of the
# unversioned name would fail against a bare wheel install. Windows DLLs are unversioned, so
# there is nothing to alias.
if ov_needs_soname_symlink "$PLATFORM"; then
  ln -sfn "libopenvino_c.so.${OV_ABI}" "$BUNDLE/lib/libopenvino_c.so"
fi

lic="$WORK/x/openvino-${OV_VERSION}.dist-info/licenses"
cp -a "$lic/LICENSE" "$BUNDLE/licenses/LICENSE"
for f in runtime-third-party-programs.txt onetbb_third-party-programs.txt onednn_third-party-programs.txt; do
  [ -f "$lic/licensing/$f" ] || { echo "vendor-openvino.sh: wheel is missing license '$f'" >&2; exit 1; }
  cp -a "$lic/licensing/$f" "$BUNDLE/licenses/$f"
done
if ov_uses_hwloc "$PLATFORM"; then
  cp -a "$HWLOC_LICENSE" "$BUNDLE/licenses/hwloc-COPYING"
fi

# Hard gate: every declared license member must exist before we call this a bundle.
while read -r m; do
  [ -s "$BUNDLE/licenses/$m" ] || { echo "vendor-openvino.sh: license '$m' missing/empty" >&2; exit 1; }
done <<EOF
$(ov_license_members "$PLATFORM")
EOF

{
  echo "ov_version=$OV_VERSION"
  if ov_needs_soname_symlink "$PLATFORM"; then echo "ov_abi=$OV_ABI"; fi
  echo "platform=$PLATFORM"
  if ov_uses_hwloc "$PLATFORM"; then echo "hwloc_version=$OV_HWLOC_VERSION"; fi
  echo "source_wheel=$(basename "$WHEEL")"
  echo "source_wheel_sha256=$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  echo "build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUNDLE/BUILDINFO"

printf '%s\n' "$BUNDLE"
