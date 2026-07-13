#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

# Fixture mimics a REAL ET install: the C2 members PLUS bin/ and share/ that the ET install emits
# but must NOT be shipped, PLUS the .et_commit build-cache input (read, not shipped).
p="$(mktemp -d)/pfx"
mkdir -p "$p/lib/cmake/ExecuTorch" "$p/include" "$p/THIRD-PARTY-NOTICES" "$p/bin" "$p/share/cpuinfo"
: > "$p/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$p/include/et.h"
: > "$p/THIRD-PARTY-NOTICES/xnnpack_LICENSE"
: > "$p/LICENSE"
: > "$p/bin/pcre2-config"
: > "$p/share/cpuinfo/cpuinfo-config.cmake"
echo "deadbeef" > "$p/.et_commit"
echo "on" > "$p/.etnp_usdt"

out="$(mktemp -d)"
tb="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$out")"
stem="executorch-runtime-1.3.1-logging-linux-x86_64"
assert_eq "$(basename "$tb")" "$stem.tar.gz" "tarball name (C1)"
assert_eq "$([ -f "$tb.sha256" ] && echo y)" "y" "sha256 sibling exists"

members="$(tar -tzf "$tb")"
# EXACT C2 member set — catches any extra (bin/, share/) or .et_commit leaking into the tarball.
lvl2="$(printf '%s\n' "$members" | awk -F/ 'NF>=2 && $2!="" {print $2}' | LC_ALL=C sort -u | tr '\n' ',')"
assert_eq "$lvl2" "BUILDINFO,LICENSE,THIRD-PARTY-NOTICES,include,lib," "tarball contains EXACTLY the C2 members (no bin/share/.et_commit)"
assert_eq "$(cd "$out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 && echo ok)" "ok" "sha256 verifies"

# A missing .et_commit must be a HARD error (never silently ship et_commit=unknown).
p2="$(mktemp -d)/pfx2"
mkdir -p "$p2/lib/cmake/ExecuTorch" "$p2/include" "$p2/THIRD-PARTY-NOTICES"; : > "$p2/LICENSE"
bash "$here/../scripts/package.sh" --prefix "$p2" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "missing .et_commit is a hard error"

# A missing .etnp_usdt marker must also be a hard error (provenance completeness).
p3="$(mktemp -d)/pfx3"
mkdir -p "$p3/lib/cmake/ExecuTorch" "$p3/include" "$p3/THIRD-PARTY-NOTICES"; : > "$p3/LICENSE"
echo "deadbeef" > "$p3/.et_commit"   # present, so we fail specifically on .etnp_usdt
bash "$here/../scripts/package.sh" --prefix "$p3" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "missing .etnp_usdt is a hard error"

exit "$ASSERT_FAILS"
