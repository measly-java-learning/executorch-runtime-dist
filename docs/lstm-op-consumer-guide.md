# Consumer Guide: `etnp::lstm.out`

This runtime ships a first-party custom LSTM operator, `etnp::lstm.out`, inside
**every variant** of the tarball (bare/logging/devtools) on every platform. Any
consumer that links the runtime and whole-archives the op gets it registered at
load time — no build flag.

## The op
- **Name (frozen, baked into `.pte`s):** `etnp::lstm.out` (functional `etnp::lstm`).
- **Schema:** single-layer, unidirectional, `batch_first=False`, float32, contiguous.
  `input [T,B,I]`, `h0/c0 [B,H]`, `w_ih [4H,I]`, `w_hh [4H,H]`, optional biases `[4H]`;
  `output [T,B,H]`, `hn/cn [B,H]`. Gate order i,f,g,o.
- Produce a `.pte` with the AOT definition in `extras/lstm/aot/etnp_lstm_op.py`
  (`to_edge_transform_and_lower` with **no** partitioner keeps the op opaque;
  `ToOutVarPass` yields `etnp::lstm.out`).

## Linking (the whole-archive requirement)
`libetnp_ops_lstm.a` is a pure static-initializer registration archive: unless it
is whole-archived at your final link it is GC'd away and you get
"operator etnp::lstm.out not found" at model-load time. The tarball ships a helper
so you don't hand-roll the per-OS flags:

    find_package(executorch CONFIG REQUIRED PATHS "<prefix>/lib/cmake/ExecuTorch")
    include("<prefix>/lib/cmake/ETNPExtras/ETNPExtras.cmake")
    add_library(my_consumer SHARED ...)
    target_link_libraries(my_consumer PRIVATE executorch ...)
    etnp_extras_whole_archive(my_consumer)   # applies --whole-archive / -force_load / /WHOLEARCHIVE:

**ET's own archives still need whole-archiving too.** `ETNPExtras` covers only the
first-party extras (`etnp_ops_lstm`). ExecuTorch's `xnnpack_backend`,
`portable_ops_lib`/`optimized_native_cpu_ops_lib`, etc. must likewise be
whole-archived per ExecuTorch's guidance — `ETNPExtras` deliberately does not
enumerate them (they drift across ET versions).

## Performance envelope (why it exists)
Versus the naive decomposition ExecuTorch emits: the custom `.pte` is **constant in
T** (naive grows with T; 2.8×–27× smaller over T=16→256 at H=32), **faster at every
benchmarked (T,H)** (1.66×–9.78× across H∈{32,64,128}, T∈{16,64,256}), and exports
shapes the naive path cannot complete (T=256,H=128 never finishes a 120s budget).
The custom op is the default choice for the supported LSTM shape.

## Training (`etnp::lstm_backward.out`)
The same bundle also ships the backward op, so a model using `etnp::lstm` can be
exported as a **joint forward+backward graph** and trained inside ExecuTorch (the
optimizer runs outside; this op supplies the gradients).

- **Name (frozen):** `etnp::lstm_backward.out` (functional `etnp::lstm_backward`).
- **Schema:** the forward's inputs plus the incoming output gradients, returning seven
  tensors — always seven, because ExecuTorch out-variants cannot return `None`:

      lstm_backward(Tensor grad_output, Tensor? grad_hn, Tensor? grad_cn,
                    Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh,
                    Tensor? b_ih, Tensor? b_hh)
        -> (grad_input, grad_h0, grad_c0, grad_w_ih, grad_w_hh,
            grad_b_ih, grad_b_hh)

  `grad_hn`/`grad_cn` are optional: `None` means zero (the common case where the
  loss uses only `output`). An absent bias still gets a `[4H]` gradient tensor; the
  autograd wrapper discards it so the torch side sees `None`.
- **Export recipe** (proven in `extras/lstm/test/test_lstm_backward_aot.py` and the
  live round-trip):

      import extras.lstm.aot.etnp_lstm_op   # registers etnp::lstm AND its autograd
      from torch.export.experimental import _export_forward_backward
      from executorch.exir import ExecutorchBackendConfig, to_edge

      ep = torch.export.export(model, example_inputs)   # forward returns the loss
      joint = _export_forward_backward(ep)
      et = to_edge(joint).to_executorch(
          config=ExecutorchBackendConfig(external_mutable_weights=True))
      et.save("train.pte")                     # .pte (serializes on first access)
      et.write_tensor_data_to_file("<outdir>")  # external weights: one .ptd

  Import `etnp_lstm_op` **before** exporting — the autograd formula is registered by
  importing it, and without it `_export_forward_backward` cannot differentiate the
  op. Load the pair with `executorch::extension::Module(pte, ptd)`; the program's
  `__et_training_parameters_index_forward` method gives the boundary between the
  loss+gradients outputs and the parameter outputs.
- **What is verified end to end:** the loss and every **parameter** gradient
  (`grad_w_ih`, `grad_w_hh`, `grad_b_ih`, `grad_b_hh`, and both `Linear` layers —
  the latter proves `grad_input`) match torch eager through the `.pte`/`.ptd` round
  trip. A second round-trip test runs **two** executes in one process with a dense
  in-place SGD update between them. `grad_h0`/`grad_c0` are computed and covered by
  float64 gradcheck and the C++ kernel unit test, but no shipped sample carries
  state across batches yet, so they are not exercised through a `.pte`.
- **Mutable-weight cache caveat (forward op).** The forward kernel caches its
  XNNPACK-packed projections keyed by the weight pointer, and decides whether to
  repack from a fingerprint that samples only part of each weight/bias. In-place
  training updates keep the pointer. A dense update changes a sampled element and
  triggers a repack — that is what the two-step round trip pins — but an update
  that leaves every sampled element unchanged (frozen/masked gate rows, a sparse
  update) can reuse stale packing, and the backward op's recompute would then
  disagree with the loss. Tracked in
  [#66](https://github.com/measly-java-learning/executorch-runtime-dist/issues/66).
- **Unoptimized on purpose.** The kernel is scalar C++, single-threaded, with no
  XNNPACK/Highway/threadpool: one forward recompute plus one reverse sweep, linear
  in T, sized for hundreds-to-thousands of parameters. It is a separate code path
  and does not change forward speed or behaviour. Optimize if/when training users
  need it.

## Cross-platform note
The live round-trip test gates every *executable* CI target (today linux-x86_64 and
linux-aarch64, both native runners). When macOS/Windows/arm64 targets gain runners,
run the round-trip there too — the per-OS whole-archive path in the helper above is
exactly what it validates.
