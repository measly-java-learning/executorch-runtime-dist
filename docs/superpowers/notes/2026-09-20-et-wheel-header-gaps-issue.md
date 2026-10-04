# DRAFT upstream issue — pytorch/executorch

> Draft for submission. Target: `pytorch/executorch`, issue (not PR).
> Status: not yet filed.

---

**Title:** 1.5.0 C++ SDK: `threadpool.h` is omitted although the target and
symbols ship; XNNPACK headers absent for custom-op builds

## Summary

The 1.5.0 wheel's C++ SDK is genuinely usable — we built a third-party custom
operator against it and ran it successfully. Two header gaps stopped that from
working without borrowing files from a source checkout.

The first looks like a straightforward oversight. The second is a feature
request.

## 1. `extension/threadpool/threadpool.h` is not shipped

The wheel ships the library, exports the symbols, and defines the CMake target —
but omits the header that declares the API.

```console
$ ls executorch/include/executorch/extension/threadpool/
threadpool_guard.h

$ nm -D --defined-only -C executorch/lib/libexecutorch_threadpool.so | grep threadpool::
... executorch::extension::threadpool::get_threadpool()
... executorch::extension::threadpool::get_pthreadpool()
... executorch::extension::threadpool::ThreadPool::run(...)
... executorch::extension::threadpool::ThreadPool::ThreadPool(unsigned long)
```

`executorch-config.cmake` defines `executorch::threadpool` and documents it as
"The shared thread pool". So a consumer can link the thread pool but cannot call
`get_threadpool()`, because nothing declares it.

`threadpool_guard.h` ships; `threadpool.h` and `cpuinfo_utils.h`, in the same
source directory, do not. Both exist in the tree at `v1.5.0`.

**Impact:** any consumer whose kernel wants to run work on ExecuTorch's own pool
— which is the documented way to avoid creating a second, uncoordinated pool —
is blocked. We worked around it with
`git show v1.5.0:extension/threadpool/threadpool.h`, which is not something a
wheel consumer should have to do.

**Suggested fix:** include `extension/threadpool/threadpool.h` (and
`cpuinfo_utils.h`) in the wheel's `include/` tree.

### Why this one is worth care

While working around it we hit the failure mode this gap invites. Substituting
the same header from an **older** release (1.3.1) built and ran cleanly — and was
silently wrong: `ThreadPool` gained a member in 1.4.0.

```diff
  52a53,56
+   /** Returns the number of threads in the threadpool. ... */
  99a104,105
+   // The number of threads in the threadpool.
+   size_t thread_count_;
```

A consumer who solves the missing header by grabbing a copy from anywhere other
than the exact matching tag gets an ABI mismatch that compiles, links, runs, and
passes tests. Shipping the header removes the temptation entirely.

## 2. XNNPACK / pthreadpool headers for custom-op builds

This one is a request rather than a bug.

The wheel's `libexecutorch_backend_xnnpack.so` exports 712 XNNPACK entry points (`nm -D` text symbols),
but ships no `xnnpack.h` or `pthreadpool.h`. A custom operator that uses XNNPACK
directly — rather than only through the delegate — can therefore link but not
compile against the SDK.

Our case is an LSTM kernel that drives XNNPACK for its batched input projection
and keeps its own operator cache. We supplied the headers from
`google/XNNPACK@92a7ad50` (the submodule pin at `v1.5.0`) and everything built
and ran correctly against the wheel's binaries:

```
-- assert_extras_registered: all extras registrar TUs present: [_GLOBAL__sub_I_etnp_lstm.cpp]
$ ./lstm_kernel_test
OK: etnp::lstm.out analytic recurrence correct
```

So the binaries are fully capable; only the headers are missing.

**Suggested fix:** ship `xnnpack.h` and `pthreadpool.h` alongside the delegate,
or document the exact submodule commits per release so consumers can fetch
matching headers reliably.

If exporting XNNPACK's API surface from the wheel is undesirable as a support
commitment, the documentation option alone would help — the pins are already
determinable from the tag, but only if you know to look, and getting it wrong
fails silently for the same ABI reasons as above.

## Context

We maintain a downstream project that repackages ExecuTorch as relocatable
`-fPIC` desktop tarballs, which existed because upstream had no such artifact.
1.5.0's C++ SDK substantially closes that gap on Linux and macOS — the
`executorch::` imported targets, the `$ORIGIN` handling and the CMake-version
notes in `executorch-config.cmake` all clearly anticipate exactly our use case,
and it shows.

These two headers are, as far as we can tell, the only thing standing between
the wheel and dropping our own Linux build entirely.

---

# Related, smaller — may be worth splitting out

## `find_package(ExecuTorch)` succeeds even when the package reports itself broken

The config sets `executorch_FOUND` and `EXECUTORCH_FOUND`, but never
`ExecuTorch_FOUND`. CMake's `REQUIRED` handling checks the `<Name>_FOUND`
spelling as written by the caller.

Observed on a deliberately incomplete prefix: the config correctly detected the
problem, printed its own diagnostic, and returned early —

```
-- ExecuTorch package at  is missing /include, so nothing can compile against it.
```

— and `find_package(ExecuTorch CONFIG REQUIRED)` **still succeeded**, leaving
`EXECUTORCH_INCLUDE_DIRS` empty. The build then failed much later with a
confusing missing-header error instead of at `find_package`.

Calling `find_package(executorch ...)` (lowercase) behaves correctly. But the
in-tree package config has historically been found as `ExecuTorch`, so existing
downstream code uses that spelling, and for those callers the config's own
self-check is silently defeated.

**Suggested fix:** set `ExecuTorch_FOUND` alongside the existing variables in
the early-return path, or normalise on whatever single spelling is intended and
document it.
