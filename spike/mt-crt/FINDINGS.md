# Static-CRT (`/MT`) Windows spike — findings

Ran on `winbox` (VS 18.8.0 Community, MSVC 19.51.36248, cmake 4.3.1-msvc1, Ninja, ET 1.3.1,
project `.venv` Python 3.12.10 x64 with torch 2.12.0+cpu). Date: 2026-07-18.

## Bottom line: **GO** (conclusion confirmed; see the correction below)

`-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` propagates cleanly through ExecuTorch **and every
third-party subproject**. A `/MT` artifact is coherent and consumable. Verified 2026-07-18 with a
corrected scan:

```
TOTAL=18  HAS_STATIC=18  WRONG_CRT=0  NO_MARKER=0  DUMPBIN_FAIL=0
CONSUME CHECK: PASS — /MT consumer links cleanly (pic_probe.dll)
```

Every installed lib **positively carries** `LIBCMT`/`libcpmt`; none carries `MSVCRT`/`MSVCPRT`; and a
matching-`/MT` consumer links with no `LNK4098`/`LNK2005`. This clears the only unknown gating the
`windows-x86_64-static` platform-suffix design.

> ### ⚠ Correction — the original run's CRT scan was invalid
>
> The first version of this document reported
> `CRT CHECK: PASS — all 18 libs request static (LIBCMT/LIBCPMT)` from `check-crt.sh`. **That output
> was meaningless.** `dumpbin` was failing on *every* lib (`rc=157`) and the scan, being
> negative-only, read the resulting silence as success.
>
> Two compounding defects, both since fixed:
> 1. **MSYS path conversion.** Under Git-Bash a leading `/` is rewritten to a Windows path, so
>    `/nologo` became `C:\Program Files\Git\nologo` and dumpbin got a garbage filename instead of its
>    flags. Fix: pass `-nologo -directives` (MSVC accepts `-` for options).
> 2. **Negative-only assertion.** The scan checked for the *absence* of the wrong marker. Absence is
>    satisfied by silence, and a broken tool produces silence. `|| true` plus `2>/dev/null` hid the
>    non-zero exit. Fix: assert the *presence* of the expected marker and treat a dumpbin failure as
>    a hard error.
>
> The **conclusion was right but was not supported by the evidence given for it.** At the time, the
> only sound evidence for GO was the consumer link (a `/MT` probe cannot link a `/MD` artifact). The
> re-run above now supports it directly. This is the same class of silent-wrong-default as the
> compiler-pin bug in finding 2 — a gate that fails *open*.

## Findings

### 1. CRT propagation is clean — no `CMAKE_ARGS` forwarding needed
Every installed static lib honored the flag, **including the ExternalProjects** (`flatcc_ep`,
`flatc_ep`) and the vendored XNNPACK/pthreadpool/cpuinfo/pcre2/tokenizers trees. XNNPACK was the
predicted risk (large vendored CMake project, plausible hardcoded `/MD`) and was a non-issue.

Per-lib detail from the corrected scan, worth keeping because it constrains how the production gate
may assert:
- Markers are **mixed case** in real dumpbin output (`LIBCMT` but `libcpmt`) — matching must be
  case-insensitive.
- C-only libs (`cpuinfo`, `pthreadpool`, `xnnpack-microkernels-prod`) carry `LIBCMT` **with no**
  `LIBCPMT`. The assertion must be `LIBCMT` **or** `LIBCPMT`, never a requirement for both.
- `NO_MARKER=0` — no lib is legitimately CRT-free, so a blanket "must carry a marker" rule is safe.

**A mid-spike prediction was wrong and is recorded here so it isn't re-derived:** an early failing
run showed the `flatcc_ep` inner cache at `CMAKE_BUILD_TYPE=Debug` linking `MSVCRTD.lib`, which was
read as "ExternalProjects don't inherit our build type or CRT." That was **false** — it was fallout
from the broken x86 configure (finding 2), not the EP boundary. Once the arch fault was fixed, the
EPs inherited both correctly.

### 2. Blocker found and fixed: cmake silently configured **32-bit** (→ issue #10)
The first run died inside `flatcc_ep` with `unresolved external __aulldiv` / `_mainCRTStartup` and
`LNK4272 x64-vs-x86`. Root cause was **not** the CRT: with no standalone cmake installed, `cmake`
resolves to the **VS-bundled** copy, whose own MSVC discovery defaults to the `Hostx86\x86`
toolchain — despite `VSCMD_ARG_TGT_ARCH=x64`, an x64 `cl` on `PATH`, and x64 `LIB`.

Fix: pin `-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl`. Confirmed: cache flips to
`Hostx64/x64/cl.exe` and the build completes.

**This affects the product recipe too** — `build-runtime.sh` has the same omission and is correct in
CI only because the GitHub runner ships a standalone cmake that wins `PATH` precedence. Filed as
**issue #10**. Note the existing relocatability smoke would **not** catch it: a consistently-32-bit
build passes `find_package` + the consumer link fine.

### 3. `CMAKE_POLICY_DEFAULT_CMP0091=NEW` is unnecessary
cmake 4.3 warns `Manually-specified variables were not used by the project:
CMAKE_POLICY_DEFAULT_CMP0091` — CMP0091 is `NEW` by default at this cmake version. The scripts here
retain it **as-run** (so the committed harness matches exactly what produced the GO above), but it
should **not** be carried into the product change.

### 4. Environment gotchas worth keeping
- CMake never re-detects a **cached** compiler — a stale build dir must be wiped or a fix appears
  not to work. (`clean.sh`)
- `flatcc` builds **in-source** (`<et-src>/third-party/flatcc/{lib,bin}`), so x86 debris survives a
  fresh build dir. (`clean.sh`)
- In Git-Bash, `link` resolves to GNU coreutils `/usr/bin/link`, not MSVC `link.exe`. CMake uses
  `CMAKE_LINKER` so it is unaffected, but nothing should rely on bare `link`.
- Invoke Git-Bash **non-login** so a profile can't reorder the dev-shell `PATH` (same lesson
  `release.yml` already encodes).
- Pass the venv interpreter explicitly (`--python`); it removes any PATH-ordering fight between the
  dev shell and venv activation.

## Not covered

- **`bare`/`devtools` variants** — only `logging` was built (matches current Windows scope).
- **clang-cl / optimized kernels** — `probe-clangcl-optimized.sh` was written but **not run**. Edge 2
  remains open; see the design discussion for why clang-cl is the lead hypothesis there.
- **Packaging/pin/CI integration** — spike stops at "artifact is coherent and links".
