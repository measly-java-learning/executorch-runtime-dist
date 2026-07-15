# Windows (amd64) Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce attested, hash-pinned, relocatable `windows-x86_64` ExecuTorch runtime tarballs (`logging` variant, core-only) from the existing build/package/CI pipeline.

**Architecture:** Reuse `build-runtime.sh` + `scripts/lib/*` under Git-Bash on a GitHub-hosted `windows-2022` runner; MSVC env activation happens in a `pwsh` workflow step (`Launch-VsDevShell`) that then invokes the bash recipe in the same session. The recipe configures ET with `-G Ninja --preset windows`, skips phase-2 extras, and reuses the generic relocatability repair. A single new `et_preset` SSOT function drives the preset for both the build and the recorded provenance.

**Tech Stack:** Bash, PowerShell (workflow only), CMake + Ninja + MSVC, GitHub Actions (`windows-2022`), the repo's `test/assert.sh` harness.

## Global Constraints

- **Prerequisite:** the pin-job filesystem-discovery refactor (`docs/superpowers/plans/2026-07-15-pin-filesystem-discovery.md`) is **already merged**. This plan does **not** modify the `pin` job's row generation.
- Platform string: **`windows-x86_64`**. Variant: **`logging`** only. **Core-only** — no `extras/`, no USDT (Linux-only by contract), no `bare`/`devtools`.
- CMake preset: **`--preset windows`** (ET 1.3.1 `tools/cmake/preset/windows.cmake`). Generator: **Ninja + MSVC**, single-config.
- Runner: GitHub-hosted **`windows-2022`** (ships Python, CMake, Ninja, VS Enterprise 2022) — **no conda, no external toolchain actions**.
- Wire format stays **`.tar.gz` + `.sha256`**; `naming.sh` unchanged.
- SSOT invariant (C5): one function computes flags/preset, both the build (`build-runtime.sh`) and recorded provenance (`package.sh`) consume it — never a second copy.
- Shell scripts run under `set -euo pipefail`; guard `grep`/glob no-match with `|| true`/`[ -e ]` (repo convention).
- `test/run.sh` auto-globs `*.test.sh`; new tests need only be placed in `test/`.

---

### Task 1: Windows build spike (de-risk, gates later specifics)

**Not TDD — this is a CI-run investigation.** It runs on a real `windows-2022` runner (nothing here is reproducible on the Linux dev box) and records findings that confirm/adjust Tasks 4–5. Front-loaded per spec §7.

**Files:**
- Create: `.github/workflows/windows-spike.yml` (throwaway `workflow_dispatch`; deleted in Task 6)
- Create: `spike/windows-msvc-spike.md` (findings; `spike/` is throwaway per CLAUDE.md)

**Interfaces:**
- Produces: recorded answers to spike items (torch-needed?, logging-compiles?, cmake leaks?, consumer feature diff) that Tasks 4–5 reference.

- [ ] **Step 1: Add a throwaway spike workflow**

Create `.github/workflows/windows-spike.yml`:

```yaml
name: windows-spike
on: { workflow_dispatch: {} }
permissions: { contents: read }
jobs:
  spike:
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@v7
      - name: Checkout ExecuTorch source
        uses: ./.github/actions/checkout-executorch
        with: { ref: v1.3.1 }
      - name: Configure + build + install (MSVC, preset windows, logging)
        shell: pwsh
        run: |
          & "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
          $src = "$PWD/et-src/executorch"; $pfx = "$PWD/out"; $bld = "$PWD/bld"
          # Spike item 2: try configuring WITHOUT torch first; note whether it fails.
          cmake -B $bld -S $src -G Ninja --preset windows `
            -DCMAKE_INSTALL_PREFIX="$pfx" -DEXECUTORCH_ENABLE_LOGGING=ON 2>&1 | Tee-Object cfg.log
          cmake --build $bld 2>&1 | Tee-Object build.log
          cmake --install $bld --prefix $pfx
      - name: Measure relocatability leaks + feature footprint
        shell: bash
        run: |
          echo "== absolute-path leaks in lib/cmake =="
          grep -rlE 'C:\\|/bld/|Windows Kits|Microsoft Visual Studio' out/lib/cmake || echo "NONE"
          echo "== installed cmake config files =="
          find out/lib/cmake -name '*.cmake' | sort
          echo "== installed libs =="
          find out/lib -name '*.lib' | sort
      - uses: actions/upload-artifact@v7
        with: { name: spike-logs, path: "*.log" }
```

- [ ] **Step 2: Trigger it and capture results**

Run: `gh workflow run windows-spike.yml --ref feature/windows-amd64-artifacts` then watch with `gh run watch`.
Expected: the job either succeeds (records the four answers) or fails with a specific error that IS the finding.

- [ ] **Step 3: Record findings**

Write `spike/windows-msvc-spike.md` answering, with evidence from the run:
1. **torch at configure time?** Did the no-torch configure succeed? → decides whether Task 4 keeps or trims the `torch` pip install on Windows.
2. **logging compiles clean on MSVC?** → confirms the core deliverable is viable.
3. **cmake config leaks?** Did the grep find `C:\`/build-dir/SDK paths in `out/lib/cmake`? → decides whether Task 4 needs a Windows-specific normalization beyond the reused prefix-leak rewrite.
4. **consumer feature diff (§6).** Compare installed targets/libs against what the JVM + Python consumers link; note whether any override (e.g. `-DEXECUTORCH_BUILD_EXTENSION_LLM=ON`, as upstream's own workflow forces) is required.

- [ ] **Step 4: Commit the spike notes**

```bash
git add .github/workflows/windows-spike.yml spike/windows-msvc-spike.md
git commit -m "spike: windows MSVC build investigation (preset windows, logging)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> **Gate:** Tasks 4–5 below assume the spike's expected outcome (logging compiles, prefix-leak rewrite suffices, torch kept, no LLM override needed). Where a finding differs, apply the adjustment named in that task's notes. Any Windows-specific cmake normalization beyond the reused prefix-leak rewrite (finding 3) is **out of this plan's guaranteed scope** and, if needed, becomes a follow-up.

---

### Task 2: `et_preset` SSOT function + unit test

**Files:**
- Create: `scripts/lib/preset.sh`
- Test: `test/lib_preset.test.sh`

**Interfaces:**
- Produces: `et_preset <platform>` → prints `windows` for `windows-*`, `linux` for `linux-*`, returns `2` on unknown. Consumed by `build-runtime.sh` (Task 4) and `package.sh` (Task 3).

- [ ] **Step 1: Write the failing test**

Create `test/lib_preset.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/preset.sh"
assert_eq "$(et_preset linux-x86_64)"   "linux"   "linux x86_64 -> linux preset"
assert_eq "$(et_preset linux-aarch64)"  "linux"   "linux aarch64 -> linux preset"
assert_eq "$(et_preset windows-x86_64)" "windows" "windows x86_64 -> windows preset"
et_preset bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_preset.test.sh`
Expected: FAIL — `scripts/lib/preset.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/preset.sh`:

```bash
#!/usr/bin/env bash
# Platform -> ExecuTorch CMake preset name (SSOT). Shared by build-runtime.sh (the build) and
# package.sh (recorded provenance) so the two can never disagree on which preset built the artifact.
# Source me.
et_preset() { # <platform>  e.g. linux-x86_64, windows-x86_64
  case "$1" in
    windows-*) printf 'windows' ;;
    linux-*)   printf 'linux' ;;
    *) echo "et_preset: unknown platform '$1'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_preset.test.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/preset.sh test/lib_preset.test.sh
git commit -m "feat: add et_preset SSOT (platform -> cmake preset)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `package.sh` — `--toolchain` param + record preset in provenance

**Files:**
- Modify: `scripts/package.sh:7` (source `preset.sh`), `:9-23` (parse `--toolchain`), `:46-51` (record preset + toolchain)
- Test: `test/package.test.sh` (extend)

**Interfaces:**
- Consumes: `et_preset <platform>` (Task 2).
- Produces: `package.sh ... [--toolchain <str>]` — records `toolchain=<str>` (default preserves the current manylinux string) and prepends `--preset <name>` to the recorded `cmake_flags` in BUILDINFO.

- [ ] **Step 1: Write the failing test (extend package.test.sh)**

Add before the final `exit "$ASSERT_FAILS"` in `test/package.test.sh`:

```bash
# --- provenance: --toolchain override + recorded preset (Windows-parity plumbing) ---
pw="$(mktemp -d)/pfxw"
mkdir -p "$pw/lib/cmake/ExecuTorch" "$pw/include" "$pw/THIRD-PARTY-NOTICES"
: > "$pw/lib/cmake/ExecuTorch/executorch-config.cmake"; : > "$pw/include/et.h"; : > "$pw/LICENSE"
: > "$pw/THIRD-PARTY-NOTICES/xnnpack_LICENSE"; echo deadbeef > "$pw/.et_commit"; echo "n/a" > "$pw/.etnp_usdt"
outw="$(mktemp -d)"
tbw="$(bash "$here/../scripts/package.sh" --prefix "$pw" --etver 1.3.1 --variant logging \
  --platform windows-x86_64 --package-tag v1.3.1-1 --outdir "$outw" --toolchain msvc-2022)"
bi="$(tar -xzOf "$tbw" executorch-runtime-1.3.1-logging-windows-x86_64/BUILDINFO)"
assert_contains "$bi" "toolchain=msvc-2022"        "--toolchain override recorded"
assert_contains "$bi" "cmake_flags=--preset windows" "windows preset recorded in provenance"
assert_contains "$bi" "usdt=n/a"                    "core-only usdt sentinel recorded"

# Default toolchain preserved when --toolchain omitted (linux back-compat), and linux preset recorded.
outl="$(mktemp -d)"
tbl="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$outl")"
bil="$(tar -xzOf "$tbl" executorch-runtime-1.3.1-logging-linux-x86_64/BUILDINFO)"
assert_contains "$bil" "toolchain=manylinux_2_28 gcc-toolset-14" "default toolchain preserved"
assert_contains "$bil" "cmake_flags=--preset linux"              "linux preset recorded in provenance"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/package.test.sh`
Expected: FAIL — `--toolchain` is an unknown arg (`exit 2`) and no `--preset` appears in `cmake_flags`.

- [ ] **Step 3: Implement the package.sh changes**

In `scripts/package.sh`, after `. "$HERE/lib/cmakeflags.sh"` (line 7) add:

```bash
. "$HERE/lib/preset.sh"
```

Add the `--toolchain` var + parse. Change the declaration line (9):

```bash
PREFIX=""; ETVER=""; VARIANT=""; PLATFORM=""; PACKAGE_TAG=""; OUTDIR="."; TOOLCHAIN=""
```

Add a case arm alongside the others (after `--outdir`):

```bash
    --toolchain) TOOLCHAIN="$2"; shift 2 ;;
```

Default the toolchain to the current manylinux string when unset (keeps Linux callers identical) — add right after the required-args loop (after line 23):

```bash
: "${TOOLCHAIN:=manylinux_2_28 gcc-toolset-14}"
```

Change the BUILDINFO generation block (lines 46–51) to prepend the preset and use the parameterized toolchain:

```bash
CMAKE_FLAGS="--preset $(et_preset "$PLATFORM") $(variant_flags "$VARIANT") $(common_cmake_flags)"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="$TOOLCHAIN" PACKAGE_TAG="$PACKAGE_TAG" \
  USDT="$USDT_STATE" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/package.test.sh && bash test/buildinfo.test.sh`
Expected: both all-`ok:`. (`buildinfo.test.sh` passes its own env and is unaffected; `package.test.sh` now covers windows + linux provenance.)

- [ ] **Step 5: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo the known `extras_members` fresh-checkout caveat).

- [ ] **Step 6: Commit**

```bash
git add scripts/package.sh test/package.test.sh
git commit -m "feat: package.sh --toolchain param + record cmake preset in provenance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `build-runtime.sh` — Windows path

**Files:**
- Modify: `build-runtime.sh` — source `preset.sh`; add `--platform`; OS-guarded preset/parallelism/toolchain-echo/extras/syslib/license/usdt-sentinel branches.

**Interfaces:**
- Consumes: `et_preset <platform>` (Task 2).
- Produces: a relocatable core-only install at `--prefix` on Windows (with `.etnp_usdt=n/a` sentinel), consumed by `package.sh` (Task 3).

**Verification note:** this edits the cmake-driving recipe, which has no hermetic unit seam — the Linux `--print-flags` regression (below) plus the real Windows CI run in **Task 6** are the verification. Do not claim it works from the edits alone.

- [ ] **Step 1: Source preset.sh + add OS/platform detection**

In `build-runtime.sh`, after `. "$HERE/scripts/lib/cmakeflags.sh"` (line 13) add:

```bash
. "$HERE/scripts/lib/preset.sh"
```

Add `--platform` to the arg vars (line 32) — default `linux-x86_64` keeps existing local/Linux invocations unchanged:

```bash
VARIANT=""; PREFIX=""; ET_SRC=""; ET_TAG="$DEFAULT_ET_TAG"; BUILD_DIR=""; PRINT_FLAGS=0; PLATFORM="linux-x86_64"
```

Add the parse arm (alongside the others near line 40):

```bash
    --platform) PLATFORM="${2:-}"; shift 2 ;;
```

After arg parsing (after line 47), derive preset + OS flag:

```bash
PRESET="$(et_preset "$PLATFORM")"     # returns 2 on unknown platform -> set -e aborts
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac
```

- [ ] **Step 2: Guard the toolchain-version echo (lines 188–193)**

Replace the `gcc --version` / `g++ --version` lines with an OS guard:

```bash
echo ">> Toolchain versions"
cmake --version
if [ "$IS_WINDOWS" -eq 1 ]; then cl 2>&1 | head -1 || true; else gcc --version; g++ --version; fi
ninja --version
python -V
```

- [ ] **Step 3: Use the preset + portable parallelism (lines 195–202)**

```bash
echo ">> configuring ($VARIANT, preset=$PRESET)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja --preset "$PRESET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  $VARIANT_FLAGS $(common_cmake_flags)

echo ">> building"
if [ "$IS_WINDOWS" -eq 1 ]; then JOBS="${NUMBER_OF_PROCESSORS:-4}"; else JOBS="$(nproc)"; fi
cmake --build "$ET_BUILD" -j"$JOBS"
```

- [ ] **Step 4: Skip phase-2 extras on Windows; write the usdt sentinel (line 208)**

Replace the bare `build_extras` call with:

```bash
if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> Windows: core-only build, skipping extras (phase 2)"
  printf 'n/a\n' > "$PREFIX/.etnp_usdt"   # packaging requires this marker; no extras/USDT on Windows
else
  build_extras
fi
```

- [ ] **Step 5: Skip Linux-only syslib normalization + Highway license on Windows**

Wrap the syslib-normalization block (lines 228–235) so it runs only on Linux:

```bash
if [ "$IS_WINDOWS" -eq 0 ]; then
  echo ">> normalizing absolute system-library paths to -l<name> (portability across host libdirs)"
  syslib="$(grep -rlE '/usr/lib64/lib[a-z0-9_]+\.(so|a)' "$PREFIX/lib/cmake" 2>/dev/null || true)"
  if [ -n "$syslib" ]; then
    echo ">> WARNING: absolute system-lib paths leaked into cmake configs; rewriting to bare link names"
    printf '%s\n' "$syslib" | while read -r f; do
      sed -i -E 's#/usr/lib64/lib([a-z0-9_]+)\.(so|a)#\1#g' "$f"
    done
  fi
fi
```

Guard the `install_highway_license` call (line 250) — Highway is fetched only by the (skipped) extras build:

```bash
if [ "$IS_WINDOWS" -eq 0 ]; then install_highway_license; fi
```

The generic prefix-leak "measuring relocatability" block (lines 210–218) is **left unguarded** — it runs on all platforms and is the reused Windows relocatability repair (spike finding 3 confirms it suffices; any extra normalization is a follow-up).

> **Spike reconciliation (finding 1):** if the spike showed the core configure needs `torch`, leave the `torch` pip install (lines 184–186) as-is. If it showed torch is not needed on Windows, guard those lines with `if [ "$IS_WINDOWS" -eq 0 ]` to skip the ~minutes-long download. Default (no change) is always correct, only slower.

- [ ] **Step 6: Regression-check the Linux dry path**

Run: `bash build-runtime.sh --print-flags --variant logging`
Expected: prints `-DEXECUTORCH_ENABLE_LOGGING=ON` and exits 0 (the `--print-flags` path is unchanged and proves the edits didn't break arg parsing / sourcing).
Run: `bash -n build-runtime.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 7: Commit**

```bash
git add build-runtime.sh
git commit -m "feat: build-runtime.sh Windows path (preset windows, core-only, no extras)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `release.yml` — `build-windows` job

**Files:**
- Modify: `.github/workflows/release.yml` — add `build-windows` job; add it to the `pin` job's `needs`.

**Interfaces:**
- Consumes: `build-runtime.sh --platform windows-x86_64` (Task 4), `package.sh --toolchain msvc-2022` (Task 3), the existing `checkout-executorch` composite action.
- Produces: `dist-logging-windows-x86_64` artifact (tarball + sha256), discovered by the (already-refactored) `pin` job.

- [ ] **Step 1: Add the `build-windows` job**

In `.github/workflows/release.yml`, add after the `build` job (before `pin`):

```yaml
  build-windows:
    needs: setup
    runs-on: windows-2022
    permissions:
      contents: read
      id-token: write
      attestations: write
    strategy:
      fail-fast: false
      matrix:
        variant: [logging]
    steps:
      - uses: actions/checkout@v7
      - name: Derive versions from tag
        id: ver
        shell: bash
        run: ./scripts/derive-version.sh >> "$GITHUB_OUTPUT"
      - name: Checkout ExecuTorch source
        uses: ./.github/actions/checkout-executorch
        with:
          ref: ${{ steps.ver.outputs.ettag }}
      - name: Build runtime (MSVC)
        shell: pwsh
        run: |
          & "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
          bash ./build-runtime.sh --variant ${{ matrix.variant }} `
            --prefix "$PWD/out" --et-src "$PWD/et-src/executorch" `
            --et-tag ${{ steps.ver.outputs.ettag }} --platform windows-x86_64
      - name: Package
        shell: bash
        run: |
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ steps.ver.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform windows-x86_64 \
            --package-tag "${GITHUB_REF_NAME}" --outdir "$PWD/dist" \
            --toolchain "msvc-2022"
      - name: Attest build provenance
        uses: actions/attest@v4
        with:
          subject-path: dist/*.tar.gz
      - uses: actions/upload-artifact@v7
        with:
          name: dist-${{ matrix.variant }}-windows-x86_64
          path: dist/*
```

- [ ] **Step 2: Make `pin` wait for `build-windows`**

Change the `pin` job's `needs: build` to:

```yaml
  pin:
    needs: [build, build-windows]
```

(The refactored `pin` job already discovers whatever artifacts land in `dist/`, so no other pin change is needed.)

- [ ] **Step 3: Drop the hardcoded `manylinux` from release notes**

In the `release` job's `gh release create` (`--notes`), replace the hardcoded `manylinux_2_28` string with a platform-neutral note, since per-artifact toolchain now lives in each `BUILDINFO`:

```yaml
          --notes "ExecuTorch runtime ${GITHUB_REF_NAME} (torch 2.12.0+cpu). Per-artifact toolchain in each BUILDINFO." \
```

- [ ] **Step 4: Sanity-check the YAML**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo YAML_OK`
Expected: `YAML_OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add build-windows job (windows-x86_64, logging)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end CI validation + spike cleanup

**Files:**
- Delete: `.github/workflows/windows-spike.yml` (throwaway from Task 1)

**Verification:** a real release-tag dry run producing a genuine Windows artifact and confirming the whole chain (build → relocatable install → package → attest → pin discovery).

- [ ] **Step 1: Remove the throwaway spike workflow**

```bash
git rm .github/workflows/windows-spike.yml
git commit -m "chore: remove windows spike workflow (superseded by build-windows)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 2: Push and cut a pre-release test tag**

Push the branch, then push a throwaway pre-release tag matching the release trigger `v*-*` (bump `<pkgrev>` so it doesn't collide with a real release):

```bash
git push -u origin feature/windows-amd64-artifacts
git tag v1.3.1-99-win-test && git push origin v1.3.1-99-win-test
```

- [ ] **Step 3: Watch the release run**

Run: `gh run watch` (select the `release` workflow run for the tag).
Expected, in order:
- `build-windows / logging` job green.
- Artifact `dist-logging-windows-x86_64` uploaded containing `executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz` + `.sha256`.
- `pin` job green; `EtRuntimePin.cmake` in the step summary contains both `..._logging_linux-x86_64` and `..._logging_windows-x86_64` rows.

- [ ] **Step 4: Verify the Windows artifact's contents + provenance**

Download and inspect:

```bash
gh release download v1.3.1-99-win-test -p '*windows-x86_64*'
tar -xzOf executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz \
  executorch-runtime-1.3.1-logging-windows-x86_64/BUILDINFO
```

Expected: `platform=windows-x86_64`, `toolchain=msvc-2022`, `cmake_flags=--preset windows ...`, `usdt=n/a`. Confirm the tarball contains exactly the C2 members (`lib`, `include`, `LICENSE`, `THIRD-PARTY-NOTICES`, `BUILDINFO`) and that `lib/cmake` has no absolute-path leaks:

```bash
mkdir _x && tar -xzf executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz -C _x
grep -rlE 'C:\\|Program Files|Windows Kits' _x/*/lib/cmake || echo "NO LEAKS"
```

Expected: `NO LEAKS`.

- [ ] **Step 5: Clean up the test tag/release**

```bash
gh release delete v1.3.1-99-win-test --yes --cleanup-tag
```

- [ ] **Step 6: Confirm the full local suite still passes**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo the known `extras_members` fresh-checkout caveat).

---

## Self-Review

- **Spec coverage:**
  - §1 CI topology (separate `build-windows` job, `windows-x86_64`, `dist-...` pattern, no container) → Task 5. Pin filesystem-discovery is the prerequisite plan (Global Constraints), not re-implemented here.
  - §2 build-runtime Windows path (preset windows, skip extras, skip syslib norm, toolchain echo, nproc→portable, usdt sentinel) → Task 4. MSVC activation via `Launch-VsDevShell` → Task 5 Step 1.
  - §3 relocatability measure-first (generic prefix rewrite reused, syslib skipped, Windows leaks measured) → Task 1 (measure), Task 4 Step 5 (reuse/guard), Task 6 Step 4 (verify).
  - §4 packaging (`.etnp_usdt` sentinel required + written; `TOOLCHAIN` parameterized) → Task 4 Step 4 (writes sentinel), Task 3 (`--toolchain`). `.tar.gz`/`naming.sh` unchanged → honored.
  - §5 flag SSOT platform-aware in one place + provenance consistency → Task 2 (`et_preset`), Task 3 (records `--preset` into BUILDINFO), Task 4 (build uses same `et_preset`).
  - §6 feature footprint / consumer diff + optional overrides → Task 1 finding 4 + Task 4 Step 5 spike-reconciliation note.
  - §7 scope + spike-gated unknowns → Task 1; item 1 (preset exists) already resolved in Global Constraints.
- **Placeholder scan:** no "TBD/TODO"; the genuinely spike-gated items (torch trim, extra normalization, LLM override) are written as conditional actions with the exact edit named and a safe default, not as blanks. Build-script tasks that lack a hermetic seam say so and defer to the Task 6 CI run rather than faking a test.
- **Type/interface consistency:** `et_preset <platform>` signature is identical across Task 2 (def), Task 3 (`et_preset "$PLATFORM"`), Task 4 (`et_preset "$PLATFORM"`). BUILDINFO field names (`toolchain=`, `cmake_flags=`, `usdt=`, `platform=`) match `gen-buildinfo.sh`. The `.etnp_usdt` sentinel written in Task 4 (`n/a`) is exactly what Task 3's test and `package.sh` read.
- **Cross-plan dependency:** Global Constraints state the pin plan must be merged first; Task 5 relies on the discovery behavior and only adds `build-windows` to `needs`.
