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
# The installer must REFUSE a tarball whose hash does not match. This is the whole point of
# pinning; an installer that downloads and runs whatever it got is not a pin.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'not a real tarball' > "$tmp/fake.tar.gz"
if CCACHE_LOCAL_ARCHIVE="$tmp/fake.tar.gz" CCACHE_PREFIX_DIR="$tmp/bin" \
     "$root/scripts/install-ccache.sh" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a tarball with the wrong hash" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: installer rejects a hash mismatch"
fi

# Fixture in the real 4.13.6 --print-stats format (tab-separated).
mk_stats() { printf 'direct_cache_hit\t%s\npreprocessed_cache_hit\t%s\ncache_miss\t%s\n' "$1" "$2" "$3"; }

mk_stats 90 0 10 > "$tmp/s1"
out="$(CCACHE_STATS_FILE="$tmp/s1" "$root/scripts/ccache-stats.sh" 2>&1)"
case "$out" in *"90.0%"*) echo "ok: computes 90% from 90 hits / 10 misses" ;;
  *) echo "FAIL: expected 90.0% in: $out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac

# Enforcement fires below the floor.
if CCACHE_STATS_FILE="$tmp/s1" CCACHE_ENFORCE=1 CCACHE_MIN_HIT_RATE=95 \
     "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "FAIL: 90% passed a 95% floor" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: enforcement fails below the floor"
fi

# ... and does NOT fire when enforcement is off (the restore-key case).
if CCACHE_STATS_FILE="$tmp/s1" CCACHE_MIN_HIT_RATE=95 \
     "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "ok: reports without failing when enforcement is off"
else
  echo "FAIL: failed despite CCACHE_ENFORCE unset" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# A zero-work run must not be reported as 100% or 0% - it is undefined, and enforcing on it would
# fail any run where every object was already up to date.
mk_stats 0 0 0 > "$tmp/s2"
out="$(CCACHE_STATS_FILE="$tmp/s2" CCACHE_ENFORCE=1 CCACHE_MIN_HIT_RATE=50 "$root/scripts/ccache-stats.sh" 2>&1)" \
  && echo "ok: zero-compilation run does not fail enforcement" \
  || { echo "FAIL: zero-work run failed enforcement: $out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# MISSING KEYS MUST BE LOUD. A parser that silently yields 0 fails every run; one that silently
# yields 100% makes the whole gate vacuous. This is the assertion that keeps it honest.
printf 'some_other_counter\t5\n' > "$tmp/s3"
if CCACHE_STATS_FILE="$tmp/s3" "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "FAIL: parser accepted stats with no recognisable counters" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: parser fails loudly when expected counters are absent"
fi

exit "$ASSERT_FAILS"
