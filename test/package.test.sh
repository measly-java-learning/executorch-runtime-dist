#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
p="$(mktemp -d)/pfx"
mkdir -p "$p/lib/cmake/ExecuTorch" "$p/include" "$p/THIRD-PARTY-NOTICES"
: > "$p/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$p/LICENSE"
echo "deadbeef" > "$p/.et_commit"
out="$(mktemp -d)"
tb="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$out")"
assert_eq "$(basename "$tb")" "executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz" "tarball name (C1)"
assert_eq "$([ -f "$tb" ] && echo y)" "y" "tarball exists"
assert_eq "$([ -f "$tb.sha256" ] && echo y)" "y" "sha256 sibling exists"
members="$(tar -tzf "$tb")"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/BUILDINFO" "BUILDINFO in tarball"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/LICENSE"   "LICENSE in tarball"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/THIRD-PARTY-NOTICES/" "notices dir"
case "$members" in *".et_commit"*) echo "FAIL: .et_commit leaked into tarball" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: .et_commit excluded";; esac
assert_eq "$(cd "$out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 && echo ok)" "ok" "sha256 verifies"
exit "$ASSERT_FAILS"
