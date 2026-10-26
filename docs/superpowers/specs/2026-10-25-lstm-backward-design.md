# `etnp::lstm` backward op — design (issue #62)

**Status:** builder-checked, for review · 2026-10-25 · branch `feature/lstm-backward`
**Issue:** measly-java-learning/executorch-runtime-dist#62 (folds in #28)
**Unlocks:** corey-cole/executorch-numpy-runtime#23 (torch-free training), specifically its #22
(`etnp::lstm` training sample).

## Why

Torch-free training means: PyTorch runs once, offline, to export a joint forward+backward graph
(`torch.export.experimental._export_forward_backward`); training then runs in ExecuTorch with numpy
driving the optimizer. That works today for standard layers because their backward lowers to kernels
the runtime already has. It does **not** work for `etnp::lstm`: the op has a
`CompositeExplicitAutograd` impl and a fake kernel but no autograd formula, so a joint export cannot
produce gradients for its weights.

The workaround — an LSTM decomposed into `linear`/`sigmoid`/`tanh` — trains correctly but its graph
grows linearly with T (issue #62: 26 s / 177 KB at T=16 → 110 s / 696 KB at T=64). The custom op
exists precisely to be constant in T; that matters more for training, not less.

This is a **product-market-fit** step. The deliverable is the capability, correctly; speed is
explicitly deferred, and we say so in the consumer docs.

## Goals

1. A joint-graph export of a model using `etnp::lstm` succeeds, and the resulting `.pte` contains
   `etnp::lstm.out` (forward) and `etnp::lstm_backward.out` (backward) as opaque ops — graph size
   constant in T.
2. Running that `.pte` produces the loss and every **parameter** gradient matching torch. The
   round-trip model is `Linear → etnp::lstm → Linear`, so the `.pte` covers the op's outputs as
   follows *(decided 2026-10-25)*:
   - `grad_w_ih, grad_w_hh, grad_b_ih, grad_b_hh` — directly, as LSTM parameter gradients;
   - `grad_input` — indirectly but in-graph: the first Linear's weight gradient is correct only if
     `grad_input` is;
   - `grad_h0, grad_c0` — **not** from the `.pte` (they are user-input gradients, a joint-export
     path nothing here exercises). Covered by the float64 gradcheck and the C++ kernel unit test.
     Revisit when a sample carries state across batches.
3. A C++ `etnp::lstm_backward.out` kernel ships in every tarball variant on Linux (x86_64,
   aarch64), registered via the same static-init mechanism and covered by the nm-guard.
4. The tier2 gate (#28) runs for real, end to end, for the first time — on this PR — and the new
   gradient round trip runs on every path that gates the LSTM (tier2, full, release).
5. `docs/lstm-op-consumer-guide.md` documents the backward op, how to export a training graph, and
   what is left unoptimized.

## Non-goals

- **Performance.** The backward kernel is plain scalar C++: no XNNPACK, no Highway, no threadpool.
  Its cost must be linear in T (one recompute + one reverse sweep), not better. Optimize later if
  the capability finds users. *(Decided 2026-10-25.)*
- **A training variant of the forward** that returns saved activations. The backward recomputes
  instead (issue #62's recommendation): one frozen op name, not two.
- **Windows.** Windows ships no extras today; this does not change that.
- **Delegated (XNNPACK-partitioned) training graphs, dynamic batch, multi-layer/bidirectional.**
  Same scope as the forward op.
- **Optimizer / `extension_training`.** numpy runs the optimizer (decided in #63).
- **Collapsing `full` and `tier2` into one round-trip definition** (#28's second checkbox). The
  `full` gate's fixture-handoff split exists to save ~10 min of wall clock; keep both forms, make
  both run the new test, and record why there are two in #28. *(My call.)*

## Anti-goals

- **The forward op's behaviour changes.** This is the one the user named. Concretely, none of these
  may happen:
  - the forward's name or schema in `extra.yaml`, or its kernel source (`etnp_lstm.cpp`,
    `lstm_cell.*`, `xnn_linear*`), changes;
  - the existing frozen forward fixtures or goldens change or need re-minting, or the forward check
    in `consumer_smoke.py` changes what it checks or its verdict. (Additive edits to that script —
    a new, separate backward check — are expected; see §5.)
  - an **inference** export (`torch.export.export` + `to_edge_transform_and_lower`, no joint graph)
    of a model using the op emits anything other than it does today — specifically, it must still
    contain `etnp::lstm.out` and **no** `lstm_backward`. Registering autograd must not leak into
    inference graphs.
  - the installed header `include/etnp/lstm.h` loses or renames its existing constants
    (`kLstmName`, `kLstmOutName`).
- Gradients that pass a loose tolerance while being subtly wrong. Guard: gradcheck in float64
  against autograd-over-`nn.LSTM`, then the `.pte` round trip at float32 tolerance; the two catch
  different classes (formula vs. kernel).

## Constraints

- ExecuTorch pin `v1.5.1`; torch from `install_executorch.sh` at that pin (as today).
- `extra.yaml` stays the single source of truth for op names and schemas; the generated header and
  the AOT both consume it.
- Registrar archives are whole-archived by consumers via `ETNPExtras.cmake`; the nm-guard must
  list every registrar TU.
- Hermetic `test/run.sh` stays hermetic; fixtures are CI-minted, never committed.
- No complex Python embedded in shell (CLAUDE.md).
- This PR must classify **tier2** under `scripts/classify-gate.sh` — i.e. it must not touch
  `build-runtime.sh` or any rule-(1b) file. If a recipe change turns out to be unavoidable, split it
  into a precursor PR so this one still exercises tier2. *(My call.)*

## How

### 1. Schema: one bundle, two ops

The backward lives in the **same bundle** (`extras/lstm/`) as the forward, per the issue: same
`extra.yaml`, same archive `libetnp_ops_lstm.a`, same AOT module. `extra.yaml` today is
"one op = one bundle" (top-level `op:` + `schema:`), and `generate_schema_header.py` /
`extras/CMakeLists.txt` carry `TODO(op#2)` notes for exactly this moment.

- Extend `extra.yaml` to declare a second op under the same namespace. The forward's existing
  `op:`/`schema:` text stays byte-identical; the backward is additive (exact YAML shape is the
  builder's — e.g. an `ops:` list, or an `extra_ops:` key that leaves the forward untouched).
- `load_schema` keeps returning the forward's dict shape for existing callers, plus access to the
  backward's entry. Its validation stays loud.
- The generated header keeps `kLstmName` / `kLstmOutName` and **adds** backward constants
  (e.g. `kLstmBackwardName` / `kLstmBackwardOutName`). Resolve the generator's `TODO(op#2)` by
  deriving names from the op, but keep the two existing spellings.

**Backward schema** (from the issue, refined):

```
lstm_backward(Tensor grad_output, Tensor? grad_hn, Tensor? grad_cn,
              Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
              Tensor? b_ih, Tensor? b_hh)
  -> (Tensor, Tensor, Tensor, Tensor, Tensor, Tensor, Tensor)
lstm_backward.out(..., *, Tensor(a!) grad_input, Tensor(b!) grad_h0, Tensor(c!) grad_c0,
                  Tensor(d!) grad_w_ih, Tensor(e!) grad_w_hh,
                  Tensor(f!) grad_b_ih, Tensor(g!) grad_b_hh) -> (...)
```

- `grad_hn` / `grad_cn` are optional because autograd passes `None` when a model does not use
  `hn`/`cn` (the common case: loss on `output` only). The kernel treats `None` as zero.
- **Absent biases:** ExecuTorch out-variant returns cannot be `None`, so the op always has seven
  outputs. When a bias is absent, the corresponding gradient output is a `[4H]` tensor the kernel
  still fills (it is the same sum either way) and the autograd wrapper discards it — the forward's
  `b_ih=None` gets a `None` gradient on the torch side. This replaces the issue's
  `convolution_backward`-style mask, which exists to *skip work*, not to change arity, and buys
  nothing at these sizes. *(My call; the builder may adopt a mask if the export path demands one —
  see Risks.)*
- `grad_h0` / `grad_c0` are always computed — they fall out of the last reverse step for free — so
  a future sample that carries state across batches needs no schema change. *(My call; the first
  sample starts every batch from zeros.)*

### 2. AOT (`extras/lstm/aot/`)

- Define both overloads of `lstm_backward` from `extra.yaml`, with a `CompositeExplicitAutograd`
  impl (so it stays opaque through `to_edge`) and a `register_fake` (shapes = forward inputs').
- **Eager reference backward:** autograd over the existing `_lstm_ref` (recompute forward with
  `requires_grad`, call `torch.autograd.grad`). This is the impl behind `lstm_backward` and the
  oracle for gradcheck; no hand-derived Python BPTT.
- `torch.library.register_autograd("etnp::lstm", backward, setup_context=...)`: `setup_context`
  saves the forward inputs (not activations); `backward` calls `torch.ops.etnp.lstm_backward` and
  maps unused bias gradients to `None`.
- The forward's `_lstm_impl`, `_lstm_out_impl`, `_lstm_fake` are not modified.

### 3. Runtime (`extras/lstm/runtime/`)

- New TU (e.g. `etnp_lstm_backward.cpp`) with its own file-scope registrar →
  `_GLOBAL__sub_I_etnp_lstm_backward.cpp`, added to `ETNP_EXTRAS_EXPECT_TUS` so the nm-guard
  requires both TUs. Same boxed-trampoline pattern as the forward (the pinned auto-unboxing macro
  caps outputs at 1; this op has seven).
- Algorithm: scalar float32. (a) Recompute the forward over T, storing per-step gates `i,f,g,o`
  and cell states `c_t` in `ctx.allocate_temp` scratch (O(T·B·H) — fine at the target sizes).
  (b) Reverse sweep accumulating `dW_ih, dW_hh, db` and propagating `dh, dc`; `grad_input` per
  step; final `dh, dc` → `grad_h0, grad_c0`. Gate order i,f,g,o; same layout contract as the
  forward.
- It does **not** call the forward kernel or its XNNPACK cache — fully independent code path, so
  it cannot perturb forward behaviour (anti-goal) and has no new link deps.
- Input checks mirror the forward (`ET_KERNEL_CHECK` on dtype and shapes; resize outputs).

### 4. Tests (`extras/lstm/test/`)

| Test | Kind | Proves |
|---|---|---|
| gradcheck: `etnp::lstm` autograd vs `torch.autograd.gradcheck`, and vs `nn.LSTM` grads, float64, with/without biases, with/without `grad_hn/grad_cn` | AOT, torch | the formula/registration |
| inference-export invariance: inference export still has `etnp::lstm.out` and no `lstm_backward` | AOT, torch | anti-goal |
| joint export: `_export_forward_backward` of a small model using the op succeeds; plan contains both `.out` ops; graph op count does not grow with T (export at two Ts, compare) | AOT, torch | goal 1 |
| C++ kernel unit test vs expected grads for **all seven** outputs, incl. `grad_h0/grad_c0` and a nonzero `grad_hn/grad_cn` case (extends `lstm_kernel_test.cpp` or a sibling) | C++, torch-free | the kernel in isolation; the only runtime check of `grad_h0/grad_c0` |
| **training round trip**: run the joint `.pte` (weights external in a `.ptd` written by the Python export) and compare loss + every parameter gradient (both Linears + the LSTM's four) to torch eager @ float32 tolerance | live, torch + prefix | goal 2 — the gate |
| consumer smoke (tier1) loads a training fixture and checks the backward registrar resolves | frozen, torch-free | consumer link path |

The training case gets its own SSOT module, the counterpart of `lstm_case.py` (e.g.
`lstm_train_case.py`): dims, seed, weights, loss, export recipe, assertions. Both the live test and
the fixture emitter call it, so live and frozen cannot drift — same rule as the forward.

**Round-trip scope:** the `.ptd` is the one the Python export writes (external weights); the C++
runner only loads `pte + ptd`, runs one training step, and dumps loss + gradients. It does **not**
call `save_ptd` or hand weights to an inference program: #63's own gate already proves the
writer and the train → infer handoff, and repeating it here would add a serialize link dep to the
LSTM runner for no new coverage. *(My call.)*

### 5. Gates (folds in #28)

- **tier2** (`live-roundtrip` job, `lstm-roundtrip` action): add the training round trip to what
  the action runs. This PR is the end-to-end proof #28 asks for; the PR description must link the
  green `live-roundtrip` run.
- **No workflow edits.** `extras-gate.yml` is a rule-(1b) file — touching it routes the PR to
  `full` and tier2 stays unproven. Every gate change goes through the scripts the workflows already
  call: `emit_fixtures.py` (mints), `scripts/package-fixtures.sh` (packs), `consumer_smoke.py`
  (verifies), and the `lstm-roundtrip` action's pytest target. If a workflow edit proves
  unavoidable, it goes in a precursor PR. *(My call.)*
- **Fixtures: same tarball, additive members.** The training fixtures join
  `etnp-lstm-fixtures-<etver>.tar.gz` next to the forward's four files (which stay byte-identical);
  `package-fixtures.sh` and its test grow the member list. No new asset, so no `naming.sh` /
  `release.yml` / `fetch`-job change. The planner must confirm the numpy runtime's fixture consumer
  tolerates extra members. *(My call.)*
- **full** (`full-aot` → `full-gates`): `full-aot` already calls `emit_fixtures.py`, so it mints
  the training fixtures with no workflow change; `full-gates` runs `consumer_smoke.py`, which picks
  up the new check.
- **release** (`release.yml` x86_64 logging leg): already runs the `lstm-roundtrip` action, so it
  picks up the new test with no workflow change.
- **tier1**: `consumer_smoke.py` gains a separate backward check. Tier1 consumes *published*
  fixtures, so a training fixture only exists for tier1 once a release has minted it; until then
  that check must skip explicitly and say so, not fail and not silently pass. *(How it detects
  absence is the builder's.)*
- Close #28 with: the green run link, the answer to "should full reuse tier2's round trip" (no —
  latency split; both run the same SSOT case), and confirmation that routing is reachable.

### 6. Docs

`docs/lstm-op-consumer-guide.md` gains a **Training** section: the backward op name and schema, how
to export a joint graph (`import extras.lstm.aot.etnp_lstm_op` before `_export_forward_backward`),
that absent biases yield `None` grads on the torch side, and a plain **Unoptimized** note — scalar,
single-threaded, linear in T, intended for hundreds–thousands of params. `extras/README.md` and
CLAUDE.md get one line each if they enumerate ops.

### 7. Release

Ship in the next `v1.5.1-N` tag. Tagging is the user's call.

## Risks

1. **The export path may not do what this doc assumes.** Specifically: that
   `_export_forward_backward` keeps `etnp::lstm_backward` opaque, that `ToOutVarPass` converts a
   seven-output functional op to its `.out` overload, and that optional `Tensor?` inputs
   (`grad_hn`, `grad_cn`, biases) survive serialization. Nothing in this repo has exercised a
   custom op with more than three outputs or with optional inputs fed `None` by autograd. **This is
   the highest-risk piece and should be proven first** — a failure here reshapes the schema.
2. **Joint export with weights as constants vs. parameters.** The forward case bakes weights in as
   constants (`lstm_case.py` asserts 3 user inputs). A training graph needs them as parameters
   (external, in a `.ptd`). The training case must not reuse the forward's export recipe.
3. **#28 routing.** If any file this PR needs is in rule (1)/(1b), the PR goes `full` and tier2
   stays unproven. See Constraints.

## Left to the builder

- Exact YAML shape for the second op, and `load_schema`'s API for it.
- Training-case dims (target: roughly I=4, H=16; T small enough for fast CI, plus a second T for the
  constant-size check), loss function, and tolerances.
- File names for the new TU, case module, and tests.
- How tier1 detects that a training fixture is absent.
- Whether the C++ unit test's expected values come from a minted file or are hard-coded.
