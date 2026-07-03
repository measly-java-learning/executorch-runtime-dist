#!/usr/bin/env bash
# Package a built et-install prefix into the C2 tarball + .sha256.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"
. "$HERE/lib/variants.sh"
. "$HERE/lib/cmakeflags.sh"

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

# .et_commit is a build-cache input (read for BUILDINFO), never shipped. Fail loudly if absent —
# silently shipping et_commit=unknown would corrupt provenance.
[ -s "$PREFIX/.et_commit" ] || { echo "package.sh: $PREFIX/.et_commit missing or empty (build the runtime first)" >&2; exit 1; }
ET_COMMIT="$(cat "$PREFIX/.et_commit")"

# Stage ONLY the C2 members (deterministic) — do NOT ship whatever else the ET install happens to
# emit (bin/, share/, ...). BUILDINFO is generated into the stage below.
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$STEM"
mkdir -p "$STAGE"
for m in lib include LICENSE THIRD-PARTY-NOTICES; do
  [ -e "$PREFIX/$m" ] || { echo "package.sh: required C2 member '$m' missing from $PREFIX" >&2; exit 1; }
  cp -a "$PREFIX/$m" "$STAGE/"
done

CMAKE_FLAGS="$(variant_flags "$VARIANT") $(common_cmake_flags)"
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
