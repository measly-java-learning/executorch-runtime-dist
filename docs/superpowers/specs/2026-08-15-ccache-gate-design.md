# ccache for the extras-gate heavy jobs — design

**Status:** approved for planning
**Date:** 2026-08-15
**Goal:** cut wall clock on the `full` gate's two compile-bound jobs by caching C++ object
compilation across runs, without touching published artifacts.

## Why

The `full` gate is compile-bound. Measured on run 31909631718 (green, post-split):

| job | duration | note |
|---|---|---|
| `classify` | 7s | |
| `full-build` | 1080s | `build-runtime.sh` — full ET compile |
| `full-aot` | 1297s | **critical path** — `install_executorch.sh` |
| `full-gates` | 58s | cheap probes |
| **wall clock** | **1369s** | vs 1807s before the job split |

The parallel split (PR #29) took this from 1807s to 1369s by overlapping the two heavy jobs. It
cannot do better than its slowest half, so further gains must make `full-aot` itself faster.

### `full-aot` is the critical path; `full-build` is not

Across the four green runs measured so far:

| run | `full-build` | `full-aot` | wall clock |
|---|---|---|---|
| 31909631718 | 1080s | 1297s | 1369s |
| 31910447973 | 803s | 1250s | 1326s |
| 31910949775 | 832s | 1276s | 1358s |
| 31913009925 | 796s | **1468s** | 1541s |

`full-aot` is the critical path in **every** run, and `full-build` has never come within 170s of
it. Two consequences that drive the implementation order:

1. **Caching `full-build` alone buys zero wall clock.** It only makes an already-idle job idler.
   Any measurement that reports a `full-build` speedup as a *gate* speedup is measuring the wrong
   thing.
2. Therefore: **wire `full-aot` first and measure it alone.** `full-build`'s cache is worth having
   only to keep it off the critical path once `full-aot` shrinks — a question that cannot be
   answered until we know how far `full-aot` actually falls, and one that costs a share of the
   10GB cache budget to answer wrongly.

### Runner variance sets the measurement bar

Both jobs vary substantially on an **unchanged** build:

- `full-build`: 796–1080s (the 1080s is the outlier; the other three cluster at 796–832s)
- `full-aot`: **1250–1468s — a 218s spread, ~17%**

The `full-aot` number is the one that matters, and it is worse than an early reading of three
runs suggested (1250–1297s looked stable; the fourth run landed at 1468s). **A ccache result must
clear ~218s to mean anything.** A single run either side of the change cannot settle it — the
measurement needs repeated runs, or an improvement large enough to dwarf the band. Anything
smaller is indistinguishable from a noisy runner.

Inside `full-aot`'s 1297s, ~1127s is building: ~2293 C++ translation units for the ExecuTorch
python package, plus a ~5 minute `pytorch_tokenizers` build. **ExecuTorch is pinned** (v1.3.1,
`e2f18eb`), so those TUs are byte-identical across every PR. Only our `patches/*` (a handful of
files) and `extras/` change. That is close to an ideal ccache workload.

### Rejected first: caching the wheel

The obvious framing — "cache the wheel we keep rebuilding" — does not work.
`install_executorch.py` runs `pip install . --no-build-isolation` against a **local directory**,
and pip's wheel cache deliberately never covers local path builds. `pytorch_tokenizers` is the
same shape (a directory in the ET tree, not a PyPI package). There is no wheel to cache. What is
cacheable is the *compilation* underneath it, which is what this design targets.

## Scope

**Gate only.** `extras-gate.yml`'s `full-aot` first, then `full-build` **only if justified** by
what `full-aot` measures (see the critical-path section above).

Explicitly out of scope: `release.yml` (its `build` job is a {3 variants × 2 arches} matrix and
would benefit more, but this repo publishes **attested** tarballs, and "published binaries were
assembled partly from a CI cache" is a provenance posture change that should be decided on its own
merits, not inherited from a speed change); the two Windows jobs (non-container MSVC runners need
`sccache`, a second unrelated mechanism); `fast-gate` and `live-roundtrip` (extras-only builds,
seconds, nothing to win).

## Correctness

**ccache's correctness does not depend on our cache key.** ccache hashes the preprocessed source,
the compiler binary, and the flags for every object. The GitHub cache key only decides which blob
we download to start from. A stale or mismatched restore cannot yield a wrong object — it only
misses more. Key design is therefore a hit-rate tuning problem, not a correctness one, and that is
why the aggressive `restore-keys` fallback below is safe.

## Mechanism

ccache is not in `quay.io/pypa/manylinux_2_28_x86_64`.

### Install from the pinned upstream release, not dnf

`dnf install -y ccache` works but provides **3.7.7** — six major versions behind, with prose-only
statistics (see below). Instead, fetch the pinned upstream release tarball:

```
https://github.com/ccache/ccache/releases/download/v4.13.6/ccache-4.13.6-linux-x86_64-glibc.tar.xz
```

- **1.2 MB**, so the download is faster than the dnf transaction and its metadata refresh.
- **Verified to run on this container**: ccache 4.13.6 executes correctly on
  AlmaLinux 8.10 / **glibc 2.28**, which is manylinux_2_28's floor. The `-glibc` build is
  sufficient; the `musl-static` variant is available as a fallback if a future base image drifts.
- Pin the **version and SHA-256** in `scripts/lib/`, following the existing `OV_WHEEL_SHA256`
  pattern — this repo already treats "pinned version + pinned hash in an SSOT lib" as the way to
  vendor a third-party binary, and reusing it keeps the integrity check uniform.

Note on signatures: the release assets carry **minisign** signatures (`.minisig`), which verify
against ccache's published public key via `minisign -V` — this is *not* a GitHub build attestation,
so `gh attestation verify` does not apply and no sigstore bundle is published alongside. Our own
pinned SHA-256 is the stronger control for this use anyway: it asserts the exact bytes we tested,
requires no additional tooling inside the container, and matches how the OpenVINO wheel is already
vendored. (`gh` is also not present in the manylinux containers — the reason the gate's download
step runs in a separate ubuntu job.)

### Not the PATH shim

The conventional trick — putting `/usr/lib64/ccache` first on `PATH` — **does not work in this
container** and must not be used. Verified: the RPM's shim dir contains only `cc`, `gcc`,
`x86_64-redhat-linux-gcc` — there is **no `c++` or `g++` shim** — and the real toolchain is
`gcc-toolset-14` (`/opt/rh/gcc-toolset-14/root/usr/bin/`), outside the shim dir. ExecuTorch is
overwhelmingly C++, so this approach would cache almost nothing while appearing to be wired up.

### Explicit compiler launcher

Two paths, because two different CMake projects are involved:

1. **ExecuTorch core — automatic.** `executorch/CMakeLists.txt:187-194` does
   `find_program(CCACHE_PROGRAM ccache)` and sets `CMAKE_CXX_COMPILER_LAUNCHER` /
   `CMAKE_C_COMPILER_LAUNCHER` when found. This covers `full-build` (which configures ET via
   `build-runtime.sh --preset linux`) **and** `full-aot` (`install_executorch.sh`). Installing
   ccache is the entire change.

2. **`pytorch_tokenizers` — explicit.** Its own
   `extension/llm/tokenizers/CMakeLists.txt` has no ccache logic, so ET's `find_program` does not
   reach it. Its `setup.py:31` `CMakeBuild` forwards the `CMAKE_ARGS` environment variable
   (`setup.py:64`), so exporting the following before `install_executorch.sh` covers it:

   ```
   CMAKE_ARGS="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
   ```

   This is the ~5 minute build that motivated the investigation.

`install_executorch.py` also contains `ccache --clear`, but only in its `--clean` path, which we
never invoke. Worth knowing before someone adds `--clean` and silently destroys the cache.

## Cache placement and layout

- `CCACHE_DIR=$GITHUB_WORKSPACE/.ccache`. In container jobs the workspace is the mounted volume,
  which is the reliable path for `actions/cache`; the ccache default (`/root/.ccache`) is inside
  the container's ephemeral layer.
- `ccache -M 2G` per cache. GitHub allows 10GB per repo with LRU eviction across ALL caches; an
  unbounded ccache (5GB default) could evict everything else in the repo.
- **Two independent caches, one per job.** `full-build` and `full-aot` run concurrently, so a
  shared key would race on save. They also compile with different flag sets, so there is no
  sharing to lose.
- `.ccache/` must be added to `.gitignore` (the repo already broadened `out*/` for exactly this
  class of accident).

## Cache keys

```
key:  ccache-<job>-<arch>-et<etver>-<hashFiles(.build-image, patches/*, scripts/lib/*, build-runtime.sh)>-<sha>
restore-keys:
  ccache-<job>-<arch>-et<etver>-<same hash>-
  ccache-<job>-<arch>-et<etver>-
```

- `<sha>` is required: `actions/cache` never overwrites an existing key, so without a unique
  suffix the cache would be written once and then frozen forever.
- The hashed inputs are the things that actually change what gets compiled: our vendored patches,
  the SSOT libraries that compose cmake flags, and the build recipe.
- `<arch>` is present so a future aarch64 job cannot restore x86-64 objects. (It would only miss,
  but it would also waste the download.)
- **`.build-image` is in the hashed set, and must stay there.** ccache hashes the compiler binary,
  so a container digest bump misses every object. Without the image in the key, that bump would
  produce an EXACT key match with a 0% hit rate — and since enforcement fires on exact matches, an
  unrelated upstream image rebuild would fail the gate with an error blaming ccache. Pinning the
  image in a repo file is what makes this expressible as `hashFiles` at all.

> **Implemented hash sets (PR #32).** The two jobs have different compiled-input surfaces, so they
> hash different sets:
> - `full-aot`: `hashFiles('.build-image', 'scripts/lib/ccache.sh')` — it never runs
>   `build-runtime.sh` and never applies `patches/*`, so hashing those would cold-miss a ~20-minute
>   cache for changes that cannot affect a single object it compiles (under-hashing is safe: ccache
>   re-hashes every object, a mismatched restore merely misses).
> - `full-build`: `hashFiles('.build-image', 'build-runtime.sh', 'patches/*', 'scripts/lib/*.sh')` —
>   it compiles from all of them, and the enforcement floor requires recipe changes to change the
>   inputs hash (otherwise a recipe edit restores an "identical-inputs" cache that then misses
>   everything and fails the gate). `scripts/lib/ccache.sh` sits inside the `scripts/lib/*.sh` glob,
>   so a ccache bump correctly invalidates both caches.

## Verification and enforcement

A cache that silently stops hitting is invisible: CI just gets slow again, which is precisely the
"standing red nobody reads" failure mode this repo has been burned by.

Every run writes `ccache -s` to `$GITHUB_STEP_SUMMARY`.

**The job FAILS when the hit rate is below the threshold, but only when the cache key matched
EXACTLY** (`steps.cache.outputs.cache-hit == 'true'`). This is the necessary escape hatch: the
first run after an ET pin bump legitimately restores an old cache via a `restore-key` prefix and
legitimately misses everything. Enforcing on a prefix-restore would fail that run for doing exactly
the right thing.

**Initial threshold: 1%.** Deliberately not a guess at the "real" number. At 1% it catches only the
failure we actually care about now — the cache has stopped working entirely — and cannot flap.
Tune upward once real hit rates are known.

**The threshold value MUST live in the workflow `env`, never in `scripts/lib/*` or any other file
inside the key's `hashFiles` set.** Otherwise raising the threshold changes the cache key and
invalidates every cache, making the tuning step expensive precisely when we want it cheap.

Hit rate is defined as:

```
(direct_cache_hit + preprocessed_cache_hit)
-------------------------------------------------------
(direct_cache_hit + preprocessed_cache_hit + cache_miss)
```

computed over the counters ccache reports for **that run only** — `ccache -z` must zero the
statistics after restoring the cache and before the build, or the restored cache's lifetime
counters would be measured instead of this run's, and the number would drift upward forever
regardless of what actually happened.

Read the counters with **`ccache --print-stats`**, not `ccache -s`. Pinning 4.13.6 (rather than
inheriting dnf's 3.7.7) buys a tab-separated machine-readable format, so the parser is a `grep`/
`awk` over stable key names instead of a regex over prose that changes between versions. The three
key names above are verified against real 4.13.6 output in the manylinux container, not assumed.
For reference, `ccache -s` in 4.x prints only a size summary by default — the detailed counters
need `-v` — which is another reason to use `--print-stats`.

The parser still needs a guard: it must fail loudly if the expected keys are absent, because a
parser that silently yields 0 hits fails every run, and one that silently yields 100% makes the
whole check vacuous.

## Expected outcome — falsifiable

ET is pinned, so the second run on a branch should hit **>90%**.

- Run 1 is **slower** than baseline: ccache overhead on every miss, plus cache upload.
- Run 2 on the same branch is the real measurement.
- If run 2 does not clear 90%, the premise of this design is wrong. Stop and reconsider rather
  than tuning keys — at a low hit rate ccache is a pure cost.

The success metric is **`full-aot`'s own duration** (baseline 1250–1297s), not the gate's wall
clock and not `full-build`. Report it that way. Gate wall clock only improves once `full-aot` drops
below `full-build`'s ~800–1080s band, at which point `full-build` becomes the critical path and the
second cache earns its keep — that is the trigger for phase two, and it is a prediction this design
makes rather than an assumption it relies on.

### Measured — 2026-08-16 (PR #32)

The two-run measurement on the first PR implementing this design:

| run | commit | `full-aot` duration | hit rate | cache |
|---|---|---|---|---|
| 31917183475 (cold) | `bca3fbb` | 1491s | 0.1% (1/1917) | not found; saved 50.9 MB |
| 31918839955 (warm) | `aa1e579` (empty) | **372s** | **100.0%** (1917/1917) | restored 49 MB, re-saved |

- **Cold run** behaved as predicted: cache miss on restore, hit rate ~0%, duration *at or above*
  the 1250–1468s baseline band (1491s, from ccache overhead plus the upload) — the slower cold run
  is expected, not a regression.
- **Warm run** settled it in one shot: all 1917 compilations hit (100.0%), duration **372s** —
  878s below the band's lower edge and ~5× the ~218s noise band, so the improvement dwarfs runner
  variance and no repeat measurement is needed.
- The **enforcement path fired correctly for the first time**: the restored cache carried the
  inputs-identifying hash, so `cache-matched-key` matched the primary-key prefix, `CCACHE_ENFORCE=1`
  engaged, and 100% ≫ the 1% floor — the gate passed with the floor actually live.
- Run 31917183475 also exposed an unrelated flake: `full-gates`' OpenVINO end-to-end compare
  failed once at `max abs diff 0.0025` (tol 0.0001) and passed on rerun at `5.96e-08` — bit-identical
  to the four pre-ccache runs, with the same inputs and the same pinned container. The delta is
  runner hardware (torch vs OpenVINO FP dispatch). Not ccache-related, but a measurement run can
  land red on it; re-run the job before reading anything into a red run.

**Phase-two decision: WIRE `full-build`.** The trigger above has fired: `full-aot` at 372s is below
`full-build`'s 800–1080s band, so the critical path has moved to `full-build` and its cache now buys
wall clock. `full-build` gets the same install/restore/configure/save/stats wiring with its own
key, and that key hashes the recipe inputs it actually compiles from (`build-runtime.sh`,
`patches/*`, `scripts/lib/*.sh`) — the enforcement-correct choice: a recipe change must produce a
*different* inputs hash (restore falls back to the loose `-et<ver>-` prefix → enforcement off,
reporting only), never an exact match that would fail the gate for doing the right thing.

### Measured — phase two (`full-build`, same PR)

| run | commit | `full-build` duration | hit rate | cache |
|---|---|---|---|---|
| 31919650432 (cold) | `d941ed9` | 993s | 1.4% (26/1898) | not found; saved 31.9 MB |
| 31920354817 (warm) | `4e5ff58` (empty) | **271s** | **100.0%** (1898/1898) | restored 31 MB, re-saved |

Same shape as `full-aot`: the cold run lands inside the 796–1080s baseline band (993s) with a ~0%
hit rate and enforcement correctly off (`matched: none`); the warm run restores, hits 100.0%, and
engages enforcement for the first time on this job — passing on 100% ≫ 1%. Duration falls to 271s
(−73%). Wall clock for the `full` gate is now ~7–8 min (max of the two heavy jobs plus `full-gates`),
down from the 1369–1541s (~23–26 min) pre-ccache band.

**Real cache size: ~31–51 MB per job** (full-build 31.9 MB, full-aot 49–51 MB; vs the 2G cap). Two
caches × every open PR against the 10GB repo budget cannot thrash at these sizes, so the cap stays
2G (risk 1, resolved by measurement).

## Known risks

1. **Cache budget thrash.** Two caches × up to 2GB × every open PR, LRU across a 10GB repo limit.
   With several concurrent PRs this could evict caches faster than they are reused, giving cost
   without benefit. **Resolved by measurement (PR #32):** each cache is ~50 MB, so eviction under
   the 10GB repo budget is not plausible; the 2G cap is retained as a safety bound.
2. **First-run regression.** Any PR whose key is novel pays ccache overhead plus upload. Acceptable
   for a gate; it is one reason this stays out of `release.yml`.
3. **A pinned ccache is one more third-party binary to keep current.** 4.13.6 is pinned by version
   and SHA-256, so it will not drift on its own — but it also will not pick up upstream fixes
   without a deliberate bump, and bumping it changes `scripts/lib/` and therefore invalidates every
   cache. That invalidation is correct (cache formats can change between versions) but means a
   ccache bump costs one full-price run per job.
4. **`install_executorch.sh --clean` would wipe the cache.** Not used today; noted so a future
   change does not silently negate this work.

## Out of scope, noted

`.github/actions/**` is in neither `extras-gate.yml`'s `paths:` filter nor
`scripts/classify-gate.sh`'s rule (1b), so a change to the shared `checkout-executorch` composite
action currently gets no gate at all. Unrelated to ccache, but it is adjacent and should be its own
issue.
