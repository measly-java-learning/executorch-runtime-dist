# ExecuTorch Runtime Dist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the ExecuTorch runtime from source in `manylinux_2_28` for three variants on `linux-x86_64`, package each as a relocatable + PIC `et-install` tarball with checksums, licenses, and provenance, and publish them on a manual version tag via a GitHub Release with a ready-to-paste `EtRuntimePin.cmake`.

**Architecture:** A single recipe entrypoint `build-runtime.sh` (contract C8) produces a self-contained relocatable et-install prefix. Small sourced shell libraries (`scripts/lib/variants.sh`, `scripts/lib/naming.sh`) are the single source of truth for variant→flags (C3) and asset naming (C1). Packaging scripts wrap a built prefix into the C2 tarball + `.sha256` + `BUILDINFO`, and a pin generator emits `EtRuntimePin.cmake` (C6). A tag-triggered GitHub Actions matrix runs everything inside the manylinux container, attests each tarball, and publishes a Release.

**Tech Stack:** Bash, CMake + Ninja, ExecuTorch source build, `torch==2.12.0+cpu`, Docker (`quay.io/pypa/manylinux_2_28_x86_64`), GitHub Actions (`actions/attest-build-provenance`, `gh` CLI).

## Global Constraints

Every task's requirements implicitly include these. Exact values copied verbatim from the spec:

- **Container:** all builds run **inside** `quay.io/pypa/manylinux_2_28_x86_64` (AlmaLinux 8, gcc-toolset-14). Scripts **assume they are already inside** it — they never pull/spawn a container. The **caller owns the boundary** (CI `container:` key; local dev via `docker run`).
- **Python:** cp312 — `export PATH=/opt/python/cp312-cp312/bin:$PATH`.
- **Torch:** `torch==2.12.0+cpu` from `--index-url https://download.pytorch.org/whl/cpu`.
- **ET target:** tag `v1.3.1`. Source is **caller-provided** via required `--et-src <dir>` (a checkout with submodules — `actions/checkout` in CI, a mounted checkout locally); the recipe does **not** clone. `--et-tag` (default `v1.3.1`) is only the version **label** for naming/BUILDINFO; `et_commit` is read from the checkout.
- **PIC is mandatory:** `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` — the reason this repo exists; output must link into a `.so`.
- **Variants (C3):** `bare` = `-DEXECUTORCH_ENABLE_LOGGING=OFF`; `logging` = `-DEXECUTORCH_ENABLE_LOGGING=ON`; `devtools` = `-DEXECUTORCH_ENABLE_LOGGING=OFF -DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON`. `logging` is the ship default.
- **Platform (C4):** `linux-x86_64` only (token scales to future targets).
- **Asset names (C1):** `executorch-runtime-<etver>-<variant>-<platform>.tar.gz` + sibling `<asset>.sha256`.
- **Tarball layout (C2):** single top-level dir `executorch-runtime-<etver>-<variant>-<platform>/` containing `lib/` (with `cmake/ExecuTorch/executorch-config.cmake`), `include/`, `LICENSE`, `THIRD-PARTY-NOTICES/`, `BUILDINFO`. Relocatable (no absolute build-prefix in any `*.cmake`) and PIC.
- **BUILDINFO keys (C5):** `et_version, et_commit, torch_version, variant, platform, cmake_flags, toolchain, build_utc, package_tag`.
- **Pin (C6):** flat `set()`s — `ET_RUNTIME_VERSION`, `ET_RUNTIME_ET_VERSION`, and per row `ET_RUNTIME_URL_<variant>_<platform>` + `ET_RUNTIME_SHA256_<variant>_<platform>`.
- **Provenance (C7):** `<asset>.sha256` (sha256sum format); one `actions/attest-build-provenance` attestation per tarball.
- **Release tag (C9):** `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`); manual push is the **only** CI trigger — no PR/branch ET builds.

**Local dev loop** (the dev box has docker 29.6.1, gh, cmake, ninja). Run any container-bound step with:
```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; <command>'
```
Fast unit tests (Tasks 1, 5, 6) run directly on the host — no container needed.

---

## File Structure

- `scripts/lib/variants.sh` — `variant_flags <variant>` → cmake flag string (C3 source of truth).
- `scripts/lib/naming.sh` — `asset_stem`/`tarball_name`/`sha_name` (C1 source of truth).
- `build-runtime.sh` — recipe entrypoint (C8): CLI, clone, build, install, relocatability, license passthrough.
- `scripts/gen-buildinfo.sh` — emit `BUILDINFO` (C5) from env.
- `scripts/package.sh` — built prefix → C2 tarball + `.sha256` (+ BUILDINFO).
- `scripts/gen-pin.sh` — emit `EtRuntimePin.cmake` (C6).
- `test/assert.sh` — tiny dependency-free assertion harness (sourced).
- `test/run.sh` — runs all `test/*.test.sh`.
- `test/*.test.sh` — fast unit tests (naming, variants, buildinfo, package, pin).
- `test/build_smoke.sh` — structural smoke on a built prefix.
- `test/relocatability.sh` — the relocatability + PIC gate.
- `test/consumer/{CMakeLists.txt,probe.cpp}` — SHARED-lib consumer used by the gate.
- `.github/workflows/release.yml` — tag-triggered matrix build + attest + publish + pin.
- `README.md` — how to cut a release / verify an artifact (already exists; extend).

---

### Task 1: Shared shell libraries + unit-test harness

Fast, no container. Establishes the C1/C3 single-source-of-truth helpers and the test harness every later unit task reuses.

**Files:**
- Create: `scripts/lib/variants.sh`, `scripts/lib/naming.sh`
- Create: `test/assert.sh`, `test/run.sh`
- Test: `test/lib_variants.test.sh`, `test/lib_naming.test.sh`

**Interfaces:**
- Produces: `variant_flags <bare|logging|devtools>` prints the flag string, returns 2 on unknown. `asset_stem <etver> <variant> <platform>`, `tarball_name <…>` (`<stem>.tar.gz`), `sha_name <…>` (`<stem>.tar.gz.sha256`). `assert_eq <actual> <expected> <msg>`, `assert_contains <haystack> <needle> <msg>` (increment `ASSERT_FAILS`).

- [ ] **Step 1: Write the assertion harness** — `test/assert.sh`

```bash
#!/usr/bin/env bash
# Minimal dependency-free assertion harness. Source me; check $ASSERT_FAILS at end.
ASSERT_FAILS=0
assert_eq() { # <actual> <expected> <msg>
  if [ "$1" = "$2" ]; then printf 'ok: %s\n' "$3"
  else printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) printf 'ok: %s\n' "$3" ;;
  *) printf 'FAIL: %s\n  missing: [%s]\n  in: [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
}
```

- [ ] **Step 2: Write the test runner** — `test/run.sh`

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fails=0
for t in "$here"/*.test.sh; do
  echo "== $t =="
  bash "$t" || fails=$((fails+1))
done
if [ "$fails" -eq 0 ]; then echo "ALL UNIT TESTS PASS"; else echo "$fails test file(s) FAILED" >&2; exit 1; fi
```

- [ ] **Step 3: Write the failing tests** — `test/lib_variants.test.sh` and `test/lib_naming.test.sh`

`test/lib_variants.test.sh`:
```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"
assert_eq "$(variant_flags bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "bare flags"
assert_eq "$(variant_flags logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON"  "logging flags"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_BUILD_DEVTOOLS=ON"     "devtools has devtools"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_EVENT_TRACER=ON" "devtools has event tracer"
assert_contains "$(variant_flags devtools)" "-DEXECUTORCH_ENABLE_LOGGING=OFF"      "devtools logging off"
variant_flags bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant returns 2"
exit "$ASSERT_FAILS"
```

`test/lib_naming.test.sh`:
```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/naming.sh"
assert_eq "$(asset_stem 1.3.1 logging linux-x86_64)"   "executorch-runtime-1.3.1-logging-linux-x86_64"            "asset_stem"
assert_eq "$(tarball_name 1.3.1 logging linux-x86_64)" "executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz"      "tarball_name"
assert_eq "$(sha_name 1.3.1 bare linux-x86_64)"        "executorch-runtime-1.3.1-bare-linux-x86_64.tar.gz.sha256"  "sha_name"
exit "$ASSERT_FAILS"
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bash test/run.sh`
Expected: FAIL — `scripts/lib/variants.sh` / `scripts/lib/naming.sh` do not exist yet (source errors / empty output mismatches).

- [ ] **Step 5: Implement `scripts/lib/variants.sh`**

```bash
#!/usr/bin/env bash
# Variant -> cmake flag string (contract C3). Single source of truth. Source me.
variant_flags() { # <bare|logging|devtools>
  case "$1" in
    bare)     printf -- '-DEXECUTORCH_ENABLE_LOGGING=OFF' ;;
    logging)  printf -- '-DEXECUTORCH_ENABLE_LOGGING=ON' ;;
    devtools) printf -- '-DEXECUTORCH_ENABLE_LOGGING=OFF -DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON' ;;
    *) echo "unknown variant: $1" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 6: Implement `scripts/lib/naming.sh`**

```bash
#!/usr/bin/env bash
# Asset naming (contract C1). Single source of truth. Source me.
asset_stem()   { printf 'executorch-runtime-%s-%s-%s' "$1" "$2" "$3"; }      # <etver> <variant> <platform>
tarball_name() { printf '%s.tar.gz' "$(asset_stem "$@")"; }
sha_name()     { printf '%s.sha256' "$(tarball_name "$@")"; }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/variants.sh scripts/lib/naming.sh test/assert.sh test/run.sh test/lib_variants.test.sh test/lib_naming.test.sh
git commit -m "feat: shared variant/naming libs + unit-test harness"
```

---

### Task 2: `build-runtime.sh` CLI + `--print-flags` (dry, no build)

Fast, no container. Delivers the fully-tested CLI surface of the C8 entrypoint. The heavy build body is added in Task 3.

**Files:**
- Create: `build-runtime.sh`
- Test: `test/build_cli.test.sh`

**Interfaces:**
- Consumes: `variant_flags` from `scripts/lib/variants.sh` (Task 1).
- Produces: CLI `build-runtime.sh --variant <v> --prefix <dir> [--et-tag <tag>]`; dry mode `--print-flags --variant <v>` prints the flag string and exits 0; missing/unknown `--variant` exits 2; missing `--prefix` (non-dry) exits 2. Default `--et-tag` is `v1.3.1`.

- [ ] **Step 1: Write the failing test** — `test/build_cli.test.sh`

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
BR="$here/../build-runtime.sh"
assert_eq "$(bash "$BR" --print-flags --variant logging)" "-DEXECUTORCH_ENABLE_LOGGING=ON" "print-flags logging"
assert_eq "$(bash "$BR" --print-flags --variant bare)"    "-DEXECUTORCH_ENABLE_LOGGING=OFF" "print-flags bare"
bash "$BR" --print-flags --variant bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown variant exits 2"
bash "$BR" --print-flags >/dev/null 2>&1;                 assert_eq "$?" "2" "missing variant exits 2"
bash "$BR" --variant logging >/dev/null 2>&1;             assert_eq "$?" "2" "missing prefix exits 2"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/build_cli.test.sh`
Expected: FAIL — `build-runtime.sh` does not exist.

- [ ] **Step 3: Implement `build-runtime.sh` (CLI only)**

```bash
#!/usr/bin/env bash
# build-runtime.sh — ExecuTorch runtime recipe entrypoint (contract C8).
# MUST run INSIDE manylinux_2_28 (quay.io/pypa/manylinux_2_28_x86_64); the caller owns the container.
# Produces a relocatable, position-independent et-install tree at --prefix.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/variants.sh"

DEFAULT_ET_TAG="v1.3.1"
PLATFORM="linux-x86_64"          # C4; single platform for now
TORCH_SPEC="torch==2.12.0+cpu"

usage() {
  cat <<'EOF'
Usage: build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> [--et-tag <tag>]
       build-runtime.sh --print-flags --variant <variant>    # dry: print effective cmake flags, no build
Must run inside manylinux_2_28. --et-tag defaults to v1.3.1.
EOF
}

VARIANT=""; PREFIX=""; ET_TAG="$DEFAULT_ET_TAG"; PRINT_FLAGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --prefix)  PREFIX="${2:-}"; shift 2 ;;
    --et-tag)  ET_TAG="${2:-}"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "--variant required" >&2; exit 2; }
VARIANT_FLAGS="$(variant_flags "$VARIANT")"   # returns 2 on unknown -> set -e aborts with code 2

if [ "$PRINT_FLAGS" -eq 1 ]; then
  printf '%s\n' "$VARIANT_FLAGS"
  exit 0
fi

[ -n "$PREFIX" ] || { echo "--prefix required" >&2; exit 2; }

# ---- Task 3 appends the real build below this line ----
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/build_cli.test.sh`
Expected: all `ok:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add build-runtime.sh test/build_cli.test.sh
git commit -m "feat: build-runtime.sh CLI + --print-flags dry mode"
```

---

### Task 3: `build-runtime.sh` real build + relocatability + license passthrough

**Heavy — runs a real ~10-minute ET build inside the manylinux container** against a **caller-provided** ET checkout (mounted; no clone), downloads torch, compiles. Produces the self-contained relocatable et-install for the `logging` variant. `SKIP_ET_BUILD=1` reuses an existing `--prefix` install and skips the slow compile (mirrors the engine's `native/build.sh`).

**Files:**
- Modify: `build-runtime.sh` — add required `--et-src <dir>` to the CLI (Task 2 marker), then append the build body after it.
- Modify: `test/build_cli.test.sh` — assert missing `--et-src` (non-dry) exits 2.
- Create: `test/build_smoke.sh`

**Interfaces:**
- Consumes: the CLI/vars from Task 2 (`VARIANT`, `PREFIX`, `ET_TAG`, `VARIANT_FLAGS`, `TORCH_SPEC`) **plus new required `--et-src <dir>`** (an ET checkout with submodules; the recipe does not clone).
- Produces: at `$PREFIX` — `lib/` (with `cmake/ExecuTorch/executorch-config.cmake`), `include/`, `LICENSE`, `THIRD-PARTY-NOTICES/`, and a hidden `.et_commit` file (full ET sha read from `--et-src`, consumed by `package.sh` in Task 5). No absolute build-prefix strings in `lib/cmake`. Build dir is a **persisted, caller-controllable `--build-dir`** (default `<dirname of --prefix>/et-build-<variant>`, inspectable when `--prefix` is on a mounted volume); **nothing is written to `$PREFIX` beyond the C2 members + `.et_commit`** (no marker). Optional env knob `SKIP_ET_BUILD=1` skips Stage A and reuses the existing `$PREFIX` install, guarded by a check that `lib/cmake/ExecuTorch/executorch-config.cmake` is present.

- [ ] **Step 1: Write the failing smoke test** — `test/build_smoke.sh`

```bash
#!/usr/bin/env bash
# Structural smoke on a built et-install prefix. Usage: build_smoke.sh <prefix>
set -u
p="${1:?usage: build_smoke.sh <prefix>}"
fails=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fails=$((fails+1)); fi; }
check "cmake config present"        "[ -f '$p/lib/cmake/ExecuTorch/executorch-config.cmake' ]"
check "include dir present"         "[ -d '$p/include' ]"
check "lib dir present"             "[ -d '$p/lib' ]"
check "LICENSE shipped"             "[ -f '$p/LICENSE' ]"
check "THIRD-PARTY-NOTICES present" "[ -d '$p/THIRD-PARTY-NOTICES' ]"
check ".et_commit recorded"         "[ -s '$p/.et_commit' ]"
check "no absolute prefix in cmake" "! grep -rq '$p' '$p/lib/cmake'"
if [ "$fails" -eq 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL ($fails)" >&2; exit 1; fi
```

- [ ] **Step 2: Run smoke to verify it fails**

Run (host is fine — no prefix exists yet):
```bash
bash test/build_smoke.sh /tmp/nope
```
Expected: multiple `FAIL:` lines, `SMOKE FAIL`, exit 1.

- [ ] **Step 3: Append the build body to `build-runtime.sh`**

First **amend the Task 2 CLI**: add a required `--et-src <dir>` arg (the caller-provided ET checkout;
the recipe does not clone), and — right after the `--prefix` check — a `SKIP_ET_BUILD=1` fast path that
reuses an existing `--prefix` install (guarded by `executorch-config.cmake` presence, `exit 1` if
missing) and needs no `--et-src`. Then replace the trailing
`# ---- Task 3 appends the real build below this line ----` marker with:

```bash
# ---- real build (Task 3) ----
[ -n "$ET_SRC" ] || { echo "--et-src required" >&2; exit 2; }
[ -d "$ET_SRC" ] || { echo "--et-src '$ET_SRC' is not a directory" >&2; exit 2; }
ET_BUILD="${BUILD_DIR:-$(dirname "$PREFIX")/et-build-$VARIANT}"   # persisted + inspectable; overridable via --build-dir
mkdir -p "$ET_BUILD"

# ET 1.3.1 install bug: some targets install to ${CMAKE_BINARY_DIR}/lib (build dir) instead of
# ${CMAKE_INSTALL_LIBDIR}; without this the .a is missing from the prefix and the exported config
# bakes an absolute build-tree path (breaks relocation). `|| true`: grep exits 1 on an already-patched
# checkout (idempotent re-run) and must not abort under set -e/pipefail.
echo ">> patching ET install-destination bug (CMAKE_BINARY_DIR/lib -> CMAKE_INSTALL_LIBDIR)"
patch_files="$(grep -rl 'DESTINATION ${CMAKE_BINARY_DIR}/lib' --include=CMakeLists.txt "$ET_SRC" || true)"
if [ -n "$patch_files" ]; then
  printf '%s\n' "$patch_files" | while read -r f; do
    echo "   patch: ${f#"$ET_SRC"/}"
    sed -i 's#DESTINATION ${CMAKE_BINARY_DIR}/lib#DESTINATION ${CMAKE_INSTALL_LIBDIR}#g' "$f"
  done
else
  echo "   (nothing to patch — source already patched)"
fi

echo ">> installing python deps"
pip install ninja
pip install -U pip setuptools wheel pyyaml
pip install "$TORCH_SPEC" --index-url https://download.pytorch.org/whl/cpu

echo ">> configuring ($VARIANT)"
# shellcheck disable=SC2086  # deliberate word-splitting of the flag string
cmake -B "$ET_BUILD" -S "$ET_SRC" -G Ninja --preset linux \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  $VARIANT_FLAGS \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON

echo ">> building"
cmake --build "$ET_BUILD" -j"$(nproc)"

echo ">> installing to $PREFIX"
mkdir -p "$PREFIX"
cmake --install "$ET_BUILD" --prefix "$PREFIX"

echo ">> measuring relocatability"
if grep -rl "$PREFIX" "$PREFIX/lib/cmake" >/dev/null 2>&1; then
  echo ">> WARNING: absolute build-prefix leaked into cmake configs; rewriting to \${PACKAGE_PREFIX_DIR}"
  grep -rl "$PREFIX" "$PREFIX/lib/cmake" | while read -r f; do
    sed -i "s#$PREFIX#\${PACKAGE_PREFIX_DIR}#g" "$f"
  done
  # If the gate (Task 4) still fails after this, escalate: this is the documented
  # "cmake-config relocatability" known-unknown from the spec.
fi

echo ">> license passthrough (C2)"
install -m 0644 "$ET_SRC/LICENSE" "$PREFIX/LICENSE"
mkdir -p "$PREFIX/THIRD-PARTY-NOTICES"
find "$ET_SRC/third-party" "$ET_SRC/backends" -iname 'LICENSE*' -type f 2>/dev/null | while read -r lf; do
  rel="${lf#"$ET_SRC"/}"
  cp "$lf" "$PREFIX/THIRD-PARTY-NOTICES/${rel//\//_}"
done

# safe.directory='*': a mounted/CI checkout may be owned by a different uid than the container user,
# which trips git's "dubious ownership" guard and blocks rev-parse.
git -c safe.directory='*' -C "$ET_SRC" rev-parse HEAD > "$PREFIX/.et_commit"
echo ">> build-runtime.sh done: $PREFIX"
```

- [ ] **Step 4: Run the real build for `logging`, then the smoke** (heavy, ~10 min)

```bash
docker run --rm -v "$PWD":/work -v /home/corey/workspace/executorch:/executorch \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; ./build-runtime.sh --variant logging --prefix /work/out-logging --et-src /executorch'
bash test/build_smoke.sh "$PWD/out-logging"
# Re-run reusing the install (skips the ~10-min compile): add SKIP_ET_BUILD=1 to the container env.
```
Expected: build completes; `SMOKE PASS`. (Keep `out-logging/` for Tasks 4 and 5 to avoid rebuilding. Add `out-*/` to `.gitignore`.)

- [ ] **Step 5: Add `.gitignore` and commit**

```bash
printf 'out-*/\n' >> .gitignore
git add build-runtime.sh test/build_smoke.sh .gitignore
git commit -m "feat: build-runtime.sh real ET build + relocatability + license passthrough"
```

---

### Task 4: Relocatability + PIC acceptance gate (the go/no-go)

**Heavy-ish** (a small CMake configure+build). Proves the built prefix is relocatable **and** position-independent by linking a **SHARED** library against an ET target. This is the milestone that validates C2.

**Files:**
- Create: `test/relocatability.sh`, `test/consumer/CMakeLists.txt`, `test/consumer/probe.cpp`

**Interfaces:**
- Consumes: a built et-install prefix from Task 3 (e.g. `out-logging/`).
- Produces: `test/relocatability.sh <prefix>` — exits 0 only if configs contain no absolute build-prefix AND a `SHARED` consumer links successfully from a relocated copy.

- [ ] **Step 1: Write the consumer** — `test/consumer/CMakeLists.txt` and `test/consumer/probe.cpp`

`test/consumer/CMakeLists.txt`:
```cmake
cmake_minimum_required(VERSION 3.24)
project(et_pic_probe LANGUAGES CXX)
find_package(executorch CONFIG REQUIRED)
# SHARED is the whole point: linking a .so fails loudly if any linked static
# object (ET core or in-tree XNNPACK/flatcc) is non-PIC.
add_library(pic_probe SHARED probe.cpp)
# `executorch` is the umbrella target from executorch-config.cmake. If that name
# is not exported, switch to the actual imported target (e.g. executorch_core) —
# inspect out-logging/lib/cmake/ExecuTorch/*.cmake for add_library(... IMPORTED).
target_link_libraries(pic_probe PRIVATE executorch)
```

`test/consumer/probe.cpp`:
```cpp
// Minimal translation unit. The point is the LINK step, not the code.
extern "C" int et_pic_probe() { return 0; }
```

- [ ] **Step 2: Write the gate** — `test/relocatability.sh`

```bash
#!/usr/bin/env bash
# Relocatability + PIC gate (spec Step 1 + Step 3). Go/no-go for the whole repo.
# Usage: relocatability.sh <et-install-prefix>
set -euo pipefail
SRC="${1:?usage: relocatability.sh <prefix>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== Step 1: measure — no absolute build-prefix in cmake configs =="
if grep -rn "$SRC" "$SRC/lib/cmake"; then
  echo "FAIL: absolute prefix leaked into cmake configs" >&2; exit 1
fi
echo "ok: relocatable"

echo "== Step 3: consume from a DIFFERENT directory + link a SHARED lib (PIC) =="
RELO="$(mktemp -d)/et-install"
cp -a "$SRC" "$RELO"
BUILD="$(mktemp -d)/consumer-build"
cmake -S "$HERE/consumer" -B "$BUILD" -G Ninja -DCMAKE_PREFIX_PATH="$RELO"
cmake --build "$BUILD"
echo "GATE PASS: relocatable AND position-independent"
```

- [ ] **Step 3: Run the gate to verify it fails on a bad input**

```bash
mkdir -p /tmp/fake/lib/cmake && bash test/relocatability.sh /tmp/fake
```
Expected: FAIL — `find_package(executorch …)` cannot be satisfied (no config), non-zero exit.

- [ ] **Step 4: Run the gate against the real `logging` prefix** (inside the container, since it links ET)

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; bash test/relocatability.sh /work/out-logging'
```
Expected: `ok: relocatable` then `GATE PASS: relocatable AND position-independent`.
If the SHARED link fails with `recompile with -fPIC`, an in-tree dep ignored the global PIC flag — this is the documented PIC known-unknown; fix by adding the dep's own PIC flag to the recipe and rerun Task 3.

- [ ] **Step 5: Commit**

```bash
git add test/relocatability.sh test/consumer/CMakeLists.txt test/consumer/probe.cpp
git commit -m "feat: relocatability + PIC acceptance gate"
```

---

### Task 5: Packaging — `BUILDINFO` + C2 tarball + `.sha256`

Mostly fast (unit-tested against a synthetic prefix); one real tar of the `logging` prefix. Adds `BUILDINFO` and produces the C1/C2 tarball and its checksum.

**Files:**
- Create: `scripts/gen-buildinfo.sh`, `scripts/package.sh`
- Test: `test/buildinfo.test.sh`, `test/package.test.sh`

**Interfaces:**
- Consumes: `variant_flags`/naming libs (Task 1); a built prefix incl. `.et_commit` (Task 3).
- Produces: `scripts/gen-buildinfo.sh` (env → BUILDINFO on stdout). `scripts/package.sh --prefix <dir> --etver <v> --variant <v> --platform <p> --package-tag <tag> --outdir <dir>` → writes `<outdir>/<stem>.tar.gz` and `<outdir>/<stem>.tar.gz.sha256`, prints the tarball path.

- [ ] **Step 1: Write failing unit tests**

`test/buildinfo.test.sh`:
```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
out="$(ET_VERSION=1.3.1 ET_COMMIT=abc123 TORCH_VERSION=2.12.0+cpu VARIANT=logging \
  PLATFORM=linux-x86_64 CMAKE_FLAGS='-DEXECUTORCH_ENABLE_LOGGING=ON' \
  TOOLCHAIN='manylinux_2_28 gcc-toolset-14' PACKAGE_TAG=v1.3.1-1 \
  bash "$here/../scripts/gen-buildinfo.sh")"
assert_contains "$out" "et_version=1.3.1"        "et_version"
assert_contains "$out" "et_commit=abc123"        "et_commit"
assert_contains "$out" "torch_version=2.12.0+cpu" "torch_version"
assert_contains "$out" "variant=logging"         "variant"
assert_contains "$out" "platform=linux-x86_64"   "platform"
assert_contains "$out" "package_tag=v1.3.1-1"    "package_tag"
assert_contains "$out" "build_utc="              "build_utc present"
assert_contains "$out" "toolchain=manylinux_2_28 gcc-toolset-14" "toolchain"
exit "$ASSERT_FAILS"
```

`test/package.test.sh` (synthetic prefix — fast, no ET build):
```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
p="$(mktemp -d)/pfx"
mkdir -p "$p/lib/cmake/ExecuTorch" "$p/include" "$p/THIRD-PARTY-NOTICES"
: > "$p/lib/cmake/ExecuTorch/executorch-config.cmake"
: > "$p/LICENSE"
echo "deadbeef" > "$p/.et_commit"
out="$(mktemp -d)"
tb="$(bash "$here/../scripts/package.sh" --prefix "$p" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$out")"
assert_eq "$(basename "$tb")" "executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz" "tarball name (C1)"
assert_eq "$([ -f "$tb" ] && echo y)" "y" "tarball exists"
assert_eq "$([ -f "$tb.sha256" ] && echo y)" "y" "sha256 sibling exists"
members="$(tar -tzf "$tb")"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/BUILDINFO" "BUILDINFO in tarball"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/LICENSE"   "LICENSE in tarball"
assert_contains "$members" "executorch-runtime-1.3.1-logging-linux-x86_64/THIRD-PARTY-NOTICES/" "notices dir"
case "$members" in *".et_commit"*) echo "FAIL: .et_commit leaked into tarball" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: .et_commit excluded";; esac
assert_eq "$(cd "$out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 && echo ok)" "ok" "sha256 verifies"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/buildinfo.test.sh; bash test/package.test.sh`
Expected: FAIL — scripts don't exist.

- [ ] **Step 3: Implement `scripts/gen-buildinfo.sh`**

```bash
#!/usr/bin/env bash
# Emit BUILDINFO (contract C5) key=value lines to stdout.
set -euo pipefail
: "${ET_VERSION:?}"; : "${ET_COMMIT:?}"; : "${TORCH_VERSION:?}"; : "${VARIANT:?}"
: "${PLATFORM:?}"; : "${CMAKE_FLAGS:?}"; : "${TOOLCHAIN:?}"; : "${PACKAGE_TAG:?}"
cat <<EOF
et_version=$ET_VERSION
et_commit=$ET_COMMIT
torch_version=$TORCH_VERSION
variant=$VARIANT
platform=$PLATFORM
cmake_flags=$CMAKE_FLAGS
toolchain=$TOOLCHAIN
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
package_tag=$PACKAGE_TAG
EOF
```

- [ ] **Step 4: Implement `scripts/package.sh`**

```bash
#!/usr/bin/env bash
# Package a built et-install prefix into the C2 tarball + .sha256.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"
. "$HERE/lib/variants.sh"

PREFIX=""; ETVER=""; VARIANT=""; PLATFORM=""; PACKAGE_TAG=""; OUTDIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --etver) ETVER="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --package-tag) PACKAGE_TAG="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for v in PREFIX ETVER VARIANT PLATFORM PACKAGE_TAG; do
  [ -n "${!v}" ] || { echo "--${v,,} required" >&2; exit 2; }
done

STEM="$(asset_stem "$ETVER" "$VARIANT" "$PLATFORM")"
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$STEM"
mkdir -p "$STAGE"
cp -a "$PREFIX/." "$STAGE/"

ET_COMMIT="$(cat "$STAGE/.et_commit" 2>/dev/null || echo unknown)"
rm -f "$STAGE/.et_commit"

CMAKE_FLAGS="$(variant_flags "$VARIANT") -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXECUTORCH_BUILD_XNNPACK=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON"
ET_VERSION="$ETVER" ET_COMMIT="$ET_COMMIT" TORCH_VERSION="2.12.0+cpu" \
  VARIANT="$VARIANT" PLATFORM="$PLATFORM" CMAKE_FLAGS="$CMAKE_FLAGS" \
  TOOLCHAIN="manylinux_2_28 gcc-toolset-14" PACKAGE_TAG="$PACKAGE_TAG" \
  "$HERE/gen-buildinfo.sh" > "$STAGE/BUILDINFO"

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(tarball_name "$ETVER" "$VARIANT" "$PLATFORM")"
tar -C "$STAGE_ROOT" -czf "$TARBALL" "$STEM"
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (now includes buildinfo + package).

- [ ] **Step 6: Real end-to-end tar of the `logging` prefix** (uses Task 3 output)

```bash
bash scripts/package.sh --prefix "$PWD/out-logging" --etver 1.3.1 --variant logging \
  --platform linux-x86_64 --package-tag v1.3.1-1 --outdir "$PWD/dist"
( cd dist && sha256sum -c executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256 )
```
Expected: prints tarball path; `sha256sum -c` prints `OK`.

- [ ] **Step 7: Commit**

```bash
printf 'dist/\n' >> .gitignore
git add scripts/gen-buildinfo.sh scripts/package.sh test/buildinfo.test.sh test/package.test.sh .gitignore
git commit -m "feat: BUILDINFO + C2 tarball packaging with sha256"
```

---

### Task 6: Pin generator — `EtRuntimePin.cmake` (C6)

Fast, no container.

**Files:**
- Create: `scripts/gen-pin.sh`
- Test: `test/pin.test.sh`

**Interfaces:**
- Consumes: `tarball_name` from naming lib (Task 1).
- Produces: `scripts/gen-pin.sh --version <pkgver> --etver <etver> --base-url <url> --row <variant> <platform> <sha256> [--row …]` → prints `EtRuntimePin.cmake` to stdout.

- [ ] **Step 1: Write the failing test** — `test/pin.test.sh`

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
base="https://github.com/measly-java-learning/executorch-runtime-dist/releases/download/v1.3.1-1"
out="$(bash "$here/../scripts/gen-pin.sh" --version 1.3.1-1 --etver 1.3.1 --base-url "$base" \
  --row logging linux-x86_64 deadbeef --row bare linux-x86_64 cafef00d)"
assert_contains "$out" 'set(ET_RUNTIME_VERSION "1.3.1-1")'    "version var"
assert_contains "$out" 'set(ET_RUNTIME_ET_VERSION "1.3.1")'   "et version var"
assert_contains "$out" "set(ET_RUNTIME_URL_logging_linux-x86_64" "logging url var"
assert_contains "$out" "$base/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz" "logging url value"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_logging_linux-x86_64 "deadbeef")' "logging sha"
assert_contains "$out" 'set(ET_RUNTIME_SHA256_bare_linux-x86_64 "cafef00d")'    "bare sha"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/pin.test.sh`
Expected: FAIL — `scripts/gen-pin.sh` does not exist.

- [ ] **Step 3: Implement `scripts/gen-pin.sh`**

```bash
#!/usr/bin/env bash
# Emit EtRuntimePin.cmake (contract C6) to stdout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"

VERSION=""; ETVER=""; BASEURL=""; ROWS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --etver) ETVER="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --row) ROWS+=("$2 $3 $4"); shift 4 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${VERSION:?}"; : "${ETVER:?}"; : "${BASEURL:?}"

printf '# Generated by executorch-runtime-dist release v%s. Do not edit by hand.\n' "$VERSION"
printf 'set(ET_RUNTIME_VERSION "%s")\n' "$VERSION"
printf 'set(ET_RUNTIME_ET_VERSION "%s")\n\n' "$ETVER"
for r in "${ROWS[@]}"; do
  # shellcheck disable=SC2086  # split the "variant platform sha" triple
  set -- $r
  variant="$1"; platform="$2"; sha="$3"
  tb="$(tarball_name "$ETVER" "$variant" "$platform")"
  printf 'set(ET_RUNTIME_URL_%s_%s\n  "%s/%s")\n' "$variant" "$platform" "$BASEURL" "$tb"
  printf 'set(ET_RUNTIME_SHA256_%s_%s "%s")\n\n' "$variant" "$platform" "$sha"
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/pin.test.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/gen-pin.sh test/pin.test.sh
git commit -m "feat: EtRuntimePin.cmake generator"
```

---

### Task 7: Prove `bare` + `devtools` variants (resolve the devtools known-unknown)

**Heavy** — two more real builds. The recipe is variant-agnostic, so `bare` should pass unchanged; `devtools` is the spec's known-unknown and may need extra flags.

**Files:**
- Modify (only if devtools requires it): `scripts/lib/variants.sh` (devtools arm)

**Interfaces:**
- Consumes: `build-runtime.sh` (Task 3), `test/build_smoke.sh` (Task 3), `test/relocatability.sh` (Task 4).
- Produces: confirmed passing `bare` and `devtools` prefixes; the final devtools flag set pinned in `variant_flags`.

- [ ] **Step 1: Build + smoke + gate `bare`** (inside container)

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  ./build-runtime.sh --variant bare --prefix /work/out-bare &&
  bash test/build_smoke.sh /work/out-bare &&
  bash test/relocatability.sh /work/out-bare'
```
Expected: `SMOKE PASS` and `GATE PASS`.

- [ ] **Step 2: Build `devtools` (expect possible configure failure)**

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  ./build-runtime.sh --variant devtools --prefix /work/out-devtools'
```

- [ ] **Step 3: If devtools configure/build fails, resolve flags and update `variant_flags`**

Read the configure error; ET 1.3.x devtools typically also needs the etdump/flatcc targets. Apply the resolved set to the `devtools)` arm of `scripts/lib/variants.sh`, e.g. (adjust to what the error actually requires):
```bash
    devtools) printf -- '-DEXECUTORCH_ENABLE_LOGGING=OFF -DEXECUTORCH_BUILD_DEVTOOLS=ON -DEXECUTORCH_ENABLE_EVENT_TRACER=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON' ;;
```
Then update `test/lib_variants.test.sh` to assert any newly required flag, and re-run `bash test/run.sh` (must pass) before rebuilding.

- [ ] **Step 4: Re-run devtools build + smoke + gate until green**

```bash
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  ./build-runtime.sh --variant devtools --prefix /work/out-devtools &&
  bash test/build_smoke.sh /work/out-devtools &&
  bash test/relocatability.sh /work/out-devtools'
```
Expected: `SMOKE PASS` and `GATE PASS`.

- [ ] **Step 5: Commit (only if variants.sh changed)**

```bash
git add scripts/lib/variants.sh test/lib_variants.test.sh
git commit -m "fix: pin resolved devtools flag set for ET 1.3.x"
```
If nothing changed, record in the task notes that the default flags built all three variants unchanged.

---

### Task 8: CI/release workflow (`.github/workflows/release.yml`)

Validated with `actionlint` locally; end-to-end proven by a pre-release tag dry run.

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `build-runtime.sh`, `scripts/package.sh`, `scripts/gen-pin.sh`.
- Produces: on tag `v<etver>-<pkgrev>` — 3 tarballs + 3 `.sha256` + per-tarball attestations + `EtRuntimePin.cmake`, all on a GitHub Release.

- [ ] **Step 1: Write the workflow** — `.github/workflows/release.yml`

```yaml
name: release
on:
  push:
    tags: ['v*-*']          # v<etver>-<pkgrev>, e.g. v1.3.1-1 (C9). Only trigger.
permissions:
  contents: write           # create release + upload assets
  id-token: write           # attestations (C7)
  attestations: write
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: quay.io/pypa/manylinux_2_28_x86_64   # caller owns the container boundary (C8)
    strategy:
      fail-fast: false
      matrix:
        variant: [bare, logging, devtools]
        platform: [linux-x86_64]
    steps:
      - uses: actions/checkout@v4
      - name: Derive versions from tag
        id: ver
        run: |
          tag="${GITHUB_REF_NAME}"        # v1.3.1-1
          pkgver="${tag#v}"                # 1.3.1-1
          etver="${pkgver%-*}"            # 1.3.1
          {
            echo "pkgver=$pkgver"
            echo "etver=$etver"
            echo "ettag=v$etver"
          } >> "$GITHUB_OUTPUT"
      - name: Build runtime
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          ./build-runtime.sh --variant "${{ matrix.variant }}" \
            --prefix "$PWD/out" --et-tag "${{ steps.ver.outputs.ettag }}"
      - name: Package
        run: |
          ./scripts/package.sh --prefix "$PWD/out" --etver "${{ steps.ver.outputs.etver }}" \
            --variant "${{ matrix.variant }}" --platform "${{ matrix.platform }}" \
            --package-tag "${GITHUB_REF_NAME}" --outdir "$PWD/dist"
      - name: Attest build provenance
        uses: actions/attest-build-provenance@v1
        with:
          subject-path: dist/*.tar.gz
      - uses: actions/upload-artifact@v4
        with:
          name: dist-${{ matrix.variant }}-${{ matrix.platform }}
          path: dist/*
  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          path: dist
          merge-multiple: true
      - name: Generate EtRuntimePin.cmake
        run: |
          tag="${GITHUB_REF_NAME}"; pkgver="${tag#v}"; etver="${pkgver%-*}"
          base="${{ github.server_url }}/${{ github.repository }}/releases/download/${tag}"
          args=(--version "$pkgver" --etver "$etver" --base-url "$base")
          for variant in bare logging devtools; do
            sha="$(cut -d' ' -f1 "dist/executorch-runtime-${etver}-${variant}-linux-x86_64.tar.gz.sha256")"
            args+=(--row "$variant" linux-x86_64 "$sha")
          done
          ./scripts/gen-pin.sh "${args[@]}" > dist/EtRuntimePin.cmake
          {
            echo '```cmake'
            cat dist/EtRuntimePin.cmake
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
      - name: Create/Update release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${GITHUB_REF_NAME}" dist/* \
            --title "${GITHUB_REF_NAME}" \
            --notes "ExecuTorch runtime ${GITHUB_REF_NAME} (torch 2.12.0+cpu, manylinux_2_28)." \
          || gh release upload "${GITHUB_REF_NAME}" dist/* --clobber
```

- [ ] **Step 2: Lint the workflow**

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color
```
Expected: no errors. (Fix any reported issue.)
Note: `checkout@v4`/`upload-artifact@v4` run node20 inside the manylinux (glibc 2.28) container — supported. If a future action fails to start in-container, split it into a non-container step.

- [ ] **Step 3: Dry run on a pre-release tag** (real CI; you push the tag — commits/pushes are the user's to make)

Suggested: push tag `v1.3.1-0` (pkgrev `0` = dry). Then verify:
```bash
gh run watch
gh release view v1.3.1-0 --json assets --jq '.assets[].name'   # expect 3 tar.gz + 3 .sha256 + EtRuntimePin.cmake
gh attestation verify \
  <(gh release download v1.3.1-0 -p 'executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz' -O -) \
  --repo measly-java-learning/executorch-runtime-dist
```
Expected: all assets present; `gh attestation verify` passes.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: tag-triggered matrix build, attest, publish, pin"
```

---

### Task 9: README — cut-a-release + verify-an-artifact docs

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Extend `README.md`** with a usage section (append after the existing intro):

```markdown
## Cutting a release

Releases are built once per ExecuTorch version and published as attested,
hash-pinned tarballs. To cut one:

1. Pick the tag `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`; bump `<pkgrev>` to re-roll the same ET version).
2. Push the tag. The `release` workflow builds all three variants
   (`bare`/`logging`/`devtools`) for `linux-x86_64` inside `manylinux_2_28`,
   attests each tarball, and publishes a GitHub Release with a ready-to-paste
   `EtRuntimePin.cmake`.

Build locally (same recipe CI uses):

    docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 \
      bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; ./build-runtime.sh --variant logging --prefix /work/out'

## Verifying an artifact

    sha256sum -c executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
    gh attestation verify executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz \
      --repo measly-java-learning/executorch-runtime-dist

## Variants

- `bare` — logging off (smallest).
- `logging` — logging on. **Ship default.**
- `devtools` — event tracer + devtools (profiling/debug).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: release + verification instructions"
```

---

## Self-Review

**Spec coverage (Part 1 + C1–C9):**
- Build recipe / variant map (C3) → Task 1 (`variants.sh`) + Task 3 (build).
- Single entrypoint `build-runtime.sh` / container boundary (C8) → Tasks 2–3.
- Relocatability + PIC gate (first milestone, C2) → Task 4.
- Tarball layout + LICENSE/THIRD-PARTY-NOTICES (C2) → Task 3 (licenses) + Task 5 (BUILDINFO, tar).
- Asset names + sha256 (C1, C7) → Task 1 (`naming.sh`) + Task 5.
- BUILDINFO (C5) → Task 5.
- EtRuntimePin.cmake (C6) → Task 6.
- CI matrix + attestation + release + pin emission (C7, C9) → Task 8.
- devtools known-unknown → Task 7.
- README → Task 9.
- Non-goal (no PR/non-tag builds) → workflow trigger is `tags: ['v*-*']` only (Task 8).

**Placeholder scan:** No "TBD"/"TODO"/"handle errors" left; every code step is complete runnable content. The one adaptive spot (devtools extra flags, Task 7 Step 3) is explicitly conditional on a real configure error with a concrete example and a test-update instruction — not a placeholder.

**Type/name consistency:** `variant_flags`, `asset_stem`/`tarball_name`/`sha_name`, `assert_eq`/`assert_contains`, `.et_commit`, and the `--variant/--prefix/--et-tag/--etver/--platform/--package-tag/--outdir/--row/--version/--base-url` flags are used identically across the tasks that define and consume them. Pin `--version` is the pkgver (`1.3.1-1`); the release tag is `v1.3.1-1`; BUILDINFO `package_tag` is the full tag — consistent with C5/C6/C9.
