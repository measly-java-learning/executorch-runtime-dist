# LSTM XnnLinearCache USDT Tracepoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Linux USDT tracepoints to the LSTM op's `XnnLinearCache` LRU so consumers can observe cache hit/miss/eviction behavior at runtime — answering "is `kMaxEntries=16` enough for my workload?" — with zero linked runtime dependency.

**Architecture:** Each probe is a header-only `<sys/sdt.h>` `DTRACE_PROBEn` (a `nop` + a non-allocated `.note.stapsdt` ELF note) fired from `XnnLinearCache::get()`. A CMake option (default-on Linux, all variants) sets a compile definition that flips the probe macros from no-ops to real probes. A `readelf`-based guard, attached POST_BUILD to the existing whole-archive link probe, proves the notes survive the link and enforces the committed probe-name/arity contract. Provenance is recorded in `BUILDINFO`.

**Tech Stack:** C++17, CMake, systemtap SDT (`sys/sdt.h`), bash, manylinux_2_28 / gcc-toolset-14, binutils (`readelf`).

## Global Constraints

- Build runs **inside `quay.io/pypa/manylinux_2_28_x86_64`** (and `_aarch64`); the recipe never clones ExecuTorch.
- Everything is **`-fPIC`** / `CMAKE_POSITION_INDEPENDENT_CODE=ON`; C++ standard is **C++17**.
- **Provider name `etnp` and probe names `lstm_xnn_cache__hit` / `__miss` / `__evict` are a committed, stable contract** — renaming any is a breaking change. Argument sets are documented but best-effort (may gain trailing args).
- **Argument widths are pinned:** channel/occupancy/capacity args are `uint32_t`; `evicted_age` is `uint64_t`.
- **No is-enabled semaphores** — plain `DTRACE_PROBEn` only.
- **Gating:** mandatory `__linux__` header gate + opt-out CMake option `ETNP_ENABLE_USDT`, **default ON on Linux, forced OFF elsewhere**, applied to **all three variants** (`bare`/`logging`/`devtools`).
- **`sys/sdt.h` is installed (`systemtap-sdt-devel`), never vendored.** If USDT is requested but the header is missing, **fail loudly** (FATAL) — never silently ship a probe-less artifact.
- **`.etnp_usdt` provenance marker is read at package time and NOT shipped** in the tarball (same treatment as `.et_commit`).

## Branch

Work happens on `feature/lstm-cache-usdt-tracepoints` (already created; the design doc is committed there). No worktree needed.

## File Structure

- **Create** `scripts/check-usdt-notes.sh` — the contract enforcer: given a binary (or canned readelf text via a test hook), assert the `etnp` provider + three probes with expected arities, or assert their absence. Used by both the POST_BUILD guard and the hermetic test.
- **Create** `test/usdt_notes.test.sh` — hermetic unit test for `check-usdt-notes.sh` using canned readelf text (runs in `test/run.sh`).
- **Create** `extras/lstm/runtime/etnp_usdt.h` — the probe macro header (gate + `DTRACE_PROBEn` wrappers / no-op fallbacks).
- **Create** `test/usdt_probe_smoke.sh` — build-environment smoke: compile a tiny TU using `etnp_usdt.h`, link, and assert notes via `check-usdt-notes.sh` (NOT in `run.sh`; needs a toolchain + `sys/sdt.h`).
- **Create** `docs/lstm-xnn-cache-usdt.md` — consumer-facing probe contract + bpftrace recipes.
- **Modify** `extras/lstm/runtime/xnn_linear_cache.h` — `#include "etnp_usdt.h"` and insert three probe calls in `get()`.
- **Modify** `extras/CMakeLists.txt` — the `ETNP_ENABLE_USDT` option, effective-value logic, `check_include_file_cxx` FATAL guard, per-op compile definition, POST_BUILD USDT guard, and the `.etnp_usdt` provenance-marker install.
- **Modify** `build-runtime.sh` — install `systemtap-sdt-devel` in `build_extras`.
- **Modify** `scripts/package.sh` — read `.etnp_usdt`, pass `USDT=` to buildinfo.
- **Modify** `scripts/gen-buildinfo.sh` — require `USDT`, emit `usdt=`.
- **Modify** `test/buildinfo.test.sh` and `test/package.test.sh` — cover the new field/marker.
- **Modify** `README.md` and `CLAUDE.md` — document the probes / contract.

---

### Task 1: Probe contract enforcer + hermetic test

The reusable check that both the build guard and CI depend on. Pure shell, fully unit-testable with canned `readelf` output (mirrors the `GATE_*` env-hook style in `scripts/classify-gate.sh`).

**Files:**
- Create: `scripts/check-usdt-notes.sh`
- Test: `test/usdt_notes.test.sh`

**Interfaces:**
- Produces: `scripts/check-usdt-notes.sh --expect <on|off> <binary>`. Exit 0 on contract satisfied, 1 on violation, 2 on usage error. Test hook: if env `USDT_READELF_TEXT` is set, it is used verbatim instead of running `readelf` on `<binary>`. Enforces provider `etnp` and probes `lstm_xnn_cache__hit` (4 args), `__miss` (4 args), `__evict` (7 args); arity is counted as the number of `@` in a probe's `Arguments:` line.

- [ ] **Step 1: Write the failing test**

Create `test/usdt_notes.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
CHK="$here/../scripts/check-usdt-notes.sh"

# Canned readelf --notes output with all three probes at correct arity (4/4/7).
good="$(cat <<'EOF'
Displaying notes found in: .note.stapsdt
  Owner                Data size 	Description
  stapsdt              0x0000004c	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__hit
    Location: 0x1234, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx
  stapsdt              0x0000004e	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__miss
    Location: 0x1240, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx
  stapsdt              0x0000005a	NT_STAPSDT (SystemTap probe descriptors)
    Provider: etnp
    Name: lstm_xnn_cache__evict
    Location: 0x1250, Base: 0x2000, Semaphore: 0x0
    Arguments: -4@%edi -4@%esi -4@%edx -4@%ecx -4@%r8d -4@%r9d -8@%rax
EOF
)"

# happy path: expect on -> pass
out="$(USDT_READELF_TEXT="$good" bash "$CHK" --expect on /nonexistent 2>&1)"; rc=$?
assert_eq "$rc" "0" "expect on with all three probes -> pass"

# missing __evict -> fail
noevict="$(printf '%s\n' "$good" | grep -v 'lstm_xnn_cache__evict')"
USDT_READELF_TEXT="$noevict" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but __evict absent -> fail"

# wrong arity on __hit (3 instead of 4) -> fail
badarity="${good/-4@%edi -4@%esi -4@%edx -4@%ecx$'\n'  stapsdt/-4@%edi -4@%esi -4@%edx$'\n'  stapsdt}"
USDT_READELF_TEXT="$badarity" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but __hit arity wrong -> fail"

# expect off with no stapsdt -> pass
USDT_READELF_TEXT="no notes here" bash "$CHK" --expect off /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "expect off with no stapsdt -> pass"

# expect off but stapsdt present -> fail
USDT_READELF_TEXT="$good" bash "$CHK" --expect off /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect off but stapsdt present -> fail"

# expect on but no provider at all -> fail
USDT_READELF_TEXT="no notes here" bash "$CHK" --expect on /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "expect on but provider absent -> fail"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/usdt_notes.test.sh`
Expected: FAIL — `scripts/check-usdt-notes.sh` does not exist yet (non-zero exit / errors).

- [ ] **Step 3: Write the implementation**

Create `scripts/check-usdt-notes.sh`:

```bash
#!/usr/bin/env bash
# Assert the committed etnp USDT probe contract in a linked binary (provider +
# probe names + per-probe arity), or assert probes are ABSENT when disabled.
#   check-usdt-notes.sh --expect <on|off> <binary>
# Test hook: if USDT_READELF_TEXT is set, it is used instead of running readelf.
# Arity is the number of '@' in a probe's "Arguments:" line (each arg is size@loc).
set -euo pipefail
EXPECT=""; BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) EXPECT="${2:-}"; shift 2 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) BIN="$1"; shift ;;
  esac
done
case "$EXPECT" in on|off) ;; *) echo "usage: check-usdt-notes.sh --expect <on|off> <binary>" >&2; exit 2 ;; esac

if [ -n "${USDT_READELF_TEXT+x}" ]; then
  notes="$USDT_READELF_TEXT"
else
  [ -n "$BIN" ] && [ -f "$BIN" ] || { echo "check-usdt-notes: binary not found: '$BIN'" >&2; exit 2; }
  notes="$(readelf --notes "$BIN")"
fi

has_stapsdt=0
printf '%s\n' "$notes" | grep -q 'NT_STAPSDT' && has_stapsdt=1

if [ "$EXPECT" = "off" ]; then
  if [ "$has_stapsdt" -eq 1 ]; then
    echo "FAIL: --expect off but NT_STAPSDT notes are present" >&2; exit 1
  fi
  echo "ok: no stapsdt notes (USDT disabled)"; exit 0
fi

# --expect on
if ! printf '%s\n' "$notes" | grep -q 'Provider: etnp'; then
  echo "FAIL: --expect on but provider 'etnp' absent" >&2; exit 1
fi

fails=0
check_probe() { # <name> <expected-argc>
  local name="$1" want="$2" args got
  # The Arguments line that follows the matching "Name:" line for this probe.
  args="$(printf '%s\n' "$notes" | awk -v n="$name" '
    /^[[:space:]]*Name:[[:space:]]/     { cur=$2 }
    /^[[:space:]]*Arguments:/ { if (cur==n) { sub(/^[[:space:]]*Arguments:[[:space:]]*/,""); print; exit } }')"
  if [ -z "$args" ]; then
    echo "FAIL: probe '$name' not found (or no Arguments line)" >&2; fails=$((fails+1)); return
  fi
  got="$(printf '%s' "$args" | tr -cd '@' | wc -c | tr -d ' ')"
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: probe '$name' arity $got != expected $want (args: $args)" >&2; fails=$((fails+1)); return
  fi
  echo "ok: probe '$name' present with arity $want"
}
check_probe lstm_xnn_cache__hit   4
check_probe lstm_xnn_cache__miss  4
check_probe lstm_xnn_cache__evict 7
[ "$fails" -eq 0 ] || { echo "$fails USDT probe check(s) failed" >&2; exit 1; }
echo "USDT probe contract OK"
```

Make it executable: `chmod +x scripts/check-usdt-notes.sh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/usdt_notes.test.sh`
Expected: all `ok:` lines, exit 0.

Also run the whole suite to confirm nothing else broke:
Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-usdt-notes.sh test/usdt_notes.test.sh
git commit -m "feat: add USDT probe-contract checker + hermetic test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Probe macro header + compile smoke

The header that flips between real probes and no-ops, verified end-to-end with a real compile+link+`readelf` smoke that needs only a toolchain and `sys/sdt.h` (no ExecuTorch).

**Files:**
- Create: `extras/lstm/runtime/etnp_usdt.h`
- Test: `test/usdt_probe_smoke.sh`

**Interfaces:**
- Produces (macros, all no-ops unless `ETNP_USDT_ENABLED` is defined truthy AND `__linux__`):
  - `ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, occ, cap)` → `DTRACE_PROBE4(etnp, lstm_xnn_cache__hit, …)`
  - `ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, occ, cap)` → `DTRACE_PROBE4(etnp, lstm_xnn_cache__miss, …)`
  - `ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, occ, cap, ein, eout, age)` → `DTRACE_PROBE7(etnp, lstm_xnn_cache__evict, …)`
- Consumes: `scripts/check-usdt-notes.sh` from Task 1.

- [ ] **Step 1: Write the failing test**

Create `test/usdt_probe_smoke.sh`:

```bash
#!/usr/bin/env bash
# Build-environment smoke (NOT in run.sh): compile a tiny TU that uses etnp_usdt.h,
# link it, and assert the probe notes survive via scripts/check-usdt-notes.sh.
# Requires: g++, binutils (readelf), and systemtap-sdt-devel (<sys/sdt.h>).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
hdr_dir="$root/extras/lstm/runtime"
tmp="$(mktemp -d)"
cat > "$tmp/smoke.cpp" <<'CPP'
#include "etnp_usdt.h"
int main() {
  ETNP_LSTM_CACHE_PROBE_HIT(1u, 2u, 3u, 16u);
  ETNP_LSTM_CACHE_PROBE_MISS(1u, 2u, 3u, 16u);
  ETNP_LSTM_CACHE_PROBE_EVICT(1u, 2u, 16u, 16u, 4u, 5u, 42ull);
  return 0;
}
CPP

echo "== USDT enabled: notes must be present =="
g++ -O2 -fPIC -DETNP_USDT_ENABLED=1 -I"$hdr_dir" "$tmp/smoke.cpp" -o "$tmp/smoke_on"
bash "$root/scripts/check-usdt-notes.sh" --expect on "$tmp/smoke_on"

echo "== USDT disabled: notes must be absent =="
g++ -O2 -fPIC -I"$hdr_dir" "$tmp/smoke.cpp" -o "$tmp/smoke_off"
bash "$root/scripts/check-usdt-notes.sh" --expect off "$tmp/smoke_off"

echo "USDT PROBE SMOKE PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/usdt_probe_smoke.sh`
Expected: FAIL — `etnp_usdt.h` does not exist (`fatal error: etnp_usdt.h: No such file or directory`).

Note: if `<sys/sdt.h>` is not installed locally, install it first (`sudo dnf install -y systemtap-sdt-devel` / `sudo apt-get install -y systemtap-sdt-dev`), or run this step inside the manylinux container. The hermetic suite (`test/run.sh`) does not depend on this.

- [ ] **Step 3: Write the implementation**

Create `extras/lstm/runtime/etnp_usdt.h`:

```cpp
// USDT (userland statically-defined tracing) probes for the LSTM XnnLinearCache.
// Each probe compiles to a single nop + a non-allocated .note.stapsdt ELF note:
// no linked runtime dependency, zero cost when untraced. Provider/probe names and
// argument widths are a committed contract (see docs/lstm-xnn-cache-usdt.md); the
// POST_BUILD readelf guard enforces them.
//
// Gating: real probes only when ETNP_USDT_ENABLED is defined truthy (set by the
// extras CMake on Linux when ETNP_ENABLE_USDT=ON) AND compiling for __linux__.
// Otherwise every macro is a no-op, so non-Linux/opt-out builds compile cleanly.
#pragma once

#if defined(ETNP_USDT_ENABLED) && ETNP_USDT_ENABLED && defined(__linux__)

#include <cstdint>
#include <sys/sdt.h>

// Widths are pinned (the note records each arg's byte size): u32 for
// channels/occupancy/capacity, u64 for the LRU tick delta.
#define ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, occ, cap)                 \
  DTRACE_PROBE4(etnp, lstm_xnn_cache__hit,                                 \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap))

#define ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, occ, cap)                \
  DTRACE_PROBE4(etnp, lstm_xnn_cache__miss,                                \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap))

#define ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, occ, cap, ein, eout, age) \
  DTRACE_PROBE7(etnp, lstm_xnn_cache__evict,                               \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap),                          \
                (uint32_t)(ein), (uint32_t)(eout), (uint64_t)(age))

#else  // disabled or non-Linux: no-ops

#define ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, occ, cap) ((void)0)
#define ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, occ, cap) ((void)0)
#define ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, occ, cap, ein, eout, age) ((void)0)

#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/usdt_probe_smoke.sh`
Expected: both sections print `ok:` lines and the final `USDT PROBE SMOKE PASS`. (Run in-container if `sys/sdt.h` is not installed locally.)

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/runtime/etnp_usdt.h test/usdt_probe_smoke.sh
git commit -m "feat: add etnp_usdt.h probe macros + compile smoke

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Fire probes from the cache + wire the build guard

Insert the probe calls at the three fire points and wire the CMake option, compile definition, FATAL header check, `systemtap-sdt-devel` provisioning, and the POST_BUILD guard on the whole-archive link probe. Verified by an in-container extras build whose POST_BUILD guard runs `check-usdt-notes.sh`.

**Files:**
- Modify: `extras/lstm/runtime/xnn_linear_cache.h` (include + 3 fire points in `get()`)
- Modify: `extras/CMakeLists.txt` (option, effective value, header FATAL, compile def, POST_BUILD guard)
- Modify: `build-runtime.sh` (`systemtap-sdt-devel` in `build_extras`)

**Interfaces:**
- Consumes: the macros from Task 2 (`etnp_usdt.h`) and `scripts/check-usdt-notes.sh` from Task 1.
- Produces: `ETNP_USDT_EFFECTIVE` (ON/OFF) and `ETNP_USDT_EXPECT_WORD` (`on`/`off`) CMake variables in `extras/CMakeLists.txt` scope, consumed by Task 4's provenance marker.

- [ ] **Step 1: Add the include to `xnn_linear_cache.h`**

In `extras/lstm/runtime/xnn_linear_cache.h`, change:

```cpp
#include "xnn_linear.h"
```
to:
```cpp
#include "xnn_linear.h"
#include "etnp_usdt.h"
```

- [ ] **Step 2: Insert the `__hit` probe**

In `XnnLinearCache::get()`, change the hit branch:

```cpp
      if (it->second->fingerprint == fp) {
        ++s.hits;
        it->second->stamp = ++s.tick;
        return it->second;
      }
```
to:
```cpp
      if (it->second->fingerprint == fp) {
        ++s.hits;
        it->second->stamp = ++s.tick;
        ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, s.map.size(), kMaxEntries);
        return it->second;
      }
```

- [ ] **Step 3: Insert the `__evict` probe**

Change the eviction block:

```cpp
    if (s.map.size() >= kMaxEntries) {
      auto oldest = s.map.begin();
      for (auto jt = s.map.begin(); jt != s.map.end(); ++jt)
        if (jt->second->stamp < oldest->second->stamp) oldest = jt;
      s.map.erase(oldest);  // shared_ptr keeps in-flight users alive
    }
```
to:
```cpp
    if (s.map.size() >= kMaxEntries) {
      auto oldest = s.map.begin();
      for (auto jt = s.map.begin(); jt != s.map.end(); ++jt)
        if (jt->second->stamp < oldest->second->stamp) oldest = jt;
      // occupancy == kMaxEntries here (eviction only happens at the cap); the
      // victim's key + LRU tick delta (s.tick - stamp) are the diagnostic payload.
      ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, s.map.size(), kMaxEntries,
                                  oldest->first.ic, oldest->first.oc,
                                  s.tick - oldest->second->stamp);
      s.map.erase(oldest);  // shared_ptr keeps in-flight users alive
    }
```

- [ ] **Step 4: Insert the `__miss` probe**

Change the tail of `get()`:

```cpp
    s.map.emplace(key, entry);
    return entry;
```
to:
```cpp
    s.map.emplace(key, entry);
    // Post-insert occupancy. Fires only on a successful (re)pack, so it equals
    // s.misses except on the rare XnnLinear::create failure (which returns nullptr).
    ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, s.map.size(), kMaxEntries);
    return entry;
```

- [ ] **Step 5: Add the CMake option + FATAL header check to `extras/CMakeLists.txt`**

Immediately after the `set(CMAKE_POSITION_INDEPENDENT_CODE ON)` line near the top, insert:

```cmake
# --- USDT tracepoints (Linux only; opt-out) ---------------------------------
# Probes are nop + non-alloc .note.stapsdt notes: no linked runtime dep, free
# when untraced. The header is __linux__-gated too; this option is the opt-out.
# Default ON on Linux, forced OFF elsewhere so future non-Linux targets build.
option(ETNP_ENABLE_USDT "Emit USDT tracepoints for the extras (Linux only)" ON)
if(ETNP_ENABLE_USDT AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(ETNP_USDT_EFFECTIVE ON)
  set(ETNP_USDT_EXPECT_WORD "on")
else()
  set(ETNP_USDT_EFFECTIVE OFF)
  set(ETNP_USDT_EXPECT_WORD "off")
endif()
if(ETNP_USDT_EFFECTIVE)
  include(CheckIncludeFileCXX)
  check_include_file_cxx("sys/sdt.h" ETNP_HAVE_SYS_SDT_H)
  if(NOT ETNP_HAVE_SYS_SDT_H)
    # Fail loudly rather than silently ship a probe-less artifact when USDT was
    # requested (same stance as the Highway-license "refuse to ship incomplete").
    message(FATAL_ERROR
      "ETNP_ENABLE_USDT=ON but <sys/sdt.h> not found. Install systemtap-sdt-devel "
      "or configure with -DETNP_ENABLE_USDT=OFF.")
  endif()
endif()
```

- [ ] **Step 6: Set the compile definition on each op archive**

In `extras/CMakeLists.txt`, after the `message(STATUS "etnp_extras: libs=...")` line (i.e. after the op-dir `foreach` has populated `ETNP_EXTRAS_LIBS`), insert:

```cmake
# Turn the probe macros on in each op archive (header is also __linux__-gated).
if(ETNP_USDT_EFFECTIVE)
  foreach(_lib IN LISTS ETNP_EXTRAS_LIBS)
    target_compile_definitions(${_lib} PRIVATE ETNP_USDT_ENABLED=1)
  endforeach()
endif()
```

- [ ] **Step 7: Attach the POST_BUILD USDT guard to the link probe**

In `extras/CMakeLists.txt`, immediately after the existing `add_custom_command(TARGET etnp_extras_link_probe POST_BUILD ...)` block (the one invoking `assert_extras_registered.cmake`), insert:

```cmake
# USDT note guard: prove the probe notes survived the whole-archive link (or are
# absent when disabled) and that the committed provider/probe/arity contract holds.
# readelf is in binutils (as nm is for the registrar guard above).
add_custom_command(TARGET etnp_extras_link_probe POST_BUILD
  COMMAND bash "${CMAKE_CURRENT_LIST_DIR}/../scripts/check-usdt-notes.sh"
          --expect ${ETNP_USDT_EXPECT_WORD} $<TARGET_FILE:etnp_extras_link_probe>
  VERBATIM)
```

- [ ] **Step 8: Provision `sys/sdt.h` in `build-runtime.sh`**

In `build-runtime.sh`, inside `build_extras()`, immediately after the `echo ">> building extras (custom ops) against the installed prefix"` line, insert:

```bash
  # USDT probes need <sys/sdt.h> (systemtap-sdt-devel) at compile time. Install it
  # unconditionally as provisioning; the CMake option ETNP_ENABLE_USDT stays the
  # single source of truth for emission. || echo: never abort a deliberate
  # -DETNP_ENABLE_USDT=OFF build on a box without the package (set -e).
  echo ">> ensuring USDT probe header (systemtap-sdt-devel)"
  dnf install -y systemtap-sdt-devel \
    || echo ">> WARNING: systemtap-sdt-devel install failed; USDT build will FATAL if enabled"
```

- [ ] **Step 9: Verify with an in-container extras build**

This exercises the fire points, the compile def, and the POST_BUILD guard together. Requires a built/extracted ExecuTorch prefix at `out/` (from a prior full build or a downloaded release tarball extracted with `--strip-components=1`).

Run (inside `quay.io/pypa/manylinux_2_28_x86_64`, with `out/` a valid ET prefix):
```bash
export PATH=/opt/python/cp312-cp312/bin:$PATH
pip install ninja
./build-runtime.sh --extras-only --variant logging --prefix "$PWD/out"
```
Expected: the build reaches the link probe and prints the guard's success lines, e.g.:
```
ok: probe 'lstm_xnn_cache__hit' present with arity 4
ok: probe 'lstm_xnn_cache__miss' present with arity 4
ok: probe 'lstm_xnn_cache__evict' present with arity 7
USDT probe contract OK
```
and the build completes with `>> --extras-only done`.

Sanity-check the opt-out path too:
```bash
./build-runtime.sh --extras-only --variant logging --prefix "$PWD/out" \
  && cmake -B out/etnp-off -S extras -DETNP_ENABLE_USDT=OFF -DCMAKE_PREFIX_PATH="$PWD/out" -G Ninja \
  && cmake --build out/etnp-off
```
Expected: the OFF build's guard prints `ok: no stapsdt notes (USDT disabled)`.

Also re-run the hermetic suite (unaffected, but confirm no regressions):
Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 10: Commit**

```bash
git add extras/lstm/runtime/xnn_linear_cache.h extras/CMakeLists.txt build-runtime.sh
git commit -m "feat: fire USDT probes from XnnLinearCache + wire build guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Record USDT state in BUILDINFO provenance

Write the `.etnp_usdt` marker from the extras install, read it in `package.sh`, emit `usdt=` from `gen-buildinfo.sh`, and cover both with tests. So a released artifact self-declares whether it carries probes.

**Files:**
- Modify: `extras/CMakeLists.txt` (write the `.etnp_usdt` marker at install time)
- Modify: `scripts/gen-buildinfo.sh` (require `USDT`, emit `usdt=`)
- Modify: `scripts/package.sh` (read `.etnp_usdt`, pass `USDT=`)
- Test: `test/buildinfo.test.sh`, `test/package.test.sh`

**Interfaces:**
- Consumes: `ETNP_USDT_EXPECT_WORD` (`on`/`off`) from Task 3's `extras/CMakeLists.txt`.
- Produces: `$PREFIX/.etnp_usdt` (content `on\n` or `off\n`); `BUILDINFO` line `usdt=<on|off>`.

- [ ] **Step 1: Write the failing buildinfo test**

In `test/buildinfo.test.sh`, add `USDT=on` to the environment of the `gen-buildinfo.sh` invocation and assert the new field. Change:

```bash
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  bash "$here/../scripts/gen-buildinfo.sh")"
```
to:
```bash
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 USDT=on \
  bash "$here/../scripts/gen-buildinfo.sh")"
```
and add, before the `exit` line:
```bash
assert_contains "$out" "usdt=on" "usdt field"

# USDT is required: omitting it is a hard error (never silently drop provenance).
ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  bash "$here/../scripts/gen-buildinfo.sh" >/dev/null 2>&1
assert_eq "$?" "1" "missing USDT is a hard error"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/buildinfo.test.sh`
Expected: FAIL on `usdt field` (output has no `usdt=`) — and the missing-USDT assertion currently sees exit 0.

- [ ] **Step 3: Implement in `gen-buildinfo.sh`**

In `scripts/gen-buildinfo.sh`, add `USDT` to the required vars — change:

```bash
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
```
to:
```bash
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
: "${USDT:?}"
```
and add a line to the heredoc (after `platform=$PLATFORM`):
```bash
usdt=$USDT
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/buildinfo.test.sh`
Expected: `ok: usdt field` and `ok: missing USDT is a hard error`, exit 0.

- [ ] **Step 5: Write the failing package test changes**

In `test/package.test.sh`, add the marker to the happy-path fixture `p`. After the `echo "deadbeef" > "$p/.et_commit"` line, insert:
```bash
echo "on" > "$p/.etnp_usdt"
```
Then add a new negative case before the final `exit "$ASSERT_FAILS"` line:
```bash
# A missing .etnp_usdt marker must also be a hard error (provenance completeness).
p3="$(mktemp -d)/pfx3"
mkdir -p "$p3/lib/cmake/ExecuTorch" "$p3/include" "$p3/THIRD-PARTY-NOTICES"; : > "$p3/LICENSE"
echo "deadbeef" > "$p3/.et_commit"   # present, so we fail specifically on .etnp_usdt
bash "$here/../scripts/package.sh" --prefix "$p3" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$(mktemp -d)" >/dev/null 2>&1
assert_eq "$?" "1" "missing .etnp_usdt is a hard error"
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bash test/package.test.sh`
Expected: FAIL — `package.sh` does not yet read `.etnp_usdt`, so the new negative case returns 0 (and the happy path may emit no `usdt=`), tripping `missing .etnp_usdt is a hard error`.

- [ ] **Step 7: Implement in `package.sh`**

In `scripts/package.sh`, after the `.et_commit` read block:

```bash
[ -s "$PREFIX/.et_commit" ] || { echo "package.sh: $PREFIX/.et_commit missing or empty (build the runtime first)" >&2; exit 1; }
ET_COMMIT="$(cat "$PREFIX/.et_commit")"
```
insert:
```bash
# .etnp_usdt: written by the extras install (on|off); read for BUILDINFO, never shipped.
[ -s "$PREFIX/.etnp_usdt" ] || { echo "package.sh: $PREFIX/.etnp_usdt missing or empty (build the extras first)" >&2; exit 1; }
USDT_STATE="$(cat "$PREFIX/.etnp_usdt")"
```
Then add `USDT="$USDT_STATE"` to the `gen-buildinfo.sh` env block — change:
```bash
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="manylinux_2_28 gcc-toolset-14" PACKAGE_TAG="$PACKAGE_TAG" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"
```
to:
```bash
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="manylinux_2_28 gcc-toolset-14" PACKAGE_TAG="$PACKAGE_TAG" \
  USDT="$USDT_STATE" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"
```

- [ ] **Step 8: Write the marker from the extras install**

In `extras/CMakeLists.txt`, after the existing `install(FILES "${CMAKE_BINARY_DIR}/ETNPExtras.cmake" DESTINATION lib/cmake/ETNPExtras)` block, insert:

```cmake
# Provenance marker: records effective USDT state for package.sh -> BUILDINFO usdt=.
# Written to the prefix root (read at package time, NOT staged into the tarball —
# same treatment as .et_commit). Value fixed at configure time; path at install time.
install(CODE "file(WRITE \"\${CMAKE_INSTALL_PREFIX}/.etnp_usdt\" \"${ETNP_USDT_EXPECT_WORD}\\n\")")
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `bash test/package.test.sh`
Expected: all `ok:` including `ok: missing .etnp_usdt is a hard error` and the unchanged `tarball contains EXACTLY the C2 members` (confirming `.etnp_usdt` does not leak), exit 0.

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 10: Commit**

```bash
git add extras/CMakeLists.txt scripts/gen-buildinfo.sh scripts/package.sh \
        test/buildinfo.test.sh test/package.test.sh
git commit -m "feat: record USDT state in BUILDINFO via .etnp_usdt marker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

Ship the consumer-facing probe contract + bpftrace recipes, and reference the probes from the top-level docs. No code; folded into one task since a reviewer gates it as a unit.

**Files:**
- Create: `docs/lstm-xnn-cache-usdt.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the consumer doc**

Create `docs/lstm-xnn-cache-usdt.md`:

```markdown
# LSTM XnnLinearCache USDT tracepoints

The `etnp::lstm.out` op packs XNNPACK fully-connected operators in a process-wide
LRU cache (`kMaxEntries = 16`). On **Linux** builds, the runtime emits USDT probes
so you can observe cache behavior in production — with **zero linked dependency**
and **zero cost when untraced** (each probe is a `nop` + a `.note.stapsdt` note).
Only your tracing tool (bpftrace / perf) needs privileges; the shipped library does not.

## Probe contract

Provider **`etnp`**. Probe names are **stable** (a rename is a breaking change).
Argument sets are documented but best-effort (may gain trailing args). All args are
`uint32_t` except `evicted_age` (`uint64_t`).

| Probe | Args (in order) |
|-------|-----------------|
| `etnp:lstm_xnn_cache__hit`   | `in_ch, out_ch, occupancy, capacity` |
| `etnp:lstm_xnn_cache__miss`  | `in_ch, out_ch, occupancy, capacity` |
| `etnp:lstm_xnn_cache__evict` | `in_ch, out_ch, occupancy, capacity, evicted_in_ch, evicted_out_ch, evicted_age` |

- `in_ch`/`out_ch` — FC dims of the current operation's key (on `__evict`, the *incoming* key).
- `occupancy` — cache entries after the event's mutation (`== capacity` on `__evict`).
- `capacity` — the compile-time cap (currently 16).
- `evicted_in_ch`/`evicted_out_ch` — FC dims of the evicted victim.
- `evicted_age` — LRU tick delta (`current_tick - victim_last_use_tick`): how many cache
  operations elapsed since the victim was last touched. Large = cold victim (working set
  fits); small = churn.

`__miss` fires once per successful (re)pack, so it tracks `s.misses` except on the rare
XNNPACK-create failure (which packs nothing).

## Is 16 enough? bpftrace recipes

Whether the probes are present in a build: `readelf --notes <your-binary> | grep etnp`.
Point bpftrace at the binary/library that linked the runtime (shown as `$BIN` below).

Hit/miss ratio over 10s:
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__hit  { @hit  = count(); }
             usdt:$BIN:etnp:lstm_xnn_cache__miss { @miss = count(); }
             interval:s:10 { print(@hit); print(@miss); exit(); }'
```

Eviction pressure + victim staleness (the "too small" signal):
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__evict {
               @evicts = count(); @age = hist(arg6);   /* evicted_age */ }'
```
Frequent evictions with small `evicted_age` (and occupancy pinned at capacity) means the
working set exceeds 16.

Occupancy distribution:
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__hit { @occ = hist(arg2); }'
```

## Build toggle

Probes are on by default on Linux for all variants (`bare`/`logging`/`devtools`) and
compiled out on non-Linux. To build without them: configure the extras with
`-DETNP_ENABLE_USDT=OFF`. The shipped `BUILDINFO` records `usdt=on|off`.
```

- [ ] **Step 2: Reference the probes from `README.md`**

In `README.md`, under the "Bundled first-party op & dependencies" section (after the LSTM paragraph), add:

```markdown
On Linux, every variant also emits **USDT tracepoints** for the op's XNNPACK FC cache
(`etnp:lstm_xnn_cache__hit`/`__miss`/`__evict`) — a zero-dependency way to see cache
hit/miss/eviction behavior at runtime. See `docs/lstm-xnn-cache-usdt.md`. `BUILDINFO`
records whether a build carries them (`usdt=on|off`).
```

- [ ] **Step 3: Note the contract in `CLAUDE.md`**

In `CLAUDE.md`, under the "Custom ops: `extras/`" section, add a bullet:

```markdown
- **USDT probe names are a committed contract** (Linux only): provider `etnp`, probes
  `lstm_xnn_cache__hit`/`__miss`/`__evict`, defined in `extras/lstm/runtime/etnp_usdt.h`
  and enforced by a POST_BUILD `readelf` guard (`scripts/check-usdt-notes.sh`). Renaming a
  probe is breaking; see `docs/lstm-xnn-cache-usdt.md`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/lstm-xnn-cache-usdt.md README.md CLAUDE.md
git commit -m "docs: document LSTM cache USDT tracepoints + contract

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **Full end-to-end coverage in CI:** the existing `extras-gate` (tier1) already rebuilds
  extras from the branch against a downloaded release prefix and links a consumer binary —
  so the POST_BUILD USDT guard runs there automatically once these changes land. No workflow
  YAML changes are required.
- **`readelf` output format** (provider/name/arguments) has been stable in binutils for
  years; the checker parses arity as the count of `@` in the `Arguments:` line, which holds
  whether args are in registers (`-4@%edi`) or immediates (`-4@$1`) under `-O2`.
- **Do not** add `test/usdt_probe_smoke.sh` to `test/run.sh` — it needs a toolchain +
  `sys/sdt.h`; `run.sh` is the hermetic pure-shell suite.
```
