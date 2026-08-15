#!/usr/bin/env bash
# Hermetic coverage for the workspace gate: input validation (the part that decides whether a
# missing input fails loudly or silently), plus the contract assertions in the probe source that a
# build-requiring test cannot check here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
gate="$here/xnnpack_workspace_run.sh"
probe="$(cat "$here/xnnpack_workspace/workspace_probe.cpp")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash "$gate" >/dev/null 2>&1
assert_eq "$?" "1" "gate: no arguments is a usage error"

mkdir -p "$tmp/prefix" "$tmp/fx"
: > "$tmp/fx/xnnpack_tiny.pte"
: > "$tmp/fx/in.bin"
printf 'XNN_IN_DIMS=1 3 16 16\nXNN_OUT_DIMS=1 8 16 16\n' > "$tmp/fx/shape"

for missing in xnnpack_tiny.pte in.bin shape; do
  mv "$tmp/fx/$missing" "$tmp/$missing.stash"
  out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
  rc=$?
  mv "$tmp/$missing.stash" "$tmp/fx/$missing"
  assert_eq "$rc" "1" "gate: missing $missing fails"
  assert_contains "$out" "$missing missing" "gate: names the missing member ($missing)"
done

printf 'XNN_IN_DIMS=\nXNN_OUT_DIMS=1 8 16 16\n' > "$tmp/fx/shape"
out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
assert_eq "$?" "1" "gate: unparseable shape file fails"
assert_contains "$out" "XNN_IN" "gate: explains the shape-file failure"

# The probe must name the backend and key by STRING. If it ever gained an include of
# XNNPACKBackend.h it would stop testing the published contract, because that header is not shipped.
assert_contains "$probe" '"XnnpackBackend"' "probe names the backend by string"
assert_contains "$probe" '"workspace_size_bytes"' "probe names the key by string"
# The probe builds the input tensor from the fixture's full dims, not a hardcoded 2D shape: the
# workspace-allocating fixture is a conv (4D), and a hardcoded {1, n} input could never load it.
assert_contains "$probe" 'XNN_IN_DIMS' "probe reads dims from the shape file"
# Match an actual #include DIRECTIVE, not the bare filename: the probe's own comment explains that
# the header is deliberately not included, so a substring test would fire on the documentation of
# the very property it is checking. (No `|| true` guard needed — grep's exit 1 is the passing case
# and a command in an `if` condition never triggers `set -e`.)
if printf '%s\n' "$probe" | grep -qE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"].*XNNPACKBackend\.h'; then
  printf 'FAIL: probe must not #include the unshipped backend header\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: probe does not #include the unshipped header\n'
fi
# The zero-before-load assertion is what stops a constant-returning stub from passing.
assert_contains "$probe" "expected 0 before any model loads" "probe asserts the pre-load zero"
# The option is read-only by contract. The backend's set_option chain ends in an implicit no-op
# SUCCESS, so an unhandled key reports Ok and a consumer's write silently appears to work — the
# probe must prove the explicit rejection branch is still there.
assert_contains "$probe" "expected InvalidArgument" "probe asserts set_option is rejected"
assert_contains "$probe" "a rejected set_option changed the reported size" \
  "probe asserts a rejected write does not mutate the value"

wf="$(cat "$here/../.github/workflows/extras-gate.yml")"
assert_contains "$wf" "test/xnnpack_workspace_run.sh" "extras-gate full-build runs the workspace gate"

exit "$ASSERT_FAILS"
