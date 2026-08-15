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
printf 'XNN_IN=8\nXNN_OUT=8\n' > "$tmp/fx/shape"

for missing in xnnpack_tiny.pte in.bin shape; do
  mv "$tmp/fx/$missing" "$tmp/$missing.stash"
  out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
  rc=$?
  mv "$tmp/$missing.stash" "$tmp/fx/$missing"
  assert_eq "$rc" "1" "gate: missing $missing fails"
  assert_contains "$out" "$missing missing" "gate: names the missing member ($missing)"
done

printf 'XNN_IN=\nXNN_OUT=8\n' > "$tmp/fx/shape"
out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
assert_eq "$?" "1" "gate: unparseable shape file fails"
assert_contains "$out" "XNN_IN" "gate: explains the shape-file failure"

# The probe must name the backend and key by STRING. If it ever gained an include of
# XNNPACKBackend.h it would stop testing the published contract, because that header is not shipped.
assert_contains "$probe" '"XnnpackBackend"' "probe names the backend by string"
assert_contains "$probe" '"workspace_size_bytes"' "probe names the key by string"
case "$probe" in
  *XNNPACKBackend.h*) printf 'FAIL: probe must not include the unshipped backend header\n' >&2
                      ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: probe includes no unshipped header\n' ;;
esac
# The zero-before-load assertion is what stops a constant-returning stub from passing.
assert_contains "$probe" "expected 0 before any model loads" "probe asserts the pre-load zero"

wf="$(cat "$here/../.github/workflows/extras-gate.yml")"
assert_contains "$wf" "test/xnnpack_workspace_run.sh" "extras-gate full-build runs the workspace gate"

exit "$ASSERT_FAILS"
