#!/usr/bin/env bash
# The build container must be pinned by digest in .build-image, and no workflow may hardcode one.
# Checks live in test/lib/check_build_image_pin.py - this script only orchestrates.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

python3 "$here/lib/check_build_image_pin.py" "$here/.." || ASSERT_FAILS=$((ASSERT_FAILS+1))
exit "$ASSERT_FAILS"
