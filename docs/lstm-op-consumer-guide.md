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

## Cross-platform note
The live round-trip test gates every *executable* CI target (today linux-x86_64 and
linux-aarch64, both native runners). When macOS/Windows/arm64 targets gain runners,
run the round-trip there too — the per-OS whole-archive path in the helper above is
exactly what it validates.
