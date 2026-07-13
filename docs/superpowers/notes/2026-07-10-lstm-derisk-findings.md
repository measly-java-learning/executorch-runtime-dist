# LSTM Productionization De-Risk Findings

Date: 2026-07-10  
Task: Task 1 — de-risk spikes (no production code)  
Purpose: Resolve version-sensitive unknowns and record Highway dependency rationale before porting.

---

## Step 1: `make_boxed` Output Cap

**Command run:**
```bash
grep -rn "num_nonconst_tensors\|static_assert" \
  /home/corey/workspace/executorch/runtime/kernel/make_boxed_from_unboxed_functor.h \
  /home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h 2>/dev/null
```

**Actual output:**
```
/home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h:189:  static_assert(
/home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h:212:    constexpr size_t num_nonconst_tensors =
/home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h:215:    static_assert(num_nonconst_tensors == 1, "Invalid number of inputs");
/home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h:217:        call_functor_with_args_from_stack<FuncType, num_nonconst_tensors>(
```

**Exact assertion (file:line):**
- **File:** `/home/corey/workspace/executorch/extension/kernel_util/make_boxed_from_unboxed_functor.h`
- **Line:** 215
- **Text:** `static_assert(num_nonconst_tensors == 1, "Invalid number of inputs");`

**Decision:** The `make_boxed_from_unboxed_functor` in our ET v1.3.1 caps mutable outputs at 1. Since the LSTM cell has 3 mutable outputs (h, c, and the output tensor), the hand-rolled boxed registrar approach is required — we cannot reuse the factory function.

---

## Step 2: XNNPACK Library and Headers in Prefix

**Command run:**
```bash
ls out-logging/lib/libXNNPACK.a out-logging/lib/libpthreadpool.a \
   out-logging/include/xnnpack.h out-logging/include/pthreadpool.h
```

**Actual output:**
```
out-logging/include/pthreadpool.h
out-logging/include/xnnpack.h
out-logging/lib/libXNNPACK.a
out-logging/lib/libpthreadpool.a
```

**Decision:** All four XNNPACK components (library and headers for both XNNPACK and pthreadpool) are present in the relocatable prefix. XNNPACK is available for use in the LSTM gemm projections.

---

## Step 3: aarch64 CI Runner — Native Execution

**File inspected:** `.github/workflows/release.yml`

**Findings from release.yml:**

1. **Line 13–17** (PLATFORMS env matrix):
   ```yaml
   PLATFORMS: >-
     [
         {"platform":"linux-x86_64","container":"quay.io/pypa/manylinux_2_28_x86_64","runs_on":"ubuntu-latest"},
         {"platform":"linux-aarch64","container":"quay.io/pypa/manylinux_2_28_aarch64","runs_on":"ubuntu-24.04-arm"}
     ]
   ```

2. **Line 39** (build job runner):
   ```yaml
   runs-on: ${{ matrix.combo.runs_on }}
   ```

**Decision:** The linux-aarch64 CI matrix element uses `runs_on: "ubuntu-24.04-arm"`, which is a native ARM64 GitHub Actions runner. This means the aarch64 build in the release workflow **executes natively on ARM hardware**, not under QEMU emulation. The round-trip test in Task 8 can therefore run on aarch64 directly if needed.

---

## Step 4: Highway vs. `at::vec` Dependency Rationale

**Commands run:**
```bash
# at::vec headers are NOT in the relocatable prefix
find out-logging/include -path '*ATen/cpu/vec*' -o -path '*optimized/vec*' 2>/dev/null

# at::vec headers exist only under torch's includes (torch-coupled)
find /home/corey/workspace/executorch -path '*ATen/cpu/vec/vec.h' 2>/dev/null | head -1
```

**Actual outputs:**
1. First command: (empty — no results)
2. Second command:
   ```
   /home/corey/workspace/executorch/.venv/lib/python3.12/site-packages/torch/include/ATen/cpu/vec/vec.h
   ```

**Decision:** 

ExecuTorch's optimized elementwise SIMD operations (`sigmoid`, `tanh`, arithmetic) are provided by `at::vec::Vectorized` — a PyTorch/ATen facility reachable via `executorch::vec` headers that include `<ATen/cpu/vec/vec.h>`. However, these headers are **torch-coupled** (they live under PyTorch's site-packages, not in a torch-free relocatable prefix).

Our LSTM kernel is **torch-free by contract** (Face 1 of the runtime). The at::vec facility:
- Requires ATen/torch headers at compile time
- Is **not included in the relocatable prefix** (`out-logging/include/`), which is torch-free

Therefore, we cannot use `at::vec` without breaking the torch-free runtime contract. **Highway** (a self-contained, torch-free SIMD abstraction layer, hash-pinned as a build dependency) is the correct substitute for elementwise ops.

The **XNNPACK library** (already in the prefix) is reused for the gemm projections, replacing ExecuTorch's `cpublas::gemm` (which depends on Eigen and is not as optimized for inference).

---

## Summary

| Finding | Conclusion |
|---------|-----------|
| **make_boxed cap** | Static assert at 1 output ⇒ hand-rolled boxed registrar required |
| **XNNPACK availability** | All libs and headers present in prefix ⇒ use for projections |
| **aarch64 runner** | Native `ubuntu-24.04-arm` runner ⇒ Task 8 round-trip can execute on aarch64 |
| **Highway rationale** | at::vec is torch-coupled; Highway is torch-free SIMD substitute ⇒ add Highway dependency |

