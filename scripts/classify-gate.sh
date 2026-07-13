#!/usr/bin/env bash
# Decide the extras-gate mode from a PR's changed-files list.
#   classify-gate.sh <changed-files-file>   # prints mode=/etver=/release_tag=
# Order: build-runtime.sh change -> full ; no matching release -> full ;
#        AOT/schema change -> tier2 ; else -> tier1.
# A gh lookup FAILURE (distinct from an empty result) exits non-zero rather than silently
# falling back to full — an infra error is re-runnable, not a build-recipe change.
# Test hooks: GATE_ET_TAG overrides the ET-pin read (else `build-runtime.sh --print-et-tag`);
#             GATE_RELEASE_TAG (set,
# maybe empty) overrides the gh lookup entirely (empty = no release); GATE_GH_CMD
# overrides the `gh` binary; GATE_RETRY_SLEEP overrides the retry backoff (0 in tests).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHANGED="${1:?usage: classify-gate.sh <changed-files-file>}"

# etver from the branch's ET pin (v1.3.1 -> 1.3.1). Ask build-runtime.sh to PRINT the tag
# rather than regex-scraping the source: the script that defines DEFAULT_ET_TAG reports it
# through the shell, so any valid quoting (single/double/none) works and a brittle sed can't
# silently yield an empty tag.
ettag="${GATE_ET_TAG:-$("$ROOT/build-runtime.sh" --print-et-tag)}"
etver="${ettag#v}"

emit() { printf 'mode=%s\netver=%s\nrelease_tag=%s\n' "$1" "$etver" "${2:-}"; }

# (1) any build-runtime.sh change forces a full build (it owns phase 1 + packaging)
if grep -qx 'build-runtime.sh' "$CHANGED"; then
  emit full ""; exit 0
fi

# (2) resolve the newest matching package release.
# A transient `gh` failure must NOT be silently treated as "no release" (which would waste
# a ~15min full build and mislabel the PR). Distinguish: an empty result from a SUCCESSFUL
# call means genuinely no release -> full; a FAILED call after retries is an infra problem
# -> exit non-zero so the (re-runnable) job fails visibly.
GH="${GATE_GH_CMD:-gh}"
if [ -n "${GATE_RELEASE_TAG+x}" ]; then
  release_tag="$GATE_RELEASE_TAG"
else
  release_tag=""; resolved=0
  for attempt in 1 2 3; do
    if tags="$("$GH" release list --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null)"; then
      resolved=1
      release_tag="$(printf '%s\n' "$tags" | grep -E "^v${etver}-" | sort -V | tail -n1 || true)"
      break
    fi
    [ "$attempt" -lt 3 ] && sleep "${GATE_RETRY_SLEEP:-$((attempt * 3))}"
  done
  if [ "$resolved" -ne 1 ]; then
    echo "classify-gate.sh: 'gh release list' failed after 3 attempts (transient?); refusing" >&2
    echo "  to default to a full build on an infra error — re-run this job." >&2
    exit 3
  fi
fi
if [ -z "$release_tag" ]; then
  emit full ""; exit 0
fi

# (3) AOT / schema change -> tier2 (the live round-trip must run)
if grep -qE '^extras/([^/]+/)?aot/|(^|/)generate_schema_header\.py$|(^|/)extra\.yaml$' "$CHANGED"; then
  emit tier2 "$release_tag"; exit 0
fi

# (4) default: pure-kernel / runtime / test edit
emit tier1 "$release_tag"
