# Custom-Code (extras) QA Gate — Design

**Date:** 2026-07-11
**Status:** Accepted (design); ready for a writing-plans pass.
**Related:**
[LSTM op delivery strategy](../../lstm-op-delivery-strategy.md) (Decision 2 — the
torch-free consumer smoke test this gate reuses),
[upstream productionization plan](../plans/2026-07-10-lstm-op-upstream-productionization.md),
[release.yml](../../../.github/workflows/release.yml).

## Problem

The repo builds a relocatable ExecuTorch runtime and, since the LSTM op landed in
`extras/`, ships **first-party custom code** on top of it. Today CI fires **only on
release tags** (`v*-*`): there is no PR/branch gate for the custom code. The only
existing correctness check for the op — the live torch round-trip — lives inside the
release build, behind the **~10–15 min ExecuTorch compile**. So the custom code
cannot be QA'd on a PR without paying for a full runtime build.

We want a **PR gate for the custom code that avoids the full ET compile**, while
staying honest about what it can and cannot prove, and without undermining the repo's
supply-chain posture (no unverified native binaries).

## Key architectural facts this design leans on

- `build-runtime.sh` runs in **two phases**: (1) the slow ET compile → install to
  `$PREFIX`; (2) a **fast extras phase** that compiles the custom kernel against the
  *already-installed* prefix, runs the kernel unit test + link-probe/nm registration
  guard, and installs `etnp_ops_lstm` + `ETNPExtras.cmake` into the prefix.
- `SKIP_ET_BUILD=1` **skips phase 1 and reuses an existing `--prefix`** (guarded by
  `executorch-config.cmake` presence). This is the seam the gate exploits.
- A **published release tarball IS a prebuilt phase-1 prefix** — relocatable, PIC,
  attested. The gate downloads one instead of compiling ET.
- The live round-trip has two halves: an **AOT half** (torch + executorch-python:
  `nn.LSTM → export → lower → .pte`, plus input + eager golden) and a **runtime half**
  (torch-free: build `lstm_runner`, run the `.pte`, compare). Publishing the `.pte` +
  golden lets the gate run only the torch-free runtime half.
- On a branch (no release tag) the target ET version is pinned by
  `DEFAULT_ET_TAG="v1.3.1"` in `build-runtime.sh` — the branch's own source of truth.
  The matching package release is the newest `v<etver>-*` GitHub release.

## Coverage model (what moves where)

A **frozen, published `.pte`** freezes the AOT side, so it cannot catch AOT↔runtime
drift (op-name/schema mismatch — the strategy doc's "nastiest failure"). Coverage
therefore splits deliberately:

- **Fast PR gate (frozen `.pte`, torch-free):** catches **runtime-kernel** regressions
  — numerics, static registration, whole-archive linkage. This is what most extras PRs
  touch. Runs on both arches.
- **Release / full build (torch present):** keeps the **live** round-trip (re-derives
  the `.pte` from current AOT source → the only place drift is caught) **and**
  regenerates + publishes the fixtures the fast gate consumes.

The one class the fast gate cannot cover — a change to the AOT op definition/schema —
is handled by a **path trigger** that escalates to the live round-trip.

## Design

### 1. Trigger — a new path-filtered PR workflow

New `.github/workflows/extras-gate.yml`. Net-new PR CI (the release workflow is
untouched except for fixture publishing, §3). Three behaviors, selected by what the PR
changed:

| PR touches | Gate runs | Cost |
|---|---|---|
| Kernel / runtime / test only (`extras/**`, **not** `aot/`; ET pin unchanged) | **Tier 1** only | cheap — no torch, no ET compile |
| AOT def or schema (`extras/**/aot/**`, the schema header/`generate_schema_header.py`) | **Tier 1 + Tier 2** | + torch/export; still no ET compile |
| **Any change to `build-runtime.sh`**, or no matching release exists | **Full-build fallback** | ~15 min — intentional; this is the risky case |

**Why any `build-runtime.sh` edit forces a full build:** the script is on the
release critical path — it owns phase 1 (the ET compile), the ET install-destination
patch, the extras wiring, the Highway license harvest, and the packaging seams. Tier 1
runs `SKIP_ET_BUILD=1` against a *downloaded* prefix, so it structurally cannot exercise
any of that. Rather than try to guess which edits are "safe," treat the whole script as
full-build-worthy. This is deliberately broader than an ET-pin-only trigger.

### 2. Tier 1 — the fast, torch-free gate

Runs **in the manylinux container** (fidelity vs. the shipped static archives), on
**both `linux-x86_64` and `linux-aarch64`**:

1. Resolve `etver` from `DEFAULT_ET_TAG`; find the newest `v<etver>-*` release.
2. Download + `sha256sum -c` + `gh attestation verify` the `logging` tarball **and**
   the fixtures asset (keeps the no-unverified-binaries posture — the gate must not be
   the one place the repo trusts an unattested binary).
3. Extract the tarball as the prefix; **scrub the shipped extras** out of it
   (`libetnp_ops_*.a`, `lib/cmake/ETNPExtras/`) so a stale artifact from the release
   can't produce a false pass on a rename/removal.
4. `SKIP_ET_BUILD=1 build-runtime.sh --prefix <extracted>` → rebuilds extras **from the
   branch**, which already runs the kernel unit test + link-probe/nm registration guard.
5. Build `lstm_runner`, run the published `.pte` against it, compare to golden `out.bin`
   at rtol/atol 1e-4.

A golden mismatch is a **red gate**. If the mismatch is an *intentional* numeric change,
the author re-blesses by regenerating fixtures via the live round-trip (Tier 2 / local),
never by silently loosening the gate.

### 3. Published fixtures — a release-time deliverable

The release `logging` / `linux-x86_64` job already runs the live round-trip. Add a step
that emits the arch-independent fixture set from that **same run** and uploads it as an
**attested** release asset:

- `etnp-lstm-fixtures-<etver>.tar.gz` containing `lstm.pte`, `in.bin`, `out.bin`
  (golden eager output), and a small `shape` file carrying the `T,B,I,H` dims the runner
  needs — plus a sibling `.sha256` and a build-provenance attestation.
- One set covers all platforms (a `.pte` flatbuffer + float32 `in/out.bin` are
  arch-neutral). Running it against both the x86_64 and aarch64 tarballs in Tier 1
  **recovers aarch64 SIMD-parity coverage** cheaply.
- This is the **same `.pte`** the downstream shim's consumer smoke test needs
  (strategy Decision 2) — a required deliverable, not gate-only scope.

**Single source of truth:** fixtures are minted from the *same* code (dims, seed,
weights) as the live round-trip — via a flag on `test_lstm_roundtrip.py` or a tiny
script it shares — so the published `.pte`/golden can never drift from what the live
test would produce.

### 4. Tier 2 — live round-trip without the ET compile

For AOT/schema PRs, run today's live `test_lstm_roundtrip.py`, but point `ETNP_PREFIX`
at the **downloaded tarball prefix** (from Tier 1) instead of a freshly built one. This
still skips the ET compile; it only adds torch + `install_executorch.sh` (which needs an
ET **source** checkout at the pinned `DEFAULT_ET_TAG`). This is the only pre-release
place AOT↔runtime drift is caught.

### 5. Full-build fallback — a release dry-run

Triggered by **any change to `build-runtime.sh`** or the absence of a matching
release. Runs
`build-runtime.sh` for real (full ET compile) + the live round-trip, mirroring the
release build as closely as possible — same invocation, **and it exercises the
fixture-emit step (without publishing)** — so a green PR gate means the eventual release
tag will build and publish. Rationale: catch ET-bump breakage **before** spending a
version suffix (`pkgrev`), not after tagging.

### 6. Usage & troubleshooting documentation (required outcome)

This is an unusual use of CI — a PR gate that downloads a prior release's attested
binary, rebuilds only half the build against it, and branches across three tiers by
path. That is not self-evident from reading the workflow YAML, and a contributor facing
a red gate needs a map. A dedicated contributor-facing doc (`docs/extras-gate.md`,
sibling to `docs/lstm-op-consumer-guide.md`) is a **first-class deliverable of this
work, not an afterthought**, and must cover:

- **Mental model** — the two-phase build, why the ET compile is avoided, and how a
  released tarball serves as a prebuilt phase-1 prefix.
- **"I changed X → which tier runs"** — the trigger table restated for contributors,
  including the deliberately broad `build-runtime.sh` → full-build rule.
- **Reading a result** — what each tier proves; crucially, that a **golden mismatch** is
  either a real kernel regression **or** an intentional numeric change that must be
  **re-blessed** (regenerate + publish fixtures via the live round-trip), never worked
  around by loosening the gate.
- **Reproduce locally** — running each tier on a dev box (the manylinux docker loop
  already used for the build/relocatability gate), including how to point at a downloaded
  tarball prefix.
- **Re-blessing fixtures** — the exact steps to regenerate `lstm.pte`/`in.bin`/`out.bin`/
  `shape` and get them into a release.
- **Troubleshooting runbook** — at minimum: `gh attestation verify` failure; no matching
  release (first release / deleted or renamed asset); stale-extras false pass and the
  scrub step; toolchain/ABI mismatch (why the gate runs in manylinux); aarch64 runner
  quirks.
- **Accepted boundaries** — what a green gate does **not** prove (mirrors the section
  below), so contributors don't over-trust it.

### 7. New / changed files

- **New** `.github/workflows/extras-gate.yml` — the path-filtered 3-way gate
  (Tier 1 / Tier 1+2 / full-build fallback), both arches for Tier 1.
- **New** torch-free consumer harness under `extras/lstm/test/` — reuses `lstm_runner`
  + a small numpy compare over the published `.pte`/`in.bin`/golden `out.bin` (reads
  dims from `shape`). Doubles as the artifact the downstream shim reuses.
- **New** fixture-emit path — a flag on `test_lstm_roundtrip.py` (or a small shared
  script) that writes `lstm.pte`/`in.bin`/`out.bin`/`shape` to an output dir from the
  same source as the live test.
- **Changed** `.github/workflows/release.yml` — package, `sha256`, upload, and attest
  the `etnp-lstm-fixtures-<etver>.tar.gz` from the existing `logging`/`x86_64`
  round-trip step.
- **New** `docs/extras-gate.md` — the usage & troubleshooting guide (§6); a required
  deliverable, not optional polish.

## What this gate does NOT prove (accepted boundaries)

- **AOT↔runtime drift** on a pure-kernel PR: out of scope for Tier 1 by construction
  (frozen `.pte`). Covered by the AOT path trigger (Tier 2) and every release.
- **Release packaging / license harvest / attestation** steps: exercised only by the
  release build and the full-build fallback, not Tier 1.
- **`build-runtime.sh` changes**: always take the full-build fallback — the script is on
  the release critical path and its phase-1/packaging behavior is invisible to Tier 1.
  Accepted cost: a build-recipe edit pays ~15 min on the PR (and cannot be QA'd cheaply).

## Open items

- Exact scrub list in Tier 1 step 3 (confirm every shipped extras artifact path).
- Fixture `shape` file format (flat `key=value` to match `BUILDINFO`, vs. the runner's
  existing `LSTM_*` env-var names).
