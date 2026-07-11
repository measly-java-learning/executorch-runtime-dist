# extras/ — first-party custom ops

Each subdirectory is one op bundle (LSTM is extra #1): `runtime/` (torch-free C++
kernel + registrar), `aot/` (torch export definition), `test/` (mandatory tests),
and `extra.yaml` (the single source of truth for the op name + schema).

## Building the runtime archive
`build-runtime.sh` builds `extras/` against the installed ExecuTorch prefix after
the ET install and installs `libetnp_ops_lstm.a` + `include/etnp/lstm.h` +
`lib/cmake/ETNPExtras/ETNPExtras.cmake` into the prefix. No separate step needed.

## Building `.pte` artifacts / running the round-trip (needs an export venv)
The AOT export path needs the `executorch` Python package installed **from the same
ExecuTorch source (`--et-src`) at the pinned commit** the runtime is built from, so
lowering passes match the runtime exactly. Create the env fresh — it's a prerequisite:

- **Local (fast):** `uv venv --seed --python 3.12 .export-venv && . .export-venv/bin/activate`,
  then `(cd executorch && ./install_executorch.sh)`. (`--seed` gives the venv pip, which
  the installer uses; plain `python3.12 -m venv` works too if `uv` is unavailable.)
- **CI:** install into the container python directly (no venv, no `uv`).

`./install_executorch.sh` pins its own torch — let that version stick (don't re-pin;
the C++ runtime is built from ET source independently, so there's no skew). Then
confirm `from executorch.exir import to_edge_transform_and_lower` imports.

Then: `ETNP_PREFIX=<built-prefix> python -m pytest extras/lstm/test/test_lstm_roundtrip.py`.
