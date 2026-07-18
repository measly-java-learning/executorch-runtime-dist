# Spike: static-CRT (`/MT`) Windows build — propagation go/no-go

**Throwaway.** Not part of the product (`spike/` per CLAUDE.md). It touches **no** product file — it
sources the real flag SSOT (`scripts/lib/*.sh`) and reuses `test/consumer`, so a clean result here
faithfully previews the shipping recipe.

## Why this exists

Serving both a Python consumer (wants `/MD`, matches CPython) and a JNI-on-locked-down-Windows
consumer (wants self-contained `/MT`, no VC++ redist) means **two** Windows artifacts — static libs
bake the CRT into every object, so one artifact can't serve both. The planned encoding is a
`windows-x86_64-static` **platform suffix** (Approach A), which reuses every existing seam (naming,
packaging, filesystem pin discovery, the pin `.cmake`'s platform-keyed selection).

That whole design rests on **one unknown**: does `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`
propagate through ET **and every third-party subproject** (XNNPACK, pthreadpool, cpuinfo,
flatcc/flatc, pcre2, tokenizers) to yield a coherent **all-`/MT`** install — or does one of them
hardcode `/MD` and force us to carry source patches? This spike answers exactly that.

## Prerequisites (winbox)

- Visual Studio (MSVC) — activate with `Launch-VsDevShell.ps1 -Arch amd64 -SkipAutomaticLocation`.
  This puts `cmake`, `ninja`, `cl`, and `dumpbin` on PATH.
- An ExecuTorch checkout **with submodules** at the target ET tag.
- A Python with `torch` + `pyyaml` (the project `.venv` used for the existing Windows build). ET
  codegen needs it; the artifact stays torch-free. **Pass it explicitly via `--python`** — see below.
- Run all scripts through **Git-Bash** (`"$env:ProgramFiles\Git\bin\bash.exe"`), not WSL bash.

## Python vs. the VS dev shell — don't fight over PATH

You do **not** need to activate the venv at all, and you should not have to sequence it against the
dev shell. Pass the interpreter by absolute path:

```powershell
--python C:/Users/cored/workspace/executorch-runtime-dist/.venv/Scripts/python.exe
```

The scripts pin cmake to exactly that interpreter (`-DPython3_EXECUTABLE=...`, the same thing
`build-runtime.sh` does on Windows) and never consult PATH for it, so dev-shell and venv env vars
can't shadow each other. `build-mt.sh` echoes which interpreter it pinned and warns early if
`pyyaml` isn't importable from it (otherwise you'd fail deep in `gen_oplist.py`).

If you'd rather activate the venv anyway, the ordering facts are:

- **Activate the VS dev shell first, then the venv.** venv activation only *prepends* `Scripts\` to
  `PATH` and sets `VIRTUAL_ENV` — it does **not** touch `INCLUDE` / `LIB` / `LIBPATH` /
  `VCINSTALLDIR`, so the MSVC environment survives intact. The reverse order also works
  (`Launch-VsDevShell` merges rather than wipes), but there's no reason to take the risk.
- **Invoke Git-Bash non-login** (`bash script.sh`, never `bash -l`). A login shell re-runs
  `/etc/profile` and reorders the inherited PATH — the exact gotcha `release.yml` already documents
  for the Windows build steps.
- Always use `-SkipAutomaticLocation` on `Launch-VsDevShell.ps1` so it doesn't change your CWD.

## Known gotcha: cmake picks the x86 toolchain on a normal VS workstation

**Symptom:** the build dies deep inside `flatcc_ep` with `unresolved external symbol __aulldiv` /
`_mainCRTStartup` and a wall of `LNK4272: library machine type 'x64' conflicts with target machine
type 'x86'`.

**Cause:** with no standalone cmake installed, `cmake` resolves to the **VS-bundled** one
(`Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin`). Invoked bare, it runs its own MSVC
discovery instead of taking `cl` from the dev-shell PATH, and defaults to the `Hostx86\x86`
toolchain — a silent 32-bit configure, even though `VSCMD_ARG_TGT_ARCH=x64` and the `cl` on PATH is
x64. CI never hit this: the GitHub runner ships a standalone cmake that wins PATH precedence.

**Handled:** `build-mt.sh` now pins `-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl`, guards the dev
shell's target arch up front, and asserts the resulting cache is x64 before building.

> `build-runtime.sh` (the product recipe) does **not** pin the compiler and is exposed to the same
> silent-32-bit configure on any machine without a standalone cmake. Tracked separately.

**If you already hit it, clean before retrying** — cmake never re-detects a cached compiler, and
flatcc builds *in-source* so its x86 debris survives a fresh build dir:

```bash
spike/mt-crt/clean.sh --et-src C:/Users/cored/workspace/executorch \
                      --build-dir C:/Users/cored/et-build-mt-logging          # dry run
spike/mt-crt/clean.sh --et-src ... --build-dir ... --yes                       # actually delete
```

Unrelated trap worth knowing: in Git-Bash, `link` resolves to GNU coreutils `/usr/bin/link`, not
MSVC's `link.exe`. cmake uses `CMAKE_LINKER` so it isn't affected, but don't rely on bare `link`.

## Run it (one shot)

```bash
# inside an activated VS dev shell, via Git-Bash:
"$env:ProgramFiles\Git\bin\bash.exe" spike/mt-crt/run-all.sh \
  --et-src   C:/Users/cored/workspace/executorch \
  --prefix   C:/tmp/out-mt \
  --python   C:/Users/cored/workspace/executorch-runtime-dist/.venv/Scripts/python.exe
```

`run-all.sh` chains the three steps and prints a single **GO / NO-GO** line. Or run them individually:

| Step | Script | What it proves |
|------|--------|----------------|
| 1 | `build-mt.sh --et-src <et> --prefix <out>` | ET + all deps **configure/build/install** under `/MT` (exit 0). Uses the exact validated Windows flat flags + the CRT knob; applies the flatc `.exe` byproduct patch idempotently. |
| 2 | `check-crt.sh <out> MultiThreaded` | **The definitive check.** `dumpbin /directives` every installed `.lib`; PASS iff none requests `MSVCRT`/`MSVCPRT` (a `/MD` leak). Names any offending lib. |
| 3 | `consume-mt.sh <out> MultiThreaded` | End-to-end: the `test/consumer` SHARED probe links with a **matching-`/MT`** consumer — no `LNK4098`/`LNK2005`. |

## Reading the result

- **GO** — all three pass ⇒ propagation is clean, Approach A is viable, we proceed to the spec. The
  eventual product change is small: a CRT flag keyed on the platform string in `configure-base.sh`,
  a second matrix entry, and threading the CRT into the relocatability smoke.
- **NO-GO** — step 2 names libs requesting `MSVCRT` while we asked for `/MT` (or step 3 fails to
  link) ⇒ some subproject hardcodes `/MD`. Capture the lib names / linker errors; that's the size of
  the upstream/patch burden, and likely the "pull the plug, wait for a hard request" signal.

### Sanity baseline (optional)

Run the same three against the current default to confirm the harness itself is sound:
`run-all.sh --crt MultiThreadedDLL --prefix C:/tmp/out-md` should be GO (that's today's `/MD` build).

## Optional, unrelated: clang-cl vs optimized kernels (edge 2)

`probe-clangcl-optimized.sh` is a **separate** near-zero-cost datapoint for the *deferred* optimized-
kernels question — does `clang-cl` compile the `optimized`/`quantized` kernels that `cl` rejects? It
does **not** gate the CRT design. Run only if you want the extra signal while already on winbox:

```bash
"$env:ProgramFiles\Git\bin\bash.exe" spike/mt-crt/probe-clangcl-optimized.sh \
  --et-src C:/Users/cored/workspace/executorch --build-dir C:/tmp/et-clangcl
```
