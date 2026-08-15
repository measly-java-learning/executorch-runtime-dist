# ccache for the extras-gate `full-aot` job — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut `full-aot`'s ~1276s duration by caching its C++ object compilation across gate runs
with ccache, enforced by a hit-rate floor so the cache cannot silently stop working.

**Architecture:** A pinned ccache binary is fetched from its upstream GitHub release and verified
against a SHA-256 held in a new `scripts/lib/ccache.sh` SSOT. `actions/cache` restores a per-job
cache into `$GITHUB_WORKSPACE/.ccache` before the build and saves it after. ExecuTorch's own CMake
auto-detects ccache; the `pytorch_tokenizers` sub-build needs an explicit `CMAKE_ARGS` injection.
After the build, `ccache --print-stats` is parsed, written to the job summary, and enforced against
a floor — but only when the cache key matched exactly.

**Tech Stack:** bash, GitHub Actions (`actions/cache@v4`), ccache 4.13.6, manylinux_2_28 container.

**Spec:** `docs/superpowers/specs/2026-08-15-ccache-gate-design.md`

## Global Constraints

- **Scope is `full-aot` ONLY.** `full-build` is explicitly deferred — it is not on the critical
  path, so caching it buys zero wall clock. Do not wire it in this plan.
- **Success metric is `full-aot`'s own duration** (baseline band 1250–1468s, ~218s of noise), never gate wall clock and
  never `full-build`.
- **Threshold value MUST live in the workflow `env` block**, never in `scripts/lib/*` or
  `build-runtime.sh` — those are inside the cache key's `hashFiles` set, so putting it there would
  make every threshold tweak invalidate every cache.
- **Initial threshold: 1%.** Not a guess at the real rate; it catches only "the cache stopped
  working entirely" and cannot flap. Tune up later.
- **Enforce only on an exact key match** (`cache-hit == 'true'`). A prefix restore-key hit must
  report but never fail — the first run after an ET pin bump legitimately misses everything.
- `CCACHE_DIR=$GITHUB_WORKSPACE/.ccache` (the mounted volume; the default `/root/.ccache` is in the
  container's ephemeral layer).
- `ccache -M 2G` and `ccache -z` before the build.
- Shell scripts run under `set -euo pipefail`. `grep` exits 1 on no-match, which aborts under
  `set -e` — guard with `|| true` per repo convention.
- ccache is **GPL-3.0**, used only as a build tool and never shipped inside an artifact, so it
  carries no notice obligation in `THIRD-PARTY-NOTICES/`. Do not add one; do state the reasoning in
  the lib so nobody re-litigates it.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/ccache.sh` (new) | SSOT: pinned version, SHA-256, URL, archive member path. Sourced only. |
| `scripts/install-ccache.sh` (new) | Download → verify SHA-256 → install to `/usr/local/bin`. Idempotent. |
| `scripts/ccache-stats.sh` (new) | Parse `--print-stats`, emit summary, enforce the floor. |
| `test/ccache_lib.test.sh` (new) | Hermetic: SSOT shape, installer/stats behaviour on fixtures. |
| `test/ccache_gate_wiring.test.sh` (new) | Hermetic: the workflow wires it correctly. |
| `.github/workflows/extras-gate.yml` | `full-aot` gains install + cache + stats steps. |
| `.gitignore` | ignore `.ccache/` |

---

### Task 1: Pin ccache in an SSOT lib

**Files:**
- Create: `scripts/lib/ccache.sh`
- Test: `test/ccache_lib.test.sh`

**Interfaces:**
- Produces: `CCACHE_VERSION`, `CCACHE_SHA256`, `CCACHE_ARCHIVE`, `CCACHE_URL`, `CCACHE_MEMBER`
  — consumed by Task 2's installer and Task 5's wiring test.

- [ ] **Step 1: Write the failing test**

```bash
# test/ccache_lib.test.sh
#!/usr/bin/env bash
# ccache is pinned by version AND hash, like the OpenVINO wheel (OV_WHEEL_SHA256). A version
# without a hash is not a pin: the same URL can serve different bytes later.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"
. "$root/scripts/lib/ccache.sh"

assert_eq "4.13.6" "$CCACHE_VERSION" "pinned ccache version"
# a sha256 is 64 lowercase hex chars - catches a truncated or placeholder paste
if printf '%s' "$CCACHE_SHA256" | grep -qE '^[0-9a-f]{64}$'; then
  echo "ok: CCACHE_SHA256 is a well-formed sha256"
else
  echo "FAIL: CCACHE_SHA256 malformed: $CCACHE_SHA256" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
# the URL must carry the pinned version, or bumping the version silently fetches the old asset
case "$CCACHE_URL" in
  *"v${CCACHE_VERSION}/"*"${CCACHE_VERSION}"*) echo "ok: URL is derived from CCACHE_VERSION" ;;
  *) echo "FAIL: CCACHE_URL does not embed CCACHE_VERSION: $CCACHE_URL" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac
case "$CCACHE_MEMBER" in
  *"${CCACHE_VERSION}"*/ccache) echo "ok: archive member is derived from CCACHE_VERSION" ;;
  *) echo "FAIL: CCACHE_MEMBER not version-derived: $CCACHE_MEMBER" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash test/ccache_lib.test.sh`
Expected: FAIL — `scripts/lib/ccache.sh` does not exist (sourcing aborts).

- [ ] **Step 3: Write the lib**

```bash
# scripts/lib/ccache.sh
#!/usr/bin/env bash
# ccache: pinned build-tool binary (version + hash). SINGLE SOURCE OF TRUTH.
# Sourced by scripts/install-ccache.sh and the hermetic tests. Source me.
#
# Fetched from the upstream GitHub release rather than `dnf install ccache`, which provides 3.7.7 -
# six majors behind. 4.x is required here for `--print-stats`, a tab-separated machine-readable
# counter dump; 3.x offers only prose output that changes between releases.
#
# Verified to run on manylinux_2_28 (AlmaLinux 8.10, glibc 2.28). The `-glibc` build suffices; a
# `musl-static` asset exists as a fallback if a future base image drifts below that floor.
#
# .tar.gz, not .tar.xz: gzip is universally present, which drops a dependency on `xz` surviving a
# base-image change. The .xz asset is ~450KB smaller and not worth the coupling.
#
# LICENSING: ccache is GPL-3.0. It is a BUILD TOOL - it never links into, and is never shipped
# inside, any published artifact - so it carries NO notice obligation and must NOT be added to
# THIRD-PARTY-NOTICES/. This differs from Google Highway, which ships as libhwy.a and therefore
# does. Recorded here so the distinction is not re-litigated.
#
# NOTE: this file is inside the ccache key's hashFiles() set, so bumping the version correctly
# invalidates every cache (cache formats can change between versions). That costs one full-price
# run per job - expected, not a bug.
CCACHE_VERSION="4.13.6"
CCACHE_ARCHIVE="ccache-${CCACHE_VERSION}-linux-x86_64-glibc.tar.gz"
CCACHE_URL="https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/${CCACHE_ARCHIVE}"
CCACHE_MEMBER="ccache-${CCACHE_VERSION}-linux-x86_64-glibc/ccache"
# sha256 of CCACHE_ARCHIVE (1754958 bytes), verified against the size GitHub's release API reports.
# Upstream signs releases with minisign (.minisig), NOT GitHub build attestations, so
# `gh attestation verify` does not apply - and `gh` is absent from the manylinux containers anyway.
# Pinning the hash ourselves asserts the exact bytes we tested and needs no extra tooling.
CCACHE_SHA256="567b1b648411819590f918f045218c92da14418bdec3b30db94a3b4f5d77cf13"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/ccache_lib.test.sh` → all `ok:` lines, exit 0.
Then: `bash test/run.sh` → `ALL UNIT TESTS PASS` (the new test is picked up by the `*.test.sh` glob).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ccache.sh test/ccache_lib.test.sh
git commit -m "feat(ccache): pin ccache 4.13.6 by version and sha256"
```

---

### Task 2: Installer script

**Files:**
- Create: `scripts/install-ccache.sh`
- Modify: `test/ccache_lib.test.sh`

**Interfaces:**
- Consumes: everything from `scripts/lib/ccache.sh`.
- Produces: `ccache` on `PATH` at `/usr/local/bin/ccache`. Exit non-zero on hash mismatch.

- [ ] **Step 1: Add the failing tests**

Append to `test/ccache_lib.test.sh`:

```bash
# The installer must REFUSE a tarball whose hash does not match. This is the whole point of
# pinning; an installer that downloads and runs whatever it got is not a pin.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'not a real tarball' > "$tmp/fake.tar.gz"
if CCACHE_LOCAL_ARCHIVE="$tmp/fake.tar.gz" CCACHE_PREFIX_DIR="$tmp/bin" \
     "$root/scripts/install-ccache.sh" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a tarball with the wrong hash" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: installer rejects a hash mismatch"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/ccache_lib.test.sh`
Expected: FAIL — `scripts/install-ccache.sh` does not exist, so the `if` sees a non-zero exit and
*passes* for the wrong reason. Confirm the file is genuinely absent before proceeding; this
assertion only becomes meaningful once the script exists.

- [ ] **Step 3: Write the installer**

```bash
#!/usr/bin/env bash
# Install the pinned ccache into CCACHE_PREFIX_DIR (default /usr/local/bin).
#   scripts/install-ccache.sh
# Test hooks: CCACHE_LOCAL_ARCHIVE uses an existing file instead of downloading;
#             CCACHE_PREFIX_DIR overrides the install dir.
#
# Idempotent: if the target already reports the pinned version, it exits 0 without downloading.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/ccache.sh
. "$ROOT/scripts/lib/ccache.sh"

prefix="${CCACHE_PREFIX_DIR:-/usr/local/bin}"
target="$prefix/ccache"

if [ -x "$target" ] && "$target" --version 2>/dev/null | head -1 | grep -q "$CCACHE_VERSION"; then
  echo "ccache $CCACHE_VERSION already installed at $target"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${CCACHE_LOCAL_ARCHIVE:-}" ]; then
  cp "$CCACHE_LOCAL_ARCHIVE" "$work/$CCACHE_ARCHIVE"
else
  curl -fsSL -o "$work/$CCACHE_ARCHIVE" "$CCACHE_URL"
fi

actual="$(sha256sum "$work/$CCACHE_ARCHIVE" | cut -d' ' -f1)"
if [ "$actual" != "$CCACHE_SHA256" ]; then
  echo "install-ccache.sh: SHA-256 MISMATCH for $CCACHE_ARCHIVE" >&2
  echo "  expected $CCACHE_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

tar -C "$work" -xzf "$work/$CCACHE_ARCHIVE" "$CCACHE_MEMBER"
mkdir -p "$prefix"
install -m 0755 "$work/$CCACHE_MEMBER" "$target"
"$target" --version | head -1
```

- [ ] **Step 4: Verify**

```bash
chmod +x scripts/install-ccache.sh
bash test/ccache_lib.test.sh      # "ok: installer rejects a hash mismatch"
bash test/run.sh                  # ALL UNIT TESTS PASS
```

Then prove the happy path against the real container (NOT hermetic, do not add to `run.sh`):

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -c 'CCACHE_PREFIX_DIR=/tmp/b ./scripts/install-ccache.sh && /tmp/b/ccache --version'
```
Expected: `ccache version 4.13.6`.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-ccache.sh test/ccache_lib.test.sh
git commit -m "feat(ccache): hash-verified installer for the pinned binary"
```

---

### Task 3: Stats parser and threshold enforcement

**Files:**
- Create: `scripts/ccache-stats.sh`
- Modify: `test/ccache_lib.test.sh`

**Interfaces:**
- Consumes: `ccache --print-stats` output (or `CCACHE_STATS_FILE` for tests).
- Produces: hit-rate line on stdout; appends to `$GITHUB_STEP_SUMMARY` when set; exits 1 when
  `CCACHE_ENFORCE=1` and the rate is below `CCACHE_MIN_HIT_RATE`.

Counter names verified against real 4.13.6 output: `direct_cache_hit`, `preprocessed_cache_hit`,
`cache_miss`.

- [ ] **Step 1: Write the failing tests**

Append to `test/ccache_lib.test.sh`:

```bash
# Fixture in the real 4.13.6 --print-stats format (tab-separated).
mk_stats() { printf 'direct_cache_hit\t%s\npreprocessed_cache_hit\t%s\ncache_miss\t%s\n' "$1" "$2" "$3"; }

mk_stats 90 0 10 > "$tmp/s1"
out="$(CCACHE_STATS_FILE="$tmp/s1" "$root/scripts/ccache-stats.sh" 2>&1)"
case "$out" in *"90.0%"*) echo "ok: computes 90% from 90 hits / 10 misses" ;;
  *) echo "FAIL: expected 90.0% in: $out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac

# Enforcement fires below the floor.
if CCACHE_STATS_FILE="$tmp/s1" CCACHE_ENFORCE=1 CCACHE_MIN_HIT_RATE=95 \
     "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "FAIL: 90% passed a 95% floor" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: enforcement fails below the floor"
fi

# ... and does NOT fire when enforcement is off (the restore-key case).
if CCACHE_STATS_FILE="$tmp/s1" CCACHE_MIN_HIT_RATE=95 \
     "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "ok: reports without failing when enforcement is off"
else
  echo "FAIL: failed despite CCACHE_ENFORCE unset" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# A zero-work run must not be reported as 100% or 0% - it is undefined, and enforcing on it would
# fail any run where every object was already up to date.
mk_stats 0 0 0 > "$tmp/s2"
out="$(CCACHE_STATS_FILE="$tmp/s2" CCACHE_ENFORCE=1 CCACHE_MIN_HIT_RATE=50 "$root/scripts/ccache-stats.sh" 2>&1)" \
  && echo "ok: zero-compilation run does not fail enforcement" \
  || { echo "FAIL: zero-work run failed enforcement: $out" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# MISSING KEYS MUST BE LOUD. A parser that silently yields 0 fails every run; one that silently
# yields 100% makes the whole gate vacuous. This is the assertion that keeps it honest.
printf 'some_other_counter\t5\n' > "$tmp/s3"
if CCACHE_STATS_FILE="$tmp/s3" "$root/scripts/ccache-stats.sh" >/dev/null 2>&1; then
  echo "FAIL: parser accepted stats with no recognisable counters" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: parser fails loudly when expected counters are absent"
fi
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash test/ccache_lib.test.sh`
Expected: FAIL on the `90.0%` assertion — the script does not exist yet.

- [ ] **Step 3: Write the parser**

```bash
#!/usr/bin/env bash
# Report the ccache hit rate for THIS run and optionally enforce a floor.
#   scripts/ccache-stats.sh
# Env: CCACHE_STATS_FILE  read stats from a file instead of running ccache (tests)
#      CCACHE_ENFORCE=1   exit 1 when below the floor (set ONLY on an exact cache-key match)
#      CCACHE_MIN_HIT_RATE  floor in percent (default 1)
#
# Counters come from `ccache --print-stats` (tab-separated, machine-readable). Do NOT parse
# `ccache -s`: in 4.x it prints only a size summary by default, and its prose changes between
# releases. Key names verified against real 4.13.6 output.
#
# The run must have been preceded by `ccache -z`, or these are LIFETIME counters and the rate
# drifts upward forever regardless of what this run did.
set -euo pipefail

if [ -n "${CCACHE_STATS_FILE:-}" ]; then
  stats="$(cat "$CCACHE_STATS_FILE")"
else
  stats="$(ccache --print-stats)"
fi

get() { printf '%s\n' "$stats" | awk -F'\t' -v k="$1" '$1==k {print $2; found=1} END {if(!found) print ""}'; }
direct="$(get direct_cache_hit)"
pre="$(get preprocessed_cache_hit)"
miss="$(get cache_miss)"

# Loud failure beats a silent 0% or 100%.
if [ -z "$direct" ] || [ -z "$pre" ] || [ -z "$miss" ]; then
  echo "ccache-stats.sh: expected counters absent from --print-stats output." >&2
  echo "  looked for: direct_cache_hit, preprocessed_cache_hit, cache_miss" >&2
  echo "  got:" >&2; printf '%s\n' "$stats" | head -20 >&2
  exit 2
fi

hits=$(( direct + pre ))
total=$(( hits + miss ))
floor="${CCACHE_MIN_HIT_RATE:-1}"

if [ "$total" -eq 0 ]; then
  # Nothing was compiled. Undefined, not 0% - enforcing here would fail a legitimately no-op run.
  msg="ccache: no compilations this run (0 hits, 0 misses) - nothing to enforce"
  echo "$msg"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$msg" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

rate="$(awk -v h="$hits" -v t="$total" 'BEGIN{printf "%.1f", (h*100)/t}')"
msg="ccache hit rate: ${rate}% (${hits} hits / ${total} compilations, ${miss} misses)"
echo "$msg"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### ccache"; echo ""; echo "$msg"; } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${CCACHE_ENFORCE:-0}" = "1" ]; then
  if awk -v r="$rate" -v f="$floor" 'BEGIN{exit !(r < f)}'; then
    echo "::error::ccache hit rate ${rate}% is below the ${floor}% floor on an EXACT cache-key match." >&2
    echo "  An exact key match means the cache restored the objects this build should reuse." >&2
    echo "  A rate this low means ccache is effectively not working - investigate before raising the floor." >&2
    exit 1
  fi
fi
```

- [ ] **Step 4: Verify**

```bash
chmod +x scripts/ccache-stats.sh
bash test/ccache_lib.test.sh   # all five new assertions ok
bash test/run.sh               # ALL UNIT TESTS PASS
```

- [ ] **Step 5: Commit**

```bash
git add scripts/ccache-stats.sh test/ccache_lib.test.sh
git commit -m "feat(ccache): hit-rate parser with a loud-failure guard"
```

---

### Task 4: Wire `full-aot` in the workflow

**Files:**
- Modify: `.github/workflows/extras-gate.yml` (the `full-aot` job)
- Modify: `.gitignore`

- [ ] **Step 1: Add `.ccache/` to `.gitignore`**

```
.ccache/
```
Place it beside the existing `out*/` entry, with a one-line comment noting it is the gate's ccache
directory and must never be committed.

- [ ] **Step 2: Add the env block to `full-aot`**

The threshold lives HERE — not in `scripts/lib/`, which the cache key hashes.

```yaml
    env:
      ETVER: ${{ needs.classify.outputs.etver }}
      CCACHE_DIR: ${{ github.workspace }}/.ccache
      # Floor for the ccache hit rate, enforced only on an exact cache-key match. Deliberately
      # low: it catches "the cache stopped working", not "the cache is suboptimal". It lives in
      # this env block ON PURPOSE - scripts/lib/* is inside the cache key's hashFiles() set, so
      # tuning it there would invalidate every cache on every tweak.
      CCACHE_MIN_HIT_RATE: "1"
```

- [ ] **Step 3: Insert the steps**

After `- uses: actions/checkout@v7` and BEFORE `Install the AOT toolchain`:

```yaml
      - name: Install pinned ccache
        run: ./scripts/install-ccache.sh
      - name: Restore ccache
        id: ccache-restore
        uses: actions/cache@v4
        with:
          path: ${{ github.workspace }}/.ccache
          # <sha> suffix is REQUIRED: actions/cache never overwrites an existing key, so without it
          # the cache would be written once and then frozen forever. restore-keys supply the
          # nearest prior cache. This is hit-rate tuning only - ccache re-hashes every object, so a
          # stale restore cannot produce a wrong artifact, only a slower build.
          key: ccache-full-aot-x86_64-et${{ needs.classify.outputs.etver }}-${{ hashFiles('patches/*.patch', 'scripts/lib/*.sh', 'build-runtime.sh') }}-${{ github.sha }}
          restore-keys: |
            ccache-full-aot-x86_64-et${{ needs.classify.outputs.etver }}-${{ hashFiles('patches/*.patch', 'scripts/lib/*.sh', 'build-runtime.sh') }}-
            ccache-full-aot-x86_64-et${{ needs.classify.outputs.etver }}-
      - name: Configure ccache
        # -z zeroes the counters so the stats step measures THIS run, not the restored cache's
        # lifetime. Without it the reported rate drifts upward forever and the floor is meaningless.
        run: |
          set -euo pipefail
          ccache -M 2G
          ccache -z
          ccache --version | head -1
```

Then modify the existing `Install the AOT toolchain` step to export `CMAKE_ARGS`:

```yaml
      - name: Install the AOT toolchain (executorch python package from the pinned source)
        run: |
          set -euo pipefail
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          # ExecuTorch's own CMakeLists auto-detects ccache (find_program at CMakeLists.txt:187),
          # but pytorch_tokenizers is a SEPARATE cmake project with no ccache logic - and it is the
          # ~5 minute sdist build. Its setup.py forwards CMAKE_ARGS, so inject the launcher here.
          export CMAKE_ARGS="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
          (cd et-src/executorch && ./install_executorch.sh)
          pip install -r requirements/extras-build.txt
```

Immediately after that step:

```yaml
      - name: ccache stats
        # Enforce ONLY on an exact key match. On a restore-key (prefix) hit the cache is from a
        # different input set - the first run after an ET pin bump legitimately misses everything,
        # and failing it would punish the run for doing the right thing.
        env:
          CCACHE_ENFORCE: ${{ steps.ccache-restore.outputs.cache-hit == 'true' && '1' || '0' }}
        run: ./scripts/ccache-stats.sh
```

- [ ] **Step 4: Verify the YAML parses and the suite is green**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/extras-gate.yml')); print('ok')"
bash test/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/extras-gate.yml .gitignore
git commit -m "perf(gate): cache full-aot's C++ compilation with ccache"
```

---

### Task 5: Structural guard for the wiring

**Files:**
- Create: `test/lib/check_ccache_wiring.py` — the structural checks
- Create: `test/ccache_gate_wiring.test.sh` — thin invoker (needed for `test/run.sh`'s glob)

The failure mode is silent: every one of these can break while the gate still passes, just slowly.

**Why two files:** per CLAUDE.md's convention, non-trivial Python does not live in a bash heredoc.
The shell script keeps the orchestration (skip logic, failure accounting) and the YAML-structural
logic goes in a file that can be linted, run directly (`python3 test/lib/check_ccache_wiring.py
.github/workflows/extras-gate.yml`), and given a traceback with real line numbers.

- [ ] **Step 1: Write the checker**

```python
#!/usr/bin/env python3
"""Assert the full-aot ccache wiring is intact.

Usage: check_ccache_wiring.py <path to extras-gate.yml>

Every assertion here protects against a change that leaves the gate GREEN but the cache useless -
the failure mode is a slow gate nobody investigates, not a red X.
"""
import sys

import yaml


def main(path: str) -> int:
    fails = 0

    def ok(cond, msg):
        nonlocal fails
        if cond:
            print(f"ok: {msg}")
        else:
            print(f"FAIL: {msg}", file=sys.stderr)
            fails += 1

    jobs = yaml.safe_load(open(path))["jobs"]
    aot = jobs["full-aot"]
    steps = aot["steps"]
    runs = "\n".join(str(s.get("run", "")) for s in steps)

    ok("./scripts/install-ccache.sh" in runs, "full-aot installs the pinned ccache")
    ok("ccache -z" in runs, "counters zeroed, so stats measure THIS run not the restored lifetime")
    ok("ccache -M" in runs, "cache size is capped (the 10GB repo budget is shared)")
    ok("./scripts/ccache-stats.sh" in runs, "hit rate is reported")

    # The tokenizers sub-build is the ~5min one and is NOT covered by ExecuTorch's find_program.
    ok("CMAKE_CXX_COMPILER_LAUNCHER=ccache" in runs,
       "launcher injected for the tokenizers sub-build")

    # The threshold must NOT live in a file the cache key hashes, or tuning it invalidates
    # every cache.
    env = aot.get("env", {})
    ok("CCACHE_MIN_HIT_RATE" in env, "threshold lives in workflow env, not scripts/lib")
    ok(str(env.get("CCACHE_DIR", "")).endswith(".ccache"), "CCACHE_DIR is under the workspace")

    cache_steps = [s for s in steps if "actions/cache" in str(s.get("uses", ""))]
    ok(len(cache_steps) == 1, "exactly one cache step")
    if cache_steps:
        with_ = cache_steps[0]["with"]
        key = str(with_["key"])
        ok("github.sha" in key, "key has a unique suffix (actions/cache never overwrites a key)")
        ok("hashFiles" in key, "key is invalidated by patches/lib/recipe changes")
        ok("restore-keys" in with_, "prefix fallback exists so a novel key still starts warm")

    # Enforcement must be conditional on an EXACT match, never a prefix restore.
    stats = [s for s in steps if "ccache-stats.sh" in str(s.get("run", ""))]
    ok(bool(stats), "a stats step exists")
    if stats:
        enforce = str(stats[0].get("env", {}).get("CCACHE_ENFORCE", ""))
        ok("cache-hit" in enforce,
           "enforcement is gated on an exact cache-key match, not a prefix hit")

    # Scope discipline: full-build is deliberately NOT wired - it is not on the critical path,
    # so caching it buys zero wall clock. See the plan's global constraints.
    build_runs = "\n".join(str(s.get("run", "")) for s in jobs["full-build"]["steps"])
    ok("install-ccache.sh" not in build_runs,
       "full-build is deliberately NOT cached (see the plan's scope constraint)")

    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 2: Write the thin invoker**

```bash
#!/usr/bin/env bash
# Structural guard for the full-aot ccache wiring. The checks live in
# test/lib/check_ccache_wiring.py - this script only orchestrates, per CLAUDE.md's convention
# against non-trivial Python embedded in shell.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

python3 "$here/lib/check_ccache_wiring.py" "$here/../.github/workflows/extras-gate.yml" \
  || ASSERT_FAILS=$((ASSERT_FAILS+1))
exit "$ASSERT_FAILS"
```

- [ ] **Step 3: Run it**

```bash
bash test/ccache_gate_wiring.test.sh
# and directly, which is the point of the split:
python3 test/lib/check_ccache_wiring.py .github/workflows/extras-gate.yml
```
Expected: all `ok:` lines, exit 0.

- [ ] **Step 4: Prove it is not vacuous**

Temporarily delete the `ccache -z` line from the workflow, re-run, confirm it FAILS, then restore.
A guard nobody has seen fail is a guard nobody should trust.

- [ ] **Step 5: Run the whole suite and commit**

```bash
bash test/run.sh
git add test/ccache_gate_wiring.test.sh test/lib/check_ccache_wiring.py
git commit -m "test(ccache): structural guard for the full-aot wiring"
```

---

### Task 6: Measure, and decide whether phase two is justified

This task produces a **number and a decision**, not code. Do not skip it: the spec commits to a
falsifiable prediction, and an unmeasured cache is exactly the "looks wired up, does nothing"
outcome the guards exist to prevent.

- [ ] **Step 1: Push and let run 1 complete (the cold run)**

Record `full-aot`'s duration and hit rate. Expect the rate near 0% and the duration **at or above**
the 1250–1468s baseline band — ccache overhead plus cache upload, with nothing to restore. This run
proving slower is expected and is not a reason to stop.

- [ ] **Step 2: Trigger run 2 on the same branch (the real measurement)**

An empty commit is sufficient (`git commit --allow-empty`). Record `full-aot`'s duration and hit
rate.

- [ ] **Step 3: Evaluate against the prediction**

| Outcome | Meaning | Action |
|---|---|---|
| hit rate >90%, `full-aot` well below 1250s | design holds | proceed to step 4 |
| hit rate >90%, duration ~unchanged | compilation was not the bottleneck we thought | STOP, reinvestigate where `full-aot`'s time actually goes |
| hit rate <90% | premise is wrong | STOP. Do not tune keys — at a low hit rate ccache is pure cost. Revert. |

**`full-aot` itself varies 1250–1468s (a 218s spread, ~17%) on an unchanged build** — measured
across four green runs. Treat any improvement smaller than ~218s as noise. One run either side of
the change CANNOT settle this; repeat the measurement, or require an improvement large enough to
dwarf the band. This is the single easiest way to fool ourselves into shipping a cache that does
nothing.

- [ ] **Step 4: Decide on phase two, with evidence**

`full-build` gets a cache **only if** `full-aot`'s new duration drops below `full-build`'s
800–1080s band — i.e. only once the critical path has actually moved. Record the decision and the
numbers in the spec's expected-outcome section. If `full-aot` is still the pole, phase two buys
nothing and must not be built.

- [ ] **Step 5: Record the real cache size**

Read it from the `ccache -s` summary or the Actions cache list. The spec caps at 2G on a guess;
two caches × every open PR share a 10GB repo budget under LRU. If the real size makes thrash
plausible, lower the cap and note the number in the spec.

- [ ] **Step 6: Commit the findings**

```bash
git add docs/superpowers/specs/2026-08-15-ccache-gate-design.md
git commit -m "docs(ccache): record measured hit rate and phase-two decision"
```
