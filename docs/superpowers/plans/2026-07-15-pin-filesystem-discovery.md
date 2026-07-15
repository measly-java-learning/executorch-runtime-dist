# Pin-job Filesystem Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `release.yml` `pin` job emit one pin row per artifact actually present in `dist/`, instead of a hardcoded `platform × {bare,logging,devtools}` loop, so a platform can ship a subset of variants.

**Architecture:** Extract discovery + row parsing into a small, unit-tested script `scripts/discover-pin-rows.sh` that reuses `scripts/lib/naming.sh` as the source of truth for the asset naming scheme. The `pin` job pipes its TSV output into the unchanged `gen-pin.sh`. Output is the same *set* of pin rows (order-independent — the pin file is a flat list of independent `set(...)` vars read by name) for today's Linux-only, all-variants matrix.

**Tech Stack:** Bash (`set -euo pipefail`), the repo's dependency-free `test/assert.sh` harness, GitHub Actions.

## Global Constraints

- Shell scripts run under `set -euo pipefail`. `grep`/glob no-match must not abort under `set -e` — guard with `|| true` or `[ -e ]` glob guards (repo convention).
- Asset naming is owned by `scripts/lib/naming.sh` (contract C1) — never hardcode a second copy of the `executorch-runtime-<etver>-<variant>-<platform>` scheme; derive from / validate against `naming.sh`.
- `gen-pin.sh` (contract C6) and its output format are **reused unchanged**.
- `test/run.sh` auto-globs `*.test.sh`; a new test file needs no registration, only placement in `test/`.
- New scripts under `scripts/` source libs as `. "$HERE/lib/<name>.sh"` (see `gen-pin.sh`, `package.sh`).

---

### Task 1: `discover-pin-rows.sh` + unit test

**Files:**
- Create: `scripts/discover-pin-rows.sh`
- Test: `test/discover_pin_rows.test.sh`

**Interfaces:**
- Consumes: `scripts/lib/naming.sh` — `asset_stem <etver> <variant> <platform>`, `tarball_name <etver> <variant> <platform>` (prints `<stem>.tar.gz`).
- Produces: `scripts/discover-pin-rows.sh --dir <dist> --etver <etver>` → stdout, one line per discovered artifact as `variant<TAB>platform<TAB>sha`, sorted by platform then variant. Consumed by the `pin` job (Task 2) via `--row variant platform sha`.

- [ ] **Step 1: Write the failing test**

Create `test/discover_pin_rows.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# sha256sum-format file: "<hex>  <filename>"; only field 1 (hex) is read.
mk() { printf '%s  %s\n' "$1" "${2%.sha256}" > "$tmp/$2"; }

# Asymmetric coverage: Linux x3 variants + Windows logging-only.
mk cafef00d executorch-runtime-1.3.1-bare-linux-x86_64.tar.gz.sha256
mk feedface executorch-runtime-1.3.1-devtools-linux-x86_64.tar.gz.sha256
mk deadbeef executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
mk 12345678 executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz.sha256
# Foreign etver — must be ignored.
mk 99999999 executorch-runtime-9.9.9-logging-linux-x86_64.tar.gz.sha256

out="$(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp" --etver 1.3.1)"

expected="$(printf 'bare\tlinux-x86_64\tcafef00d\ndevtools\tlinux-x86_64\tfeedface\nlogging\tlinux-x86_64\tdeadbeef\nlogging\twindows-x86_64\t12345678')"
assert_eq "$out" "$expected" "asymmetric discovery, sorted platform then variant, foreign etver excluded"

# Platform string containing a dash is split correctly (variant vs platform).
assert_contains "$out" "$(printf 'logging\twindows-x86_64\t12345678')" "dash-containing platform split correctly"

# Exactly 4 rows (foreign etver dropped).
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "4" "foreign-etver file excluded from row count"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/discover_pin_rows.test.sh`
Expected: FAIL — `scripts/discover-pin-rows.sh` does not exist (`No such file or directory`).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/discover-pin-rows.sh`:

```bash
#!/usr/bin/env bash
# Discover built release artifacts in a dist dir and emit pin rows for gen-pin.sh.
# One line per <dir>/executorch-runtime-<etver>-<variant>-<platform>.tar.gz.sha256:
#   variant<TAB>platform<TAB>sha   (sorted platform then variant, deterministic)
# naming.sh owns the scheme; each parsed (variant,platform) is validated by reconstructing
# the expected basename via tarball_name and failing loudly on any mismatch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"

DIR=""; ETVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="${2:-}"; shift 2 ;;
    --etver) ETVER="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${DIR:?--dir required}"; : "${ETVER:?--etver required}"
[ -d "$DIR" ] || { echo "discover-pin-rows: --dir '$DIR' is not a directory" >&2; exit 1; }

prefix="executorch-runtime-${ETVER}-"
for sha in "$DIR"/*.tar.gz.sha256; do
  [ -e "$sha" ] || continue                 # glob no-match guard (set -e safe)
  b="$(basename "$sha")"
  rest="${b#"$prefix"}"                      # strip known prefix
  [ "$rest" != "$b" ] || continue           # different etver / not our scheme -> skip
  rest="${rest%.tar.gz.sha256}"             # -> <variant>-<platform>
  variant="${rest%%-*}"                     # variants never contain '-'
  platform="${rest#*-}"                     # platforms may (linux-x86_64, windows-x86_64)
  # Validate against the naming SSOT; a mismatch means our parse and naming.sh disagree.
  [ "$(tarball_name "$ETVER" "$variant" "$platform").sha256" = "$b" ] \
    || { echo "discover-pin-rows: parse mismatch for '$b'" >&2; exit 1; }
  sha_hex="$(cut -d' ' -f1 "$sha")"
  printf '%s\t%s\t%s\n' "$variant" "$platform" "$sha_hex"
done | sort -t"$(printf '\t')" -k2,2 -k1,1
```

Make it executable:

```bash
chmod +x scripts/discover-pin-rows.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/discover_pin_rows.test.sh`
Expected: all `ok:` lines, exit 0.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `bash test/run.sh`
Expected: ends with `ALL UNIT TESTS PASS` (the pre-existing `extras_members` caveat from a fresh checkout without a built prefix is unrelated to this change).

- [ ] **Step 6: Commit**

```bash
git add scripts/discover-pin-rows.sh test/discover_pin_rows.test.sh
git commit -m "feat: add discover-pin-rows.sh for filesystem-driven pin generation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Wire the `pin` job to discovery

**Files:**
- Modify: `.github/workflows/release.yml:118-129` (the `Generate EtRuntimePin.cmake` step)
- Test: `test/pin_discovery_integration.test.sh`

**Interfaces:**
- Consumes: `scripts/discover-pin-rows.sh` (Task 1) and `scripts/gen-pin.sh` (unchanged: `--version <pkgver> --etver <etver> --base-url <url> --row <variant> <platform> <sha> ...`).
- Produces: `dist/EtRuntimePin.cmake` with one `ET_RUNTIME_URL_*` / `ET_RUNTIME_SHA256_*` pair per discovered artifact.

- [ ] **Step 1: Write the failing integration test**

Create `test/pin_discovery_integration.test.sh` — this replicates the exact bash pipeline the workflow step runs, proving discovery feeds gen-pin correctly and asymmetric coverage produces only the present rows:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mk() { printf '%s  %s\n' "$1" "${2%.sha256}" > "$tmp/$2"; }
mk deadbeef executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
mk 12345678 executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz.sha256

# Mirror the workflow step's pipeline exactly.
base="https://example.com/releases/download/v1.3.1-1"
args=(--version 1.3.1-1 --etver 1.3.1 --base-url "$base")
while IFS="$(printf '\t')" read -r variant platform sha; do
  args+=(--row "$variant" "$platform" "$sha")
done < <(bash "$here/../scripts/discover-pin-rows.sh" --dir "$tmp" --etver 1.3.1)
out="$(bash "$here/../scripts/gen-pin.sh" "${args[@]}")"

assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_linux-x86_64 "deadbeef")'   "linux row present"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_windows-x86_64 "12345678")' "windows row present"
assert_contains "$out" "$base/executorch-runtime-1.3.1-logging-windows-x86_64.tar.gz" "windows url value"
# No fabricated windows bare/devtools rows (the old hardcoded loop would have demanded them).
case "$out" in *windows-x86_64*bare*|*bare*windows-x86_64*) printf 'FAIL: unexpected windows bare row\n' >&2; exit 1 ;; esac

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it passes already**

Run: `bash test/pin_discovery_integration.test.sh`
Expected: PASS — this test exercises the scripts directly (not the YAML), so it passes once Task 1 exists. It is the regression guard for the pipeline the workflow will run.

- [ ] **Step 3: Edit the `pin` job step**

In `.github/workflows/release.yml`, replace the hardcoded double loop in the `Generate EtRuntimePin.cmake` step. Change:

```yaml
          args=(--version "$pkgver" --etver "$etver" --base-url "$base")
          for platform in $(echo "$PLATFORMS" | jq -r '.[].platform'); do
            for variant in bare logging devtools; do
              sha="$(cut -d' ' -f1 "dist/executorch-runtime-${etver}-${variant}-${platform}.tar.gz.sha256")"
              args+=(--row "$variant" "$platform" "$sha")
            done
          done
          ./scripts/gen-pin.sh "${args[@]}" > dist/EtRuntimePin.cmake
```

to:

```yaml
          args=(--version "$pkgver" --etver "$etver" --base-url "$base")
          while IFS=$'\t' read -r variant platform sha; do
            args+=(--row "$variant" "$platform" "$sha")
          done < <(./scripts/discover-pin-rows.sh --dir dist --etver "$etver")
          ./scripts/gen-pin.sh "${args[@]}" > dist/EtRuntimePin.cmake
```

This removes the `pin` job's use of `$PLATFORMS` and the hardcoded `bare logging devtools` list. (The workflow-level `env.PLATFORMS` stays — the `setup`/`build` jobs still use it.)

- [ ] **Step 4: Sanity-check the YAML**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo YAML_OK`
Expected: `YAML_OK` (no parse error). Also confirm the `pin` step no longer greps `$PLATFORMS`:
Run: `awk '/^  pin:/,/^  release:/' .github/workflows/release.yml | grep -c PLATFORMS`
Expected: `0`.

- [ ] **Step 5: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml test/pin_discovery_integration.test.sh
git commit -m "refactor: drive pin job from filesystem discovery, not hardcoded matrix

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** §"Design/Extracted testable script" → Task 1 (`discover-pin-rows.sh` reusing `naming.sh`, first-dash split, sha extraction, deterministic sort). §"Tests" → Task 1 test (single/asymmetric coverage, dash-split, sha, ordering) + Task 2 integration test. §"pin job becomes discover→gen-pin, hardcode + $PLATFORMS removed" → Task 2. `gen-pin.sh`/`naming.sh` reused-unchanged → honored. No spec requirement left without a task.
- **Naming validation:** the SSOT concern (no second copy of the scheme) is enforced by the `tarball_name` round-trip check in Task 1 Step 3.
- **Type/interface consistency:** Task 2 consumes exactly the `variant<TAB>platform<TAB>sha` TSV that Task 1 produces; the `while IFS=$'\t' read` matches the `printf '%s\t%s\t%s\n'` emitter.
- **Note vs. spec:** spec said "Registered in `test/run.sh`"; corrected here — `run.sh` auto-globs `*.test.sh`, so placement suffices (Global Constraints).
