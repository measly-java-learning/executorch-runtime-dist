# XNNPACK Workspace Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a consumer read the XNNPACK delegate's workspace arena size in bytes at runtime, through the already-installed backend-options API, so host-side native-memory reporting can be exact.

**Architecture:** Four additive patches to the caller-supplied ExecuTorch/XNNPACK source tree, applied by a new idempotent patch script that `build-runtime.sh` invokes during its existing patch phase. The value surfaces through `runtime::get_option("XnnpackBackend", …)`, which already ships — no new installed headers. A post-build `nm` guard plus a behavioural gate test prove the patches survived compilation.

**Tech Stack:** bash (`set -euo pipefail`), C (vendored XNNPACK), C++17 (ExecuTorch runtime), CMake, Python (fixture emission via torch/executorch AOT), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-14-xnnpack-workspace-size-design.md`

## Global Constraints

- **Option key string:** `workspace_size_bytes` — a consumer contract; the engine hardcodes it because `XNNPACKBackend.h` does not ship.
- **Backend name string:** `XnnpackBackend` (existing; `xnnpack_backend_key` in `backends/xnnpack/runtime/XNNPACKBackend.h`).
- **Value type:** `int` bytes, **saturating at `INT_MAX`**. Never wrap. `OptionValue` is `std::variant<bool, int, std::array<char, 256>>` and must NOT be modified — adding any 64-bit alternative raises its alignment from 4 to 8 and breaks the installed ABI (see the spec's rejected-alternative section).
- **Read-only:** `set_option` on this key returns `Error::InvalidArgument`.
- **Lazy init:** the size is `0` before any XNNPACK-delegated method loads. This is correct behaviour and must be asserted, not worked around.
- **Sharing mode:** pin `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON`.
- **Patch idempotency:** every patch step must be a no-op on an already-patched tree and a **hard error** on a failed match. Never a silent skip.
- **Shell:** `set -euo pipefail`; `grep` returning 1 on no-match must be guarded with `|| true` (existing repo convention).
- **ET version under test:** `v1.3.1` (commit `e2f18eb`).
- Do not modify `docs/superpowers/specs/` or `spike/` — those are dated records.

---

### Task 1: Pin the XNNPACK shared-workspace flag

Independent of everything else and hermetically testable. Do it first so the rest of the work builds against the mode it assumes.

**Files:**
- Modify: `scripts/lib/cmakeflags.sh:15`
- Test: `test/lib_cmakeflags.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `common_cmake_flags <platform>` now includes `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON` on every platform.

- [ ] **Step 1: Write the failing test**

Append to `test/lib_cmakeflags.test.sh`, before the final `exit "$ASSERT_FAILS"`:

```bash
# The workspace-size accessor reports ONE process-wide arena, which is only true under Global
# sharing. Upstream defaults this ON (tools/cmake/preset/default.cmake), but the comment directly
# above that default says "Keeping this OFF by default" — prose and value disagree, so the default
# is one upstream edit away from flipping. Pin it rather than inherit it. Platform-independent:
# unlike OpenVINO this is not an x86-64-only concern.
for p in linux-x86_64 linux-aarch64 windows-x86_64 windows-x86_64-static; do
  assert_contains "$(common_cmake_flags "$p")" "-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON" \
    "shared workspace pinned on $p"
done
assert_contains "$(effective_cmake_flags linux-x86_64 logging)" \
  "-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON" "effective flags carry the workspace pin"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_cmakeflags.test.sh`
Expected: FAIL — `shared workspace pinned on linux-x86_64`, missing `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON`.

- [ ] **Step 3: Add the flag**

In `scripts/lib/cmakeflags.sh`, extend the `local flags=` string in `common_cmake_flags` with ` -DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON` (append inside the single quotes, before the closing quote). Add above the function, after the existing OpenVINO paragraph:

```bash
# EXECUTORCH_XNNPACK_SHARED_WORKSPACE is pinned, not inherited. It controls whether XNNPACK delegate
# instances share one workspace arena; the workspace_size_bytes backend option reports a single
# process-wide figure, which is only meaningful under Global sharing. Upstream's default is ON but
# the comment above it says the opposite, so the value is one edit from flipping and taking the
# meaning of a published consumer contract with it.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_cmakeflags.test.sh && bash test/run.sh`
Expected: both PASS. `test/buildinfo.test.sh` and `test/build_cli.test.sh` also read these flags — confirm they stay green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/cmakeflags.sh test/lib_cmakeflags.test.sh
git commit -m "build: pin EXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON"
```

---

### Task 2: Patch script skeleton + XNNPACK accessor (patch A)

**Files:**
- Create: `scripts/patch-et-xnnpack-workspace.sh` (mode 100755)
- Create: `patches/xnnpack-workspace-size-accessor.patch`
- Create: `test/patch_et_xnnpack_workspace.test.sh`
- Modify: `test/exec_perms.test.sh:11-12`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/patch-et-xnnpack-workspace.sh <et-src>` — applies all workspace-size patches to a checked-out ET tree. Exit 0 on applied-or-already-applied, 1 on any failure. Invoked by `build-runtime.sh` in Task 4.

**Why `git apply` and not `sed`:** the existing patch phase uses `sed` one-liners for single-token substitutions. These patches insert whole functions, which `sed` cannot do legibly or verify. `git apply --reverse --check` gives exact idempotency detection for free, and ET arrives as a git checkout with submodules (contract C8), so `git` is always available. The XNNPACK patch targets the **submodule**, so it is applied with `git -C <et-src>/backends/xnnpack/third-party/XNNPACK`.

- [ ] **Step 1: Write the failing test**

Create `test/patch_et_xnnpack_workspace.test.sh`:

```bash
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
```

- [ ] **Step 2: Create the test fixture tree**

Copy the eight real files from a checked-out ET `v1.3.1` into `test/fixtures/etpatch/` so the hermetic test patches real anchor text rather than a paraphrase:

```bash
mkdir -p test/fixtures/etpatch
ET=/path/to/executorch     # a v1.3.1 checkout with submodules
for f in backends/xnnpack/runtime/XNNWorkspace.h \
         backends/xnnpack/runtime/XNNWorkspaceManager.h \
         backends/xnnpack/runtime/XNNWorkspaceManager.cpp \
         backends/xnnpack/runtime/XNNPACKBackend.h \
         backends/xnnpack/runtime/XnnpackBackendOptions.h \
         backends/xnnpack/runtime/XnnpackBackendOptions.cpp; do
  cp "$ET/$f" test/fixtures/etpatch/
done
cp "$ET/backends/xnnpack/third-party/XNNPACK/include/xnnpack.h" test/fixtures/etpatch/
cp "$ET/backends/xnnpack/third-party/XNNPACK/src/runtime.c"     test/fixtures/etpatch/
```

These are BSD-licensed Meta/Google sources used as test fixtures. Add `test/fixtures/etpatch/README.md`:

```markdown
Verbatim copies of ExecuTorch v1.3.1 (commit e2f18eb) and its vendored XNNPACK sources, used as
hermetic fixtures for test/patch_et_xnnpack_workspace.test.sh. They exist so the patch test runs
against the real anchor text without needing a multi-GB ET checkout.

Refresh these when the ET pin moves, in the same commit that refreshes patches/*.patch — a stale
fixture makes the patch test pass while the real build fails.
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash test/patch_et_xnnpack_workspace.test.sh`
Expected: FAIL — `scripts/patch-et-xnnpack-workspace.sh` does not exist, so every assertion fails.

- [ ] **Step 4: Generate the XNNPACK accessor patch**

Work in a real ET checkout, then export the diff. In `backends/xnnpack/third-party/XNNPACK/include/xnnpack.h`, immediately after the `xnn_release_workspace` declaration (line ~2405, right before the `/// Runtime is a combination of…` comment), insert:

```c
/// Get the current size, in bytes, of the memory arena allocated by a workspace.
/// The arena is grown as needed by xnn_create_runtime_v4 and is never shrunk, so this is a
/// high-water mark. Returns 0 for a NULL workspace or one that has not yet been grown.
/// NOTE: not upstream. Added by measly-java-learning/executorch-runtime-dist to support host-side
/// native memory accounting. See docs/xnnpack-workspace-size-consumer.md.
size_t xnn_get_workspace_size(xnn_workspace_t workspace);
```

In `src/runtime.c`, immediately after the closing brace of `xnn_release_workspace` (line ~128), insert:

```c
size_t xnn_get_workspace_size(xnn_workspace_t workspace)
{
  if (workspace == NULL) {
    return 0;
  }
  return workspace->size;
}
```

Then export:

```bash
mkdir -p patches
git -C "$ET/backends/xnnpack/third-party/XNNPACK" diff \
  > patches/xnnpack-workspace-size-accessor.patch
git -C "$ET/backends/xnnpack/third-party/XNNPACK" checkout -- .
```

- [ ] **Step 5: Write the patch script**

Create `scripts/patch-et-xnnpack-workspace.sh`:

```bash
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
```

- [ ] **Step 6: Run test to verify it passes**

Run: `chmod +x scripts/patch-et-xnnpack-workspace.sh && bash test/patch_et_xnnpack_workspace.test.sh`
Expected: PASS.

- [ ] **Step 7: Add the script to the executable-permissions test**

In `test/exec_perms.test.sh`, add `scripts/patch-et-xnnpack-workspace.sh` to the `for s in …` list. It is invoked by path from `build-runtime.sh`, so a 100644 commit would break a fresh CI checkout.

- [ ] **Step 8: Run the full suite and commit**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

```bash
git add scripts/patch-et-xnnpack-workspace.sh patches/ test/patch_et_xnnpack_workspace.test.sh \
        test/fixtures/etpatch/ test/exec_perms.test.sh
git commit -m "build: add idempotent ET patch script + XNNPACK workspace-size accessor"
```

---

### Task 3: ExecuTorch runtime patches — wrapper, manager sum, option key

All three land together: the option key (D) calls the manager sum (C), which calls the wrapper (B). Splitting them would leave the tree in a state no test can exercise.

**Files:**
- Create: `patches/et-xnnpack-workspace-size.patch`
- Modify: `scripts/patch-et-xnnpack-workspace.sh` (add the second `apply_patch` call)
- Test: `test/patch_et_xnnpack_workspace.test.sh`

**Interfaces:**
- Consumes: `xnn_get_workspace_size(xnn_workspace_t)` from Task 2.
- Produces, inside the patched ET tree:
  - `size_t XNNWorkspace::size()` — synchronized read.
  - `size_t XNNWorkspaceManager::total_workspace_size() const` — sum over live workspaces.
  - option key `workspace_size_bytes` readable via `runtime::get_option("XnnpackBackend", …)` as `int`.

- [ ] **Step 1: Extend the test**

In `test/patch_et_xnnpack_workspace.test.sh`, after the existing accessor assertion, add:

```bash
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
```

And extend the drift case so a moved ET-side anchor fails too:

```bash
mk_tree "$tmp/drift2"
: > "$tmp/drift2/backends/xnnpack/runtime/XNNWorkspaceManager.cpp"
git -C "$tmp/drift2" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift2" 2>&1)"
assert_eq "$?" "1" "drifted ET-side anchor fails"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/patch_et_xnnpack_workspace.test.sh`
Expected: FAIL — `wrapper accessor patched in`, `manager sum patched in`, `option key patched in`.

- [ ] **Step 3: Edit the ET tree — wrapper (patch B)**

In `backends/xnnpack/runtime/XNNWorkspace.h`, after the `id()` method (before `disable_locking()`), insert:

```cpp
  // Returns the current size in bytes of the underlying arena. Acquires the workspace lock: the
  // arena is grown by xnn_create_runtime_v4 during a concurrent delegate init, so an unlocked read
  // could tear. Not upstream — see docs/xnnpack-workspace-size-consumer.md.
  size_t size() {
    auto [lock, workspace] = acquire();
    return xnn_get_workspace_size(workspace);
  }
```

- [ ] **Step 4: Edit the ET tree — manager sum (patch C)**

In `XNNWorkspaceManager.h`, after the two `get_or_create_workspace` declarations, insert:

```cpp
  /**
   * Total size in bytes of all live XNNPACK workspaces.
   *
   * Sums workspaces this manager still tracks. Under Global sharing (the mode this build pins)
   * there is exactly one. NOTE: workspaces created under WorkspaceSharingMode::Disabled are
   * returned to the caller WITHOUT being tracked here, so they are not counted — under Disabled
   * this returns 0. That is why the build pins EXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON.
   *
   * @return Total live workspace bytes, saturating at SIZE_MAX.
   */
  size_t total_workspace_size() const;
```

In `XNNWorkspaceManager.cpp`, append inside the namespace:

```cpp
size_t XNNWorkspaceManager::total_workspace_size() const {
  std::scoped_lock<std::mutex> lock(workspace_meta_mutex_);
  size_t total = 0;

  if (auto live = global_workspace_.lock()) {
    total += live->size();
  }
  // Sum the per-model map too, not just the global slot. Under Global sharing this loop is empty,
  // but reading only the global workspace would silently under-report if the mode ever changed —
  // and the mode default is one upstream edit from flipping.
  for (const auto& entry : model_workspaces_) {
    if (auto live = entry.second.lock()) {
      total += live->size();
    }
  }
  return total;
}
```

- [ ] **Step 5: Edit the ET tree — option key (patch D)**

In `XNNPACKBackend.h`, after `weight_cache_option_key`, insert:

```cpp
/// The key for the read-only workspace size option. Returns the total size in bytes of all live
/// XNNPACK workspaces as an int, saturating at INT_MAX. Reads 0 until the first XNNPACK-delegated
/// method is loaded, because the arena is created lazily during delegate init. set_option on this
/// key returns InvalidArgument. Not upstream — added for host-side native memory accounting.
const char workspace_size_option_key[] = "workspace_size_bytes";
```

In `XnnpackBackendOptions.h`, no member is needed — the value is computed. In `XnnpackBackendOptions.cpp`, extend `get_option`'s chain before the closing brace:

```cpp
  } else if (strcmp(option.key, workspace_size_option_key) == 0) {
    const size_t total = workspace_manager_.total_workspace_size();
    // Saturate rather than narrow. OptionValue has no 64-bit alternative and adding one would
    // change the alignment of an INSTALLED type (see the spec). A clamped byte count degrades a
    // memory report; a wrapped negative one corrupts it.
    option.value = static_cast<int>(
        total > static_cast<size_t>(INT_MAX) ? INT_MAX : total);
```

And in `set_option`, before the final closing brace, reject writes explicitly:

```cpp
  } else if (strcmp(option.key, workspace_size_option_key) == 0) {
    // The existing chain ends in an implicit no-op success, so without this a write would look
    // like it worked. This option is derived state and read-only.
    ET_LOG(Error, "XNNPACK workspace_size_bytes is read-only.");
    return Error::InvalidArgument;
```

Add `#include <climits>` to `XnnpackBackendOptions.cpp` for `INT_MAX`.

- [ ] **Step 6: Export the patch and wire it up**

```bash
git -C "$ET" diff -- backends/xnnpack/runtime > patches/et-xnnpack-workspace-size.patch
git -C "$ET" checkout -- backends/xnnpack/runtime
```

Add to `scripts/patch-et-xnnpack-workspace.sh`, after the existing call:

```bash
apply_patch "$ET_SRC" "$ROOT/patches/et-xnnpack-workspace-size.patch"
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bash test/patch_et_xnnpack_workspace.test.sh && bash test/run.sh`
Expected: both PASS.

- [ ] **Step 8: Commit**

```bash
git add patches/ scripts/patch-et-xnnpack-workspace.sh test/patch_et_xnnpack_workspace.test.sh
git commit -m "build: patch workspace-size accessor through to the backend option"
```

---

### Task 4: Invoke the patches from the recipe + post-build nm guard

**Files:**
- Modify: `build-runtime.sh` (patch phase ~line 187-199; post-install phase after `cmake --install`)
- Test: `test/build_cli.test.sh`

**Interfaces:**
- Consumes: `scripts/patch-et-xnnpack-workspace.sh <et-src>` from Tasks 2–3.
- Produces: every built prefix contains `libxnnpack_backend.a` exporting `xnn_get_workspace_size`; the build fails otherwise.

- [ ] **Step 1: Invoke the patch script**

In `build-runtime.sh`, immediately after the existing `flatc_ep` Windows patch block and before `echo ">> installing python deps"`, add:

```bash
# Workspace-size accessor patches (see scripts/patch-et-xnnpack-workspace.sh). Applied here, with
# the other source patches, because they must land before configure. Not guarded by platform:
# XNNPACK builds on every platform we ship.
"$HERE/scripts/patch-et-xnnpack-workspace.sh" "$ET_SRC"
```

Confirm `HERE` is the variable `build-runtime.sh` uses for its own directory; if it uses a different name, use that one.

- [ ] **Step 2: Add the post-build nm guard**

After the install + relocatability repair, before license passthrough, add:

```bash
# Prove the workspace-size patch survived compilation, not merely that a file was edited. The
# accessor is a published consumer contract; a future ET bump that drops the patch must fail the
# build here rather than regress a consumer's memory accounting silently.
# Windows: MSVC has no nm, and the archive is a .lib — skip, the Linux gate covers the contract.
if [ "$IS_WINDOWS" -eq 0 ]; then
  echo ">> verifying xnn_get_workspace_size is present in the installed XNNPACK backend"
  _xnnlib="$PREFIX/lib/libxnnpack_backend.a"
  [ -f "$_xnnlib" ] || { echo "   FAIL: $_xnnlib missing" >&2; exit 1; }
  # `|| true`: grep exits 1 on no-match, which would abort under set -e before the message below.
  if [ -z "$(nm -g --defined-only "$_xnnlib" 2>/dev/null | grep 'xnn_get_workspace_size' || true)" ]; then
    echo "   FAIL: xnn_get_workspace_size not found in $_xnnlib" >&2
    echo "   The patch applied but the symbol did not survive the build. Check that the ET pin" >&2
    echo "   still compiles src/runtime.c into the xnnpack backend archive." >&2
    exit 1
  fi
  echo "   ok: accessor present"
fi
```

Confirm `IS_WINDOWS` is the existing variable name (it is used by the `flatc_ep` patch block).

- [ ] **Step 3: Verify the CLI paths still work**

Run: `bash test/build_cli.test.sh && ./build-runtime.sh --print-flags --variant logging`
Expected: PASS, and the flag string includes `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON`. `--print-flags` must still exit before any patching or building happens — if the patch invocation runs on the `--print-flags` path, move it below that early exit.

- [ ] **Step 4: Run the full suite and commit**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

```bash
git add build-runtime.sh
git commit -m "build: apply workspace-size patches and guard the built symbol"
```

---

### Task 5: XNNPACK-delegated fixture emitter

The LSTM fixture lowers to the `etnp::lstm` custom op with no `XnnpackPartitioner`, so its *delegate* workspace is 0 and a test built on it would pass against a completely broken accessor. This task mints a genuinely delegated `.pte`.

**Files:**
- Create: `scripts/emit-xnnpack-fixtures.py`
- Test: `test/xnnpack_fixtures.test.sh`
- Modify: `test/exec_perms.test.sh` — **no change**; this is invoked as `python scripts/…`, matching `scripts/emit-openvino-fixtures.py`, which is not in that list.

**Interfaces:**
- Consumes: nothing.
- Produces: `python scripts/emit-xnnpack-fixtures.py <outdir>` writes `xnnpack_tiny.pte`, `in.bin`, `out.bin`, `shape` (`XNN_IN=8` / `XNN_OUT=8`).

- [ ] **Step 1: Write the emitter**

Create `scripts/emit-xnnpack-fixtures.py`, modelled on `scripts/emit-openvino-fixtures.py`:

```python
"""Mint an XNNPACK-DELEGATED fixture for the workspace-size gate: a trivial model plus its golden
eager output. Writes xnnpack_tiny.pte, in.bin, out.bin, and a shape file.

This exists because the LSTM fixture is NOT XNNPACK-delegated -- it lowers to the etnp::lstm custom
op, whose XNNPACK use is inside our own kernel rather than the delegate. Its delegate workspace
reads 0, so a workspace-size test built on it would pass against a completely broken accessor.

Requires the AOT venv: torch and the executorch python package built from the SAME pinned ET source.
"""
import pathlib
import sys

DIM = 8


def main(outdir: pathlib.Path) -> None:
    import torch
    from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
    from executorch.exir import to_edge_transform_and_lower

    class Tiny(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.lin = torch.nn.Linear(DIM, DIM)

        def forward(self, x):
            return torch.relu(self.lin(x))

    # Fixed seed: the fixture must be reproducible across releases for the same versions.
    torch.manual_seed(0)
    model = Tiny().eval()
    example = (torch.randn(1, DIM),)

    with torch.no_grad():
        golden = model(*example)

    exported = torch.export.export(model, example)
    lowered = to_edge_transform_and_lower(exported, partitioner=[XnnpackPartitioner()])
    pte = lowered.to_executorch().buffer

    # Prove the delegate was actually applied. Without this, a partitioner that silently declined
    # every node would still produce a valid .pte -- one that allocates no workspace at all, which
    # is precisely the vacuous pass this fixture exists to prevent.
    if b"XnnpackBackend" not in pte:
        raise SystemExit("emit-xnnpack-fixtures: .pte contains no XnnpackBackend delegate")

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "xnnpack_tiny.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(example[0].contiguous().numpy().tobytes())
    (outdir / "out.bin").write_bytes(golden.contiguous().numpy().tobytes())
    (outdir / "shape").write_text(f"XNN_IN={DIM}\nXNN_OUT={DIM}\n")
    print(f"emit-xnnpack-fixtures: wrote {len(pte)} byte .pte to {outdir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit-xnnpack-fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
```

Verify the partitioner import path against the pinned ET source before committing:
`grep -rn "class XnnpackPartitioner" $ET/backends/xnnpack/partition/`.

- [ ] **Step 2: Write the hermetic test**

Create `test/xnnpack_fixtures.test.sh`. Torch is not available in the hermetic suite, so this checks the emitter's contract statically — the same approach `test/openvino_fixtures.test.sh` takes:

```bash
#!/usr/bin/env bash
# The emitter needs torch + executorch, which the hermetic suite does not have. What IS checkable
# without them is the contract that makes the fixture worth having: that it asserts the delegate
# was applied, and that its member names match what the gate script reads.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
src="$(cat "$here/../scripts/emit-xnnpack-fixtures.py")"

assert_contains "$src" 'XnnpackPartitioner' "uses the XNNPACK partitioner"
# Without this guard a partitioner that declined every node yields a valid .pte that allocates no
# workspace -- the gate would then pass against a completely broken accessor.
assert_contains "$src" 'b"XnnpackBackend" not in pte' "asserts the delegate was actually applied"
for m in 'xnnpack_tiny.pte' 'in.bin' 'out.bin' 'shape' 'XNN_IN=' 'XNN_OUT='; do
  assert_contains "$src" "$m" "emits $m"
done
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$here/../scripts/emit-xnnpack-fixtures.py"
assert_eq "$?" "0" "emitter parses as python"
exit "$ASSERT_FAILS"
```

- [ ] **Step 3: Run the tests**

Run: `bash test/xnnpack_fixtures.test.sh && bash test/run.sh`
Expected: both PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/emit-xnnpack-fixtures.py test/xnnpack_fixtures.test.sh
git commit -m "test: add an XNNPACK-delegated fixture emitter"
```

---

### Task 6: Behavioural probe + gate script

**Files:**
- Create: `test/xnnpack_workspace/workspace_probe.cpp`
- Create: `test/xnnpack_workspace/CMakeLists.txt`
- Create: `test/xnnpack_workspace_run.sh`
- Create: `test/xnnpack_workspace_run.test.sh`

**Interfaces:**
- Consumes: the patched prefix from Task 4; the fixture from Task 5.
- Produces: `bash test/xnnpack_workspace_run.sh <et-prefix> <fixture-dir>` — exit 0 only if the option reads 0 before load and > 0 after.

- [ ] **Step 1: Write the probe**

Create `test/xnnpack_workspace/workspace_probe.cpp`:

```cpp
// Proves the workspace-size backend option works end to end against a BUILT prefix: reads 0 before
// any model loads (the arena is created lazily during delegate init), and > 0 after loading an
// XNNPACK-delegated .pte. The before-reading is not decoration — without it a stub that always
// returned a constant would pass.
//   workspace_probe <model.pte> <in.bin>      (dims via XNN_IN)
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

#include <executorch/extension/module/module.h>
#include <executorch/extension/tensor/tensor_ptr.h>
#include <executorch/runtime/backend/interface.h>
#include <executorch/runtime/backend/options.h>

using executorch::extension::Module;
using executorch::extension::make_tensor_ptr;
using executorch::runtime::BackendOption;
using executorch::runtime::EValue;
using executorch::runtime::Span;

// Hardcoded, not included: XNNPACKBackend.h is not an installed header, so a consumer names these
// by string exactly as this probe does. That makes the probe a real test of the published contract.
static constexpr const char* kBackend = "XnnpackBackend";
static constexpr const char* kKey = "workspace_size_bytes";

static int read_workspace_size() {
  BackendOption opt{};
  std::snprintf(opt.key, sizeof(opt.key), "%s", kKey);
  Span<BackendOption> span(&opt, 1);
  const auto err = executorch::ET_RUNTIME_NAMESPACE::get_option(kBackend, span);
  if (err != executorch::runtime::Error::Ok) {
    std::fprintf(stderr, "get_option failed (error %d)\n", static_cast<int>(err));
    std::exit(1);
  }
  auto* val = std::get_if<int>(&opt.value);
  if (!val) {
    std::fprintf(stderr, "workspace_size_bytes is not an int\n");
    std::exit(1);
  }
  return *val;
}

int main(int argc, char** argv) {
  if (argc != 3) { std::fprintf(stderr, "usage: workspace_probe model in.bin\n"); return 2; }
  const char* dim_env = std::getenv("XNN_IN");
  if (!dim_env) { std::fprintf(stderr, "env XNN_IN not set\n"); return 2; }
  const int n_in = std::atoi(dim_env);

  const int before = read_workspace_size();
  std::printf("workspace before load: %d\n", before);
  if (before != 0) {
    std::fprintf(stderr, "expected 0 before any model loads, got %d\n", before);
    return 1;
  }

  std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
  const std::streamsize n = f.tellg(); f.seekg(0);
  std::vector<float> in(static_cast<size_t>(n) / sizeof(float));
  f.read(reinterpret_cast<char*>(in.data()), n);
  if (in.size() != static_cast<size_t>(n_in)) {
    std::fprintf(stderr, "in.bin has %zu floats, XNN_IN=%d\n", in.size(), n_in);
    return 2;
  }

  auto t_in = make_tensor_ptr({1, n_in}, in.data());
  Module module(argv[1]);
  std::vector<EValue> inputs = {*t_in};
  const auto res = module.forward(inputs);
  if (!res.ok()) {
    std::fprintf(stderr, "forward failed (error %d)\n", static_cast<int>(res.error()));
    return 1;
  }

  const int after = read_workspace_size();
  std::printf("workspace after load: %d\n", after);
  if (after <= 0) {
    std::fprintf(stderr, "expected a non-zero workspace after loading a delegated model\n");
    return 1;
  }
  std::printf("PROBE PASS: workspace grew from 0 to %d bytes\n", after);
  return 0;
}
```

- [ ] **Step 2: Write the probe's CMakeLists**

Create `test/xnnpack_workspace/CMakeLists.txt`:

```cmake
# Builds workspace_probe the way a downstream consumer links the shipped tarball.
cmake_minimum_required(VERSION 3.24)
project(etnp_workspace_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(executorch CONFIG REQUIRED)

add_executable(workspace_probe workspace_probe.cpp)
# executorch_backends carries xnnpack_backend with --whole-archive, which is what registers the
# delegate. Without it the .pte loads no XnnpackBackend and the workspace never allocates.
target_link_libraries(workspace_probe PRIVATE
  executorch executorch_backends optimized_native_cpu_ops_lib
  extension_module_static extension_data_loader extension_tensor)
```

- [ ] **Step 3: Write the gate script**

Create `test/xnnpack_workspace_run.sh`:

```bash
#!/usr/bin/env bash
# Behavioural gate for the workspace-size backend option. Builds a consumer-shaped probe against a
# built prefix and runs it over an XNNPACK-delegated fixture, asserting the option reads 0 before
# any model loads and > 0 after.
#
# This is the check that protects the consumer contract on a future ET bump. The nm guard in
# build-runtime.sh proves the symbol exists; only this proves the value is reachable and real.
#
# Usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>
set -euo pipefail
PREFIX="${1:?usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>}"
FIXTURES="${2:?usage: xnnpack_workspace_run.sh <et-prefix> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# `if`, not `[ -f ... ] && source`: under `set -e` a false `&&` list at statement level aborts the
# script, so the short form would exit before validation anywhere the toolset is absent.
if [ -f /opt/rh/gcc-toolset-14/enable ]; then
  source /opt/rh/gcc-toolset-14/enable
fi

PREFIX="$(cd "$PREFIX" && pwd)"
FIXTURES="$(cd "$FIXTURES" && pwd)"

pte="$FIXTURES/xnnpack_tiny.pte"
inbin="$FIXTURES/in.bin"
shapefile="$FIXTURES/shape"
for f in "$pte" "$inbin" "$shapefile"; do
  [ -e "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# Parsed, not sourced: `shape` is a generated fixture member, and sourcing a file to get one integer
# is a habit worth not forming.
xnn_in="$(sed -n 's/^XNN_IN=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
if [ -z "$xnn_in" ]; then
  echo "FAIL: could not read XNN_IN from $shapefile" >&2
  cat "$shapefile" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
echo "== Building workspace_probe against $PREFIX =="
gen=()
if command -v ninja >/dev/null 2>&1; then gen=(-G Ninja); fi
cmake -B "$SCRATCH/build" -S "$HERE/xnnpack_workspace" "${gen[@]}" -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$SCRATCH/build" --target workspace_probe

echo "== Running the probe =="
XNN_IN="$xnn_in" "$SCRATCH/build/workspace_probe" "$pte" "$inbin"

echo "GATE PASS: workspace_size_bytes is reachable and reports a live arena"
```

- [ ] **Step 4: Write the hermetic test**

Create `test/xnnpack_workspace_run.test.sh`:

```bash
#!/usr/bin/env bash
# Hermetic coverage for the workspace gate: input validation (the part that decides whether a
# missing input fails loudly or silently), plus the contract assertions in the probe source that a
# build-requiring test cannot check here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
gate="$here/xnnpack_workspace_run.sh"
probe="$(cat "$here/xnnpack_workspace/workspace_probe.cpp")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash "$gate" >/dev/null 2>&1
assert_eq "$?" "1" "gate: no arguments is a usage error"

mkdir -p "$tmp/prefix" "$tmp/fx"
: > "$tmp/fx/xnnpack_tiny.pte"
: > "$tmp/fx/in.bin"
printf 'XNN_IN=8\nXNN_OUT=8\n' > "$tmp/fx/shape"

for missing in xnnpack_tiny.pte in.bin shape; do
  mv "$tmp/fx/$missing" "$tmp/$missing.stash"
  out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
  rc=$?
  mv "$tmp/$missing.stash" "$tmp/fx/$missing"
  assert_eq "$rc" "1" "gate: missing $missing fails"
  assert_contains "$out" "$missing missing" "gate: names the missing member ($missing)"
done

printf 'XNN_IN=\nXNN_OUT=8\n' > "$tmp/fx/shape"
out="$(bash "$gate" "$tmp/prefix" "$tmp/fx" 2>&1)"
assert_eq "$?" "1" "gate: unparseable shape file fails"
assert_contains "$out" "XNN_IN" "gate: explains the shape-file failure"

# The probe must name the backend and key by STRING. If it ever gained an include of
# XNNPACKBackend.h it would stop testing the published contract, because that header is not shipped.
assert_contains "$probe" '"XnnpackBackend"' "probe names the backend by string"
assert_contains "$probe" '"workspace_size_bytes"' "probe names the key by string"
# Match an actual #include DIRECTIVE, not the bare filename: the probe's own comment explains that
# the header is deliberately not included, so a substring test would fire on the documentation of
# the very property it is checking. (No `|| true` guard needed — grep's exit 1 is the passing case
# and a command in an `if` condition never triggers `set -e`.)
if printf '%s\n' "$probe" | grep -qE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"].*XNNPACKBackend\.h'; then
  printf 'FAIL: probe must not #include the unshipped backend header\n' >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: probe does not #include the unshipped header\n'
fi
# The zero-before-load assertion is what stops a constant-returning stub from passing.
assert_contains "$probe" "expected 0 before any model loads" "probe asserts the pre-load zero"

wf="$(cat "$here/../.github/workflows/extras-gate.yml")"
assert_contains "$wf" "test/xnnpack_workspace_run.sh" "extras-gate full-build runs the workspace gate"

exit "$ASSERT_FAILS"
```

- [ ] **Step 5: Run the tests**

Run: `bash test/xnnpack_workspace_run.test.sh`
Expected: FAIL on the last assertion only (`extras-gate full-build runs the workspace gate`) — Task 7 wires that. Every other assertion must pass.

- [ ] **Step 6: Commit**

```bash
git add test/xnnpack_workspace/ test/xnnpack_workspace_run.sh test/xnnpack_workspace_run.test.sh
git commit -m "test: add the workspace-size behavioural probe and gate"
```

---

### Task 7: CI wiring

**Files:**
- Modify: `.github/workflows/extras-gate.yml` (`paths:` filter; `full-build` job)
- Modify: `scripts/classify-gate.sh` (routing rule 1b)
- Test: `test/classify_gate.test.sh`, `test/xnnpack_workspace_run.test.sh`

**Interfaces:**
- Consumes: `scripts/emit-xnnpack-fixtures.py`, `test/xnnpack_workspace_run.sh`.
- Produces: `full-build` fails if the workspace option regresses.

**Decision:** gate-only, not published as a release asset. The fixture serves our own gate; unlike the LSTM and OpenVINO fixtures, no consumer needs it. The `nm` guard from Task 4 runs in every build including release, so a dropped patch still fails a release; the behavioural check runs where the fixture is cheap to mint.

- [ ] **Step 1: Add the gate step**

In `.github/workflows/extras-gate.yml`, append to the `full-build` job's steps:

```yaml
      - name: XNNPACK workspace-size gate (fixture emit + behavioural probe)
        # The nm guard in build-runtime.sh proves the symbol exists; only this proves the value is
        # reachable through the published option and reflects a live arena. torch and the pinned
        # executorch package are already installed by the round-trip action above.
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          python scripts/emit-xnnpack-fixtures.py "$PWD/xnnfixtures-dryrun"
          bash test/xnnpack_workspace_run.sh "$PWD/out" "$PWD/xnnfixtures-dryrun"
```

- [ ] **Step 2: Extend the paths filter**

In the same file's `paths:` list, add:

```yaml
      # Workspace-size surface. These run only in `full`, so without a trigger an edit to one would
      # ship with no run at all.
      - 'scripts/patch-et-xnnpack-workspace.sh'
      - 'scripts/emit-xnnpack-fixtures.py'
      - 'patches/**'
      - 'test/xnnpack_workspace_run.sh'
      - 'test/xnnpack_workspace/**'
```

- [ ] **Step 3: Extend the routing rule**

In `scripts/classify-gate.sh`, extend rule (1b)'s regex to route these to `full`:

```bash
if grep -qxE 'scripts/(vendor-openvino\.sh|lib/openvino\.sh|patch-et-xnnpack-workspace\.sh|emit-xnnpack-fixtures\.py)|patches/.*|test/xnnpack_workspace(_run\.sh|/.*)' "$CHANGED"; then
```

Keep the existing OpenVINO alternatives intact — if the branch you are on already extended this regex for the OpenVINO gate scripts, merge rather than replace.

- [ ] **Step 4: Extend the routing test**

In `test/classify_gate.test.sh`, add to the `for f in …` routing loop: `scripts/patch-et-xnnpack-workspace.sh`, `patches/et-xnnpack-workspace-size.patch`, `test/xnnpack_workspace_run.sh`. Add the same paths to the workflow-reachability `for p in …` loop, quoting the glob entries as `'patches/**'` and `'test/xnnpack_workspace/**'`.

- [ ] **Step 5: Verify**

Run:
```bash
bash test/classify_gate.test.sh
bash test/xnnpack_workspace_run.test.sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/extras-gate.yml')); print('yaml ok')"
bash test/run.sh
```
Expected: all PASS, including the workflow-wiring assertion that failed at the end of Task 6.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/extras-gate.yml scripts/classify-gate.sh test/classify_gate.test.sh
git commit -m "ci: run the XNNPACK workspace-size gate in full-build"
```

---

### Task 8: Consumer documentation + contract entry

**Files:**
- Create: `docs/xnnpack-workspace-size-consumer.md`
- Modify: `docs/handover-to-engine.md` (§2 contract list; the C1–C10 header line)
- Modify: `CLAUDE.md` (Architecture section)

**Interfaces:**
- Consumes: the option contract from Task 3.
- Produces: a durable statement of what the engine is reading.

- [ ] **Step 1: Write the consumer doc**

Create `docs/xnnpack-workspace-size-consumer.md`. It must state, with no cross-references to other consumer docs (each consumer is an independent leaf distribution):

- The backend name `XnnpackBackend` and key `workspace_size_bytes`, both as literal strings, with the note that `XNNPACKBackend.h` does not ship so the consumer hardcodes them.
- A complete C++ example using `runtime::get_option` and `std::get_if<int>`, matching `test/xnnpack_workspace/workspace_probe.cpp`.
- **Reads 0 until the first XNNPACK-delegated method loads** — the arena is lazily created, so a zero is not a broken accessor.
- The value **saturates at `INT_MAX`**; it never wraps negative.
- The option is **read-only**; `set_option` returns `InvalidArgument`.
- The figure is process-wide across all XNNPACK delegate instances, because the build pins `EXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON`.
- It includes allocator alignment padding, and is a high-water mark: the arena grows and is never shrunk.
- This is **not upstream ExecuTorch** — it is a vendored patch in this distribution, and code depending on it will not build against a stock ExecuTorch.

- [ ] **Step 2: Add the contract entry**

In `docs/handover-to-engine.md` §2, add a new contract item after C10 describing the option key, its `int`-saturating semantics, its lazy-init zero, and its read-only nature. Update the "frozen contract (C1–C10)" reference in the document header to the new range, and check for other range mentions:

```bash
grep -n "C1–C10\|C1-C10" docs/handover-to-engine.md README.md CLAUDE.md
```

- [ ] **Step 3: Note it in CLAUDE.md**

Add a short subsection to the Architecture section covering the vendored patch set: what `scripts/patch-et-xnnpack-workspace.sh` does, that `patches/*.patch` must be regenerated together with `test/fixtures/etpatch/` when the ET pin moves, and that the `nm` guard plus the gate exist to catch a dropped patch.

- [ ] **Step 4: Verify and commit**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

```bash
git add docs/xnnpack-workspace-size-consumer.md docs/handover-to-engine.md CLAUDE.md
git commit -m "docs: document the workspace-size option as a consumer contract"
```

---

## Verification before opening the PR

- [ ] `bash test/run.sh` → `ALL UNIT TESTS PASS`
- [ ] `./build-runtime.sh --print-flags --variant logging` includes `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON`
- [ ] Both workflows parse as YAML
- [ ] A real container build applies both patches, passes the `nm` guard, and passes `test/xnnpack_workspace_run.sh`:

```bash
docker run --rm -v "$PWD":/work -v /path/to/executorch:/executorch \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant logging --prefix /work/out --et-src /executorch'
```

- [ ] Re-run the same build command against the same `--et-src` to confirm the patch step reports `already patched` and the build still succeeds. Idempotency is a contract, and the container run is the only place it is tested against a real tree.

## Post-merge

A pkgrev bump (`v1.3.1-8` → `v1.3.1-9`) publishes the change. The engine then takes the new `EtRuntimePin.cmake` and can report the workspace as an exact third component. That release is a separate action, not part of this plan.
