#!/usr/bin/env bash
# build-runtime.sh — ExecuTorch runtime recipe entrypoint.
# MUST run INSIDE manylinux_2_28 (quay.io/pypa/manylinux_2_28_x86_64). The caller owns BOTH boundaries:
#   1. the container (this script never pulls/spawns one), and
#   2. the ExecuTorch source — provided as a checked-out tree (with submodules) via --et-src.
#      The recipe never clones. CI supplies it via actions/checkout; local dev mounts a checkout.
# Produces a relocatable, position-independent et-install tree at --prefix.
#
# SKIP_ET_BUILD=1 (env) reuses an existing --prefix install instead of rebuilding
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/variants.sh"
. "$HERE/scripts/lib/cmakeflags.sh"
. "$HERE/scripts/lib/configure-base.sh"

# As we run as root inside a container, set this flag to avoid log spam
export PIP_ROOT_USER_ACTION=ignore
DEFAULT_ET_TAG="v1.3.1"
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

VARIANT=""; PREFIX=""; ET_SRC=""; ET_TAG="$DEFAULT_ET_TAG"; BUILD_DIR=""; PRINT_FLAGS=0; PLATFORM="linux-x86_64"
EXTRAS_ONLY=0; PRINT_ET_TAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant)   VARIANT="${2:-}"; shift 2 ;;
    --prefix)    PREFIX="${2:-}"; shift 2 ;;
    --et-src)    ET_SRC="${2:-}"; shift 2 ;;
    --et-tag)    ET_TAG="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    --platform)  PLATFORM="${2:-}"; shift 2 ;;
    --extras-only)   EXTRAS_ONLY=1; shift ;;
    --print-et-tag)  PRINT_ET_TAG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "${PRINT_ET_TAG:-0}" -eq 1 ]; then
  printf '%s\n' "$ET_TAG"   # ET_TAG defaults to DEFAULT_ET_TAG (overridable via --et-tag)
  exit 0
fi

# As this script is intended to run in a container with a volume mount, the permissions of the built artifacts
# can be a little goofy.  Use a trap to ensure that permissions get set to something meaningful for the user running the container
# regardless of build status.  Lack of `HOST_UID` for GitHub Action means this won't do anything when run in CI
cleanup() {
  rc=$?
  if [ -n "${HOST_UID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${BUILD_DIR}" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

[ -n "$VARIANT" ] || { echo "--variant required" >&2; exit 2; }
VARIANT_FLAGS="$(variant_flags "$VARIANT")"   # returns 2 on unknown -> set -e aborts with code 2
CONFIGURE_BASE="$(et_configure_base "$PLATFORM")"   # returns 2 on unknown platform -> set -e aborts
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac

if [ "$PRINT_FLAGS" -eq 1 ]; then
  printf '%s\n' "$VARIANT_FLAGS"
  exit 0
fi

[ -n "$PREFIX" ] || { echo "--prefix required" >&2; exit 2; }
CONFIG="$PREFIX/lib/cmake/ExecuTorch/executorch-config.cmake"

# Phase 2: build + install the extras (custom ops) against an already-installed prefix.
# Reachable standalone via --extras-only (used by the PR gate to rebuild extras from a
# branch against a downloaded release prefix, skipping the ~15min ET compile).
build_extras() {
  echo ">> building extras (custom ops) against the installed prefix"
  # USDT probes need <sys/sdt.h> (systemtap-sdt-devel) at compile time. Install it
  # unconditionally as provisioning; the CMake option ETNP_ENABLE_USDT stays the
  # single source of truth for emission. || echo: never abort a deliberate
  # -DETNP_ENABLE_USDT=OFF build on a box without the package (set -e).
  echo ">> ensuring USDT probe header (systemtap-sdt-devel)"
  dnf install -y systemtap-sdt-devel \
    || echo ">> WARNING: systemtap-sdt-devel install failed; USDT build will FATAL if enabled"
  # The extras cmake generates etnp_lstm_schema.h from extra.yaml via
  # generate_schema_header.py (import yaml). build_extras owns this dep, so every
  # --extras-only caller is covered — the tier1/tier2 gate jobs run --extras-only
  # BEFORE install_executorch.sh provides a full env, and the full build already
  # installed it in phase 1 (redundant here, harmless).
  echo ">> ensuring extras build deps (pyyaml for schema-gen)"
  pip install -q pyyaml \
    || echo ">> WARNING: pyyaml install failed; schema-gen will fail if absent"
  # Place the extras build tree NEXT TO the ET build tree (its sibling), exactly as the
  # pre-refactor inline code did — for both the default and an explicit --build-dir. This
  # keeps the full-build path behaviorally identical (Task 2 review decision).
  local _etb="${BUILD_DIR:-$(dirname "$PREFIX")/et-build-$VARIANT}"
  local extras_build="$(dirname "$_etb")/etnp-extras-$VARIANT"
  cmake -B "$extras_build" -S "$HERE/extras" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  # Building the link probe runs the POST_BUILD nm-guard (registrar survived).
  cmake --build "$extras_build" -j"$(nproc)"
  cmake --install "$extras_build" --prefix "$PREFIX"
  EXTRAS_BUILD="$extras_build"   # exported for the full-build Highway-license step
}

# Highway (libhwy.a) is fetched + installed by build_extras; its LICENSE is not in ET's
# tree. Copy it into the prefix or hard-fail — shipping libhwy.a without its license is a
# compliance defect. Called by BOTH the full build and --extras-only, so a locally-built
# or gate-built prefix is never license-incomplete for the dependency the extras phase adds.
install_highway_license() {
  mkdir -p "$PREFIX/THIRD-PARTY-NOTICES"
  local hwy_lic
  hwy_lic="$(find "$EXTRAS_BUILD" -path '*highway-src/LICENSE' -type f 2>/dev/null | head -n1 || true)"
  if [ -n "$hwy_lic" ]; then
    cp "$hwy_lic" "$PREFIX/THIRD-PARTY-NOTICES/highway_LICENSE"
  else
    echo ">> ERROR: Highway LICENSE not found under $EXTRAS_BUILD; refusing to ship libhwy.a without its license" >&2
    exit 1
  fi
}

# ---- --extras-only: rebuild ONLY the extras against an existing prefix ----
# Used by the PR gate: a downloaded release tarball is the ET install; we rebuild the
# branch's custom ops on top of it. No ET compile, no --et-src, no ET-license/reloc steps —
# but DO run install_highway_license, because build_extras installs libhwy.a and a
# distributed local build must carry Highway's license too (parity with the full build).
if [ "${EXTRAS_ONLY:-0}" -eq 1 ]; then
  test -f "$CONFIG" \
    || { echo "--extras-only but $CONFIG is missing; provide a built/extracted ET prefix" >&2; exit 1; }
  build_extras
  install_highway_license
  echo ">> --extras-only done: $PREFIX"
  exit 0
fi

# ---- SKIP_ET_BUILD: reuse an existing --prefix install ----
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

# An upstream issue for this has been opened here:
# https://github.com/pytorch/executorch/issues/20709
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

if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — upstream flatc byproduct bug"
  sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' \
    "$ET_SRC/third-party/CMakeLists.txt" || true
fi

# Rather than the full `install_requirements.sh` from the ExecuTorch source,
# just install the minimal set of deps for our build process
echo ">> installing python deps"
pip install -U pip setuptools wheel pyyaml
pip install ninja
pip install "$TORCH_SPEC" --index-url https://download.pytorch.org/whl/cpu

echo ">> Toolchain versions"
cmake --version
if [ "$IS_WINDOWS" -eq 1 ]; then cl 2>&1 | head -1 || true; else gcc --version; g++ --version; fi
ninja --version
python -V

echo ">> configuring ($VARIANT, platform=$PLATFORM)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja $CONFIGURE_BASE \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  $VARIANT_FLAGS $(common_cmake_flags)

echo ">> building"
if [ "$IS_WINDOWS" -eq 1 ]; then JOBS="${NUMBER_OF_PROCESSORS:-4}"; else JOBS="$(nproc)"; fi
cmake --build "$ET_BUILD" -j"$JOBS"

echo ">> installing to $PREFIX"
mkdir -p "$PREFIX"
cmake --install "$ET_BUILD" --prefix "$PREFIX"

if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> Windows: core-only build, skipping extras (phase 2)"
  printf 'n/a\n' > "$PREFIX/.etnp_usdt"   # packaging requires this marker; no extras/USDT on Windows
else
  build_extras
fi

echo ">> measuring relocatability"
# capture once (`|| true`: grep exits 1 on no match, which must not abort under set -e/pipefail)
leaked="$(grep -rl "$PREFIX" "$PREFIX/lib/cmake" 2>/dev/null || true)"
if [ -n "$leaked" ]; then
  echo ">> WARNING: absolute build-prefix leaked into cmake configs; rewriting to \${PACKAGE_PREFIX_DIR}"
  printf '%s\n' "$leaked" | while read -r f; do
    sed -i "s#$PREFIX#\${PACKAGE_PREFIX_DIR}#g" "$f"
  done
fi

# ET's find_library resolves system libs to container-absolute paths and bakes them into the
# exported INTERFACE_LINK_LIBRARIES (e.g. /usr/lib64/libm.so, /usr/lib64/librt.so — this recipe
# runs in manylinux_2_28, a RHEL base where system libs live under /usr/lib64). Those absolute
# paths break consumers whose libm/librt live elsewhere (Debian/Ubuntu multiarch keeps them at
# /usr/lib/x86_64-linux-gnu), failing at link time with "cannot find /usr/lib64/libm.so" even
# though the lib is present. Rewrite each to its bare link name so the consumer's own linker
# resolves it via -l<name>. Anchored on /usr/lib64/ so project archives under
# ${PACKAGE_PREFIX_DIR}/lib are never touched. (|| true: grep exits 1 on no match under set -e.)
if [ "$IS_WINDOWS" -eq 0 ]; then
  echo ">> normalizing absolute system-library paths to -l<name> (portability across host libdirs)"
  syslib="$(grep -rlE '/usr/lib64/lib[a-z0-9_]+\.(so|a)' "$PREFIX/lib/cmake" 2>/dev/null || true)"
  if [ -n "$syslib" ]; then
    echo ">> WARNING: absolute system-lib paths leaked into cmake configs; rewriting to bare link names"
    printf '%s\n' "$syslib" | while read -r f; do
      sed -i -E 's#/usr/lib64/lib([a-z0-9_]+)\.(so|a)#\1#g' "$f"
    done
  fi
fi

echo ">> license passthrough"
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

if [ "$IS_WINDOWS" -eq 0 ]; then install_highway_license; fi

# safe.directory='*': the checkout may be owned by a different uid than the container user (mounted
# tree / CI), which otherwise trips git's "dubious ownership" guard and blocks rev-parse.
git -c safe.directory='*' -C "$ET_SRC" rev-parse HEAD > "$PREFIX/.et_commit"
echo ">> build-runtime.sh done: $PREFIX"
