# Spike: `optimized_native_cpu_ops_lib` on Windows (issue #46)

**Status:** run; stopped at Step 3 — the /MD build fails to compile, which is the finding. **Host:** `winbox` (VS 18 / MSVC 19.51, Ninja, cmake, Git-Bash).
**Type:** throwaway. Nothing built here ships; the flag edit lives on a scratch branch that is
deleted when the spike reports.

## The question

Issue #46 argues from upstream CI that `EXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON` builds under MSVC at
our pin. That argument is sound but incomplete: upstream's `windows-msvc.yml` exercises neither
`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` (/MT) nor `EXECUTORCH_BUILD_OPENVINO=ON`, and both are in
our Windows configure base. `--print-flags` cannot close that gap — it only echoes the flag string.

Two things to find out:

1. **Does it build and install?** `optimized_native_cpu_ops_lib` and its dependencies (`eigen_blas`,
   `cpublas`, `optimized_{kernels,ops_lib,portable_kernels,portable_ops_lib}`) at **both** CRTs. The
   /MT × `eigen_blas`/`cpublas` combination is the genuinely untested one.
2. **Does the existing native C++ test code still function as designed?** Three probes run on
   Windows today:

   | Probe | Driver | Effect of the flag |
   |---|---|---|
   | `test/consumer/probe.cpp` | `test/relocatability-windows.sh` | None expected — links `executorch` only on non-UNIX. A failure here means the install/export broke. |
   | `test/openvino/blob_probe.c`, `devices_probe.c`, `win_origin_probe.c` | `test/openvino_smoke-windows.sh` | None expected — bundle-only, no ET prefix. Run as a control. |
   | `test/openvino/ov_runner.cpp` | `test/openvino_fixture_run-windows.sh` | **Behaviour changes.** `test/openvino/CMakeLists.txt:14`'s `if(TARGET optimized_native_cpu_ops_lib)` silently flips to the optimized branch on Windows for the first time, changing what `ov_runner` links. This is the probe the spike exists to exercise. |

`test/xnnpack_workspace/workspace_probe.cpp` is Linux-only (gate line 591) and is out of scope.

## Git plan

**The spike branch never reaches `origin`.** It is created locally, carried to winbox as a
`git bundle` over scp, and deleted when the spike reports. This repo is public, and commit 2 below
is explicitly throwaway — publishing it, even briefly, buys nothing. (Pushing would not trigger CI:
`unit.yml` is `pull_request` + `push: branches: [main]`, `extras-gate.yml` is `pull_request` only,
`release.yml` is `push: tags`. So CI is not the reason; visibility is.)

Branch `spike/windows-optimized-ops`, cut from `main` on the Linux workstation. Two commits, kept
separable because they have opposite fates:

| Commit | Content | Fate |
|---|---|---|
| 1 | this note (`docs/superpowers/notes/2026-08-22-windows-optimized-ops-spike.md`) | **kept** — the only thing that ever reaches `origin`, as a `docs/` PR to `main` once findings are appended |
| 2 | the one-line `EXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON` edit to `scripts/lib/configure-base.sh` | **throwaway** — local only; the real change is a separate bounded task carrying issue #46's full test/doc fallout |

```bash
git checkout main && git pull --ff-only
git checkout -b spike/windows-optimized-ops
git add docs/superpowers/notes/2026-08-22-windows-optimized-ops-spike.md
git commit -m "docs: spike procedure for optimized_native_cpu_ops_lib on Windows (#46)"
# ... Step 0's flag edit ...
git commit -am "spike: enable EXECUTORCH_BUILD_KERNELS_OPTIMIZED on Windows (THROWAWAY)"
```

### Transport to winbox

One command per iteration, re-run verbatim after every fix — the bundle is regenerated from scratch,
so it can never carry a stale tip:

```bash
git bundle create /tmp/spike.bundle main..spike/windows-optimized-ops
scp /tmp/spike.bundle winbox:<staging path>
```

On winbox, fetch from the bundle file and check the branch out. `$DIST` must not already have the
branch checked out when fetching into it:

```bash
ssh winbox 'git -C <dist> checkout main;
  git -C <dist> fetch <staging>/spike.bundle spike/windows-optimized-ops:spike/windows-optimized-ops --force;
  git -C <dist> checkout spike/windows-optimized-ops;
  git -C <dist> log --oneline -2;
  exit $LASTEXITCODE'
```

`git -C` is used throughout precisely because ssh gives no usable cwd.

`--force` is what makes re-iteration work: the second bundle rewrites the same ref. Verify the tip
hash matches the workstation's before every build — a build against a stale bundle is the one
failure mode this transport adds, and it looks exactly like a real compile result.

`git bundle` refuses to build a bundle whose basis the far side lacks, so `main..` requires winbox's
`main` to be at or past the workstation's. Confirm with `git -C $DIST rev-parse main` on the first
iteration; if it has drifted, `git -C $DIST fetch origin && git -C $DIST checkout main &&
git -C $DIST pull --ff-only` first (that fetch is from `origin`, and touches only `main`).

### Afterwards

Findings are appended to commit 1's file, which is then cherry-picked onto a `docs/` branch and
opened as a PR to `main`. The local spike branch — commit 2 with it — is deleted. Nothing else
persists.

This repo's branch conventions (`feature/*`, `fix/*`, `docs/*`, `chore/*`) have no spike prefix;
`spike/` is used here to match the existing `spike/` directory's meaning, and since the branch is
local-only the convention is not load-bearing.

## Execution model (ssh-driven)

This spike is driven from the Linux workstation over `ssh winbox`, **not** from an interactive
PowerShell session on the console. That difference invalidates the command shapes used by Task 5 of
the 1.4.1 plan and by the `shell: pwsh` steps in `extras-gate.yml`; do not copy either verbatim.
Measured on this host:

| Fact | Consequence |
|---|---|
| ssh lands in pwsh 7 with cwd `C:\Users\<user>` | `./build-runtime.ps1` and `$PWD` resolve to the wrong place. Never use a relative path or `$PWD`. |
| each ssh command is a fresh pwsh | `$DIST`/`$ETSRC` do not persist between commands. Never set a variable in one invocation and use it in the next. |
| nested quoting is three layers deep (local bash → ssh → pwsh → Git-Bash `-Command`) | inline `-Command 'set -euo pipefail; ...'` strings and backtick continuations are not worth escaping. |
| `pwsh -File script.ps1` returns **1** for any failure; the real code needs `exit $LASTEXITCODE` at BOTH layers | a bare invocation hides *which* step failed, though not *that* it failed. |
| the `&` call operator parses correctly through ssh | `& cmd args` inside a staged script is fine. |

**Therefore: no inline command strings.** Each step below is a small `.ps1` driver, authored on the
workstation, staged once by scp next to the bundle, and invoked with one flat command:

```bash
scp step3-build-md.ps1 winbox:<staging>/
ssh winbox 'pwsh -NoProfile -File <staging>/step3-build-md.ps1 -Dist <dist> -EtSrc <etsrc>; exit $LASTEXITCODE'
```

Every driver takes `-Dist` / `-EtSrc` as mandatory parameters (so no machine path is written into
this repo and nothing depends on session state), sets `$ErrorActionPreference = 'Stop'`, does its own
`Set-Location`, and ends with `exit $LASTEXITCODE`.

The two ET builds (Steps 3 and 6) run 15-25 minutes, which is longer than a foreground ssh command
should be held open. Those drivers launch the build detached with output tee'd to a log under
`$Dist`, print the log path, and exit immediately; progress is then polled with short
`Get-Content -Tail` commands and completion is detected from a sentinel line the driver appends with
the build's exit code. A foreground ssh call is used only for the short steps (assertions, packaging,
gates).

## Preconditions

- #45 (Eigen license passthrough) landed on `main` as b1d7600 — so pulling `eigen_blas` into the
  Windows artifacts no longer replicates a licence defect. Confirm the licence actually ships (Step 5).
- `$ETSRC` on winbox was moved to pristine v1.4.1 during the 1.4.1 bump. Re-assert rather than assume.

Paths stay in shell variables, never in this repo's history:

| Variable | Points at |
|---|---|
| `$DIST` | the existing `executorch-runtime-dist` clone on winbox |
| `$ETSRC` | the existing ExecuTorch checkout (leaf dir named exactly `executorch`) |

## Procedure

Each step names what it answers. A failure at Step 3 or 6 **is** the finding — stop and report.

### Step 0 — scratch branch (Linux workstation)

Create the branch and land commit 1 (this note) per the **Git plan** above. Then make the edit that
becomes commit 2: add `-DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON` to `_ET_WINDOWS_COMMON` in
`scripts/lib/configure-base.sh`. Nothing else — no test updates, no doc updates.

```bash
./build-runtime.sh --print-flags --variant logging --platform windows-x86_64-static
```
Expect the flag present exactly once, `KERNELS_QUANTIZED` still absent.

`bash test/run.sh` will fail at `lib_configure_base.test.sh` and `package.test.sh`, which assert the
*absence*. That is issue #46's documented fallout, not a spike finding — leave them red; the
throwaway commit's message says so.

Then bundle and copy per **Transport to winbox** above. **Nothing on winbox works until the bundle
lands and its tip hash matches.**

### Step 1 — baseline the current ov_runner behaviour (winbox, optional but cheap)

Before changing anything, run the OpenVINO fixture gate against the **published** v1.4.1-1 Windows
tarball. Expected STATUS line: `ov_runner kernels: portable_ops_lib`. Without this the "it flipped"
observation in Step 9 has nothing to flip *from*.

### Step 2 — pin the workspace

`$DIST` is an existing clone of this repo on winbox. Fetch the branch from the bundle per
**Transport to winbox**, then assert the tip hash matches the workstation. Nothing is committed on
winbox.

```powershell
git -C $DIST log --oneline -2                         # tip must match the workstation
git -C $ETSRC describe --tags                        # expect v1.4.1
git -C $ETSRC status --porcelain                      # expect: nothing
git -C $ETSRC submodule foreach --recursive "git status --porcelain"   # expect: nothing
```

If `$ETSRC` is dirty, force it pristine (`checkout -f v1.4.1`, `clean -fd`,
`submodule update --init --recursive --force`, `submodule foreach --recursive "git checkout -f; git clean -fd"`).

Then delete every stale prefix and build tree under `$DIST` (`out-*`, `et-build-*`). A reused CMake
cache is exactly what would paper over a CRT or kernel-set difference.

### Step 3 — build /MD (`windows-x86_64`)

Driver `step3-build-md.ps1`, invoked per **Execution model**. Its body, with `$Dist`/`$EtSrc` from
parameters and absolute paths throughout:

```powershell
Set-Location $Dist
& "$Dist/build-runtime.ps1" "$Dist/build-runtime.sh" --variant logging `
    --prefix "$Dist/out-md" --et-src $EtSrc --build-dir "$Dist/et-build-md" `
    --platform windows-x86_64
```

Backtick continuations are safe *here* because this is a staged file, not a string passed through
ssh. The driver launches this detached, tees to `$Dist/spike-md.log`, and appends a sentinel with the
exit code; poll with `ssh winbox 'Get-Content -Tail 40 <dist>/spike-md.log'`.

The cheap one first: if optimized kernels break MSVC at all, they break here, and /MT would tell us
nothing new.

Answers Q1a. Also **count C4530 warnings** — `ADD_EXCEPTION_BOUNDARY`
(`tools/cmake/Codegen.cmake:205`) emits `try`/`catch` in the registration TU and ET adds `/EHsc`
only for pybind targets, so the warning is expected. Non-fatal (no `/WX`), but the count decides
whether the eventual PR should scope `/EHsc` the way the vendored OpenVINO patch does.

Watch the patch phase: `applied` on a pristine tree, `already patched` on the second build.

### Step 4 — assert the install

In `$DIST/out-md/lib`, expect the seven new archives (`optimized_native_cpu_ops_lib`,
`optimized_{kernels,ops_lib,portable_kernels,portable_ops_lib}`, `cpublas`, `eigen_blas`) in their
MSVC `.lib` spelling, and `optimized_native_cpu_ops_lib` present as an exported target in
`lib/cmake/ExecuTorch`. An installed archive with no export entry would leave
`test/openvino/CMakeLists.txt`'s `if(TARGET ...)` false and make Step 9 vacuous.

### Step 5 — assert the Eigen licence shipped

Confirm the #45 passthrough fires on Windows now that `eigen_blas` is present. A missing licence
here is a hard compliance failure, not a warning.

### Step 6 — build /MT (`windows-x86_64-static`)

Driver `step6-build-mt.ps1`, identical to Step 3's but with `--prefix "$Dist/out-mt"`,
`--build-dir "$Dist/et-build-mt"`, `--platform windows-x86_64-static`, logging to `spike-mt.log`. Separate build dir on purpose: the two flavours differ only in
`CMAKE_MSVC_RUNTIME_LIBRARY`, the one difference a shared cache would hide. Answers Q1b — the
combination nobody has compiled.

### Step 7 — package + CRT scan

Driver `step7-package.ps1`. The bash body goes in a **staged `.sh` file** (`step7-package.sh`,
scp'd alongside) rather than an inline `-Command` string — that is what removes the third quoting
layer. The driver is then just:

```powershell
Set-Location $Dist
& "$Dist/build-runtime.ps1" "<staging>/step7-package.sh"
exit $LASTEXITCODE
```

and the staged bash, which runs under Git-Bash in the dev shell with cwd `$Dist`:

```bash
set -euo pipefail
. scripts/lib/configure-base.sh
for p in windows-x86_64:out-md windows-x86_64-static:out-mt; do
  plat="${p%%:*}"; dir="${p##*:}"
  ./scripts/package.sh --prefix "$PWD/$dir" --etver 1.4.1 --variant logging \
     --platform "$plat" --package-tag v1.4.1-1 --outdir "$PWD/dist" --toolchain msvc-2022
  ./scripts/check-windows-crt.sh "$PWD/$dir" "$(crt_for_platform "$plat")"
done
```

`check-windows-crt.sh` takes the **CRT value**, not the platform — derive it from
`crt_for_platform`, as `release.yml:226` does. This is the step that would catch an `eigen_blas` or
`cpublas` object built against the wrong CRT; the linker demonstrably will not.

Record `TOTAL=` from each scan — it should rise by the number of new archives — and the tarball
size delta versus the published v1.4.1-1 Windows assets. That is the cost side of the trade.

### Step 8 — relocatability on both tarballs

Same shape as Step 7: a staged `step8-reloc.sh` run through `build-runtime.ps1`.

```bash
set -euo pipefail
for plat in windows-x86_64 windows-x86_64-static; do
  ./test/relocatability-windows.sh "$PWD/dist/executorch-runtime-1.4.1-logging-$plat.tar.gz" "$plat"
done
```

Runs on the packaged bytes, so it also catches a staging fault (a new `lib/cmake` export not
packaged). Native C++ probe: `test/consumer/probe.cpp`. Expected: unchanged pass.

### Step 9 — the OpenVINO probes (the point of the spike)

Vendor the bundle and download the published fixtures rather than minting them — the AOT venv
(`executorch` python built from the pinned source, plus nncf) is not worth standing up on Windows
for a spike:

Staged `step9-openvino.sh`, resolving the bundle stem from the SSOT rather than spelling it out
(`extras-gate.yml:640-647` does the same, and for the same reason — `OV_VERSION` moves):

```bash
set -euo pipefail
. ./scripts/lib/openvino.sh
stem="$(ov_asset_stem windows-x86_64)"
./scripts/vendor-openvino.sh --platform windows-x86_64 --out "$PWD/ovstage-win"
./test/openvino_smoke-windows.sh "$PWD/ovstage-win/$stem"
./test/openvino_fixture_run-windows.sh "$PWD/out-md" "$PWD/ovstage-win/$stem" "$PWD/ovfixtures"
```

Fixtures are fetched beforehand into `$Dist/ovfixtures` (`gh release download v1.4.1-1 -p
'etnp-openvino-fixtures-1.4.1-*.tar.gz'`, extracted flat). The bundle vendoring needs
`requirements/openvino-runtime.txt` installed, as the gate's pwsh step does.

Acceptance, all three required:
1. The smoke gate passes unchanged (control — it never touches the ET prefix).
2. The configure log reads **`ov_runner kernels: optimized_native_cpu_ops_lib`**, not
   `portable_ops_lib`. If it still says portable, Step 4's export assertion was wrong and the rest
   of this step proves nothing.
3. `ov_runner` links, runs the fixture `.pte` through the delegate, and still matches the eager
   golden. A mismatch would mean the optimized kernel set changed numerics on a path the delegate
   falls back to — the single most valuable thing this spike can find.

Repeat 2-3 against `$DIST/out-mt` if /MD is green; the link surface differs by CRT.

### Step 10 — report

Findings go two places: appended to this note as a `## Findings` section (commit 1, cherry-picked
onto a `docs/` branch and opened as a PR to `main`), and summarised as a comment on issue
#46 — build result per CRT, C4530 count and the `/EHsc` recommendation, installed-lib and tarball
size deltas, and the three OpenVINO acceptance results. Then delete the local
`spike/windows-optimized-ops` and its winbox copy, taking the throwaway flag commit with them. The real change — one flag plus the test/doc fallout table already
enumerated in the issue — is a separate bounded task.

## What this spike does not cover

- Linux. Unchanged by the flag; the existing gates cover it.
- `bare` / `devtools`. Windows ships `logging` only.
- Extras. `build-runtime.sh:240` skips phase 2 on Windows.
## Findings

**Answer to Q1a: NO — the combination does not compile under MSVC at our pin.** Stopped at Step 3
per the procedure ("a failure at Step 3 or 6 **is** the finding — stop and report"). Steps 4–9 did
not run; Step 6 (/MT) was not attempted because the failure is a language-standard compile error,
independent of `CMAKE_MSVC_RUNTIME_LIBRARY` (the plan's own guidance: "if optimized kernels break
MSVC at all, they break here").

### The failure (Step 3, `windows-x86_64`, /MD)

Configure passed with the spike flag set (verify: `--print-flags` → `KERNELS_OPTIMIZED=ON` present,
`KERNELS_QUANTIZED` absent). Build reached 711/1620 targets, then:

```
kernels/optimized/blas/BlasKernel.cpp   FAILED: [code=2]
torch\include\c10\util\StringUtil.h(169): error C7555: use of designated initializers requires at
least '/std:c++20'
```

- The TU compiles with `-std:c++17 -MD /EHsc`; torch 2.13.0+cpu include dirs come first on the
  command line. `BlasKernel.cpp` includes `<ATen/cpu/vec/vec.h>`, `<ATen/cpu/vec/functional.h>`,
  `<c10/util/Unroll.h>`, `<c10/util/irange.h>` — it is a port of PyTorch's
  `ReducedPrecisionFloatGemvFastPathKernel.cpp`.
- The installed `torch==2.13.0+cpu` `StringUtil.h:169` reads
  `return {.function = function, .file = file, .line = line};` — designated initializers. **Issue
  #46's rebuttal is wrong for the pinned torch**: its claim that "in current torch [it] is
  positional… no designated initializer left to trip on" does not hold at `torch==2.13.0+cpu`. The
  spike measured exactly finding 3's C7555, at the current pin, against a fresh install of the
  pinned torch (installed by `build-runtime.sh:203`, not the stale `.venv`).
- Toolchain: MSVC 19.51.36252.0 (VS 18/2026, MSVC 14.51.36231), cmake 4.3.1-msvc1, ninja 1.13.2,
  Python 3.12.10 (store Python), torch 2.13.0+cpu.
- C4530 count: **37** in the partial build. Kernel TUs already compile with `/EHsc` at this pin
  (measured on the `BlasKernel.cpp` command line), so the plan's "/EHsc scoping" question is
  answered: the scoping precedent from the vendored OpenVINO patch is not needed for the kernel
  targets; 37 C4530s came from other TUs before the build stopped.
- Q1b (/MT): not run, per above.

### What the follow-up task inherits

- The likely mechanism behind "upstream CI is green": our configure installs torch and its include
  dirs win over ET's portable c10 shim, so `c10/util/Unroll.h` and the ATen vector headers resolve
  to torch's C++20-requiring copies. Upstream's kernels-only CI may not install torch at all.
  [INFERENCE] A fix path (raise the kernel TUs to `/std:c++20`, or scope the torch include set, or
  point c10 at ET's shim) is issue #46's bounded task, not this spike's.
- Baseline observations that would otherwise have been Step 9 context: the published v1.4.1-1
  Windows tarball ships **no OpenVINO delegate** (`openvino_version=n/a`, no `openvino_backend.lib`;
  the OV Windows port landed after the release), so the fixture gate against it fails Stage 2 with
  `Backend OpenvinoBackend is not registered` — baseline STATUS line was
  `ov_runner kernels: portable_ops_lib` as expected. The bundle-only smoke gate passes on winbox.

### Execution-model notes for the next Windows spike

- `Start-Process` children die when the ssh session exits on winbox. Hold the ssh open for the
  build's duration (workstation-side `async`) and `Tee-Object` to a log; do not detach.
- `pwsh -File` command-line args that start with `--` clash with pwsh's own parameters; put flags
  in staged `.ps1`/`.sh` files, invoked through `&` or `build-runtime.ps1` with one positional arg.
- The flag edit must be verified as a full-string diff, not just "new flag present": the first
  bundle carried a flag string that had lost a `-D` prefix (authoring error), which `cmake`
  rejected at configure; fixed and re-bundled (tip-hash check caught the stale side).
