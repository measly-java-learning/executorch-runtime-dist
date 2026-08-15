# Consuming the OpenVINO delegate from Java/JNI

For a JVM application shipping qualified jars with platform-specific `.so` files. Linux
`x86_64` only — that is the only platform where this delegate exists.

## What to ship

The OpenVINO delegate is already compiled into every `linux-x86_64` runtime tarball as
`lib/libopenvino_backend.a`. The OpenVINO **runtime** is separate and must be vendored into your
jar. Use our published `openvino-runtime-<ovver>-linux-x86_64.tar.gz` — it is hash-pinned and
attested, so every build vendors identical bytes.

Its `lib/` is a **flat** directory holding exactly seven libraries plus one symlink:

| file | why |
|---|---|
| `libopenvino_c.so` → `libopenvino_c.so.<abi>` | the symlink we add; the wheel omits it |
| `libopenvino_c.so.<abi>` | the C API the delegate dlopens |
| `libopenvino.so.<abi>` | core runtime |
| `libopenvino_intel_cpu_plugin.so` | the CPU device (~52 MB, the bulk of the size) |
| `libopenvino_ir_frontend.so.<abi>` | deserializes the IR embedded in the compiled blob |
| `libtbb.so.12` | threading |
| `libtbbbind_2_5.so.3` | NUMA-aware binding; dlopened by `libtbb` |
| `libhwloc.so.15` | topology; needed by `tbbbind` |

About **69 MB on disk, ~21 MB compressed** in a jar. The GPU/NPU plugins and the ONNX/TF/PyTorch/
Paddle/JAX frontends are deliberately excluded: those parse third-party model formats, which you
never do.

**Do not prune `libopenvino_ir_frontend` along with the other frontends.** It is not a
model-format parser — the blob your `.pte` carries is OpenVINO IR, and importing it needs this
library. Without it the runtime still loads and still reports a CPU device, then fails every
model at load with `failed to import model for device 'CPU' (status=-1)`.

**Extract all of them into one directory and keep them together.** Every library carries
`RPATH=$ORIGIN`, so a flat directory resolves the entire graph with no `LD_LIBRARY_PATH`, no
`ldconfig`, and no system install. Splitting them across directories breaks that.

## The critical part: you cannot use `LD_LIBRARY_PATH` from Java

glibc's dynamic loader reads `LD_LIBRARY_PATH` **once, at process start**. A JVM cannot change
its own — `System.getenv` is read-only, and `ProcessBuilder` only affects child processes. Even
`setenv("LD_LIBRARY_PATH", …)` from JNI is too late to influence later `dlopen` calls.

`OPENVINO_LIB_PATH` does not have this problem: the delegate reads it at `dlopen` time. So from
JNI it is the **only** mechanism that works.

```c
// In your JNI init, AFTER extracting the natives and BEFORE the first inference.
// dir = absolute path to the directory you extracted lib/ into.
static int etnp_init_openvino(const char* dir) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/libopenvino_c.so", dir);
  // overwrite=1: a stale value from a previous init would silently win.
  if (setenv("OPENVINO_LIB_PATH", path, 1) != 0) {
    return -1;
  }
  return 0;
}
```

Three rules, all of which have bitten people:

1. `OPENVINO_LIB_PATH` is the **full path to the `.so` file**, not the directory.
2. Set it **before the first inference**. The delegate loads once under `std::call_once` and
   never retries — a first failure poisons the process until restart.
3. Extract to a **stable, readable** directory. A temp dir cleaned between the `setenv` and the
   first inference fails exactly the same way.

## Platform floor

The bundle is built from the `manylinux2014` wheel; its libraries need at most **glibc 2.17 /
GLIBCXX 3.4.19 / CXXABI 1.3.7**, comfortably below the glibc 2.28 floor of our `linux-x86_64`
runtime tarballs. So if our runtime tarball runs on a host, this bundle does too.

## Why not Intel's toolkit archive?

It is ABI-compatible with `manylinux_2_28` and would work if you installed it yourself. We do not
redistribute it for two reasons: its `runtime/lib/*` is under the Intel OpenVINO Distribution
License (only headers/samples/Python are Apache 2.0) and its `redist.txt` does not list Linux
TBB; and its libraries carry **no `RPATH`**, so making them work from JNI would require
`patchelf` — modifying Intel-provided binaries. The PyPI wheel is Apache 2.0 end to end and
already ships `$ORIGIN`, so we vendor from it and modify nothing.

If you install the Intel archive into your own container instead, note that it *does* ship the
unversioned `libopenvino_c.so` symlink, but you must set `LD_LIBRARY_PATH` to both
`runtime/lib/intel64` **and** `runtime/3rdparty/tbb/lib` at process launch — which, per the
section above, cannot be done from inside the JVM.

## Version compatibility

A `.pte` embeds a precompiled OpenVINO blob, so export-time and runtime versions must be
compatible. Compatibility was measured to hold in both directions across 2025.1 ↔ 2025.4 (with a
corrupted-blob control proving the check is real), so `>=2025.1.0,<2026.0.0` is supported, with
**runtime version ≥ export version** as the safe rule.

Vendor **one exact** OpenVINO version rather than floating within the supported range, and record
it in your jar's manifest. A range lets a rebuild silently vendor a different OpenVINO than the
one your models were exported against, which surfaces as an import failure at model load rather
than at build time.

## Checklist

- [ ] Vendor the six libs + symlink into one flat directory in the Linux-qualified jar
- [ ] Extract them together, preserving the symlink, to a stable directory
- [ ] `setenv("OPENVINO_LIB_PATH", "<dir>/libopenvino_c.so", 1)` in JNI init
- [ ] Do this before the first inference
- [ ] Ship `licenses/` from the bundle — Apache 2.0 plus the hwloc BSD-3-Clause notice
