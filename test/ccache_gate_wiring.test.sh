#!/usr/bin/env bash
# Structural guard for the full-aot ccache wiring. The checks live in
# test/lib/check_ccache_wiring.py - this script only orchestrates, per CLAUDE.md's convention
# against non-trivial Python embedded in shell.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

python3 "$here/lib/check_ccache_wiring.py" "$here/../.github/workflows/extras-gate.yml" \
  || ASSERT_FAILS=$((ASSERT_FAILS+1))
exit "$ASSERT_FAILS"
