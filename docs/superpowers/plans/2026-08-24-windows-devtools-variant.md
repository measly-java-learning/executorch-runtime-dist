# Windows `devtools` Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `devtools` tarballs for both Windows CRT platforms (`windows-x86_64`,
`windows-x86_64-static`), alongside the existing `logging`, in both `release.yml` and
`extras-gate.yml`'s Windows jobs.

**Architecture:** Two independent pieces. (1) A new, tested, non-swallowing replacement for the
untested inline `sed ... || true` in `build-runtime.sh` that fixes two Windows-only
`ExternalProject_Add` bugs in ET's `third-party/CMakeLists.txt` (`flatc_ep`/`flatcc_ep` byproduct
naming), verified live on `winbox` during the feasibility spike. (2) CI matrix + gate-routing
changes so `devtools` actually gets built on both Windows jobs, including a real artifact-name
collision in `extras-gate.yml`'s `full-build-windows`/`full-gates-windows` pair found while
reading those jobs closely for this plan (not previously known — `win-tarball-${{
matrix.platform }}` has no `variant` component, so two variants building the same platform would
collide).

**Tech Stack:** Bash (`set -euo pipefail`), GitHub Actions YAML, the repo's hermetic
`test/*.test.sh` + `test/assert.sh` harness (`bash test/run.sh`, ~2s, no build/container/ET
checkout), Python structural workflow-YAML tests under `test/lib/*.py`.

**Spec:** `docs/superpowers/specs/2026-08-24-windows-devtools-variant-design.md`

## Global Constraints

- Both Windows CRT platforms (`windows-x86_64`, `windows-x86_64-static`) ship `devtools`; `bare`
  stays Linux-only, untouched. (Spec §1, §2)
- No devtools-specific MSVC/C++20 incompatibility exists (spike-confirmed) — the only blocker is
  the two `flatcc_ep` upstream-file bugs, both must be fixed as part of this work. (Spec §3.1)
- The new fix must be idempotent, hard-fail (not `|| true`) on a moved anchor, and hermetically
  testable on Linux without an ET checkout — the standard this repo already holds `patches/*` to.
  (Spec §3.2, §3.3)
- `extras-gate.yml`'s `full-build-windows` matrix must mirror `release.yml`'s `build-windows`
  matrix exactly (variant AND platform), because a green `full` gate is supposed to mean the tag
  build will succeed. (Spec §4, existing `test/lib/extras_gate_windows.py` docstring)
- Do not touch: Windows extras (still skipped unconditionally), `bare` on any platform, any Linux
  job, `patches/et-devtools-headers.patch` (already Windows-compatible, spec-confirmed), `pin`
  job (already variant/platform-generic). Do not cut a release tag — follow-up, needs explicit
  user approval. (Spec §2 non-goals, §7)

---

## File Structure

- `scripts/patch-et-windows-byproducts.sh` — **new.** Fixes both `flatc_ep`/`flatcc_ep`
  `BUILD_BYPRODUCTS` byproduct-naming bugs and `flatcc_ep`'s missing
  `-DCMAKE_BUILD_TYPE=Release`, replacing the untested inline sed.
- `test/fixtures/etpatch/thirdparty-CMakeLists.txt` — **new.** Pristine fixture (real anchor
  text from the `v1.4.1` pin) the hermetic test patches against.
- `test/patch_et_windows_byproducts.test.sh` — **new.** Hermetic coverage for the new script.
- `build-runtime.sh` — **modify.** Replace the old inline sed with a call to the new script.
- `scripts/classify-gate.sh` — **modify.** Route edits to the new script to `full`.
- `.github/workflows/extras-gate.yml` — **modify.** `paths:` filter gains the new script;
  `full-build-windows` matrix gains `devtools`; its `win-tarball-*` artifact name gains
  `matrix.variant` (fixes the collision); `full-gates-windows` pins its download to the
  `logging` tarball explicitly.
- `.github/workflows/release.yml` — **modify.** `build-windows` matrix gains `devtools`; the
  descriptive comment above it is updated.
- `test/classify_gate.test.sh` — **modify.** New script path added to both existing coverage
  loops.
- `test/lib/extras_gate_windows.py` — **modify.** Assert the `variant` matrix (not just
  `platform`) matches between the two Windows jobs.
- `README.md` — **modify.** Note `devtools` now ships for both Windows platforms.
- `docs/devtools-header-install-handover.md` — **modify.** Flip §8's status.

---

### Task 1: `scripts/patch-et-windows-byproducts.sh` + hermetic test

**Files:**
- Create: `scripts/patch-et-windows-byproducts.sh`
- Create: `test/fixtures/etpatch/thirdparty-CMakeLists.txt`
- Test: `test/patch_et_windows_byproducts.test.sh`

**Interfaces:**
- Produces: `patch-et-windows-byproducts.sh <et-src>` — rewrites
  `<et-src>/third-party/CMakeLists.txt` in place. Exit 0 on success (including a no-op re-run on
  an already-patched tree), exit 1 on a missing/invalid argument, missing tree, missing file, or
  a moved anchor (post-condition check fails). No stdout contract beyond human-readable progress
  lines; consumed by Task 2 (build-runtime.sh's `IS_WINDOWS` block).

- [ ] **Step 1: Create the fixture (pristine, pre-patch content)**

Create `test/fixtures/etpatch/thirdparty-CMakeLists.txt` with exactly this content (the real
`third-party/CMakeLists.txt` anchor text at the `v1.4.1` pin, verified against a local ET
checkout pinned at this repo's `DEFAULT_ET_TAG="v1.4.1"`, commit
`e4d02f41f7909e8ed5bf4a14ffc520d733453d9f` — trimmed to the two `ExternalProject_Add` blocks the
script touches):

```cmake
# We use ExternalProject to build flatc from source to force it target the host.
# Otherwise, flatc will target the project's toolchain (i.e. iOS, or Android).
ExternalProject_Add(
  flatbuffers_ep
  PREFIX ${CMAKE_CURRENT_BINARY_DIR}/flatc_ep
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/flatc_ep/src/build
  SOURCE_DIR ${PROJECT_SOURCE_DIR}/third-party/flatbuffers
  CMAKE_ARGS
    -DFLATBUFFERS_BUILD_FLATC=ON
    -DFLATBUFFERS_INSTALL=ON
    -DFLATBUFFERS_BUILD_FLATHASH=OFF
    -DFLATBUFFERS_BUILD_FLATLIB=OFF
    -DFLATBUFFERS_BUILD_TESTS=OFF
    -DCMAKE_INSTALL_PREFIX:PATH=<INSTALL_DIR>
    -DCMAKE_CXX_FLAGS="-DFLATBUFFERS_MAX_ALIGNMENT=${EXECUTORCH_FLATBUFFERS_MAX_ALIGNMENT}"
    # Unset the toolchain to build for the host instead of the toolchain set for
    # the project.
    -DCMAKE_TOOLCHAIN_FILE=
    # If building for iOS, "unset" these variables to rely on the host (macOS)
    # defaults.
    $<$<AND:$<BOOL:${APPLE}>,$<BOOL:$<FILTER:${PLATFORM},EXCLUDE,^MAC>>>:-DCMAKE_OSX_SYSROOT=>
    -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${CMAKE_OSX_DEPLOYMENT_TARGET}
  BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc
                   ${_executorch_external_project_additional_args}
                   ${_flatbuffers_ep_additional_args}
)
ExternalProject_Get_Property(flatbuffers_ep INSTALL_DIR)
add_executable(flatc IMPORTED GLOBAL)
add_dependencies(flatc flatbuffers_ep)
if(CMAKE_HOST_WIN32)
  # flatbuffers does not use CMAKE_BUILD_TYPE. Internally, the build forces
  # Release config, but from CMake's perspective the build type is always Debug.
  set_target_properties(
    flatc PROPERTIES IMPORTED_LOCATION ${INSTALL_DIR}/bin/flatc.exe
  )
else()
  set_target_properties(
    flatc PROPERTIES IMPORTED_LOCATION ${INSTALL_DIR}/bin/flatc
  )
endif()

# MARK: - flatcc

if(WIN32)
  # For some reason, when configuring the external project during build
  # CMAKE_C_SIMULATE_ID is set to MSVC, but CMAKE_CXX_SIMULATE_ID is not set. To
  # make sure the external project is configured correctly, set it explicitly
  # here.
  set(_flatcc_extra_cmake_args -DCMAKE_CXX_SIMULATE_ID=MSVC)
else()
  set(_flatcc_extra_cmake_args)
endif()

# Similar to flatbuffers, we want to build flatcc for the host. See inline
# comments in the flatbuffers ExternalProject_Add for more details.
ExternalProject_Add(
  flatcc_ep
  PREFIX ${CMAKE_CURRENT_BINARY_DIR}/flatcc_ep
  SOURCE_DIR ${PROJECT_SOURCE_DIR}/third-party/flatcc
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/flatcc_ep/src/build
  CMAKE_ARGS
    -DFLATCC_RTONLY=OFF
    -DFLATCC_TEST=OFF
    -DFLATCC_REFLECTION=OFF
    -DFLATCC_DEBUG_CLANG_SANITIZE=OFF
    -DFLATCC_ALLOW_WERROR=OFF
    -DFLATCC_INSTALL=ON
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_INSTALL_PREFIX:PATH=<INSTALL_DIR>
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_TOOLCHAIN_FILE=
    $<$<AND:$<BOOL:${APPLE}>,$<BOOL:$<FILTER:${PLATFORM},EXCLUDE,^MAC>>>:-DCMAKE_OSX_SYSROOT=>
    -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${CMAKE_OSX_DEPLOYMENT_TARGET}
    ${_flatcc_extra_cmake_args}
  BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatcc
                   ${_executorch_external_project_additional_args}
                   ${_flatbuffers_ep_additional_args}
)
file(REMOVE_RECURSE ${PROJECT_SOURCE_DIR}/third-party/flatcc/lib)
ExternalProject_Get_Property(flatcc_ep INSTALL_DIR)
add_executable(flatcc_cli IMPORTED GLOBAL)
add_dependencies(flatcc_cli flatcc_ep)
if(CMAKE_HOST_WIN32)
  set_target_properties(
    flatcc_cli PROPERTIES IMPORTED_LOCATION ${INSTALL_DIR}/bin/flatcc.exe
  )
else()
  set_target_properties(
    flatcc_cli PROPERTIES IMPORTED_LOCATION ${INSTALL_DIR}/bin/flatcc
  )
endif()
```

Set permissions to match the sibling fixtures: `chmod 664
test/fixtures/etpatch/thirdparty-CMakeLists.txt`.

- [ ] **Step 2: Write the failing test**

Create `test/patch_et_windows_byproducts.test.sh`:

```bash
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash test/patch_et_windows_byproducts.test.sh`
Expected: FAIL — `scripts/patch-et-windows-byproducts.sh: No such file or directory` (script
doesn't exist yet).

- [ ] **Step 4: Implement `scripts/patch-et-windows-byproducts.sh`**

```bash
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
```

Make it executable: `chmod +x scripts/patch-et-windows-byproducts.sh`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash test/patch_et_windows_byproducts.test.sh`
Expected: PASS, all `ok:` lines, `ASSERT_FAILS=0`.

- [ ] **Step 6: Wire it into `build-runtime.sh`, replacing the old inline sed**

In `build-runtime.sh`, change:

```bash
if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — upstream flatc byproduct bug"
  sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' \
    "$ET_SRC/third-party/CMakeLists.txt" || true
fi
```

to:

```bash
if [ "$IS_WINDOWS" -eq 1 ]; then
  "$HERE/scripts/patch-et-windows-byproducts.sh" "$ET_SRC"
fi
```

- [ ] **Step 7: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 8: Commit**

```bash
git add scripts/patch-et-windows-byproducts.sh test/fixtures/etpatch/thirdparty-CMakeLists.txt \
  test/patch_et_windows_byproducts.test.sh build-runtime.sh
git commit -m "feat: fix flatcc_ep Windows byproduct naming, tested and non-swallowing"
```

---

### Task 2: Route the new script through `classify-gate.sh` + `extras-gate.yml`

**Files:**
- Modify: `scripts/classify-gate.sh`
- Modify: `.github/workflows/extras-gate.yml`
- Test: `test/classify_gate.test.sh`

**Interfaces:** None new — this task only makes sure an edit to Task 1's script is classified
`full` and the workflow that runs `full` actually starts for it, matching every other Windows/
OpenVINO-adjacent script already in both lists.

- [ ] **Step 1: Write the failing test**

In `test/classify_gate.test.sh`, add `scripts/patch-et-windows-byproducts.sh` to the existing
`for f in ...` full-surface loop (the one starting `for f in scripts/vendor-openvino.sh
scripts/lib/openvino.sh \`):

```bash
for f in scripts/vendor-openvino.sh scripts/lib/openvino.sh \
         test/openvino_smoke.sh test/openvino_fixture_run.sh test/openvino/ov_runner.cpp \
         scripts/patch-et-sources.sh scripts/patch-et-windows-byproducts.sh \
         patches/et-xnnpack-workspace-size.patch test/xnnpack_workspace_run.sh \
         .github/workflows/extras-gate.yml; do
```

And add it to the reachability loop (the one starting `for p in scripts/vendor-openvino.sh
scripts/lib/openvino.sh scripts/lib/cmakeflags.sh \`):

```bash
for p in scripts/vendor-openvino.sh scripts/lib/openvino.sh scripts/lib/cmakeflags.sh \
         test/openvino_smoke.sh test/openvino_fixture_run.sh 'test/openvino/**' \
         scripts/patch-et-sources.sh scripts/patch-et-windows-byproducts.sh \
         scripts/emit-xnnpack-fixtures.py \
         'patches/**' test/xnnpack_workspace_run.sh 'test/xnnpack_workspace/**'; do
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/classify_gate.test.sh`
Expected: FAIL on both new assertions — `classify-gate.sh` doesn't yet route
`scripts/patch-et-windows-byproducts.sh` to `full` (routes to `tier1` instead), and
`extras-gate.yml`'s `paths:` filter doesn't yet contain it.

- [ ] **Step 3: Implement — `classify-gate.sh`**

Change:

```bash
if grep -qxE 'scripts/(vendor-openvino\.sh|lib/openvino\.sh|patch-et-sources\.sh|emit-xnnpack-fixtures\.py)|patches/.*|test/xnnpack_workspace(_run\.sh|/.*)|test/openvino(_smoke(-windows)?\.sh|_fixture_run(-windows)?\.sh|/.*)|\.github/workflows/extras-gate\.yml|\.build-image|scripts/(lib/ccache\.sh|install-ccache\.sh|ccache-stats\.sh)' "$CHANGED"; then
```

to:

```bash
if grep -qxE 'scripts/(vendor-openvino\.sh|lib/openvino\.sh|patch-et-sources\.sh|patch-et-windows-byproducts\.sh|emit-xnnpack-fixtures\.py)|patches/.*|test/xnnpack_workspace(_run\.sh|/.*)|test/openvino(_smoke(-windows)?\.sh|_fixture_run(-windows)?\.sh|/.*)|\.github/workflows/extras-gate\.yml|\.build-image|scripts/(lib/ccache\.sh|install-ccache\.sh|ccache-stats\.sh)' "$CHANGED"; then
```

- [ ] **Step 4: Implement — `extras-gate.yml` paths filter**

In the `on: pull_request: paths:` list, change:

```yaml
      # Workspace-size surface, same reasoning: these run only in `full`, so without a trigger an
      # edit to one would ship with no run at all.
      - 'scripts/patch-et-sources.sh'
      - 'scripts/emit-xnnpack-fixtures.py'
```

to:

```yaml
      # Workspace-size surface, same reasoning: these run only in `full`, so without a trigger an
      # edit to one would ship with no run at all.
      - 'scripts/patch-et-sources.sh'
      # Windows-only flatc(c)_ep byproduct-naming fix (see build-runtime.sh's IS_WINDOWS block).
      # Same reasoning: only exercised by full-build-windows, which only runs in `full`.
      - 'scripts/patch-et-windows-byproducts.sh'
      - 'scripts/emit-xnnpack-fixtures.py'
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash test/classify_gate.test.sh`
Expected: PASS, all assertions succeed (no `FAIL:` lines), `$fail` stays 0.

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Commit**

```bash
git add scripts/classify-gate.sh .github/workflows/extras-gate.yml test/classify_gate.test.sh
git commit -m "chore(ci): route the Windows byproduct fix through the full gate"
```

---

### Task 3: `release.yml` — add `devtools` to the `build-windows` matrix

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:** None new. `Package`, `Relocatability smoke`, and `CRT consistency scan` steps
already read `matrix.variant`/`matrix.platform` generically — no step body changes.

- [ ] **Step 1: Update the descriptive comment**

Change:

```yaml
  #
  # Windows amd64 support is implemented via `build-windows` below (MSVC, logging variant
  # only, GitHub-hosted windows-2022 runner, no container). It builds TWO platforms that differ
  # only in the C runtime — windows-x86_64 (/MD, for CPython extensions) and
  # windows-x86_64-static (/MT, for self-contained JNI DLLs) — because MSVC bakes the CRT into
  # every object and a consumer must link the flavor matching its own. NOTE: these platforms are
  # NOT in env.PLATFORMS; that list drives the linux container matrix only. macOS remains future
  # work and would follow this job's pattern, uploading via the same `dist-variant-platform`
  # naming and added to `pin`'s `needs`.
```

to:

```yaml
  #
  # Windows amd64 support is implemented via `build-windows` below (MSVC, GitHub-hosted
  # windows-2022 runner, no container). It builds `logging` and `devtools` (bare stays
  # Linux-only — never requested for Windows) across TWO platforms that differ only in the C
  # runtime — windows-x86_64 (/MD, for CPython extensions) and windows-x86_64-static (/MT, for
  # self-contained JNI DLLs) — because MSVC bakes the CRT into every object and a consumer must
  # link the flavor matching its own. devtools needs two upstream-file fixes to ET's
  # third-party/CMakeLists.txt flatcc_ep block to compile under MSVC at all; see
  # scripts/patch-et-windows-byproducts.sh and spike/2026-08-24-windows-devtools-variant-spike.md.
  # NOTE: these platforms are NOT in env.PLATFORMS; that list drives the linux container matrix
  # only. macOS remains future work and would follow this job's pattern, uploading via the same
  # `dist-variant-platform` naming and added to `pin`'s `needs`.
```

- [ ] **Step 2: Grow the variant matrix**

Change:

```yaml
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
        # Two CRT flavors. MSVC bakes the CRT into every object, so a consumer must link the one
        # matching its own: /MD for CPython extensions, /MT for self-contained JNI DLLs.
        platform: [windows-x86_64, windows-x86_64-static]
```

to:

```yaml
    strategy:
      fail-fast: false
      matrix:
        variant: [logging, devtools]
        # Two CRT flavors. MSVC bakes the CRT into every object, so a consumer must link the one
        # matching its own: /MD for CPython extensions, /MT for self-contained JNI DLLs.
        platform: [windows-x86_64, windows-x86_64-static]
```

- [ ] **Step 3: Structural sanity check**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "ok: release.yml parses"`
Expected: `ok: release.yml parses`.

Run: `bash test/release_workflow.test.sh`
Expected: PASS (this test doesn't assert on the variant matrix, so it should already pass
unchanged — confirms the edit didn't break anything it does check).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): publish devtools for both Windows CRT platforms"
```

---

### Task 4: `extras-gate.yml` — mirror the matrix, fix the artifact-name collision

**Files:**
- Modify: `.github/workflows/extras-gate.yml`
- Modify: `test/lib/extras_gate_windows.py`

**Interfaces:**
- Produces: `full-build-windows` uploads one artifact per `(variant, platform)` pair, named
  `win-tarball-${{ matrix.variant }}-${{ matrix.platform }}` (was `win-tarball-${{
  matrix.platform }}`, which two variants building the same platform would collide on: GitHub
  Actions artifact names must be unique within a run, and a same-name re-upload from another
  matrix leg either overwrites unpredictably or errors, depending on the action version — either
  way, not something to find out at release time). `full-gates-windows` downloads exactly
  `win-tarball-logging-${{ matrix.platform }}` — pinned to `logging` explicitly, matching the
  existing Linux precedent (`release.yml`'s LSTM round-trip gate also runs `if matrix.variant ==
  'logging'` only) that expensive runtime-behavior gates run once per platform against a
  representative variant, not every variant; `devtools`'s own correctness on Windows is already
  covered by `full-build-windows`'s per-leg relocatability-smoke and CRT-scan steps.

- [ ] **Step 1: Write the failing test**

In `test/lib/extras_gate_windows.py`, add a variant-matrix parity check alongside the existing
platform-matrix one. Change:

```python
    # Same platform axis as the release job, or the gate proves less than it claims.
    gate_platforms = set(job["strategy"]["matrix"]["platform"])
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"platform matrix {sorted(gate_platforms)} != release {sorted(rel_platforms)}")
```

to:

```python
    # Same platform AND variant axes as the release job, or the gate proves less than it claims —
    # this is the property that makes "green full gate" mean "the eventual release tag builds."
    gate_platforms = set(job["strategy"]["matrix"]["platform"])
    rel_platforms = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["platform"])
    if gate_platforms != rel_platforms:
        fails.append(f"platform matrix {sorted(gate_platforms)} != release {sorted(rel_platforms)}")

    gate_variants = set(job["strategy"]["matrix"]["variant"])
    rel_variants = set(release["jobs"]["build-windows"]["strategy"]["matrix"]["variant"])
    if gate_variants != rel_variants:
        fails.append(f"variant matrix {sorted(gate_variants)} != release {sorted(rel_variants)}")
```

- [ ] **Step 2: Run test to verify it fails**

Task 3 already landed `variant: [logging, devtools]` into `release.yml`'s `build-windows`, while
`extras-gate.yml`'s `full-build-windows` still reads `variant: [logging]` — so this assertion has
a real mismatch to catch right now, without needing any temporary edits.

Run: `python3 test/lib/extras_gate_windows.py`
Expected: FAIL — `variant matrix ['logging'] != release ['devtools', 'logging']`.

- [ ] **Step 3: Grow the `full-build-windows` variant matrix + fix the artifact name**

Change:

```yaml
  full-build-windows:
    needs: classify
    if: needs.classify.outputs.mode == 'full'
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
        platform: [windows-x86_64, windows-x86_64-static]
```

to:

```yaml
  full-build-windows:
    needs: classify
    if: needs.classify.outputs.mode == 'full'
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        # Mirrors release.yml's build-windows matrix exactly (test/lib/extras_gate_windows.py
        # asserts this) -- a green `full` gate means the eventual release tag will build.
        variant: [logging, devtools]
        platform: [windows-x86_64, windows-x86_64-static]
```

Then, in the same job's upload step, change:

```yaml
      - uses: actions/upload-artifact@v7
        with:
          name: win-tarball-${{ matrix.platform }}
          path: dist/*.tar.gz
          retention-days: 1
```

to:

```yaml
      - uses: actions/upload-artifact@v7
        with:
          # Includes matrix.variant: two variants building the same platform would otherwise
          # upload under the identical name and collide (artifact names must be unique per run).
          name: win-tarball-${{ matrix.variant }}-${{ matrix.platform }}
          path: dist/*.tar.gz
          retention-days: 1
```

- [ ] **Step 4: Pin `full-gates-windows`'s download to the `logging` tarball**

Change:

```yaml
      - uses: actions/download-artifact@v8
        with:
          name: win-tarball-${{ matrix.platform }}
          path: winpkg
```

(in the `full-gates-windows` job) to:

```yaml
      - uses: actions/download-artifact@v8
        with:
          # Pinned to logging: this job gates OpenVINO delegate BEHAVIOUR at runtime, which
          # doesn't vary by devtools/logging (same reasoning release.yml's LSTM round-trip gate
          # uses to run only `if matrix.variant == 'logging'`). devtools's own correctness on
          # Windows is covered by full-build-windows's per-leg relocatability-smoke and CRT-scan
          # steps instead of a second, redundant runtime-fixture leg here.
          name: win-tarball-logging-${{ matrix.platform }}
          path: winpkg
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 test/lib/extras_gate_windows.py`
Expected: `ok: full-build-windows mirrors release build-windows`.

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/extras-gate.yml'))" && echo "ok: extras-gate.yml parses"`
Expected: `ok: extras-gate.yml parses`.

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/extras-gate.yml test/lib/extras_gate_windows.py
git commit -m "fix(ci): mirror devtools into full-build-windows, fix win-tarball artifact collision"
```

---

### Task 5: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/devtools-header-install-handover.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Update `README.md`**

In the "Variants" section, change:

```markdown
## Variants

Each release builds three variants of the runtime for `linux-x86_64`:

- `bare` — logging off (smallest).
- `logging` — logging on. **Ship default.**
- `devtools` — devtools + event tracer (profiling/debug).
```

to:

```markdown
## Variants

Each release builds three variants of the runtime for `linux-x86_64`:

- `bare` — logging off (smallest).
- `logging` — logging on. **Ship default.**
- `devtools` — devtools + event tracer (profiling/debug).

Windows (`windows-x86_64` /MD, `windows-x86_64-static` /MT) ships `logging` and `devtools`;
`bare` stays Linux-only.
```

- [ ] **Step 2: Update the handover doc's §8 status**

In `docs/devtools-header-install-handover.md`, change:

```markdown
## 8. Optional separate workstream — Windows devtools rows

Independent of the above and not a blocker. The pin currently publishes `devtools` for
`linux-x86_64` and `linux-aarch64` only; Windows has `logging` and `logging…-static`. If Windows
devtools is published, the engine needs **both** CRT rows — `windows-x86_64` and
`windows-x86_64-static` — because it links the `/MT` static row so its DLL needs no VC++
redistributable. A single `/MD` devtools row is not usable by that consumer.
```

to:

```markdown
## 8. Windows devtools rows — implemented

`devtools` now ships for both Windows CRT rows (`windows-x86_64`, `windows-x86_64-static`) — see
`docs/superpowers/plans/2026-08-24-windows-devtools-variant.md` and
`spike/2026-08-24-windows-devtools-variant-spike.md`. Not yet released (no new tag pushed as of
this writing).
```

And update the top status line from:

```markdown
**Status:** items 1-3 implemented — see
`docs/superpowers/plans/2026-08-24-devtools-header-install.md`. Not yet released (no
`v1.4.1-3` tag pushed). §8 (Windows devtools rows) remains a separate, unstarted workstream.
```

to:

```markdown
**Status:** items 1-3 and §8 implemented — see
`docs/superpowers/plans/2026-08-24-devtools-header-install.md` and
`docs/superpowers/plans/2026-08-24-windows-devtools-variant.md`. Not yet released (no new tag
pushed as of this writing).
```

- [ ] **Step 3: Run the full suite (docs-only sanity check)**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/devtools-header-install-handover.md
git commit -m "docs: note the Windows devtools rows are implemented"
```

---

## Post-plan follow-up (not part of this plan's tasks)

- Cutting a release tag that includes this change is a user-authorized action, not something to
  do as part of implementing this plan. Ask the user once Tasks 1-5 are merged to `main`.
- The spike's live winbox edits (the same two fixes, applied by hand during feasibility testing)
  are throwaway and were never committed anywhere — `spike/2026-08-24-windows-devtools-variant-spike.md`'s
  *Afterwards* section already says so. Once this plan's Task 1 lands and is verified (ideally by
  re-running the actual Windows build once against the new script — ⚠️ this plan does not include
  a live Windows CI run as a task, since `bash test/run.sh` is hermetic and does not build
  anything; the FIRST real signal that `scripts/patch-et-windows-byproducts.sh` works on a real
  MSVC toolchain will be the next `full` gate run or release-tag push), winbox's leftover state
  (`out-devtools-md`, `et-build-devtools-md`, the live-edited `$EtSrc`, scratch driver scripts) can
  be cleaned up.
