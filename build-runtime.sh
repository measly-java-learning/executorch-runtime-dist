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
. "$HERE/scripts/lib/openvino.sh"   # ov_enabled_for_platform, used by common_cmake_flags
. "$HERE/scripts/lib/cmakeflags.sh"
. "$HERE/scripts/lib/configure-base.sh"

# As we run as root inside a container, set this flag to avoid log spam
export PIP_ROOT_USER_ACTION=ignore
DEFAULT_ET_TAG="v1.4.1"
TORCH_SPEC="torch==2.13.0+cpu"

usage() {
  cat <<'EOF'
Usage: build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> --et-src <et-checkout>
                        [--et-tag <label>] [--build-dir <dir>]
       build-runtime.sh --print-flags --variant <variant> [--platform <platform>]  # dry: print effective cmake flags, no build
Runs inside manylinux_2_28. --et-src is a checked-out ExecuTorch tree (with submodules); the recipe does not clone.
--et-tag is the version label (default v1.4.1). --build-dir is the CMake build tree (default:
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
# Kept even though the cmake invocation below no longer interpolates these directly: calling
# variant_flags/et_configure_base here is early validation — each returns 2 on an unknown
# variant/platform, and set -e turns that into an immediate abort before any expensive work
# (ET compile). effective_cmake_flags (used below) would fail just as fast, but by then we've
# already parsed --print-flags etc.; keep the fail-fast at the top.
VARIANT_FLAGS="$(variant_flags "$VARIANT")"   # returns 2 on unknown -> set -e aborts with code 2
CONFIGURE_BASE="$(et_configure_base "$PLATFORM")"   # returns 2 on unknown platform -> set -e aborts
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac
# On Windows the pwsh caller passes $PWD with backslashes (C:\...\out), but cmake writes forward-slash
# paths into lib/cmake/*.cmake. The relocatability leak-scan below (grep -rl "$PREFIX") would then
# search for a backslash string the forward-slash file content never contains -> a real prefix leak
# would go undetected, and a backslash PREFIX is unsafe as a grep/sed pattern. Normalize to forward
# slashes (cmake accepts them as an install prefix) so the scan and any rewrite operate on cmake-shaped
# paths. Guarded on non-empty PREFIX so the --print-flags path (PREFIX may be unset) is untouched.
if [ "$IS_WINDOWS" -eq 1 ] && [ -n "$PREFIX" ]; then PREFIX="${PREFIX//\\//}"; fi

if [ "$PRINT_FLAGS" -eq 1 ]; then
  # The EFFECTIVE set, platform-aware — this is the only way to inspect the CRT without a build.
  effective_cmake_flags "$PLATFORM" "$VARIANT" || exit 2
  printf '\n'
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
  python -m pip install -q pyyaml \
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

if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — upstream flatc byproduct bug"
  sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' \
    "$ET_SRC/third-party/CMakeLists.txt" || true
fi

# Workspace-size accessor patches (see scripts/patch-et-xnnpack-workspace.sh). Applied here, with
# the other source patches, because they must land before configure. Not guarded by platform:
# XNNPACK builds on every platform we ship.
"$HERE/scripts/patch-et-xnnpack-workspace.sh" "$ET_SRC"

# Rather than the full `install_requirements.sh` from the ExecuTorch source,
# just install the minimal set of deps for our build process
echo ">> installing python deps"
# `python -m pip`, never the bare `pip` console script. On Windows pip cannot upgrade itself
# through pip.exe -- the running executable is locked, so pip refuses outright and tells you to
# re-run it this way. It stayed invisible while the runner image happened to ship the newest pip
# and `-U pip` was a no-op; the day upstream published a newer one, both Windows jobs failed.
# Harmless on Linux, where the same call works either way.
python -m pip install -U pip setuptools wheel pyyaml
python -m pip install ninja
python -m pip install "$TORCH_SPEC" --index-url https://download.pytorch.org/whl/cpu

echo ">> Toolchain versions"
cmake --version
if [ "$IS_WINDOWS" -eq 1 ]; then cl 2>&1 | head -1 || true; else gcc --version; g++ --version; fi
ninja --version
python -V

# On Windows the GitHub runner ships multiple Pythons; cmake's find_package(Python3) picks the
# newest in the hostedtoolcache (e.g. 3.14.x), but our `pip install pyyaml/torch` above targets
# whichever `python` is on the Git-Bash PATH (e.g. 3.12.x). ET's codegen (gen_oplist.py) then runs
# under cmake's interpreter and dies with ModuleNotFoundError: yaml. Pin cmake to the SAME
# interpreter we installed into so codegen sees our deps. (No-op on Linux: the manylinux container
# has a single python, so find_package already agrees with our pip.)
PYTHON_PIN=""
if [ "$IS_WINDOWS" -eq 1 ]; then
  py="$(python -c 'import sys; print(sys.executable.replace(chr(92), "/"))')"
  echo ">> pinning cmake Python to $py (avoids runner multi-interpreter mismatch)"
  PYTHON_PIN="-DPYTHON_EXECUTABLE=$py -DPython_EXECUTABLE=$py -DPython3_EXECUTABLE=$py"
fi

echo ">> configuring ($VARIANT, platform=$PLATFORM)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja \
  $(effective_cmake_flags "$PLATFORM" "$VARIANT") \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  $PYTHON_PIN

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

# Prove the workspace-size patches survived compilation, not merely that files were edited. The
# accessor and the option key are a published consumer contract; a future ET bump that drops a
# patch must fail the build here rather than regress a consumer's memory accounting silently.
# Windows: MSVC has no nm, and the archives are .lib — skip, the Linux gate covers the contract.
if [ "$IS_WINDOWS" -eq 0 ]; then
  echo ">> verifying workspace-size symbols are present in the installed prefix"
  # Patch A (xnn_get_workspace_size) compiles into the XNNPACK submodule, which this ET pin ships
  # as its OWN archive (libXNNPACK.a) rather than folded into libxnnpack_backend.a. Scanning every
  # lib/*.a tests the property that matters — the symbol is somewhere in the shipped prefix —
  # without depending on a pin's archive layout.
  # Patch C (total_workspace_size) and patch D (workspace_size_option_key) live in the ET-side
  # backend archive. The option key is a namespace-scope const char[] (internal linkage), so it is
  # a LOCAL symbol: include local symbols (no `-g` flag). `nm -C` demangles so the guard reads
  # source names. Patch B (XNNWorkspace::size()) is defined inline in its header and its only call
  # site inlines it away in Release, so it emits no symbol of its own; it is covered by patch C
  # (its sole caller) plus the behavioural gate (test/xnnpack_workspace_run.sh), which exercises
  # the whole chain end to end.
  # `|| true`: nm exits nonzero when the glob matches no archive; grep exits 1 on no-match —
  # neither may abort under set -e before the messages below.
  _wsyms="$(nm -C --defined-only "$PREFIX"/lib/*.a 2>/dev/null || true)"
  _wsfail=""
  for _sym in xnn_get_workspace_size XNNWorkspaceManager::total_workspace_size workspace_size_option_key; do
    # case, not `grep -q | printf`: grep -q exits the moment it matches, SIGPIPE-killing the
    # writer, and pipefail then reports the pipeline failed — a false FAIL on a good build.
    case "$_wsyms" in
      *"$_sym"*) ;;
      *) echo "   FAIL: $_sym not found in $PREFIX/lib" >&2; _wsfail=1 ;;
    esac
  done
  if [ -n "$_wsfail" ]; then
    echo "   A workspace-size patch applied but a required symbol did not survive the build." >&2
    echo "   Check that the ET pin still compiles the patched sources into the shipped archives." >&2
    exit 1
  fi
  echo "   ok: workspace-size symbols present"
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
