# LSTM XnnLinearCache USDT tracepoints — design

**Date:** 2026-07-13
**Status:** Approved (design); implementation not started
**Scope:** Add Linux USDT (userland statically-defined tracing) probes to the
`XnnLinearCache` LRU in the bundled LSTM custom op, so operators can observe cache
behavior at runtime without a heavyweight telemetry library.

## Motivation

`extras/lstm/runtime/xnn_linear_cache.h` packs XNNPACK fully-connected operators keyed
by weight identity, capped at a fixed `kMaxEntries = 16`. The cap is a guess. A consumer
running real workloads currently has no way to see whether 16 is right: the cache is a
process-global static with `hits`/`misses`/`size` counters that are never surfaced.

The concrete question a user needs to answer is **"is a cache size of 16 enough for my
workload?"** The signals that answer it are hit rate, miss rate, eviction pressure,
occupancy, and — when evicting — *which* entry got evicted and how stale it was.

USDT is the right mechanism because `<sys/sdt.h>` is header-only: each probe compiles to
a single `nop` plus a non-allocated `.note.stapsdt` ELF note. There is **no linked runtime
library and zero cost when untraced** — the opposite of LTTng-UST or a metrics library.
Only trace-*time* users (bpftrace/perf) need tooling, on their own machines.

## Key decisions (locked)

1. **Audience / contract.** USDT is the durable answer to cache observability. The
   **provider name and probe names are a committed, stable contract**; the **argument set
   is documented but best-effort** (may gain trailing args). Renaming a probe is a breaking
   change; appending an arg to `__evict` is not.
2. **Probe shape (B):** three separately-named probes — `__hit`, `__miss`, `__evict` — sharing
   a common 4-arg prefix, with `__evict` appending victim detail. Separate names are the
   idiomatic bpftrace surface and make the committed contract explicit (vs. an integer
   `event` arg that would itself be an undocumented sub-contract).
3. **No is-enabled semaphores.** All args are already cheap to compute, so plain
   `DTRACE_PROBEn` (nop + note) is used — this keeps the build free of a writable `.probes`
   variable and its PIC-addressing wrinkles, preserving the "zero linked dependency" property.
4. **Gating:** a mandatory platform gate (`__linux__`) plus an opt-out CMake option
   `ETNP_ENABLE_USDT`, **default ON on Linux, forced OFF elsewhere**. Applied to **all three
   variants** (`bare`/`logging`/`devtools`) — the notes are non-alloc and free when untraced,
   so uniform observability beats a marginal `bare` size win.
5. **`sys/sdt.h` sourcing:** installed at build time via `systemtap-sdt-devel` in the
   manylinux container. **Not vendored** (avoids owning a header that can drift from the
   systemtap the tracing tools expect).
6. **Provenance:** the effective USDT state is recorded in `BUILDINFO` (`usdt=on|off`), so a
   released artifact self-declares whether it carries probes.

## The probe contract

Provider: **`etnp`**. Probe base name: **`lstm_xnn_cache`**. Fired from
`XnnLinearCache::get()` in `xnn_linear_cache.h`.

All channel/occupancy/capacity args are passed as fixed-width `uint32_t` and `evicted_age`
as `uint64_t` — the `.note.stapsdt` note records each arg's byte size, so widths are pinned
explicitly rather than shipping an implicit `size_t` that could drift on a future 32-bit target.

| Probe | Macro | Args (in order) |
|-------|-------|-----------------|
| `etnp:lstm_xnn_cache__hit`   | `DTRACE_PROBE4` | `u32 in_ch, u32 out_ch, u32 occupancy, u32 capacity` |
| `etnp:lstm_xnn_cache__miss`  | `DTRACE_PROBE4` | `u32 in_ch, u32 out_ch, u32 occupancy, u32 capacity` |
| `etnp:lstm_xnn_cache__evict` | `DTRACE_PROBE7` | `u32 in_ch, u32 out_ch, u32 occupancy, u32 capacity, u32 evicted_in_ch, u32 evicted_out_ch, u64 evicted_age` |

**Argument semantics** (the documented, best-effort part of the contract):

- `in_ch`, `out_ch` — the FC dimensions of the key for **the current operation** (on
  `__evict`, the *incoming* key whose insertion triggered the eviction).
- `occupancy` — `map.size()` **read after the mutation** for that event. On `__hit` it is
  the stable steady-state occupancy; on `__miss` during warm-up it traces the fill
  trajectory (`k → k+1`). On `__evict` it is definitionally `== capacity` (eviction only
  happens at the cap) — it is retained in the common prefix for handler uniformity, and its
  redundancy on `__evict` is expected.
- `capacity` — the compile-time cap (`kMaxEntries`, currently 16). Passed so scripts are
  self-describing (`occupancy/capacity`) and survive a future cap change without edits.
- `evicted_in_ch`, `evicted_out_ch` — FC dimensions of the **victim** (the LRU entry removed).
- `evicted_age` — **LRU tick delta**: `s.tick - victim.stamp`, i.e. the number of cache
  operations that elapsed since the victim was last touched (≥ 1). A large delta means the
  victim was genuinely cold (working set fits); a small delta means churn/thrash.

**The diagnostic:** `__evict` firing frequently while `occupancy == capacity`, especially
with small `evicted_age` and subsequent `__miss` on recently-evicted `(in_ch,out_ch)` pairs,
is the unambiguous "16 is too small for this workload" signal.

### Fire points in `get()`

- `__hit`: in the fingerprint-match branch, after `++s.hits; stamp = ++s.tick`.
- `__miss`: **only after a successful repack + `emplace`** (occupancy read post-insert). If
  `XnnLinear::create` fails and `get` returns `nullptr`, no probe fires — no state changed.
  Note: `++s.misses` runs *before* the create attempt, so `__miss` events equal `s.misses`
  **except** on the rare XNNPACK create-failure path (which increments `s.misses`, returns
  `nullptr`, and fires nothing). This is documented so a consumer counting `__miss` events
  understands it counts successful (re)packs, not lookup-misses.
- `__evict`: inside the `map.size() >= kMaxEntries` block, after selecting `oldest`, reading
  the victim's key/stamp before `erase`.

## Components & integration

### 1. Probe macro header — `extras/lstm/runtime/etnp_usdt.h` (new)

A small header providing the enable gate and the three LSTM-cache probe macros:

- When `defined(ETNP_USDT_ENABLED) && __linux__`: `#include <sys/sdt.h>` and define
  `ETNP_LSTM_CACHE_PROBE_HIT/_MISS/_EVICT(...)` to the corresponding `DTRACE_PROBE4/4/7`.
- Otherwise: each macro expands to `((void)0)`.

Kept LSTM-local (not a shared `extras/` abstraction) per the repo's "glob now, generalize
when op #2 exists" ethos. The generic gate can be lifted later if a second op wants probes.

### 2. `xnn_linear_cache.h` — call sites

`#include "etnp_usdt.h"` and insert the three macro calls at the fire points above. The
cache's existing logic is unchanged; probes only read already-computed values
(`in_ch`, `out_ch`, `s.map.size()`, `kMaxEntries`, the victim key, `s.tick - stamp`).

### 3. `extras/lstm/runtime/CMakeLists.txt` — build wiring

- `option(ETNP_ENABLE_USDT "Emit USDT tracepoints (Linux only)" ON)`.
- Effective enable `= ETNP_ENABLE_USDT AND CMAKE_SYSTEM_NAME STREQUAL "Linux"`.
- When effective: `check_include_file_cxx(sys/sdt.h HAVE_SYS_SDT_H)`; **FATAL_ERROR if
  missing** (a requested-but-unavailable probe header must fail loudly, matching the repo's
  Highway-license "refuse to ship incomplete" stance — never silently ship a probe-less
  artifact when USDT was asked for). Then
  `target_compile_definitions(etnp_ops_lstm PRIVATE ETNP_USDT_ENABLED=1)`.
- Write the provenance marker (see §5).

`ETNP_ENABLE_USDT` is passed to the extras configure by `build-runtime.sh`'s `build_extras`
only if a non-default value is needed; default-ON needs no flag.

### 4. `build-runtime.sh` — provision `sys/sdt.h`

In `build_extras` (covers both the full build and the `--extras-only` gate path), ensure the
SDT header is present before configuring extras: `dnf install -y systemtap-sdt-devel`
(idempotent). Installed **unconditionally** — the CMake option remains the single source of
truth for *emission*; this step only provisions the dependency so that if emission is on, the
header exists. Harmless when a user sets `ETNP_ENABLE_USDT=OFF`.

### 5. Provenance: `BUILDINFO usdt=on|off`

Mirror the existing `.et_commit` build-marker pattern (a prefix file read at package time,
never shipped):

- The extras CMake writes `${CMAKE_INSTALL_PREFIX}/.etnp_usdt` (`on`/`off`) reflecting the
  **effective** option — CMake is the single source of truth for the value.
- `scripts/package.sh` reads `$PREFIX/.etnp_usdt` (fail loudly if absent, like `.et_commit`)
  and passes `USDT=<val>` to `gen-buildinfo.sh`.
- `scripts/gen-buildinfo.sh` gains a required `USDT` var and emits `usdt=$USDT`.
- `.etnp_usdt` is **not** staged into the tarball (it is a build-cache marker, like `.et_commit`).

## Testing

The probe *notes surviving the whole-archive link into a final binary* is the single most
important thing to verify (a static-archive note can silently vanish). This is validated
empirically, and the same check guards the committed name/arity contract.

1. **POST_BUILD note assertion — `cmake/assert_usdt_probes.cmake` (new).** Mirrors the
   existing `assert_extras_registered.cmake` nm-guard. Attached POST_BUILD to
   `etnp_extras_link_probe` (which whole-archives `etnp_ops_lstm`, a faithful proxy for a
   real consumer link). Invoked with `-DSO=<probe binary> -DEXPECT_USDT=<ON|OFF>` (the driver
   passes the effective value). Runs `readelf --notes` and:
   - When `EXPECT_USDT=ON`: asserts a `stapsdt` note with provider `etnp` and all three
     probe names present, and that each carries the expected arg count (4/4/7). A dropped
     note, a rename, or an arity change fails the build.
   - When `EXPECT_USDT=OFF`: asserts **no** `stapsdt`/`etnp` notes (guards the opt-out path).

   `readelf` is in binutils (already relied on for `nm`). This runs on every build — release
   and gate — so it can never regress silently.

2. **Consumer-side check (secondary).** The extras-gate tier1 job already links a torch-free
   consumer binary; optionally assert the `etnp` stapsdt notes are present there too, as a
   real-consumer confirmation beyond the in-tree link probe.

3. **Kernel/behavior unchanged.** Existing `lstm_kernel_test` and round-trip gates must stay
   green — probes are pure `nop`s and read-only, so no functional test changes are expected;
   their continued passing is the regression guard for "probes didn't perturb the kernel."

4. **Live bpftrace verification — manual, documented, out of CI.** Attaching bpftrace/perf
   needs BPF/root privileges most CI runners lack, so a live smoke is **not** a CI gate. The
   consumer doc ships a copy-paste bpftrace recipe for manual verification.

The hermetic `test/*.test.sh` suite is pure-shell (no build), so the readelf assertion lives
as a POST_BUILD/gate step rather than in `test/run.sh`. `test/buildinfo.test.sh` is updated
for the new `usdt=` field.

## Documentation

- **`docs/lstm-xnn-cache-usdt.md` (new)** — the consumer-facing probe contract (provider,
  probe names, arg layout + widths + semantics, stability guarantee) plus bpftrace one-liners
  that answer "is 16 enough": hit-rate, eviction-rate, occupancy histogram, and
  `evicted_age` distribution. This is the deliverable that makes the feature usable.
- **`README.md`** — brief mention under the variants/consuming sections that Linux tarballs
  carry `etnp` USDT probes, linking to the doc.
- **`CLAUDE.md`** — note the probe-name contract alongside the other committed contracts
  (C1 naming, C2 tarball, C3 variants).

## Explicit non-goals (YAGNI)

- No is-enabled semaphores.
- No macOS/Windows tracing (probes compile out; ETW/dtrace equivalents are future work).
- No generic per-op probe framework — LSTM-local until a second op needs it.
- No live bpftrace assertion in CI.
- No configurable `kMaxEntries` — the probes *inform* a future decision to change it; changing
  it is out of scope here (though `capacity` is exposed so scripts survive such a change).

## Risk / considerations addressed

- **Note survival through static-archive → consumer link** — the load-bearing unknown;
  validated by the POST_BUILD readelf assertion on the whole-archive link probe (§Testing 1).
- **Committed-contract drift** — the same assertion pins provider/probe names + arities.
- **Build dependency** — `systemtap-sdt-devel` is build-time only; consumers/tarball carry
  only the notes. FATAL_ERROR if the header is missing when USDT is requested.
- **PIC** — semaphore-less probes are PC-relative and PIC-safe.
- **Provenance** — `BUILDINFO usdt=` self-declares the shipped state.
