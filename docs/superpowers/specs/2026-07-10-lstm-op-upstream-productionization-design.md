# Design: Productionize `etnp::lstm.out` in `executorch-runtime-dist`

**Date:** 2026-07-10
**Status:** Accepted (design); ready for implementation planning.
**Repo:** `executorch-runtime-dist` (Repo A — builds the relocatable ExecuTorch
library + ships the hash-pinned tarball).
**Derives from (read these first):**
- `docs/lstm-op-delivery-strategy.md` — the decision record (Decisions 1 & 3 are what this
  design executes).
- The shim's executable handoff:
  `/home/corey/workspace/executorch-numpy-runtime/docs/superpowers/specs/2026-07-09-upstream-lstm-productionization-handoff.md`
  — the four faces, the critical gotchas (A–E), and the exact source files to port.

**Source to port from** (`SRC = /home/corey/workspace/executorch-numpy-runtime`, valid at
commit `95a5efd`; the LSTM example files live only on branch `feature/lstm-sequence-kernel` —
resolve any reference with `git -C $SRC show 95a5efd:<path>`).

The MVP performance probe passed (custom op wins on `.pte` size at every config, wins on speed
at every benchmarked `(T,H)`, and exports shapes the naive decomposition cannot complete). This
is the go-signal to move the op into its permanent home.

## Objective / definition of done

Ship `etnp::lstm.out` inside **every variant** of the relocatable tarball so every consumer of
the tarball gets it registered at load time, **and** provide the AOT definition plus a **live**
torch round-trip test that proves export→lower→run matches `torch.nn.LSTM` at rtol/atol 1e-4.
Concretely:

1. The runtime kernel compiles into a shipped static archive, is whole-archived by consumers,
   and its registrar TU is guarded so it cannot be dropped at link.
2. The op is **always-on in every variant**; the namespace **stays `etnp::lstm.out`** (baked
   into every `.pte` that uses it — do not rename). Strategy Decision 1.
3. A **live** torch test exports an `nn.LSTM`, lowers it through the custom op, runs it against
   the built library, and compares to torch eager at rtol/atol 1e-4. This **replaces** the MVP's
   committed-golden-header workaround (which only existed because the numpy repo is torch-free).
4. The op follows a documented per-op **`extras` bundle** layout (four faces), as extra #1 / the
   template. **Build the convention, not a framework** (strategy Decision 3).

## Architecture

The tarball today is a **pure ExecuTorch build**: `build-runtime.sh` runs `cmake -S $ET_SRC`,
`cmake --install` into a prefix, then `package.sh` stages the C2 members (`lib/`, `include/`,
`LICENSE`, `THIRD-PARTY-NOTICES/`, `BUILDINFO`) into the tarball. There is **no** existing
kernel-packaging seam here (unlike the shim's `Kernels.cmake`).

We add a standalone **`extras/` build step layered *after* the ET install** — not injected into
ET's cmake and not patched into ET source. This keeps zero coupling to ET internals and lets the
extras directory own its own build.

### The `extras/` directory (LSTM is extra #1 / the template)

```
extras/
  lstm/
    extra.yaml            # manifest: op name, canonical schema (single source of truth), variants: [all]
    runtime/              # Face 1 — torch-free C++ (ported from shim @ 95a5efd)
      etnp_lstm.cpp        boxed registrar (3 mutable outputs -> hand-rolled trampoline)
      lstm_cell.h  lstm_cell.cc     Highway-SIMD fused cell update
      xnn_linear.h  xnn_linear_cache.h
      CMakeLists.txt       builds libetnp_ops_lstm.a; links prefix XNNPACK + fetched Highway
    aot/                  # Face 3 — Python + torch
      etnp_lstm_op.py      torch.library def; schema read from ../extra.yaml
    test/                 # Face 4 — mandatory live round-trip
      test_lstm_roundtrip.py
  CMakeLists.txt          # globs each op dir, builds its .a, installs into the prefix
```

### Build flow (per variant, inside manylinux)

1. Build ET → install prefix (unchanged).
2. **New:** the `extras/` CMake project globs each op dir, compiles its `.a`, and installs into
   the prefix: `lib/libetnp_ops_lstm.a`, `include/etnp/lstm.h`, and a sibling cmake fragment
   `lib/cmake/ETNPExtras/ETNPExtras.cmake`.
3. `package.sh` tars the prefix as today — the new members ride inside the existing C2 layout.
   `package.sh` staging is extended to include the new `lib/`, `include/etnp/`, and
   `lib/cmake/ETNPExtras/` members.

### Face 2 — op schema / name as single source of truth (the "nastiest failure" guard)

Op-name/schema drift across C++ and Python is the worst failure mode (exports fine → op-not-found
at runtime). The canonical schema strings live **once** in `extra.yaml`:

```
lstm(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
     Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor)
lstm.out(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
         Tensor? b_ih, Tensor? b_hh, *,
         Tensor(a!) output, Tensor(b!) hn, Tensor(c!) cn)
         -> (Tensor(a!), Tensor(b!), Tensor(c!))
```

The Python AOT reads them for `_lib.define(...)`; a small generate step emits a C++ header
carrying the op-name string the registrar uses. The build **fails** if the generated header
drifts from `extra.yaml`.

### Dependencies

- **XNNPACK — free from the built prefix.** Verified: the prefix already ships `libXNNPACK.a`,
  `libpthreadpool.a`, `libxnnpack_backend.a`, and the public headers `xnnpack.h` /
  `pthreadpool.h` under `lib/` + `include/`. The extras target links straight against the prefix.
- **Highway 1.4.0 — fetched/pinned by the extras CMake** (SHA256
  `e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c`), since ET does not vendor
  Highway. The fused cell update (`lstm_cell.cc`) uses Highway dynamic SIMD dispatch.

### Scope of the supported op (do not widen)

Single-layer, unidirectional, `batch_first=False`, float32, contiguous. `input [T,B,I]`,
`h0/c0 [B,H]`, `w_ih [4H,I]`, `w_hh [4H,H]`, optional biases `[4H]`; `output [T,B,H]`,
`hn/cn [B,H]`. **Gate row order i,f,g,o** (PyTorch).

## Face 1 — runtime kernel, linking & the whole-archive guard

**Port, don't rewrite** (from shim @ `95a5efd`):

- **Registrar stays boxed.** The op has 3 mutable outputs (`output, hn, cn`); the pinned
  runtime's `extension/kernel_util/make_boxed_from_unboxed_functor.h` `static_assert`s
  `num_nonconst_tensors == 1`, so the auto-unboxing macro rejects three outputs. Keep the
  hand-rolled `lstm_boxed(KernelRuntimeContext&, Span<EValue*>)` trampoline +
  `register_kernel(Kernel("etnp::lstm.out", lstm_boxed))`. Task 1 **re-verifies** the cap against
  *our* ET version; boxed is version-robust either way, so we keep it unless there's a reason not
  to (Gotcha A).
- **XNNPACK FC helper** (`xnn_linear.h` + `xnn_linear_cache.h`) and the **Highway fused cell**
  (`lstm_cell.{h,cc}`) port verbatim. Read `xnn_linear_cache.h`'s safety comment before porting
  (process-wide packed-operator cache: pointer+dims key, content fingerprint, LRU 16, per-entry
  run mutex) (Gotcha B).
- The kernel uses `ctx.allocate_temp` for a `T·B·4H` float scratch buffer, so any direct-invoke
  harness must construct `KernelRuntimeContext` **with a temp allocator** whose arena is sized for
  the largest `(T,B,H)` exercised (the shim used 4 MiB) (Gotcha D).

### The archive & its link contract

`extras/lstm/runtime/CMakeLists.txt` compiles the LSTM sources to `libetnp_ops_lstm.a` — a pure
static-initializer registration TU, exactly like `libxnnpack_backend.a`. Therefore:

1. It installs into the prefix `lib/` and is exposed by the sibling cmake fragment `ETNPExtras`
   as an imported target `etnp_ops_lstm` (with its include dir).
2. Consumers **must whole-archive it** at their final `.so`/executable link, or the registrar GCs
   away → "unregistered operator" at load. This failure is silent and load-time; the fix ships
   *inside* the tarball (below) rather than living as prose.

### Shipped whole-archive declaration (`ETNPExtras.cmake`)

The extras build installs `lib/cmake/ETNPExtras/ETNPExtras.cmake`, which:

1. **Defines the imported targets** — `etnp_ops_lstm` (the `.a`) with its include dir.
2. **Declares the whole-archive set** — `set(ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS etnp_ops_lstm)`,
   generated from the manifest, so future extras append automatically and consumers never edit a
   link line.
3. **Provides a helper** — `etnp_extras_whole_archive(<consumer_target>)` that wraps the set with
   the correct per-platform flags: `--whole-archive` (GNU ld/Linux), `-force_load` (macOS),
   `/WHOLEARCHIVE:` (MSVC/Windows).

**Scope: extras-only.** The fragment declares only our ops' archives — it does **not** enumerate
ET's own archives (`xnnpack_backend`, `portable_ops_lib`, …), which keeps us decoupled from ET's
per-version archive set. The consumer guide narrates that ET's backend/ops archives also need
whole-archiving per ET's own guidance.

### Generalized manifest guard (the nm-guard, generalized)

Port `assert_kernels_registered.cmake` from the shim. For each op in the manifest it computes the
expected registrar TU symbol (`_GLOBAL__sub_I_<basename>`) and asserts, via `nm` on the installed
`.a` after a whole-archive test link, that (a) **exactly one registrar TU per manifested op**
survived, and (b) **no duplicate op names** across extras. Runs POST_BUILD so a link-time drop
fails the build, not a consumer at runtime. The guard is **static** (host-side `nm`) so it runs
on every build target, including cross-compiled ones.

## AOT definition + the live round-trip test

### Face 3 — AOT definition (`extras/lstm/aot/etnp_lstm_op.py`)

Port the shim's `tools/etnp_lstm_op.py`. Proven recipe (Gotcha C): define **both** `lstm` and
`lstm.out` as `CompositeExplicitAutograd` + a `register_fake`; `to_edge_transform_and_lower`
**without** a partitioner keeps the op opaque; ET's `ToOutVarPass` (inside `.to_executorch()`)
rewrites it to `etnp::lstm.out` automatically. Verified to yield a `.pte` containing exactly
`['etnp::lstm.out']`. The one change from the shim: schema strings are **read from `extra.yaml`**,
not hardcoded.

### Face 4 — live round-trip test (`extras/lstm/test/test_lstm_roundtrip.py`)

Mandatory. Torch is a first-class dependency here, so this **replaces** the shim's committed
golden workaround (`gen_lstm_golden.py` → `lstm_golden.h` → `lstm_parity_test.cpp`). End to end:

1. Build an `nn.LSTM` (the supported shape) in torch; capture eager output.
2. Import the AOT def; `export` → `to_edge_transform_and_lower` (no partitioner) →
   `.to_executorch()` → tiny `.pte`.
3. Run that `.pte` against the **just-built library**.
4. Compare to eager at **rtol/atol 1e-4** (shim saw max|diff| ≈ 1.5e-7).

**Runner: a tiny C++ runner** built against the tarball prefix, whole-archiving `etnp_ops_lstm`
(+ `xnnpack_backend`) via the shipped `etnp_extras_whole_archive()` helper, then `Module::load` +
`execute`. This is chosen over ExecuTorch's Python `pybindings` deliberately: pybindings would
exercise ET's pip-wheel runtime, **not our tarball**. The C++ runner is the **first real exercise
of the shipped consumer contract** — it proves the whole-archive fragment and the guard work end
to end, not merely that the `.a` compiles.

### CI placement and cross-platform scope

The test needs torch (already pip-installed during `build-runtime.sh`) + a built prefix, so it
slots into qa-gate after the build. The two halves of validation scale differently:

- **Numerical parity** (kernel matches eager at 1e-4) is **architecture**-sensitive (Highway SIMD
  dispatch + XNNPACK microkernels differ across x86_64 / aarch64 / Apple arm64), not
  OS-sensitive, and is variant-independent.
- **The consumer contract** (whole-archive + link + `Module::load`/`execute`) is
  **OS/toolchain**-sensitive (the per-OS whole-archive flags above).

Therefore:

- **The static manifest/nm guard runs on every `(variant, platform)` build** — cheap, host-side,
  including cross-compiled targets.
- **The live round-trip *executes* a binary**, so it runs only where the target can actually run.
  Today: `logging/linux-x86_64` (one representative build; the op is variant-identical). Run it on
  `linux-aarch64` too **if** that runner executes natively/under QEMU (Task 1 confirms; a
  build-only/cross-compiled target runs the guard but not the round-trip).
- **Revisit when macOS / Windows / arm64 gain runners** — each new *executable* OS/arch target
  should run the round-trip, since the per-OS whole-archive path is exactly what it validates. The
  consumer guide records this so it is not lost.

## Task breakdown

1. **De-risk spikes** (no production code; output a findings note): (a) check our ET version's
   `make_boxed_from_unboxed_functor.h` for the `num_nonconst_tensors == 1` cap; (b) confirm the
   prefix exposes XNNPACK headers+`.a` (already verified) and settle the Highway 1.4.0 fetch;
   (c) confirm whether the aarch64 CI runner executes or is build-only.
2. **`extras/` skeleton + manifest** — `extra.yaml` (name, canonical schema, `variants: [all]`),
   glob-driven `extras/CMakeLists.txt`, schema→C++ header generate step. Assert the manifest
   parses and the header is byte-identical to the schema source.
3. **Port Face 1 (runtime kernel)** — `etnp_lstm.cpp` (+ boxed trampoline), `lstm_cell.{h,cc}`,
   `xnn_linear*.h`; wire XNNPACK-from-prefix + Highway fetch → `libetnp_ops_lstm.a`. Port a
   direct-invoke kernel unit test (temp-allocator arena sized for the largest `(T,B,H)`).
4. **Generalized manifest guard** — port `assert_kernels_registered.cmake`; one registrar TU per
   manifested op survives whole-archive, no duplicate op names; wire POST_BUILD.
5. **`ETNPExtras.cmake` install + whole-archive helper** — imported target,
   `ETNP_EXTRAS_WHOLE_ARCHIVE_LIBS`, `etnp_extras_whole_archive()` (per-OS wrapping). Extend
   `package.sh` staging to include the new `lib/`, `include/etnp/`, `lib/cmake/ETNPExtras/`
   members.
6. **Face 3 (AOT)** — port `etnp_lstm_op.py`, schema read from `extra.yaml`.
7. **Face 4 (live round-trip) + C++ runner** — build the runner against the prefix using the
   shipped helper; export→lower→run→compare at 1e-4. Mandatory/gating.
8. **CI wiring** — static guard on every `(variant, platform)`; round-trip on each executable
   target (today `logging/linux-x86_64`, + aarch64 if it executes).
9. **Docs + tarball re-roll** — new `docs/lstm-op-consumer-guide.md` (op name/schema, always-on,
   whole-archive-via-helper, per-OS note, the benchmark envelope from the handoff); surface the
   new **Google Highway 1.4.0** dependency in the **top-level project docs** (`README.md`) in
   addition to the consumer guide, since it is now a build/ship dependency. Note the existing
   `build-runtime.sh` license passthrough only scans ET's `third-party/`/`backends/` dirs, so
   Highway's LICENSE must be added to `THIRD-PARTY-NOTICES/` explicitly (the extras build fetches
   Highway, ET's tree does not) — wire this where the extras Highway fetch lands (Task 5). Then
   `BUILDINFO` / `pkgrev` bump; cut the new tarball.

## Testing strategy

- **Kernel unit test** (Task 3) — direct invoke with a temp allocator; correctness of the ported
  kernel in isolation.
- **Static manifest/nm guard** (Task 4) — every build; registrar TU survives, no name collisions.
- **Live torch round-trip** (Task 7) — gating; export→lower→run→compare at 1e-4 via the C++
  runner against the built tarball.
- **Existing `test/*.sh`** (C2 layout, relocatability, packaging) — extended to assert the new
  tarball members (`libetnp_ops_lstm.a`, `include/etnp/lstm.h`, `lib/cmake/ETNPExtras/`) are
  present and relocatable.

## Error handling — a convention that cannot silently rot

The build **fails** (not warns) if any of these hold: a manifested op's registrar TU is missing
post-link; two ops collide on name; an extra lacks a test; or the generated schema header drifts
from `extra.yaml`. These are the self-verifying guarantees that let "convention over framework"
be safe with a single op.

## Explicitly out of scope (Do-NOT)

- Do **not** rename the op or change the schema (`.pte` permanence).
- Do **not** widen beyond single-layer / unidirectional / `batch_first=False` / float32 (the
  "bulletproof full `nn.LSTM`" was deliberately cut).
- Do **not** build a plugin *framework* yet — LSTM is extra #1; a glob + convention now, formalize
  a manifest/codegen only after ops #2–3 reveal the abstraction.
- Do **not** port the throwaway MVP bench/feasibility/advisor tooling as production code — it is
  *evidence*, not a deliverable (and the advisor's speed heuristics are stale pre-restructure
  calibration).
- Do **not** edit `docs/handover-to-engine.md` (a frozen contract for a different work item) — the
  new `docs/lstm-op-consumer-guide.md` is the self-contained consumer contract for this op.
- The numpy-runtime follow-up (pin bump + torch-free consumer smoke test) is strategy Decision 2
  and belongs to that repo — out of scope here.
