#!/usr/bin/env bash
# Fix two Windows-only ExternalProject_Add bugs in ET's third-party/CMakeLists.txt, both in the
# flatc(c)_ep blocks that build flatbuffers'/flatcc's host CLI tools. Neither was reachable before
# this repo built the `devtools` variant on Windows: flatcc_ep is only configured when
# EXECUTORCH_BUILD_DEVTOOLS=ON, so nothing exercised it here until now.
# See spike/2026-08-24-windows-devtools-variant-spike.md for the diagnosis and live verification.
#
#   1. BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc(c) declares no .exe suffix on either
#      ExternalProject. A prior fix covered flatbuffers_ep's copy with an anchor that does not
#      match flatcc_ep's (one extra trailing 'c'), so flatcc_ep's was never touched. One regex now
#      covers both, with the trailing 'c' optional.
#   2. flatcc_ep's CMAKE_ARGS never passes -DCMAKE_BUILD_TYPE=Release, so its single-config Ninja
#      sub-build defaults to a debug-postfixed flatcc_d.exe that does not match the
#      IMPORTED_LOCATION ET declares (bin/flatcc.exe) -- even after fix 1 makes the byproduct
#      DECLARATION say .exe, the actual built file is still flatcc_d.exe without this.
#      flatbuffers_ep does not need this: its own comment notes the build forces Release
#      internally regardless of CMAKE_BUILD_TYPE. flatcc has no such forcing.
#
# Idempotent: safe to re-run against an already-patched tree, matching this repo's convention that
# the recipe never fails on already-patched sources. NOT gated on the host OS internally -- the
# caller (build-runtime.sh) decides WHEN to invoke this inside its own IS_WINDOWS check; this
# script always performs the edit when called, which is what makes it testable hermetically on
# Linux (test/patch_et_windows_byproducts.test.sh).
#
# Every check below verifies the POST-condition (not "did sed report success") because GNU sed
# exits 0 whether or not a pattern matched -- relying on sed's exit code is exactly how the old
# inline `sed ... || true` this replaces could drift silently.
#
# Usage: patch-et-windows-byproducts.sh <et-src>
set -euo pipefail
ET_SRC="${1:?usage: patch-et-windows-byproducts.sh <et-src>}"
[ -d "$ET_SRC" ] || { echo "patch-et-windows-byproducts.sh: no such tree: $ET_SRC" >&2; exit 1; }
TP="$ET_SRC/third-party/CMakeLists.txt"
[ -f "$TP" ] || { echo "patch-et-windows-byproducts.sh: missing $TP" >&2; exit 1; }

echo ">> patching flatc(c)_ep BUILD_BYPRODUCTS for WIN32 (.exe) -- upstream flatc/flatcc byproduct bug"
sed -i -E 's#(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc?)$#\1.exe#' "$TP"
grep -qE 'BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\.exe$' "$TP" || {
  echo "patch-et-windows-byproducts.sh: flatbuffers_ep BUILD_BYPRODUCTS anchor not found in $TP" >&2
  echo "  -- the ET pin probably moved; regenerate this script's pattern against the new pin." >&2
  exit 1; }
grep -qE 'BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc\.exe$' "$TP" || {
  echo "patch-et-windows-byproducts.sh: flatcc_ep BUILD_BYPRODUCTS anchor not found in $TP" >&2
  echo "  -- the ET pin probably moved; regenerate this script's pattern against the new pin." >&2
  exit 1; }

echo ">> patching flatcc_ep CMAKE_ARGS to force -DCMAKE_BUILD_TYPE=Release"
if ! grep -qF -- '-DCMAKE_BUILD_TYPE=Release' "$TP"; then
  sed -i 's#\(^    -DFLATCC_INSTALL=ON\)$#\1\n    -DCMAKE_BUILD_TYPE=Release#' "$TP"
fi
grep -qF -- '-DCMAKE_BUILD_TYPE=Release' "$TP" || {
  echo "patch-et-windows-byproducts.sh: -DFLATCC_INSTALL=ON anchor not found in $TP" >&2
  echo "  -- the ET pin probably moved; regenerate this script's pattern against the new pin." >&2
  exit 1; }
[ "$(grep -cF -- '-DCMAKE_BUILD_TYPE=Release' "$TP")" -eq 1 ] || {
  echo "patch-et-windows-byproducts.sh: -DCMAKE_BUILD_TYPE=Release appears more than once in $TP" >&2
  exit 1; }
