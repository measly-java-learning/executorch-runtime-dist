#!/usr/bin/env bash
# SPIKE build: reproduce the design recipe just enough to feed the relocatability
# + PIC gate. Runs INSIDE quay.io/pypa/manylinux_2_28_x86_64. Uses an existing ET
# source checkout (mounted read-only) instead of cloning, to save the ~10-min
# recursive clone. Out-of-tree build dir keeps the source checkout untouched.
set -euo pipefail

ET_SRC="${ET_SRC:-/et-src}"     # existing v1.3.1 checkout, mounted read-write (built in-place)
PREFIX="${PREFIX:-/work/out-logging}"
VARIANT_FLAGS="-DEXECUTORCH_ENABLE_LOGGING=ON"   # logging variant (C3 ship default)
TORCH_SPEC="torch==2.12.0+cpu"
ET_BUILD="${ET_BUILD:-/work/et-build}"   # persisted so reconfigure/rebuild is incremental

# ET 1.3.1 bug: a few targets install to ${CMAKE_BINARY_DIR}/lib (the BUILD dir)
# instead of ${CMAKE_INSTALL_LIBDIR}, so their .a is never placed in the prefix and
# the exported ExecuTorchTargets baked an absolute build-tree path (breaks relocation).
# Correct siblings use ${CMAKE_INSTALL_LIBDIR}; rewrite the buggy ones to match.
echo ">> patching ET install-destination bug (CMAKE_BINARY_DIR/lib -> CMAKE_INSTALL_LIBDIR)"
grep -rl 'DESTINATION ${CMAKE_BINARY_DIR}/lib' --include=CMakeLists.txt "$ET_SRC" | while read -r f; do
  echo "   patch: ${f#"$ET_SRC"/}"
  sed -i 's#DESTINATION ${CMAKE_BINARY_DIR}/lib#DESTINATION ${CMAKE_INSTALL_LIBDIR}#g' "$f"
done

echo ">> python deps"
pip install ninja
pip install -U pip setuptools wheel pyyaml
pip install "$TORCH_SPEC" --index-url https://download.pytorch.org/whl/cpu

echo ">> configuring (logging, PIC on) from $ET_SRC"
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

echo ">> measuring relocatability (raw, before any rewrite)"
if grep -rl "$PREFIX" "$PREFIX/lib/cmake" >/dev/null 2>&1; then
  echo ">> NOTE: absolute build-prefix leaked into cmake configs; rewriting to \${PACKAGE_PREFIX_DIR}"
  grep -rl "$PREFIX" "$PREFIX/lib/cmake" | while read -r f; do
    sed -i "s#$PREFIX#\${PACKAGE_PREFIX_DIR}#g" "$f"
  done
else
  echo ">> clean: no absolute prefix in cmake configs"
fi

echo ">> build done: $PREFIX"
