#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" \
  bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out" "et_version=1.3.1"        "et_version"
assert_contains "$out" "et_commit=abc123"        "et_commit"
assert_contains "$out" "torch_version=2.12.0+cpu" "torch_version"
assert_contains "$out" "variant=logging"         "variant"
assert_contains "$out" "platform=linux-x86_64"   "platform"
assert_contains "$out" "package_tag=v1.3.1-1"    "package_tag"
assert_contains "$out" "build_utc="              "build_utc present"
assert_contains "$out" "toolchain=manylinux_2_28 gcc-toolset-14" "toolchain"
assert_contains "$out" "usdt=on" "usdt field"

# USDT is required: omitting it is a hard error (never silently drop provenance).
ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  OPENVINO_VERSION=n/a \
  bash "$here/../scripts/gen-buildinfo.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing USDT is a hard error"

# C5: OpenVINO provenance. linux-x86_64 records the pinned version; every other platform
# records n/a so the key is always present and greppable.
out_ov="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='--preset linux' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=on \
  OPENVINO_VERSION="$OV_VERSION" bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_ov" "openvino_version=$OV_VERSION" "buildinfo records openvino_version"

out_na="$(ET_VERSION=1.3.1 ET_COMMIT=abc TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=windows-x86_64 CMAKE_FLAGS='flags' TOOLCHAIN=tc PACKAGE_TAG=v1.3.1-1 USDT=n/a \
  OPENVINO_VERSION=n/a bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out_na" "openvino_version=n/a" "buildinfo records n/a off linux-x86_64"

exit "$ASSERT_FAILS"
