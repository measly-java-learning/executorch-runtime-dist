# Windows (amd64) Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce attested, hash-pinned, relocatable `windows-x86_64` ExecuTorch runtime tarballs (`logging` variant, core-only) from the existing build/package/CI pipeline.

**Architecture:** Reuse `build-runtime.sh` + `scripts/lib/*` under Git-Bash on a GitHub-hosted `windows-2022` runner; MSVC env activation happens in a `pwsh` workflow step (`Launch-VsDevShell`) that then invokes the bash recipe in the same session. The recipe configures ET with `-G Ninja` + a **flat Windows flag list** (NOT `--preset windows` — see the spike), applies a **flatc `.exe` byproduct patch**, skips phase-2 extras, and reuses the generic relocatability repair. A single new `et_configure_base` SSOT function returns the per-platform configure base (`--preset linux` on Linux, the flat flag list on Windows) for both the build and the recorded provenance.

**Tech Stack:** Bash, PowerShell (workflow only), CMake + Ninja + MSVC, GitHub Actions (`windows-2022`), the repo's `test/assert.sh` harness.

> **Spike-informed (2026-07-15, `spike/windows-msvc-spike.md`):** the spike already ran on the
> `winbox` host and validated a torch-free Ninja+MSVC build at C++17. Its findings are baked into the
> tasks below — Task 1 is **already complete** (records the outcome), and Tasks 2/4/5 reflect the
> corrections (flat flags, no preset, flatc patch, no optimized/quantized kernels, no C++20).

## Global Constraints

- **Prerequisite:** the pin-job filesystem-discovery refactor (`docs/superpowers/plans/2026-07-15-pin-filesystem-discovery.md`) is **already merged**. This plan does **not** modify the `pin` job's row generation.
- Platform string: **`windows-x86_64`**. Variant: **`logging`** only. **Core-only** — no `extras/`, no USDT (Linux-only by contract), no `bare`/`devtools`.
- CMake configure base: **flat `-D` flags, NOT `--preset windows`** (the preset pins ClangCL + the VS generator). Generator: **Ninja + MSVC**, single-config, **C++17** (no `CMAKE_CXX_STANDARD` override). Feature set = windows-preset features **minus** `KERNELS_OPTIMIZED`/`QUANTIZED` (keeps the build torch-free and matches the Linux footprint).
- **flatc patch:** Windows builds `sed`-patch `third-party/CMakeLists.txt` `BUILD_BYPRODUCTS ... /bin/flatc` → `/bin/flatc.exe` (a second load-bearing ET patch, like #20709). To be filed upstream (Task 7).
- Runner: GitHub-hosted **`windows-2022`** (ships Python, CMake, Ninja, VS Enterprise 2022) — **no conda, no external toolchain actions**.
- Wire format stays **`.tar.gz` + `.sha256`**; `naming.sh` unchanged.
- SSOT invariant (C5): one function returns the per-platform configure base, both the build (`build-runtime.sh`) and recorded provenance (`package.sh`) consume it — never a second copy.
- Shell scripts run under `set -euo pipefail`; guard `grep`/glob no-match with `|| true`/`[ -e ]` (repo convention).
- `test/run.sh` auto-globs `*.test.sh`; new tests need only be placed in `test/`.

---

### Task 1: Windows build spike — ✅ COMPLETE

**Done 2026-07-15**, interactively on the `winbox` host (VS 18 / MSVC 19.51), not via a throwaway CI
workflow. Findings committed to **`spike/windows-msvc-spike.md`** (commit `7558ddd`). Outcome:

- Torch-free single-config **Ninja + MSVC** build succeeds end-to-end (configure → build 1353/1353 →
  install) at **C++17**; produces a coherent runtime (`executorch(_core)`, `portable_kernels`,
  XNNPACK backend, full `extension_*` set) and links `executor_runner.exe`.
- **Finding 1:** `--preset windows` is unusable (pins ClangCL + VS generator) → flat `-D` flags (Task 2).
- **Finding 2:** `flatc_ep` `BUILD_BYPRODUCTS` omits `.exe` on WIN32 → Ninja "no known rule" → new
  recipe patch (Task 4) + upstream issue draft (Task 7).
- **Finding 3:** `KERNELS_OPTIMIZED`/`QUANTIZED` pull torch `c10` headers that break MSVC → omit them
  (matches the Linux footprint; no C++20 needed) (Task 2/4).
- **Finding 4:** `lib/cmake` near-clean; only `extension_evalue_util` → build-tree leak, which is not
  Windows-specific (shared with Linux) (Task 4 measure-and-warn).
- **Finding 5:** base feature set matches Linux; no consumer overrides needed for v1.

No action remains for this task — it is the source of the Task 2/4/5 specifics below.

---

### Task 2: `et_configure_base` SSOT function + unit test

**Files:**
- Create: `scripts/lib/configure-base.sh`
- Test: `test/lib_configure_base.test.sh`

**Interfaces:**
- Produces: `et_configure_base <platform>` → prints the platform's cmake **configure base**: `--preset linux` for `linux-*`; a flat `-D` flag list (the windows-preset feature set **minus** `KERNELS_OPTIMIZED`/`QUANTIZED`) for `windows-*`; returns `2` on unknown. Consumed by `build-runtime.sh` (Task 4) and `package.sh` (Task 3). Supersedes the earlier `et_preset` idea — the ET `windows` preset pins ClangCL + the VS generator and is unusable (spike finding 1).

- [ ] **Step 1: Write the failing test**

Create `test/lib_configure_base.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/configure-base.sh"
assert_eq "$(et_configure_base linux-x86_64)"  "--preset linux" "linux x86_64 -> linux preset"
assert_eq "$(et_configure_base linux-aarch64)" "--preset linux" "linux aarch64 -> linux preset"
win="$(et_configure_base windows-x86_64)"
assert_contains "$win" "-DEXECUTORCH_BUILD_XNNPACK=ON"                  "windows base enables xnnpack"
assert_contains "$win" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"          "windows base enables executor_runner"
assert_contains "$win" "-DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON" "windows base enables named_data_map (EXTENSION_MODULE dep)"
# Must NOT enable the torch-header-pulling kernels, and must NOT use a preset.
case "$win" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: windows base must not enable optimized/quantized kernels\n' >&2; exit 1 ;; esac
case "$win" in *--preset*) printf 'FAIL: windows base must not use a cmake preset\n' >&2; exit 1 ;; esac
et_configure_base bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_configure_base.test.sh`
Expected: FAIL — `scripts/lib/configure-base.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/configure-base.sh`:

```bash
#!/usr/bin/env bash
# Platform -> ExecuTorch cmake CONFIGURE BASE (SSOT). Shared by build-runtime.sh (the build) and
# package.sh (recorded provenance) so the two can never disagree on how the artifact was configured.
# Linux uses the ET `linux` preset. Windows uses a flat flag list because the ET `windows` preset
# pins toolset ClangCL + the VS generator, incompatible with our Ninja/MSVC single-config build
# (spike finding 1). The Windows list is the windows-preset feature set MINUS
# KERNELS_OPTIMIZED/QUANTIZED — those pull torch c10 headers that break MSVC, and Linux ships neither
# (spike finding 3). `common_cmake_flags` + `variant_flags` still layer on top of this base.
# Source me.
et_configure_base() { # <platform>
  case "$1" in
    linux-*)   printf -- '--preset linux' ;;
    windows-*) printf -- '%s' \
'-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON' ;;
    *) echo "et_configure_base: unknown platform '$1'" >&2; return 2 ;;
  esac
}
```

(The Windows base overlaps `common_cmake_flags` on XNNPACK/EXTENSION_*/build-type/PIC with identical values — harmless; it is the complete spike-validated set so the base alone reproduces the working configure.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_configure_base.test.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/configure-base.sh test/lib_configure_base.test.sh
git commit -m "feat: add et_configure_base SSOT (platform -> cmake configure base)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `package.sh` — `--toolchain` param + record configure base in provenance

**Files:**
- Modify: `scripts/package.sh:7` (source `configure-base.sh`), `:9-23` (parse `--toolchain`), `:46-51` (record configure base + toolchain)
- Test: `test/package.test.sh` (extend)

**Interfaces:**
- Consumes: `et_configure_base <platform>` (Task 2).
- Produces: `package.sh ... [--toolchain <str>]` — records `toolchain=<str>` (default preserves the current manylinux string) and prepends the per-platform **configure base** (`--preset linux` on Linux, the flat `-D` list on Windows) to the recorded `cmake_flags` in BUILDINFO.

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
assert_contains "$bi" "toolchain=msvc-2022"                        "--toolchain override recorded"
assert_contains "$bi" "cmake_flags=-DCMAKE_BUILD_TYPE=Release"     "windows flat configure base recorded (not a preset)"
assert_contains "$bi" "-DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON"      "windows base flag recorded"
case "$bi" in *"cmake_flags="*"--preset"*) printf 'FAIL: windows provenance must not record a preset\n' >&2; exit 1 ;; esac
case "$bi" in *KERNELS_OPTIMIZED*|*KERNELS_QUANTIZED*) printf 'FAIL: windows provenance must not record optimized/quantized kernels\n' >&2; exit 1 ;; esac
assert_contains "$bi" "usdt=n/a"                                   "core-only usdt sentinel recorded"

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
. "$HERE/lib/configure-base.sh"
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

Change the BUILDINFO generation block (lines 46–51) to prepend the per-platform configure base and use the parameterized toolchain:

```bash
CMAKE_FLAGS="$(et_configure_base "$PLATFORM") $(variant_flags "$VARIANT") $(common_cmake_flags)"
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
- Modify: `build-runtime.sh` — source `configure-base.sh`; add `--platform`; OS-guarded configure-base/flatc-patch/parallelism/toolchain-echo/extras/syslib/license/usdt-sentinel branches.

**Interfaces:**
- Consumes: `et_configure_base <platform>` (Task 2).
- Produces: a relocatable core-only install at `--prefix` on Windows (with `.etnp_usdt=n/a` sentinel), consumed by `package.sh` (Task 3).

**Verification note:** this edits the cmake-driving recipe, which has no hermetic unit seam — the Linux `--print-flags` regression (below) plus the real Windows CI run in **Task 6** are the verification. Do not claim it works from the edits alone. (The full Windows build+install was proven manually in the spike; this task ports that into the recipe.)

- [ ] **Step 1: Source configure-base.sh + add OS/platform detection**

In `build-runtime.sh`, after `. "$HERE/scripts/lib/cmakeflags.sh"` (line 13) add:

```bash
. "$HERE/scripts/lib/configure-base.sh"
```

Add `--platform` to the arg vars (line 32) — default `linux-x86_64` keeps existing local/Linux invocations unchanged:

```bash
VARIANT=""; PREFIX=""; ET_SRC=""; ET_TAG="$DEFAULT_ET_TAG"; BUILD_DIR=""; PRINT_FLAGS=0; PLATFORM="linux-x86_64"
```

Add the parse arm (alongside the others near line 40):

```bash
    --platform) PLATFORM="${2:-}"; shift 2 ;;
```

After arg parsing (after line 47), derive the configure base + OS flag:

```bash
CONFIGURE_BASE="$(et_configure_base "$PLATFORM")"   # returns 2 on unknown platform -> set -e aborts
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

- [ ] **Step 3: Apply the flatc `.exe` byproduct patch (Windows only), then configure with the platform base + portable parallelism (lines ~168–202)**

First, alongside the existing ET install-dest patch (`#20709`, ~lines 168–179), add the Windows-only flatc byproduct patch. `third-party/CMakeLists.txt:56` declares `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` (no `.exe`); on WIN32 the consumer imports `bin/flatc.exe`, so Ninja has "no known rule" and the build dies. Idempotent, Windows-only (`$` anchor keeps a re-run from double-appending):

```bash
if [ "$IS_WINDOWS" -eq 1 ]; then
  echo ">> patching flatc_ep BUILD_BYPRODUCTS for WIN32 (.exe) — upstream flatc byproduct bug"
  sed -i 's#\(BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc\)$#\1.exe#' \
    "$ET_SRC/third-party/CMakeLists.txt" || true
fi
```

Then configure using the per-platform base (no hardcoded preset) + portable parallelism:

```bash
echo ">> configuring ($VARIANT, platform=$PLATFORM)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag strings
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja $CONFIGURE_BASE \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  $VARIANT_FLAGS $(common_cmake_flags)

echo ">> building"
if [ "$IS_WINDOWS" -eq 1 ]; then JOBS="${NUMBER_OF_PROCESSORS:-4}"; else JOBS="$(nproc)"; fi
cmake --build "$ET_BUILD" -j"$JOBS"
```

Note: no `-DCMAKE_CXX_STANDARD` — C++17 (default) builds clean once optimized/quantized kernels are off (spike finding 3). `$CONFIGURE_BASE` is `--preset linux` on Linux and the flat `-D` list on Windows; both then get `$VARIANT_FLAGS` + `common_cmake_flags`.

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

The generic prefix-leak "measuring relocatability" block (lines 210–218) is **left unguarded** — it runs on all platforms as the reused Windows relocatability repair. Spike finding 4: the install is near-clean (only `extension_evalue_util` → build-tree, a non-Windows-specific quirk shared with Linux); keep the measure-and-warn so any leak stays loud. No Windows-specific normalization is added in v1.

> **torch (spike finding 2, resolved):** keep the `torch` pip install (lines 184–186) on Windows unchanged — ET's configure/codegen uses it. It is *not* compiled into the artifact once the optimized/quantized kernels are off (the produced runtime is torch-free), so no trimming is needed for correctness.

- [ ] **Step 6: Regression-check the Linux dry path**

Run: `bash build-runtime.sh --print-flags --variant logging`
Expected: prints `-DEXECUTORCH_ENABLE_LOGGING=ON` and exits 0 (the `--print-flags` path is unchanged and proves the edits didn't break arg parsing / sourcing).
Run: `bash -n build-runtime.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 7: Commit**

```bash
git add build-runtime.sh
git commit -m "feat: build-runtime.sh Windows path (flat flags + flatc patch, core-only, no extras)

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

### Task 6: End-to-end CI validation

**Verification:** a real release-tag dry run producing a genuine Windows artifact and confirming the whole chain (build → relocatable install → package → attest → pin discovery). (No spike workflow to clean up — the spike ran interactively on the `winbox` host, not via a throwaway CI job.)

- [ ] **Step 1: Push and cut a pre-release test tag**

Push the branch, then push a throwaway pre-release tag matching the release trigger `v*-*` (bump `<pkgrev>` so it doesn't collide with a real release):

```bash
git push -u origin feature/windows-amd64-artifacts
git tag v1.3.1-99-win-test && git push origin v1.3.1-99-win-test
```

- [ ] **Step 2: Watch the release run**

Run: `gh run watch` (select the `release` workflow run for the tag).
Expected, in order:
- `build-windows / logging` job green.
- Artifact `dist-logging-windows-x86_64` uploaded containing `executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz` + `.sha256`.
- `pin` job green; `EtRuntimePin.cmake` in the step summary contains both `..._logging_linux-x86_64` and `..._logging_windows-x86_64` rows.

- [ ] **Step 3: Verify the Windows artifact's contents + provenance**

Download and inspect:

```bash
gh release download v1.3.1-99-win-test -p '*windows-x86_64*'
tar -xzOf executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz \
  executorch-runtime-1.3.1-logging-windows-x86_64/BUILDINFO
```

Expected: `platform=windows-x86_64`, `toolchain=msvc-2022`, `usdt=n/a`, and `cmake_flags=` starting with the flat Windows base (`-DCMAKE_BUILD_TYPE=Release ... -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=ON ...`) — **not** a `--preset`, and with **no** `KERNELS_OPTIMIZED`/`QUANTIZED`. Confirm the tarball contains exactly the C2 members (`lib`, `include`, `LICENSE`, `THIRD-PARTY-NOTICES`, `BUILDINFO`) and that `lib/cmake` has no absolute-path leaks:

```bash
mkdir _x && tar -xzf executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz -C _x
grep -rlE 'C:\\|Program Files|Windows Kits' _x/*/lib/cmake || echo "NO LEAKS"
```

Expected: `NO LEAKS`.

- [ ] **Step 4: Clean up the test tag/release**

```bash
gh release delete v1.3.1-99-win-test --yes --cleanup-tag
```

- [ ] **Step 5: Confirm the full local suite still passes**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (modulo the known `extras_members` fresh-checkout caveat).

---

### Task 7: Upstream issue draft for the flatc byproduct bug

**Files:**
- Create: `docs/superpowers/notes/2026-07-15-flatc-win32-byproduct-upstream-issue.md`

**Interfaces:** none — deliverable is a self-contained markdown to paste into a new `pytorch/executorch` issue (parallels how the `${CMAKE_BINARY_DIR}/lib` bug became #20709). No code.

- [ ] **Step 1: Write the issue draft**

Create `docs/superpowers/notes/2026-07-15-flatc-win32-byproduct-upstream-issue.md` containing a filable bug report:

- **Title:** `flatc_ep BUILD_BYPRODUCTS omits .exe on WIN32 → Ninja "no known rule to make flatc.exe"`
- **Environment:** Windows, `-G Ninja`, MSVC (repro on VS 18 / MSVC 19.51, ET 1.3.1).
- **Repro:** `cmake -S . -B build -G Ninja <core flags>` then `cmake --build build` → fails with
  `ninja: error: 'third-party/flatc_ep/bin/flatc.exe', needed by '.../program_generated.h', missing and no known rule to make it`.
- **Root cause:** `third-party/CMakeLists.txt:56` declares `BUILD_BYPRODUCTS <INSTALL_DIR>/bin/flatc` (no extension), but `:66` sets the WIN32 imported location to `<INSTALL_DIR>/bin/flatc.exe`. Ninja requires the byproduct path to match the consumed file exactly; non-Ninja generators use the target-level `add_dependencies(flatc flatbuffers_ep)` and are unaffected.
- **Proposed fix:** make `BUILD_BYPRODUCTS` conditional on WIN32 (append `.exe`), mirroring the existing `IMPORTED_LOCATION` `if(WIN32 …)` block — include a small diff.
- **Note:** this repo carries a local `sed` patch (build-runtime.sh Windows path, Task 4) until upstreamed.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/notes/2026-07-15-flatc-win32-byproduct-upstream-issue.md
git commit -m "docs: upstream issue draft for flatc WIN32 byproduct bug

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:**
  - §1 CI topology (separate `build-windows` job, `windows-x86_64`, `dist-...` pattern, no container) → Task 5. Pin filesystem-discovery is the prerequisite plan (Global Constraints), not re-implemented here.
  - §2 build-runtime Windows path (flat flags, **flatc `.exe` patch**, skip extras, skip syslib norm, toolchain echo, nproc→portable, usdt sentinel) → Task 4. MSVC activation via `Launch-VsDevShell` → Task 5 Step 1.
  - §3 relocatability (generic prefix rewrite reused, syslib skipped, measured near-clean) → Task 4 Step 3/5 (reuse/guard), Task 6 Step 3 (verify). Spike (Task 1) already measured.
  - §4 packaging (`.etnp_usdt` sentinel required + written; `TOOLCHAIN` parameterized) → Task 4 Step 4 (writes sentinel), Task 3 (`--toolchain`). `.tar.gz`/`naming.sh` unchanged → honored.
  - §5 flag SSOT platform-aware in one place + provenance consistency → Task 2 (`et_configure_base`), Task 3 (records the configure base into BUILDINFO), Task 4 (build uses same `et_configure_base`).
  - §6 feature footprint (omit optimized/quantized to match Linux, torch-free) → Task 2 (base excludes them) + Task 4 (build) + Task 6 Step 3 (verify no optimized/quantized in provenance).
  - §7 scope + spike — **Task 1 is complete** (findings recorded); the flatc upstream draft → Task 7.
- **Placeholder scan:** no "TBD/TODO"; the spike is resolved so no conditional "if the spike shows X" branches remain — the flat flag set, the flatc patch, and C++17 are stated concretely. Build-script tasks (4/5) that lack a hermetic seam say so and defer to the Task 6 CI run (the spike already proved the build manually).
- **Type/interface consistency:** `et_configure_base <platform>` signature is identical across Task 2 (def), Task 3 (`et_configure_base "$PLATFORM"`), Task 4 (`et_configure_base "$PLATFORM"`). BUILDINFO field names (`toolchain=`, `cmake_flags=`, `usdt=`, `platform=`) match `gen-buildinfo.sh`. The `.etnp_usdt` sentinel written in Task 4 (`n/a`) is exactly what Task 3's test and `package.sh` read.
- **Cross-plan dependency:** Global Constraints state the pin plan must be merged first; Task 5 relies on the discovery behavior and only adds `build-windows` to `needs`.
