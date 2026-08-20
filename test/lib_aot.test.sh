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

# The flag itself is a contract, not a preference: ET v1.4.1's pybind11 3.0.4 needs
# Development.Embed for its SHARED modules, which the pinned manylinux image cannot provide.
assert_eq "$(et_aot_cmake_args)" "-DEXECUTORCH_BUILD_PYBIND=OFF" "AOT cmake args"

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
    "$rel sources the AOT args SSOT"
  assert_eq "$([ "$(grep -c 'et_aot_cmake_args' "$f")" -ge 1 ] && echo yes || echo no)" "yes" \
    "$rel calls et_aot_cmake_args"
done <<< "$callers"

# A second spelling of the flag anywhere else is the drift this SSOT exists to prevent.
strays="$(grep -rl 'EXECUTORCH_BUILD_PYBIND' "$root/.github" "$root/scripts" "$root/build-runtime.sh" 2>/dev/null \
          | grep -v "^$root/scripts/lib/aot\.sh$" || true)"
assert_eq "$strays" "" "EXECUTORCH_BUILD_PYBIND is spelled only in scripts/lib/aot.sh"

exit "$ASSERT_FAILS"
