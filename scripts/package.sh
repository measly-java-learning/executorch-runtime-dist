#!/usr/bin/env bash
# Package a built et-install prefix into the C2 tarball + .sha256.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"
. "$HERE/lib/variants.sh"

PREFIX=""; ETVER=""; VARIANT=""; PLATFORM=""; PACKAGE_TAG=""; OUTDIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --etver) ETVER="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --package-tag) PACKAGE_TAG="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for v in PREFIX ETVER VARIANT PLATFORM PACKAGE_TAG; do
  [ -n "${!v}" ] || { echo "--${v,,} required" >&2; exit 2; }
done

STEM="$(asset_stem "$ETVER" "$VARIANT" "$PLATFORM")"
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$STEM"
mkdir -p "$STAGE"
cp -a "$PREFIX/." "$STAGE/"

ET_COMMIT="$(cat "$STAGE/.et_commit" 2>/dev/null || echo unknown)"
rm -f "$STAGE/.et_commit"

CMAKE_FLAGS="$(variant_flags "$VARIANT") -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="manylinux_2_28 gcc-toolset-14" PACKAGE_TAG="$PACKAGE_TAG" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(tarball_name "$ETVER" "$VARIANT" "$PLATFORM")"
tar -C "$STAGE_ROOT" -czf "$TARBALL" "$STEM"
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
