# OpenVINO support on `linux-x86_64` — design

## Problem

Upstream ExecuTorch ships an optional `executorch[openvino]` extra that enables the Intel
OpenVINO delegate. This repo publishes the *runtime* half of ExecuTorch, and today builds with
`EXECUTORCH_BUILD_OPENVINO=OFF` (the upstream default), so no consumer of our tarballs can load
an OpenVINO-delegated `.pte` at all.

Two first-party consumers want it, both on Linux x86-64:

- a **Python package** with deliberately slimmer dependencies than the official `executorch`
  wheel (no PyTorch), and
- a **Java/JNI application** shipping qualified jars with platform-specific `.so` files.

Neither should have to re-derive how the delegate finds its runtime. That derivation is
non-obvious, and getting it wrong fails at model-load time rather than at build time.

## What was measured

Everything below was measured during the spike against ET 1.3.1 in
`quay.io/pypa/manylinux_2_28_x86_64`, not inferred from documentation.

**The backend itself is nearly free.**

- `backends/openvino/CMakeLists.txt` resolves the OpenVINO C API via `dlopen`/`dlsym`, so there
  is **no build-time dependency on any OpenVINO SDK**. Verified: the build container contains no
  OpenVINO whatsoever (`ldconfig` count 0, no `libopenvino*` on disk) and the build and consumer
  link both succeed.
- Enabling it adds one 43.3 KB static archive, `lib/libopenvino_backend.a`.
- It compiles `-fPIC` correctly under our flags: zero absolute `R_X86_64_32/32S` relocations.
- It exports cleanly into `ExecuTorchTargets` using `${_IMPORT_PREFIX}`. **The existing
  relocatability repair needs no changes** — zero absolute-prefix leaks, zero build-tree leaks.
- Upstream already adds it to the `executorch_backends` aggregate and attaches
  `--whole-archive` to the imported target, so downstream needs no `ETNPExtras`-style helper.
  Verified `_GLOBAL__sub_I_OpenvinoBackend.cpp` survives into a consumer `.so`.

**The runtime lookup is where consumers will get hurt.**

- The backend dlopens the *unversioned* name `libopenvino_c.so`, falling back to whatever
  `OPENVINO_LIB_PATH` holds (`OpenvinoBackend.cpp:47-50`).
- `OPENVINO_LIB_PATH` is a **full path to the library file**, not a directory — it is passed
  straight to `dlopen`. The error text ("set `OPENVINO_LIB_PATH` or `LD_LIBRARY_PATH`") reads
  like it takes a directory; it does not.
- Loading is `std::call_once` with **no retry**. If the first attempt fails, the process stays
  broken until restart.

**Two upstream distributions behave differently, and neither is strictly better:**

| | PyPI wheel | Intel RHEL8 archive |
|---|---|---|
| unversioned `libopenvino_c.so` symlink | **absent** | present |
| `RPATH` on runtime libs | `$ORIGIN` | **none** |
| TBB location | same dir | separate `runtime/3rdparty/tbb/lib` |
| needs `OPENVINO_LIB_PATH` | **yes** | no |
| needs `LD_LIBRARY_PATH` | no | **yes** (two dirs) |
| max GLIBC / GLIBCXX / CXXABI | 2.17 / 3.4.19 / 1.3.7 | 2.27 / 3.4.22 / 1.3.11 |
| license of runtime libs | **Apache 2.0** | **Intel OpenVINO Distribution License (EULA)** |

Both ABI floors sit below the `manylinux_2_28` baseline (AlmaLinux 8.10, glibc 2.28), so either
runs anywhere our existing artifacts run.

**The JVM constraint is decisive.** A JVM cannot set `LD_LIBRARY_PATH` for itself after startup —
glibc's loader reads it once at process start, so a `setenv` from JNI does not affect later
`dlopen` searches. `OPENVINO_LIB_PATH` *is* read at call time and therefore does work from JNI.
This rules out the archive's bare layout for the Java consumer, and makes `$ORIGIN` + an explicit
`OPENVINO_LIB_PATH` the only mechanism that works identically for both consumers.

**Minimal CPU-only file set** (measured working, device enumeration returns `CPU`):

| file | size |
|---|---|
| `libopenvino_intel_cpu_plugin.so` | 52.4 MB |
| `libopenvino.so.<ver>` | 18.1 MB |
| `libtbb.so.12` | 368 KB |
| `libopenvino_c.so.<ver>` | 331 KB |

68 MB on disk, ~21 MB zip-compressed. The GPU/NPU plugins and every model frontend
(ONNX/TF/PyTorch/Paddle/JAX) are droppable: we consume a precompiled blob and never parse a model
format.

`libtbbbind_2_5.so.3` (30.6 KB) + `libhwloc.so.15` (460.6 KB) are **also shipped in the wheel** and
are *not* dead weight: under `LD_DEBUG=libs`, `libtbb` dlopens `libtbbbind_2_5.so.3` by name (it is
not a `NEEDED` entry), which in turn pulls `libhwloc.so.15` via its own `NEEDED` + `$ORIGIN`. Both
resolve from the same flat directory. Omitting them is safe — TBB degrades gracefully, which is why
the 4-file set above still initialised cleanly — but including them enables topology-aware thread
binding.

**Blob version compatibility is looser than feared.** The AOT side calls
`compiled.export_model()` (`preprocess.py:60`) and the runtime calls `ov_core_import_model`, so
the `.pte` embeds a precompiled OpenVINO blob. Measured, with a corrupted-blob control to prove
the probe can detect failure:

| test | result |
|---|---|
| corrupted blob → 2025.4.1 runtime (control) | **IMPORT FAILED** (status −1) |
| blob 2025.4.1 → runtime 2025.4.0 | IMPORT OK |
| blob 2025.4.1 → runtime 2025.1.0 | IMPORT OK |
| blob 2025.1.0 → runtime 2025.4.1 | IMPORT OK |

Compatibility holds in both directions across the 2025.x line, so upstream's
`>=2025.1.0,<2026.0.0` range is defensible rather than requiring an exact pin.

## Decisions

### 1. Fold the backend into all three Linux variants; do not add a fourth variant

`EXECUTORCH_BUILD_OPENVINO=ON` for `bare`, `logging`, and `devtools` on `linux-x86_64`. Cost is
43.3 KB per tarball and no build-time dependency; a separate variant would double the Linux
matrix to buy nothing, because `dlopen` means an unused delegate costs nothing at runtime.

The flag is **platform-gated to `linux-*`**. Windows is excluded: the backend's
`-frtti -fexceptions` is GCC/Clang spelling, it relies on `dlopen`/`CMAKE_DL_LIBS`, and upstream's
own extra is gated `platform_system == 'Linux'`. This matches our existing posture where Windows
ships `logging` only.

`linux-aarch64` is excluded — OpenVINO's Intel CPU plugin is x86-64. Scope is `linux-x86_64`
exactly, as the task states.

**Placement:** the flag belongs with the other variant-independent flags rather than in
`et_configure_base`, which is documented as the *configure base* (preset vs flat Windows list).
`common_cmake_flags` is currently platform-blind, so it gains a platform parameter, and
`effective_cmake_flags` passes `$1` through. This keeps `EXECUTORCH_BUILD_OPENVINO` next to
`EXECUTORCH_BUILD_XNNPACK`, where a reader will look for it.

### 2. Publish the OpenVINO runtime as a separate hash-pinned asset (new contract C10)

Rather than bloating every variant tarball by 68 MB, or leaving each consumer to assemble its
own, the release publishes one additional Linux-only asset:

```
openvino-runtime-<ovver>-linux-x86_64.tar.gz   (+ .sha256, + attestation)
```

Versioned by **OpenVINO** version, not ET version: it tracks an independent upstream and must be
re-rollable without an ET version bump.

This is the same value proposition as the rest of the repo — a relocatable, hash-pinned,
attested artifact that downstream re-verifies — applied to the one dependency the delegate needs
at runtime. It also guarantees the Python and JNI consumers ship **byte-identical** OpenVINO,
which is the failure mode most likely to produce a "works in Python, fails in Java" bug.

**Tarball layout (C10):** a single top-level directory containing one flat `lib/` directory, so
`$ORIGIN` resolves everything:

```
openvino-runtime-<ovver>-linux-x86_64/
  lib/
    libopenvino_c.so -> libopenvino_c.so.<abi>      # symlink we add
    libopenvino_c.so.<abi>
    libopenvino.so.<abi>
    libopenvino_intel_cpu_plugin.so
    libtbb.so.12                                    # plain file in the wheel, no symlink needed
    libtbbbind_2_5.so.3                             # NUMA binding, dlopened by libtbb
    libhwloc.so.15                                  # topology, NEEDED by tbbbind
  licenses/
    LICENSE                                  # Apache 2.0
    runtime-third-party-programs.txt
    onetbb_third-party-programs.txt
    onednn_third-party-programs.txt
    hwloc-COPYING                            # BSD-3-Clause — NOT bundled in the wheel; see §7
  BUILDINFO                                  # ov_version, ov_wheel_sha256, source_url, members
```

We **add** the unversioned `libopenvino_c.so` symlink the wheel omits. That makes the backend's
default lookup work whenever the directory happens to be on the search path, while
`OPENVINO_LIB_PATH` remains the supported mechanism.

### 3. Vendor from the PyPI wheel, not the Intel archive

This reverses the spike's working assumption.

To be precise about what is and isn't at issue: **both upstream projects are Apache 2.0** —
`openvinotoolkit/openvino` and `uxlfoundation/oneTBB` (the wheel bundles oneTBB 2021.13.1, the
successor to classic TBB, confirmed from `TBB_VERSION` in the binary). The source licensing is
not in question, and redistributing Apache-2.0 binaries is routine.

What differs is the **terms Intel attaches to its own prebuilt distribution**, which is a
separate matter from the license of the sources it was built from.
`docs/licensing/readme.txt` in the Intel archive states that only headers, samples, and the
Python API are Apache 2.0; **`runtime/lib/*` is under the Intel OpenVINO Distribution License**.
Its `redist.txt` does permit redistributing `runtime/lib/intel64/*` on Linux, but the Linux
section does **not** list `runtime/3rdparty/tbb/lib/*` (TBB is listed for macOS and Windows
only) — and we need `libtbb`. Separately, making the archive usable from JNI required
`patchelf --set-rpath` to *modify* Intel-provided binaries, which a distribution EULA is likely
to restrict.

The PyPI wheel sidesteps all of that: it is plain **Apache 2.0**
(`License: OSI Approved :: Apache Software License`, with `LICENSE`,
`runtime-third-party-programs.txt`, `onetbb_third-party-programs.txt`, and
`onednn_third-party-programs.txt` bundled as declared `License-File`s) and already carries
`RPATH=$ORIGIN`, so vendoring from it requires **no binary modification at all** and is 68 MB
rather than 79 MB. It is Apache 2.0 end to end — sources and the binary distribution alike — so
our obligation is the ordinary Apache-2.0 one: carry the license and the attribution notices,
which the bundle does by construction.

The Intel archive remains the better choice for anyone installing OpenVINO into their own
container by hand — it is ABI-compatible with `manylinux_2_28` and its unversioned symlinks make
the default lookup work. That guidance belongs in the docs; it is not what we redistribute.

Shipping the license files is a **hard gate**, not a nicety — the same discipline already applied
to Google Highway's license in `build_extras`.

### 4. `scripts/vendor-openvino.sh` is the single source of truth for assembly

One script, used by CI to produce the asset and runnable by hand:

```
scripts/vendor-openvino.sh --ov-version <ver> --out <dir> [--wheel <path>]
```

It downloads (or accepts) the `manylinux2014_x86_64` wheel, verifies its SHA-256, extracts the
CPU-only subset, creates the symlink, copies the license files, writes `BUILDINFO`, and fails
loudly if any expected member or license file is missing. The member list lives in
`scripts/lib/openvino.sh` alongside the pinned OpenVINO version, so the script, the packaging
test, and the docs cannot drift — the same pattern as `scripts/lib/naming.sh`.

### 5. Consumer contract: always set `OPENVINO_LIB_PATH`

Both docs will say the same thing, because a single mechanism that works everywhere beats two
that each work somewhere:

> Set `OPENVINO_LIB_PATH` to the **absolute path of the `libopenvino_c.so` file** before the
> first inference. Do not rely on `LD_LIBRARY_PATH`.

Rationale, in the docs: `$ORIGIN` resolves the rest of the graph, `OPENVINO_LIB_PATH` is read at
call time (so JNI can set it via `setenv`), and `std::call_once` means a first failure is
permanent for the process.

### 6. Version policy

The pinned OpenVINO version is recorded in `scripts/lib/openvino.sh`, in the asset name, in the
asset's `BUILDINFO`, and in each variant tarball's `BUILDINFO` as `openvino_version` (extending
C5). Consumers are told to prefer the published asset; those installing their own are told
`>=2025.1.0,<2026.0.0` is supported, with **runtime version ≥ export version** as the safe rule,
since the cross-version evidence comes from a trivial graph that does not exercise version-gated
ops.

### 7. Include `libtbbbind` + `libhwloc`, and add the hwloc notice ourselves

Both ship in the wheel, so **nothing needs to be sourced externally**. They cost ~491 KB on top
of the 68 MB base — negligible — and they are genuinely exercised at runtime (§"What was
measured"), so we include them rather than making consumers assemble a second-tier bundle.

This carries one obligation that the wheel does *not* satisfy for us. **`libhwloc` is
BSD-3-Clause and is not attributed anywhere in the wheel's license material** — verified zero
matches for `hwloc` / "Portable Hardware Locality" across `LICENSE`,
`runtime-third-party-programs.txt`, `onetbb_third-party-programs.txt`, and
`onednn_third-party-programs.txt`. BSD-3-Clause requires reproducing the copyright notice and
disclaimer in binary redistributions, so shipping `libhwloc.so.15` under only the Apache-2.0
material would be a real gap.

`scripts/vendor-openvino.sh` therefore fetches hwloc's `COPYING` for the matching release and
installs it as `licenses/hwloc-COPYING`, and the bundle test **fails hard** if it is missing —
the same treatment `build_extras` already gives Google Highway's license. The bundled version is
**hwloc 2.8.x**, determined by calling `hwloc_get_api_version()` on the shipped binary
(`0x020800`), since the release string is stripped from the library.

If the hwloc notice is ever unavailable at build time, the correct fallback is to **drop
`libtbbbind` + `libhwloc` from the bundle**, not to ship them unattributed — losing NUMA binding
is a performance regression, shipping unattributed BSD code is a compliance failure.

## Changes by file

| file | change |
|---|---|
| `scripts/lib/cmakeflags.sh` | `common_cmake_flags` takes a platform; adds `EXECUTORCH_BUILD_OPENVINO=ON` for `linux-x86_64`; `effective_cmake_flags` passes it through. Verified safe: `common_cmake_flags` has **no callers outside this file** — every other consumer (`build-runtime.sh`, `scripts/package.sh`) goes through `effective_cmake_flags`, which already takes a platform |
| `scripts/lib/openvino.sh` | **new** — pinned OV version, wheel SHA-256, member list, asset naming |
| `scripts/vendor-openvino.sh` | **new** — wheel → normalized bundle |
| `scripts/gen-pin.sh` | emit `ET_RUNTIME_OPENVINO_URL` / `_SHA256` / `_VERSION` |
| `scripts/gen-buildinfo.sh` | record `openvino_version` (C5) |
| `.github/workflows/release.yml` | new `openvino` job producing + attesting the asset; `pin` consumes it; `release` uploads it |
| `.github/workflows/extras-gate.yml` | `classify-gate.sh` routes `scripts/vendor-openvino.sh` / `scripts/lib/openvino.sh` changes to a mode that rebuilds and smoke-tests the bundle |
| `test/consumer/CMakeLists.txt` | link `executorch_backends` so the PIC gate actually covers the delegate |
| `test/lib_cmakeflags.test.sh` | **new** — flag present on `linux-x86_64`, absent on Windows and aarch64 |
| `test/openvino_bundle.test.sh` | **new** — member list, symlink, licenses present (incl. `hwloc-COPYING`, hard-fail) |
| `test/openvino_smoke.sh` | **new** — dlopen the bundle, enumerate devices, expect `CPU` |
| `docs/openvino-python-consumer.md` | **new** — deliverable |
| `docs/openvino-jni-consumer.md` | **new** — deliverable |
| `README.md`, `CLAUDE.md` | document C10 and the new asset |

## Testing

Hermetic shell tests (no build, no container) cover flag composition, bundle membership, and
license presence, consistent with the existing 16-test suite.

**No existing test needs rewriting.** `test/build_cli.test.sh` and `test/package.test.sh:81`
assert with `assert_contains` rather than exact string equality, so an added flag does not break
them — verified against the current assertions. New coverage is therefore purely additive.

Two tests need a container and real artifacts:

- **`test/openvino_smoke.sh`** — dlopens the bundle's `libopenvino_c.so` by absolute path with
  `LD_LIBRARY_PATH` explicitly **unset**, calls `ov_core_get_available_devices`, and asserts
  `CPU` appears. This is the test that catches a broken `$ORIGIN`, a missing plugin, or a missing
  TBB — none of which a file-listing test can see. The spike's probe becomes this test.
- **`test/relocatability.sh`** — unchanged, but now meaningful for the delegate because
  `test/consumer` links `executorch_backends`. Without that edit nothing would link
  `openvino_backend` and any regression in it would be invisible.

Deliberately **not** covered by CI: a full AOT round-trip through `torch` + `openvino` to produce
a real delegated `.pte`. That needs the heavy export venv and belongs with the existing
`extras/lstm` round-trip pattern if it is ever wanted; the blob-import path is already covered by
the smoke test at the C API level.

## Consumer documentation — the two deliverables

Both are written so a consumer never has to read this spec or re-run the spike.

**`docs/openvino-python-consumer.md`** — for the slim, torch-free Python package:

- OpenVINO is a *runtime* dependency only; nothing on this path imports torch.
- Two supported sourcing options: our published asset (preferred, hash-pinned), or
  `pip install "openvino>=2025.1.0,<2026.0.0"`.
- **The pip path needs `OPENVINO_LIB_PATH`** — the wheel has no unversioned
  `libopenvino_c.so`, so the default lookup fails. Includes the `importlib.util.find_spec` snippet
  that resolves `openvino/libs/libopenvino_c.so.*`.
- Set it before the first inference; `std::call_once` means a first failure is permanent.
- Version policy and the blob-compatibility evidence.

**`docs/openvino-jni-consumer.md`** — for the qualified-jar JNI application:

- Which files to vendor and what they cost (~21 MB compressed), and why the GPU/NPU plugins and
  frontends are omitted.
- Extract to one flat directory; `$ORIGIN` resolves the rest.
- **You cannot set `LD_LIBRARY_PATH` from Java.** Call `setenv("OPENVINO_LIB_PATH", path, 1)`
  from the JNI layer after extraction, before the first inference. This is the section that
  saves the most re-derivation.
- ABI floor (glibc 2.28 via `manylinux_2_28`) and why the Intel archive, while ABI-fine, is not
  what we redistribute.
- A copy-pasteable init sequence and the `libopenvino_c.so` naming/symlink rules.

## Scope boundaries

- **`linux-x86_64` only.** No Windows (no `dlopen`, upstream extra is Linux-gated), no
  `linux-aarch64` (Intel CPU plugin is x86-64), no macOS.
- **CPU device only.** GPU/NPU plugins are excluded from the bundle. Adding them later is a
  member-list change in `scripts/lib/openvino.sh`, not a redesign.
- **No AOT/export tooling.** The partitioner and quantizer live in the `executorch` Python
  package and stay a consumer-side `pip install`; this repo ships runtime artifacts. The docs
  say so explicitly, because "mirror `executorch[openvino]`" could otherwise be read as promising
  a self-contained export story.
- **No change to the relocatability repair.** Measured unnecessary.

## Risks and open questions

1. **Blob compatibility evidence is from a trivial graph.** matmul+relu does not exercise
   version-gated ops. Mitigation: the docs state "runtime ≥ export version" rather than claiming
   the full range is safe in both directions.
2. **Asset size.** ~21 MB compressed added per release. Accepted deliberately in exchange for
   byte-identical OpenVINO across both consumers.
3. **Redistribution.** Low risk. OpenVINO and oneTBB are both Apache 2.0 upstream, and the wheel
   we vendor from is itself Apache 2.0 with its attribution notices included, so this is an
   ordinary Apache-2.0 redistribution: carry the license and notices, which the bundle does by
   construction and `test/openvino_bundle.test.sh` enforces. The Intel archive's EULA terms are
   avoided entirely by not shipping its binaries.
4. **OpenVINO version bumps are now our responsibility.** A new OV release requires updating
   `scripts/lib/openvino.sh` and re-rolling the asset. This is a new maintenance surface the repo
   did not previously have.
