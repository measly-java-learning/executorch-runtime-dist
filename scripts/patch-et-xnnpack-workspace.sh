#!/usr/bin/env bash
# Apply the workspace-size patches to a caller-supplied ExecuTorch checkout.
#
# These expose the XNNPACK delegate's arena size through the backend-options API so consumers can
# account for it in host-side native memory reporting. Upstream XNNPACK has no size accessor and
# ExecuTorch surfaces none, so this is a vendored patch set. See
# docs/superpowers/specs/2026-08-14-xnnpack-workspace-size-design.md.
#
# Idempotent by contract: build-runtime.sh re-runs against a persisted build tree and a checkout
# that may already be patched. A patch that is already applied is success; a patch that does NOT
# apply is a HARD ERROR, never a skip. A silently unapplied patch ships a runtime whose consumer
# contract is quietly broken, which is the exact failure the post-build nm guard and the gate's
# behavioural test exist to catch — but the recipe should fail first, and more legibly.
#
# Usage: patch-et-xnnpack-workspace.sh <et-src>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ET_SRC="${1:?usage: patch-et-xnnpack-workspace.sh <et-src>}"
[ -d "$ET_SRC" ] || { echo "patch-et-xnnpack-workspace.sh: no such tree: $ET_SRC" >&2; exit 1; }

XNN_DIR="$ET_SRC/backends/xnnpack/third-party/XNNPACK"

# apply_patch <target-dir> <patch-file>
# git apply --reverse --check succeeds only when the patch is ALREADY applied, which is an exact
# idempotency test — far more reliable than grepping for a marker string.
apply_patch() {
  local dir="$1" patch="$2" name
  name="$(basename "$patch")"
  [ -d "$dir" ] || { echo "   FAIL: target dir missing: $dir" >&2; return 1; }
  [ -f "$patch" ] || { echo "   FAIL: patch missing: $patch" >&2; return 1; }
  if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo "   $name: already patched"
    return 0
  fi
  if git -C "$dir" apply --check "$patch" 2>/dev/null; then
    git -C "$dir" apply "$patch"
    echo "   $name: applied"
    return 0
  fi
  echo "   FAIL: $name does not apply to $dir" >&2
  echo "   The ExecuTorch pin probably moved and the anchor text with it. Regenerate the patch" >&2
  echo "   against the new pin and refresh test/fixtures/etpatch/ in the same commit." >&2
  return 1
}

echo ">> patching ET/XNNPACK for workspace-size accounting"
apply_patch "$XNN_DIR"  "$ROOT/patches/xnnpack-workspace-size-accessor.patch"
apply_patch "$ET_SRC" "$ROOT/patches/et-xnnpack-workspace-size.patch"
