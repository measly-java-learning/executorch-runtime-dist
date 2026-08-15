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

Across the three green runs measured so far:

| run | `full-build` | `full-aot` | wall clock |
|---|---|---|---|
| 31909631718 | 1080s | 1297s | 1369s |
| 31910447973 | 803s | 1250s | 1326s |
| 31910949775 | 832s | 1276s | 1358s |

`full-aot` is the critical path in **every** run, and `full-build` has never come within 170s of
it. Two consequences that drive the implementation order:

1. **Caching `full-build` alone buys zero wall clock.** It only makes an already-idle job idler.
   Any measurement that reports a `full-build` speedup as a *gate* speedup is measuring the wrong
   thing.
2. Therefore: **wire `full-aot` first and measure it alone.** `full-build`'s cache is worth having
   only to keep it off the critical path once `full-aot` shrinks — a question that cannot be
   answered until we know how far `full-aot` actually falls, and one that costs a share of the
   10GB cache budget to answer wrongly.

Note also that `full-build` has ranged 803–1080s across three runs — **±30% runner variance** on an
unchanged build. Any single-run ccache measurement smaller than that is noise. Conclusions need
either a repeated run or a difference large enough to clear that band.

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
key:  ccache-<job>-<arch>-et<etver>-<hashFiles(patches/*, scripts/lib/*, build-runtime.sh)>-<sha>
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

## Known risks

1. **Cache budget thrash.** Two caches × up to 2GB × every open PR, LRU across a 10GB repo limit.
   With several concurrent PRs this could evict caches faster than they are reused, giving cost
   without benefit. The real per-cache size is unknown until the first run; it may argue for a cap
   below 2GB. **Revisit after the first measurement.**
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
