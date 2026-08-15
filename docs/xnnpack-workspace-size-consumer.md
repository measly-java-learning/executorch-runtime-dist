# Consuming the XNNPACK workspace-size backend option

How to read the size, in bytes, of the memory arena the XNNPACK delegate allocates, through the
already-installed backend-options API. This exists for host-side native-memory reporting: when you
account for what the runtime holds, the XNNPACK workspace is a real allocation that is otherwise
invisible to you.

## The contract in one paragraph

Every variant of every release in this distribution ships the XNNPACK delegate with a **read-only**
backend option — backend `XnnpackBackend`, key `workspace_size_bytes` — that reports the process-wide
XNNPACK workspace arena size in bytes as an `int`. `XNNPACKBackend.h` does **not** ship in the
tarball, so a consumer cannot include it; you hardcode the two strings exactly as written above.

## Reading the value

```cpp
#include <cstdio>
#include <variant>

#include <executorch/runtime/backend/interface.h>
#include <executorch/runtime/backend/options.h>

using executorch::runtime::BackendOption;
using executorch::runtime::Error;
using executorch::runtime::Span;

// Hardcoded, not included: XNNPACKBackend.h is not an installed header, so a consumer names
// these by string exactly as this example does.
static constexpr const char* kBackend = "XnnpackBackend";
static constexpr const char* kKey = "workspace_size_bytes";

// Returns the XNNPACK workspace arena size in bytes, or -1 on failure.
static int read_workspace_size() {
  BackendOption opt{};
  std::snprintf(opt.key, sizeof(opt.key), "%s", kKey);
  Span<BackendOption> span(&opt, 1);
  const auto err = executorch::ET_RUNTIME_NAMESPACE::get_option(kBackend, span);
  if (err != Error::Ok) {
    std::fprintf(stderr, "get_option failed (error %d)\n", static_cast<int>(err));
    return -1;
  }
  auto* val = std::get_if<int>(&opt.value);
  if (!val) {
    std::fprintf(stderr, "workspace_size_bytes is not an int\n");
    return -1;
  }
  return *val;
}
```

Call `read_workspace_size()` whenever you need the figure; the read is synchronized with delegate
init. The value is derived state — there is no way to write it (see "Read-only" below).

## Semantics

- **Zero until the first XNNPACK-delegated method loads.** The arena is created **lazily** during
  delegate init, so reading `0` before any XNNPACK-delegated method has loaded is correct behaviour,
  not a broken accessor. Poll after a load that definitely delegated.
- **`int` bytes, saturating at `INT_MAX`.** The value is clamped rather than narrowed, so it never
  wraps negative. A clamped byte count degrades a memory report; a wrapped one would corrupt it.
- **Process-wide.** The figure covers all live XNNPACK delegate instances in the process, because the
  build pins `EXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON` — all delegates share one workspace arena. Do
  not sum this value across instances; it is already the total.
- **Read-only.** `set_option` on this key returns `Error::InvalidArgument`. The existing option chain
  would otherwise swallow a write as a silent no-op success.
- **High-water mark, including allocator alignment padding.** The arena is grown as needed by
  `xnn_create_runtime_v4` and is **never shrunk**, so the value is the peak size, not the current
  live footprint. It includes alignment padding, so it is a slight over-estimate of the exact bytes
  of tensor data.
- **Not upstream.** This option is a **vendored patch in this distribution**; stock ExecuTorch and
  stock XNNPACK have no size accessor. Code depending on it will **not build or run** against an
  unpatched ExecuTorch. If you ever stop consuming this distribution's tarballs, this feature
  disappears with them.

## Checklist

- [ ] Read via `executorch::ET_RUNTIME_NAMESPACE::get_option("XnnpackBackend", …)` with key
      `workspace_size_bytes`, value read with `std::get_if<int>`
- [ ] Treat `0` before the first delegated load as correct, and re-read after a delegated load
- [ ] Report the value as-is (`int`, saturating at `INT_MAX`); never re-derive or sum per instance
- [ ] Never call `set_option` on this key (it returns `InvalidArgument`)
- [ ] Remember the figure includes alignment padding and is a high-water mark
