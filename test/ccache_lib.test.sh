#!/usr/bin/env bash
# ccache is pinned by version AND hash, like the OpenVINO wheel (OV_WHEEL_SHA256). A version
# without a hash is not a pin: the same URL can serve different bytes later.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"
. "$root/scripts/lib/ccache.sh"

# NB: assert.sh takes (actual, expected, msg) in that order.
assert_eq "$CCACHE_VERSION" "4.13.6" "pinned ccache version"
# a sha256 is 64 lowercase hex chars - catches a truncated or placeholder paste
if printf '%s' "$CCACHE_SHA256" | grep -qE '^[0-9a-f]{64}$'; then
  echo "ok: CCACHE_SHA256 is a well-formed sha256"
else
  echo "FAIL: CCACHE_SHA256 malformed: $CCACHE_SHA256" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
# the URL must carry the pinned version, or bumping the version silently fetches the old asset
case "$CCACHE_URL" in
  *"v${CCACHE_VERSION}/"*"${CCACHE_VERSION}"*) echo "ok: URL is derived from CCACHE_VERSION" ;;
  *) echo "FAIL: CCACHE_URL does not embed CCACHE_VERSION: $CCACHE_URL" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac
case "$CCACHE_MEMBER" in
  *"${CCACHE_VERSION}"*/ccache) echo "ok: archive member is derived from CCACHE_VERSION" ;;
  *) echo "FAIL: CCACHE_MEMBER not version-derived: $CCACHE_MEMBER" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac
exit "$ASSERT_FAILS"
