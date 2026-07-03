#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out" "et_version=1.3.1"        "et_version"
assert_contains "$out" "et_commit=abc123"        "et_commit"
assert_contains "$out" "torch_version=2.12.0+cpu" "torch_version"
assert_contains "$out" "variant=logging"         "variant"
assert_contains "$out" "platform=linux-x86_64"   "platform"
assert_contains "$out" "package_tag=v1.3.1-1"    "package_tag"
assert_contains "$out" "build_utc="              "build_utc present"
assert_contains "$out" "toolchain=manylinux_2_28 gcc-toolset-14" "toolchain"
exit "$ASSERT_FAILS"
