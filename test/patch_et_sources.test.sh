#!/usr/bin/env bash
# Hermetic coverage for the ET/XNNPACK workspace-size patch script. No ET checkout and no build:
# builds a synthetic git tree containing only the anchor text each patch targets. What matters here
# is the three behaviours the recipe depends on — applies once, is a no-op the second time, and
# fails LOUDLY when the anchor is gone (an ET bump that moved the code must break the build, not
# silently ship an unpatched runtime).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
script="$here/../scripts/patch-et-sources.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a miniature ET tree: outer git repo + an XNNPACK "submodule" that is just a nested repo.
mk_tree() { # <root>
  local r="$1"
  mkdir -p "$r/backends/xnnpack/runtime" \
           "$r/backends/xnnpack/third-party/XNNPACK/include" \
           "$r/backends/xnnpack/third-party/XNNPACK/src"
  cp "$here/fixtures/etpatch/xnnpack.h"              "$r/backends/xnnpack/third-party/XNNPACK/include/xnnpack.h"
  cp "$here/fixtures/etpatch/runtime.c"              "$r/backends/xnnpack/third-party/XNNPACK/src/runtime.c"
  cp "$here/fixtures/etpatch/XNNWorkspace.h"         "$r/backends/xnnpack/runtime/XNNWorkspace.h"
  cp "$here/fixtures/etpatch/XNNWorkspaceManager.h"  "$r/backends/xnnpack/runtime/XNNWorkspaceManager.h"
  cp "$here/fixtures/etpatch/XNNWorkspaceManager.cpp" "$r/backends/xnnpack/runtime/XNNWorkspaceManager.cpp"
  cp "$here/fixtures/etpatch/XNNPACKBackend.h"       "$r/backends/xnnpack/runtime/XNNPACKBackend.h"
  cp "$here/fixtures/etpatch/XnnpackBackendOptions.h"   "$r/backends/xnnpack/runtime/XnnpackBackendOptions.h"
  cp "$here/fixtures/etpatch/XnnpackBackendOptions.cpp" "$r/backends/xnnpack/runtime/XnnpackBackendOptions.cpp"
  mkdir -p "$r/backends/openvino/runtime"
  cp "$here/fixtures/etpatch/OpenvinoApi.h"          "$r/backends/openvino/runtime/OpenvinoApi.h"
  cp "$here/fixtures/etpatch/OpenvinoBackend.cpp"    "$r/backends/openvino/runtime/OpenvinoBackend.cpp"
  cp "$here/fixtures/etpatch/openvino-CMakeLists.txt" "$r/backends/openvino/CMakeLists.txt"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
  local x="$r/backends/xnnpack/third-party/XNNPACK"
  rm -rf "$x/.git"
  git -C "$x" init -q
  git -C "$x" add -A
  git -C "$x" -c user.email=t@t -c user.name=t commit -qm init
}

mk_tree "$tmp/et"
bash "$script" "$tmp/et" >"$tmp/out1" 2>&1
assert_eq "$?" "0" "first apply succeeds"
assert_contains "$(cat "$tmp/et/backends/xnnpack/third-party/XNNPACK/include/xnnpack.h")" \
  "xnn_get_workspace_size" "accessor declared after patching"
assert_contains "$(cat "$tmp/et/backends/xnnpack/runtime/XNNWorkspace.h")" \
  "size_t size()" "wrapper accessor patched in"
assert_contains "$(cat "$tmp/et/backends/xnnpack/runtime/XNNWorkspaceManager.h")" \
  "total_workspace_size" "manager sum patched in"
assert_contains "$(cat "$tmp/et/backends/xnnpack/runtime/XNNPACKBackend.h")" \
  "workspace_size_bytes" "option key patched in"
# The key is a published consumer contract (the engine hardcodes the string because
# XNNPACKBackend.h does not ship). A rename is breaking, so pin the exact spelling.
assert_contains "$(cat "$tmp/et/backends/xnnpack/runtime/XNNPACKBackend.h")" \
  'workspace_size_option_key[] = "workspace_size_bytes"' "option key spelling is exact"

# The OpenVINO/Windows patch. Assert on the three things that make it work, not merely that
# something changed: the Windows loader arm, the MSVC compile-option spelling, and the DLL name.
assert_contains "$(cat "$tmp/et/backends/openvino/runtime/OpenvinoApi.h")" \
  "LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR" "windows loader flag patched in"
# Both flags are load-bearing: SEARCH_DLL_LOAD_DIR alone switches the loader to the alternate
# search order and drops System32, where the MSVC runtime the OpenVINO DLLs import from lives.
# Verified empirically -- issue #37, comment 5372679998. Pin the pair so a "simplification" fails.
assert_contains "$(cat "$tmp/et/backends/openvino/runtime/OpenvinoApi.h")" \
  "LOAD_LIBRARY_SEARCH_DEFAULT_DIRS" "the second loader flag is present too"
assert_contains "$(cat "$tmp/et/backends/openvino/runtime/OpenvinoBackend.cpp")" \
  'kDefaultLibName = "openvino_c.dll"' "windows default library name patched in"
assert_contains "$(cat "$tmp/et/backends/openvino/runtime/OpenvinoApi.h")" \
  "FreeLibrary" "windows handle deleter patched in"
assert_contains "$(cat "$tmp/et/backends/openvino/CMakeLists.txt")" \
  "/EHsc /GR" "MSVC compile options patched in"

# The Linux path must be untouched. The patch is a no-op there by construction, and this is the
# assertion that keeps it that way: a future edit that drops an #ifdef would break Linux silently.
assert_contains "$(cat "$tmp/et/backends/openvino/runtime/OpenvinoBackend.cpp")" \
  'kDefaultLibName = "libopenvino_c.so"' "POSIX default library name survives"
assert_contains "$(cat "$tmp/et/backends/openvino/CMakeLists.txt")" \
  "-frtti -fexceptions" "GCC/Clang compile options survive"

# Idempotency is not a nicety: build-runtime.sh re-runs against a persisted --build-dir and a
# caller-supplied checkout that may already be patched from a previous run.
bash "$script" "$tmp/et" >"$tmp/out2" 2>&1
assert_eq "$?" "0" "second apply succeeds (idempotent)"
assert_contains "$(cat "$tmp/out2")" "already patched" "second apply reports already-patched"
assert_eq "$(grep -c 'xnn_get_workspace_size' "$tmp/et/backends/xnnpack/third-party/XNNPACK/include/xnnpack.h")" \
  "1" "accessor declared exactly once (not applied twice)"

# The anchor is gone — an ET bump moved the code. This MUST fail.
mk_tree "$tmp/drift"
: > "$tmp/drift/backends/xnnpack/third-party/XNNPACK/include/xnnpack.h"
git -C "$tmp/drift/backends/xnnpack/third-party/XNNPACK" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift" 2>&1)"
assert_eq "$?" "1" "drifted anchor fails"
assert_contains "$out" "does not apply" "drift failure explains itself"

mk_tree "$tmp/drift2"
: > "$tmp/drift2/backends/xnnpack/runtime/XNNWorkspaceManager.cpp"
git -C "$tmp/drift2" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift2" 2>&1)"
assert_eq "$?" "1" "drifted ET-side anchor fails"

mk_tree "$tmp/drift3"
: > "$tmp/drift3/backends/openvino/runtime/OpenvinoBackend.cpp"
git -C "$tmp/drift3" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift3" 2>&1)"
assert_eq "$?" "1" "drifted OpenVINO anchor fails"
assert_contains "$out" "does not apply" "OpenVINO drift failure explains itself"

bash "$script" >/dev/null 2>&1
assert_eq "$?" "1" "missing argument is an error"
bash "$script" "$tmp/nonexistent" >/dev/null 2>&1
assert_eq "$?" "1" "nonexistent tree is an error"

exit "$ASSERT_FAILS"
