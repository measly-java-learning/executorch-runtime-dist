# `etnp::lstm` Backward Op Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `etnp::lstm_backward` (AOT autograd + scalar C++ kernel) so a joint forward+backward export of a model using `etnp::lstm` trains in ExecuTorch, gated end to end on tier2 for the first time (#28).

**Architecture:** The backward is a second op in the existing `extras/lstm` bundle: `extra.yaml` grows a second schema, the AOT module registers autograd on the forward that calls the new op, and a new registrar TU in `libetnp_ops_lstm.a` implements it in scalar float32 (recompute forward, reverse sweep). A new training case module is the single source for the training `.pte`, `.ptd` and golden gradients, consumed by both the live round trip and the fixture emitter. Every gate change goes through scripts the workflows already call — no workflow edits — so this PR classifies tier2.

**Tech Stack:** ExecuTorch v1.5.1 (C++ runtime + `exir` Python), torch from `install_executorch.sh` at that pin, `torch.library`, `torch.export.experimental._export_forward_backward`, CMake ≥ 3.24, pytest, bash.

**Spec:** `docs/superpowers/specs/2026-10-25-lstm-backward-design.md`

## Global Constraints

- ET pin `v1.5.1`; torch is whatever `install_executorch.sh` at `v1.5.1` installs.
- Forward is frozen: no change to the forward's `op:`/`schema:` text in `extra.yaml`, to `etnp_lstm.cpp`, `lstm_cell.*`, `xnn_linear*`, to `_lstm_impl`/`_lstm_out_impl`/`_lstm_fake`, or to the forward fixture members `lstm.pte in.bin out.bin shape` (byte-identical) or `consumer_smoke.py`'s forward check and verdict.
- Installed header `include/etnp/lstm.h` keeps `kLstmName` and `kLstmOutName` with their current values.
- Inference export of a model using the op contains `etnp::lstm.out` and **no** `lstm_backward`.
- Backward kernel: scalar float32, no XNNPACK / Highway / threadpool, no call into the forward kernel or `XnnLinearCache`. Linear in T.
- Backward schema has 7 outputs always; `grad_hn`, `grad_cn`, `b_ih`, `b_hh` are `Tensor?`; `None` grad inputs mean zero.
- **This PR must classify `tier2`.** Do not touch `build-runtime.sh`, `.github/workflows/*.yml`, or any path matched by rule (1b) in `scripts/classify-gate.sh` (it includes `patches/`, `.build-image`, `scripts/patch-et-sources.sh`, `scripts/emit-*.py`, `test/ptd_writer*`, `test/xnnpack_workspace*`, `test/openvino*`, ccache scripts). If a task finds such an edit unavoidable, STOP and report — it becomes a precursor PR.
- Hermetic `test/run.sh` stays hermetic. Fixtures are CI-minted, never committed. No complex Python in shell (CLAUDE.md). No bare `Task N` / `§N` references in code comments.
- Linux only (Windows ships no extras).

**Environments** (referenced by tasks):
- **AOT env:** the build container (`$(cat .build-image)`) with a v1.5.1 ExecuTorch checkout (with submodules) at `$SCRATCH/et-src/executorch` and a Python venv persisted at `$SCRATCH/aotvenv`, built once in Task 1 via `. scripts/lib/aot.sh; et_aot_install_build_deps` + `install_executorch.sh` + `pip install -r requirements/roundtrip.txt`. (The host's `/home/corey/workspace/executorch/.venv` is ET 1.3.1 — do not use it.)
- **Prefix:** the published `v1.5.1-1` `logging` `linux-x86_64` tarball extracted to `$SCRATCH/prefix`, with the branch's extras rebuilt into it exactly as the tier2 job does (`rm -f prefix/lib/libetnp_ops_*.a prefix/lib/libhwy.a; rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp; ./build-runtime.sh --extras-only --variant logging --prefix $SCRATCH/prefix`). `v1.5.1-1` is what `classify-gate.sh` will resolve for tier2.

## Review Focus

1. **Autograd leaks into inference exports.** Exporting a model using the op without a joint graph must produce exactly today's program (`etnp::lstm.out`, no backward op). Pinned by an assertion in `lstm_case.build_case()` (Task 2) — which runs in every gate path, not just pytest.
2. **Bias absent (`b_ih=None` / `b_hh=None`).** Users expect a model without biases to train, with `None` grads for the missing biases and correct weight grads. Pinned by gradcheck cases (Task 2) and a C++ case with null biases (Task 3).
3. **Loss uses `hn`/`cn`, not just `output`.** Autograd then passes real `grad_hn`/`grad_cn`; a kernel that assumes `None` silently drops gradient. Pinned by a gradcheck case with loss on `hn + cn` (Task 2) and a nonzero `grad_hn/grad_cn` C++ case (Task 3).
4. **Training fixture missing from an older published release.** tier1 consumes `v1.5.1-1` fixtures that have no training members; the new check must print an explicit SKIP, never fail and never silently pass. Pinned in Task 5.
5. **T = 1.** A single-step sequence is the edge of the reverse sweep (no recurrent gradient). Pinned by a gradcheck case with T=1 (Task 2) and a C++ T=1 case (Task 3).

---

### Task 0: Commit the spec and plan

**Files:** `docs/superpowers/specs/2026-10-25-lstm-backward-design.md`, `docs/superpowers/plans/2026-10-25-lstm-backward.md`

- [ ] **Step 1:** On branch `feature/lstm-backward` (already created from `main` at `40693c0`), commit both files: `git commit -m "docs: lstm backward design + plan (#62)"`.

### Task 1: Two-op schema in `extra.yaml` + generator

**Files:**
- Modify: `extras/lstm/extra.yaml`, `extras/generate_schema_header.py`, `extras/test_generate_schema_header.py`, `extras/CMakeLists.txt` (the `TODO(op#2)` reset only)

**Interfaces:**
- Produces: `extra.yaml` key `extra_ops:` — a list of `{op: <name>, schema: {functional, out}}` entries under the same namespace; the existing top-level `op:`/`schema:` are untouched. `load_schema(path) -> dict` returns the same keys as today **plus** `"extra_ops": list[dict]`, each dict with `op, qualified_name, qualified_out_name, functional, out` (whitespace-normalised like the forward). `render_header` emits, in addition to `kLstmName`/`kLstmOutName`, `kLstmBackwardName = "etnp::lstm_backward"` and `kLstmBackwardOutName = "etnp::lstm_backward.out"` (constant names derived from the op: CamelCase of `op` + `Name`/`OutName`, with the forward's two spellings unchanged).
- Backward schema text (verbatim into `extra.yaml`):
  - functional: `lstm_backward(Tensor grad_output, Tensor? grad_hn, Tensor? grad_cn, Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor, Tensor, Tensor, Tensor, Tensor)`
  - out: same args, then `*, Tensor(a!) grad_input, Tensor(b!) grad_h0, Tensor(c!) grad_c0, Tensor(d!) grad_w_ih, Tensor(e!) grad_w_hh, Tensor(f!) grad_b_ih, Tensor(g!) grad_b_hh) -> (Tensor(a!), Tensor(b!), Tensor(c!), Tensor(d!), Tensor(e!), Tensor(f!), Tensor(g!))`

- [ ] **Step 1: AOT env.** Build it (see Environments). Verify: `python -c "import executorch.version as v, torch; print(v.__version__, torch.__version__)"` prints `1.5.1…`.
- [ ] **Step 2: Failing tests** in `extras/test_generate_schema_header.py`:
  - `test_header_has_backward_names`: header contains `constexpr char kLstmBackwardName[] = "etnp::lstm_backward";` and `kLstmBackwardOutName[] = "etnp::lstm_backward.out";`, and still the two forward lines.
  - `test_load_schema_extra_ops`: `s["extra_ops"][0]["qualified_out_name"] == "etnp::lstm_backward.out"`, `functional.startswith("lstm_backward(")`, `out.startswith("lstm_backward.out(")`.
  - `test_forward_schema_unchanged`: `s["functional"]` and `s["out"]` equal the exact normalised strings they produce on `main` (copy them from a run on `main` into the test as literals).
  - `test_extra_ops_optional`: a YAML without `extra_ops` loads with `s["extra_ops"] == []`.
- [ ] **Step 3:** Run `python -m pytest extras/test_generate_schema_header.py -v` → new tests FAIL.
- [ ] **Step 4:** Implement. Resolve the generator's `TODO(op#2)` comment (constant names now derive from the op). In `extras/CMakeLists.txt`, resolve the first half of its `TODO(op#2)` (reset `ETNP_EXTRAS_EXPECT_TUS` to `""` before each `add_subdirectory`); leave the test-wiring half as is.
- [ ] **Step 5:** Tests PASS; `bash test/run.sh` green.
- [ ] **Step 6:** Commit `feat(lstm): declare lstm_backward in extra.yaml (#62)`.

### Task 2: AOT face — backward op, autograd, export proof (STOP GATE)

**Files:**
- Modify: `extras/lstm/aot/etnp_lstm_op.py`, `extras/lstm/aot/lstm_case.py` (one assertion only)
- Create: `extras/lstm/aot/lstm_train_case.py`, `extras/lstm/test/test_lstm_backward_aot.py`

**Interfaces:**
- Consumes: `load_schema(...)["extra_ops"]` (Task 1).
- Produces:
  - `torch.ops.etnp.lstm_backward` (functional + `.out`), `CompositeExplicitAutograd` impls, `register_fake` returning 7 tensors shaped like `(input, h0, c0, w_ih, w_hh, [4H], [4H])`.
  - `_lstm_backward_ref(grad_output, grad_hn, grad_cn, input, h0, c0, w_ih, w_hh, b_ih, b_hh) -> tuple[7]`: recompute `_lstm_ref` on detached inputs with `requires_grad`, `torch.autograd.grad` with `None` grads treated as zeros; for an absent bias, return `torch.zeros(4H)`.
  - `torch.library.register_autograd("etnp::lstm", _lstm_backward, setup_context=_lstm_setup_context)`: context saves the 7 forward inputs; backward calls `torch.ops.etnp.lstm_backward` and returns `None` for any bias that was `None` in the forward.
  - `lstm_train_case.py`: `DIMS = {"T": 8, "B": 2, "I": 4, "H": 16, "O": 1}`, `class TrainNet(nn.Module)` = `Linear(I, I) → etnp::lstm (params w_ih, w_hh, b_ih, b_hh as nn.Parameter) → Linear(H, O)` on `output[-1]`, loss `mse_loss` against a target; `build_train_case(T=DIMS["T"]) -> (pte_bytes, ptd_bytes, in_bytes, golden_bytes, dims, meta)` where `in_bytes = x[T,B,I] ++ target[B,O]` (h0/c0 are zero buffers inside the model, not inputs), `golden_bytes = loss ++ every parameter gradient in the joint graph's gradient-output order`, and `meta` records that order (`list[str]` of parameter FQNs) and the plan's operator count.
- Training export recipe (to be **proven** here, not assumed): `torch.export.export(...)` → `_export_forward_backward(ep)` → `to_edge(...)` → `.to_executorch(ExecutorchBackendConfig(external_mutable_weights=True))` with the `.ptd` taken from the manager's data files (`_tensor_data` / `write_tensor_data_to_file` — whichever v1.5.1 exposes). No partitioner.

- [ ] **Step 1: Failing tests** in `test_lstm_backward_aot.py` (all `pytest.importorskip("torch")`):
  - `test_backward_op_registered`: `torch.ops.etnp.lstm_backward.default` and `.out` exist; fake returns 7 shapes as above.
  - `test_gradcheck` parametrised over `(bias, loss_on, T)` ∈ `{with, without} × {output, hn_cn} × {1, 5}`: float64, `torch.autograd.gradcheck` on a function calling `torch.ops.etnp.lstm` with all of `input, h0, c0, w_ih, w_hh, (b_ih, b_hh)` requiring grad.
  - `test_matches_nn_lstm`: with biases, float64, compare autograd grads through `torch.ops.etnp.lstm` against grads through `torch.nn.LSTM` with the same weights, all 7 (or 5 without bias), `atol=1e-10`.
  - `test_no_bias_grads_are_none`: forward with `b_ih=b_hh=None`; `torch.autograd.grad(..., allow_unused=True)` gives weight grads and the bias inputs are absent — the backward returns `None` for them.
  - `test_inference_export_unchanged`: call `lstm_case.build_case()` (it asserts internally, see Step 3).
  - `test_joint_export`: `build_train_case()`; plan operator names include `etnp::lstm.out` and `etnp::lstm_backward.out`; `meta` lists every `TrainNet` parameter.
  - `test_graph_constant_in_T`: `build_train_case(T=8)` and `build_train_case(T=32)` report the same operator count.
- [ ] **Step 2:** Run in the AOT env: `python -m pytest extras/lstm/test/test_lstm_backward_aot.py -v` → FAIL (op undefined).
- [ ] **Step 3:** In `lstm_case.build_case()`, add one assertion after the existing `etnp::lstm.out` one: no operator name starts with `etnp::lstm_backward`. Nothing else in that file changes.
- [ ] **Step 4:** Implement the op, autograd and `lstm_train_case.py`. The training case asserts its own invariants inside `build_train_case` (same pattern as `lstm_case`): both `.out` ops present, gradient-order list covers every parameter, `.ptd` non-empty.
- [ ] **Step 5:** Tests PASS.
- [ ] **Step 6 — STOP GATE.** If `test_joint_export` cannot pass because `_export_forward_backward` decomposes the op, `ToOutVarPass` rejects the 7-output op, or `Tensor?` inputs fed `None` by autograd fail to serialize: stop, do not reshape the schema, and report what failed with the traceback. The schema change goes back to the user.
- [ ] **Step 7:** Re-run `python extras/lstm/aot/emit_fixtures.py $SCRATCH/fx-main` on `main` and on the branch; `cmp` all four members → identical (forward frozen).
- [ ] **Step 8:** Commit `feat(lstm): autograd for etnp::lstm via lstm_backward (#62)`.

### Task 3: C++ `etnp::lstm_backward.out` kernel

**Files:**
- Create: `extras/lstm/runtime/etnp_lstm_backward.cpp`, `extras/lstm/test/lstm_backward_kernel_test.cpp`, `extras/lstm/aot/emit_backward_kernel_vectors.py` (dev-time generator, see Step 1)
- Modify: `extras/lstm/runtime/CMakeLists.txt`, `extras/CMakeLists.txt`

**Interfaces:**
- Consumes: `etnp::schema::kLstmBackwardOutName` (Task 1); `_lstm_backward_ref` (Task 2, only to mint test vectors).
- Produces: registered kernel `etnp::lstm_backward.out`; registrar TU `_GLOBAL__sub_I_etnp_lstm_backward.cpp`; `ETNP_EXTRAS_EXPECT_TUS` = both TUs.
- Boxed stack order: `grad_output, grad_hn?, grad_cn?, input, h0, c0, w_ih, w_hh, b_ih?, b_hh?, grad_input, grad_h0, grad_c0, grad_w_ih, grad_w_hh, grad_b_ih, grad_b_hh` (17 EValues).

- [ ] **Step 1: Test vectors.** `emit_backward_kernel_vectors.py` (AOT env) prints a C++ header body of `constexpr float` arrays for cases: (a) T=3,B=2,I=2,H=3 with biases, random seeded inputs, `grad_output` random, `grad_hn=grad_cn=None`; (b) same with nonzero `grad_hn`/`grad_cn`; (c) no biases; (d) T=1. Expected values from `_lstm_backward_ref` in float64 cast to float32. Commit the generated `extras/lstm/test/lstm_backward_vectors.h` with a "GENERATED by … — re-run to refresh" header (test vectors, not a CI fixture).
- [ ] **Step 2: Failing test** `lstm_backward_kernel_test.cpp`, same shape as `lstm_kernel_test.cpp` (registry lookup, temp allocator): for each case, run the op and compare all 7 outputs to the vectors at `atol=1e-5, rtol=1e-4`; for (c), pass `EValue()` (None) for biases and check `grad_b_*` are filled (not NaN) without asserting their value. Prints `FAIL: case=<c> out=<name> idx=<i> got=<g> want=<w>` or `OK: etnp::lstm_backward.out`.
- [ ] **Step 3:** Wire both kernel tests to **run** as POST_BUILD steps of their executables in `extras/CMakeLists.txt`, guarded by `if(NOT CMAKE_CROSSCOMPILING)` (today `lstm_kernel_test` is built but nothing executes it). First build with only the forward test wired: it must print `OK` — if the never-run forward test fails, STOP and report (that is a pre-existing forward bug, out of scope to fix here). Then wire the backward test → build FAILS (op not registered).
- [ ] **Step 4:** Implement: input checks mirror the forward (`Float`, shapes, `grad_output` `[T,B,H]`, optional grads `[B,H]`); resize all 7 outputs; scratch via `ctx.allocate_temp` for per-step `i,f,g,o` (post-activation) and `c_t` for t∈[0,T] (`c_{-1}=c0`) and `h_t`; reverse sweep accumulating `dW_ih += dg_t^T x_t`, `dW_hh += dg_t^T h_{t-1}`, `db += Σ_b dg_t`, `grad_input_t = dg_t W_ih`, `dh_{t-1} = dg_t W_hh`; `grad_b_ih` and `grad_b_hh` both equal `db`. Boxed trampoline like the forward. Add the TU to `etnp_ops_lstm` and to `ETNP_EXTRAS_EXPECT_TUS`.
- [ ] **Step 5:** Rebuild extras → both kernel tests print `OK`, nm-guard passes with two TUs, `check-usdt-notes.sh` passes.
- [ ] **Step 6:** `git diff main -- extras/lstm/runtime/etnp_lstm.cpp extras/lstm/runtime/lstm_cell.* extras/lstm/runtime/xnn_linear*` → empty.
- [ ] **Step 7:** Commit `feat(lstm): scalar lstm_backward.out kernel (#62)`.

### Task 4: Training fixtures — emit + package

**Files:**
- Modify: `extras/lstm/aot/emit_fixtures.py`, `scripts/package-fixtures.sh`, `extras/lstm/test/test_emit_fixtures.py`, `test/package_fixtures.test.sh`

**Interfaces:**
- Consumes: `build_train_case()` (Task 2).
- Produces: fixture members, added to the existing set and tarball: `train.pte`, `train.ptd`, `train_in.bin`, `train_out.bin` (golden), `train_shape` (lines `TRAIN_T=…`, `TRAIN_B=…`, `TRAIN_I=…`, `TRAIN_H=…`, `TRAIN_O=…`, `TRAIN_NOUT=<floats in train_out.bin>`). Tar member order: the four forward members first, unchanged, then the five training members.

- [ ] **Step 1: Failing tests.** `test_emit_fixtures.py`: `train_shape_text(dims, nout)` format test (torch-free); `test_emit_writes_all_members` covers all 9 members. `package_fixtures.test.sh`: fake dir gains the 5 training members; expected members string becomes all 9 sorted; a dir missing `train.ptd` fails non-zero.
- [ ] **Step 2:** Run → FAIL. (`bash test/package_fixtures.test.sh`; pytest in AOT env.)
- [ ] **Step 3:** Implement. `scripts/package-fixtures.sh` is not a rule-(1b) path — confirm: `printf 'scripts/package-fixtures.sh\n' > $SCRATCH/changed; GATE_ET_TAG=v1.5.1 GATE_RELEASE_TAG=v1.5.1-1 bash scripts/classify-gate.sh $SCRATCH/changed` → `mode=tier1`.
- [ ] **Step 4:** Tests PASS; `bash test/run.sh` green; Task 2 Step 7's byte-identity check still holds.
- [ ] **Step 5:** Commit `feat(lstm): mint + package training fixtures (#62)`.

### Task 5: Training runner, live round trip, consumer smoke

**Files:**
- Create: `extras/lstm/test/lstm_train_runner.cpp`
- Modify: `extras/lstm/test/CMakeLists.txt`, `extras/lstm/test/_runner.py`, `extras/lstm/test/test_lstm_roundtrip.py`, `extras/lstm/test/consumer_smoke.py`, `extras/lstm/test/test_consumer_smoke.py`, `.github/actions/lstm-roundtrip/action.yml`

**Interfaces:**
- Consumes: training fixture members (Task 4); `build_train_case()` (Task 2).
- Produces:
  - `lstm_train_runner <train.pte> <train.ptd> <train_in.bin> <out.bin>`, dims from env `TRAIN_T/B/I/O`: `Module(pte, ptd)`, run `forward(x, target)`, read the gradient boundary from the program's training metadata method (`__et_training_parameters_index_forward`), write outputs `[0, boundary)` (loss + gradients) as flat float32. Links the forward runner's set plus `extension_flat_tensor`.
  - `_runner.build_runner(here, prefix, build_dir, target="lstm_runner")` (new optional `target`); `run_train_runner(runner, pte, ptd, inbin, outbin, dims)`.
  - `consumer_smoke.parse_train_shape(path) -> dict`, `consumer_smoke.train_check(fixtures_dir, prefix, tmp) -> str` returning `"ok"` or `"skip"` (exits 1 on mismatch). `main` runs the forward check exactly as today, then the training check; if `train.pte` is absent it prints `consumer smoke SKIP training: no train.pte in <dir> (fixture predates lstm_backward)`; else `consumer smoke OK training`.

- [ ] **Step 1: Failing tests.** `test_consumer_smoke.py`: `test_parse_train_shape`; `test_train_check_skips_without_fixture` (empty tmp dir → `"skip"`, no runner build attempted). `test_lstm_roundtrip.py`: `test_training_roundtrip_matches_eager` — `build_train_case()`, write files, build `lstm_train_runner`, run, compare to golden with `np.allclose(rtol=1e-4, atol=1e-5)`, failure message names the first mismatching gradient by FQN from `meta`.
- [ ] **Step 2:** Run against the Prefix in the AOT env → FAIL (no runner).
- [ ] **Step 3:** Implement. In `action.yml`, change the pytest line to run `test_lstm_roundtrip.py` **and** `test_lstm_backward_aot.py` (the gradcheck/export tests then run in tier2 and release). `action.yml` is not a rule-(1b) path; confirm with `classify-gate.sh` as in Task 4 (expected `mode=tier1` for that file alone).
- [ ] **Step 4:** Tests PASS. Then the frozen paths: `FIXTURES_DIR=<Task 4 emit dir> ETNP_PREFIX=$SCRATCH/prefix python extras/lstm/test/consumer_smoke.py` → `consumer smoke OK` and `consumer smoke OK training`. With the **published** `v1.5.1-1` fixtures (`gh release download v1.5.1-1 -p 'etnp-lstm-fixtures-*'`) → `consumer smoke OK` and the SKIP line, exit 0.
- [ ] **Step 5: Red check.** Rebuild extras with the backward TU removed from `etnp_ops_lstm` (local only) → the training round trip fails with an operator-not-found error, not a pass. Restore.
- [ ] **Step 6:** Commit `test(lstm): training round trip + consumer smoke (#62)`.

### Task 6: Local tier2-equivalent run

**Files:** none (verification)

- [ ] **Step 1:** From a `git archive HEAD` copy, in the container: reproduce the `live-roundtrip` job — fresh `v1.5.1-1` Prefix, the `--extras-only` rebuild, then the `lstm-roundtrip` action's commands. Expected: all tests in both files pass.
- [ ] **Step 2:** Reproduce `fast-gate` (tier1): `consumer_smoke.py` over the published `v1.5.1-1` fixtures → forward OK + training SKIP.
- [ ] **Step 3:** Classify the branch: `git diff --name-only main > $SCRATCH/changed; GATE_ET_TAG=v1.5.1 GATE_RELEASE_TAG=v1.5.1-1 bash scripts/classify-gate.sh $SCRATCH/changed` → `mode=tier2`. If not, STOP (Global Constraints).
- [ ] **Step 4:** Confirm downstream tolerance: `executorch-numpy-runtime` vendors the fixture files by name (`tests/models/README.md`, `tests/test_lstm_smoke.py`); extra members don't affect it. Note this in the PR body.

### Task 7: Docs

**Files:** Modify `docs/lstm-op-consumer-guide.md`, `extras/README.md` (if it enumerates ops), `CLAUDE.md` (one line in the custom-ops section), `docs/extras-gate.md` (tier2 now proven; training check + SKIP semantics)

- [ ] **Step 1:** Consumer guide gains a **Training** section: op name + schema; export recipe (import `extras.lstm.aot.etnp_lstm_op` before `_export_forward_backward`, `external_mutable_weights=True`); absent biases → `None` grads; `grad_h0/grad_c0` are computed but not verified through a `.pte` yet; an **Unoptimized** paragraph (scalar, single-threaded, linear in T, sized for hundreds–thousands of params; forward speed unaffected). Record the recipe exactly as Task 2 proved it.
- [ ] **Step 2:** Commit `docs(lstm): training with lstm_backward (#62)`.

### Task 8: PR and #28

- [ ] **Step 1:** Push; open PR to `main` titled `feat: etnp::lstm backward op for training (#62)`. Body: summary, the tier2-classification evidence (Task 6 Step 3), downstream note (Task 6 Step 4), the unoptimized disclaimer, "Closes #62" **only after** a release ships it — use "Part of #62" (acceptance includes a release).
- [ ] **Step 2:** Watch the `extras-gate` run; confirm `classify` emitted `tier2` and `live-roundtrip` ran green. Link that job in the PR body.
- [ ] **Step 3:** Draft (do not post) the #28 closing comment: green `live-roundtrip` link; routing reachable; answer to "should full reuse tier2's round trip" — no, the `full` split saves ~10 min wall clock, and both forms consume the same case modules (`lstm_case.py`, `lstm_train_case.py`) so they cannot drift. Hand it to the user with the PR link. Merge and the `v1.5.1-2` tag are the user's call.
