#!/usr/bin/env bash
# build-runtime.sh — ExecuTorch runtime recipe entrypoint (contract C8).
# MUST run INSIDE manylinux_2_28 (quay.io/pypa/manylinux_2_28_x86_64). The caller owns BOTH boundaries:
#   1. the container (this script never pulls/spawns one), and
#   2. the ExecuTorch source — provided as a checked-out tree (with submodules) via --et-src.
#      The recipe never clones. CI supplies it via actions/checkout; local dev mounts a checkout.
# Produces a relocatable, position-independent et-install tree at --prefix.
#
# SKIP_ET_BUILD=1 (env) reuses an existing --prefix install instead of rebuilding — mirrors the
# engine's native/build.sh Stage A knob; keyed off the install prefix, writes no marker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/variants.sh"

DEFAULT_ET_TAG="v1.3.1"
PLATFORM="linux-x86_64"          # C4; single platform for now
TORCH_SPEC="torch==2.12.0+cpu"

usage() {
  cat <<'EOF'
Usage: build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> --et-src <et-checkout>
                        [--et-tag <label>] [--build-dir <dir>]
       build-runtime.sh --print-flags --variant <variant>    # dry: print effective cmake flags, no build
Runs inside manylinux_2_28. --et-src is a checked-out ExecuTorch tree (with submodules); the recipe does not clone.
--et-tag is the version label (default v1.3.1). --build-dir is the CMake build tree (default:
<dirname of --prefix>/et-build-<variant>); it persists for inspection and incremental rebuilds — put it
on a mounted volume to inspect artifacts out of the container. Set SKIP_ET_BUILD=1 to reuse an existing --prefix install.
EOF
}

VARIANT=""; PREFIX=""; ET_SRC=""; ET_TAG="$DEFAULT_ET_TAG"; BUILD_DIR=""; PRINT_FLAGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant)   VARIANT="${2:-}"; shift 2 ;;
    --prefix)    PREFIX="${2:-}"; shift 2 ;;
    --et-src)    ET_SRC="${2:-}"; shift 2 ;;
    --et-tag)    ET_TAG="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "--variant required" >&2; exit 2; }
VARIANT_FLAGS="$(variant_flags "$VARIANT")"   # returns 2 on unknown -> set -e aborts with code 2

if [ "$PRINT_FLAGS" -eq 1 ]; then
  printf '%s\n' "$VARIANT_FLAGS"
  exit 0
fi

[ -n "$PREFIX" ] || { echo "--prefix required" >&2; exit 2; }
CONFIG="$PREFIX/lib/cmake/ExecuTorch/executorch-config.cmake"

# ---- SKIP_ET_BUILD: reuse an existing --prefix install (mirrors engine native/build.sh Stage A) ----
# Explicit opt-in; keyed off the install prefix (not the source), guarded so a stale/empty prefix
# fails fast rather than silently shipping nothing. Does not need --et-src.
if [ "${SKIP_ET_BUILD:-0}" = "1" ]; then
  test -f "$CONFIG" \
    || { echo "SKIP_ET_BUILD=1 but $CONFIG is missing; build the runtime first" >&2; exit 1; }
  echo ">> SKIP_ET_BUILD=1: reusing existing ExecuTorch install at $PREFIX"
  exit 0
fi

[ -n "$ET_SRC" ] || { echo "--et-src required" >&2; exit 2; }
[ -d "$ET_SRC" ] || { echo "--et-src '$ET_SRC' is not a directory" >&2; exit 2; }

# ---- real build ----
# Consistent, caller-controllable build tree (default sits next to --prefix, so a mounted --prefix puts
# it on the same volume — inspectable out of the container). Persisted (not deleted): retained artifacts
# allow inspection and make a non-SKIP re-run incremental via ninja.
ET_BUILD="${BUILD_DIR:-$(dirname "$PREFIX")/et-build-$VARIANT}"
mkdir -p "$ET_BUILD"

# ET 1.3.1 install bug: a few targets install to ${CMAKE_BINARY_DIR}/lib (the build dir) instead of
# ${CMAKE_INSTALL_LIBDIR}, so their .a is missing from the prefix and the exported ExecuTorchTargets
# bakes an absolute build-tree path (breaks find_package relocation). Rewrite to match sibling targets.
echo ">> patching ET install-destination bug (CMAKE_BINARY_DIR/lib -> CMAKE_INSTALL_LIBDIR)"
# `|| true`: grep exits 1 when there's nothing to match (e.g. an already-patched checkout on an
# idempotent re-run); that must not abort the recipe under `set -e`/`pipefail`.
patch_files="$(grep -rl 'DESTINATION ${CMAKE_BINARY_DIR}/lib' --include=CMakeLists.txt "$ET_SRC" || true)"
if [ -n "$patch_files" ]; then
  printf '%s\n' "$patch_files" | while read -r f; do
    echo "   patch: ${f#"$ET_SRC"/}"
    sed -i 's#DESTINATION ${CMAKE_BINARY_DIR}/lib#DESTINATION ${CMAKE_INSTALL_LIBDIR}#g' "$f"
  done
else
  echo "   (nothing to patch — source already patched)"
fi

echo ">> installing python deps"
pip install ninja
pip install -U pip setuptools wheel pyyaml
pip install "$TORCH_SPEC" --index-url https://download.pytorch.org/whl/cpu

echo ">> configuring ($VARIANT)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag string
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja --preset linux \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  $VARIANT_FLAGS \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON

echo ">> building"
cmake --build "$ET_BUILD" -j"$(nproc)"

echo ">> installing to $PREFIX"
mkdir -p "$PREFIX"
cmake --install "$ET_BUILD" --prefix "$PREFIX"

echo ">> measuring relocatability"
# capture once (`|| true`: grep exits 1 on no match, which must not abort under set -e/pipefail)
leaked="$(grep -rl "$PREFIX" "$PREFIX/lib/cmake" 2>/dev/null || true)"
if [ -n "$leaked" ]; then
  echo ">> WARNING: absolute build-prefix leaked into cmake configs; rewriting to \${PACKAGE_PREFIX_DIR}"
  printf '%s\n' "$leaked" | while read -r f; do
    sed -i "s#$PREFIX#\${PACKAGE_PREFIX_DIR}#g" "$f"
  done
fi

echo ">> license passthrough (C2)"
install -m 0644 "$ET_SRC/LICENSE" "$PREFIX/LICENSE"
mkdir -p "$PREFIX/THIRD-PARTY-NOTICES"
# guard each dir (a future ET tag may drop/rename one) so a bare `find | while` can't abort the
# recipe under set -e/pipefail with its stderr masked; `|| true` covers any residual find failure.
for d in "$ET_SRC/third-party" "$ET_SRC/backends"; do
  [ -d "$d" ] || continue
  find "$d" -iname 'LICENSE*' -type f | while read -r lf; do
    rel="${lf#"$ET_SRC"/}"
    cp "$lf" "$PREFIX/THIRD-PARTY-NOTICES/${rel//\//_}"
  done || true
done

# safe.directory='*': the checkout may be owned by a different uid than the container user (mounted
# tree / CI), which otherwise trips git's "dubious ownership" guard and blocks rev-parse.
git -c safe.directory='*' -C "$ET_SRC" rev-parse HEAD > "$PREFIX/.et_commit"
echo ">> build-runtime.sh done: $PREFIX"
