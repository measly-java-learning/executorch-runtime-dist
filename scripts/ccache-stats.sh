#!/usr/bin/env bash
# Report the ccache hit rate for THIS run and optionally enforce a floor.
#   scripts/ccache-stats.sh
# Env: CCACHE_STATS_FILE  read stats from a file instead of running ccache (tests)
#      CCACHE_ENFORCE=1   exit 1 when below the floor (set ONLY on an exact cache-key match)
#      CCACHE_MIN_HIT_RATE  floor in percent (default 1)
#
# Counters come from `ccache --print-stats` (tab-separated, machine-readable). Do NOT parse
# `ccache -s`: in 4.x it prints only a size summary by default, and its prose changes between
# releases. Key names verified against real 4.13.6 output.
#
# The run must have been preceded by `ccache -z`, or these are LIFETIME counters and the rate
# drifts upward forever regardless of what this run did.
set -euo pipefail

if [ -n "${CCACHE_STATS_FILE:-}" ]; then
  stats="$(cat "$CCACHE_STATS_FILE")"
else
  stats="$(ccache --print-stats)"
fi

get() { printf '%s\n' "$stats" | awk -F'\t' -v k="$1" '$1==k {print $2; found=1} END {if(!found) print ""}'; }
direct="$(get direct_cache_hit)"
pre="$(get preprocessed_cache_hit)"
miss="$(get cache_miss)"

# Loud failure beats a silent 0% or 100%.
if [ -z "$direct" ] || [ -z "$pre" ] || [ -z "$miss" ]; then
  echo "ccache-stats.sh: expected counters absent from --print-stats output." >&2
  echo "  looked for: direct_cache_hit, preprocessed_cache_hit, cache_miss" >&2
  echo "  got:" >&2; printf '%s\n' "$stats" | head -20 >&2
  exit 2
fi

hits=$(( direct + pre ))
total=$(( hits + miss ))
floor="${CCACHE_MIN_HIT_RATE:-1}"

if [ "$total" -eq 0 ]; then
  # Nothing was compiled. Undefined, not 0% - enforcing here would fail a legitimately no-op run.
  msg="ccache: no compilations this run (0 hits, 0 misses) - nothing to enforce"
  echo "$msg"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$msg" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

rate="$(awk -v h="$hits" -v t="$total" 'BEGIN{printf "%.1f", (h*100)/t}')"
msg="ccache hit rate: ${rate}% (${hits} hits / ${total} compilations, ${miss} misses)"
echo "$msg"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### ccache"; echo ""; echo "$msg"; } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${CCACHE_ENFORCE:-0}" = "1" ]; then
  if awk -v r="$rate" -v f="$floor" 'BEGIN{exit !(r < f)}'; then
    echo "::error::ccache hit rate ${rate}% is below the ${floor}% floor on an EXACT cache-key match." >&2
    echo "  An exact key match means the cache restored the objects this build should reuse." >&2
    echo "  A rate this low means ccache is effectively not working - investigate before raising the floor." >&2
    exit 1
  fi
fi
