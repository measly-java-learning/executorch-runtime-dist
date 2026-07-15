#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mk() { printf '%s  %s\n' "$1" "${2%.sha256}" > "$tmp/$2"; }
mk aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaadeadbeef executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
mk bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb12345678 executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz.sha256

# Mirror the workflow step's pipeline exactly.
base="https://example.com/releases/download/v1.3.1-1"
args=(--version 1.3.1-1 --etver 1.3.1 --base-url "$base")
while IFS="$(printf '\t')" read -r variant platform sha; do
  args+=(--row "$variant" "$platform" "$sha")
done < <(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp" --etver 1.3.1)
out="$(bash "$here/../scripts/gen-pin.sh" "${args[@]}")"

assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_linux-x86_64 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaadeadbeef")'   "linux row present"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_windows-x86_64 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb12345678")' "windows row present"
assert_contains "$out" "$base/executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz" "windows url value"
# No fabricated windows bare/devtools rows (the old hardcoded loop would have demanded them).
case "$out" in *windows-x86_64*bare*|*bare*windows-x86_64*) printf 'FAIL: unexpected windows bare row\n' >&2; exit 1 ;; esac

exit "$ASSERT_FAILS"
