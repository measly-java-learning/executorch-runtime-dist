# The extras (custom-code) QA gate

## What it is / why it looks unusual
- The runtime build has two phases: a slow ExecuTorch compile (~10–15 min) that installs
  a prefix, and a fast **extras** phase that compiles the custom LSTM op against that
  prefix. A *released tarball is a prebuilt phase-1 prefix*.
- The PR gate downloads an **attested** release tarball, scrubs the shipped extras out,
  rebuilds extras **from your branch** (`build-runtime.sh --extras-only`), and runs your
  kernel against a **published `.pte` + golden** fixture set — so it never pays the ET
  compile.

## Which tier runs (I changed X → …)
| You changed | Gate | Cost |
|---|---|---|
| kernel / runtime / test under `extras/**` (not `aot/`) | **tier1** — torch-free consumer smoke, both arches | cheap |
| AOT def / schema / fixture source (`extras/**/aot/**` — incl. `lstm_case.py` + `emit_fixtures.py` — `generate_schema_header.py`, `extra.yaml`) | **tier1 + tier2** — adds the live round-trip | + torch/export |
| **`build-runtime.sh`** (any change), or no release exists for the pinned ET | **full** — a full-build release dry-run | ~15 min |

Decision logic lives in `scripts/classify-gate.sh` (unit-tested in `test/classify_gate.test.sh`).

## Reading a result
- **tier1 green:** the branch kernel reproduces the published golden on both arches, and
  the static-registration/whole-archive guard passed.
- **tier1 `consumer smoke MISMATCH`:** either a real kernel regression **or** an
  *intentional* numeric change. Never loosen the tolerance — **re-bless** (below).
- **tier2:** additionally proves AOT↔runtime agreement (the "exports fine / op-not-found
  at runtime" class). Only tier2/full re-derive the `.pte` from your AOT source.
- **full:** a faithful dry-run of the release build; green means the release tag will build.

## Reproduce locally
Use the manylinux docker loop (same two caller-owned boundaries as CI):
```bash
# tier1 mechanics against a local ./prefix (extracted logging tarball) + ./fixtures:
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH; pip install ninja numpy
  rm -f prefix/lib/libetnp_ops_*.a prefix/lib/libhwy.a; rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp
  ./build-runtime.sh --extras-only --variant logging --prefix /work/prefix
  FIXTURES_DIR=/work/fixtures ETNP_PREFIX=/work/prefix python extras/lstm/test/consumer_smoke.py'
```
For the full build / live round-trip, mount an ExecuTorch checkout and run
`build-runtime.sh --variant logging --prefix … --et-src …` then the round-trip (see the
design/handover docs).

## Re-blessing fixtures (intentional numeric or AOT change)
The published `.pte`/golden come from `extras/lstm/aot/lstm_case.py` via
`extras/lstm/aot/emit_fixtures.py`. To change them:
1. Update `lstm_case.py` (and the kernel/AOT as needed).
2. In an env with torch + executorch installed against the pinned ET, run the **live**
   round-trip to confirm agreement: `ETNP_PREFIX=<prefix> pytest extras/lstm/test/test_lstm_roundtrip.py`.
3. Cut a release — the release build re-mints and publishes
   `etnp-lstm-fixtures-<etver>.tar.gz` from the same source. The next PR's tier1 then
   compares against the new golden.

## Troubleshooting
- **`gh attestation verify` on a fork PR:** fork PRs run with a reduced, secret-less read
  token GitHub won't let the workflow elevate, so attestation verify is **skipped on forks**
  (you'll see a `::notice::`) while `sha256sum -c` is enforced in every case. On a
  **same-repo** PR a genuine verify failure means the asset isn't provenance-attested — do
  not proceed; re-cut the release. `gh` runs only in the ubuntu `fetch`/`classify` jobs (it
  is absent from manylinux).
- **`classify` fails with "gh release list failed after 3 attempts":** a transient GitHub
  API/network error while resolving the release (not a build-recipe change). The classifier
  deliberately refuses to mislabel this as a full build — just re-run the job.
- **No matching release / first release:** classify falls back to **full**; expect ~15 min.
- **Stale-extras false pass:** the scrub step removes `lib/libetnp_ops_*.a`, `lib/libhwy.a`,
  `lib/cmake/ETNPExtras/`, `include/etnp/` before the rebuild — if you add op artifacts,
  extend the scrub list.
- **Toolchain/ABI mismatch:** the gate compiles inside manylinux_2_28 on purpose; do not
  run the extras rebuild on the host toolchain.
- **aarch64 runner:** tier1's aarch64 leg uses `ubuntu-24.04-arm` + the aarch64 manylinux
  image; the `.pte`/golden are arch-independent, so the same fixtures drive both arches.

## What a green gate does NOT prove
- AOT↔runtime drift on a **pure-kernel** PR (frozen `.pte`) — covered by the AOT path
  trigger and every release.
- Release packaging / license harvest / attestation — only the release build + full-build
  fallback exercise those.
- ET-version compatibility — an ET bump always takes the full-build fallback.
- A change to **`test_lstm_roundtrip.py` alone** classifies tier1 (a `test/` file that
  defines no fixtures), so the live round-trip is not re-run to validate the edited test
  itself. Low-risk (it is the harness, not shipped source or fixtures) — pair such edits
  with an AOT/kernel change, or run the round-trip locally.
