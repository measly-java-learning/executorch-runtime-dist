# Eigen License Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop shipping `lib/libeigen_blas.a` (MPL-2.0 Eigen) in release tarballs with no Eigen license text, and make a recurrence a hard build failure rather than a silent omission.

**Architecture:** The license passthrough currently lives inline in `build-runtime.sh`'s license phase and is unreachable by the hermetic test suite (it runs only after a full ET compile). Extract it into a new SSOT library `scripts/lib/licenses.sh` — matching the repo's existing `scripts/lib/*.sh` + `test/lib_*.test.sh` pattern — then fix the two gaps there (sweep root, filename glob) and add a presence-driven guard that refuses to finish a build when an archive with a notice obligation has no matching notice. `test/extras_members.sh` gets an independent assertion on the real built prefix, so the shipped bytes are checked in both the PR gate and the release job.

**Tech Stack:** Bash (`set -euo pipefail` in scripts, `set -u` in tests), the repo's dependency-free `test/assert.sh` harness, GitHub Actions (no workflow changes needed — `unit.yml` globs `test/*.test.sh`, and both `release.yml` and `extras-gate.yml` already invoke `test/extras_members.sh`).

**Spec:** GitHub issue [measly-java-learning/executorch-runtime-dist#45](https://github.com/measly-java-learning/executorch-runtime-dist/issues/45) — "Release tarballs ship libeigen_blas.a (MPL-2.0) with no Eigen license". Read it before starting; the plan argues from it.

**Repo:** All paths are relative to `/home/corey/workspace/executorch-runtime-dist` (NOT the `djl-executorch-engine` checkout this plan may have been written from).

## Global Constraints

- **Branch first.** `git switch -c fix/eigen-license-passthrough` off `main` before Task 1. Do not commit to `main`.
- **The hermetic suite must stay hermetic.** `test/run.sh` globs `test/*.test.sh` and CI runs it on every PR from a clean checkout. A check needing a built prefix must NOT be named `*.test.sh` (see the header comment in `test/extras_members.sh`).
- **Presence-driven, never platform-driven.** The Eigen guard keys off whether the archive is installed, not off `IS_WINDOWS`. Windows ships no `eigen_blas.lib` today only because `scripts/lib/configure-base.sh` omits `KERNELS_OPTIMIZED`; the day that changes the guard must already cover it with no edit. (Issue #45 "Scope note".)
- **Comments state what is, not what was.** No "previously", no "used to", no task/stage labels in shipped comments.
- **Tests assert behavior, not diff shape.** No greps for current wording of a comment or a specific notice filename that a future ET tag can move.
- **No new dependencies.** `find`, `cp`, `mkdir` only — the recipe runs inside the pinned manylinux image.
- **Notice filenames are path-derived** (`${rel//\//_}` relative to `$ET_SRC`) and must stay that way so two deps' `LICENSE` files cannot collide. Assertions therefore match `*eigen*`, never an exact vendoring path.
- ExecuTorch source tree for local verification: `~/workspace/executorch` (tag v1.3.1). The recipe's `DEFAULT_ET_TAG` is `v1.4.1`; if the Eigen vendoring path differs there, the guard is what tells you.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `scripts/lib/licenses.sh` | **create** | SSOT for the third-party notice sweep and the shipped-archive notice guard. Sourced by `build-runtime.sh`. |
| `test/lib_licenses.test.sh` | **create** | Hermetic unit test for both functions against synthesized source/prefix trees. |
| `build-runtime.sh` | modify (`:11-15` sources, `:312-325` license phase) | Source the new lib; call the two functions instead of the inline sweep. |
| `test/extras_members.sh` | modify (`:15-19`) | Independent assertion on the real built prefix that an Eigen notice shipped alongside `libeigen_blas.a`. |
| `README.md` | modify (~`:26-35`) | State the Eigen/MPL-2.0 obligation the tarball now discharges. |
| `docs/handover-to-engine.md` | modify (§6 Notes / gotchas) | Tell the consumer that whole-archiving `optimized_native_cpu_ops_lib` redistributes Eigen, so the notice has to travel into their `.so` distribution too. |

**Explicitly out of scope:** `install_highway_license()` stays where it is in `build-runtime.sh`. It is coupled to `EXTRAS_BUILD` and to the `--extras-only` early-exit path, it already hard-fails correctly, and moving it would enlarge a compliance fix into a refactor.

---

### Task 1: Notice sweep library — the two gaps

**Files:**
- Create: `scripts/lib/licenses.sh`
- Test: `test/lib_licenses.test.sh`

**Interfaces:**
- Consumes: nothing (leaf library).
- Produces:
  - `ET_NOTICE_ROOTS` — space-separated list of source-tree-relative dirs to sweep.
  - `install_third_party_notices <et_src> <prefix>` — copies every `LICENSE*`/`COPYING*` under those roots into `<prefix>/THIRD-PARTY-NOTICES/`, named `${path_relative_to_et_src//\//_}`. Returns 0; a missing root is skipped, not an error.

- [ ] **Step 1: Write the failing test**

Create `test/lib_licenses.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/licenses.sh"

has() { [ -f "$1" ] && printf 'yes' || printf 'no'; }

# A source tree shaped like ExecuTorch's: notices under the two long-swept roots, plus Eigen
# vendored under kernels/ where it names its files COPYING.* rather than LICENSE*.
src="$(mktemp -d)"; pfx="$(mktemp -d)"
mkdir -p "$src/third-party/xnnpack" "$src/third-party/gflags" \
         "$src/backends/xnnpack/third-party/FP16" \
         "$src/kernels/optimized/third-party/eigen"
: > "$src/third-party/xnnpack/LICENSE"
: > "$src/third-party/gflags/COPYING.txt"
: > "$src/backends/xnnpack/third-party/FP16/LICENSE"
: > "$src/kernels/optimized/third-party/eigen/LICENSE"
: > "$src/kernels/optimized/third-party/eigen/COPYING.MPL2"
: > "$src/kernels/optimized/third-party/eigen/COPYING.README"

install_third_party_notices "$src" "$pfx"
n="$pfx/THIRD-PARTY-NOTICES"

# The roots that already worked must keep working.
assert_eq "$(has "$n/third-party_xnnpack_LICENSE")" "yes" "third-party root still swept"
assert_eq "$(has "$n/backends_xnnpack_third-party_FP16_LICENSE")" "yes" "backends root still swept"

# Gap 1: the Eigen vendoring root is under neither of those.
assert_eq "$(has "$n/kernels_optimized_third-party_eigen_LICENSE")" "yes" "eigen root swept"
# Gap 2: Eigen's per-component notices are named COPYING.*, and COPYING.README is the file that
# states which parts are MPL-2.0 and which are BSD/MINPACK/Apache.
assert_eq "$(has "$n/kernels_optimized_third-party_eigen_COPYING.MPL2")" "yes" "COPYING glob matches"
assert_eq "$(has "$n/kernels_optimized_third-party_eigen_COPYING.README")" "yes" "COPYING.README shipped"
assert_eq "$(has "$n/third-party_gflags_COPYING.txt")" "yes" "COPYING glob applies to every root"

# Names are path-derived, so two deps' LICENSE files cannot overwrite each other.
assert_eq "$(ls "$n" | wc -l)" "6" "every notice landed under a distinct name"

# A root a future ET tag drops is skipped, not fatal.
src2="$(mktemp -d)"; pfx2="$(mktemp -d)"
mkdir -p "$src2/third-party/only/here"; : > "$src2/third-party/only/here/LICENSE"
install_third_party_notices "$src2" "$pfx2"; rc=$?
assert_eq "$rc" "0" "absent roots are skipped, not an error"
assert_eq "$(has "$pfx2/THIRD-PARTY-NOTICES/third-party_only_here_LICENSE")" "yes" "sweep continued past the absent roots"

rm -rf "$src" "$pfx" "$src2" "$pfx2"
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/corey/workspace/executorch-runtime-dist
bash test/lib_licenses.test.sh
```

Expected: FAIL — `scripts/lib/licenses.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/licenses.sh`:

```bash
#!/usr/bin/env bash
# Third-party license passthrough into a built prefix's THIRD-PARTY-NOTICES/ (contract C2).
# Single source of truth: build-runtime.sh sources this rather than inlining a find/cp loop, so the
# sweep is reachable by the hermetic unit suite without a 15-minute ExecuTorch compile.
# Source me.

# ExecuTorch source dirs swept for notice files. `kernels` is here because Eigen is vendored at
# kernels/optimized/third-party/eigen and libeigen_blas.a ships in every Linux tarball; the whole
# kernels subtree is swept rather than that one path so a dep vendored elsewhere under it is caught
# too.
ET_NOTICE_ROOTS='third-party backends kernels'

# Copy every LICENSE*/COPYING* under ET_NOTICE_ROOTS into <prefix>/THIRD-PARTY-NOTICES/, named by
# its path relative to the source tree with slashes turned into underscores, so two deps' LICENSE
# files cannot collide. COPYING* is swept alongside LICENSE* because Eigen carries its notices as
# COPYING.APACHE/BSD/MINPACK/MPL2/README, and COPYING.README is the file that says which portions
# are under which license.
install_third_party_notices() { # <et_src> <prefix>
  local et_src="$1" prefix="$2" d
  mkdir -p "$prefix/THIRD-PARTY-NOTICES"
  for d in $ET_NOTICE_ROOTS; do
    # guard each dir (a future ET tag may drop/rename one) so a bare `find | while` can't abort the
    # recipe under set -e/pipefail with its stderr masked; `|| true` covers any residual find failure.
    [ -d "$et_src/$d" ] || continue
    find "$et_src/$d" \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -type f | while read -r lf; do
      rel="${lf#"$et_src"/}"
      cp "$lf" "$prefix/THIRD-PARTY-NOTICES/${rel//\//_}"
    done || true
  done
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash test/lib_licenses.test.sh
```

Expected: every line `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/licenses.sh test/lib_licenses.test.sh
git commit -m "fix: sweep the Eigen vendoring root and COPYING* for notices (#45)"
```

---

### Task 2: Refuse to finish a build that installs an unlicensed archive

**Files:**
- Modify: `scripts/lib/licenses.sh` (append)
- Test: `test/lib_licenses.test.sh` (append)

**Interfaces:**
- Consumes: nothing from Task 1 at runtime; lives in the same file.
- Produces: `assert_shipped_archive_notices <prefix>` — returns 0 when every archive with a notice obligation has a matching notice in `<prefix>/THIRD-PARTY-NOTICES/`, returns 1 (after writing a diagnostic to stderr naming the archive) otherwise. Under `set -e` in `build-runtime.sh` a bare call aborts the recipe.

- [ ] **Step 1: Write the failing test**

Append to `test/lib_licenses.test.sh`, immediately before the final `exit "$ASSERT_FAILS"`:

```bash
# --- shipped-archive notice guard ---
# A silent `find` that matches nothing is exactly how the Eigen gap survived 36 notices and several
# releases, so the sweep landing nothing must fail the build rather than pass quietly.
mkprefix() { # <archive-or-empty> <notice-or-empty>  -> echoes the prefix path
  local p; p="$(mktemp -d)"; mkdir -p "$p/lib" "$p/THIRD-PARTY-NOTICES"
  [ -n "$1" ] && : > "$p/lib/$1"
  [ -n "$2" ] && : > "$p/THIRD-PARTY-NOTICES/$2"
  printf '%s' "$p"
}
guard() { assert_shipped_archive_notices "$1" >/dev/null 2>&1 && printf 'pass' || printf 'fail'; }

p_bad="$(mkprefix libeigen_blas.a '')"
assert_eq "$(guard "$p_bad")" "fail" "eigen archive with no notice is refused"

p_ok="$(mkprefix libeigen_blas.a kernels_optimized_third-party_eigen_COPYING.MPL2)"
assert_eq "$(guard "$p_ok")" "pass" "eigen archive with its notice is accepted"

# The notice name is path-derived, so the guard matches the dep, not a path a future tag can move.
p_moved="$(mkprefix libeigen_blas.a some_other_vendoring_path_eigen_LICENSE)"
assert_eq "$(guard "$p_moved")" "pass" "guard matches the dep, not one hard-coded notice path"

# No archive installed -> no obligation. This is what keeps the guard silent on Windows today
# without a platform test in it.
p_none="$(mkprefix '' '')"
assert_eq "$(guard "$p_none")" "pass" "no archive, no obligation"

# The Windows spelling of the same archive carries the same obligation, so enabling the optimized
# kernels on Windows cannot reintroduce the gap.
p_win="$(mkprefix eigen_blas.lib '')"
assert_eq "$(guard "$p_win")" "fail" "windows eigen_blas.lib with no notice is refused"

# The diagnostic has to name the archive; "refusing to ship" with no subject is not actionable.
msg="$(assert_shipped_archive_notices "$p_bad" 2>&1 >/dev/null || true)"
assert_contains "$msg" "libeigen_blas.a" "diagnostic names the offending archive"

rm -rf "$p_bad" "$p_ok" "$p_moved" "$p_none" "$p_win"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash test/lib_licenses.test.sh
```

Expected: FAIL — `assert_shipped_archive_notices: command not found` on the guard lines (the Task 1 assertions still pass).

- [ ] **Step 3: Write the implementation**

Append to `scripts/lib/licenses.sh`:

```bash
# Archives that carry a notice obligation, as <archive-basename>|<notice-substring>. Keyed off what
# is installed, never off the platform: Windows ships no eigen_blas.lib today only because
# configure-base.sh omits KERNELS_OPTIMIZED, and the day it does not, this covers it unchanged.
# libeigen_blas.a is MPL-2.0 Eigen, reached through optimized_kernels -> cpublas -> eigen_blas, which
# is the chain behind optimized_native_cpu_ops_lib — the ops lib consumers are told to whole-archive.
_ET_LICENSED_ARCHIVES='libeigen_blas.a|eigen eigen_blas.lib|eigen'

# Fail when an archive above is installed and the sweep landed no matching notice. The whole point
# is that a `find` matching nothing is loud: without this, a moved upstream vendoring path silently
# produces an unlicensed tarball, which is what issue #45 was.
assert_shipped_archive_notices() { # <prefix>
  local prefix="$1" entry archive needle fail=0
  for entry in $_ET_LICENSED_ARCHIVES; do
    archive="${entry%%|*}"; needle="${entry##*|}"
    [ -f "$prefix/lib/$archive" ] || continue
    if [ -z "$(find "$prefix/THIRD-PARTY-NOTICES" -maxdepth 1 -type f -iname "*$needle*" 2>/dev/null | head -n1)" ]; then
      echo ">> ERROR: lib/$archive is installed but no *$needle* notice landed in" >&2
      echo "   $prefix/THIRD-PARTY-NOTICES/ — refusing to ship it without its license." >&2
      echo "   The upstream vendoring path likely moved. Locate it with:" >&2
      echo "     find \$ET_SRC -ipath '*$needle*' \\( -iname 'LICENSE*' -o -iname 'COPYING*' \\)" >&2
      echo "   then add its root to ET_NOTICE_ROOTS in scripts/lib/licenses.sh." >&2
      fail=1
    fi
  done
  [ "$fail" -eq 0 ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash test/lib_licenses.test.sh && bash test/run.sh
```

Expected: `test/lib_licenses.test.sh` all `ok:`, and `ALL UNIT TESTS PASS` from the suite.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/licenses.sh test/lib_licenses.test.sh
git commit -m "fix: hard-fail a build that installs libeigen_blas.a with no Eigen notice (#45)"
```

---

### Task 3: Wire the recipe to the library

**Files:**
- Modify: `build-runtime.sh` — the source block at `:11-15`, and the license phase at `:312-325`

**Interfaces:**
- Consumes: `install_third_party_notices <et_src> <prefix>` and `assert_shipped_archive_notices <prefix>` from Tasks 1-2.
- Produces: nothing new. `install_highway_license` is untouched.

- [ ] **Step 1: Source the library**

In `build-runtime.sh`, add to the existing source block (after `configure-base.sh`, line ~15):

```bash
. "$HERE/scripts/lib/licenses.sh"
```

- [ ] **Step 2: Replace the inline sweep**

Replace `build-runtime.sh:312-325` — from `echo ">> license passthrough"` through the `install_highway_license` line — with:

```bash
echo ">> license passthrough"
install -m 0644 "$ET_SRC/LICENSE" "$PREFIX/LICENSE"
install_third_party_notices "$ET_SRC" "$PREFIX"

if [ "$IS_WINDOWS" -eq 0 ]; then install_highway_license; fi

# Every installed archive with a notice obligation must have its notice in the tree. Not gated on
# IS_WINDOWS: the guard keys off what got installed, so it follows the optimized kernels wherever
# they are enabled.
assert_shipped_archive_notices "$PREFIX"
```

- [ ] **Step 3: Verify the script still parses and the CLI paths are intact**

```bash
bash -n build-runtime.sh
bash test/build_cli.test.sh
./build-runtime.sh --print-flags --variant logging | head -c 120; echo
```

Expected: no syntax error; `build_cli.test.sh` all `ok:`; the flag line prints as before. (`--print-flags` exits before the license phase — this proves sourcing the new lib did not disturb it.)

- [ ] **Step 4: Exercise the real license phase end to end**

The license phase runs only after a full ET compile, so drive its two functions directly against the real ExecuTorch checkout and a copy of an existing built prefix. This is a genuine end-to-end check — real source tree, real prefix containing `lib/libeigen_blas.a`:

```bash
cd /home/corey/workspace/executorch-runtime-dist
rm -rf /tmp/eigen-check-prefix
cp -a out-logging /tmp/eigen-check-prefix
# Baseline: the prefix as shipped today has the archive and no Eigen notice -> must be refused.
bash -c '. scripts/lib/licenses.sh; assert_shipped_archive_notices /tmp/eigen-check-prefix'; echo "rc=$?"
```

Expected: the diagnostic naming `lib/libeigen_blas.a`, `rc=1`.

```bash
bash -c '. scripts/lib/licenses.sh
         install_third_party_notices "$HOME/workspace/executorch" /tmp/eigen-check-prefix
         assert_shipped_archive_notices /tmp/eigen-check-prefix'; echo "rc=$?"
ls /tmp/eigen-check-prefix/THIRD-PARTY-NOTICES | grep -i eigen
```

Expected: `rc=0`, and the listing shows `kernels_optimized_third-party_eigen_COPYING.APACHE`, `..._COPYING.BSD`, `..._COPYING.MINPACK`, `..._COPYING.MPL2`, `..._COPYING.README`, `..._LICENSE`.

If the guard still fails here, the vendoring path moved in the ET tag you swept — run the `find` the diagnostic prints and add the new root to `ET_NOTICE_ROOTS`, then re-run this step.

- [ ] **Step 5: Commit**

```bash
git add build-runtime.sh
git commit -m "fix: route the recipe's license phase through scripts/lib/licenses.sh (#45)"
```

---

### Task 4: Assert it on the shipped bytes, and say so in the docs

**Files:**
- Modify: `test/extras_members.sh:15-19`
- Modify: `README.md` (the tarball-layout section, ~`:26-35`)
- Modify: `docs/handover-to-engine.md` (§6 Notes / gotchas)

**Interfaces:**
- Consumes: a built prefix at `$PREFIX` (default `out-logging`). Deliberately does NOT source `scripts/lib/licenses.sh` — an independent assertion catches a bug in the guard's own matcher, which reusing it could not.
- Produces: nothing consumed by later tasks. This is the last check before attestation in `release.yml` and the post-build check in `extras-gate.yml`; both already invoke this script, so no workflow edits.

- [ ] **Step 1: Add the failing assertion**

In `test/extras_members.sh`, after the `for m in ... done` member loop and before the op-name `grep`, insert:

```bash
# libeigen_blas.a is MPL-2.0 Eigen and ships in every Linux tarball that builds the optimized
# kernels. Its notice is named after the upstream vendoring path, so match the dep rather than a
# path a future ET tag can move. Presence-driven, so a prefix without the archive is silent.
if [ -f "$PREFIX/lib/libeigen_blas.a" ] && \
   [ -z "$(find "$PREFIX/THIRD-PARTY-NOTICES" -maxdepth 1 -type f -iname '*eigen*' 2>/dev/null | head -n1)" ]; then
  echo "MISSING: THIRD-PARTY-NOTICES entry for libeigen_blas.a (Eigen, MPL-2.0)"; fail=1
fi
```

- [ ] **Step 2: Run it against the unfixed prefix to verify it fails**

```bash
cd /home/corey/workspace/executorch-runtime-dist
PREFIX="$PWD/out-logging" bash test/extras_members.sh; echo "rc=$?"
```

Expected: `MISSING: THIRD-PARTY-NOTICES entry for libeigen_blas.a (Eigen, MPL-2.0)`, `rc=1`. (This prefix was built before the fix — it is the exact artifact issue #45 reports.)

- [ ] **Step 3: Run it against the repaired prefix to verify it passes**

```bash
PREFIX=/tmp/eigen-check-prefix bash test/extras_members.sh; echo "rc=$?"
```

Expected: `OK: extras members present + relocatable`, `rc=0`. (That prefix got its notices in Task 3 Step 4; if it is gone, re-run that step.)

- [ ] **Step 4: State the obligation in README.md**

In `README.md`, directly under the tarball-layout code fence, add:

```markdown
`THIRD-PARTY-NOTICES/` carries the license files of everything statically linked into `lib/`,
including **Eigen (MPL-2.0)** behind `libeigen_blas.a`. The build refuses to finish if an archive
with a notice obligation has no matching notice.
```

- [ ] **Step 5: Warn the consumer in docs/handover-to-engine.md**

In §6 "Notes / gotchas", immediately after the whole-archive bullet, add:

```markdown
- **Whole-archiving `optimized_native_cpu_ops_lib` redistributes Eigen.** It reaches
  `libeigen_blas.a` through `optimized_kernels -> cpublas -> eigen_blas`, so the resulting
  `.so` contains MPL-2.0 code. MPL-2.0 §3.2/§3.3 make that a notice obligation on *your*
  distribution, not just on this tarball: pass `THIRD-PARTY-NOTICES/kernels_optimized_third-party_eigen_*`
  through to whatever you ship.
```

- [ ] **Step 6: Full green**

```bash
bash test/run.sh
bash -n build-runtime.sh
PREFIX=/tmp/eigen-check-prefix bash test/extras_members.sh
```

Expected: `ALL UNIT TESTS PASS`; no syntax error; `OK: extras members present + relocatable`.

- [ ] **Step 7: Commit**

```bash
git add test/extras_members.sh README.md docs/handover-to-engine.md
git commit -m "test: pin the Eigen notice on the shipped prefix; document the obligation (#45)"
```

---

### Task 5: Prove it on a real build, then open the PR

**Files:** none (verification + integration).

- [ ] **Step 1: Confirm the local checkout is clean and the suite is green**

```bash
cd /home/corey/workspace/executorch-runtime-dist
git status --short
bash test/run.sh
```

Expected: only intended files changed (or nothing, post-commit); `ALL UNIT TESTS PASS`.

- [ ] **Step 2: Rebuild one variant in the pinned container**

This is the only thing that proves the recipe's own license phase, as opposed to its two extracted functions. It is a long build; run it once, on `logging`, against the ET tag the recipe defaults to.

```bash
docker run --rm -v "$PWD":/work -v "$HOME/workspace/executorch":/executorch \
  -w /work "$(cat .build-image)" \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant logging --prefix /work/out-eigen --et-src /executorch'
```

Expected: the build reaches `>> build-runtime.sh done: /work/out-eigen` with no license error.

```bash
ls out-eigen/THIRD-PARTY-NOTICES | grep -ci eigen
PREFIX="$PWD/out-eigen" bash test/extras_members.sh
```

Expected: a non-zero count; `OK: extras members present + relocatable`.

If the ET checkout is v1.3.1 while `--print-et-tag` reports v1.4.1, either pass `--et-src` a v1.4.1 tree or note in the PR body which tag the build was proven against — the guard is what protects the tag you did not build.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin fix/eigen-license-passthrough
gh pr create --title "fix: ship Eigen's license with libeigen_blas.a (#45)" --body "$(cat <<'EOF'
Fixes #45.

## The bug

Every Linux tarball ships `lib/libeigen_blas.a` — MPL-2.0 Eigen — with no Eigen notice among the 36
entries in `THIRD-PARTY-NOTICES/`. Two independent gaps in the passthrough, both required to hit it:
the sweep covered `third-party/` and `backends/` but Eigen is vendored at
`kernels/optimized/third-party/eigen`, and the glob matched `LICENSE*` while Eigen names its
per-component notices `COPYING.*`.

## The fix

- `scripts/lib/licenses.sh` (new) is the SSOT for the sweep, so the logic is reachable by the
  hermetic suite instead of only after a 15-minute ExecuTorch compile. `kernels` joins the swept
  roots and `COPYING*` joins the glob — which also picks up `third-party/gflags/COPYING.txt`, a
  smaller instance of the same gap.
- `assert_shipped_archive_notices` follows the Highway precedent and hard-fails the build when an
  archive with a notice obligation has no matching notice. It keys off what is installed, never off
  the platform, so enabling the optimized kernels on Windows cannot reintroduce the gap.
- `test/extras_members.sh` asserts it on the real built prefix — the last check before attestation.

## Tests

- `test/lib_licenses.test.sh` (new, hermetic): both gaps, name collisions, absent roots, and the
  guard's four states plus its Windows spelling.
- `test/extras_members.sh` verified red against the pre-fix `out-logging` prefix and green after.
EOF
)"
```

- [ ] **Step 4: Confirm CI**

```bash
gh pr checks --watch
```

Expected: `unit.yml` green (the new hermetic test runs there), and the extras gate's post-build `extras_members.sh` step green against a freshly built prefix.
