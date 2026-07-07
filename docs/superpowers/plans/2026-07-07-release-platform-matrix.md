# Release Workflow Platform-Matrix Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `.github/workflows/release.yml` so a future `linux-aarch64` platform addition is a one-line edit, with no other architectural change.

**Architecture:** Extract the tag/pkgver/etver derivation into a testable `scripts/derive-version.sh`. Introduce a single `env.PLATFORMS` JSON array (`{platform, container, runs_on}` per entry) consumed by the `build` job's matrix and by a new `pin` job. Split the current `release` job into `pin` (generates `EtRuntimePin.cmake`, needs `build`) and `release` (single `gh release create`/`upload`, needs `pin`) so a future per-platform loop in `pin` never races on release creation. Give each job least-privilege `permissions:`.

**Tech Stack:** GitHub Actions YAML, bash (existing `scripts/*.sh` + `test/*.test.sh` dependency-free harness), `jq` (preinstalled on `ubuntu-latest` runners), `actionlint` (installed locally at `/home/corey/.local/bin/actionlint`, bundles shellcheck for `run:` blocks).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-07-release-platform-matrix-design.md` — this plan implements it exactly; do not add scope beyond it (no actual aarch64 support, no toolchain/build-step changes).
- No new platform is added. `PLATFORMS` keeps exactly one entry: `linux-x86_64` / `quay.io/pypa/manylinux_2_28_x86_64` / `ubuntu-latest`.
- Follow existing script conventions: `set -euo pipefail`, sourced-or-executed dependency-free bash, no external deps beyond what's already used (`jq` is new — already present on GH-hosted runners and any modern dev machine; no test depends on it being absent).
- Follow existing test conventions: `test/*.test.sh` sourcing `test/assert.sh`, added to `test/run.sh` automatically (it globs `*.test.sh`), and workflow-invoked scripts must be committed as git mode `100755` (enforced by `test/exec_perms.test.sh`).
- Every workflow-invoked script must remain independently testable from the shell, without any GitHub Actions context, exactly as `build-runtime.sh --print-flags` and `scripts/gen-pin.sh` already are.

---

### Task 1: Extract version derivation into `scripts/derive-version.sh`

**Files:**
- Create: `scripts/derive-version.sh`
- Create: `test/derive_version.test.sh`
- Modify: `test/exec_perms.test.sh`

**Interfaces:**
- Produces: `scripts/derive-version.sh` — reads `GITHUB_REF_NAME` (env var, required), writes three `key=value` lines to stdout: `pkgver=<tag without leading v>`, `etver=<pkgver without trailing -N>`, `ettag=v<etver>`. Exits 1 (via `set -u` unbound-var error under `:?`) if `GITHUB_REF_NAME` is unset. This output format is both directly appendable to `$GITHUB_OUTPUT` and `eval`-able as shell assignments — later tasks rely on both consumption styles.

- [ ] **Step 1: Write the failing test**

Create `test/derive_version.test.sh`:

```sh
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

out="$(GITHUB_REF_NAME=v1.3.1-1 bash "$here/../scripts/derive-version.sh")"
assert_contains "$out" "pkgver=1.3.1-1" "pkgver"
assert_contains "$out" "etver=1.3.1"    "etver"
assert_contains "$out" "ettag=v1.3.1"   "ettag"

out2="$(GITHUB_REF_NAME=v2.0.0-3 bash "$here/../scripts/derive-version.sh")"
assert_contains "$out2" "pkgver=2.0.0-3" "pkgver (second pkgrev)"
assert_contains "$out2" "etver=2.0.0"    "etver (second pkgrev)"
assert_contains "$out2" "ettag=v2.0.0"   "ettag (second pkgrev)"

env -u GITHUB_REF_NAME bash "$here/../scripts/derive-version.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing GITHUB_REF_NAME is a hard error"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/derive_version.test.sh`
Expected: FAIL — `scripts/derive-version.sh: No such file or directory` (nonzero exit, error on stderr).

- [ ] **Step 3: Write the script**

Create `scripts/derive-version.sh`:

```sh
#!/usr/bin/env bash
# Derive pkgver/etver/ettag from a release tag (v<etver>-<pkgrev>, e.g. v1.3.1-1).
# Reads GITHUB_REF_NAME; prints key=value lines (both $GITHUB_OUTPUT-appendable and eval-able).
set -euo pipefail
tag="${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
pkgver="${tag#v}"
etver="${pkgver%-*}"
printf 'pkgver=%s\netver=%s\nettag=v%s\n' "$pkgver" "$etver" "$etver"
```

Make it executable:

```bash
chmod 755 scripts/derive-version.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/derive_version.test.sh`
Expected: all `ok:` lines, no `FAIL:` lines, exit 0.

- [ ] **Step 5: Add the script to the executable-permissions check**

Modify `test/exec_perms.test.sh` — the `for s in ...` list currently reads:

```sh
for s in build-runtime.sh scripts/package.sh scripts/gen-pin.sh scripts/gen-buildinfo.sh; do
```

Change to:

```sh
for s in build-runtime.sh scripts/package.sh scripts/gen-pin.sh scripts/gen-buildinfo.sh scripts/derive-version.sh; do
```

- [ ] **Step 6: Run the full test suite**

Run: `bash test/run.sh`
Expected: last line `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Commit**

```bash
git add scripts/derive-version.sh test/derive_version.test.sh test/exec_perms.test.sh
git commit -m "$(cat <<'EOF'
feat: extract tag/pkgver/etver derivation into scripts/derive-version.sh

Testable locally via GITHUB_REF_NAME=... without any GitHub Actions
context. release.yml's build and pin jobs both need this logic after
the upcoming job split, so it moves out of inline YAML.
EOF
)"
```

---

### Task 2: Restructure `.github/workflows/release.yml` (PLATFORMS matrix, build/pin/release split, least-privilege permissions)

**Files:**
- Modify: `.github/workflows/release.yml` (full rewrite)

**Interfaces:**
- Consumes: `scripts/derive-version.sh` from Task 1 (invoked as `./scripts/derive-version.sh`, requires the git-executable-bit already verified by `test/exec_perms.test.sh`).
- Consumes: `scripts/gen-pin.sh` (unchanged, already accepts `--row <variant> <platform> <sha>` per row — confirmed in `scripts/gen-pin.sh`).
- Consumes: `scripts/package.sh` (unchanged, `--platform` flag).
- Produces: four jobs — `setup` (no dependencies, exposes `env.PLATFORMS` as job output `platforms`), `build` (needs `setup`; matrix `variant × combo`, `combo` sourced from `needs.setup.outputs.platforms`), `pin` (needs `build`), `release` (needs `pin`). Artifact names: `dist-<variant>-<platform>` (from `build`) and `pin` (from `pin`, containing `EtRuntimePin.cmake`).
- Note: GitHub Actions disallows the `env` context inside `jobs.<job_id>.strategy.matrix` (only `github`/`needs`/`vars`/`inputs` are available there — confirmed via `actionlint`). This is why `build`'s matrix reads `needs.setup.outputs.platforms` rather than `env.PLATFORMS` directly, while `pin` (a normal `run:` step, not `strategy.matrix`) can still read `env.PLATFORMS` — via the `$PLATFORMS` shell variable GitHub Actions injects into every `run:` step's environment, which also avoids any quoting issues from the JSON's embedded double quotes.

- [ ] **Step 1: Replace the full file contents**

Replace `.github/workflows/release.yml` with:

```yaml
name: release
on:
  push:
    tags: ['v*-*']          # v<etver>-<pkgrev>, e.g. v1.3.1-1

permissions:
  contents: read            # least-privilege default; each job below elevates only what it needs

env:
  # Single source of truth for release platforms. manylinux bakes the architecture into the
  # container image name, so each entry carries its own container + runner. Adding a platform
  # (e.g. linux-aarch64) later is a one-line append here; no job-level YAML changes needed.
  PLATFORMS: >-
    [{"platform":"linux-x86_64","container":"quay.io/pypa/manylinux_2_28_x86_64","runs_on":"ubuntu-latest"}]

jobs:
  setup:
    # env is not readable from strategy.matrix (GitHub Actions restriction — confirmed via
    # actionlint), so build's matrix reads this job's output instead of env.PLATFORMS directly.
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      platforms: ${{ steps.platforms.outputs.platforms }}
    steps:
      - id: platforms
        run: echo "platforms=$PLATFORMS" >> "$GITHUB_OUTPUT"

  build:
    needs: setup
    runs-on: ${{ matrix.combo.runs_on }}
    container:
      image: ${{ matrix.combo.container }}   # caller owns the container boundary
    permissions:
      contents: read
      id-token: write        # attestations
      attestations: write
    strategy:
      fail-fast: false
      matrix:
        variant: [bare, logging, devtools]
        combo: ${{ fromJSON(needs.setup.outputs.platforms) }}
    steps:
      - uses: actions/checkout@v7
      - name: Derive versions from tag
        id: ver
        run: ./scripts/derive-version.sh >> "$GITHUB_OUTPUT"
      - name: Checkout ExecuTorch source (caller-owned per C8; the recipe does not clone)
        uses: actions/checkout@v7
        with:
          repository: pytorch/executorch
          ref: ${{ steps.ver.outputs.ettag }}
          submodules: recursive
          path: executorch
      - name: Build runtime
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          ./build-runtime.sh --variant "${{ matrix.variant }}" \
            --prefix "$PWD/out" --et-src "$PWD/executorch" \
            --et-tag "${{ steps.ver.outputs.ettag }}"
      - name: Package
        run: |
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ steps.ver.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform "${{ matrix.combo.platform }}" \
            --package-tag "${GITHUB_REF_NAME}" --outdir "$PWD/dist"
      - name: Attest build provenance
        uses: actions/attest@v4
        with:
          subject-path: dist/*.tar.gz
      - uses: actions/upload-artifact@v7
        with:
          name: dist-${{ matrix.variant }}-${{ matrix.combo.platform }}
          path: dist/*

  pin:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with:
          path: dist
          merge-multiple: true
      - name: Generate EtRuntimePin.cmake
        run: |
          eval "$(./scripts/derive-version.sh)"
          base="${{ github.server_url }}/${{ github.repository }}/releases/download/${GITHUB_REF_NAME}"
          args=(--version "$pkgver" --etver "$etver" --base-url "$base")
          for platform in $(echo "$PLATFORMS" | jq -r '.[].platform'); do
            for variant in bare logging devtools; do
              sha="$(cut -d' ' -f1 "dist/executorch-runtime-${etver}-${variant}-${platform}.tar.gz.sha256")"
              args+=(--row "$variant" "$platform" "$sha")
            done
          done
          ./scripts/gen-pin.sh "${args[@]}" > dist/EtRuntimePin.cmake
          {
            echo '```cmake'
            cat dist/EtRuntimePin.cmake
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
      - uses: actions/upload-artifact@v7
        with:
          name: pin
          path: dist/EtRuntimePin.cmake

  release:
    needs: pin
    runs-on: ubuntu-latest
    permissions:
      contents: write         # create release + upload assets
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with:
          path: dist
          merge-multiple: true
      - name: Create/Update release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${GITHUB_REF_NAME}" dist/* \
            --title "${GITHUB_REF_NAME}" \
            --notes "ExecuTorch runtime ${GITHUB_REF_NAME} (torch 2.12.0+cpu, manylinux_2_28)." \
          || gh release upload "${GITHUB_REF_NAME}" dist/* --clobber
```

- [ ] **Step 2: Validate the workflow syntax and embedded shell**

Run: `/home/corey/.local/bin/actionlint .github/workflows/release.yml`
Expected: no output, exit 0. (`actionlint` bundles shellcheck for `run:` blocks — this catches quoting/syntax errors in the new `pin` job's loop that nothing else in this repo would.)

If it reports issues, fix them in the YAML above and re-run until clean.

- [ ] **Step 3: Re-run the full local test suite**

Run: `bash test/run.sh`
Expected: last line `ALL UNIT TESTS PASS`. (This doesn't execute the workflow itself, but confirms Task 1's script and the exec-permissions check still pass after this change.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
ci: parametrize release.yml platforms and split build/pin/release

- Single env.PLATFORMS source of truth ({platform, container, runs_on})
  consumed by build's matrix (via a new setup job, since env isn't
  readable from strategy.matrix) and pin's loop, so adding
  linux-aarch64 later is a one-line append.
- Split the old release job into pin (generates EtRuntimePin.cmake,
  needs: build) and release (single gh release create/upload, needs:
  pin), so a future per-platform pin loop never races on release
  creation.
- Least-privilege permissions per job: build gets id-token/attestations
  (no contents:write), pin/setup get contents:read only, release gets
  contents:write only. Resolves the file's prior TODO about scoping
  attestation permissions to build.
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** `PLATFORMS` single source of truth (Task 2 Step 1) ✓; `build`/`pin`/`release` split (Task 2 Step 1) ✓; least-privilege per-job permissions (Task 2 Step 1) ✓; `scripts/derive-version.sh` extraction (Task 1) ✓. All four spec sections have a corresponding task/step.
- **Placeholder scan:** no TBD/TODO; every step shows full file contents or exact commands with expected output.
- **Type/name consistency:** `matrix.combo.platform` / `matrix.combo.container` / `matrix.combo.runs_on` used consistently between the `combo` matrix definition and its references in `build`; `dist-<variant>-<platform>` artifact name in `build` matches the `merge-multiple: true` download in `pin` and `release`; `pkgver`/`etver`/`ettag` names match between `scripts/derive-version.sh`'s output and both consumers (`$GITHUB_OUTPUT` in `build`, `eval` in `pin`); `needs.setup.outputs.platforms` name matches the `setup` job's `outputs:` key and its step id (`steps.platforms.outputs.platforms`).
- **Correction from implementation:** the original plan had `build`'s matrix read `env.PLATFORMS` directly — `actionlint` caught that GitHub Actions disallows `env` inside `strategy.matrix`. Fixed by adding a `setup` job (see spec `docs/superpowers/specs/2026-07-07-release-platform-matrix-design.md`, "Single source of truth for platforms" section) and updating this task's YAML and commit message accordingly before re-dispatch.
