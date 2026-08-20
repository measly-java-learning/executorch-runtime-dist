#!/usr/bin/env bash
# classify-gate.sh picks tier1/tier2/full from a changed-files list, with the gh
# release lookup stubbed via GATE_RELEASE_TAG and the ET tag via GATE_ET_TAG.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

run() {  # run <changed-lines> ; sets $out (mode/etver/release_tag)
  printf '%s\n' "$1" > "$tmp/ch"
  out="$(GATE_ET_TAG="${GATE_ET_TAG:-v1.3.1}" "$root/scripts/classify-gate.sh" "$tmp/ch")"
}
mode() { printf '%s\n' "$out" | sed -n 's/^mode=//p'; }
check() { [ "$(mode)" = "$2" ] || { echo "FAIL [$1]: mode=$(mode) want=$2"; fail=1; }; }

# a build-runtime.sh change is always full, even with a release present
GATE_RELEASE_TAG="v1.3.1-2" run "build-runtime.sh"                ; check buildsh full
# pure kernel edit, release exists -> tier1
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/runtime/lstm_cell.cc"; check kernel tier1
# AOT change -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/etnp_lstm_op.py" ; check aot   tier2
# schema generator -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/generate_schema_header.py"; check schema tier2
# extra.yaml (op name/schema) -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/extra.yaml"          ; check yaml  tier2
# fixture-defining files live under aot/ -> tier2 (guards the classification bug this fixes)
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/lstm_case.py"    ; check case  tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/emit_fixtures.py"; check emit  tier2
# no matching release -> full (even for a pure kernel edit)
GATE_RELEASE_TAG="" run "extras/lstm/runtime/lstm_cell.cc"        ; check norelease full
# etver is derived from the ET tag (GATE_ET_TAG override, via run())
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/runtime/lstm_cell.cc"
printf '%s\n' "$out" | grep -q '^etver=1.3.1$' || { echo "FAIL etver parse"; fail=1; }

# etver derived from the REAL build-runtime.sh --print-et-tag when GATE_ET_TAG is unset
# (integration: proves classify reads the pin without regex-scraping the source)
printf 'extras/lstm/runtime/lstm_cell.cc\n' > "$tmp/ch"
out="$(GATE_RELEASE_TAG="v1.3.1-2" "$root/scripts/classify-gate.sh" "$tmp/ch")"
printf '%s\n' "$out" | grep -q '^etver=1.4.1$' || { echo "FAIL: etver via --print-et-tag"; fail=1; }

# transient gh failure (no GATE_RELEASE_TAG) exits non-zero — must NOT silently emit full
printf 'extras/lstm/runtime/lstm_cell.cc\n' > "$tmp/ch"
if GATE_ET_TAG="v1.3.1" GATE_GH_CMD="false" GATE_RETRY_SLEEP=0 \
     "$root/scripts/classify-gate.sh" "$tmp/ch" >/dev/null 2>&1; then
  echo "FAIL: gh failure should exit non-zero, not succeed"; fail=1
fi

# a working gh stub (no GATE_RELEASE_TAG) resolves the newest matching tag -> tier1
cat > "$tmp/ghstub" <<'STUB'
#!/usr/bin/env bash
printf 'v1.2.0-9\nv1.3.1-1\nv1.3.1-2\n'   # emulates: gh release list --json tagName --jq '.[].tagName'
STUB
chmod +x "$tmp/ghstub"
out="$(GATE_ET_TAG="v1.3.1" GATE_GH_CMD="$tmp/ghstub" "$root/scripts/classify-gate.sh" "$tmp/ch")"
[ "$(mode)" = "tier1" ] || { echo "FAIL: stub resolve mode=$(mode)"; fail=1; }
printf '%s\n' "$out" | grep -q '^release_tag=v1.3.1-2$' || { echo "FAIL: stub newest tag"; fail=1; }

# An OpenVINO vendoring/SSOT change alters a published artifact's contents, and the gate scripts
# and workspace-size surface only run in `full`, so each must get the full treatment rather than a
# kernel-only tier1 gate.
for f in scripts/vendor-openvino.sh scripts/lib/openvino.sh \
         test/openvino_smoke.sh test/openvino_fixture_run.sh test/openvino/ov_runner.cpp \
         scripts/patch-et-xnnpack-workspace.sh \
         patches/et-xnnpack-workspace-size.patch test/xnnpack_workspace_run.sh \
         .github/workflows/extras-gate.yml; do
  cf="$(mktemp)"; printf '%s\n' "$f" > "$cf"
  out="$(GATE_ET_TAG=v1.3.1 GATE_RELEASE_TAG=v1.3.1-1 bash "$here/../scripts/classify-gate.sh" "$cf")"
  assert_contains "$out" "mode=full" "full-surface change ($f) forces a full gate"
done

# Editing the gate definition must RUN the gate. This is not a stylistic rule: PR #29 restructured
# the `full` jobs and went green without executing a single one of them, because extras-gate.yml
# started the workflow but classified as tier1.
cf="$(mktemp)"; printf '%s\n' '.github/workflows/extras-gate.yml' > "$cf"
out="$(GATE_ET_TAG=v1.3.1 GATE_RELEASE_TAG=v1.3.1-1 bash "$here/../scripts/classify-gate.sh" "$cf")"
assert_contains "$out" "mode=full" "a change to the gate definition runs the gate"
# The sibling workflow must NOT be swept in: release.yml is not validated by extras-gate, so
# routing it to `full` would buy a 19-minute job that proves nothing about it.
cf="$(mktemp)"; printf '%s\n' '.github/workflows/release.yml' > "$cf"
out="$(GATE_ET_TAG=v1.3.1 GATE_RELEASE_TAG=v1.3.1-1 bash "$here/../scripts/classify-gate.sh" "$cf")"
assert_contains "$out" "mode=tier1" "release.yml is not routed to full"

# A routing rule is only as good as the workflow's `paths:` filter: if extras-gate.yml does not
# TRIGGER for a file, classify-gate.sh never runs and the rule above is dead code. This guards the
# reachability half, which a script-only test cannot see.
wf="$here/../.github/workflows/extras-gate.yml"
for p in scripts/vendor-openvino.sh scripts/lib/openvino.sh scripts/lib/cmakeflags.sh \
         test/openvino_smoke.sh test/openvino_fixture_run.sh 'test/openvino/**' \
         scripts/patch-et-xnnpack-workspace.sh scripts/emit-xnnpack-fixtures.py \
         'patches/**' test/xnnpack_workspace_run.sh 'test/xnnpack_workspace/**'; do
  assert_contains "$(cat "$wf")" "'$p'" "extras-gate workflow triggers on $p"
done

[ "$fail" -eq 0 ] && [ "$ASSERT_FAILS" -eq 0 ] && echo "OK: classify-gate" || exit 1
