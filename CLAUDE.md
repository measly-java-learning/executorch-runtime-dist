# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

CI infrastructure that builds **position-independent (`-fPIC`), relocatable desktop
builds of [ExecuTorch](https://github.com/pytorch/executorch)** and publishes them as
attested, hash-pinned tarballs. Upstream ExecuTorch does not build with `-fPIC` by
default, which makes it hard to link into a JVM via JNI; that gap is the reason this
repo exists. This repo produces *artifacts*, not a library — there is almost no
long-lived compiled product here, just a build recipe + packaging + CI + a small set
of first-party custom ops.

Every release builds three variants **on Linux**; Windows ships `logging` only:
- `bare` — logging off (smallest)
- `logging` — logging on (**ship default**)
- `devtools` — devtools + event tracer (profiling/debug)

## Key commands

```bash
# Run the full shell unit-test suite (16 *.test.sh files: naming, variants, packaging,
# gate classification, version derivation, pin generation, buildinfo, perms, extras).
# These are hermetic — no build, no container needed.
bash test/run.sh

# Run one unit test
bash test/lib_variants.test.sh

# Print the full effective cmake flags (configure base + variant + common, deduped) without
# building. Platform-aware: this is how you inspect the Windows CRT without a 15-minute build.
./build-runtime.sh --print-flags --variant devtools
./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static

# Structural smoke-check of an already-built prefix
bash test/build_smoke.sh /path/to/out

# LSTM AOT round-trip (needs an export venv — see extras/README.md)
ETNP_PREFIX=<built-prefix> python -m pytest extras/lstm/test/test_lstm_roundtrip.py
```

### Building the runtime locally

`build-runtime.sh` is the single build entrypoint. It **must run inside the
`quay.io/pypa/manylinux_2_28_x86_64` container** and **never clones ExecuTorch** — the
caller always supplies a checked-out ET source tree (with submodules) via `--et-src`:

```bash
docker run --rm -v "$PWD":/work -v /path/to/executorch:/executorch \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant logging --prefix /work/out --et-src /executorch'
```

Useful flags/env for iteration:
- `SKIP_ET_BUILD=1` — reuse an existing `--prefix` install, skip the ~10–15min ET compile.
- `--extras-only` — rebuild *only* the custom ops (phase 2) against an existing prefix.
- `--build-dir` — the CMake build tree (persisted for incremental rebuilds); default is
  `<dirname of --prefix>/et-build-<variant>`.
- `HOST_UID`/`HOST_GID` — chown built artifacts back to the host user (mounted-volume ergonomics).

## Architecture

### Build recipe: two phases

`build-runtime.sh` runs two distinct phases:
1. **Phase 1 — ExecuTorch build+install.** Configures ET with the `linux` preset plus the
   variant flags and common flags, builds, installs to `--prefix`. Then it *repairs the
   install for relocatability* (see below) and does license passthrough.
2. **Phase 2 — extras (`build_extras`).** Builds `extras/` against the just-installed
   prefix and installs the custom-op archives + headers + `lib/cmake/ETNPExtras`. Also
   installs Google Highway's license (Highway is fetched by the extras build; shipping
   `libhwy.a` without its license is treated as a hard compliance failure).

`--extras-only` runs phase 2 alone against a downloaded release prefix — this is how the
PR gate rebuilds a branch's custom ops without paying for a full ET compile.

### Relocatability repair (the core value-add)

After `cmake --install`, the recipe rewrites the exported CMake configs so the tarball is
portable. This is the heart of what makes the artifact usable downstream — treat these
`sed` steps as load-bearing, not incidental:
- Patches an ET 1.3.1 install bug where some targets install to `${CMAKE_BINARY_DIR}/lib`
  instead of `${CMAKE_INSTALL_LIBDIR}` (upstream issue pytorch/executorch#20709).
- Rewrites any leaked absolute `--prefix` in `lib/cmake` to `${PACKAGE_PREFIX_DIR}`.
- Normalizes absolute system-lib paths (`/usr/lib64/libm.so`, etc.) to bare `-l<name>`
  so consumers on Debian/Ubuntu multiarch (where these live elsewhere) can link.

### Single-source-of-truth libraries

`scripts/lib/*.sh` are sourced by both the build and the packaging/CI so the two can
never drift. When changing anything they define, change it here, not at a call site:
- `configure-base.sh` — platform → cmake configure base (`--preset linux` vs the flat Windows flag
  list), **and** `crt_for_platform`, the one platform→CRT mapping consumed by the build, the
  relocatability gate, and the CI CRT scan.
- `variants.sh` — variant → cmake flag string (contract C3).
- `cmakeflags.sh` — common variant-independent cmake flags, **and** `effective_cmake_flags`, which
  composes + dedupes the full set. The build, `--print-flags`, and `BUILDINFO` provenance (C5) all
  go through it, so they cannot diverge.
- `naming.sh` — asset/tarball/sha/fixtures naming (contract C1).

### Custom ops: `extras/`

Each subdir under `extras/` is one op bundle (`lstm` is op #1) with `runtime/` (torch-free
C++ kernel + static-init registrar), `aot/` (torch export definition), `test/` (mandatory —
`extras/CMakeLists.txt` FATAL_ERRORs an op with no `test/` dir), and `extra.yaml`.

- **`extra.yaml` is the single source of truth for op name + schema.** Both the C++
  registrar (via a header generated by `generate_schema_header.py`) and the Python AOT
  read from it, so the two faces cannot drift.
- Op archives are pure static-initializer registration libs (like `libxnnpack_backend.a`);
  consumers **must** whole-archive them via the installed `ETNPExtras.cmake` helper.
- A **post-link nm-guard** (`cmake/assert_extras_registered.cmake`) proves each op's
  registrar TU survived `--gc-sections`/whole-archive — a dropped registrar is otherwise
  invisible until "operator not found" at model-load time.
- **USDT probe names are a committed contract** (Linux only): provider `etnp`, probes
  `lstm_xnn_cache__hit`/`__miss`/`__evict`, defined in `extras/lstm/runtime/etnp_usdt.h`
  and enforced by a POST_BUILD `readelf` guard (`scripts/check-usdt-notes.sh`). Renaming a
  probe is breaking; see `docs/lstm-xnn-cache-usdt.md`.

### CI workflows

- **`.github/workflows/release.yml`** — the *only* release trigger is pushing a tag
  `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`; bump `<pkgrev>` to re-roll the same ET version).
  Matrix of {variant} × {platform}; the **Linux** platforms are a single JSON source-of-truth in the
  workflow `env.PLATFORMS`. Windows is a **separate `build-windows` job, not in `env.PLATFORMS`**
  (it needs MSVC on a non-container runner); it has its own {variant} × {platform} matrix over
  `windows-x86_64` (/MD) and `windows-x86_64-static` (/MT). Jobs: `setup` → `build` +
  `build-windows` (attest each tarball) → `pin` (generates `EtRuntimePin.cmake`) → `release`.
- **`.github/workflows/extras-gate.yml`** — PR gate for `extras/**` / `build-runtime.sh`
  changes. `scripts/classify-gate.sh` picks a mode from the changed files:
  - `tier1` — pure kernel/runtime/test edit → torch-free consumer smoke on both arches.
  - `tier2` — AOT/schema/`extra.yaml` change → also run the live torch round-trip.
  - `full` — any `build-runtime.sh` change (or no matching release) → full-build release
    dry-run, so a green gate means the eventual release tag will build.

  tier1/tier2 download a published release tarball and rebuild only the branch's extras
  on top of it (via `--extras-only`), skipping the ~15min ET compile.

## Downstream consumption

Downstream projects do **not** build this recipe. They pull a release's generated
`EtRuntimePin.cmake` (records URL + SHA-256 for every variant/platform), `FetchContent`
the pinned tarball (re-verified on every build), and `find_package(ExecuTorch ...)`
against `lib/cmake/ExecuTorch` in the extracted prefix. See README.md "Consuming
downstream" and `docs/handover-to-engine.md`.

## Conventions

- Shell scripts run under `set -euo pipefail`. `grep` exits 1 on no-match, which aborts
  under `set -e`/`pipefail` — existing code guards these with `|| true`; keep that pattern.
- The recipe is idempotent: re-runs must not fail on already-patched sources or existing
  build trees.
- Design docs and plans live in `docs/superpowers/{specs,plans,notes}/`; op-specific docs
  in `docs/`. `spike/` holds throwaway spike artifacts and logs — not part of the product.
