#!/usr/bin/env bash
# Hermetic coverage for the ET/XNNPACK workspace-size patch script. No ET checkout and no build:
# builds a synthetic git tree containing only the anchor text each patch targets. What matters here
# is the three behaviours the recipe depends on — applies once, is a no-op the second time, and
# fails LOUDLY when the anchor is gone (an ET bump that moved the code must break the build, not
# silently ship an unpatched runtime).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
script="$here/../scripts/patch-et-xnnpack-workspace.sh"

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

bash "$script" >/dev/null 2>&1
assert_eq "$?" "1" "missing argument is an error"
bash "$script" "$tmp/nonexistent" >/dev/null 2>&1
assert_eq "$?" "1" "nonexistent tree is an error"

exit "$ASSERT_FAILS"
