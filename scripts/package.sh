#!/usr/bin/env bash
# Package a built et-install prefix into the C2 tarball + .sha256.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"
. "$HERE/lib/variants.sh"
. "$HERE/lib/cmakeflags.sh"
. "$HERE/lib/openvino.sh"
. "$HERE/lib/configure-base.sh"

PREFIX=""; ETVER=""; VARIANT=""; PLATFORM=""; PACKAGE_TAG=""; OUTDIR="."; TOOLCHAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --etver) ETVER="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --package-tag) PACKAGE_TAG="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --toolchain) TOOLCHAIN="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for v in PREFIX ETVER VARIANT PLATFORM PACKAGE_TAG; do
  [ -n "${!v}" ] || { echo "--${v,,} required" >&2; exit 2; }
done
: "${TOOLCHAIN:=manylinux_2_28 gcc-toolset-14}"

STEM="$(asset_stem "$ETVER" "$VARIANT" "$PLATFORM")"

# .et_commit is a build-cache input (read for BUILDINFO), never shipped. Fail loudly if absent —
# silently shipping et_commit=unknown would corrupt provenance.
[ -s "$PREFIX/.et_commit" ] || { echo "package.sh: $PREFIX/.et_commit missing or empty (build the runtime first)" >&2; exit 1; }
ET_COMMIT="$(cat "$PREFIX/.et_commit")"

# .etnp_usdt: written by the extras install (on|off); read for BUILDINFO, never shipped.
[ -s "$PREFIX/.etnp_usdt" ] || { echo "package.sh: $PREFIX/.etnp_usdt missing or empty (build the extras first)" >&2; exit 1; }
USDT_STATE="$(cat "$PREFIX/.etnp_usdt")"

# Stage ONLY the C2 members (deterministic) — do NOT ship whatever else the ET install happens to
# emit (bin/, share/, ...). BUILDINFO is generated into the stage below.
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$STEM"
mkdir -p "$STAGE"
for m in lib include LICENSE THIRD-PARTY-NOTICES; do
  [ -e "$PREFIX/$m" ] || { echo "package.sh: required C2 member '$m' missing from $PREFIX" >&2; exit 1; }
  cp -a "$PREFIX/$m" "$STAGE/"
done

# OpenVINO provenance. Do NOT infer this from the platform string alone: if the delegate ever stops
# being compiled in (upstream renames the option — cmake only WARNS about an unused -D cache var),
# the flag silently no-ops, `executorch_backends` quietly omits openvino_backend, the PIC gate still
# passes, and we would ship a tarball whose BUILDINFO claims a delegate it does not contain. Assert
# on the archive itself; the platform predicate lives in lib/openvino.sh so it cannot drift from the
# one cmakeflags.sh uses to set the flag.
if ov_enabled_for_platform "$PLATFORM"; then
  [ -f "$PREFIX/lib/libopenvino_backend.a" ] || {
    echo "package.sh: platform '$PLATFORM' enables OpenVINO but $PREFIX/lib/libopenvino_backend.a" >&2
    echo "  is missing — the delegate was not built. Refusing to record openvino_version for a" >&2
    echo "  tarball that does not contain it." >&2
    exit 1; }
  OPENVINO_VERSION="$OV_VERSION"
else
  OPENVINO_VERSION="n/a"
fi

CMAKE_FLAGS="$(effective_cmake_flags "$PLATFORM" "$VARIANT")"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="$TOOLCHAIN" PACKAGE_TAG="$PACKAGE_TAG" \
  USDT="$USDT_STATE" \
  OPENVINO_VERSION="$OPENVINO_VERSION" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(tarball_name "$ETVER" "$VARIANT" "$PLATFORM")"
tar -C "$STAGE_ROOT" -czf "$TARBALL" "$STEM"
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
