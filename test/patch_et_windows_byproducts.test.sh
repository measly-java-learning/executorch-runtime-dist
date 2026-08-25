#!/usr/bin/env bash
# Hermetic coverage for the Windows flatc(c)_ep byproduct-naming fix (spike:
# spike/2026-08-24-windows-devtools-variant-spike.md). No ET checkout, no build: operates on a
# synthetic third-party/CMakeLists.txt fixture carrying just the two ExternalProject_Add anchors.
# Proves: both BUILD_BYPRODUCTS lines get suffixed, flatcc_ep's CMAKE_ARGS gains
# -DCMAKE_BUILD_TYPE=Release exactly once, both are idempotent on a second run, a tree that
# already had ONLY the flatbuffers_ep half fixed (the real pre-this-change state of any persisted
# $ET_SRC checkout, from the sed this script replaces) is handled correctly, and a moved anchor is
# a hard error -- not the `|| true` swallow this replaces.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
script="$here/../scripts/patch-et-windows-byproducts.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mk_tree() { # <root>
  mkdir -p "$1/third-party"
  cp "$here/fixtures/etpatch/thirdparty-CMakeLists.txt" "$1/third-party/CMakeLists.txt"
}

mk_tree "$tmp/et"
tp="$tmp/et/third-party/CMakeLists.txt"
bash "$script" "$tmp/et" >"$tmp/out1" 2>&1
assert_eq "$?" "0" "first run succeeds"
assert_contains "$(cat "$tp")" 'BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc.exe' \
  "flatbuffers_ep byproduct suffixed"
assert_contains "$(cat "$tp")" 'BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc.exe' \
  "flatcc_ep byproduct suffixed"
assert_contains "$(cat "$tp")" '-DCMAKE_BUILD_TYPE=Release' \
  "flatcc_ep CMAKE_ARGS gains CMAKE_BUILD_TYPE=Release"
assert_eq "$(grep -cF -- '-DCMAKE_BUILD_TYPE=Release' "$tp")" "1" \
  "CMAKE_BUILD_TYPE=Release appears exactly once"
assert_eq "$(grep -c 'bin/flatc\.exe\.exe' "$tp" || true)" "0" "no double .exe suffix anywhere"

# Idempotency: build-runtime.sh re-runs against a persisted checkout that may already be patched.
cp "$tp" "$tmp/after1.txt"
bash "$script" "$tmp/et" >"$tmp/out2" 2>&1
assert_eq "$?" "0" "second run succeeds"
diff -q "$tmp/after1.txt" "$tp" >/dev/null 2>&1
assert_eq "$?" "0" "second run is byte-identical to the first (true idempotency)"

# A tree that already had ONLY the old flatbuffers_ep-only fix applied (real pre-this-change state
# on a persisted checkout) must still get flatcc_ep fixed, without double-suffixing flatbuffers_ep.
mk_tree "$tmp/partial"
ptp="$tmp/partial/third-party/CMakeLists.txt"
sed -i 's#BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc$#BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc.exe#' "$ptp"
bash "$script" "$tmp/partial" >/dev/null 2>&1
assert_eq "$?" "0" "partially-patched tree still succeeds"
assert_contains "$(cat "$ptp")" 'BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc.exe' \
  "flatcc_ep byproduct fixed on a partially-patched tree"
assert_eq "$(grep -c 'bin/flatc\.exe\.exe' "$ptp" || true)" "0" \
  "pre-existing flatbuffers_ep fix not double-suffixed"

# Drift: the flatcc_ep BUILD_BYPRODUCTS anchor is gone entirely -> hard error, not a silent no-op.
mk_tree "$tmp/driftA"
dtpA="$tmp/driftA/third-party/CMakeLists.txt"
sed -i '/BUILD_BYPRODUCTS <INSTALL_DIR>\/bin\/flatcc$/d' "$dtpA"
out="$(bash "$script" "$tmp/driftA" 2>&1)"
assert_eq "$?" "1" "missing flatcc_ep BUILD_BYPRODUCTS anchor is a hard error"
assert_contains "$out" "pin probably moved" "drift failure explains itself"

# Drift: the -DFLATCC_INSTALL=ON anchor is gone -> hard error.
mk_tree "$tmp/driftB"
dtpB="$tmp/driftB/third-party/CMakeLists.txt"
sed -i '/-DFLATCC_INSTALL=ON$/d' "$dtpB"
out="$(bash "$script" "$tmp/driftB" 2>&1)"
assert_eq "$?" "1" "missing FLATCC_INSTALL=ON anchor is a hard error"

bash "$script" >/dev/null 2>&1
assert_eq "$?" "1" "missing argument is an error"
bash "$script" "$tmp/nonexistent" >/dev/null 2>&1
assert_eq "$?" "1" "nonexistent tree is an error"

exit "$ASSERT_FAILS"
