# Expose XNNPACK workspace size for host-side memory accounting — Design

**Issue:** [#17](https://github.com/measly-java-learning/executorch-runtime-dist/issues/17)
**Consumer:** `measly-java-learning/djl-executorch-engine` (currently pinned at `v1.3.1-8`)
**Status:** design, not yet planned
**Verified against:** ExecuTorch `v1.3.1` (`e2f18eb`) and its vendored XNNPACK submodule

## Goal

Let a consumer read the byte size of the XNNPACK delegate's workspace arena at runtime, so
host-side native-memory reporting can account for it exactly instead of shipping a documented
lower bound.

## Background

`djl-executorch-engine` reports per-model native footprint. Two of its three components — the
planned activation arena and its own input staging buffers — are exact. The XNNPACK workspace is
the third and is currently unmeasurable from outside:

- `xnn_workspace_t` is opaque in the installed XNNPACK headers: `xnn_create_workspace` and
  `xnn_release_workspace`, no size accessor.
- ExecuTorch's `XNNWorkspace` wrapper exposes `acquire()` and `unsafe_get_workspace()`, neither
  of which yields a size.

An RSS-delta proxy was considered upstream of this design and rejected as misleading under
shared-workspace mode.

The byte count already exists in memory. `struct xnn_workspace`
(`backends/xnnpack/third-party/XNNPACK/src/xnnpack/subgraph.h:659`) is:

```c
struct xnn_workspace {
  void* data;
  size_t size;
  struct xnn_runtime* first_user;
  size_t ref_count;
};
```

`size` is the current arena allocation — a high-water mark set in `xnn_create_runtime_v4`, grown
and never shrunk. That is exactly the figure host-side accounting wants. Upstream XNNPACK has no
getter for it, so this is a vendored patch rather than a submodule bump.

## Architecture

Four additive source patches to the ExecuTorch/XNNPACK tree, applied by `build-runtime.sh`'s
existing patch phase, surfaced to consumers through the **already-installed** backend-options API.

```
xnn_workspace.size                          (exists)
  └─ xnn_get_workspace_size()               patch A — vendored XNNPACK
      └─ XNNWorkspace::size()               patch B — ET wrapper, lock-synchronized
          └─ XNNWorkspaceManager::total_workspace_size()   patch C — sums live workspaces
              └─ XnnpackBackendOptions::get_option("workspace_size_bytes")   patch D
                  └─ runtime::get_option("XnnpackBackend", …)   ALREADY INSTALLED
```

### Why the options API, and not installed headers

The issue's suggested shape was a size accessor on the `XNNWorkspace` wrapper surfaced through the
installed headers. That route is more work and is not necessary:

- **No `backends/` header ships today.** ET installs headers from an explicit per-directory list
  in its root `CMakeLists.txt` (`runtime/core/`, `runtime/executor/`, `runtime/kernel/`,
  `runtime/backend/`, `runtime/platform/`, `extension/*`). `backends/` is not in that list, and
  `backends/xnnpack/CMakeLists.txt:135` explicitly clears `PUBLIC_HEADER` on the XNNPACK target.
  Taking the header route means adding install rules for a new header chain.
- **Even installed, the consumer has no handle.** The workspace lives inside
  `XnnpackBackendOptions::workspace_manager()`, created during delegate init. The engine drives the
  backend purely through string-keyed options and includes no backend headers.
- **`runtime/backend/interface.h` is installed** and already declares the free function the engine
  needs:

  ```cpp
  Error get_option(const char* backend_name, Span<BackendOption> backend_options);
  ```

So the options route requires **zero** new installed headers and has no reachability problem. It is
also the mechanism the consumer already uses, which means no new integration pattern to document.

### The value type

```cpp
using OptionValue = std::variant<bool, int, std::array<char, kMaxOptionValueLength>>;
```
— `runtime/backend/options.h:26`

There is no `size_t` alternative. **Decision: report `int` bytes, saturating at `INT_MAX`.** A
workspace above 2 GiB is implausible for this use, but saturation is specified rather than left to
narrowing: a silently negative byte count in a memory report is worse than a clamped one. The
saturating behaviour is part of the documented contract, not an implementation detail.

#### Considered and rejected: patching `size_t` into `OptionValue`

Since this work already patches the ET tree, the obvious question is whether to append `size_t` to
the variant and report the byte count exactly. **Rejected: it is an ABI break, not a
layout-neutral append.** Measured with the two variants compiled side by side (x86-64, gcc,
C++17):

| | `OptionValue` | `alignof` | `BackendOption` |
|---|---|---|---|
| stock | 260 | 4 | 324 |
| with `size_t` | 264 | 8 | 328 |

Every current alternative — `bool`, `int`, `array<char, 256>` — is at most 4-byte aligned, so
`OptionValue` has 4-byte alignment today. **Any** 64-bit alternative raises it to 8 and grows every
`BackendOption`. `int64_t` behaves identically; there is no 64-bit type that fits for free.

`runtime/backend/options.h` is an **installed** header, so this would change a type consumers
compile against. An object compiled against our headers and linked against anything built from
stock ET headers — or the reverse — gets a silent layout mismatch with no diagnostic. That is the
same failure class as the `/MD` vs `/MT` CRT mismatch documented in `docs/handover-to-engine.md`
(§2, C4), and it is reachable here: a consumer could plausibly have the official `executorch`
package and our runtime in one process.

The change would be *source*-compatible — access is entirely via `std::get_if<T>`, with no
`.index()` switching or exhaustive visitation anywhere in `runtime/`, `backends/`, or `extension/`,
and appending preserves the existing indices. The break is purely size and alignment. That is
precisely what makes it dangerous: it compiles and links clean, then corrupts.

The trade is a permanent public-ABI divergence inherited by every downstream consumer, plus higher
patch-conflict risk on ET bumps, in exchange for lifting a 2 GiB ceiling on arenas measured in
megabytes.

Two fallbacks if exactness above 2 GiB ever becomes real:

1. Report decimal bytes in the existing `array<char, 256>` alternative — exact, unbounded, no header
   change, no ABI risk; only uglier at the call site.
2. Upstream a 64-bit alternative to ExecuTorch, where the ABI can be revved coherently for
   everyone. This is a far more upstreamable change than the vendored XNNPACK getter in patch A.

### Sharing mode

`EXECUTORCH_XNNPACK_SHARED_WORKSPACE` defaults to `BOOL ON` (`tools/cmake/preset/default.cmake:287`),
so our Linux builds get `WorkspaceSharingMode::Global` and there is exactly one workspace per
process. The premise the consumer relies on holds today.

It holds by a thread. The comment immediately above that default reads *"Keeping this OFF by
default to maintain existing behavior"* — upstream's prose and value disagree, so the default is one
edit from flipping. If it flips, the reported figure silently becomes per-delegate-instance and
stops meaning what the consumer thinks it means.

**Decision: pin `-DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON` explicitly** in `common_cmake_flags`
rather than inherit it.

For the same reason patch C sums *live* workspaces from the manager's `weak_ptr`s rather than
reading the single global one. Under `Global` the two are identical; under any other mode the sum
stays correct. Guarding the mode in one place and assuming it in another is how the two drift.

## Components

### Patch A — vendored XNNPACK accessor

Declare in `backends/xnnpack/third-party/XNNPACK/include/xnnpack.h`:

```c
size_t xnn_get_workspace_size(xnn_workspace_t workspace);
```

Implement in `src/runtime.c` returning `workspace->size`, null-guarded to `0`. Purely additive
symbol; `struct xnn_workspace` stays internal, so no ABI exposure.

### Patch B — `XNNWorkspace::size()`

A wrapper method that reads the size through `acquire()`, so the read is synchronized exactly like
every other access to the handle rather than racing a concurrent `xnn_create_runtime_v4` that grows
the arena.

### Patch C — `XNNWorkspaceManager::total_workspace_size()`

Sums live workspaces under `workspace_meta_mutex_`. The manager holds `weak_ptr`s
(`global_workspace_`, `model_workspaces_`), so expired entries are skipped — this is "sum what is
alive", not a running total. Under `Global` that is one entry.

### Patch D — the option key

Read-only key in `XnnpackBackendOptions::get_option`. `set_option` must **reject** it explicitly
with `Error::InvalidArgument` rather than fall through the existing `strcmp` chain and silently
return `Error::Ok` without doing anything — the current chain's final `else` is a no-op success,
which would make a write attempt look like it worked.

The key name is a consumer contract: the engine hardcodes the string, since
`XNNPACKBackend.h` (where the existing key constants live) does not ship.

### Patch E — applying A–D from the recipe

`build-runtime.sh` already has a source-patch phase (the `pytorch/executorch#20709`
install-destination fix, and the Windows `flatc_ep` byproduct fix). Patches A–D extend it, applied
before configure.

The existing phase sets the pattern these must follow: `grep -rl` for the target text guarded with
`|| true`, patch only what matched, and print "nothing to patch — source already patched" when the
tree is clean. The recipe is idempotent by contract, and these patches touch a caller-supplied ET
checkout that may already be patched from a previous run in the same working tree.

Unlike the existing `sed` one-liners, patches B–D insert whole methods, so they need an anchor that
survives reformatting and a guard that refuses to apply twice. Whether that is `sed` against a
distinctive anchor line or a checked-in `.patch` applied with `git apply --3way` is an
implementation decision; the requirement is that a second run is a no-op and a *failed* match is a
hard error rather than a silent skip. A silently unapplied patch is precisely what the guard and
behavioural test exist to catch, but the recipe should fail first and more legibly.

## Data flow

1. Consumer loads an XNNPACK-delegated method. Delegate init obtains a workspace from the manager;
   XNNPACK grows the arena during `xnn_create_runtime_v4`.
2. Consumer calls `runtime::get_option("XnnpackBackend", span)` with one `BackendOption` whose key
   is the new key.
3. `XnnpackBackendOptions::get_option` → `XNNWorkspaceManager::total_workspace_size()` → per-live
   workspace `XNNWorkspace::size()` → `xnn_get_workspace_size()` → `workspace->size`.
4. Consumer adds the returned `int` to its native-footprint report.

**Timing:** the workspace is created lazily on first delegate init, so the reported size is `0`
before any XNNPACK-delegated model loads. That is correct behaviour, and the consumer doc must say
so — otherwise a zero reads as a broken accessor.

## Error handling

- Null workspace → `0`, not a crash. A memory report should degrade to an underestimate.
- Backend not registered → `runtime::get_option` already returns `Error::NotFound`; unchanged.
- Unknown key → unchanged existing behaviour.
- Write attempt on the read-only key → `Error::InvalidArgument` (see patch D).
- Value above `INT_MAX` → saturate, do not wrap.

## Testing

### The fixture problem

The behavioural test needs an **XNNPACK-delegated** `.pte`, and we do not have one. The LSTM
fixture lowers to the `etnp::lstm` custom op with no `XnnpackPartitioner` in its AOT path — its
XNNPACK use is inside our own kernel, not the delegate, so its delegate workspace reads `0` and the
test would pass vacuously against a broken accessor.

This needs a tiny XNNPACK-delegated fixture, in the shape of `scripts/emit-openvino-fixtures.py`:
a trivial `nn.Linear` model lowered with `XnnpackPartitioner`, asserting `b"XnnpackBackend"` appears
in the emitted `.pte` exactly as the OpenVINO emitter asserts its own backend marker. Whether it is
published as a release asset or emitted in-gate is a planning decision; the gate only needs it to
exist at test time.

### Guard — replaces the header check

The issue proposed asserting that the installed `xnnpack.h` declares the new symbol. No such file
ships, so instead:

1. `nm` on the built archive for `xnn_get_workspace_size`, proving the patch survived compilation
   rather than merely that a file was edited.
2. The behavioural test below.

That pair is strictly stronger than the original header grep.

### Behavioural test

A small C++ probe built against the installed prefix — the `test/openvino/ov_runner.cpp` pattern —
that loads the XNNPACK fixture, queries the option, and asserts a non-zero size. Two assertions
matter and neither is optional:

- **Before** any model loads, the size is `0`. This pins the documented lazy-init behaviour.
- **After** loading, the size is `> 0`. This is what fails the build if a future ET bump drops the
  patch, which is the whole point of making it a consumer contract.

### Unit tests

`test/lib_cmakeflags.test.sh` gains an assertion that the sharing-mode flag is pinned.

## Gate coverage

The `build-runtime.sh` change routes the extras gate to `full` via rule (1) in
`scripts/classify-gate.sh`, so patches A–E, the guard, and the behavioural test all run on the PR.
No routing change needed.

## Consumer-facing contract change

The contract enumeration lives in `docs/handover-to-engine.md` (§2, C1–C10) — note that `README.md`
does **not** enumerate the contracts, despite referencing one. This work adds an item: the backend
option key, its `int`-bytes-saturating semantics, its lazy-init zero, and the fact that it is
read-only. It must be added there and in a consumer-facing note, or the engine has no durable
statement of what it is reading.

The release itself is a pkgrev bump (`v1.3.1-8` → `v1.3.1-9`): CI rebuilds and re-attests all
variants and platforms, and the engine takes the new `EtRuntimePin.cmake`.

## Risks

- **Patch drift on future ET pins.** The vendored XNNPACK submodule moves on ET bumps and the
  patches must tolerate it. Mitigated by the guard and behavioural test, which turn a silently
  dropped patch into a build failure. Fully droppable once upstream lands a getter.
- **Sharing-mode default flip upstream.** Mitigated by pinning the flag explicitly.
- **`size` includes allocator alignment padding.** This is the actual allocation, which is what
  host-side accounting wants — noted so it is not mistaken for a defect later.
- No new dependency; no `THIRD-PARTY-NOTICES` change.

## Out of scope

- Per-model workspace attribution. Under `Global` sharing there is one arena and no meaningful
  per-model split; the consumer's requirement is a process-level figure.
- Engine-side changes. Those live in the consumer repo.
- Upstreaming the accessor to XNNPACK. Worth doing eventually, and it would let us drop patch A
  (and shrink patch E to three patches), but it does not gate this work.
