#!/usr/bin/env bash
# classify-gate.sh picks tier1/tier2/full from a changed-files list, with the gh
# release lookup stubbed via GATE_RELEASE_TAG and the ET tag via GATE_ET_TAG.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
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
printf '%s\n' "$out" | grep -q '^etver=1.3.1$' || { echo "FAIL: etver via --print-et-tag"; fail=1; }

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

[ "$fail" -eq 0 ] && echo "OK: classify-gate" || exit 1
