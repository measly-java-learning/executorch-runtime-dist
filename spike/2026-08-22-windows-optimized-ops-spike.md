# Spike: `optimized_native_cpu_ops_lib` on Windows (issue #46)

**Status:** run; stopped at Step 3 — the /MD build fails to compile, which is the finding. **Host:** `winbox` (VS 18 / MSVC 19.51, Ninja, cmake, Git-Bash).
**Type:** throwaway. Nothing built here ships; the flag edit lives on a scratch branch.
**Cleanup is deferred, not immediate** — on a failing run nothing is deleted until the follow-up
task that consumes the finding is done with it. See *Afterwards* below.

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

**The spike branch never reaches `origin`.** It is created locally and carried to winbox as a
`git bundle` over scp. It is deleted only after a *green* run; a failing run keeps it (see
*Afterwards*). This repo is public, and commit 2 below
is explicitly throwaway — publishing it, even briefly, buys nothing. (Pushing would not trigger CI:
`unit.yml` is `pull_request` + `push: branches: [main]`, `extras-gate.yml` is `pull_request` only,
`release.yml` is `push: tags`. So CI is not the reason; visibility is.)

Branch `spike/windows-optimized-ops`, cut from `main` on the Linux workstation. Two commits, kept
separable because they have opposite fates:

| Commit | Content | Fate |
|---|---|---|
| 1 | this note (`spike/2026-08-22-windows-optimized-ops-spike.md`) | **kept** — landed directly on `main` under `spike/`, the tree CLAUDE.md designates for throwaway spike artifacts |
| 2 | the one-line `EXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON` edit to `scripts/lib/configure-base.sh` | **throwaway** — local only; the real change is a separate bounded task carrying issue #46's full test/doc fallout |

```bash
git checkout main && git pull --ff-only
git checkout -b spike/windows-optimized-ops
git add spike/2026-08-22-windows-optimized-ops-spike.md
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

Findings are appended to commit 1's file, which then lands on `main` under `spike/`. (A `docs/`
branch + PR was tried and declined: a spike's output is a finding, not a durable reference, so it
does not earn a review cycle or a place in `docs/`.) What happens next depends on the outcome, and
the two paths are deliberately different:

**Green run** — the local spike branch, commit 2 with it, is deleted; the winbox build trees,
prefixes, logs and staging dir are removed. Nothing else persists.

**Failing run — no cleanup.** Nothing is deleted: not the branch, not the build tree, not the
staging dir, not the logs, and *not* the patched `$ETSRC`. A compile failure is a finding whose
value is the reproduction, and every one of these is part of it:

| Kept | Why |
|---|---|
| local `spike/windows-optimized-ops` (both commits) | the exact tree that failed; a re-cut branch is not provably the same |
| `$DIST/et-build-md` (and `-mt` if reached) | holds `CMakeCache.txt`, `compile_commands.json`, and `.ninja_log` — the failing command line with its real include order is only recoverable from here |
| `$DIST/spike-*.log` | the full diagnostic text, including warning counts that a re-run may not reproduce |
| `$DIST/out-*`, even partially populated | shows how far the install got |
| `$ETSRC` **in its patched state** | do NOT re-run the pristine-ing from Step 2. The patch state is part of the repro, and reverting it destroys the ability to re-issue the exact failing compile by hand |
| the staging dir (drivers + bundle) | re-issuing one command against the failed tree is the cheapest diagnostic loop available |

These are released by whoever picks up the follow-up task, once they no longer need the
reproduction — not by the spike. Say so explicitly when reporting, so the next person does not
assume a clean host.

**Restarting after a fix.** Step 2's "delete every stale prefix and build tree" is written for a
first run and must not be applied blindly to a restart: rename the failed tree aside
(`et-build-md` → `et-build-md-fail-<n>`) rather than deleting it, so the before/after compile lines
can be diffed. Only delete it once the restart is green.

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

The two ET builds (Steps 3 and 6) run 15-25 minutes. **Do not detach them.** This was written the
other way round before the first run and is corrected here from measurement: `Start-Process`
children are killed when the ssh session exits on winbox, so a detach-and-poll driver loses the
build partway through. Instead hold one ssh call open for the build's duration — asynchronously on
the *workstation* side, so the agent is not blocked — with the driver piping through `Tee-Object` to
a log under `$Dist`. Poll that log with separate short ssh calls. Short steps (assertions,
packaging, gates) are ordinary foreground calls.

Two further mechanics, also measured during the first run:

- **Never pass `--`-prefixed flags on a `pwsh -File` command line.** They collide with pwsh's own
  parameter parsing. Flags belong inside the staged `.ps1`/`.sh` file, which is invoked with `&` or
  handed to `build-runtime.ps1` as a single positional argument. The `-Dist`/`-EtSrc` params below
  are single-dash and safe.
- **Verify a staged edit as a full-string diff, not a substring probe.** The first bundle carried a
  flag string that had silently lost a `-D` prefix — and recon of the surviving commit shows the
  loss landed on `EXECUTORCH_BUILD_EXTENSION_TENSOR`, an *existing* flag adjacent to the edit, not
  on the new one. A probe for the new flag therefore passed while an unrelated, previously working
  flag was corrupted. That is the failure mode a substring check cannot see, and `cmake` rejected
  the configure. The tip-hash check from *Transport to winbox* caught which side
  was stale, but only the full-string comparison identified what was wrong.

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

**On a restart after a failure, do not run this step as written** — rename the failed tree aside
instead of deleting it, per *Afterwards*. Blind-deleting it discards the only copy of the failing
compile command line.

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

Findings go two places: appended to this note as a `## Findings` section (commit 1, committed
directly to `main` under `spike/`), and summarised as a comment on issue
#46 — build result per CRT, C4530 count and the `/EHsc` recommendation, installed-lib and tarball
size deltas, and the three OpenVINO acceptance results.

Cleanup is conditional, per *Afterwards*: on a green run, delete the local
`spike/windows-optimized-ops` and its winbox copy, taking the throwaway flag commit with them. **On
a failing run, delete nothing** and state in the report that the branch, build trees, logs and the
patched `$ETSRC` are all still in place for the follow-up. The real change — the flag plus the
test/doc fallout enumerated in the issue — is a separate bounded task.

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

### Host state after the run (recon 2026-08-22)

Recorded from a read-only sweep of winbox after the spike, because the follow-up task will otherwise
assume the *Afterwards* retention policy was in force. **It was not — that policy was written after
this run.** What actually survives:

| Item | State |
|---|---|
| `$ETSRC` (`workspace/executorch`) | **Retained.** `v1.4.1`, working tree dirty with the OpenVINO + XNNPACK patches and `third-party/CMakeLists.txt` (patched 2026-08-22 14:47). The repro's source side is intact. |
| `$DIST` (`workspace/executorch-runtime-dist`) | Back on `main` at `5e3eaa3`. Branch `spike/windows-optimized-ops` **deleted**. |
| The two spike commits | **Recoverable from the reflog, not from any branch:** `babe493` (first tip, carrying the dropped-`-D` authoring error) and `f145a7e` (corrected tip — `main` plus exactly `-DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON`). Both still resolve; neither is protected from `gc`. |
| Build tree, `out-*` prefix, `spike-*.log` | **Gone.** No `CMakeCache.txt` newer than 2026-08-22 exists anywhere under `workspace`. |
| `AppData/Local/Temp/tmp.*` (2 dirs) | Leftovers from the OpenVINO baseline only — `probe.exe`, `smoke.blob`, `win_origin_probe.obj`, and a small consumer build tree. Nothing from the ET compile. |

**Consequence for the follow-up.** The diagnostic the include-ordering hypothesis needs — the actual
`cl` command line for `BlasKernel.cpp`, showing whether torch's include dirs precede ET's c10 shim —
lived in the deleted build tree's `compile_commands.json`. It cannot be read; it has to be
regenerated. The cheap way is a **configure-only** re-run at `f145a7e`: `cmake` writes
`compile_commands.json` at configure time, so the include order is recoverable without paying for
711 targets of compilation.

**Before anything else, protect the two SHAs.** They are reachable only through the reflog and will
be pruned eventually:

```bash
ssh winbox 'git -C <dist> tag spike/optimized-ops-final f145a7e;
            git -C <dist> tag spike/optimized-ops-firstcut babe493'
```

The second is worth keeping as well as the first: it is the only record of the `-D` corruption
described above.

### Re-run 2026-08-22 (second run) — failure reproduced, mechanism identified

Re-run from the recovered `f145a7e` (verified as `main` plus exactly one flag: 14 flags in, 15 out,
one added, none removed — the set comparison `babe493` would have failed). **Same failure, same
place:** `[593/1620] BlasKernel.cpp` → `C7555` at `torch/include/c10/util/StringUtil.h(169)`,
`ninja: build stopped`, rc=2. Q1a stays NO.

The re-run's purpose was the compile line, which the first run's deleted build tree had taken with
it. From `et-build-md/compile_commands.json`:

```
-IC:\...\site-packages\torch\include
-IC:\...\site-packages\torch\include\torch\csrc\api\include
-IC:\Users\cored\workspace\executorch\..
-IC:\Users\cored\workspace\executorch\runtime\core\portable_type\c10
... /EHsc -O2 -std:c++17 -MD -DET_BUILD_WITH_BLAS
```

Torch's include dirs do precede ET's c10 shim. **But the include-ordering hypothesis is still
refuted**, because reordering cannot fix this:

- `BlasKernel.cpp:17-20` includes `<ATen/cpu/vec/functional.h>`, `<ATen/cpu/vec/vec.h>`,
  `<c10/util/Unroll.h>` and `<c10/util/irange.h>` **unconditionally** — not behind any `#ifdef`.
- ET's shim (`runtime/core/portable_type/c10/c10/util/`) carries `irange.h`, `Half.h`,
  `BFloat16.h`, `complex.h` and friends but has **no `StringUtil.h` and no `Unroll.h`**, and no
  ATen tree at all.

So this TU genuinely requires real torch headers; `StringUtil.h` arrives transitively through them
and there is no other provider to reorder in front. `find_package_torch_headers()`
(`CMakeLists.txt:642`) is doing what it is supposed to. `-DET_BUILD_WITH_BLAS` comes unconditionally
from `kernels/optimized/CMakeLists.txt:33`.

**Why upstream's MSVC CI is green and ours is not — the discriminator is torch, not our configure.**
`.ci/scripts/setup-windows-msvc.ps1` sets no `/std:` flag and ET defaults `CMAKE_CXX_STANDARD 17`
(`CMakeLists.txt:116-117`), so upstream compiles this same TU at C++17 with `KERNELS_OPTIMIZED=ON`.
The only remaining variable is the torch whose headers are on the line: `2.12.0+cpu` has
`SourceLocation::current` returning positionally, `2.13.0+cpu` returns designated. Ours is pinned to
2.13.0.

That reframes the follow-up: this is not a defect in our Windows configure to be worked around, it
is **ET 1.4.1 + torch 2.13 being broken for `cpublas` under MSVC at C++17** — an upstream bug worth
reporting, alongside whichever local mitigation we choose (narrowly raising the `cpublas` target to
`/std:c++20` is the obvious candidate; note ET's own consumer contract, and ours, is C++17).

**Host state after this run — everything retained**, per *Afterwards*: branch
`spike/windows-optimized-ops` checked out at `f145a7e`, `et-build-md/` intact (with
`compile_commands.json` and `.ninja_log`), `spike-md.log` complete. No `out-md` — the install phase
was never reached. Tags `spike/optimized-ops-final` (`f145a7e`) and `spike/optimized-ops-firstcut`
(`babe493`) protect both commits from `gc`.

### Minimal repro — the defect is one torch header, not ExecuTorch

Isolated on winbox with disposable TUs that include a single torch header and nothing else: no
ExecuTorch, no ATen, no BLAS, no `find_package`. Compiled with `cl` at both standards
(`-DC10_USING_CUSTOM_GENERATED_MACROS -DNOMINMAX -EHsc`, torch 2.13.0+cpu include dirs only).

```
RESULT t_stringutil   c++17   rc=2 error C7555
RESULT t_stringutil   c++20   rc=0 ok
RESULT t_unroll       c++17   rc=0 ok
RESULT t_unroll       c++20   rc=0 ok
```

The whole failing program is two lines:

```cpp
#include <c10/util/StringUtil.h>
int probe_stringutil() { return 0; }
```

`Unroll.h` is innocent at both standards — it does not reach `StringUtil.h`. So the eventual
upstream report and any local mitigation both scope to `StringUtil.h` alone. The offending code,
read verbatim from the installed `torch==2.13.0+cpu`:

```cpp
static constexpr SourceLocation current(...) noexcept {
  return {.function = function, .file = file, .line = line};   // line 169
}
```

**Why Linux never sees this.** Designated initializers are C++20. GCC accepts them at `-std=c++17`
as an extension — verified locally, it compiles with only a `-Wc++20-extensions` warning and still
exits 0 even under `-pedantic`. MSVC rejects them outright (`C7555`, an error with no opt-out below
`/std:c++20`). That asymmetry, not anything about our configure, is the entire Linux/Windows
difference.

**Blast radius.** Any MSVC C++17 TU that includes `c10/util/StringUtil.h`, directly or
transitively, fails. `cpublas` is simply the first one our build reaches; it is not special.

**Conclusion.** This is an upstream defect in torch 2.13.0 — a header that PyTorch documents as
C++17-consumable requires C++20 under a conforming compiler. It is not an ExecuTorch bug, not a
defect in this repo's Windows configure base, and not fixable by include reordering. Options for
the follow-up, in preference order: report upstream and pin around it; or raise only the affected
target to `/std:c++20`, accepting a C++20-compiled archive inside an artifact whose consumer
contract is C++17.

### Upstream: pytorch/pytorch#193590 (already open)

Filed 2026-08-14 by an unrelated reporter, OPEN, `module: build` / `module: cpp-extensions` /
triaged, **no maintainer comment yet**. Same root cause, same torch 2.13.0, same two headers. Our
spike is an independent reproduction and does not need a new issue.

Their entry path is `nvcc -std=c++17` on a CUDA build; ours is plain `cl -std:c++17` with no CUDA
anywhere. Confirmed on winbox that **both** defects the issue names reproduce that way, with
distinct diagnostics — so they are two separate defects, not one cascading:

| Header | Line | MSVC error | Construct |
|---|---|---|---|
| `c10/util/StringUtil.h` | 169 | `C7555` | designated initializers |
| `c10/core/AutogradState.h` | 89, 90 | `C7582` | default member initializers for bit-fields |

What our data adds, should it be worth posting:

1. **Not nvcc-specific.** Plain MSVC `cl`, no CUDA, no `torch/extension.h` — a two-line TU including
   one c10 header. The issue currently reads as an nvcc-frontend problem; it is not.
2. **Not MSVC-version-specific.** They repro'd on 19.44 and 19.29; ours is 19.51 (VS 18/2026).
3. **A consumer class their analysis misses.** The issue explains the defect is normally masked
   because `torch/utils/cpp_extension.py` injects `/std:c++20` for MSVC. Cmake-based consumers that
   use torch *headers* directly — ExecuTorch's `find_package_torch_headers()`, and therefore this
   repo — never go through `cpp_extension.py` and get no such injection. That widens the blast
   radius beyond CUDA extension builds and strengthens their "a C++17-compatible header is the only
   clean path" argument.
4. **MSVC's diagnostics are the precise ones.** `C7555`/`C7582` name the exact construct and the
   required standard, unlike the "expected an expression" the nvcc frontend emits. Useful for
   anyone bisecting this.

**What it means for us.** The fix is upstream and not in our hands; the issue is unanswered, so no
timeline. `EXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON` on Windows stays blocked behind either an upstream
header fix, a torch pin that predates the regression (2.12 is positional — verified locally), or
raising the affected targets to `/std:c++20` against a C++17 consumer contract. Note that a
`StringUtil.h`-only upstream fix would **not** unblock us on its own if our build also reaches
`AutogradState.h`; that TU was not on the failing compile line, so whether we reach it is untested.

