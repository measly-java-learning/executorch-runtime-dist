#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"

# Scripts the release workflow runs as commands (`./scripts/foo.sh`, or invoked by path from another
# script) MUST be committed executable (git mode 100755), or a fresh CI checkout can't run them.
# NOTE: we check git's TRACKED mode via `git ls-files -s`, NOT the working-tree bit — the original
# failure was a script that was +x locally but committed as 100644, which a `test -x` check misses.
for s in build-runtime.sh scripts/package.sh scripts/gen-pin.sh scripts/gen-buildinfo.sh scripts/derive-version.sh; do
  mode="$(cd "$root" && git ls-files -s -- "$s" | awk '{print $1}')"
  assert_eq "$mode" "100755" "$s committed executable (100755)"
done
exit "$ASSERT_FAILS"
