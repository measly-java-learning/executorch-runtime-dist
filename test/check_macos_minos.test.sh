#!/usr/bin/env bash
# Hermetic tests for scripts/check-macos-minos.sh. Stub otool/lipo (via the MINOS_OTOOL/MINOS_LIPO
# hooks) serve canned output per archive, so every pass/fail shape runs on Linux CI too.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
S="$here/../scripts/check-macos-minos.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
canned="$tmp/canned"; mkdir -p "$canned" "$tmp/bin"

# Stubs: `otool -l <a>` prints canned/<basename>.otool, `lipo -archs <a>` prints canned/<basename>.archs.
# A missing canned file makes the stub fail, like a real tool error.
cat > "$tmp/bin/otool" <<EOF
#!/bin/sh
cat "$canned/\$(basename "\$2").otool" 2>/dev/null || { echo "otool: cannot read \$2" >&2; exit 1; }
EOF
cat > "$tmp/bin/lipo" <<EOF
#!/bin/sh
cat "$canned/\$(basename "\$2").archs" 2>/dev/null || { echo "lipo: cannot read \$2" >&2; exit 1; }
EOF
chmod +x "$tmp/bin/otool" "$tmp/bin/lipo"
export MINOS_OTOOL="$tmp/bin/otool" MINOS_LIPO="$tmp/bin/lipo"

member() { # <archive-path> <member> <platform> <minos>   (shaped like real `otool -l` output)
  printf '%s(%s):\nLoad command 0\n      cmd LC_SEGMENT_64\n  cmdsize 232\nLoad command 1\n      cmd LC_BUILD_VERSION\n  cmdsize 24\n platform %s\n    minos %s\n      sdk 26.5\n   ntools 0\n' "$1" "$2" "$3" "$4"
}
legacy_member() { # <archive-path> <member>   (LC_VERSION_MIN_MACOSX only, no LC_BUILD_VERSION)
  printf '%s(%s):\nLoad command 0\n      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n  version 10.15\n      sdk 11.0\n' "$1" "$2"
}
newprefix() { rm -rf "$tmp/p" "$canned"; mkdir -p "$tmp/p/lib" "$canned"; }
lib() { # <name> <archs> ; otool body on stdin
  : > "$tmp/p/lib/$1"; printf '%s\n' "$2" > "$canned/$1.archs"
  { printf 'Archive : %s\n' "$tmp/p/lib/$1"; cat; } > "$canned/$1.otool"
}
run() { out="$(bash "$S" "$tmp/p" 14.0 arm64 2>&1)"; rc=$?; }

# --- pass: two archives, every member macOS at or below the target ---
newprefix
{ member x a.o 1 14.0; member x b.o 1 13.0; } | lib liba.a arm64
member x c.o 1 11.0 | lib libb.a arm64
run
assert_eq "$rc" "0" "all members macOS minos <= 14.0, arm64 only -> pass"
assert_contains "$out" "objects: 3" "counts every member"

# --- the spike's real defect: extras at the host SDK's minos ---
newprefix
{ member x etnp_lstm.cpp.o 1 26.0; member x lstm_cell.cc.o 1 14.0; } | lib libetnp_ops_lstm.a arm64
run
assert_eq "$rc" "1" "a member at minos 26.0 -> fail"
assert_contains "$out" "MINOS libetnp_ops_lstm.a(etnp_lstm.cpp.o) -> minos 26.0 > 14.0" "names the archive, member and versions"

# --- numeric, not lexical, comparison: 14.0.1 > 14.0, 9.0 < 14.0 ---
newprefix; member x a.o 1 14.0.1 | lib liba.a arm64; run
assert_eq "$rc" "1" "minos 14.0.1 > 14.0 -> fail"
newprefix; member x a.o 1 9.0 | lib liba.a arm64; run
assert_eq "$rc" "0" "minos 9.0 < 14.0 -> pass (lexically '9' > '1')"
newprefix; member x a.o 1 14 | lib liba.a arm64; run
assert_eq "$rc" "0" "minos 14 == 14.0 -> pass"

# --- wrong platform (an iOS object in a macOS tarball) ---
newprefix; member x a.o 2 14.0 | lib liba.a arm64; run
assert_eq "$rc" "1" "platform 2 (iOS) -> fail"
assert_contains "$out" "PLAT" "reports the platform"
newprefix; member x a.o MACOS 14.0 | lib liba.a arm64; run
assert_eq "$rc" "0" "platform spelled MACOS (older cctools) -> pass"

# --- no LC_BUILD_VERSION: legacy-only member is a failure, not a silent pass ---
newprefix; { member x a.o 1 14.0; legacy_member x old.o; } | lib liba.a arm64; run
assert_eq "$rc" "1" "member with only LC_VERSION_MIN_MACOSX -> fail"
assert_contains "$out" "INDET liba.a(old.o)" "names the member with no build version"

# --- architecture ---
newprefix; member x a.o 1 14.0 | lib liba.a "x86_64 arm64"; run
assert_eq "$rc" "1" "fat archive with an x86_64 slice -> fail"
assert_contains "$out" "ARCH  liba.a" "reports the arch"
newprefix; member x a.o 1 14.0 | lib liba.a x86_64; run
assert_eq "$rc" "1" "x86_64-only archive -> fail"

# --- tool errors are failures ---
newprefix; member x a.o 1 14.0 | lib liba.a arm64; rm "$canned/liba.a.otool"; run
assert_eq "$rc" "1" "otool failure -> fail, not skip"
newprefix; member x a.o 1 14.0 | lib liba.a arm64; rm "$canned/liba.a.archs"; run
assert_eq "$rc" "1" "lipo failure -> fail, not skip"
newprefix; : | lib liba.a arm64; run
assert_eq "$rc" "1" "otool output with no members -> fail"

# --- empty/missing prefix and usage ---
newprefix; run
assert_eq "$rc" "1" "no lib/*.a at all -> fail (nothing checked is not a pass)"
bash "$S" "$tmp/nope" 14.0 arm64 >/dev/null 2>&1; assert_eq "$?" "1" "missing lib/ -> fail"
bash "$S" >/dev/null 2>&1;                       assert_eq "$?" "2" "no args -> usage error 2"
bash "$S" "$tmp/p" 14.0 >/dev/null 2>&1;         assert_eq "$?" "2" "missing arch -> usage error 2"
bash "$S" "$tmp/p" 14.x arm64 >/dev/null 2>&1;   assert_eq "$?" "2" "malformed minos -> usage error 2"
exit "$ASSERT_FAILS"
