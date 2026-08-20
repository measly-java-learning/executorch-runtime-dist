#!/usr/bin/env bash
# scripts/lib/aot.sh is the SSOT for the cmake args handed to install_executorch.sh. Two places run
# that install — the gate's full-aot step and the lstm-roundtrip composite action, which the RELEASE
# workflow also uses — so a flag added at one call site and forgotten at the other breaks the
# release long after the gate went green. That drift is what this test exists to catch.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"

. "$root/scripts/lib/aot.sh"

# The package name must track the RUNNING interpreter's minor version, because CPython's C ABI is
# stable per minor: linking a libpython from a different minor is the bug this derivation prevents.
# Hermetic and real — it runs against whatever python3 this machine has, not a hardcoded 3.12.
mm="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
assert_eq "$(et_aot_python_devel_pkg)" "python${mm}-devel" "devel package tracks the live interpreter"

# et_aot_install_build_deps itself is NOT run here: it needs dnf, root, and an el8 userspace, none
# of which belong in a hermetic suite that must pass from a clean checkout on any machine. Its
# behaviour was verified inside the pinned container; what this file guards is that both call sites
# go through it and that nothing re-spells its contents elsewhere.
assert_eq "$(type -t et_aot_install_build_deps)" "function" "et_aot_install_build_deps is defined"

# Every call site that RUNS install_executorch.sh must go through the SSOT. Match the invocation
# (`./install_executorch.sh`), not a bare mention — checkout-executorch/action.yml names the script
# in a comment explaining its leaf-directory requirement and must not be caught by this.
# `|| true`: grep exits 1 on no-match, and an empty list is handled explicitly below.
callers="$(grep -rl '\./install_executorch\.sh' "$root/.github" || true)"
assert_eq "$([ -n "$callers" ] && echo present || echo none)" "present" \
  "at least one install_executorch.sh call site exists under .github"

# NOT a pipeline: `while read` on the right of a `|` runs in a subshell, so ASSERT_FAILS increments
# would be discarded and the test would exit 0 while printing FAILs. A here-string keeps the loop in
# this shell.
while read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$root"/}"
  # Assert on a short derived value, not the file body — assert_contains echoes its haystack, and a
  # whole workflow file in the failure output buries the finding.
  assert_eq "$([ "$(grep -c 'scripts/lib/aot\.sh' "$f")" -ge 1 ] && echo yes || echo no)" "yes" \
    "$rel sources the AOT SSOT"
  assert_eq "$([ "$(grep -c 'et_aot_install_build_deps' "$f")" -ge 1 ] && echo yes || echo no)" "yes" \
    "$rel calls et_aot_install_build_deps"
done <<< "$callers"

# Both AOT-install files must be in extras-gate's `paths:` filter. They run only in full-aot and
# live-roundtrip, so if the filter does not list them an AOT-only change starts NO workflow and
# ships ungated — and the round-trip action is shared with release.yml, so that lands at the tag.
# The workflow's own comments record this trap biting twice before.
gate="$root/.github/workflows/extras-gate.yml"
paths_block="$(sed -n '/^on:/,/^permissions:/p' "$gate")"
for p in "scripts/lib/aot.sh" ".github/actions/lstm-roundtrip/action.yml"; do
  assert_contains "$paths_block" "'$p'" "extras-gate paths filter lists $p"
done

# A second spelling of the devel package anywhere else is the drift this SSOT exists to prevent.
strays="$(grep -rlE 'python3\.[0-9]+-devel' "$root/.github" "$root/scripts" "$root/build-runtime.sh" 2>/dev/null \
          | grep -v "^$root/scripts/lib/aot\.sh$" || true)"
assert_eq "$strays" "" "the python devel package is spelled only in scripts/lib/aot.sh"

exit "$ASSERT_FAILS"
