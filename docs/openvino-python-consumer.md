# Consuming the OpenVINO delegate from Python

For a slim, torch-free Python package built on this repo's runtime tarballs.

## What you need, and what you don't

The OpenVINO delegate is **already compiled into** every `linux-x86_64` runtime tarball
(`bare`, `logging`, `devtools`) as `lib/libopenvino_backend.a`. You do not enable anything.

What the tarball does **not** contain is the OpenVINO runtime itself. The delegate resolves the
OpenVINO C API with `dlopen` at first use, so OpenVINO is a **runtime** dependency only. Nothing
on this path imports PyTorch.

Exporting a model (the partitioner and quantizer) is a separate concern that lives in the
upstream `executorch` Python package and needs torch. This repo ships runtime artifacts only.

## Getting the OpenVINO runtime

**Option A — our published asset (preferred).** Each release publishes
`openvino-runtime-<ovver>-linux-x86_64.tar.gz` with a SHA-256 and a build attestation, pinned in
`EtRuntimePin.cmake` as `ET_RUNTIME_OPENVINO_URL` / `ET_RUNTIME_OPENVINO_SHA256` /
`ET_RUNTIME_OPENVINO_VERSION`. It is a flat directory that self-resolves, and the hash pin means
you get identical bytes on every build.

**Option B — pip.** `pip install "openvino>=2025.1.0,<2026.0.0"`.

## The one thing that will bite you

**The pip wheel has no unversioned `libopenvino_c.so`.** It ships only the SONAME-versioned file
(e.g. `libopenvino_c.so.2541`), but the delegate's default lookup is the *unversioned* name. So
with a plain `pip install`, the default lookup **fails**:

```
dlopen("libopenvino_c.so") -> cannot open shared object file: No such file or directory
```

You must therefore set `OPENVINO_LIB_PATH`. Three rules:

1. It is the **full path to the `.so` file**, not a directory. (The error message mentions
   `LD_LIBRARY_PATH`, which reads like it wants a directory. It does not.)
2. Set it **before the first inference**. Loading happens once under `std::call_once` with no
   retry — if the first attempt fails, the process stays broken until restart.
3. You do **not** need `LD_LIBRARY_PATH`. Every OpenVINO library carries `RPATH=$ORIGIN`, so
   pointing at one file resolves the rest of the graph from the same directory.

Resolve it like this:

```python
import glob
import os
from importlib.util import find_spec


def openvino_lib_path() -> str:
    """Absolute path to libopenvino_c.so.* inside the installed openvino wheel."""
    spec = find_spec("openvino")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError('openvino is not installed; pip install "openvino>=2025.1.0,<2026.0.0"')
    libs = os.path.join(list(spec.submodule_search_locations)[0], "libs")
    matches = sorted(glob.glob(os.path.join(libs, "libopenvino_c.so*")))
    if not matches:
        raise RuntimeError(f"no libopenvino_c.so* under {libs}")
    return matches[0]


# MUST run before the first inference.
# Note the explicit guard rather than os.environ.setdefault(...): setdefault evaluates its default
# eagerly, so it would call openvino_lib_path() — and raise if the pip wheel is absent — even when
# OPENVINO_LIB_PATH is already set correctly (e.g. you are using the published bundle from
# Option A, or an operator exported it).
if "OPENVINO_LIB_PATH" not in os.environ:
    os.environ["OPENVINO_LIB_PATH"] = openvino_lib_path()
```

If you use our published asset instead, the path is simply
`<extracted>/openvino-runtime-<ovver>-linux-x86_64/lib/libopenvino_c.so` — we add the unversioned
symlink the wheel omits, so either name works.

## Version compatibility

A `.pte` with an OpenVINO delegate embeds a **precompiled OpenVINO blob** (the AOT side calls
`compiled.export_model()`; the runtime calls `ov_core_import_model`). So the export-time and
runtime OpenVINO versions have to be compatible.

Measured across the 2025.x line, with a corrupted-blob control confirming the check is real:

| blob built with | imported by | result |
|---|---|---|
| corrupted bytes | 2025.4.1 | **fails** (control) |
| 2025.4.1 | 2025.4.0 | ok |
| 2025.4.1 | 2025.1.0 | ok |
| 2025.1.0 | 2025.4.1 | ok |

So `>=2025.1.0,<2026.0.0` is supported. The safe rule is **runtime version ≥ export version** —
the evidence above comes from a trivial graph and does not exercise version-gated operators.

Pin **one exact** OpenVINO version rather than floating within the supported range, and record it
next to your package version. A range lets a rebuild silently resolve a different OpenVINO than
the one your models were exported against, which surfaces as an import failure at model load
rather than at install time.

## Troubleshooting

| symptom | cause |
|---|---|
| `OpenVINO runtime not found (dlopen failed…)` | `OPENVINO_LIB_PATH` unset, or set to a directory instead of a file |
| Works once, then never again in the same process | first load failed; `std::call_once` does not retry — fix the env and restart |
| `IMPORT FAILED` at model load | blob/runtime version mismatch; re-export or upgrade the runtime |
| Delegate silently unused | the `.pte` was not exported with the OpenVINO partitioner |
