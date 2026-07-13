# Custom-Code (extras) QA Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a path-filtered PR gate that QAs the LSTM/extras custom code without paying the ~10–15 min ExecuTorch compile, by rebuilding only the extras phase against a downloaded, attested release tarball and running a torch-free consumer smoke over published `.pte` fixtures.

**Architecture:** A released runtime tarball is a prebuilt "phase-1" ExecuTorch prefix. The gate downloads + verifies it, scrubs the shipped extras out, rebuilds extras **from the branch** via a new `build-runtime.sh --extras-only` entrypoint, then runs the branch's kernel against a published, arch-independent `.pte`/golden fixture set. A `classify` step picks one of three modes by inspecting the PR's changed files: **tier1** (torch-free consumer smoke, both arches), **tier2** (tier1 + the live torch round-trip, for AOT/schema changes), or **full** (a full-build release dry-run, for any `build-runtime.sh` change or when no matching release exists).

**Tech Stack:** Bash, CMake/Ninja, GitHub Actions, Python (torch + executorch for AOT/fixture generation; numpy-only for the consumer smoke), `gh` CLI (download/attestation), manylinux_2_28 containers.

## Global Constraints

- **ET version pin (branch source of truth):** `DEFAULT_ET_TAG="v1.3.1"` in `build-runtime.sh:17`. The gate derives `etver` (`1.3.1`) from it.
- **Ship/default variant:** `logging`. The gate uses `logging` for all runtime work.
- **Platforms:** `linux-x86_64` and `linux-aarch64` (manylinux_2_28, glibc ≥ 2.28). Tier 1 runs both; tier2/full run x86_64 only.
- **Container discipline:** any step that compiles/links against the ET static archives runs **inside** `quay.io/pypa/manylinux_2_28_<arch>` (fidelity vs. the shipped archives). `gh` is **not** available in those images — download/verify happens in an `ubuntu-latest` job and artifacts are passed in.
- **Supply-chain posture:** every downloaded tarball/fixture is `sha256sum -c`'d before use — **mandatory in every case, including fork PRs** (the `.sha256` is published by our release, so a match proves the bytes are exactly what we shipped). `gh attestation verify` is **defense-in-depth**: enforced on same-repo PRs, best-effort (skipped with a `::notice::`) on fork PRs whose reduced, un-elevatable token can't read attestations — so external contributions are never blocked while integrity stays gated.
- **Numeric tolerance:** rtol/atol `1e-4` (matches the existing round-trip).
- **Extras license parity (invariant):** any path that installs `libhwy.a` also installs Highway's license — `build_extras` is always followed by `install_highway_license` (full build **and** `--extras-only`), so no built prefix (CI, gate, or local) is license-incomplete for the dependency the extras phase adds.
- **Import convention (Python under `extras/`):** every `extras/lstm/**/*.py` puts the repo root on `sys.path` (`_REPO_ROOT = Path(__file__).resolve().parents[3]`, or `HERE.parents[2]` when `HERE` is the file's dir) and imports **every** cross-module dependency by its full package path — `from extras.lstm.test._runner import …`, `from extras.lstm.aot import lstm_case`/`emit_fixtures`, `import extras.lstm.aot.etnp_lstm_op`. No bare sibling imports (`import lstm_case`, `from _runner import …`): those only resolve when the containing dir happens to be on the path (script-run or pytest launch) and let a module load under two identities in one process. This keeps imports cwd-independent and single-identity for scripts, pytest, and any future cross-op reuse. (A package-based alternative — `__init__.py` + `python -m` — is captured under **Deferred / future work**.)
- **Asset naming is single-source:** runtime tarballs via `scripts/lib/naming.sh`; fixtures via the new `fixtures_name` added there.
- **Fixture single source of truth:** the published `.pte`/golden and the live round-trip are generated from the *same* code (`extras/lstm/aot/lstm_case.py`) — dims, seed, weights, arity/op-name assertions all live there once.
- **Shell test harness:** new `test/*.test.sh` files are auto-discovered by `test/run.sh` (globs `*.test.sh`); no wiring needed. Run all with `bash test/run.sh`.

---

### Task 1: Fixtures naming + packaging script

**Files:**
- Modify: `scripts/lib/naming.sh` (append `fixtures_name`)
- Create: `scripts/package-fixtures.sh`
- Test: `test/package_fixtures.test.sh`

**Interfaces:**
- Produces: `fixtures_name <etver>` → `etnp-lstm-fixtures-<etver>.tar.gz` (bash function, sourced).
- Produces: `scripts/package-fixtures.sh --dir <fixtures-dir> --etver <etver> --outdir <dir>` → writes `<outdir>/etnp-lstm-fixtures-<etver>.tar.gz` + `.sha256` (flat: the 4 fixture files at tar root); prints the tarball path on stdout. Non-zero on missing input file.

- [ ] **Step 1: Write the failing test**

Create `test/package_fixtures.test.sh`:

```bash
#!/usr/bin/env bash
# Packages a fixtures dir into etnp-lstm-fixtures-<etver>.tar.gz + .sha256 (flat layout).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# a fake fixtures dir with the 4 expected members
mkdir -p "$tmp/fx"
printf 'PTE'   > "$tmp/fx/lstm.pte"
printf 'IN'    > "$tmp/fx/in.bin"
printf 'OUT'   > "$tmp/fx/out.bin"
printf 'LSTM_T=5\n' > "$tmp/fx/shape"

out="$("$root/scripts/package-fixtures.sh" --dir "$tmp/fx" --etver 1.3.1 --outdir "$tmp/out")" \
  || { echo "package-fixtures.sh failed"; exit 1; }

tb="$tmp/out/etnp-lstm-fixtures-1.3.1.tar.gz"
[ "$out" = "$tb" ] || { echo "stdout path mismatch: $out"; fail=1; }
[ -f "$tb" ] || { echo "MISSING tarball"; fail=1; }
[ -f "$tb.sha256" ] || { echo "MISSING sha256"; fail=1; }
( cd "$tmp/out" && sha256sum -c "etnp-lstm-fixtures-1.3.1.tar.gz.sha256" >/dev/null ) \
  || { echo "sha256 does not verify"; fail=1; }
# flat layout: files at tar root, no leading directory
names="$(tar -tzf "$tb" | sort | tr '\n' ' ')"
[ "$names" = "in.bin lstm.pte out.bin shape " ] || { echo "bad tar members: $names"; fail=1; }
# missing --dir fails non-zero
"$root/scripts/package-fixtures.sh" --dir "$tmp/nope" --etver 1.3.1 --outdir "$tmp/out" 2>/dev/null \
  && { echo "expected failure on missing dir"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: package-fixtures" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/package_fixtures.test.sh`
Expected: FAIL (script does not exist yet).

- [ ] **Step 3: Add `fixtures_name` to `scripts/lib/naming.sh`**

Append after `sha_name`:

```bash
fixtures_name() { printf 'etnp-lstm-fixtures-%s.tar.gz' "$1"; }               # <etver> (arch-independent)
```

- [ ] **Step 4: Create `scripts/package-fixtures.sh`**

```bash
#!/usr/bin/env bash
# Package the arch-independent LSTM fixture set (lstm.pte, in.bin, out.bin, shape)
# into etnp-lstm-fixtures-<etver>.tar.gz + .sha256 (flat: files at tar root).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"

DIR=""; ETVER=""; OUTDIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    DIR="$2"; shift 2 ;;
    --etver)  ETVER="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] && [ -n "$ETVER" ] || { echo "--dir and --etver required" >&2; exit 2; }
[ -d "$DIR" ] || { echo "package-fixtures.sh: --dir '$DIR' not a directory" >&2; exit 1; }
for m in lstm.pte in.bin out.bin shape; do
  [ -s "$DIR/$m" ] || { echo "package-fixtures.sh: missing fixture member '$m' in $DIR" >&2; exit 1; }
done

mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(fixtures_name "$ETVER")"
tar -C "$DIR" -czf "$TARBALL" lstm.pte in.bin out.bin shape
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
```

Make executable: `chmod +x scripts/package-fixtures.sh`

- [ ] **Step 5: Run test to verify it passes**

Run: `bash test/package_fixtures.test.sh`
Expected: `OK: package-fixtures`

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/naming.sh scripts/package-fixtures.sh test/package_fixtures.test.sh
git commit -m "feat(gate): fixtures naming + package-fixtures.sh"
```

---

### Task 2: `build-runtime.sh --extras-only` (phase-2-only entrypoint)

**Files:**
- Modify: `build-runtime.sh` (extract a `build_extras` function; add `--extras-only` flag + guard)
- Test: `test/extras_only.test.sh`

**Interfaces:**
- Produces: `build-runtime.sh --extras-only --variant <v> --prefix <existing-prefix>` → rebuilds + installs only the extras (custom ops) against an existing ET install; requires `<prefix>/lib/cmake/ExecuTorch/executorch-config.cmake` (fails fast otherwise); does **not** need `--et-src` and does not clone. It **does** run the Highway license passthrough (so `libhwy.a` never ships without its license — parity with the full build), but not the ET-side license/relocatability steps (those belong to `--et-src`). Non-zero on a missing/invalid prefix or a missing Highway license.
- Produces: `build-runtime.sh --print-et-tag` → prints the pinned ET tag (`$ET_TAG`, default `DEFAULT_ET_TAG`) and exits; needs no `--variant`/`--prefix`. Lets `classify-gate.sh` (Task 7) read the ET pin via the shell that defines it — no brittle regex over the source.
- Consumed by: Task 8 (Tier 1 + Tier 2 rebuild-from-branch steps); `classify-gate.sh` (Task 7, via `--print-et-tag`).

**Context:** today the extras build is lines `build-runtime.sh:134-143`. `SKIP_ET_BUILD=1` exits at line 76 *before* it, so there is no phase-2-only path. This task factors 134-143 into `build_extras()` **and** the Highway-license block (185-194) into `install_highway_license()`, reaching both via `--extras-only`. The full-build flow stays behaviorally identical — it calls the same two functions in the same order/positions. The license extraction closes a compliance gap: without it, `--extras-only` would install `libhwy.a` (fetched by the extras build) while skipping its license, so a *distributed local build* against a bare prefix could ship `libhwy.a` unlicensed.

- [ ] **Step 1: Write the failing test**

Create `test/extras_only.test.sh`:

```bash
#!/usr/bin/env bash
# --extras-only guards: requires --prefix + --variant and an existing ET config;
# fails fast (non-zero) when the prefix has no executorch-config.cmake.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# empty prefix (no executorch-config.cmake) must fail fast, not attempt a build
"$root/build-runtime.sh" --extras-only --variant logging --prefix "$tmp/empty" 2>"$tmp/err"
rc=$?
[ "$rc" -ne 0 ] || { echo "expected non-zero on missing ET config"; fail=1; }
grep -qi 'executorch-config.cmake' "$tmp/err" || { echo "expected a clear config-missing error"; fail=1; }

# missing --prefix must fail with usage/required error
"$root/build-runtime.sh" --extras-only --variant logging 2>"$tmp/err2"
[ "$?" -ne 0 ] || { echo "expected non-zero on missing --prefix"; fail=1; }

# --print-et-tag echoes the pinned default tag by letting the shell parse its own var
# (no brittle regex over the source; robust to any valid quoting) — used by classify-gate.sh
tag="$("$root/build-runtime.sh" --print-et-tag)"
[ "$tag" = "v1.3.1" ] || { echo "expected --print-et-tag=v1.3.1, got '$tag'"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: --extras-only guards + --print-et-tag" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/extras_only.test.sh`
Expected: FAIL (`--extras-only` and `--print-et-tag` are unknown args today → exit 2 / empty output; neither the config-missing path nor the tag print exists yet).

- [ ] **Step 3: Extract `build_extras()` in `build-runtime.sh`**

Replace the inline extras block (`build-runtime.sh:134-143`) with a call, and define the function near the top (after the arg parse, before `# ---- SKIP_ET_BUILD` at line ~69). New function:

```bash
# Phase 2: build + install the extras (custom ops) against an already-installed prefix.
# Reachable standalone via --extras-only (used by the PR gate to rebuild extras from a
# branch against a downloaded release prefix, skipping the ~15min ET compile).
build_extras() {
  echo ">> building extras (custom ops) against the installed prefix"
  # Place the extras build tree NEXT TO the ET build tree (its sibling), exactly as the
  # pre-refactor inline code did — for both the default and an explicit --build-dir, so the
  # full-build path stays behaviorally identical.
  local _etb="${BUILD_DIR:-$(dirname "$PREFIX")/et-build-$VARIANT}"
  local extras_build="$(dirname "$_etb")/etnp-extras-$VARIANT"
  cmake -B "$extras_build" -S "$HERE/extras" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  # Building the link probe runs the POST_BUILD nm-guard (registrar survived).
  cmake --build "$extras_build" -j"$(nproc)"
  cmake --install "$extras_build" --prefix "$PREFIX"
  EXTRAS_BUILD="$extras_build"   # exported for the full-build Highway-license step
}
```

At the former location (lines 134-143) leave just:

```bash
build_extras
```

Then extract the existing **Highway-license block** (`build-runtime.sh:185-194`) into a
function too, so every path that installs `libhwy.a` also installs its license. Define it
near `build_extras`:

```bash
# Highway (libhwy.a) is fetched + installed by build_extras; its LICENSE is not in ET's
# tree. Copy it into the prefix or hard-fail — shipping libhwy.a without its license is a
# compliance defect. Called by BOTH the full build and --extras-only, so a locally-built
# or gate-built prefix is never license-incomplete for the dependency the extras phase adds.
install_highway_license() {
  mkdir -p "$PREFIX/THIRD-PARTY-NOTICES"
  local hwy_lic
  hwy_lic="$(find "$EXTRAS_BUILD" -path '*highway-src/LICENSE' -type f 2>/dev/null | head -n1 || true)"
  if [ -n "$hwy_lic" ]; then
    cp "$hwy_lic" "$PREFIX/THIRD-PARTY-NOTICES/highway_LICENSE"
  else
    echo ">> ERROR: Highway LICENSE not found under $EXTRAS_BUILD; refusing to ship libhwy.a without its license" >&2
    exit 1
  fi
}
```

At the former Highway block location (lines 185-194), leave just:

```bash
install_highway_license
```

(The ET `LICENSE` + ET `THIRD-PARTY-NOTICES/` passthrough above it stays inline in the full
path — those come from `--et-src`, which `--extras-only` does not have and is not
responsible for. The extras phase only adds `libhwy.a`, so only its license is shared
between the two paths.)

- [ ] **Step 4: Add the `--extras-only` flag + guard**

In the arg-parse loop, add two cases (alongside `--print-flags`):

```bash
    --extras-only)   EXTRAS_ONLY=1; shift ;;
    --print-et-tag)  PRINT_ET_TAG=1; shift ;;
```

Initialize both with the other vars (line 32): add `EXTRAS_ONLY=0; PRINT_ET_TAG=0`.

Immediately **after the arg-parse `while` loop** (before the `[ -n "$VARIANT" ]` check, so it needs no `--variant`), add the `--print-et-tag` early-exit. This is the robust, single-source way for `classify-gate.sh` to read the ET pin: the shell that *defines* `DEFAULT_ET_TAG` reports it, so any valid quoting (single/double/none) works — no brittle regex over the source file:

```bash
if [ "${PRINT_ET_TAG:-0}" -eq 1 ]; then
  printf '%s\n' "$ET_TAG"   # ET_TAG defaults to DEFAULT_ET_TAG (overridable via --et-tag)
  exit 0
fi
```

Then, after the `--print-flags` early-exit block (after line 64) and after `PREFIX` is validated + `CONFIG` is set (lines 66-67), add the `--extras-only` block:

```bash
# ---- --extras-only: rebuild ONLY the extras against an existing prefix ----
# Used by the PR gate: a downloaded release tarball is the ET install; we rebuild the
# branch's custom ops on top of it. No ET compile, no --et-src, no ET-license/reloc steps —
# but DO run install_highway_license, because build_extras installs libhwy.a and a
# distributed local build must carry Highway's license too (parity with the full build).
if [ "${EXTRAS_ONLY:-0}" -eq 1 ]; then
  test -f "$CONFIG" \
    || { echo "--extras-only but $CONFIG is missing; provide a built/extracted ET prefix" >&2; exit 1; }
  build_extras
  install_highway_license
  echo ">> --extras-only done: $PREFIX"
  exit 0
fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash test/extras_only.test.sh`
Expected: `OK: --extras-only guards`

- [ ] **Step 6: Regression-check the rest of the shell suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS` (the extraction must not disturb existing tests).

- [ ] **Step 7: Commit**

```bash
git add build-runtime.sh test/extras_only.test.sh
git commit -m "feat(gate): build-runtime.sh --extras-only (phase-2-only rebuild)"
```

---

### Task 3: Fixture single-source (`lstm_case.py`) + round-trip refactor + shared runner helper

**Files:**
- Create: `extras/lstm/aot/lstm_case.py` (torch; the single source of dims/seed/weights/assertions). Lives under `aot/` — **not** `test/` — because it defines the export recipe + golden, so a change to it must trigger tier2 via the existing `aot/` classifier rule.
- Create: `extras/lstm/test/_runner.py` (torch-free cmake build/run helpers)
- Modify: `extras/lstm/test/test_lstm_roundtrip.py` (become a thin wrapper over `lstm_case` + `_runner`)

**Interfaces:**
- Produces: `lstm_case.DIMS` → `{"T":5,"B":2,"I":4,"H":3}`.
- Produces: `lstm_case.build_case()` → `(pte_bytes: bytes, in_bytes: bytes, golden_bytes: bytes, dims: dict)`. Deterministic (`torch.manual_seed(0)`). `golden_bytes` is the **eager** `nn.LSTM` output `[T,B,H]` as flat float32. Raises `AssertionError` on unexpected export arity (≠3 user inputs) or if the lowered program's op is not `etnp::lstm`/`out`.
- Produces: `_runner.build_runner(here: Path, prefix: Path, build_dir: Path) -> Path` and `_runner.run_runner(runner: Path, model: Path, inbin: Path, outbin: Path, dims: dict) -> None`.
- Consumed by: Task 4 (`emit_fixtures.py`), Task 5 (`consumer_smoke.py` uses `_runner`).

- [ ] **Step 1: Create `extras/lstm/test/_runner.py`** (torch-free)

```python
"""Torch-free helpers to build + run lstm_runner against an installed prefix.
Shared by the live round-trip (test_lstm_roundtrip.py) and the consumer smoke."""
import os
import pathlib
import subprocess


def build_runner(here: pathlib.Path, prefix: pathlib.Path, build_dir: pathlib.Path) -> pathlib.Path:
    subprocess.run(["cmake", "-B", str(build_dir), "-S", str(here), "-G", "Ninja",
                    f"-DCMAKE_PREFIX_PATH={prefix}", f"-DETNP_PREFIX={prefix}"], check=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "lstm_runner"], check=True)
    return build_dir / "lstm_runner"


def run_runner(runner: pathlib.Path, model: pathlib.Path, inbin: pathlib.Path,
               outbin: pathlib.Path, dims: dict) -> None:
    env = {**os.environ,
           "LSTM_T": str(dims["T"]), "LSTM_B": str(dims["B"]),
           "LSTM_I": str(dims["I"]), "LSTM_H": str(dims["H"])}
    subprocess.run([str(runner), str(model), str(inbin), str(outbin)], check=True, env=env)
```

- [ ] **Step 2: Create `extras/lstm/aot/lstm_case.py`** (torch)

```python
"""Single source of truth for the LSTM QA case: dims, seed, weights, export recipe,
and the arity / op-name assertions. Both the live round-trip and the published-fixture
emitter call build_case(), so the .pte/golden the gate consumes can never drift from
what the live test would produce.

NOTE on input arity: the 4 LSTM weights are plain (non-Parameter) attributes closed
over by forward, so torch.export lifts them as CONSTANTS baked into the .pte, NOT graph
inputs. The exported forward therefore takes only (x, h0, c0). build_case() asserts this
so a future export-recipe change that flips it back fails loudly here.
"""
import pathlib
import struct
import sys

import torch

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/aot/ -> repo root, for extras.*
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
import extras.lstm.aot.etnp_lstm_op  # noqa: E402,F401  registers torch.ops.etnp.lstm

DIMS = {"T": 5, "B": 2, "I": 4, "H": 3}


class Wrap(torch.nn.Module):
    def __init__(self, wih, whh, bih, bhh):
        super().__init__()
        self.wih, self.whh, self.bih, self.bhh = wih, whh, bih, bhh

    def forward(self, x, h0, c0):
        return torch.ops.etnp.lstm(x, h0, c0, self.wih, self.whh, self.bih, self.bhh)


def _flat(*ts) -> bytes:
    return b"".join(struct.pack(f"{t.numel()}f", *t.flatten().tolist()) for t in ts)


def build_case():
    """(pte_bytes, in_bytes, golden_bytes, dims). golden = eager nn.LSTM output."""
    from executorch.exir import to_edge_transform_and_lower
    T, B, I, H = DIMS["T"], DIMS["B"], DIMS["I"], DIMS["H"]
    torch.manual_seed(0)
    lstm = torch.nn.LSTM(I, H, num_layers=1, batch_first=False)
    wih, whh = lstm.weight_ih_l0.detach(), lstm.weight_hh_l0.detach()
    bih, bhh = lstm.bias_ih_l0.detach(), lstm.bias_hh_l0.detach()
    x = torch.randn(T, B, I)
    h0 = torch.zeros(B, H)
    c0 = torch.zeros(B, H)

    eager_out, _ = lstm(x, (h0.unsqueeze(0), c0.unsqueeze(0)))

    ep = torch.export.export(Wrap(wih, whh, bih, bhh), (x, h0, c0))
    user_inputs = [s for s in ep.graph_signature.input_specs
                   if s.kind == torch.export.graph_signature.InputKind.USER_INPUT]
    assert len(user_inputs) == 3, (
        f"expected 3 user inputs (x,h0,c0) with weights baked as constants, "
        f"got {len(user_inputs)}: {[s.arg.name for s in user_inputs]}")

    pte = to_edge_transform_and_lower(ep).to_executorch()
    ops = pte.executorch_program.execution_plan[0].operators
    assert any(op.name == "etnp::lstm" and op.overload == "out" for op in ops), ops

    return (pte.buffer, _flat(x, h0, c0),
            _flat(eager_out.detach()), dict(DIMS))
```

- [ ] **Step 3: Refactor `test_lstm_roundtrip.py` to use them**

Replace the whole file with the thin wrapper (behavior identical — build the case, run the runner against `ETNP_PREFIX`, compare to golden):

```python
"""Live round-trip: nn.LSTM -> export+lower through etnp::lstm -> run vs a C++ runner
built against the installed prefix -> compare to torch eager @ 1e-4.
Requires: torch + executorch (AOT), a built/installed prefix (ETNP_PREFIX), cmake, ninja.
The case (dims/seed/weights/assertions) lives once in lstm_case.py — the same source the
published fixtures are minted from, so live and frozen paths cannot drift."""
import os
import pathlib
import sys
import tempfile

import numpy as np

# Imports work from ANY cwd and each module has ONE canonical identity: put the repo root on
# sys.path and import both helpers by their FULL package path (never bare `_runner`/`lstm_case`,
# which only resolve when the containing dir happens to be on the path). `_runner` is the
# torch-free test helper under test/; `lstm_case` is AOT-side under aot/ (a change to it
# triggers tier2 — see scripts/classify-gate.sh).
HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test._runner import build_runner, run_runner  # noqa: E402
from extras.lstm.aot import lstm_case  # noqa: E402


def test_roundtrip_matches_eager():
    prefix = pathlib.Path(os.environ["ETNP_PREFIX"]).resolve()
    pte, in_bytes, golden, dims = lstm_case.build_case()

    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "lstm.pte").write_bytes(pte)
    (tmp / "in.bin").write_bytes(in_bytes)

    runner = build_runner(HERE, prefix, tmp / "rbuild")
    run_runner(runner, tmp / "lstm.pte", tmp / "in.bin", tmp / "out.bin", dims)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer(golden, dtype=np.float32)
    assert got.shape == ref.shape and np.allclose(got, ref, rtol=1e-4, atol=1e-4), \
        np.abs(got - ref).max()
```

Note: every module is imported by its full package path (`extras.lstm.test._runner`, `extras.lstm.aot.lstm_case`) after putting the repo root on `sys.path`, so imports are cwd-independent and each module has a single canonical identity — no bare sibling imports that depend on how the file was launched. See the **Import convention** in Global Constraints.

- [ ] **Step 4: Verify import wiring without torch**

Run: `python -c "import ast; ast.parse(open('extras/lstm/aot/lstm_case.py').read()); ast.parse(open('extras/lstm/test/_runner.py').read()); ast.parse(open('extras/lstm/test/test_lstm_roundtrip.py').read()); print('syntax ok')"`
Expected: `syntax ok`

(The full round-trip needs torch + executorch + a built prefix; it is exercised end-to-end by the Tier 2 / full-build workflow jobs and the local docker loop, not in the plain dev shell. See Task 8's manual dry-run.)

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/aot/lstm_case.py extras/lstm/test/_runner.py extras/lstm/test/test_lstm_roundtrip.py
git commit -m "refactor(gate): extract lstm_case single-source + shared runner helper"
```

---

### Task 4: `emit_fixtures.py` (mint the published fixture set)

**Files:**
- Create: `extras/lstm/aot/emit_fixtures.py` (torch; AOT-side, so a change to it triggers tier2 via the `aot/` rule)
- Test: `extras/lstm/test/test_emit_fixtures.py` (guarded: skips without torch)

**Interfaces:**
- Consumes: `lstm_case.build_case()`, `lstm_case.DIMS`.
- Produces: `python extras/lstm/aot/emit_fixtures.py <outdir>` writes `lstm.pte`, `in.bin`, `out.bin` (golden), and `shape` (lines `LSTM_T=5` … `LSTM_H=3`) into `<outdir>`.
- Produces (importable): `emit_fixtures.shape_text(dims: dict) -> str`.
- Consumed by: Task 5 (`consumer_smoke.parse_shape` parses the same `shape` format), Task 6 (release workflow), Task 8 (full-build dry-run).

- [ ] **Step 1: Write the failing test**

Create `extras/lstm/test/test_emit_fixtures.py`:

```python
import importlib.util
import pathlib
import sys

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.aot import emit_fixtures  # noqa: E402


def test_shape_text_format():
    txt = emit_fixtures.shape_text({"T": 5, "B": 2, "I": 4, "H": 3})
    assert txt == "LSTM_T=5\nLSTM_B=2\nLSTM_I=4\nLSTM_H=3\n"


@pytest.mark.skipif(importlib.util.find_spec("torch") is None,
                    reason="torch not installed in this env")
def test_emit_writes_all_members(tmp_path):
    emit_fixtures.main(tmp_path)
    for m in ("lstm.pte", "in.bin", "out.bin", "shape"):
        assert (tmp_path / m).stat().st_size > 0, m
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest extras/lstm/test/test_emit_fixtures.py::test_shape_text_format -v`
Expected: FAIL (`emit_fixtures` does not exist).

- [ ] **Step 3: Create `extras/lstm/aot/emit_fixtures.py`**

```python
"""Mint the published LSTM fixture set from lstm_case.build_case() (the same source the
live round-trip uses). Writes lstm.pte, in.bin, out.bin (golden eager output), and a
shape file (LSTM_<dim>=<n> lines) the torch-free consumer smoke reads."""
import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/aot/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


def shape_text(dims: dict) -> str:
    return "".join(f"LSTM_{k}={v}\n" for k, v in dims.items())


def main(outdir: pathlib.Path) -> None:
    from extras.lstm.aot import lstm_case  # torch import deferred so shape_text stays torch-free
    pte, in_bytes, golden, dims = lstm_case.build_case()
    outdir = pathlib.Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "lstm.pte").write_bytes(pte)
    (outdir / "in.bin").write_bytes(in_bytes)
    (outdir / "out.bin").write_bytes(golden)
    (outdir / "shape").write_text(shape_text(dims))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: emit_fixtures.py <outdir>\n")
        sys.exit(2)
    main(pathlib.Path(sys.argv[1]))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest extras/lstm/test/test_emit_fixtures.py -v`
Expected: `test_shape_text_format` PASS; `test_emit_writes_all_members` PASS or SKIP (skips if torch absent).

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/aot/emit_fixtures.py extras/lstm/test/test_emit_fixtures.py
git commit -m "feat(gate): emit_fixtures.py mints published .pte/golden/shape"
```

---

### Task 5: `consumer_smoke.py` (torch-free run of published .pte vs golden)

**Files:**
- Create: `extras/lstm/test/consumer_smoke.py` (numpy-only)
- Test: `extras/lstm/test/test_consumer_smoke.py` (numpy-only pure-logic tests)

**Interfaces:**
- Consumes: `_runner.build_runner`/`run_runner`; a fixtures dir (`lstm.pte`, `in.bin`, `out.bin`, `shape`); `ETNP_PREFIX`.
- Produces (importable, testable without a prefix): `consumer_smoke.parse_shape(path) -> dims`; `consumer_smoke.within_tol(got, ref) -> bool`.
- Produces (CLI): `FIXTURES_DIR=<dir> ETNP_PREFIX=<prefix> python extras/lstm/test/consumer_smoke.py` → builds `lstm_runner`, runs the published `.pte`, compares to golden `out.bin` at 1e-4; exits non-zero on mismatch.
- Consumed by: Task 8 (Tier 1 job).

- [ ] **Step 1: Write the failing test**

Create `extras/lstm/test/test_consumer_smoke.py`:

```python
import pathlib
import sys

import numpy as np

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test import consumer_smoke  # noqa: E402


def test_parse_shape_roundtrip(tmp_path):
    (tmp_path / "shape").write_text("LSTM_T=5\nLSTM_B=2\nLSTM_I=4\nLSTM_H=3\n")
    assert consumer_smoke.parse_shape(tmp_path / "shape") == {"T": 5, "B": 2, "I": 4, "H": 3}


def test_within_tol():
    a = np.array([1.0, 2.0, 3.0], dtype=np.float32)
    assert consumer_smoke.within_tol(a, a + 1e-6)
    assert not consumer_smoke.within_tol(a, a + 1e-2)
    assert not consumer_smoke.within_tol(a, a[:2])   # shape mismatch
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest extras/lstm/test/test_consumer_smoke.py -v`
Expected: FAIL (`consumer_smoke` does not exist).

- [ ] **Step 3: Create `extras/lstm/test/consumer_smoke.py`**

```python
"""Torch-free consumer smoke: build lstm_runner against an installed prefix, run a
PUBLISHED .pte over its in.bin, and compare to the published golden out.bin @ 1e-4.
This is the same contract the downstream numpy runtime will exercise. No torch."""
import os
import pathlib
import sys
import tempfile

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = HERE.parents[2]                       # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test._runner import build_runner, run_runner  # noqa: E402


def parse_shape(path) -> dict:
    d = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        k, v = line.split("=", 1)
        d[k] = v
    return {"T": int(d["LSTM_T"]), "B": int(d["LSTM_B"]),
            "I": int(d["LSTM_I"]), "H": int(d["LSTM_H"])}


def within_tol(got, ref, rtol: float = 1e-4, atol: float = 1e-4) -> bool:
    return got.shape == ref.shape and bool(np.allclose(got, ref, rtol=rtol, atol=atol))


def main(fixtures_dir: pathlib.Path, prefix: pathlib.Path) -> None:
    dims = parse_shape(fixtures_dir / "shape")
    tmp = pathlib.Path(tempfile.mkdtemp())
    runner = build_runner(HERE, prefix, tmp / "rbuild")
    run_runner(runner, fixtures_dir / "lstm.pte", fixtures_dir / "in.bin", tmp / "out.bin", dims)

    got = np.frombuffer((tmp / "out.bin").read_bytes(), dtype=np.float32)
    ref = np.frombuffer((fixtures_dir / "out.bin").read_bytes(), dtype=np.float32)
    if not within_tol(got, ref):
        sys.stderr.write(
            "consumer smoke MISMATCH: the branch kernel does not reproduce the published "
            "golden. If this is an INTENTIONAL numeric change, re-bless the fixtures via the "
            f"live round-trip (see docs/extras-gate.md). max|diff|={np.abs(got - ref).max()}\n")
        sys.exit(1)
    print("consumer smoke OK")


if __name__ == "__main__":
    main(pathlib.Path(os.environ["FIXTURES_DIR"]).resolve(),
         pathlib.Path(os.environ["ETNP_PREFIX"]).resolve())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest extras/lstm/test/test_consumer_smoke.py -v`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add extras/lstm/test/consumer_smoke.py extras/lstm/test/test_consumer_smoke.py
git commit -m "feat(gate): torch-free consumer_smoke over published fixtures"
```

---

### Task 6: Shared CI composite actions + publish fixtures from the release build

**Files:**
- Create: `.github/actions/checkout-executorch/action.yml`
- Create: `.github/actions/lstm-roundtrip/action.yml`
- Modify: `.github/workflows/release.yml` (use both composites; add fixture emit + package)

**Interfaces:**
- Produces (reusable composite actions, consumed here **and** by Task 8):
  - `./.github/actions/checkout-executorch` — input `ref` (ET tag, e.g. `v1.3.1`); checks out `pytorch/executorch` with submodules into `./executorch`.
  - `./.github/actions/lstm-roundtrip` — inputs `prefix` (ET install to test → `ETNP_PREFIX`) and `executorch-src` (default `executorch`); installs the ET python package and runs `test_lstm_roundtrip.py`.
- Consumes: `emit_fixtures.py` (Task 4), `scripts/package-fixtures.sh` (Task 1), the built `out` prefix + the torch/executorch the round-trip action just installed.
- Produces: `dist/etnp-lstm-fixtures-<etver>.tar.gz` + `.sha256` in the `logging`/`linux-x86_64` cell, which the **existing** `Attest` (`subject-path: dist/*.tar.gz`) + `upload-artifact` (`path: dist/*`) steps attest + publish automatically. The `pin` job's name-specific globbing ignores it; `release`'s `gh release create dist/*` includes it.

**Context / why hoist:** the ET checkout (`repository/ref/submodules/path`) and the live round-trip (`install_executorch` + `pip` + `pytest`) are each duplicated **3×** — release build, gate `live-roundtrip`, gate `full-build` — and both carry correctness-critical detail (the `submodules: recursive` flag; the exact install+pytest sequence). Two composite actions remove that drift risk with no new machinery. (The intra-gate scrub + `--extras-only` block is a smaller, gate-only duplicate — left inline for now; see Deferred / future work.) Fixtures are arch-independent, so they are emitted in **x86_64 logging only**.

- [ ] **Step 1: Create `.github/actions/checkout-executorch/action.yml`**

```yaml
name: Checkout ExecuTorch
description: Check out pytorch/executorch at a tag with submodules, into ./et-src/executorch
inputs:
  ref:
    description: ExecuTorch git ref/tag (e.g. v1.3.1)
    required: true
runs:
  using: composite
  steps:
    - uses: actions/checkout@v7
      with:
        repository: pytorch/executorch
        ref: ${{ inputs.ref }}
        submodules: recursive
        # Nested: install_executorch.sh requires the LEAF dir be named exactly 'executorch'
        # (open since v0.4.0), but a top-level ./executorch shadows the installed wheel under
        # `python -m pytest`'s cwd-on-sys.path (missing exir/_serialize/program.fbs). Nesting
        # gives leaf 'executorch' while the workspace root holds only 'et-src'. pytorch/executorch#5766.
        path: et-src/executorch
```

- [ ] **Step 2: Create `.github/actions/lstm-roundtrip/action.yml`**

```yaml
name: LSTM live round-trip
description: Install the ExecuTorch python package and run the export->run-vs-eager round-trip against a prefix
inputs:
  prefix:
    description: ET install prefix to test against (becomes ETNP_PREFIX)
    required: true
  executorch-src:
    description: Path to the checked-out ExecuTorch source (for install_executorch.sh)
    required: false
    default: et-src/executorch
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        export PATH=/opt/python/cp312-cp312/bin:$PATH
        # AOT export needs the executorch python package from the SAME pinned ET source.
        (cd "${{ inputs.executorch-src }}" && ./install_executorch.sh)
        pip install numpy pytest ninja
        ETNP_PREFIX="${{ inputs.prefix }}" python -m pytest extras/lstm/test/test_lstm_roundtrip.py -v
```

- [ ] **Step 3: Refactor `release.yml` to use the composites**

Replace the `Checkout ExecuTorch source` step (`release.yml:56-62`) with:

```yaml
      - name: Checkout ExecuTorch source
        uses: ./.github/actions/checkout-executorch
        with:
          ref: ${{ steps.ver.outputs.ettag }}
```

Replace the `LSTM round-trip gate` step (`release.yml:69-85`) — keeping its `if: matrix.variant == 'logging'` guard (variant-identical kernel: gate `logging` only, both platforms) — with a call to the composite:

```yaml
      - name: LSTM round-trip gate (export -> run vs eager)
        # Variant-identical kernel: gate on `logging` only (both platforms). The round-trip
        # recipe now lives in the composite action, shared with the extras-gate workflow.
        if: matrix.variant == 'logging'
        uses: ./.github/actions/lstm-roundtrip
        with:
          prefix: ${{ github.workspace }}/out
```

- [ ] **Step 4: Add the fixture emit + package step**

Insert immediately **after** the `LSTM round-trip gate` step and **before** the `Package` step:

```yaml
      - name: Emit + package LSTM fixtures (arch-independent; x86_64 logging only)
        if: matrix.variant == 'logging' && matrix.combo.platform == 'linux-x86_64'
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          # torch + executorch are already installed by the round-trip action above; the
          # built prefix is $PWD/out. Mint the fixtures from the SAME lstm_case source.
          python extras/lstm/aot/emit_fixtures.py "$PWD/fixtures"
          mkdir -p "$PWD/dist"
          ./scripts/package-fixtures.sh --dir "$PWD/fixtures" \
            --etver "${{ steps.ver.outputs.etver }}" --outdir "$PWD/dist"
```

The subsequent `Package` step also writes into `$PWD/dist`; both tarballs land there, so the existing `Attest`/`upload-artifact` steps cover both.

- [ ] **Step 5: Validate the workflow + actions parse**

Run: `python3 -c "import yaml; [yaml.safe_load(open(p)) for p in ['.github/workflows/release.yml','.github/actions/checkout-executorch/action.yml','.github/actions/lstm-roundtrip/action.yml']]; print('yaml ok')"`
Expected: `yaml ok`
(If `actionlint` is installed: `actionlint` → no errors.)

- [ ] **Step 6: Commit**

```bash
git add .github/actions/checkout-executorch/action.yml .github/actions/lstm-roundtrip/action.yml .github/workflows/release.yml
git commit -m "feat(gate): checkout-executorch + lstm-roundtrip composite actions; publish fixtures"
```

---

### Task 7: `classify-gate.sh` (tier decision)

**Files:**
- Create: `scripts/classify-gate.sh`
- Test: `test/classify_gate.test.sh`

**Interfaces:**
- Produces: `scripts/classify-gate.sh <changed-files-file>` → prints `mode=<tier1|tier2|full>`, `etver=<x.y.z>`, `release_tag=<v..-..|>` (three `key=value` lines, `$GITHUB_OUTPUT`-appendable).
- Decision order: (1) any `build-runtime.sh` change → `full`; (2) else resolve newest `v<etver>-*` release — none → `full`; (3) else any AOT/schema file changed → `tier2`; (4) else → `tier1`.
- AOT/schema match: a changed path matching `^extras/([^/]+/)?aot/`, or basename `generate_schema_header.py`, or basename `extra.yaml`. The `aot/` arm deliberately covers `extras/lstm/aot/lstm_case.py` and `extras/lstm/aot/emit_fixtures.py` — the fixture-defining files were placed under `aot/` (Tasks 3–4) precisely so a change to them forces tier2, rather than needing a special-case rule here.
- Test hooks (env): `GATE_ET_TAG` overrides the ET-pin read (else `build-runtime.sh --print-et-tag`); `GATE_RELEASE_TAG` (set, possibly empty) overrides the `gh` lookup — empty string means "no release"; `GATE_GH_CMD` overrides the `gh` binary (inject a stub/`false`); `GATE_RETRY_SLEEP` overrides the retry backoff (set `0` in tests). When the `gh` lookup is used and **fails** after 3 attempts (as opposed to returning no rows), the script exits non-zero (code 3) rather than emitting `full` — a transient infra error must not masquerade as a build-recipe change.
- Consumed by: Task 8 (`classify` job).

**Note (accepted gap):** a PR that edits **only `extras/lstm/test/test_lstm_roundtrip.py`** (the live-round-trip test itself, not the case/kernel/AOT) classifies **tier1** — it is a `test/` file and defines no fixtures — so the live round-trip does not re-run to validate the edited test. This is accepted as low-risk: it is the test harness, not shipped source or the published fixtures. If a future change makes this matter, add a narrow `test_lstm_roundtrip.py → tier2` clause to the AOT/schema match. Documented for contributors in `docs/extras-gate.md` (Task 9).

- [ ] **Step 1: Write the failing test**

Create `test/classify_gate.test.sh`:

```bash
#!/usr/bin/env bash
# classify-gate.sh picks tier1/tier2/full from a changed-files list, with the gh
# release lookup stubbed via GATE_RELEASE_TAG and the ET tag via GATE_ET_TAG.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

run() {  # run <changed-lines> ; sets $out (mode/etver/release_tag)
  printf '%s\n' "$1" > "$tmp/ch"
  out="$(GATE_ET_TAG="${GATE_ET_TAG:-v1.3.1}" "$root/scripts/classify-gate.sh" "$tmp/ch")"
}
mode() { printf '%s\n' "$out" | sed -n 's/^mode=//p'; }
check() { [ "$(mode)" = "$2" ] || { echo "FAIL [$1]: mode=$(mode) want=$2"; fail=1; }; }

# a build-runtime.sh change is always full, even with a release present
GATE_RELEASE_TAG="v1.3.1-2" run "build-runtime.sh"                ; check buildsh full
# pure kernel edit, release exists -> tier1
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/runtime/lstm_cell.cc"; check kernel tier1
# AOT change -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/etnp_lstm_op.py" ; check aot   tier2
# schema generator -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/generate_schema_header.py"; check schema tier2
# extra.yaml (op name/schema) -> tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/extra.yaml"          ; check yaml  tier2
# fixture-defining files live under aot/ -> tier2 (guards the classification bug this fixes)
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/lstm_case.py"    ; check case  tier2
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/aot/emit_fixtures.py"; check emit  tier2
# no matching release -> full (even for a pure kernel edit)
GATE_RELEASE_TAG="" run "extras/lstm/runtime/lstm_cell.cc"        ; check norelease full
# etver is derived from the ET tag (GATE_ET_TAG override, via run())
GATE_RELEASE_TAG="v1.3.1-2" run "extras/lstm/runtime/lstm_cell.cc"
printf '%s\n' "$out" | grep -q '^etver=1.3.1$' || { echo "FAIL etver parse"; fail=1; }

# etver derived from the REAL build-runtime.sh --print-et-tag when GATE_ET_TAG is unset
# (integration: proves classify reads the pin without regex-scraping the source)
printf 'extras/lstm/runtime/lstm_cell.cc\n' > "$tmp/ch"
out="$(GATE_RELEASE_TAG="v1.3.1-2" "$root/scripts/classify-gate.sh" "$tmp/ch")"
printf '%s\n' "$out" | grep -q '^etver=1.3.1$' || { echo "FAIL: etver via --print-et-tag"; fail=1; }

# transient gh failure (no GATE_RELEASE_TAG) exits non-zero — must NOT silently emit full
printf 'extras/lstm/runtime/lstm_cell.cc\n' > "$tmp/ch"
if GATE_ET_TAG="v1.3.1" GATE_GH_CMD="false" GATE_RETRY_SLEEP=0 \
     "$root/scripts/classify-gate.sh" "$tmp/ch" >/dev/null 2>&1; then
  echo "FAIL: gh failure should exit non-zero, not succeed"; fail=1
fi

# a working gh stub (no GATE_RELEASE_TAG) resolves the newest matching tag -> tier1
cat > "$tmp/ghstub" <<'STUB'
#!/usr/bin/env bash
printf 'v1.2.0-9\nv1.3.1-1\nv1.3.1-2\n'   # emulates: gh release list --json tagName --jq '.[].tagName'
STUB
chmod +x "$tmp/ghstub"
out="$(GATE_ET_TAG="v1.3.1" GATE_GH_CMD="$tmp/ghstub" "$root/scripts/classify-gate.sh" "$tmp/ch")"
[ "$(mode)" = "tier1" ] || { echo "FAIL: stub resolve mode=$(mode)"; fail=1; }
printf '%s\n' "$out" | grep -q '^release_tag=v1.3.1-2$' || { echo "FAIL: stub newest tag"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: classify-gate" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/classify_gate.test.sh`
Expected: FAIL (script does not exist).

- [ ] **Step 3: Create `scripts/classify-gate.sh`**

```bash
#!/usr/bin/env bash
# Decide the extras-gate mode from a PR's changed-files list.
#   classify-gate.sh <changed-files-file>   # prints mode=/etver=/release_tag=
# Order: build-runtime.sh change -> full ; no matching release -> full ;
#        AOT/schema change -> tier2 ; else -> tier1.
# A gh lookup FAILURE (distinct from an empty result) exits non-zero rather than silently
# falling back to full — an infra error is re-runnable, not a build-recipe change.
# Test hooks: GATE_ET_TAG overrides the ET-pin read (else `build-runtime.sh --print-et-tag`);
#             GATE_RELEASE_TAG (set,
# maybe empty) overrides the gh lookup entirely (empty = no release); GATE_GH_CMD
# overrides the `gh` binary; GATE_RETRY_SLEEP overrides the retry backoff (0 in tests).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHANGED="${1:?usage: classify-gate.sh <changed-files-file>}"

# etver from the branch's ET pin (v1.3.1 -> 1.3.1). Ask build-runtime.sh to PRINT the tag
# rather than regex-scraping the source: the script that defines DEFAULT_ET_TAG reports it
# through the shell, so any valid quoting (single/double/none) works and a brittle sed can't
# silently yield an empty tag.
ettag="${GATE_ET_TAG:-$("$ROOT/build-runtime.sh" --print-et-tag)}"
etver="${ettag#v}"

emit() { printf 'mode=%s\netver=%s\nrelease_tag=%s\n' "$1" "$etver" "${2:-}"; }

# (1) any build-runtime.sh change forces a full build (it owns phase 1 + packaging)
if grep -qx 'build-runtime.sh' "$CHANGED"; then
  emit full ""; exit 0
fi

# (2) resolve the newest matching package release.
# A transient `gh` failure must NOT be silently treated as "no release" (which would waste
# a ~15min full build and mislabel the PR). Distinguish: an empty result from a SUCCESSFUL
# call means genuinely no release -> full; a FAILED call after retries is an infra problem
# -> exit non-zero so the (re-runnable) job fails visibly.
GH="${GATE_GH_CMD:-gh}"
if [ -n "${GATE_RELEASE_TAG+x}" ]; then
  release_tag="$GATE_RELEASE_TAG"
else
  release_tag=""; resolved=0
  for attempt in 1 2 3; do
    if tags="$("$GH" release list --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null)"; then
      resolved=1
      release_tag="$(printf '%s\n' "$tags" | grep -E "^v${etver}-" | sort -V | tail -n1 || true)"
      break
    fi
    [ "$attempt" -lt 3 ] && sleep "${GATE_RETRY_SLEEP:-$((attempt * 3))}"
  done
  if [ "$resolved" -ne 1 ]; then
    echo "classify-gate.sh: 'gh release list' failed after 3 attempts (transient?); refusing" >&2
    echo "  to default to a full build on an infra error — re-run this job." >&2
    exit 3
  fi
fi
if [ -z "$release_tag" ]; then
  emit full ""; exit 0
fi

# (3) AOT / schema change -> tier2 (the live round-trip must run)
if grep -qE '^extras/([^/]+/)?aot/|(^|/)generate_schema_header\.py$|(^|/)extra\.yaml$' "$CHANGED"; then
  emit tier2 "$release_tag"; exit 0
fi

# (4) default: pure-kernel / runtime / test edit
emit tier1 "$release_tag"
```

Make executable: `chmod +x scripts/classify-gate.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/classify_gate.test.sh`
Expected: `OK: classify-gate`

- [ ] **Step 5: Full shell-suite regression**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`

- [ ] **Step 6: Commit**

```bash
git add scripts/classify-gate.sh test/classify_gate.test.sh
git commit -m "feat(gate): classify-gate.sh tier decision"
```

---

### Task 8: The `extras-gate.yml` PR workflow

**Files:**
- Create: `.github/workflows/extras-gate.yml`

**Interfaces:**
- Consumes: `scripts/classify-gate.sh` (Task 7), `build-runtime.sh --extras-only` (Task 2), the `checkout-executorch` + `lstm-roundtrip` composite actions (Task 6), `consumer_smoke.py` (Task 5), `test_lstm_roundtrip.py` (Task 3), `emit_fixtures.py` (Task 4), and the published tarball/fixtures (Task 6). **Depends on Task 6** for the composite actions — the `live-roundtrip`/`full-build` jobs `uses: ./.github/actions/...`.
- Jobs: `classify` (ubuntu) → `fetch` (ubuntu, tier1|tier2: gh download+verify, upload `gate-inputs`) → `fast-gate` (manylinux matrix, both arches: scrub + `--extras-only` + consumer_smoke), `live-roundtrip` (manylinux x86_64, tier2 only), `full-build` (manylinux x86_64, full only).

**Context / rationale baked into comments:** `gh` is unavailable in manylinux → all `gh` use is confined to the ubuntu `fetch`/`classify` jobs; container jobs receive artifacts via `actions/download-artifact`. Tier 1 + Tier 2 both **rebuild extras from the branch** so the kernel under test is the branch's, not the shipped one.

- [ ] **Step 1: Create `.github/workflows/extras-gate.yml`**

```yaml
name: extras-gate
on:
  pull_request:
    paths:
      - 'extras/**'
      - 'build-runtime.sh'
      - 'scripts/classify-gate.sh'
      - '.github/workflows/extras-gate.yml'

permissions:
  contents: read

jobs:
  classify:
    runs-on: ubuntu-latest
    outputs:
      mode: ${{ steps.c.outputs.mode }}
      etver: ${{ steps.c.outputs.etver }}
      release_tag: ${{ steps.c.outputs.release_tag }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0            # need the merge base to diff against base_ref
      - name: Changed files vs base
        run: git diff --name-only "origin/${{ github.base_ref }}...HEAD" > changed.txt
      - id: c
        env:
          GH_TOKEN: ${{ github.token }}   # classify-gate.sh's gh release lookup
        run: ./scripts/classify-gate.sh changed.txt | tee -a "$GITHUB_OUTPUT"

  # Download + verify (sha256 + attestation) the logging tarballs (both arches) and the
  # fixtures in an ubuntu job, because `gh` is not present in the manylinux containers.
  fetch:
    needs: classify
    if: needs.classify.outputs.mode == 'tier1' || needs.classify.outputs.mode == 'tier2'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      attestations: read        # gh attestation verify (same-repo PRs; fork tokens can't elevate)
    env:
      ETVER: ${{ needs.classify.outputs.etver }}
      RELEASE_TAG: ${{ needs.classify.outputs.release_tag }}
      GH_TOKEN: ${{ github.token }}
      # Fork PRs run with a reduced, secret-less read token GitHub does not let the workflow
      # elevate, so `gh attestation verify` can fail on forks. sha256 is the MANDATORY
      # integrity gate in every case (the .sha256 is published by our release, so a match
      # proves the bytes are exactly what we shipped); attestation is defense-in-depth —
      # enforced for same-repo PRs, best-effort (skipped with a notice) on forks, so
      # external contributions are never blocked.
      IS_SAME_REPO: ${{ github.event.pull_request.head.repo.full_name == github.repository }}
    steps:
      - name: Download + verify runtime tarballs + fixtures
        run: |
          set -euo pipefail
          mkdir gate-inputs
          # Build the -p pattern list as a bash ARRAY (never via `printf %q` + word-split:
          # %q emits shell quoting that command-substitution does NOT re-parse, so a quoted
          # token would reach gh as a literal-quote glob and silently match nothing).
          fx="etnp-lstm-fixtures-${ETVER}.tar.gz"
          patterns=( -p "$fx" -p "$fx.sha256" )
          for plat in linux-x86_64 linux-aarch64; do
            tb="executorch-runtime-${ETVER}-logging-${plat}.tar.gz"
            patterns+=( -p "$tb" -p "$tb.sha256" )
          done
          ( cd gate-inputs && gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" "${patterns[@]}" )
          cd gate-inputs
          for f in *.tar.gz; do
            sha256sum -c "$f.sha256"                 # mandatory integrity gate (all PRs, incl. forks)
          done
          if [ "$IS_SAME_REPO" = "true" ]; then
            for f in *.tar.gz; do
              gh attestation verify "$f" --repo "$GITHUB_REPOSITORY"   # provenance (defense-in-depth)
            done
          else
            echo "::notice::fork PR — skipping gh attestation verify (fork token lacks access); sha256 integrity is still enforced. See docs/extras-gate.md."
          fi
      - uses: actions/upload-artifact@v7
        with:
          name: gate-inputs
          path: gate-inputs/*

  # Tier 1: torch-free consumer smoke on BOTH arches. Rebuilds extras from the branch
  # against the downloaded prefix, then runs the published .pte vs golden.
  fast-gate:
    needs: [classify, fetch]
    if: needs.classify.outputs.mode == 'tier1' || needs.classify.outputs.mode == 'tier2'
    runs-on: ${{ matrix.combo.runs_on }}
    container:
      image: ${{ matrix.combo.container }}
    strategy:
      fail-fast: false
      matrix:
        combo:
          - { platform: linux-x86_64,  container: "quay.io/pypa/manylinux_2_28_x86_64",  runs_on: ubuntu-latest }
          - { platform: linux-aarch64, container: "quay.io/pypa/manylinux_2_28_aarch64", runs_on: ubuntu-24.04-arm }
    env:
      ETVER: ${{ needs.classify.outputs.etver }}
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with:
          name: gate-inputs
          path: gate-inputs
      - name: Extract prefix + fixtures
        run: |
          set -euo pipefail
          mkdir prefix fixtures
          tar -C prefix   -xzf "gate-inputs/executorch-runtime-${ETVER}-logging-${{ matrix.combo.platform }}.tar.gz" --strip-components=1
          tar -C fixtures -xzf "gate-inputs/etnp-lstm-fixtures-${ETVER}.tar.gz"
      - name: Scrub shipped extras (so a rename/removal cannot false-pass)
        run: |
          rm -f  prefix/lib/libetnp_ops_*.a
          rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp
      - name: Rebuild extras from branch (phase 2 only) + consumer smoke
        run: |
          set -euo pipefail
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          pip install ninja numpy    # cmake is present in the manylinux image (as in release.yml)
          ./build-runtime.sh --extras-only --variant logging --prefix "$PWD/prefix"
          FIXTURES_DIR="$PWD/fixtures" ETNP_PREFIX="$PWD/prefix" \
            python extras/lstm/test/consumer_smoke.py

  # Tier 2: the live torch round-trip (AOT<->runtime drift), reusing the downloaded
  # prefix so it STILL skips the ~15min ET compile — only torch/export is added.
  live-roundtrip:
    needs: [classify, fetch]
    if: needs.classify.outputs.mode == 'tier2'
    runs-on: ubuntu-latest
    container:
      image: "quay.io/pypa/manylinux_2_28_x86_64"
    env:
      ETVER: ${{ needs.classify.outputs.etver }}
    steps:
      - uses: actions/checkout@v7
      - name: Checkout ExecuTorch source (for the export python package)
        uses: ./.github/actions/checkout-executorch
        with:
          ref: v${{ needs.classify.outputs.etver }}
      - uses: actions/download-artifact@v8
        with:
          name: gate-inputs
          path: gate-inputs
      - name: Extract prefix + rebuild extras from branch
        run: |
          set -euo pipefail
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          mkdir prefix
          tar -C prefix -xzf "gate-inputs/executorch-runtime-${ETVER}-logging-linux-x86_64.tar.gz" --strip-components=1
          rm -f  prefix/lib/libetnp_ops_*.a
          rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp
          pip install ninja
          ./build-runtime.sh --extras-only --variant logging --prefix "$PWD/prefix"
      - name: Live round-trip (export -> run vs eager)
        uses: ./.github/actions/lstm-roundtrip
        with:
          prefix: ${{ github.workspace }}/prefix

  # Fallback: any build-runtime.sh change (or no matching release) → a full-build
  # release DRY-RUN. Full ET compile + live round-trip + fixture-emit (not published),
  # so a green gate means the eventual release tag will build — before spending a pkgrev.
  full-build:
    needs: classify
    if: needs.classify.outputs.mode == 'full'
    runs-on: ubuntu-latest
    container:
      image: "quay.io/pypa/manylinux_2_28_x86_64"
    env:
      ETVER: ${{ needs.classify.outputs.etver }}
    steps:
      - uses: actions/checkout@v7
      - name: Checkout ExecuTorch source
        uses: ./.github/actions/checkout-executorch
        with:
          ref: v${{ needs.classify.outputs.etver }}
      - name: Full build (release dry-run — full ET compile)
        run: |
          set -euo pipefail
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          ./build-runtime.sh --variant logging --prefix "$PWD/out" \
            --et-src "$PWD/et-src/executorch" --et-tag "v${ETVER}"
      - name: Live round-trip (export -> run vs eager)
        uses: ./.github/actions/lstm-roundtrip
        with:
          prefix: ${{ github.workspace }}/out
      - name: Fixture-emit dry-run (prove emit works; not published)
        run: |
          export PATH=/opt/python/cp312-cp312/bin:$PATH
          python extras/lstm/aot/emit_fixtures.py "$PWD/fixtures-dryrun"
```

- [ ] **Step 2: Validate the workflow parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/extras-gate.yml')); print('yaml ok')"`
Expected: `yaml ok`
(If `actionlint` is installed: `actionlint .github/workflows/extras-gate.yml` → no errors.)

- [ ] **Step 3: Local Tier-1 dry-run (manual, documents the mechanism)**

This proves the Tier-1 mechanics without CI, using the local docker loop from the design doc. Requires a published release to exist for the pinned ET version (or a locally-built+packaged tarball + fixtures). Record the outcome in the PR description.

```bash
# given a downloaded/extracted logging tarball at ./prefix and fixtures at ./fixtures:
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH
  pip install ninja numpy
  rm -f prefix/lib/libetnp_ops_*.a; rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp
  ./build-runtime.sh --extras-only --variant logging --prefix /work/prefix
  FIXTURES_DIR=/work/fixtures ETNP_PREFIX=/work/prefix python extras/lstm/test/consumer_smoke.py'
```
Expected: `consumer smoke OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/extras-gate.yml
git commit -m "feat(gate): extras-gate.yml path-filtered PR gate (tier1/tier2/full)"
```

---

### Task 9: Usage & troubleshooting documentation

**Files:**
- Create: `docs/extras-gate.md`

**Interfaces:** none (contributor-facing doc). Required deliverable per spec §6.

- [ ] **Step 1: Create `docs/extras-gate.md`**

Write the guide covering exactly the spec §6 checklist. Use this structure and fill each section with real content (no placeholders):

````markdown
# The extras (custom-code) QA gate

## What it is / why it looks unusual
- The runtime build has two phases: a slow ExecuTorch compile (~10–15 min) that installs
  a prefix, and a fast **extras** phase that compiles the custom LSTM op against that
  prefix. A *released tarball is a prebuilt phase-1 prefix*.
- The PR gate downloads an **attested** release tarball, scrubs the shipped extras out,
  rebuilds extras **from your branch** (`build-runtime.sh --extras-only`), and runs your
  kernel against a **published `.pte` + golden** fixture set — so it never pays the ET
  compile.

## Which tier runs (I changed X → …)
| You changed | Gate | Cost |
|---|---|---|
| kernel / runtime / test under `extras/**` (not `aot/`) | **tier1** — torch-free consumer smoke, both arches | cheap |
| AOT def / schema / fixture source (`extras/**/aot/**` — incl. `lstm_case.py` + `emit_fixtures.py` — `generate_schema_header.py`, `extra.yaml`) | **tier1 + tier2** — adds the live round-trip | + torch/export |
| **`build-runtime.sh`** (any change), or no release exists for the pinned ET | **full** — a full-build release dry-run | ~15 min |

Decision logic lives in `scripts/classify-gate.sh` (unit-tested in `test/classify_gate.test.sh`).

## Reading a result
- **tier1 green:** the branch kernel reproduces the published golden on both arches, and
  the static-registration/whole-archive guard passed.
- **tier1 `consumer smoke MISMATCH`:** either a real kernel regression **or** an
  *intentional* numeric change. Never loosen the tolerance — **re-bless** (below).
- **tier2:** additionally proves AOT↔runtime agreement (the "exports fine / op-not-found
  at runtime" class). Only tier2/full re-derive the `.pte` from your AOT source.
- **full:** a faithful dry-run of the release build; green means the release tag will build.

## Reproduce locally
Use the manylinux docker loop (same two caller-owned boundaries as CI):
```bash
# tier1 mechanics against a local ./prefix (extracted logging tarball) + ./fixtures:
docker run --rm -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_x86_64 bash -lc '
  export PATH=/opt/python/cp312-cp312/bin:$PATH; pip install ninja numpy
  rm -f prefix/lib/libetnp_ops_*.a; rm -rf prefix/lib/cmake/ETNPExtras prefix/include/etnp
  ./build-runtime.sh --extras-only --variant logging --prefix /work/prefix
  FIXTURES_DIR=/work/fixtures ETNP_PREFIX=/work/prefix python extras/lstm/test/consumer_smoke.py'
```
For the full build / live round-trip, mount an ExecuTorch checkout and run
`build-runtime.sh --variant logging --prefix … --et-src …` then the round-trip (see the
design/handover docs).

## Re-blessing fixtures (intentional numeric or AOT change)
The published `.pte`/golden come from `extras/lstm/aot/lstm_case.py` via
`extras/lstm/aot/emit_fixtures.py`. To change them:
1. Update `lstm_case.py` (and the kernel/AOT as needed).
2. In an env with torch + executorch installed against the pinned ET, run the **live**
   round-trip to confirm agreement: `ETNP_PREFIX=<prefix> pytest extras/lstm/test/test_lstm_roundtrip.py`.
3. Cut a release — the release build re-mints and publishes
   `etnp-lstm-fixtures-<etver>.tar.gz` from the same source. The next PR's tier1 then
   compares against the new golden.

## Troubleshooting
- **`gh attestation verify` on a fork PR:** fork PRs run with a reduced, secret-less read
  token GitHub won't let the workflow elevate, so attestation verify is **skipped on forks**
  (you'll see a `::notice::`) while `sha256sum -c` is enforced in every case. On a
  **same-repo** PR a genuine verify failure means the asset isn't provenance-attested — do
  not proceed; re-cut the release. `gh` runs only in the ubuntu `fetch`/`classify` jobs (it
  is absent from manylinux).
- **`classify` fails with "gh release list failed after 3 attempts":** a transient GitHub
  API/network error while resolving the release (not a build-recipe change). The classifier
  deliberately refuses to mislabel this as a full build — just re-run the job.
- **No matching release / first release:** classify falls back to **full**; expect ~15 min.
- **Stale-extras false pass:** the scrub step removes `lib/libetnp_ops_*.a`,
  `lib/cmake/ETNPExtras/`, `include/etnp/` before the rebuild — if you add op artifacts,
  extend the scrub list.
- **Toolchain/ABI mismatch:** the gate compiles inside manylinux_2_28 on purpose; do not
  run the extras rebuild on the host toolchain.
- **aarch64 runner:** tier1's aarch64 leg uses `ubuntu-24.04-arm` + the aarch64 manylinux
  image; the `.pte`/golden are arch-independent, so the same fixtures drive both arches.

## What a green gate does NOT prove
- AOT↔runtime drift on a **pure-kernel** PR (frozen `.pte`) — covered by the AOT path
  trigger and every release.
- Release packaging / license harvest / attestation — only the release build + full-build
  fallback exercise those.
- ET-version compatibility — an ET bump always takes the full-build fallback.
- A change to **`test_lstm_roundtrip.py` alone** classifies tier1 (a `test/` file that
  defines no fixtures), so the live round-trip is not re-run to validate the edited test
  itself. Low-risk (it is the harness, not shipped source or fixtures) — pair such edits
  with an AOT/kernel change, or run the round-trip locally.
````

- [ ] **Step 2: Sanity-check the doc renders / links**

Run: `python3 -c "p=open('docs/extras-gate.md').read(); assert 'consumer smoke MISMATCH' in p and '--extras-only' in p; print('doc ok')"`
Expected: `doc ok`

- [ ] **Step 3: Commit**

```bash
git add docs/extras-gate.md
git commit -m "docs(gate): usage & troubleshooting guide for the extras QA gate"
```

---

## Deferred / future work

- **Package-based imports instead of per-file `sys.path` bootstrap.** The current Import
  convention (Global Constraints) has each `extras/lstm/**/*.py` insert the repo root and
  import by full package path. A cleaner long-term structure is to make the test tree a
  real package and let Python's import machinery do the work: add `__init__.py` at the root
  of the test code directory (`extras/lstm/test/__init__.py`, plus the parent packages as
  needed), run the entry-point scripts via `python -m extras.lstm.aot.emit_fixtures` /
  `-m extras.lstm.test.consumer_smoke` instead of `python <path>.py`, and drop the per-file
  bootstrap. Deferred because it changes the workflow's script-invocation convention (Tasks
  6, 8 call `python extras/lstm/**.py` directly) and touches packaging; the per-file
  bootstrap ships the gate now with no packaging changes.
  - **Placement rule when we do this (repo preference):** any *shared, non-fixture* test
    helper (e.g. `_runner`) belongs in the test package — an `__init__.py` at the test-dir
    root or a submodule of it — **not** in `conftest.py`. `conftest.py` is reserved strictly
    for pytest **fixtures**; it is not a home for common code.
- **Hoist the intra-gate scrub + `--extras-only` block into a composite action.** The
  scrub (`rm libetnp_ops_*.a` + `cmake/ETNPExtras` + `include/etnp`) followed by `pip install
  ninja` + `build-runtime.sh --extras-only` is duplicated in the gate's `fast-gate` and
  `live-roundtrip` jobs (2×, gate-only). It could become a third composite action
  (`rebuild-extras-from-branch`, input `prefix`) to centralize the correctness-sensitive
  scrub list. Left inline now to avoid over-engineering (the two cross-workflow duplicates —
  ET checkout + round-trip — were the higher-value hoists done in Task 6); revisit if the
  scrub list changes or a third call site appears.

## Self-Review

**Spec coverage:**
- §1 trigger / three tiers → Tasks 7 (classify) + 8 (workflow). ✓ (`build-runtime.sh`→full rule in classify Step 3 (1); AOT→tier2 (3); default tier1 (4).)
- §2 Tier 1 fast gate (download+verify+scrub+extras-only+consumer smoke, both arches) → Tasks 2, 5, 8 (`fetch`+`fast-gate`). ✓ Attestation in `fetch`. ✓ Scrub list matches Global Constraints. ✓
- §3 published fixtures (arch-independent, attested, single-source) → Tasks 1, 3, 4, 6. ✓ Attest via release.yml's existing `dist/*.tar.gz` step.
- §4 Tier 2 live round-trip reusing downloaded prefix → Task 8 `live-roundtrip`. ✓
- §5 full-build release dry-run (build + round-trip + emit) → Task 8 `full-build`. ✓
- §6 documentation → Task 9. ✓ (mirrors the §6 checklist section-for-section.)
- §7 files list → all created: extras-gate.yml (T8), consumer harness (T5), fixture-emit (T4), release.yml change (T6), docs (T9). ✓ Plus the necessary `--extras-only` (T2), `lstm_case`/`_runner` (T3), `classify-gate.sh` (T7), `package-fixtures.sh`/naming (T1) the spec implied.
- Open items resolved: shape format = `LSTM_*=<n>` (T4); scrub list fixed (Global Constraints, T8). ✓
- Classification correctness: `lstm_case.py`/`emit_fixtures.py` live under `extras/lstm/aot/` (T3/T4) so the existing tier2 `aot/` rule catches fixture-defining changes — guarded by classify test cases (T7). Residual `test_lstm_roundtrip.py`-only edits documented as an accepted tier1 gap (T7 note, T9 docs). ✓
- `gh` robustness (T7/T8): download args built as a bash array (no `printf %q` injection); `gh release list` failure retried then surfaced as a non-zero classify (never a silent full build) — tested via `GATE_GH_CMD`/`GATE_RETRY_SLEEP`; `gh attestation verify` gated to same-repo PRs with sha256 mandatory everywhere, so fork PRs aren't blocked. ✓
- DRY across workflows (T6/T8): the ET checkout and the live round-trip — each duplicated 3× (release build + gate `live-roundtrip` + gate `full-build`) — are hoisted into the `checkout-executorch` and `lstm-roundtrip` composite actions (Task 6), consumed by both workflows. Task 8 declares the dependency on Task 6's actions. Intra-gate scrub+`--extras-only` duplicate left inline, recorded in Deferred / future work. ✓
- ET-pin read robustness (T2/T7): `classify-gate.sh` reads the pin via `build-runtime.sh --print-et-tag` (the shell that defines `DEFAULT_ET_TAG` reports it), replacing a brittle `sed` that silently yielded an empty tag on any non-`"…"` quoting. Covered by a `--print-et-tag` unit test (T2) and a real-derivation classify test (T7). Keeps the pin inside `build-runtime.sh`, preserving the "any change → full build" coupling. ✓

**Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N"; every code step shows full content. ✓

**Type/name consistency:** `build_case()` 4-tuple `(pte_bytes,in_bytes,golden_bytes,dims)` produced in T3, consumed identically in T4/T3-test; `parse_shape`/`within_tol` names match between T5 code and test; `shape_text` format `LSTM_T=5\n…` identical in T4 (producer) and T5/T7 (consumers) and the runner's `LSTM_*` env names (`lstm_runner.cpp:43-46`); `fixtures_name` used by T1 script and referenced by T6/T8 asset names; `classify-gate.sh` output keys `mode/etver/release_tag` consumed by T8 job outputs. ✓

---

## Execution Handoff

(Presented to the user after saving.)
