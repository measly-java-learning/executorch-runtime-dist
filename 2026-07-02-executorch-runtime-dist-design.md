# ExecuTorch Runtime Distribution (`executorch-runtime-dist`) — Design & Hand-off

> **What this is:** a cold-start hand-off spec for a **new agent** implementing
> `measly-java-learning/executorch-runtime-dist` (referred to here as **Repo A**). It assumes no
> prior context. Three delineated parts:
> 1. **Repo A implementation spec** — what to build.
> 2. **The Contract (C1–C9)** — the interface the engine (**Repo B**) depends on; treat as frozen.
> 3. **The Repo B Impact Map** — which engine touch-point each contract point drives, with a
>    Contract Deltas log for anything you're *forced* to change.
>
> **Receiving agent:** plan and implement Part 1 yourself (run your own writing-plans pass). This
> document is your input, not your plan. Treat Part 2 as fixed; if implementation forces a change,
> follow the drift rule in Part 3 — that is the *only* thing that flows back to Repo B.

---

## Background (why Repo A exists)

An out-of-tree DJL engine (Repo B, in a personal namespace — **out of scope to move**) loads a
custom JNI shim (`libexecutorch_djl.so`) that statically links an **ExecuTorch runtime**. Producing
that runtime is a heavy, ~10-minute build: it runs in a `manylinux_2_28` container, downloads
`torch==2.12.0` (whose wheel sets a **glibc ≥ 2.28** floor), and compiles ExecuTorch from source.
It changes rarely — only on an ET version bump or a build-flag change.

Repo A extracts that build so it runs **once per ET version**, publishing the resulting `et-install`
tree as versioned, hash-pinned, attested GitHub Release tarballs. Repo B then **downloads** the
runtime instead of building it, cutting the ET compile out of the engine's CI entirely.

**Supply-chain posture (non-negotiable):** Repo B deliberately never commits native binaries. Repo A
must therefore be the **sole, auditable builder** — every artifact SHA-256-pinned *and* accompanied
by a GitHub build-provenance attestation, so "my CI built this from this commit" is *verifiable*, not
promised.

---

# Part 1 — Repo A implementation spec

## Scope

**In:** build the ET runtime from source in `manylinux_2_28`, for three variants
(`bare`/`logging`/`devtools`) on one platform (`linux-x86_64`); package each as a **relocatable**
`et-install` tarball + `.sha256` + `BUILDINFO`; on a manual version tag, run a CI matrix that builds,
attests, and publishes a GitHub Release and emits a ready-to-paste `EtRuntimePin.cmake` snippet.

**Out:** the engine consumption side (Repo B); model-export tooling; multi-platform builds (design
the *naming* to scale, but only `linux-x86_64` is built now); **PR / non-tag CI builds** — the only
CI trigger is a manual version-tag push (C9), so do not build a PR or `push`-to-branch pipeline (a
lightweight shellcheck/lint on PRs is fine, but no ET compile off-tag).

## The build recipe (migrated verbatim from the engine's Stage A)

Repo A owns the canonical recipe. It is exactly what the engine's `build.sh` Stage A does today, plus
the `ET_VARIANT` flag map. Reproduce faithfully:

**Environment:** `quay.io/pypa/manylinux_2_28_x86_64` (AlmaLinux 8; gcc-toolset-14). Use cp312:
`export PATH=/opt/python/cp312-cp312/bin:$PATH`.

**Target ET version:** `v1.3.1` is the **confirmed first target**, paired with `torch==2.12.0+cpu`.
It is `build-runtime.sh`'s default `--et-tag` (see C8). Later ET bumps re-parameterize this value; the
rest of the recipe is version-agnostic.

**ExecuTorch source — caller-provided (not cloned by the recipe).** `build-runtime.sh` does **not**
fetch source; the **caller supplies a checked-out ET tree** (with submodules) and passes its path via
`--et-src <dir>`. This mirrors the caller-owned container boundary: CI uses `actions/checkout`
(`repository: pytorch/executorch`, `ref: v1.3.1`, `submodules: recursive`); local dev mounts an
existing checkout; Repo B's fallback checks out ET then invokes. Submodules are **required** — the ET
build links in-tree third-party (flatcc, XNNPACK, etc.). Do **not** rely on `install_requirements.sh`;
the working recipe installs deps directly (below). The release's ET version label comes from `--et-tag`
(default `v1.3.1`, used for asset naming C1 / `BUILDINFO` C5); `et_commit` is read from the provided
tree via `git -C <et-src> rev-parse HEAD`.

**Python deps (in the container):**
```bash
pip install ninja
pip install -U pip setuptools wheel pyyaml
pip install torch==2.12.0+cpu --index-url https://download.pytorch.org/whl/cpu
```

**Variant flag map** (`ET_VARIANT` → cmake flags):

| variant | flags |
|---|---|
| `bare`     | `-DEXECUTORCH_ENABLE_LOGGING=OFF` |
| `logging`  | `-DEXECUTORCH_ENABLE_LOGGING=ON` |
| `devtools` | `-DEXECUTORCH_ENABLE_LOGGING=OFF -DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON` |

**Configure / build / install:**
```bash
cmake -B "${ET_BUILD}" -S "${ET_SRC}" -G Ninja --preset linux \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  "${ET_VARIANT_FLAGS[@]}" \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
cmake --build "${ET_BUILD}" -j"$(nproc)"
cmake --install "${ET_BUILD}" --prefix "${PREFIX}"   # emits lib/cmake/ExecuTorch/executorch-config.cmake
```

> **PIC is load-bearing (not incidental):** ET's `--preset linux` produces **non-PIC** binaries by
> default. `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` is the whole reason this repo exists — it's what
> makes the static libs linkable into the JNI **shared** object (`libexecutorch_djl.so`). Do not drop
> it. Note that in-tree third-party deps (XNNPACK, flatcc) may not honor the global PIC flag; the
> acceptance gate (below) is what actually proves the output is position-independent.

> **devtools flag risk (RESOLVED 2026-07-02):** the `devtools` combo (`EXECUTORCH_BUILD_DEVTOOLS=ON` +
> `EXECUTORCH_ENABLE_EVENT_TRACER=ON`) was exercised against real ET 1.3.1 and **builds clean with no
> extra flags** — SMOKE PASS + relocatability/PIC GATE PASS, with `libetdump.a`, `libflatccrt.a`,
> `libbundled_program.a` installed and no build-tree paths leaked. Key reason: the ET install-destination
> patch (`${CMAKE_BINARY_DIR}/lib` → `${CMAKE_INSTALL_LIBDIR}`) that `build-runtime.sh` applies also
> covers `etdump`/`bundled_program`/`flatccrt`, so their archives land in the prefix and the exported
> config stays relocatable. No devtools-specific recipe changes were needed.

### Single recipe entrypoint (used by BOTH CI and Repo B)

Factor the recipe into **`build-runtime.sh`** so CI and Repo B's from-source fallback call the *same*
code (this is what guarantees a local from-source runtime matches the released one):

```
./build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> --et-src <et-checkout> [--et-tag <label>] [--build-dir <dir>]
```

- Produces a **relocatable** `et-install` at `<install-dir>` (see next section).
- **Container boundary — caller-owned.** `build-runtime.sh` **assumes it is already running inside
  `manylinux_2_28`**; it does *not* pull or spawn a container. Each caller is responsible for the
  boundary: CI supplies it via the workflow `container:` key; Repo B's from-source fallback enters
  the container before invoking. This keeps the script a single, portable recipe with no dependency
  on a host container runtime.
- **Source boundary — caller-owned (`--et-src`, required).** The recipe does **not** clone; the caller
  supplies a checked-out ET tree with submodules (CI via `actions/checkout`; local dev via a mounted
  checkout; Repo B via its own checkout). Symmetric with the container boundary above.
- **Build reuse — `SKIP_ET_BUILD=1` (mirrors the engine's Stage A knob).** Default is to build. When
  the env var `SKIP_ET_BUILD=1` is set, the recipe **skips the entire slow Stage A** (torch deps +
  configure + compile + install) and **reuses the existing `--prefix` install**, after a hard guard
  that `--prefix/lib/cmake/ExecuTorch/executorch-config.cmake` exists (fail-fast otherwise). This is
  the same explicit opt-in the engine's `native/build.sh` uses — keyed off the **install prefix**, not
  the source tree, and it writes **no marker into `--prefix`** (so the C2 tarball is unaffected). On a
  fresh CI checkout the flag is unset and it always builds; a developer iterating locally sets it to
  reuse a prior install and skip the ~10-minute compile.
- **Build tree — consistent & inspectable (`--build-dir`).** The CMake build tree defaults to
  `<dirname of --prefix>/et-build-<variant>` (overridable via `--build-dir`), so when `--prefix` is on
  a mounted volume the build tree lands there too and its **artifacts can be inspected out of the
  container**. It is **persisted** (not a `mktemp`, not auto-deleted): retained objects also make a
  non-`SKIP` re-run incremental via ninja. (`SKIP_ET_BUILD` remains the explicit reuse-the-install
  path; the persistent build tree is complementary.)
- Non-zero exit on any failure.
- `--et-tag` is the **version label** (default `v1.3.1`) used for asset naming (C1) and `BUILDINFO`
  (C5); `et_commit` is read from the provided checkout (`git -C <et-src> rev-parse HEAD`).

This entrypoint's name, flags, and prefix semantics are **contract point C8** — Repo B invokes it.

## Known unknowns (budget planning time for these)

Resolved before hand-off: ET **does** expose `--preset linux` (confirmed); it is simply non-PIC by
default, which the load-bearing `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` addresses. Both remaining
unknowns are now **RESOLVED** (2026-07-02) during implementation:

1. **`devtools` flag set vs real ET 1.3.x — RESOLVED.** `DEVTOOLS=ON` + `EVENT_TRACER=ON` builds clean
   against real ET 1.3.1 with no extra flags (SMOKE + relocatability/PIC GATE PASS; etdump/flatccrt/
   bundled_program installed, no leak). The install-destination patch is what makes it relocatable.
2. **cmake-config relocatability — RESOLVED.** ET's generated configs are relocatable **except** for an
   upstream install bug (four `CMakeLists.txt` installed to `${CMAKE_BINARY_DIR}/lib`, baking an absolute
   build-tree path and dropping the `.a` from the prefix). `build-runtime.sh` patches those four before
   configure; after that, no absolute build/prefix paths remain and the gate passes. (Reported upstream —
   `spike/upstream-bug-report.md`.) The post-install `${PACKAGE_PREFIX_DIR}` rewrite is kept as
   belt-and-suspenders but is currently a no-op.

## Relocatability — the FIRST milestone, gates everything

A tarball is worthless if `find_package(executorch)` breaks when extracted to a path other than the
build machine's `CMAKE_INSTALL_PREFIX`. CMake package configs sometimes bake **absolute** paths into
`lib/cmake/ExecuTorch/*.cmake` (`IMPORTED_LOCATION`, `INTERFACE_INCLUDE_DIRECTORIES`).

**Step 1 — measure.** After a `logging` install, grep the generated configs for the absolute prefix:
```bash
grep -rn "${PREFIX}" "${PREFIX}/lib/cmake/"    # any hit = non-relocatable
```
Relocatable configs derive paths from `${CMAKE_CURRENT_LIST_DIR}` / `${PACKAGE_PREFIX_DIR}` and show
no absolute build-prefix hits.

**Step 2 — mitigate if needed.** If absolute paths are present, post-process the generated `*.cmake`
in the staging prefix to recompute paths relative to `${CMAKE_CURRENT_LIST_DIR}` before tarring. (Do
not attempt to make the consumer replicate the build prefix — that's the fragile anti-pattern.)

**Step 3 — acceptance gate (required test — proves relocatability AND PIC).** Extract a built tarball
to a **different** directory and prove consumption. Critically, the consumer target must be a
`SHARED` library (a stand-in for `libexecutorch_djl.so`), **not** an executable — an executable links
non-PIC static libs happily, so it would *not* catch a PIC regression, whereas linking a `.so` fails
loudly if any ET (or in-tree third-party) object is non-PIC:
```bash
tar -C /tmp/relotest -xzf executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz
# tiny consumer CMakeLists:
#   find_package(executorch CONFIG REQUIRED PATHS /tmp/relotest/<stem>/lib/cmake/ExecuTorch)
#   add_library(pic_probe SHARED probe.cpp)      # SHARED is the point
#   target_link_libraries(pic_probe PRIVATE <an ET target that pulls in XNNPACK/flatcc>)
# configure + build must succeed
```
This one gate is the go/no-go for the whole approach — it proves the tree is relocatable *and* that
the binaries are genuinely position-independent. Build it early.

## Artifacts

### Tarball layout (C2)
Each tarball contains a **single top-level directory** named after the asset stem:
```
executorch-runtime-<etver>-<variant>-<platform>/
  lib/                   # incl. cmake/ExecuTorch/executorch-config.cmake (relocatable)
  include/
  LICENSE                # ExecuTorch's license (from the ET checkout)
  THIRD-PARTY-NOTICES/   # license/notice files for statically-linked deps (XNNPACK, flatcc, etc.)
  BUILDINFO
```
`LICENSE` and `THIRD-PARTY-NOTICES/` travel with the redistributed compiled binaries so downstream
consumption is license-compliant — this is part of the "safely and responsibly consumed" posture.
So the consumer's `ET_INSTALL` is `<extracted>/executorch-runtime-<etver>-<variant>-<platform>`, and
`executorch-config.cmake` sits at `<ET_INSTALL>/lib/cmake/ExecuTorch/`.

### `BUILDINFO` (C5)
Plain `key=value` lines (human/greppable; not machine-consumed by Repo B):
```
et_version=1.3.1
et_commit=<full sha of the ET checkout>
torch_version=2.12.0+cpu
variant=logging
platform=linux-x86_64
cmake_flags=-DEXECUTORCH_ENABLE_LOGGING=ON ...   # the full effective flag set
toolchain=manylinux_2_28 gcc-toolset-14
build_utc=2026-07-02T00:00:00Z
package_tag=v1.3.1-1
```

### Checksums + attestation (C7)
- `<asset>.sha256` in `sha256sum` format (hash + filename), one per tarball.
- Each tarball gets a GitHub build-provenance attestation via `actions/attest-build-provenance`.
- Verify: `gh attestation verify <tarball> --repo measly-java-learning/executorch-runtime-dist`.

### Pin snippet (C6)
CI's final job emits an `EtRuntimePin.cmake` (a **release asset** and a job-summary block) that Repo B
pastes in wholesale. Flat `set()` variables keyed by `<variant>_<platform>`:
```cmake
# Generated by executorch-runtime-dist release v1.3.1-1. Do not edit by hand.
set(ET_RUNTIME_VERSION "1.3.1-1")
set(ET_RUNTIME_ET_VERSION "1.3.1")

set(ET_RUNTIME_URL_logging_linux-x86_64
  "https://github.com/measly-java-learning/executorch-runtime-dist/releases/download/v1.3.1-1/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz")
set(ET_RUNTIME_SHA256_logging_linux-x86_64 "<sha256>")
# ...bare and devtools rows, same shape...
```

## CI / release pipeline

- **Trigger:** push of tag `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`) — **manual**, you decide when to
  support a new ET. (C9)
- **Build matrix:** `variant ∈ {bare, logging, devtools}` × `platform ∈ {linux-x86_64}`. Each job
  declares the `container:` key (`quay.io/pypa/manylinux_2_28_x86_64`) so the job body already runs
  inside manylinux, **checks out `pytorch/executorch`** (`actions/checkout` with `repository:
  pytorch/executorch`, `ref: <et-tag>`, `submodules: recursive`), then calls `build-runtime.sh
  --variant <v> --prefix <stage> --et-src <et-checkout>` (the script owns neither the container nor
  the source — see C8).
- **Per job:** build → assemble the C2 tarball → `sha256sum` → `attest-build-provenance`.
- **Aggregate job:** create/update the GitHub Release for the tag; upload all tarballs + `.sha256`;
  generate and attach the `EtRuntimePin.cmake` snippet (C6) covering every `(variant, platform)`.
- Permissions: the attestation action needs `id-token: write` and `attestations: write`.

## Repo A file structure

- `build-runtime.sh` — the recipe entrypoint (C8); the migrated Stage A + variant map. Takes a
  caller-provided `--et-src` checkout (does not clone); `SKIP_ET_BUILD=1` reuses an existing
  `--prefix` install instead of rebuilding.
- `scripts/` — package a prefix into the C2 tarball (including collecting `LICENSE` +
  `THIRD-PARTY-NOTICES/` from the ET checkout); emit `BUILDINFO`; generate `EtRuntimePin.cmake`.
- `.github/workflows/release.yml` — the matrix build + attest + publish + pin emission.
- `test/relocatability.sh` — the extract-elsewhere + `find_package` gate.
- `README.md` — what the repo is, how to cut a release, how to verify an artifact.

## Testing / acceptance

**Local validation loop.** The dev machine has docker (29.6.1), `gh`, `cmake`, `ninja`, and an existing
ET `v1.3.1` checkout at `/home/corey/workspace/executorch`, so the entire build + gate can be exercised
locally without CI by mounting **both** the repo and the ET checkout into the manylinux container — the
same two caller-owned boundaries CI uses (`container:` + `actions/checkout`):
```bash
docker run --rm -v "$PWD":/work -v /home/corey/workspace/executorch:/executorch \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; ./build-runtime.sh --variant logging --prefix /work/out --et-src /executorch'
```
The mounted checkout stands in for `actions/checkout`; re-runs can set `SKIP_ET_BUILD=1` to reuse the
existing `/work/out` install and skip the ~10-minute compile.
The relocatability/PIC gate (`test/relocatability.sh`) runs the same way against the produced prefix.

1. **Relocatability + PIC gate** (above) — extract-elsewhere + `find_package` + link into a **SHARED**
   library, on `logging`. Go/no-go for the whole approach.
2. **`build-runtime.sh` local dry run** for one variant (via the docker loop above) → a usable prefix.
3. **CI dry run on a pre-release tag** → all six assets (3 tarballs + 3 sha256) + attestations, and a
   valid `EtRuntimePin.cmake`; `gh attestation verify` passes on each tarball.

---

# Part 2 — The Contract (C1–C9)

> This block is the interface Repo B depends on. **Frozen.** If implementation forces a change,
> apply the drift rule in Part 3. Written to be liftable into a standalone `et-runtime-contract.md`
> if it ever needs to graduate.

- **C1 — Asset names:** `executorch-runtime-<etver>-<variant>-<platform>.tar.gz`, plus a sibling
  `<asset>.sha256`.
- **C2 — Tarball layout:** one top-level dir `executorch-runtime-<etver>-<variant>-<platform>/`
  containing `lib/` (with `cmake/ExecuTorch/executorch-config.cmake`), `include/`, `LICENSE`,
  `THIRD-PARTY-NOTICES/`, and `BUILDINFO`. The tree is **relocatable** (no absolute build-prefix
  paths in any `*.cmake`) and the `lib/` binaries are **position-independent** (linkable into a `.so`).
- **C3 — Variants:** `bare` (LOGGING=OFF), `logging` (LOGGING=ON), `devtools` (LOGGING=OFF +
  DEVTOOLS=ON + EVENT_TRACER=ON). **`logging` is the engine's ship default.**
- **C4 — Platforms:** `linux-x86_64` (glibc ≥ 2.28 floor). The `<platform>` token scales to future
  targets.
- **C5 — `BUILDINFO`:** `key=value` lines with keys `et_version, et_commit, torch_version, variant,
  platform, cmake_flags, toolchain, build_utc, package_tag`.
- **C6 — `EtRuntimePin.cmake`:** flat cmake `set()`s: `ET_RUNTIME_VERSION`, `ET_RUNTIME_ET_VERSION`,
  and per row `ET_RUNTIME_URL_<variant>_<platform>` + `ET_RUNTIME_SHA256_<variant>_<platform>`.
- **C7 — Integrity/provenance:** `<asset>.sha256` (sha256sum format); GitHub build-provenance
  attestation per tarball; `gh attestation verify <tarball> --repo measly-java-learning/executorch-runtime-dist`.
- **C8 — From-source entrypoint:** `build-runtime.sh --variant <v> --prefix <dir> --et-src <et-checkout>
  [--et-tag <label>] [--build-dir <dir>]` → relocatable `et-install` at `<dir>`; non-zero on failure.
  `--build-dir` (default `<dirname of --prefix>/et-build-<variant>`) is a persisted, inspectable CMake
  build tree. **Two caller-owned
  boundaries:** (1) the script **must be invoked inside** `manylinux_2_28` (container boundary), and
  (2) the caller **provides the ExecuTorch source** as a checked-out tree with submodules via
  `--et-src` — the recipe does **not** clone (source boundary). CI supplies both (the `container:` key
  + `actions/checkout` of `pytorch/executorch`); Repo B's fallback enters the container and checks out
  ET before calling. `--et-tag` is the **version label** (default `v1.3.1`) for naming/`BUILDINFO`;
  `et_commit` is read from the checkout. Optional env knob **`SKIP_ET_BUILD=1`** skips the slow Stage A
  and reuses the existing `--prefix` install (guarded by `executorch-config.cmake` presence), mirroring
  the engine's flag; nothing extra is written into `--prefix`. Repo B clones Repo A at tag
  `v<etver>-<pkgrev>` (C9) to invoke it.
- **C9 — Release tag:** `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`); `pkgrev` increments for re-rolls of the
  same ET version.

---

# Part 3 — Repo B Impact Map

> **Drift rule (for the Repo A agent):** the Contract is frozen. If you are *forced* to change a
> `Cn`, do two things: (1) append a **Contract Delta** entry below; (2) mark that row's Impact
> column with `⚠`. The set of `⚠` rows is the complete, targeted punch-list for Repo B — nothing
> else in Repo B can be affected by your work.

### Contract Deltas (append-only; empty at hand-off)

- **2026-07-02 — C8 reshaped: caller-owned source (`--et-src`, no clone) + build reuse.** The original
  C8 had `build-runtime.sh` clone ExecuTorch itself. That is inconsistent with how the recipe actually
  lands: in CI the source arrives via `actions/checkout`, and Repo B's fallback likewise checks out ET.
  Revised so the caller **provides** the source tree via a required `--et-src <dir>` (symmetric with the
  already-caller-owned container boundary); the recipe no longer clones. `--et-tag` becomes the version
  **label** (default `v1.3.1`) for naming/`BUILDINFO`; `et_commit` is read from the checkout. For speed,
  an optional env knob **`SKIP_ET_BUILD=1`** (mirroring the engine's `native/build.sh` Stage A flag)
  skips the whole slow build and **reuses the existing `--prefix` install**, guarded by a check that
  `executorch-config.cmake` is present. The earlier `--force`/`.et_build_meta` idea is **withdrawn** —
  reuse is an explicit opt-in keyed to the **install prefix** (not the source, not a marker), so
  nothing extra is written into `--prefix` and **C2 is unaffected**.
  **Repo B impact (⚠ C8):** its from-source fallback must now `actions/checkout` (or `git clone
  --recursive`) ExecuTorch and pass `--et-src`, rather than relying on the recipe to fetch it.

### Map: Contract point → Repo B touch-point

| C# | Repo B artifact it drives | Status |
|----|---------------------------|--------|
| C1 | `EtRuntimePin.cmake` URL/filename construction; `native/build_variants.sh` download filenames | ok |
| C2 | `native/CMakeLists.txt`: `ET_INSTALL` derived as `<fetched>/executorch-runtime-<etver>-<variant>-<platform>`; `find_package` PATHS. Added `LICENSE`/`THIRD-PARTY-NOTICES/` are informational (no functional consumer) — **no `⚠`**. | ok |
| C3 | `EtRuntimePin.cmake` rows; `build_variants.sh` variant list; `docs/benchmarking.md` variant meaning | ok |
| C4 | `EtRuntimePin.cmake` platform key; engine platform detection (currently `linux-x86_64` only) | ok |
| C5 | Informational only — no functional consumer (engine may log it). Low. | ok |
| C6 | `native/CMakeLists.txt`: `include(EtRuntimePin.cmake)` + read `ET_RUNTIME_*` vars + `FetchContent(URL, URL_HASH SHA256=…)`. **Primary consumer.** | ok |
| C7 | `FetchContent` `URL_HASH` uses the SHA; optional engine-CI step running `gh attestation verify` before use | ok |
| C8 | `native/build.sh` from-source fallback: clone Repo A at the pinned tag, **enter `manylinux_2_28`** (container boundary), **check out `pytorch/executorch` with submodules**, then invoke `build-runtime.sh --variant logging --prefix <tmp> --et-src <et-checkout>` | ⚠ (2026-07-02 delta: source is now caller-provided via `--et-src`; the recipe no longer clones — the fallback must check out ET itself) |
| C9 | Engine from-source fallback clone tag; `EtRuntimePin.cmake` version comment | ok |

### Repo B work these imply (for the later Repo B spec — NOT this agent's job)

The engine's ET-runtime resolution becomes 3-way in `native/CMakeLists.txt` / `build.sh`:
1. `ET_INSTALL` provided → use it (unchanged escape hatch).
2. build-from-source toggle → clone Repo A @ pinned tag, run `build-runtime.sh` **inside `manylinux_2_28`** (C8), point `ET_INSTALL` at it.
3. default → `FetchContent` the pinned `logging`/`linux-x86_64` tarball with `URL_HASH` (C1/C2/C6).
Plus: `build.sh` **drops Stage A** (recipe now lives in Repo A); `build_variants.sh` **downloads** the
three variant tarballs instead of building them.

---

## Hand-off checklist for the receiving agent

- [ ] Read Part 1; run your own writing-plans pass to produce Repo A's implementation plan.
- [ ] Prove the **relocatability + PIC gate** before anything else — it can invalidate C2.
- [ ] Keep Part 2 frozen; log any forced change as a Contract Delta + `⚠` the mapped row.
- [ ] On completion, the `⚠` rows (if any) + the Deltas log are what returns to the engine repo.
