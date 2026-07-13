#!/usr/bin/env bash
# Emit BUILDINFO (contract C5) key=value lines to stdout.
set -euo pipefail
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
: "${USDT:?}"
cat <<EOF
et_version=$ET_VERSION
et_commit=$ET_COMMIT
torch_version=$TORCH_VERSION
variant=$VARIANT
platform=$PLATFORM
usdt=$USDT
cmake_flags=$CMAKE_FLAGS
toolchain=$TOOLCHAIN
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
package_tag=$PACKAGE_TAG
EOF
