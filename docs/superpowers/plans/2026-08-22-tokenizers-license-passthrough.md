# Tokenizers Dependency Stack License Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop shipping the 96-archive `extension/llm/tokenizers` dependency stack (abseil, sentencepiece, re2, pcre2, tokenizers) plus FFHT with no license text, and make a recurrence a hard build failure.

**Architecture:** Issue #45 built the machinery this plan reuses: `scripts/lib/licenses.sh` holds the notice sweep (`ET_NOTICE_ROOTS`, `ET_NOTICE_PRUNE_DIRS`, `install_third_party_notices`) and the presence-driven guard (`_ET_LICENSED_ARCHIVES`, `assert_shipped_archive_notices`), with a hermetic test at `test/lib_licenses.test.sh` and a shipped-prefix assertion in `test/extras_members.sh`. This plan adds one sweep root, one prune entry, five guard entries, and the matching assertions. No new files, no new mechanism.

**Tech Stack:** Bash (`set -euo pipefail` in scripts, `set -u` in tests), the repo's dependency-free `test/assert.sh` harness. No workflow changes — `unit.yml` globs `test/*.test.sh`, and `release.yml` and `extras-gate.yml` already run `test/extras_members.sh`.

**Spec:** GitHub issue [measly-java-learning/executorch-runtime-dist#52](https://github.com/measly-java-learning/executorch-runtime-dist/issues/52). Read it before starting. Every open question its "The trap" section raises has since been measured; the answers are in Global Constraints below and are binding — do not re-litigate them, but do re-verify any you are about to depend on.

## Global Constraints

- **Prerequisite: satisfied.** PR #51 is merged (squashed to `b1d7600` on `main`), so `scripts/lib/licenses.sh`, `ET_NOTICE_PRUNE_DIRS`, `_ET_LICENSED_ARCHIVES`, and the README paragraph Task 1 edits are all on `main`. Start from a clean `main` and branch: `git switch main && git pull && git switch -c fix/tokenizers-license-passthrough`.
- **Measured facts — these are settled, treat them as given:**
  - Adding `extension` to `ET_NOTICE_ROOTS` takes the sweep from **42 → 57** notices against the ExecuTorch tree at `$HOME/workspace/executorch`.
  - Exactly **one** of those 15 additions must be excluded: `extension/llm/tokenizers/build/temp.linux-x86_64-cpython-312/…/_deps/pybind11-src/LICENSE`. It is **untracked build residue**, so it exists in a checkout that has been built in and not in a clean CI checkout — a nondeterministic notice set. Pruning directories named `build` removes it. **Target count: 56.**
  - No notice in the current 42 comes from a path containing `build/`, so that prune drops nothing.
  - The other 14 additions all stay. Verified against the shipped archives: protobuf-lite and sentencepiece's vendored absl compile into `libsentencepiece.a` (`google::protobuf` and `absl::internal` symbols present); `darts_clone` and `esaxx` are header-only (`darts.h`, `esa.hxx`, `sais.hxx`) and compile in the same way; pcre2's `deps/sljit` is compiled in (11 JIT symbols in `libpcre2-8.a`); nlohmann json is in `libtokenizers.a` (471 symbols); FFHT is in the shipped `lib/` (5 symbols). `pcre2/cmake/COPYING-CMAKE-SCRIPTS` is kept — it is a permissive notice, and pruning `cmake` directories would risk dropping real ones.
  - **Linux-only.** The published `v1.3.1-10` Windows tarball ships 0 of these archives (the Windows configure base sets no LLM-extension flag). The guard is presence-driven, so this needs no platform branch.
- **Presence-driven, never platform-driven.** Guard entries key off whether the archive is installed.
- **Notice filenames are path-derived** (`${rel//\//_}` relative to `$ET_SRC`). Guard needles and test assertions match a **`<dep>_<noticefile>` tail**, never a full path — the tail survives a vendoring-path move, which is the sensitivity we want.
- **The `re2` / `pcre2` needle collision is real.** A needle of `re2` matches `..._pcre2_COPYING`, so a missing re2 notice would pass the guard whenever pcre2's is present. Use `_re2_LICENSE`. Verified: it matches `extension_llm_tokenizers_third-party_re2_LICENSE` and does not match `extension_llm_tokenizers_third-party_pcre2_COPYING`.
- **No new dependencies:** `find`, `cp`, `mkdir` only.
- **Comments state what is, not what was.** No history, no task labels.
- **Tests assert behavior, not diff shape.**
- `test/extras_members.sh` stays out of `test/run.sh`'s hermetic glob — it needs a built prefix.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01XUbfzoAtfTWRFodP6JUYK6`

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `README.md` | modify | Drive-by: drop the PR-#51 summary sentence. Unrelated to #52. |
| `scripts/lib/licenses.sh` | modify | Add the `extension` root, the `build` prune, and five `_ET_LICENSED_ARCHIVES` entries. |
| `test/lib_licenses.test.sh` | modify | Hermetic coverage for the new root, the prune, and the new guard entries. |
| `test/extras_members.sh` | modify | Shipped-prefix assertion for the new archives. |

---

### Task 1: Drive-by — remove the PR summary from README.md

Unrelated to issue #52. It is here because the text lands in the same file area and the user asked for it as a drive-by.

**Files:**
- Modify: `README.md` (the `THIRD-PARTY-NOTICES/` paragraph under the tarball-layout fence)

- [ ] **Step 1: Read the paragraph**

```bash
cd /home/corey/workspace/executorch-runtime-dist
sed -n '17,32p' README.md
```

The paragraph currently reads (two sentences):

```
`THIRD-PARTY-NOTICES/` carries the license files of everything statically linked into `lib/`,
including **Eigen (MPL-2.0)** behind `libeigen_blas.a`. The build refuses to finish if it installs
`libeigen_blas.a` (or its Windows spelling) with no matching Eigen notice alongside it.
```

- [ ] **Step 2: Cut the second sentence**

Keep the first sentence, delete the second. The result is exactly:

```
`THIRD-PARTY-NOTICES/` carries the license files of everything statically linked into `lib/`,
including **Eigen (MPL-2.0)** behind `libeigen_blas.a`.
```

The first sentence is a durable fact about what the tarball contains. The second narrates one release's enforcement mechanism into a reference document: it singles out whichever archive the current change happened to touch, and it goes stale as `_ET_LICENSED_ARCHIVES` grows — which **this plan grows in Task 2**. The guard is documented where it lives, in `scripts/lib/licenses.sh`.

Do not add a replacement sentence about the guard, and do not extend the Eigen mention to the tokenizers stack.

- [ ] **Step 3: Verify nothing else moved**

```bash
git diff --stat README.md
```

Expected: `1 file changed, 1 insertion(+), 3 deletions(-)` or similar — a single paragraph edit, no other hunks.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: keep the notices paragraph to the tarball fact"
```

---

### Task 2: Sweep the extension root; prune build residue

**Files:**
- Modify: `scripts/lib/licenses.sh` (`ET_NOTICE_ROOTS`, `ET_NOTICE_PRUNE_DIRS`)
- Test: `test/lib_licenses.test.sh`

**Interfaces:**
- Consumes: `install_third_party_notices <et_src> <prefix>`, unchanged in signature.
- Produces: no new identifiers. `ET_NOTICE_ROOTS` gains `extension`; `ET_NOTICE_PRUNE_DIRS` gains `build`.

- [ ] **Step 1: Write the failing test**

In `test/lib_licenses.test.sh`, extend the **first** block's fake source tree (the one that builds `$src`) with the two new shapes, placing these lines beside the existing `mkdir -p`/`: >` fixture lines:

```bash
mkdir -p "$src/extension/llm/tokenizers/third-party/re2" \
         "$src/extension/llm/tokenizers/build/temp.linux-x86_64-cpython-312/_deps/pybind11-src"
: > "$src/extension/llm/tokenizers/third-party/re2/LICENSE"
: > "$src/extension/llm/tokenizers/build/temp.linux-x86_64-cpython-312/_deps/pybind11-src/LICENSE"
```

Then add these assertions next to the existing ones, and raise the existing exact-count assertion from `6` to `7` (the re2 notice lands; the pybind11 one must not):

```bash
# The tokenizers dependency stack is vendored under extension/, outside the roots the sweep
# covered for third-party and backends.
assert_eq "$(has "$n/extension_llm_tokenizers_third-party_re2_LICENSE")" "yes" "extension root swept"
# A tokenizers build tree is untracked output: present in a checkout that has been built in,
# absent in a clean CI checkout. Sweeping it would make the notice set depend on that.
assert_eq "$(has "$n/extension_llm_tokenizers_build_temp.linux-x86_64-cpython-312__deps_pybind11-src_LICENSE")" \
  "no" "build residue is pruned"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash test/lib_licenses.test.sh
```

Expected: FAIL on `extension root swept` (`no`, want `yes`), on `build residue is pruned` (`yes`, want `no`), and on the count assertion.

- [ ] **Step 3: Implement**

In `scripts/lib/licenses.sh`, add `extension` to the roots and `build` to the prune list:

```bash
ET_NOTICE_ROOTS='third-party backends kernels extension'
```

```bash
ET_NOTICE_PRUNE_DIRS='bench build'
```

Update both variables' comments so they state the present rule for the full list — `bench` because Eigen's benchmark tree is not compiled into the shipped `lib/` and its GPLv2 notice would claim an obligation the artifact does not carry; `build` because a vendored dep's build tree is untracked output, so sweeping it makes the notice set depend on whether the checkout was built in. Keep the comments describing what the rule is, not which change added which entry.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash test/lib_licenses.test.sh && bash test/run.sh
```

Expected: all `ok:`, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Verify against the real tree**

```bash
bash -c '. scripts/lib/licenses.sh
         P=/tmp/tok-sweep; rm -rf $P; mkdir -p $P
         install_third_party_notices "$HOME/workspace/executorch" $P
         echo "count=$(ls $P/THIRD-PARTY-NOTICES | wc -l)"
         ls $P/THIRD-PARTY-NOTICES | grep -c pybind11 || echo "pybind11: absent (correct)"
         ls $P/THIRD-PARTY-NOTICES | grep -E "abseil|sentencepiece|_re2_|pcre2|tokenizers_LICENSE|FFHT"'
```

Expected: `count=56`; pybind11 absent; the abseil, sentencepiece (and its four vendored notices), re2, pcre2 (and `sljit`, `COPYING-CMAKE-SCRIPTS`), tokenizers, json, and FFHT entries all listed.

If the count is 57, the `build` prune did not take effect. If it is 42, the root did not.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/licenses.sh test/lib_licenses.test.sh
git commit -m "fix: sweep the extension vendoring root for notices (#52)"
```

---

### Task 3: Guard the tokenizer-stack archives

**Files:**
- Modify: `scripts/lib/licenses.sh` (`_ET_LICENSED_ARCHIVES`)
- Test: `test/lib_licenses.test.sh`

**Interfaces:**
- Consumes: `assert_shipped_archive_notices <prefix>` and the `mkprefix`/`guard` helpers already defined in the test's guard block.
- Produces: no new identifiers. `_ET_LICENSED_ARCHIVES` gains five `<archive>|<needle>` pairs.

- [ ] **Step 1: Write the failing test**

Append to the guard block in `test/lib_licenses.test.sh`, before the final `exit "$ASSERT_FAILS"`:

```bash
# --- tokenizer stack ---
# One representative archive per dependency: if the dep is built at all, this archive is present.
for pair in "libabsl_base.a:extension_llm_tokenizers_third-party_abseil-cpp_LICENSE" \
            "libsentencepiece.a:extension_llm_tokenizers_third-party_sentencepiece_LICENSE" \
            "libre2.a:extension_llm_tokenizers_third-party_re2_LICENSE" \
            "libpcre2-8.a:extension_llm_tokenizers_third-party_pcre2_COPYING" \
            "libtokenizers.a:extension_llm_tokenizers_LICENSE"; do
  arch="${pair%%:*}"; note="${pair##*:}"
  p_no="$(mkprefix "$arch" '')"
  assert_eq "$(guard "$p_no")" "fail" "$arch with no notice is refused"
  p_yes="$(mkprefix "$arch" "$note")"
  assert_eq "$(guard "$p_yes")" "pass" "$arch with its notice is accepted"
  rm -rf "$p_no" "$p_yes"
done

# pcre2's notice must not satisfy re2's obligation. Both dep names end in "re2", so a needle of
# "re2" alone passes a prefix that ships libre2.a with only the pcre2 notice.
p_collide="$(mkprefix libre2.a extension_llm_tokenizers_third-party_pcre2_COPYING)"
assert_eq "$(guard "$p_collide")" "fail" "the pcre2 notice does not satisfy libre2.a"
rm -rf "$p_collide"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash test/lib_licenses.test.sh
```

Expected: every `... with no notice is refused` assertion FAILS with `pass` (the archives are not in the list yet, so the guard skips them), and the collision assertion FAILS the same way.

- [ ] **Step 3: Implement**

In `scripts/lib/licenses.sh`, extend `_ET_LICENSED_ARCHIVES`:

```bash
_ET_LICENSED_ARCHIVES='libeigen_blas.a|eigen eigen_blas.lib|eigen
libabsl_base.a|abseil-cpp_LICENSE
libsentencepiece.a|sentencepiece_LICENSE
libre2.a|_re2_LICENSE
libpcre2-8.a|pcre2_COPYING
libtokenizers.a|tokenizers_LICENSE'
```

Keep whatever quoting and whitespace style the existing single-line value uses — the loop splits on whitespace, so newlines and spaces are equivalent; pick whichever reads better and stays one entry per dependency.

Add a comment above the new entries stating two things: that each needle is a `<dep>_<noticefile>` tail rather than a full path, so it survives a vendoring-path move; and that `libre2.a` uses `_re2_LICENSE` specifically because a bare `re2` also matches the pcre2 notice, which would let a missing re2 notice pass whenever pcre2's is present.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash test/lib_licenses.test.sh && bash test/run.sh
```

Expected: all `ok:`, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Verify the guard passes on a real swept prefix**

```bash
rm -rf /tmp/tok-guard && cp -a out-eigen /tmp/tok-guard 2>/dev/null || cp -a out-logging /tmp/tok-guard
bash -c '. scripts/lib/licenses.sh
         install_third_party_notices "$HOME/workspace/executorch" /tmp/tok-guard
         assert_shipped_archive_notices /tmp/tok-guard'; echo "rc=$?"
```

Expected: `rc=0`. A non-zero rc names the archive whose notice did not land — that is a real gap, not a test to adjust.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/licenses.sh test/lib_licenses.test.sh
git commit -m "fix: hard-fail a build shipping the tokenizer stack unlicensed (#52)"
```

---

### Task 4: Assert it on the shipped bytes

**Files:**
- Modify: `test/extras_members.sh`

**Interfaces:**
- Consumes: a built prefix at `$PREFIX` (default `out-logging`). Deliberately does **not** source `scripts/lib/licenses.sh` — an independent assertion catches a bug in the guard's own matcher, which reusing it could not. This mirrors the existing Eigen assertion directly above it.

- [ ] **Step 1: Add the assertion**

In `test/extras_members.sh`, immediately after the existing `libeigen_blas.a` block, add:

```bash
# The extension/llm/tokenizers stack ships ~96 archives on Linux. One representative archive per
# dependency: if the dep is built at all, this archive is present. Matched by dependency rather
# than by the path-derived notice filename, which a future ExecuTorch tag can move. Presence-driven,
# so a prefix built without these (every Windows tarball) stays silent.
for pair in "libabsl_base.a:abseil" "libsentencepiece.a:sentencepiece" \
            "libre2.a:_re2_LICENSE" "libpcre2-8.a:pcre2" "libtokenizers.a:tokenizers_LICENSE"; do
  arch="${pair%%:*}"; note="${pair##*:}"
  if [ -f "$PREFIX/lib/$arch" ] && \
     [ -z "$(find "$PREFIX/THIRD-PARTY-NOTICES" -maxdepth 1 -type f -iname "*$note*" 2>/dev/null | head -n1)" ]; then
    echo "MISSING: THIRD-PARTY-NOTICES entry for $arch"; fail=1
  fi
done
```

The needles here are deliberately *not* the same strings as `_ET_LICENSED_ARCHIVES`' — `abseil` and
`pcre2` rather than `abseil-cpp_LICENSE` and `pcre2_COPYING`. That is the independence this
assertion exists for: matching the same way the guard matches would let one bad matcher pass both.
`libre2.a` is the exception and keeps `_re2_LICENSE`, because there the loose form is not merely
redundant but wrong — it matches the pcre2 notice. Do not "align" these with Task 3's list.

- [ ] **Step 2: Run against an unswept prefix to verify it fails**

```bash
PREFIX="$PWD/out-logging" bash test/extras_members.sh; echo "rc=$?"
```

Expected: a `MISSING:` line for each of the five archives, `rc=1`. `out-logging` is a real prefix carrying the stack with none of its notices.

If `out-logging` is gone, rebuild the red case from the published tarball:
```bash
cd /tmp && curl -sSL -o rt.tar.gz \
  https://github.com/measly-java-learning/executorch-runtime-dist/releases/download/v1.3.1-10/executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz \
  && tar xzf rt.tar.gz
```
That tree has no extras members, so it will also report the pre-existing extras `MISSING:` lines — read only the five license lines from it.

- [ ] **Step 3: Run against the swept prefix to verify it passes**

```bash
PREFIX=/tmp/tok-guard bash test/extras_members.sh; echo "rc=$?"
```

Expected: `OK: extras members present + relocatable`, `rc=0`. That prefix got its notices in Task 3 Step 5.

- [ ] **Step 4: Confirm the Windows case stays silent**

```bash
scratch=$(mktemp -d); mkdir -p "$scratch/lib" "$scratch/THIRD-PARTY-NOTICES"
PREFIX="$scratch" bash test/extras_members.sh 2>&1 | grep -c "THIRD-PARTY-NOTICES entry" || echo "0 license findings (correct)"
rm -rf "$scratch"
```

Expected: zero license findings. The prefix will still report the extras members it lacks — that is the script's pre-existing behaviour, not this assertion.

- [ ] **Step 5: Commit**

```bash
git add test/extras_members.sh
git commit -m "test: pin the tokenizer-stack notices on the shipped prefix (#52)"
```

---

### Task 5: Prove it on a real build, then open the PR

**Files:** none (verification + integration).

- [ ] **Step 1: Full green locally**

```bash
git status --short
bash test/run.sh
```

Expected: clean tree; `ALL UNIT TESTS PASS`.

- [ ] **Step 2: Rebuild one variant in the pinned container**

The only thing that proves the recipe's own license phase end to end.

```bash
rm -rf out-tok
docker run --rm -v "$PWD":/work -v "$HOME/workspace/executorch":/executorch \
  -w /work -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$(cat .build-image)" \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant logging --prefix /work/out-tok --et-src /executorch'
```

Expected: reaches `>> build-runtime.sh done: /work/out-tok` with no license error.

```bash
ls out-tok/THIRD-PARTY-NOTICES | wc -l
PREFIX="$PWD/out-tok" bash test/extras_members.sh
```

Expected: **57** entries (56 from the sweep + `highway_LICENSE`, which `install_highway_license` adds outside the sweep); `OK: extras members present + relocatable`.

The container writes as root; chown the output back rather than using sudo:
```bash
docker run --rm -v "$PWD":/work -w /work "$(cat .build-image)" chown -R "$(id -u):$(id -g)" /work/out-tok
```

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin fix/tokenizers-license-passthrough
gh pr create --base main --title "fix: ship licenses for the tokenizers dependency stack (#52)" --body "$(cat <<'EOF'
Fixes #52.

## The bug

Every Linux tarball ships 96 archives from the `extension/llm/tokenizers` stack — 91 `libabsl_*.a`
(Apache-2.0), `libsentencepiece.a` (Apache-2.0), `libre2.a` (BSD-3), `libpcre2-8.a`/`libpcre2-posix.a`
(PCRE2), `libtokenizers.a`/`libregex_lookahead.a` (BSD-3) — plus FFHT, with no license text for any
of them. Same root cause as #45: a vendoring root outside the sweep. Confirmed on the published
`v1.3.1-10` artifact: 36 notices, zero matching these deps.

## The fix

- `extension` joins `ET_NOTICE_ROOTS`; the sweep goes 42 -> 56 notices.
- `build` joins `ET_NOTICE_PRUNE_DIRS`. A tokenizers build tree is untracked output, so sweeping it
  would make the notice set differ between a clean CI checkout and a built-in local one. It is the
  only one of the 15 candidate additions that is excluded — the other 14 all cover code verified
  present in the shipped archives, including sentencepiece's vendored protobuf-lite/absl
  (`google::protobuf` + `absl::internal` symbols), the header-only darts_clone/esaxx, pcre2's sljit
  (11 JIT symbols), and nlohmann json (471 symbols in `libtokenizers.a`).
- Five representative archives join `_ET_LICENSED_ARCHIVES` so the guard covers them. Needles are
  `<dep>_<noticefile>` tails, which survive a vendoring-path move. `libre2.a` uses `_re2_LICENSE`
  deliberately: a bare `re2` also matches the pcre2 notice, so a missing re2 notice would pass
  whenever pcre2's was present — there is a test for exactly that.
- `test/extras_members.sh` asserts it on the real built prefix.

Linux-only, and not by a platform branch: the published Windows tarballs ship none of these
archives, and the guard is presence-driven.

## Verification

- `test/lib_licenses.test.sh`: the new root, the build-residue prune, each new guard entry in both
  states, and the pcre2/re2 collision.
- `test/extras_members.sh` verified red against a pre-fix prefix (five `MISSING:` lines) and green
  after; silent on a prefix without the stack.
- Full container build: 57 notices shipped (56 swept + `highway_LICENSE`), guard passes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Confirm CI**

```bash
gh pr checks --watch
```

Expected: `unit` green, and the extras gate's `full` mode green (a `build-runtime.sh`-adjacent change routes there; `scripts/lib/` changes may not — check `classify`'s verdict and do not assume).
