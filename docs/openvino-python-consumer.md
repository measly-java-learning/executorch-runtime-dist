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

**Option A — our published asset (preferred).** Each release publishes an
`openvino-runtime-<ovver>-<platform>.tar.gz` per platform (currently `linux-x86_64` and
`windows-x86_64`, the latter also serving `windows-x86_64-static`) with a SHA-256 and a build
attestation, pinned in `EtRuntimePin.cmake` as per-platform `ET_RUNTIME_OPENVINO_URL_<platform>` /
`ET_RUNTIME_OPENVINO_SHA256_<platform>` vars, read through `et_runtime_openvino_url(<platform> url
sha)` — which returns empty strings for a platform with no bundle (the vars are absent entirely
from a release that published no bundle). It is a flat directory that self-resolves, and the hash pin means
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

## Windows

The delegate ships in the `windows-x86_64` and `windows-x86_64-static` tarballs, and each release
now publishes a Windows OpenVINO runtime bundle — `openvino-runtime-<ovver>-windows-x86_64.tar.gz`,
pinned in `EtRuntimePin.cmake` under the `windows-x86_64` row (aliased for
`windows-x86_64-static`). Fetch it with the same selector you use on Linux:

```cmake
et_runtime_openvino_url("${ET_RUNTIME_ROW}" ov_url ov_sha)
if(ov_url)
  FetchContent_Declare(openvino_runtime
    URL       "${ov_url}"
    URL_HASH  "SHA256=${ov_sha}")
  FetchContent_MakeAvailable(openvino_runtime)
endif()
```

`OPENVINO_LIB_PATH` is read from the **process environment** (`getenv`) at load time, so a CMake
`set()` never reaches it — the value must be in the environment of the process from launch. Set it
in the shell that starts the application, before the process runs. The value that always works is
the pip wheel's DLL inside your venv: pip installs the Windows wheel's DLLs at a fixed location,
and `%VIRTUAL_ENV%` is always an absolute path:

```
py -3.12 -m pip install openvino==2025.4.1
set OPENVINO_LIB_PATH=%VIRTUAL_ENV%\Lib\site-packages\openvino\libs\openvino_c.dll
```

(PowerShell: `$env:OPENVINO_LIB_PATH = "$env:VIRTUAL_ENV\Lib\site-packages\openvino\libs\openvino_c.dll"`)

If you use the published bundle instead, point the variable at the extracted DLL's absolute path
the same way, from the same shell:

```
set OPENVINO_LIB_PATH=C:\path\to\openvino-runtime-2025.4.1-windows-x86_64\lib\openvino_c.dll
```

If your launcher cannot set a process variable, assigning `os.environ["OPENVINO_LIB_PATH"]` in
Python before the first inference also works — but set it in the launching shell wherever you can;
setting it inside the application is the fallback, not the pattern.

`OPENVINO_LIB_PATH` **must be absolute on Windows.** The backend passes an absolute path to
`LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`, which is what lets a flat bundle resolve
its own siblings — Windows has no `$ORIGIN`. A bare filename falls back to the default search order
(PATH), which will not find the sibling DLLs of an arbitrary directory.

The OpenVINO DLLs are built against the dynamic CRT and import `MSVCP140.dll` / `VCRUNTIME140.dll`
from System32, so the **Microsoft Visual C++ redistributable must be installed**. Without it the
load fails with error 126 (`ERROR_MOD_NOT_FOUND`) — which can mean a *dependency* was not found,
not just the DLL itself. A `/MT` static consumer against these `/MD` DLLs is safe: every OpenVINO
allocation is released through an OpenVINO-side free function, so no CRT object crosses the
boundary.
