# Windows static-CRT (`/MT`) artifact — design

**Status:** spike-validated (GO), ready for an implementation plan.
**Spike:** `spike/mt-crt/` (harness + `FINDINGS.md`), run 2026-07-18 on winbox.
**Prerequisite:** issue #10 (Windows compiler pin) — see §4.

## Problem

The Windows artifact is built with MSVC's default **`/MD`** (dynamic CRT). That is correct for the
Python consumer — CPython is itself `/MD`, and a `/MT` extension in that process means two CRTs and
two heaps, with the classic cross-allocation corruption whenever a resource crosses the boundary.

It is a poor fit for the Java/JNI consumer. A `/MD` JNI DLL requires the VC++ redistributable on the
end user's machine. The Windows JNI audience here is **developers on locked-down workstations** who
may not be able to install it. `/MT` folds the CRT into the DLL, making it self-contained — the
idiomatic choice for a distributable Java-native library, and safe for JNI specifically because
JNI's ABI is pure C and never passes CRT-owned resources across the boundary (all memory/handles go
through `JNIEnv`). Both `/MD` and `/MT` are *correct* for JNI; only `/MT` removes the redist.

**One artifact cannot serve both.** MSVC records the CRT choice per-object as `/DEFAULTLIB`
directives (`LIBCMT`/`LIBCPMT` for `/MT`, `MSVCRT`/`MSVCPRT` for `/MD`). Every statically-linked
object in a downstream DLL must agree, or the link fails with `LNK4098`/`LNK2005`. Since we ship
**static** libs, the downstream's CRT is forced to match ours. Hence: two Windows artifacts.

## Decisions

| Question | Decision | Rationale |
|---|---|---|
| Encode the CRT how? | **Platform suffix** — `windows-x86_64-static` | Reuses every existing seam; naming contract C1 stays a 3-tuple. §2 |
| New `crt` dimension alongside variant/platform? | **No** | Breaks C1's signature and touches 6+ files for no gain. §2 |
| Default `windows-x86_64` semantics | **Unchanged = `/MD`**, but now pinned explicitly | Backward compatible for existing Python consumers; removes an implicit default. §3 |
| Set `CMAKE_POLICY_DEFAULT_CMP0091=NEW`? | **No** | cmake ≥3.15 defaults it NEW; cmake 4.3 warns it is unused. Spike finding 3. |
| Variants in scope | **`logging` only** | Matches current Windows scope; 1 job → 2. §5 |

## 1. Why the CRT must be a first-class artifact axis

Not a build flag we can leave to the consumer: the choice is baked into the shipped `.lib` objects at
compile time. A consumer cannot re-target it. The artifact therefore carries an ABI-ish property that
must be visible in its identity — which is exactly what the platform token already expresses.

## 2. Encoding: a platform suffix

`windows-x86_64` (`/MD`, unchanged) and `windows-x86_64-static` (`/MT`).

Treating the CRT as part of the platform is honest rather than a hack — it *is* an ABI/linkage
distinction of the target, the same category as OS and architecture. And `platform` is already
threaded end-to-end: naming, packaging, provenance, pin discovery, the pin `.cmake`'s
platform-keyed selection, and the build matrix.

**Rejected — a separate `crt` dimension.** It would break `asset_stem <etver> <variant> <platform>`
(contract C1) and force changes through `package.sh`, `discover-pin-rows.sh`, `gen-pin.sh`, the pin
`.cmake` schema, `BUILDINFO`, and every test that constructs the tuple. Strictly more churn for an
equivalent result.

## 3. What changes — and what deliberately doesn't

The high-value finding from tracing the blast radius is how little moves.

### Changes

**`scripts/lib/configure-base.sh`** — the only product logic change. Add a `windows-x86_64-static`
case carrying `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`, and add
`-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` to the existing `windows-x86_64` case so today's
implicit default becomes explicit and recorded. Both Windows cases otherwise share the identical
flag list; factor the shared body so the two cannot drift.

**`.github/workflows/release.yml`** — `build-windows` gains a platform axis over
`[windows-x86_64, windows-x86_64-static]` (1 job → 2). Two call sites currently hardcode
`windows-x86_64` and must become `${{ matrix.platform }}`: the `--platform` argument to
`build-runtime.sh`/`package.sh`, and the `upload-artifact` name
(`dist-${{ matrix.variant }}-windows-x86_64`) — **if that name is not parameterized the two CRT
builds collide on upload.**

**`test/relocatability-windows.sh`** — must thread the CRT into the consumer configure. It currently
builds `test/consumer` with cmake defaults (`/MD`); against a `/MT` artifact that fails `LNK4098`.
Derive the CRT from the platform argument (or accept it explicitly) and pass
`-DCMAKE_MSVC_RUNTIME_LIBRARY`. **This gate is what proves the `/MT` artifact is actually
consumable, so it must not be allowed to silently test the wrong CRT.**

**`test/lib_configure_base.test.sh`** — assert each Windows platform emits its expected
`CMAKE_MSVC_RUNTIME_LIBRARY`, that the two remain otherwise flag-identical, and that
`windows-x86_64-static` still carries the existing `KERNELS_OPTIMIZED`/`QUANTIZED` and no-preset
guards.

**`README.md` / `docs/handover-to-engine.md`** — document which artifact to pick (§7).

### Explicitly no change (verified by reading, not assumed)

- **`scripts/lib/naming.sh`** — `asset_stem <etver> <variant> <platform>` is unchanged; the suffix
  rides inside the platform token.
- **`scripts/discover-pin-rows.sh`** — parses `variant="${rest%%-*}"` / `platform="${rest#*-}"`,
  i.e. splits on the *first* dash, so multi-dash platforms already work (it handles `linux-x86_64`
  today). It validates by reconstructing the basename via `tarball_name`, which still matches. The
  new artifact appears as a pin row automatically.
- **`scripts/gen-pin.sh`** — emits `ET_RUNTIME_URL_<variant>_<platform>` /
  `ET_RUNTIME_SHA256_<variant>_<platform>`. Dashes already appear in existing platform names, so
  `..._logging_windows-x86_64-static` needs no schema change.
- **`scripts/package.sh`** — line 49 derives `CMAKE_FLAGS` from
  `et_configure_base "$PLATFORM"`, so putting the CRT flag in the SSOT makes `BUILDINFO` provenance
  record it **automatically**. Contract C5 (build and provenance cannot diverge) is preserved for
  free; this is the payoff of the existing SSOT design.

## 4. Prerequisite: the compiler pin (issue #10)

`build-runtime.sh` does not pin `CMAKE_C_COMPILER`/`CMAKE_CXX_COMPILER`. Where `cmake` resolves to
the VS-bundled copy (any stock VS workstation with no standalone cmake), its own MSVC discovery
defaults to the `Hostx86\x86` toolchain and silently configures **32-bit** — despite an x64 dev
shell, x64 `cl` on `PATH`, and x64 `LIB`. CI is correct only by accident of the runner shipping a
standalone cmake that wins `PATH` precedence.

This is **not** caused by the CRT work and is filed separately as issue #10, but it blocked the spike
and should land first: it is a prerequisite for anyone reproducing either Windows artifact locally.
The fix is `-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl` in the Windows configure base, plus a
target-arch guard and a post-configure assertion that the cache holds no `Hostx86/x86`.

Note the existing relocatability smoke would **not** catch a 32-bit build: a *consistently* x86
artifact configures, links, and passes `find_package` + the consumer link. Worth an explicit
architecture assertion on the packaged artifact (e.g. `dumpbin /headers` machine type) — see §8.

## 5. CI matrix

`logging` × `{windows-x86_64, windows-x86_64-static}` = 2 Windows jobs. Each runs the full existing
sequence — build → package → relocatability smoke (now CRT-aware) → attest → upload — so the `/MT`
artifact is gated exactly as strictly as the `/MD` one before it is attested. `pin` already consumes
whatever lands in `dist/` via filesystem discovery, so it needs no edit.

## 6. Testing

- **Unit (hermetic, `bash test/run.sh`):** the `lib_configure_base` assertions in §3; extend
  `discover_pin_rows.test.sh` with a `windows-x86_64-static` fixture to lock in that the multi-dash
  platform round-trips through parse → `tarball_name` reconstruction.
- **Integration (CI):** the CRT-aware relocatability smoke per platform.
- **CRT-consistency scan — in scope.** Promote `spike/mt-crt/check-crt.sh` into the Windows release
  gate (run on the packaged prefix, before attest, alongside the relocatability smoke). It is the
  only check that catches a *future* ET or third-party dependency starting to hardcode `/MD`: a leak
  in a lib the consumer probe does not pull in would otherwise ship silently. ~40 lines of
  `dumpbin /directives`, and it directly guards the invariant this whole design rests on.

## 7. Downstream consumption

`EtRuntimePin.cmake` already selects by platform, so consumers pick a row:

- **Python / CPython extensions → `windows-x86_64`** (`/MD`). Required: must match CPython's CRT.
  Ship the VC++ runtime DLLs with the wheel (e.g. `delvewheel`) or depend on the redist.
- **Java / JNI → `windows-x86_64-static`** (`/MT`). Self-contained; no redist on the end user's
  machine. The consumer's own JNI DLL must also compile `/MT`.

Document that mixing is a link-time failure (`LNK4098`/`LNK2005`), not a subtle runtime bug — the
failure mode is loud, which is worth stating so consumers don't fear silent corruption.

## 8. Scope boundaries

**In scope:** `windows-x86_64-static` for `logging`; explicit CRT pin on both Windows platforms;
CRT-aware relocatability smoke; the CRT-consistency scan promoted into the release gate (§6);
provenance via the existing SSOT; pin row; attestation; docs.

**Out of scope:** `bare`/`devtools` on Windows (unchanged — Windows ships `logging` only); macOS;
`extras/` on Windows; optimized/quantized kernels and the clang-cl question (separate, see below);
any change to Linux artifacts.

**Recommended follow-up, not required here:** an architecture assertion on the packaged Windows
artifact (§4), since no current gate would catch a coherently-32-bit build.

## 9. Spike-resolved unknowns

Full detail in `spike/mt-crt/FINDINGS.md`.

1. ~~Does `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` propagate through ET *and* every third-party
   subproject?~~ **Yes — clean.** 18/18 installed static libs request `LIBCMT`/`LIBCPMT`, zero
   `MSVCRT` leaks, including the `flatcc_ep`/`flatc_ep` ExternalProjects and the vendored
   XNNPACK/pthreadpool/cpuinfo/pcre2/tokenizers trees. XNNPACK, the predicted risk, was a non-issue.
   **No `CMAKE_ARGS` forwarding is needed** — an earlier reading of the failing run suggested
   ExternalProjects did not inherit the CRT; that was fallout from the 32-bit misconfigure, not the
   EP boundary.
2. ~~Does a `/MT` consumer link?~~ **Yes** — `test/consumer` builds `pic_probe.dll` clean, no
   `LNK4098`/`LNK2005`.
3. ~~Is `CMP0091` needed?~~ **No** (spike finding 3).

**Residual risk:** low. The remaining unknowns are mechanical (CI wiring, artifact-name collision)
rather than "does the toolchain permit this", and each has a test named in §6.

## 10. Deliberately unaddressed: optimized kernels / clang-cl

The Windows build omits `KERNELS_OPTIMIZED`/`QUANTIZED` because they pull torch `c10` headers that
MSVC rejects (C7555, C2672) — see the 2026-07-15 Windows design §6. That is **orthogonal** to the
CRT: clang-cl consumes the same Microsoft CRT and honors `/MD`/`/MT` identically, so switching
compilers would not remove a single decision here.

clang-cl remains the lead hypothesis for *that* question (Clang tolerates the C++20 designated
initializers at C++17 as GCC does, and c10 is continuously tested against Clang), and the original
spike's rejection was narrower than it reads — it ruled out the ET `windows` **preset** (which pins
toolset ClangCL + the VS generator), not clang-cl on Ninja. `spike/mt-crt/probe-clangcl-optimized.sh`
exists to answer it but **has not been run**. Out of scope here.
