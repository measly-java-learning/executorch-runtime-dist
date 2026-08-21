# OpenVINO Windows Compile Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vendor the ExecuTorch OpenVINO Windows port as a patch, enable the delegate on both Windows platforms, and make the PR gate compile and package it — so the patch is exercised code rather than dead weight.

**Architecture:** Three moves in one PR. (1) The existing single-purpose patch script becomes a general ET source-patch script and gains the OpenVINO patch, with hermetic fixtures in lockstep. (2) `ov_enabled_for_platform` — the SSOT both `cmakeflags.sh` and `package.sh` consume — gains the two Windows platforms, and `package.sh` stops hardcoding the POSIX archive name. (3) `extras-gate` gains a Windows job mirroring `release.yml`'s `build-windows`, so a `full` PR proves the Windows tag will build.

**Tech Stack:** Bash (`set -euo pipefail`), CMake + Ninja, MSVC (`cl`), GitHub Actions, ExecuTorch v1.4.1.

**Spec:** https://github.com/measly-java-learning/executorch-runtime-dist/issues/37 and its three result comments, which record the verified findings this plan builds on:
- cross-OS blob portability — [comment 5372346221](https://github.com/measly-java-learning/executorch-runtime-dist/issues/37#issuecomment-5372346221)
- the `$ORIGIN` substitute (blocker 2) — [comment 5372679998](https://github.com/measly-java-learning/executorch-runtime-dist/issues/37#issuecomment-5372679998)
- the MSVC port (blockers 1 and 3) — [comment 5373356538](https://github.com/measly-java-learning/executorch-runtime-dist/issues/37#issuecomment-5373356538)

## Global Constraints

- ET pin is **v1.4.1** (`e4d02f41f7909e8ed5bf4a14ffc520d733453d9f`). The patch and all `test/fixtures/etpatch/` files must be generated against this exact commit.
- **Patches and fixtures move in lockstep.** A stale fixture makes the hermetic test pass while the real build fails. Regenerate both in the same commit when the pin moves.
- **Idempotency is a contract.** A second patch run reports `already patched`; a moved anchor is a HARD error, never a silent skip.
- Windows platforms are exactly two: `windows-x86_64` (`/MD`, `MultiThreadedDLL`) and `windows-x86_64-static` (`/MT`, `MultiThreaded`). Both come from `crt_for_platform` in `scripts/lib/configure-base.sh`.
- Shell runs under `set -euo pipefail`. `grep` exits 1 on no-match, which aborts under `set -e`/`pipefail` — guard with `|| true`.
- No complex Python embedded in shell scripts. Structural tests that parse YAML go in `test/lib/<name>.py` with a thin `<name>.test.sh` invoker.
- Work lands on a branch (`feature/*`) through a PR.
- `bash test/run.sh` must be green from a clean checkout at the end of every task.

## Decision Record

**`ov_enabled_for_platform` is flipped now, and the Windows tarball ships the delegate.** The alternative — a gate-only `-DEXECUTORCH_BUILD_OPENVINO=ON` override leaving the shipped predicate Linux-only — was rejected because it makes the gate test a configuration we do not ship, which is exactly the drift the SSOT comment in `scripts/lib/openvino.sh` warns about.

**Accepted, recorded risk:** until the `win_amd64` bundle lands (issue #37 step 3), Windows tarballs carry an OpenVINO delegate that no runtime gate has exercised on Windows, and `BUILDINFO` records `openvino_version=2025.4.1` with no Windows bundle asset published. The delegate is inert unless a consumer sets `OPENVINO_LIB_PATH`, and `docs/openvino-python-consumer.md` already documents pointing it at a pip-installed wheel. Task 2 adds a docs note so this is discoverable rather than surprising.

**Out of scope, deliberately:** the `win_amd64` bundle (`vendor-openvino.sh --platform`, `ov_lib_members` becoming platform-taking), the PowerShell ports of `openvino_smoke.sh` / `openvino_fixture_run.sh`, Windows OpenVINO rows in `gen-pin.sh`, and an upstream ExecuTorch PR. `gen-pin.sh` is safe to leave alone: its OpenVINO rows are driven by explicit `--openvino-sha` / `--openvino-platform` arguments from `release.yml`, **not** by `ov_enabled_for_platform`, so flipping the predicate does not emit pin rows for a nonexistent asset.

---

## File Structure

**Created:**
- `patches/et-openvino-windows.patch` — the vendored MSVC port of ET's OpenVINO backend.
- `test/fixtures/etpatch/OpenvinoApi.h`, `OpenvinoBackend.cpp`, `openvino-CMakeLists.txt` — verbatim v1.4.1 anchor text for the hermetic patch test.
- `.github/workflows/extras-gate.yml` job `full-build-windows` — no new file, but a new unit of responsibility.
- `test/lib/extras_gate_windows.py` + `test/extras_gate_windows.test.sh` — structural assertions on the new job.

**Renamed:**
- `scripts/patch-et-xnnpack-workspace.sh` → `scripts/patch-et-sources.sh` (it applies three patches across two concerns now; the old name would lie).
- `test/patch_et_xnnpack_workspace.test.sh` → `test/patch_et_sources.test.sh`.

**Modified:**
- `scripts/lib/openvino.sh` — `ov_enabled_for_platform` gains the Windows cases; new `ov_backend_archive_name`.
- `scripts/package.sh:56-65` — assert on the platform-correct archive name.
- `scripts/classify-gate.sh:50` — the routing regex learns the renamed script and the new patch.
- `build-runtime.sh:188-191` — call the renamed script.
- `.github/workflows/extras-gate.yml` — `paths:` filter and the new job.
- `test/lib_openvino.test.sh`, `test/lib_cmakeflags.test.sh`, `test/exec_perms.test.sh`, `test/classify_gate.test.sh` — invert the Windows-is-off assertions and cover the rename.
- `CLAUDE.md:98` — the script name and what it now covers.
- `docs/openvino-python-consumer.md` — Windows `OPENVINO_LIB_PATH` guidance.

Historical plan docs under `docs/superpowers/plans/2026-08-14-*` and `2026-08-20-*` reference the old script name. **Leave them alone** — they are a record of what was done at the time, not live documentation.

---

## Task 1: Vendor the OpenVINO Windows patch

**Files:**
- Create: `patches/et-openvino-windows.patch`
- Create: `test/fixtures/etpatch/OpenvinoApi.h`, `test/fixtures/etpatch/OpenvinoBackend.cpp`, `test/fixtures/etpatch/openvino-CMakeLists.txt`
- Rename: `scripts/patch-et-xnnpack-workspace.sh` → `scripts/patch-et-sources.sh`
- Rename: `test/patch_et_xnnpack_workspace.test.sh` → `test/patch_et_sources.test.sh`
- Modify: `build-runtime.sh:188-191`, `scripts/classify-gate.sh:50`, `.github/workflows/extras-gate.yml:29`, `test/exec_perms.test.sh:12`, `test/classify_gate.test.sh:65,91`, `CLAUDE.md:98`
- Modify: `test/fixtures/etpatch/README.md`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `scripts/patch-et-sources.sh <et-src>` — same contract as before (idempotent; hard error on drift), now applying three patches. Task 3's Windows gate job depends on this running during the build's patch phase.

- [ ] **Step 1: Create the branch**

```bash
cd /path/to/executorch-runtime-dist
git fetch origin
git checkout -b feature/openvino-windows-enable origin/main
```

- [ ] **Step 2: Save the patch**

Write the diff below to `patches/et-openvino-windows.patch` verbatim. It is the exact patch verified to build under MSVC at both CRTs against v1.4.1.

```diff
diff --git a/backends/openvino/CMakeLists.txt b/backends/openvino/CMakeLists.txt
index 5b7a1349b..dacbe4e9d 100644
--- a/backends/openvino/CMakeLists.txt
+++ b/backends/openvino/CMakeLists.txt
@@ -28,14 +28,19 @@ set(COMMON_INCLUDE_DIRS ${EXECUTORCH_ROOT}/..)
 # Include utility CMake scripts from ExecuteTorch
 include(${EXECUTORCH_ROOT}/tools/cmake/Utils.cmake)
 
-# The backend resolves OpenVINO C API symbols via dlopen/dlsym at runtime, so
-# there is no build-time dependency on the OpenVINO SDK.
+# The backend resolves OpenVINO C API symbols at runtime (dlopen or LoadLibraryEx), so there
+# is no build-time dependency on the OpenVINO SDK.
 
 # Define OpenVINO backend as a static library
 add_library(openvino_backend STATIC)
 
-# Enable exceptions and RTTI for OpenVINO backend
-target_compile_options(openvino_backend PRIVATE -frtti -fexceptions)
+# Enable exceptions and RTTI. MSVC rejects the GCC/Clang spelling; this branch also covers
+# clang-cl, which CMake reports as MSVC.
+if(MSVC)
+  target_compile_options(openvino_backend PRIVATE /EHsc /GR)
+else()
+  target_compile_options(openvino_backend PRIVATE -frtti -fexceptions)
+endif()
 
 # Add source files for OpenVINO backend
 target_sources(
diff --git a/backends/openvino/runtime/OpenvinoApi.h b/backends/openvino/runtime/OpenvinoApi.h
index 90403e24b..374051fa5 100644
--- a/backends/openvino/runtime/OpenvinoApi.h
+++ b/backends/openvino/runtime/OpenvinoApi.h
@@ -8,7 +8,17 @@
 
 #pragma once
 
+#ifdef _WIN32
+#ifndef WIN32_LEAN_AND_MEAN
+#define WIN32_LEAN_AND_MEAN
+#endif
+#ifndef NOMINMAX
+#define NOMINMAX
+#endif
+#include <windows.h>
+#else
 #include <dlfcn.h>
+#endif
 #include <cstddef>
 #include <cstdint>
 #include <memory>
@@ -99,12 +109,53 @@ using ov_shape_free_fn = ov_status_e (*)(ov_shape_t*);
 struct DlCloser {
   void operator()(void* handle) {
     if (handle) {
+#ifdef _WIN32
+      FreeLibrary(static_cast<HMODULE>(handle));
+#else
       dlclose(handle);
+#endif
     }
   }
 };
 using DlHandle = std::unique_ptr<void, DlCloser>;
 
+#ifdef _WIN32
+// LoadLibraryEx FAILS when a LOAD_LIBRARY_SEARCH_* flag is paired with a bare filename, so the
+// absolute and bare cases below must take different branches.
+inline bool is_absolute_path(const char* path) {
+  if (!path || !path[0]) {
+    return false;
+  }
+  if (path[0] == '\\' || path[0] == '/') {
+    return true; // UNC or rooted
+  }
+  return path[1] == ':' && (path[2] == '\\' || path[2] == '/');
+}
+
+// DEFAULT_DIRS is required, not belt-and-braces: any LOAD_LIBRARY_SEARCH_* flag switches the
+// loader to the alternate search order, which drops System32 -- where the MSVC runtime the
+// OpenVINO DLLs import from lives. DLL_LOAD_DIR alone fails with ERROR_MOD_NOT_FOUND.
+inline void* open_library(const char* path) {
+  int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
+  if (wlen <= 0) {
+    return nullptr;
+  }
+  // unique_ptr<wchar_t[]> rather than std::wstring: <memory> is already a dependency of this
+  // header and <string> is not, so this keeps the include set unchanged.
+  std::unique_ptr<wchar_t[]> wpath(new wchar_t[wlen]);
+  if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.get(), wlen) <= 0) {
+    return nullptr;
+  }
+  if (is_absolute_path(path)) {
+    return LoadLibraryExW(
+        wpath.get(),
+        nullptr,
+        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
+  }
+  return LoadLibraryW(wpath.get());
+}
+#endif
+
 struct OpenvinoFunctions {
   ov_core_create_fn core_create = nullptr;
   ov_core_free_fn core_free = nullptr;
diff --git a/backends/openvino/runtime/OpenvinoBackend.cpp b/backends/openvino/runtime/OpenvinoBackend.cpp
index 3cf87e6ab..4d2dc2222 100644
--- a/backends/openvino/runtime/OpenvinoBackend.cpp
+++ b/backends/openvino/runtime/OpenvinoBackend.cpp
@@ -23,10 +23,26 @@ namespace openvino {
 
 namespace {
 
+#ifdef _WIN32
+constexpr const char* kDefaultLibName = "openvino_c.dll";
+#else
 constexpr const char* kDefaultLibName = "libopenvino_c.so";
+#endif
 
 template <typename FuncPtr>
 FuncPtr load_symbol(void* handle, const char* name) {
+#ifdef _WIN32
+  FARPROC sym = GetProcAddress(static_cast<HMODULE>(handle), name);
+  if (!sym) {
+    ET_LOG(
+        Error,
+        "OpenVINO: failed to resolve symbol '%s' (GetLastError=%lu)",
+        name,
+        static_cast<unsigned long>(GetLastError()));
+    return nullptr;
+  }
+  return reinterpret_cast<FuncPtr>(sym);
+#else
   dlerror(); // Clear any stale error state.
   void* sym = dlsym(handle, name);
   const char* err = dlerror();
@@ -35,6 +51,7 @@ FuncPtr load_symbol(void* handle, const char* name) {
     return nullptr;
   }
   return reinterpret_cast<FuncPtr>(sym);
+#endif
 }
 
 } // namespace
@@ -47,6 +64,21 @@ bool OpenvinoBackend::ensure_loaded() const {
     const char* lib_path = std::getenv("OPENVINO_LIB_PATH");
     const char* effective_path = lib_path ? lib_path : kDefaultLibName;
 
+#ifdef _WIN32
+    void* handle = open_library(effective_path);
+    if (!handle) {
+      ET_LOG(
+          Error,
+          "OpenVINO runtime not found (LoadLibrary failed for '%s', "
+          "GetLastError=%lu). Set OPENVINO_LIB_PATH to the ABSOLUTE path of "
+          "'openvino_c.dll'. Error 126 may instead mean a DEPENDENCY was not "
+          "found: the OpenVINO DLLs require the MSVC redistributable. Install "
+          "OpenVINO with: pip install \"openvino>=2025.1.0,<2026.0.0\"",
+          effective_path,
+          static_cast<unsigned long>(GetLastError()));
+      return;
+    }
+#else
     void* handle = dlopen(effective_path, RTLD_NOW | RTLD_LOCAL);
     if (!handle) {
       ET_LOG(
@@ -58,6 +90,7 @@ bool OpenvinoBackend::ensure_loaded() const {
           dlerror());
       return;
     }
+#endif
     lib_handle_.reset(handle);
 
 #define LOAD_SYM(field, symbol_name)                                  \
```

The Windows loader helpers (`is_absolute_path`, `open_library`) live in **`OpenvinoApi.h`**, not in
`OpenvinoBackend.cpp`, for two reasons. That header is already the platform-API shim — it owns the
`dlfcn.h`/`windows.h` switch and `DlCloser`/`DlHandle` — so open and close belong together rather
than split across two files. And it is the drift-resistant place to put them: between v1.3.1 and
v1.4.1 upstream touched `OpenvinoBackend.cpp` in 5 commits and `OpenvinoApi.h` in 1, so keeping the
`.cpp` hunk small is what makes the next pin bump cheap. They are `inline` because they are now in a
header, and use `unique_ptr<wchar_t[]>` rather than `std::wstring` so the header's include set is
unchanged (`<memory>` is already there; `<string>` is not).

- [ ] **Step 3: Verify the patch applies to a real v1.4.1 checkout**

Against a checkout at `e4d02f41`, with no other local edits:

```bash
git -C /path/to/executorch apply --check /path/to/executorch-runtime-dist/patches/et-openvino-windows.patch
echo "exit=$?"
```

Expected: `exit=0`. A non-zero exit means the patch was generated against a different pin — stop and regenerate rather than hand-editing it.

- [ ] **Step 4: Capture the fixtures**

The hermetic test patches real anchor text, so the fixtures are verbatim pristine copies. Take them from a **clean** v1.4.1 checkout (`git stash` or `git checkout -f --` first if the patch from Step 3 is still applied):

```bash
ET=/path/to/executorch   # at e4d02f41, clean
DEST=test/fixtures/etpatch
git -C "$ET" show HEAD:backends/openvino/runtime/OpenvinoApi.h      > "$DEST/OpenvinoApi.h"
git -C "$ET" show HEAD:backends/openvino/runtime/OpenvinoBackend.cpp > "$DEST/OpenvinoBackend.cpp"
git -C "$ET" show HEAD:backends/openvino/CMakeLists.txt             > "$DEST/openvino-CMakeLists.txt"
```

`git show HEAD:<path>` rather than `cp`: it reads the committed blob, so a dirty working tree cannot contaminate a fixture. The CMakeLists fixture is renamed with an `openvino-` prefix because `test/fixtures/etpatch/` is a flat directory and a bare `CMakeLists.txt` there would be ambiguous.

- [ ] **Step 5: Rename the patch script and its test**

```bash
git mv scripts/patch-et-xnnpack-workspace.sh scripts/patch-et-sources.sh
git mv test/patch_et_xnnpack_workspace.test.sh test/patch_et_sources.test.sh
```

- [ ] **Step 6: Update the script's header and add the third patch**

In `scripts/patch-et-sources.sh`, replace the header comment (everything from line 2 through the `# Usage:` line) with:

```bash
# Apply the vendored source patches to a caller-supplied ExecuTorch checkout. Two concerns:
#
#   1. WORKSPACE SIZE — expose the XNNPACK delegate's arena size through the backend-options API so
#      consumers can account for it in host-side native memory reporting. Upstream XNNPACK has no
#      size accessor and ExecuTorch surfaces none. See
#      docs/superpowers/specs/2026-08-14-xnnpack-workspace-size-design.md.
#   2. OPENVINO ON WINDOWS — ExecuTorch's OpenVINO backend is POSIX-only: it includes <dlfcn.h> and
#      compiles with -frtti/-fexceptions, neither of which MSVC accepts. The patch adds a
#      LoadLibraryEx/GetProcAddress arm and the MSVC compile-option spelling. It is a no-op on
#      Linux by construction: every change is inside #ifdef _WIN32 or an if(MSVC) branch, verified
#      with `unifdef -U_WIN32` reproducing the pristine files. See
#      https://github.com/measly-java-learning/executorch-runtime-dist/issues/37.
#
# Idempotent by contract: build-runtime.sh re-runs against a persisted build tree and a checkout
# that may already be patched. A patch that is already applied is success; a patch that does NOT
# apply is a HARD ERROR, never a skip. A silently unapplied patch ships a runtime whose consumer
# contract is quietly broken, which is the exact failure the post-build nm guard and the gate's
# behavioural test exist to catch — but the recipe should fail first, and more legibly.
#
# Usage: patch-et-sources.sh <et-src>
```

Then replace the final two lines with three:

```bash
echo ">> patching ET sources (workspace-size accounting, OpenVINO/Windows)"
apply_patch "$XNN_DIR" "$ROOT/patches/xnnpack-workspace-size-accessor.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-xnnpack-workspace-size.patch"
apply_patch "$ET_SRC"  "$ROOT/patches/et-openvino-windows.patch"
```

Also update the drift message inside `apply_patch`, which names the old fixture path correctly already — leave `test/fixtures/etpatch/` as written.

- [ ] **Step 7: Update every call site of the old name**

Replace only the basename STEM, never the full path. `classify-gate.sh` embeds the name inside a
regex as `patch-et-xnnpack-workspace\.sh`, so a pattern written against the literal path would have
to escape the `\.` and get it right in both halves — a stem replacement sidesteps that entirely and
is correct in all five files:

```bash
sed -i 's#patch-et-xnnpack-workspace#patch-et-sources#g' \
  build-runtime.sh \
  scripts/classify-gate.sh \
  .github/workflows/extras-gate.yml \
  test/exec_perms.test.sh \
  test/classify_gate.test.sh
```

Note the new patch itself needs no routing rule: `classify-gate.sh`'s regex already matches
`patches/.*`, so `patches/et-openvino-windows.patch` routes to `full` on day one.

Verify nothing live still references the old name (the two historical plan docs are expected and must be left alone):

```bash
grep -rn 'patch-et-xnnpack-workspace' --include='*' . | grep -v '^\./\.git/' | grep -v 'docs/superpowers/plans/'
```

Expected: no output.

- [ ] **Step 8: Update CLAUDE.md**

Replace the sentence at `CLAUDE.md:98` beginning "`scripts/patch-et-xnnpack-workspace.sh` applies a small vendored patch set" with:

```markdown
`scripts/patch-et-sources.sh` applies the vendored patch set (`patches/*.patch`) to the
caller-supplied ExecuTorch checkout during the build's patch phase, before configure. Two concerns:
the XNNPACK **workspace-size** accessor (the read-only `workspace_size_bytes` backend option — the
consumer contract in `docs/xnnpack-workspace-size-consumer.md`), and the **OpenVINO Windows** port
(`LoadLibraryEx`/`GetProcAddress` instead of `dlopen`, plus the MSVC spelling of `-frtti
-fexceptions`). Both are local additions; code depending on either will not build against a stock
ExecuTorch.
```

- [ ] **Step 9: Extend the hermetic patch test**

In `test/patch_et_sources.test.sh`, extend `mk_tree` to lay down the OpenVINO fixtures, adding these three lines after the existing `cp` block and before `git -C "$r" init -q`:

```bash
  mkdir -p "$r/backends/openvino/runtime"
  cp "$here/fixtures/etpatch/OpenvinoApi.h"          "$r/backends/openvino/runtime/OpenvinoApi.h"
  cp "$here/fixtures/etpatch/OpenvinoBackend.cpp"    "$r/backends/openvino/runtime/OpenvinoBackend.cpp"
  cp "$here/fixtures/etpatch/openvino-CMakeLists.txt" "$r/backends/openvino/CMakeLists.txt"
```

Then add these assertions after the existing `workspace_size_option_key` spelling assertion:

```bash
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
```

Add a third drift case after the existing `drift2` block, so a moved OpenVINO anchor is caught the same way:

```bash
mk_tree "$tmp/drift3"
: > "$tmp/drift3/backends/openvino/runtime/OpenvinoBackend.cpp"
git -C "$tmp/drift3" -c user.email=t@t -c user.name=t commit -qam drift
out="$(bash "$script" "$tmp/drift3" 2>&1)"
assert_eq "$?" "1" "drifted OpenVINO anchor fails"
assert_contains "$out" "does not apply" "OpenVINO drift failure explains itself"
```

- [ ] **Step 10: Update the fixtures README**

Replace the first paragraph of `test/fixtures/etpatch/README.md` with:

```markdown
Verbatim copies of ExecuTorch v1.4.1 (commit e4d02f4) and its vendored XNNPACK sources, used as
hermetic fixtures for test/patch_et_sources.test.sh. They exist so the patch test runs against the
real anchor text without needing a multi-GB ET checkout. The `Xnn*`/`XNN*`/`xnnpack.h`/`runtime.c`
files back the workspace-size patches; `OpenvinoApi.h`, `OpenvinoBackend.cpp` and
`openvino-CMakeLists.txt` back the OpenVINO/Windows patch (the last is renamed because this is a
flat directory and a bare `CMakeLists.txt` would be ambiguous).
```

- [ ] **Step 11: Run the suite**

```bash
bash test/run.sh
```

Expected: `ALL UNIT TESTS PASS`. If `patch_et_sources.test.sh` reports `does not apply`, the fixtures and the patch were generated from different trees — regenerate both from `e4d02f41`.

- [ ] **Step 12: Commit**

```bash
git add patches/et-openvino-windows.patch test/fixtures/etpatch/ \
  scripts/patch-et-sources.sh test/patch_et_sources.test.sh \
  build-runtime.sh scripts/classify-gate.sh .github/workflows/extras-gate.yml \
  test/exec_perms.test.sh test/classify_gate.test.sh CLAUDE.md
git commit -m "feat(patches): vendor the OpenVINO Windows port

ExecuTorch's OpenVINO backend is POSIX-only (<dlfcn.h>, -frtti/-fexceptions).
The patch adds a LoadLibraryEx/GetProcAddress arm and the MSVC compile-option
spelling; verified building openvino_backend.lib under MSVC at both CRTs
against v1.4.1. No-op on Linux by construction -- unifdef -U_WIN32 reproduces
the pristine files exactly.

Renames patch-et-xnnpack-workspace.sh -> patch-et-sources.sh: it now applies
three patches across two concerns and the old name would lie."
```

---

## Task 2: Enable OpenVINO on the Windows platforms

**Files:**
- Modify: `scripts/lib/openvino.sh:77-82` (`ov_enabled_for_platform`), plus a new `ov_backend_archive_name`
- Modify: `scripts/package.sh:56-65`
- Modify: `test/lib_openvino.test.sh:52-57`, `test/lib_cmakeflags.test.sh:18-21,29-32`
- Modify: `docs/openvino-python-consumer.md`

**Interfaces:**
- Consumes: Task 1's patch, which is what makes the enabled build compile at all. Enabling without it fails at `#include <dlfcn.h>`.
- Produces: `ov_backend_archive_name <platform>` → `openvino_backend.lib` on `windows-*`, `libopenvino_backend.a` otherwise. Task 3's gate job depends on `package.sh` accepting the Windows artifact.

- [ ] **Step 1: Write the failing test**

In `test/lib_openvino.test.sh`, replace line 56 (the `windows-x86_64` must-be-off assertion) with both platforms asserted ON, and add coverage for the new helper:

```bash
ov_enabled_for_platform windows-x86_64 && printf 'ok: enabled on windows-x86_64\n' || { printf 'FAIL: windows-x86_64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_enabled_for_platform windows-x86_64-static && printf 'ok: enabled on windows-x86_64-static\n' || { printf 'FAIL: windows-x86_64-static\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# MSVC does not use the lib*.a convention. package.sh asserts the delegate archive EXISTS before
# recording openvino_version, so a single hardcoded spelling would fail every Windows release the
# moment the predicate above turned Windows on.
assert_eq "$(ov_backend_archive_name linux-x86_64)"          "libopenvino_backend.a" "POSIX archive name"
assert_eq "$(ov_backend_archive_name windows-x86_64)"        "openvino_backend.lib"  "MSVC archive name"
assert_eq "$(ov_backend_archive_name windows-x86_64-static)" "openvino_backend.lib"  "MSVC archive name (static CRT)"
```

In `test/lib_cmakeflags.test.sh`, invert the two Windows blocks at lines 18-21 and 29-32:

```bash
assert_contains "$(common_cmake_flags windows-x86_64)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "openvino enabled on windows-x86_64"
assert_contains "$(effective_cmake_flags windows-x86_64-static logging)" "-DEXECUTORCH_BUILD_OPENVINO=ON" \
  "windows effective flags carry openvino"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash test/lib_openvino.test.sh; bash test/lib_cmakeflags.test.sh
```

Expected: FAIL on the Windows assertions, and `ov_backend_archive_name: command not found`.

- [ ] **Step 3: Flip the predicate and add the helper**

In `scripts/lib/openvino.sh`, replace the `ov_enabled_for_platform` body:

```bash
ov_enabled_for_platform() { # <platform> -> 0 (enabled) / 1 (not)
  case "${1:-}" in
    linux-x86_64|windows-x86_64|windows-x86_64-static) return 0 ;;
    *) return 1 ;;
  esac
}

# Platform -> the delegate archive the build produces. MSVC does not use the lib*.a convention, so
# package.sh's existence assertion cannot hardcode one spelling. Kept beside the predicate above
# deliberately: the two are read together, and a platform added to one without the other produces a
# release that fails at packaging rather than at configure.
ov_backend_archive_name() { # <platform>
  case "${1:-}" in
    windows-*) printf 'openvino_backend.lib' ;;
    *)         printf 'libopenvino_backend.a' ;;
  esac
}
```

Update the comment above `ov_enabled_for_platform` — the existing text says "a future linux-aarch64 enablement". Replace that final sentence with:

```bash
# places is exactly the drift CLAUDE.md warns about: an enablement that updated only one would ship
# a tarball whose BUILDINFO lies about its contents. Windows is enabled here as of the OpenVINO
# Windows port (issue #37): the delegate compiles and ships, but the win_amd64 RUNTIME BUNDLE does
# not exist yet, so a Windows consumer must point OPENVINO_LIB_PATH at their own openvino_c.dll.
```

- [ ] **Step 4: Teach package.sh the archive name**

In `scripts/package.sh`, replace lines 56-61 with:

```bash
if ov_enabled_for_platform "$PLATFORM"; then
  _ov_archive="$(ov_backend_archive_name "$PLATFORM")"
  [ -f "$PREFIX/lib/$_ov_archive" ] || {
    echo "package.sh: platform '$PLATFORM' enables OpenVINO but $PREFIX/lib/$_ov_archive" >&2
    echo "  is missing — the delegate was not built. Refusing to record openvino_version for a" >&2
    echo "  tarball that does not contain it." >&2
    exit 1; }
  OPENVINO_VERSION="$OV_VERSION"
else
  OPENVINO_VERSION="n/a"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash test/lib_openvino.test.sh; bash test/lib_cmakeflags.test.sh; bash test/run.sh
```

Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 6: Confirm the effective Windows flags actually changed**

```bash
./build-runtime.sh --print-flags --variant logging --platform windows-x86_64 | tr ' ' '\n' | grep OPENVINO
```

Expected: `-DEXECUTORCH_BUILD_OPENVINO=ON`. This is the observable that Task 3's job depends on; if it is absent the gate would build and prove nothing.

- [ ] **Step 7: Document the Windows consumer path**

Append to `docs/openvino-python-consumer.md`:

```markdown
## Windows

The delegate ships in the `windows-x86_64` and `windows-x86_64-static` tarballs, but **no Windows
OpenVINO runtime bundle is published yet** — `EtRuntimePin.cmake` carries bundle rows for
`linux-x86_64` only. On Windows, point `OPENVINO_LIB_PATH` at the absolute path of an
`openvino_c.dll` you supply yourself, most easily from the same PyPI wheel this project vendors on
Linux:

```
py -3.12 -m pip install openvino==2025.4.1
set OPENVINO_LIB_PATH=%VIRTUAL_ENV%\Lib\site-packages\openvino\libs\openvino_c.dll
```

`OPENVINO_LIB_PATH` **must be absolute on Windows.** The backend passes an absolute path to
`LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`, which is what lets a flat bundle resolve
its own siblings — Windows has no `$ORIGIN`. A bare filename falls back to the default search order
(PATH), which will not find the sibling DLLs of an arbitrary directory.

The OpenVINO DLLs are built against the dynamic CRT and import `MSVCP140.dll` / `VCRUNTIME140.dll`
from System32, so the **Microsoft Visual C++ redistributable must be installed**. Without it the
load fails with error 126 (`ERROR_MOD_NOT_FOUND`), which names nothing useful. A `/MT` static
consumer against these `/MD` DLLs is safe: every OpenVINO allocation is released through an
OpenVINO-side free function, so no CRT object crosses the boundary.
```

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/openvino.sh scripts/package.sh test/lib_openvino.test.sh \
  test/lib_cmakeflags.test.sh docs/openvino-python-consumer.md
git commit -m "feat(openvino): enable the delegate on both Windows platforms

ov_enabled_for_platform is the SSOT consumed by cmakeflags.sh (which sets
EXECUTORCH_BUILD_OPENVINO) and package.sh (which asserts the archive exists),
so both change together. package.sh gains ov_backend_archive_name because MSVC
produces openvino_backend.lib, not libopenvino_backend.a.

The win_amd64 runtime bundle does not exist yet, so Windows consumers must
supply their own openvino_c.dll -- documented, including the absolute-path
requirement and the MSVC redistributable dependency."
```

---

## Task 3: Compile and package Windows in the PR gate

**Files:**
- Modify: `.github/workflows/extras-gate.yml` (new `full-build-windows` job)
- Create: `test/lib/extras_gate_windows.py`, `test/extras_gate_windows.test.sh`

**Interfaces:**
- Consumes: Task 1's `scripts/patch-et-sources.sh` (runs in the build's patch phase) and Task 2's enablement (without it the job compiles no OpenVINO code and proves nothing).
- Produces: no shell interface; the deliverable is CI coverage.

- [ ] **Step 1: Write the failing structural test**

Create `test/lib/extras_gate_windows.py`:

```python
"""Structural assertions on extras-gate's Windows job.

The job exists to prove that a `full` PR will not break the Windows release tag. That guarantee is
only real if the job mirrors release.yml's build-windows: same two platforms, same entrypoint, and
a package step -- because package.sh carries the OpenVINO archive assertion, and a build-only job
would let a packaging regression ship.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
JOB = "full-build-windows"


def main() -> int:
    gate = yaml.safe_load((ROOT / ".github/workflows/extras-gate.yml").read_text())
    release = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
    fails = []

    if JOB not in gate["jobs"]:
        print(f"FAIL: extras-gate has no {JOB} job")
        return 1
    job = gate["jobs"][JOB]

    if not str(job.get("runs-on", "")).startswith("windows"):
        fails.append(f"{JOB} must run on a windows runner, got {job.get('runs-on')!r}")

    # Same platform axis as the release job, or the gate proves less than it claims.
    gate_platforms = set(job["strategy"]["matrix"]["platform"])
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"platform matrix {sorted(gate_platforms)} != release {sorted(rel_platforms)}")

    if job.get("needs") != "classify" and "classify" not in (job.get("needs") or []):
        fails.append(f"{JOB} must depend on classify")
    if "full" not in str(job.get("if", "")):
        fails.append(f"{JOB} must be gated on mode == 'full'")

    steps = yaml.dump(job["steps"])
    for needle, why in [
        ("build-runtime.ps1", "must build through the same entrypoint release.yml uses"),
        ("scripts/package.sh", "must package: package.sh carries the OpenVINO archive assertion"),
        ("checkout-executorch", "must check out the pinned ExecuTorch source"),
    ]:
        if needle not in steps:
            fails.append(f"{JOB} {why} (missing {needle})")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"ok: {JOB} mirrors release build-windows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Create `test/extras_gate_windows.test.sh`:

```bash
#!/usr/bin/env bash
# Thin invoker: the real checks parse workflow YAML and live in test/lib/extras_gate_windows.py.
# test/run.sh globs *.test.sh, so this file is how that suite reaches them.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/lib/extras_gate_windows.py"
exit $?
```

```bash
chmod 755 test/extras_gate_windows.test.sh
chmod 644 test/lib/extras_gate_windows.py
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash test/extras_gate_windows.test.sh
```

Expected: `FAIL: extras-gate has no full-build-windows job`, exit 1.

- [ ] **Step 3: Add the job**

Append to `.github/workflows/extras-gate.yml`, after the `full-build` job:

```yaml
  # Windows arm of the full gate. Deliberately mirrors release.yml's build-windows -- same two CRT
  # platforms, same build-runtime.ps1 entrypoint, same package step -- because the whole point of
  # `full` is that a green gate means the eventual release tag will build. Before this job, nothing
  # on a PR ever compiled Windows: every other job here is ubuntu-latest, so an MSVC-breaking change
  # (the vendored OpenVINO patch is exactly that shape) surfaced at the tag instead.
  #
  # It packages as well as builds: package.sh holds the assertion that the OpenVINO delegate archive
  # exists before BUILDINFO records openvino_version, and that assertion is platform-dependent
  # (openvino_backend.lib vs libopenvino_backend.a). A build-only job would let that regress.
  full-build-windows:
    needs: classify
    if: needs.classify.outputs.mode == 'full'
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
        platform: [windows-x86_64, windows-x86_64-static]
    steps:
      - name: Configure Git for Windows checkout (long paths + symlinks)
        # Same two Windows git defaults release.yml documents: third-party/ao -> cutlass has
        # filenames past MAX_PATH, and Git-for-Windows defaults core.symlinks=false, which would
        # materialize ET's symlinks as text stubs. --system so every submodule subprocess inherits.
        shell: pwsh
        run: |
          git config --system core.longpaths true
          git config --system core.symlinks true
      - uses: actions/checkout@v7
      - name: Checkout ExecuTorch source
        uses: ./.github/actions/checkout-executorch
        with:
          ref: v${{ needs.classify.outputs.etver }}
      - name: Build runtime (MSVC)
        shell: pwsh
        run: |
          & ./build-runtime.ps1 ./build-runtime.sh --variant ${{ matrix.variant }} `
            --prefix "$PWD/out" --et-src "$PWD/et-src/executorch" `
            --et-tag v${{ needs.classify.outputs.etver }} --platform ${{ matrix.platform }}
          if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }
      - name: Assert the OpenVINO delegate was actually built
        # The build succeeding is not the same as the delegate compiling: EXECUTORCH_BUILD_OPENVINO
        # is a cache variable, and cmake only WARNS about an unused -D. Without this, an upstream
        # rename would silently drop the delegate and the gate would stay green.
        shell: bash
        run: |
          [ -f out/lib/openvino_backend.lib ] || {
            echo "::error::out/lib/openvino_backend.lib missing — the OpenVINO delegate was not built"
            exit 1; }
          echo "ok: openvino_backend.lib present"
      - name: Package
        shell: bash
        run: |
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ needs.classify.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform ${{ matrix.platform }} \
            --package-tag "gate-${GITHUB_SHA::7}" --outdir "$PWD/dist" \
            --toolchain "msvc-2022"
```

- [ ] **Step 4: Run the structural test to verify it passes**

```bash
bash test/extras_gate_windows.test.sh && bash test/run.sh
```

Expected: `ok: full-build-windows mirrors release build-windows`, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/extras-gate.yml test/lib/extras_gate_windows.py \
  test/extras_gate_windows.test.sh
git commit -m "ci(gate): compile and package Windows in the full gate

Every other extras-gate job is ubuntu-latest, so nothing on a PR ever built
Windows -- an MSVC-breaking change surfaced at the release tag instead. The
vendored OpenVINO patch is exactly that shape, so it needs this coverage.

Mirrors release.yml's build-windows (both CRT platforms, build-runtime.ps1,
package.sh) and asserts openvino_backend.lib exists, since EXECUTORCH_BUILD_
OPENVINO is a cache variable cmake only warns about when unused."
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin feature/openvino-windows-enable
gh pr create --fill
```

The PR touches `patches/**`, `scripts/lib/openvino.sh` and `.github/workflows/extras-gate.yml`, all of which `classify-gate.sh` routes to **`full`** — so the gate runs `full-build`, `full-aot`, `full-gates` **and** the new `full-build-windows`. Expect roughly 20-25 minutes for the Windows arm; it has no ccache.

- [ ] **Step 7: Verify the gate proved what it claims**

In the `full-build-windows` logs for **both** platforms, confirm all three:

1. `et-openvino-windows.patch: applied` — from the patch phase. `already patched` here means a dirty cached checkout, not success.
2. `ok: openvino_backend.lib present` — the delegate compiled under MSVC.
3. The Package step succeeded — `package.sh`'s archive assertion accepted the MSVC name.

If (1) says `applied` but (2) fails, the patch landed and the enablement did not: check `--print-flags` for `-DEXECUTORCH_BUILD_OPENVINO=ON`.

---

## What this does NOT deliver

Stated plainly so the PR is not mistaken for finishing issue #37:

- **No runtime verification on Windows.** Nothing loads a `.pte` through the delegate on Windows. The loader semantics were verified standalone (`test/openvino/win_origin_probe.c`, on branch `feature/openvino-windows-origin-probe`), and the delegate now compiles — but the two have never met. That needs the bundle and the PowerShell gate ports.
- **No `win_amd64` bundle.** `vendor-openvino.sh` is still `linux-x86_64`-hardcoded, `ov_lib_members` is not platform-taking, and `EtRuntimePin.cmake` has no Windows OpenVINO rows.
- **No upstream ExecuTorch PR.** The patch is a clean, generally useful contribution and should be offered upstream; until then every ET pin bump must regenerate it and the fixtures together.
