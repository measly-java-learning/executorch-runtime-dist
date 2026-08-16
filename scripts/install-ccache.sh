#!/usr/bin/env bash
# Install the pinned ccache into CCACHE_PREFIX_DIR (default /usr/local/bin).
#   scripts/install-ccache.sh
# Test hooks: CCACHE_LOCAL_ARCHIVE uses an existing file instead of downloading;
#             CCACHE_PREFIX_DIR overrides the install dir.
#
# Idempotent: if the target already reports the pinned version, it exits 0 without downloading.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/ccache.sh
. "$ROOT/scripts/lib/ccache.sh"

prefix="${CCACHE_PREFIX_DIR:-/usr/local/bin}"
target="$prefix/ccache"

if [ -x "$target" ] && "$target" --version 2>/dev/null | head -1 | grep -q "$CCACHE_VERSION"; then
  echo "ccache $CCACHE_VERSION already installed at $target"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${CCACHE_LOCAL_ARCHIVE:-}" ]; then
  cp "$CCACHE_LOCAL_ARCHIVE" "$work/$CCACHE_ARCHIVE"
else
  curl -fsSL -o "$work/$CCACHE_ARCHIVE" "$CCACHE_URL"
fi

actual="$(sha256sum "$work/$CCACHE_ARCHIVE" | cut -d' ' -f1)"
if [ "$actual" != "$CCACHE_SHA256" ]; then
  echo "install-ccache.sh: SHA-256 MISMATCH for $CCACHE_ARCHIVE" >&2
  echo "  expected $CCACHE_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

tar -C "$work" -xzf "$work/$CCACHE_ARCHIVE" "$CCACHE_MEMBER"
mkdir -p "$prefix"
install -m 0755 "$work/$CCACHE_MEMBER" "$target"
"$target" --version | head -1
