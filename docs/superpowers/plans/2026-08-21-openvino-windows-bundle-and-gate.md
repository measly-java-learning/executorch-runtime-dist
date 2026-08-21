# OpenVINO Windows Bundle and Runtime Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a `win_amd64` OpenVINO runtime bundle and prove, in CI, that the Windows ExecuTorch delegate loads it and runs a delegated `.pte` correctly — closing the last unproven link in Windows OpenVINO support.

**Architecture:** Four moves. (1) The bundle SSOT `scripts/lib/openvino.sh` becomes platform-taking for members, licenses and the wheel pin. (2) `vendor-openvino.sh` grows `--platform`; the Windows path skips the SONAME symlink and the entire hwloc licence fetch. (3) Two Windows gate scripts mirror the Linux pair, built on the already-written `win_origin_probe.c`. (4) A `full-gates-windows` job runs them against the packaged tarball on every `full` PR.

**Tech Stack:** Bash (`set -euo pipefail`) under Git-Bash on Windows, CMake + Ninja, MSVC (`cl`), GitHub Actions, OpenVINO 2025.4.1.

**Spec:** https://github.com/measly-java-learning/executorch-runtime-dist/issues/37, steps 3 and 5 of its suggested order, plus the verified findings in its result comments — in particular [the win_amd64 member mapping and the flat-bundle load result](https://github.com/measly-java-learning/executorch-runtime-dist/issues/37#issuecomment-5372679998).

**Predecessor:** `docs/superpowers/plans/2026-08-21-openvino-windows-compile-coverage.md` (merged as PR #43), which vendored the backend patch and enabled the delegate on both Windows platforms.

## Global Constraints

- `OV_VERSION` is **2025.4.1** for both platforms. No version skew: the same `OV_WHEEL_PYTAG` (`cp312`) publishes both wheels.
- The `win_amd64` wheel sha256 is **`c50293d1463698012eaa526dcc83f841b85a3f4952eea4c9445c83e0346f8e80`** (41,791,284 bytes), verified twice against PyPI.
- **`OV_ABI` is Linux-only.** Windows DLLs are unversioned (`openvino_c.dll`, not `openvino_c.dll.2541`), so there is no SONAME and no symlink to add.
- **Windows has no hwloc.** It is folded into `tbbbind_2_5.dll`, so `OV_HWLOC_VERSION` / `OV_HWLOC_LICENSE_URL` and their hard gate do not apply — the single largest piece of out-of-band work in `vendor-openvino.sh` disappears on this platform.
- Shell runs under `set -euo pipefail`; `grep` exits 1 on no-match, so guard with `|| true`.
- Windows bash recipes run under the VS dev shell via `pwsh -File build-runtime.ps1 <script> [args]`. WSL bash is never acceptable.
- `bash test/run.sh` must be green from a clean checkout at the end of every task.
- Work lands on a branch (`feature/*`) through a PR.

## Decision Record

**Bash `-windows.sh` mirrors, not PowerShell.** Issue #37 suggested "PowerShell mirrors", but the established convention here is a bash sibling run under Git-Bash: `test/relocatability-windows.sh` is exactly this, and `build-runtime.ps1`'s header already names it as one of the recipes it launches. Bash mirrors keep the two platforms' gates readable side by side and reuse the same argument contracts.

**`win_origin_probe.c` replaces both Linux probes on Windows.** `devices_probe.c` and `blob_probe.c` are separate binaries because each covers one stage. The Windows probe already does resolve + enumerate + blob-import in one binary, *and* carries a `plain`-mode negative control the Linux smoke gate has no equivalent of. Landing it is also the merge of the dangling `feature/openvino-windows-origin-probe` branch, which is still not on `main`.

**The gate vendors its own bundle rather than receiving one as an artifact.** This requires replacing `unzip` with `python -m zipfile -e` in `vendor-openvino.sh` (Task 2, Step 4): Git for Windows does **not** ship `unzip`, while python is already a hard dependency of the script because it shells out to `pip download`. The change is platform-neutral and removes a dependency rather than adding one.

**The gate runs against the packaged tarball, not the build tree.** `full-build-windows` already produces `dist/*.tar.gz`; the gate extracts that. Testing the bytes a consumer receives is the same principle as release.yml's relocatability smoke, and it catches packaging faults (a `lib/` member dropped during staging) that a build-tree test cannot see.

**Upstream ExecuTorch PR is deliberately deferred until after this lands.** Judging by the interval between this project's last upstream PR and its release, acceptance is months away — and a patch is far easier to argue for when it is backed by a working, gated, published implementation than as a speculative port. Completing the work *is* the case for the patch. Nothing here depends on upstream, and every ET pin bump regenerates the patch in the meantime (`scripts/patch-et-sources.sh` fails loudly if an anchor moves, so the cost is visible rather than silent).

**Out of scope:** publishing the Windows bundle. `release.yml`'s `openvino` job still hardcodes `linux-x86_64`, and `gen-pin.sh` still has no Windows OpenVINO rows. **The standing risk from PR #43 therefore persists after this plan lands**: a release tag still ships Windows tarballs whose `BUILDINFO` advertises `openvino_version=2025.4.1` with no published Windows bundle. What changes is that we will know the pairing *works*. Step 6 is the follow-up plan and should be written immediately after this one.

---

## File Structure

**Created:**
- `test/openvino_smoke-windows.sh` — Windows sibling of `openvino_smoke.sh` (resolve + enumerate + blob import, plus a negative control).
- `test/openvino_fixture_run-windows.sh` — Windows sibling of `openvino_fixture_run.sh` (negative control, execute, compare).
- `test/openvino/win_origin_probe.c` — cherry-picked from `feature/openvino-windows-origin-probe`.
- `test/lib/extras_gate_ov_windows.py` + `test/extras_gate_ov_windows.test.sh` — structural assertions on the new job.

**Modified:**
- `scripts/lib/openvino.sh` — platform-taking `ov_lib_members` / `ov_license_members`; Windows wheel sha; wheel platform tag.
- `scripts/vendor-openvino.sh` — `--platform`; skip symlink and hwloc on Windows; `python -m zipfile` instead of `unzip`.
- `test/lib_openvino.test.sh` — cover both platforms' member and licence sets.
- `test/vendor_openvino.test.sh` (if present; otherwise extend `lib_openvino.test.sh`) — the synthetic-wheel path for Windows.
- `.github/workflows/extras-gate.yml` — `full-gates-windows` job; `paths:` filter.
- `build-runtime.ps1` — add the two new recipes to the header's list.
- `docs/openvino-python-consumer.md` — replace the "supply your own DLL" guidance once a real bundle exists in CI.

---

## Task 1: Make the bundle SSOT platform-aware

**Files:**
- Modify: `scripts/lib/openvino.sh`
- Modify: `test/lib_openvino.test.sh`

**Interfaces:**
- Produces:
  - `ov_lib_members <platform>` — 7 Linux members; 6 Windows members (no hwloc).
  - `ov_license_members <platform>` — 5 Linux; 4 Windows (no `hwloc-COPYING`).
  - `ov_wheel_sha256 <platform>` — the pinned wheel digest.
  - `ov_wheel_platform_tag <platform>` — `manylinux2014_x86_64` or `win_amd64`.
  - `ov_uses_hwloc <platform>` — 0 (yes) / 1 (no); the single predicate for the licence-fetch branch.

- [ ] **Step 1: Create the branch**

```bash
git fetch origin && git checkout -b feature/openvino-windows-bundle origin/main
```

- [ ] **Step 2: Write the failing tests**

Append to `test/lib_openvino.test.sh`:

```bash
# --- platform-taking bundle surface -------------------------------------------------------
# The Windows wheel ships the same CPU runtime set MINUS hwloc, which is folded into
# tbbbind_2_5.dll. A member list that is right for one platform and silently reused for the other
# is how a bundle ends up missing the IR frontend -- the failure openvino_smoke.sh stage 2 exists
# to catch, and which enumerates CPU perfectly right up until it cannot import a model.
assert_eq "$(ov_lib_members linux-x86_64 | wc -l)"   "7" "linux bundle has 7 libs"
assert_eq "$(ov_lib_members windows-x86_64 | wc -l)" "6" "windows bundle has 6 libs (no hwloc)"
assert_contains "$(ov_lib_members windows-x86_64)" "openvino_ir_frontend.dll" \
  "windows keeps the IR frontend"
assert_contains "$(ov_lib_members windows-x86_64)" "tbbbind_2_5.dll" \
  "windows keeps tbbbind (verified loadable from a flat bundle)"
case "$(ov_lib_members windows-x86_64)" in
  *hwloc*) printf 'FAIL: windows must not list hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: no hwloc on windows\n' ;;
esac
case "$(ov_lib_members windows-x86_64)" in
  *.so*) printf 'FAIL: windows members must be DLLs\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: windows members are DLLs\n' ;;
esac

assert_eq "$(ov_license_members linux-x86_64 | wc -l)"   "5" "linux ships 5 licence files"
assert_eq "$(ov_license_members windows-x86_64 | wc -l)" "4" "windows ships 4 (no hwloc-COPYING)"

# Both CRT platforms share one bundle: the bundle is the OpenVINO runtime, not our artifact, and
# the wheel's DLLs are /MD regardless of how a consumer links. Verified safe -- every OpenVINO
# allocation is freed through an OpenVINO-side function, so no CRT object crosses the boundary.
assert_eq "$(ov_lib_members windows-x86_64-static)" "$(ov_lib_members windows-x86_64)" \
  "both windows CRTs share one bundle"

assert_eq "$(ov_wheel_platform_tag linux-x86_64)"   "manylinux2014_x86_64" "linux wheel tag"
assert_eq "$(ov_wheel_platform_tag windows-x86_64)" "win_amd64"            "windows wheel tag"
_ovsha="$(ov_wheel_sha256 windows-x86_64)"
assert_eq "${#_ovsha}" "64" "windows wheel sha is 64 hex"
ov_uses_hwloc linux-x86_64   && printf 'ok: hwloc applies on linux\n'   || { printf 'FAIL: linux uses hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ov_uses_hwloc windows-x86_64 && { printf 'FAIL: windows must not use hwloc\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok: no hwloc on windows\n'

# An unknown platform must FAIL rather than default to one platform's member list -- the same
# reasoning crt_for_platform documents in configure-base.sh.
ov_lib_members bogus-platform     >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform rejected (libs)"
ov_license_members bogus-platform >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform rejected (licences)"
ov_wheel_sha256 ""                >/dev/null 2>&1; assert_eq "$?" "2" "empty platform rejected (sha)"
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bash test/lib_openvino.test.sh
```

Expected: failures on the new assertions, and `ov_wheel_platform_tag: command not found`.

- [ ] **Step 4: Make the SSOT platform-aware**

In `scripts/lib/openvino.sh`, add the Windows wheel pin next to the existing one:

```bash
OV_WHEEL_SHA256="88f074286d420c1a1a95e7f2ba11109a899f2f3b3fd818cfe1e47ead22cc7e45"
# The win_amd64 wheel of the SAME OV_VERSION and OV_WHEEL_PYTAG, so the two platforms can never
# skew. 41,791,284 bytes; verified against PyPI.
OV_WHEEL_SHA256_WIN="c50293d1463698012eaa526dcc83f841b85a3f4952eea4c9445c83e0346f8e80"
```

Replace `ov_lib_members` and `ov_license_members` with platform-taking forms, keeping the existing
Linux comment block above them unchanged:

```bash
# Windows ships the same CPU runtime set MINUS hwloc: there is no separate hwloc DLL because it is
# folded into tbbbind_2_5.dll. The DLLs are unversioned, so OV_ABI does not appear here.
# tbbbind_2_5.dll IS kept: the prediction was that TBB's bare-name load would miss it in a flat
# bundle and silently lose NUMA binding, but it resolves -- verified by module enumeration in
# issue #37, comment 5372679998.
ov_lib_members() { # <platform>
  case "${1:-}" in
    linux-x86_64)
      cat <<EOF
libopenvino_c.so.${OV_ABI}
libopenvino.so.${OV_ABI}
libopenvino_intel_cpu_plugin.so
libopenvino_ir_frontend.so.${OV_ABI}
libtbb.so.12
libtbbbind_2_5.so.3
libhwloc.so.15
EOF
      ;;
    windows-x86_64|windows-x86_64-static)
      cat <<'EOF'
openvino_c.dll
openvino.dll
openvino_intel_cpu_plugin.dll
openvino_ir_frontend.dll
tbb12.dll
tbbbind_2_5.dll
EOF
      ;;
    *) echo "ov_lib_members: no member list for platform '${1:-}'" >&2; return 2 ;;
  esac
}

ov_license_members() { # <platform>
  case "${1:-}" in
    linux-x86_64)
      cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
hwloc-COPYING
EOF
      ;;
    windows-x86_64|windows-x86_64-static)
      cat <<'EOF'
LICENSE
runtime-third-party-programs.txt
onetbb_third-party-programs.txt
onednn_third-party-programs.txt
EOF
      ;;
    *) echo "ov_license_members: no licence list for platform '${1:-}'" >&2; return 2 ;;
  esac
}

# The wheel pin and its pip platform tag, per platform. Kept beside the member lists: the three
# are read together, and a platform added to one but not the others fails at vendoring rather
# than shipping a mismatched bundle.
ov_wheel_sha256() { # <platform>
  case "${1:-}" in
    linux-x86_64) printf '%s' "$OV_WHEEL_SHA256" ;;
    windows-x86_64|windows-x86_64-static) printf '%s' "$OV_WHEEL_SHA256_WIN" ;;
    *) echo "ov_wheel_sha256: no wheel pinned for platform '${1:-}'" >&2; return 2 ;;
  esac
}

ov_wheel_platform_tag() { # <platform>
  case "${1:-}" in
    linux-x86_64) printf 'manylinux2014_x86_64' ;;
    windows-x86_64|windows-x86_64-static) printf 'win_amd64' ;;
    *) echo "ov_wheel_platform_tag: no wheel tag for platform '${1:-}'" >&2; return 2 ;;
  esac
}

# THE predicate for "does this platform's bundle carry hwloc, and therefore need its notice
# fetched out of band?" One mapping, so vendor-openvino.sh's licence gate cannot disagree with
# ov_license_members about whether hwloc-COPYING is expected.
ov_uses_hwloc() { # <platform> -> 0 (yes) / 1 (no)
  case "${1:-}" in
    linux-x86_64) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 5: Update the existing single-platform call sites**

`ov_lib_members` and `ov_license_members` now require an argument. Find every caller and pass one:

```bash
grep -rn 'ov_lib_members\|ov_license_members' --include='*.sh' --include='*.yml' . | grep -v '^\./\.git/'
```

Expected callers: `scripts/vendor-openvino.sh` (Task 2 rewrites these) and `test/lib_openvino.test.sh`. Any other hit must be given an explicit platform — never a default.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bash test/lib_openvino.test.sh && bash test/run.sh
```

Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/openvino.sh test/lib_openvino.test.sh
git commit -m "feat(openvino): make the bundle SSOT platform-taking

ov_lib_members/ov_license_members now take a platform; adds ov_wheel_sha256,
ov_wheel_platform_tag and ov_uses_hwloc. Windows ships the same CPU runtime set
minus hwloc (folded into tbbbind_2_5.dll) with unversioned DLLs, so OV_ABI does
not apply there.

An unknown platform returns 2 rather than defaulting to a member list, for the
reason crt_for_platform documents: a wrong-but-plausible default ships a bundle
that fails at model load, not at vendoring."
```

---

## Task 2: Teach `vendor-openvino.sh` to assemble either platform

**Files:**
- Modify: `scripts/vendor-openvino.sh`
- Modify: `test/lib_openvino.test.sh` (or the existing vendor test, if one exists)

**Interfaces:**
- Consumes: Task 1's five helpers.
- Produces: `vendor-openvino.sh --platform <p> --out <dir>` → `<dir>/openvino-runtime-2025.4.1-<p>/{lib,licenses,BUILDINFO}`, printing the bundle path. Task 4's gate job calls this.

- [ ] **Step 1: Add the flag and thread the platform through**

In `scripts/vendor-openvino.sh`, replace the hardcoded `PLATFORM="linux-x86_64"` and the arg loop:

```bash
PLATFORM="linux-x86_64"
OUT=""; WHEEL=""; HWLOC_LICENSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)            OUT="$2"; shift 2 ;;
    --platform)       PLATFORM="$2"; shift 2 ;;
    --wheel)          WHEEL="$2"; shift 2 ;;
    --hwloc-license)  HWLOC_LICENSE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:?--out required}"
# Fail here rather than at the first missing member: an unrecognised platform has no member list,
# no wheel pin and no tag, and the errors from those would each describe a symptom.
ov_wheel_sha256 "$PLATFORM" >/dev/null || exit 2
```

Update the usage line in the header to `vendor-openvino.sh --out <dir> [--platform <p>] [--wheel <path>] [--hwloc-license <path>]`, and note that the Windows path skips the symlink and the hwloc fetch.

- [ ] **Step 2: Make the download platform-aware**

```bash
  pip download "openvino==$OV_VERSION" --no-deps --only-binary :all: \
    --python-version "${OV_WHEEL_PYTAG#cp}" --platform "$(ov_wheel_platform_tag "$PLATFORM")" \
    -d "$WORK/dl" >&2
  WHEEL="$(ls "$WORK"/dl/openvino-*.whl)"
  actual="$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  expected="$(ov_wheel_sha256 "$PLATFORM")"
  [ "$actual" = "$expected" ] || {
    echo "vendor-openvino.sh: wheel sha256 mismatch for $PLATFORM" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  }
```

- [ ] **Step 3: Gate the hwloc fetch on the platform**

Replace the whole hwloc block with the platform-gated form. The body is unchanged; only the
surrounding `if` and the indentation are new:

```bash
# ---- obtain the hwloc notice (BSD-3-Clause; NOT bundled in the wheel) ----
# Linux only: on Windows hwloc is folded into tbbbind_2_5.dll, so there is no separate binary to
# attribute and nothing to fetch. ov_uses_hwloc is the one predicate for this, shared with
# ov_license_members so the fetch and the licence gate cannot disagree about what is expected.
if ov_uses_hwloc "$PLATFORM"; then
  if [ -z "$HWLOC_LICENSE" ]; then
    HWLOC_LICENSE="$WORK/hwloc-COPYING"
    echo ">> fetching hwloc $OV_HWLOC_VERSION COPYING" >&2
    curl -fsSL "$OV_HWLOC_LICENSE_URL" -o "$HWLOC_LICENSE" || {
      echo "vendor-openvino.sh: could not fetch hwloc license from $OV_HWLOC_LICENSE_URL" >&2
      echo "  Refusing to ship libhwloc.so.15 unattributed. Supply --hwloc-license, or drop" >&2
      echo "  libtbbbind/libhwloc from ov_lib_members (losing NUMA binding) — never ship without it." >&2
      exit 1
    }
  fi
  [ -s "$HWLOC_LICENSE" ] || {
    echo "vendor-openvino.sh: hwloc license '$HWLOC_LICENSE' missing or empty" >&2; exit 1; }
fi
```

and likewise the copy further down:

```bash
if ov_uses_hwloc "$PLATFORM"; then
  cp -a "$HWLOC_LICENSE" "$BUNDLE/licenses/hwloc-COPYING"
fi
```

- [ ] **Step 4: Replace `unzip` with `python -m zipfile`**

```bash
# python, not unzip: Git for Windows does not ship unzip, and this script must run on the Windows
# gate runner as well as in the manylinux container. python is already a hard dependency (pip
# download above), so this removes a dependency rather than adding one.
python -m zipfile -e "$WHEEL" "$WORK/x"
```

- [ ] **Step 5: Gate the symlink on the platform**

First add a dedicated predicate to `scripts/lib/openvino.sh`. Do **not** reuse `ov_uses_hwloc`,
even though both are currently "linux only" — they are different facts, and collapsing them means
a future platform silently inherits the wrong one:

```bash
# Does this platform's bundle need the unversioned compatibility symlink?
ov_needs_soname_symlink() { # <platform> -> 0 (yes) / 1 (no)
  case "${1:-}" in
    linux-x86_64) return 0 ;;
    *) return 1 ;;
  esac
}
```

Then guard the symlink with it:

```bash
# The wheel ships only the SONAME-versioned file, so ExecuTorch's default dlopen of the
# unversioned name would fail against a bare wheel install. Windows DLLs are unversioned, so
# there is nothing to alias.
if ov_needs_soname_symlink "$PLATFORM"; then
  ln -sfn "libopenvino_c.so.${OV_ABI}" "$BUNDLE/lib/libopenvino_c.so"
fi
```

- [ ] **Step 6: Make the members, licences and BUILDINFO platform-aware**

Pass the platform to both member loops (`$(ov_lib_members "$PLATFORM")`, `$(ov_license_members "$PLATFORM")`), and emit BUILDINFO without the Linux-only keys:

`if`, not `&&` — the repo's convention, documented in `test/openvino_fixture_run.sh`'s header:
a false `&&` list at statement level is a known `set -e` foot-gun and is not worth re-litigating
per call site.

```bash
{
  echo "ov_version=$OV_VERSION"
  if ov_needs_soname_symlink "$PLATFORM"; then echo "ov_abi=$OV_ABI"; fi
  echo "platform=$PLATFORM"
  if ov_uses_hwloc "$PLATFORM"; then echo "hwloc_version=$OV_HWLOC_VERSION"; fi
  echo "source_wheel=$(basename "$WHEEL")"
  echo "source_wheel_sha256=$(sha256sum "$WHEEL" | cut -d' ' -f1)"
  echo "build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUNDLE/BUILDINFO"
```

- [ ] **Step 7: Assemble a real Windows bundle and check it against the issue's mapping**

This runs on **Linux** — the script only downloads and copies, which is the property that keeps
the bundle out of the release's Windows critical path:

```bash
./scripts/vendor-openvino.sh --platform windows-x86_64 --out /tmp/ovwin
ls -l /tmp/ovwin/openvino-runtime-2025.4.1-windows-x86_64/lib
cat /tmp/ovwin/openvino-runtime-2025.4.1-windows-x86_64/BUILDINFO
```

Expected: exactly 6 DLLs, `licenses/` with 4 files and **no** `hwloc-COPYING`, and a BUILDINFO with
no `ov_abi` and no `hwloc_version` line. Sizes should match the issue's mapping table
(`openvino_c.dll` ~217 KB, `openvino.dll` ~14.5 MB, `openvino_intel_cpu_plugin.dll` ~39.7 MB,
`openvino_ir_frontend.dll` ~436 KB, `tbb12.dll` ~188 KB, `tbbbind_2_5.dll` ~206 KB).

- [ ] **Step 8: Confirm the Linux bundle is byte-for-byte unaffected**

The Linux path is the one already in production, so prove the refactor did not disturb it:

```bash
./scripts/vendor-openvino.sh --platform linux-x86_64 --out /tmp/ovlin
find /tmp/ovlin -type f -o -type l | sed "s#/tmp/ovlin/##" | sort > /tmp/ovlin.manifest
grep -c . /tmp/ovlin.manifest   # expect 13: 7 libs + 1 symlink + 5 licences ... minus BUILDINFO
cat /tmp/ovlin.manifest
```

Expected: the 7 libs, the `lib/libopenvino_c.so` symlink, 5 licence files including
`hwloc-COPYING`, and `BUILDINFO` still carrying `ov_abi=` and `hwloc_version=`.

- [ ] **Step 9: Run the suite and commit**

```bash
bash test/run.sh
git add scripts/vendor-openvino.sh scripts/lib/openvino.sh test/lib_openvino.test.sh
git commit -m "feat(openvino): vendor the win_amd64 bundle

--platform selects the wheel, member list, licence set and BUILDINFO keys. The
Windows path skips the SONAME symlink (DLLs are unversioned) and the entire
hwloc licence fetch (hwloc is folded into tbbbind_2_5.dll) -- the largest piece
of out-of-band work in this script, gone for that platform.

unzip -> python -m zipfile: Git for Windows ships no unzip and this must run on
the Windows gate runner; python was already required by pip download.

Still assembles on Linux for both platforms, keeping the bundle off the
Windows critical path."
```

---

## Task 3: Windows gate scripts

**Files:**
- Create: `test/openvino/win_origin_probe.c` (cherry-pick), `test/openvino_smoke-windows.sh`, `test/openvino_fixture_run-windows.sh`
- Modify: `build-runtime.ps1` (header recipe list)

**Interfaces:**
- Consumes: Task 2's bundle layout.
- Produces:
  - `openvino_smoke-windows.sh <bundle-dir>`
  - `openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>`
  Both take the same positional arguments as their Linux siblings, so Task 4's job reads the same as `full-gates`.

- [ ] **Step 1: Land the probe**

```bash
git cherry-pick 34ddf8b   # test(openvino): add the Windows $ORIGIN-substitute probe
```

If the cherry-pick conflicts, take the branch's version wholesale — `main` has no copy of this file. Then update its header, which currently says it is not wired into any gate:

```
// Wired into test/openvino_smoke-windows.sh, which compiles it with cl and runs BOTH the `plain`
// negative control and the `dllload` acceptance cell. See that script for the gate contract.
```

- [ ] **Step 2: Write the Windows smoke gate**

Create `test/openvino_smoke-windows.sh`:

```bash
#!/usr/bin/env bash
# Windows runtime acceptance gate for the C10 bundle -- sibling of test/openvino_smoke.sh.
#
# Windows-specific vs the Linux sibling:
#   - ONE probe binary, not two. win_origin_probe.c does resolve + enumerate + blob import in a
#     single process, so there is no separate devices_probe/blob_probe split.
#   - THREE cells, not two. The extra one is a NEGATIVE CONTROL that the Linux gate has no
#     equivalent of: Linux self-resolves via RPATH=$ORIGIN, which either works or does not, while
#     Windows will happily satisfy a load from PATH, the app directory or System32. Without the
#     `plain` cell a passing `dllload` cell could just mean some other OpenVINO was found, and the
#     gate would be measuring the runner's installed software rather than our bundle.
#   - No `env -u LD_LIBRARY_PATH`. The Windows analogue is stripping PATH, done below.
#
# Usage: openvino_smoke-windows.sh <bundle-dir>
# Must run under the VS dev shell: pwsh -File build-runtime.ps1 test/openvino_smoke-windows.sh <dir>
set -euo pipefail
BUNDLE="${1:?usage: openvino_smoke-windows.sh <bundle-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$BUNDLE" && pwd)"

lib="$BUNDLE/lib/openvino_c.dll"
[ -f "$lib" ] || { echo "FAIL: $lib missing" >&2; exit 1; }

command -v cl >/dev/null 2>&1 \
  || { echo "FAIL: cl not on PATH -- run me through build-runtime.ps1" >&2; exit 1; }
command -v python >/dev/null 2>&1 \
  || { echo "FAIL: python not on PATH; the blob cell needs the openvino python package" >&2; exit 1; }
python -c 'import openvino' 2>/dev/null \
  || { echo "FAIL: the 'openvino' python package is required to mint a blob" >&2
       echo "  install the SAME version the bundle pins: pip install openvino==<OV_VERSION>" >&2
       exit 1; }

SCRATCH="$(mktemp -d)"
python "$HERE/openvino/make_blob.py" "$SCRATCH/smoke.blob"

# Build in the scratch dir, NOT the bundle dir: LOAD_LIBRARY_SEARCH_DEFAULT_DIRS includes the
# application directory, so an exe sitting next to the DLLs would satisfy the negative control
# from its own directory and make the control vacuous.
( cd "$SCRATCH" && cl /nologo /W3 /O2 /D_CRT_SECURE_NO_WARNINGS \
    "$(cygpath -w "$HERE/openvino/win_origin_probe.c")" \
    /Fe:probe.exe psapi.lib >/dev/null )
probe="$SCRATCH/probe.exe"

winbundle="$(cygpath -w "$lib")"
winblob="$(cygpath -w "$SCRATCH/smoke.blob")"

# Strip PATH to the system directories for every cell. This is the Windows analogue of the Linux
# gate's `env -u LD_LIBRARY_PATH`, and it is what makes the negative control meaningful.
minpath="$(cygpath -w "$SYSTEMROOT")\\System32;$(cygpath -w "$SYSTEMROOT")"

echo "== Cell 1: NEGATIVE CONTROL -- plain LoadLibraryW (must FAIL) =="
if PATH="$minpath" "$probe" plain "$winbundle" "$winblob"; then
  echo "FAIL: the bundle loaded WITHOUT the search flags. Something else on this machine is" >&2
  echo "  satisfying the dependency graph (PATH, the app dir, or System32), so cell 2 would" >&2
  echo "  pass vacuously and prove nothing about the flat bundle." >&2
  exit 1
fi
echo "ok: plain load fails, as it must without \$ORIGIN"

echo "== Cell 2: resolve + enumerate + import via LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR =="
out="$(PATH="$minpath" "$probe" dllload "$winbundle" "$winblob")" || {
  echo "FAIL: the bundle did not fully load" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"
case "$out" in
  *"DEVICE CPU"*) ;;
  *) echo "FAIL: CPU device not enumerated (plugin or TBB missing from the bundle?)" >&2; exit 1 ;;
esac
case "$out" in
  *"IMPORT OK"*) ;;
  *) echo "FAIL: blob import failed. A bundle can enumerate CPU and still fail here -- the usual" >&2
     echo "  cause is a missing openvino_ir_frontend.dll, which deserializes the IR in the blob." >&2
     exit 1 ;;
esac
case "$out" in
  *OUTSIDE*) echo "FAIL: a module resolved from OUTSIDE the bundle; the gate measured the" >&2
             echo "  runner's installed OpenVINO, not ours." >&2; exit 1 ;;
  *) ;;
esac

echo "GATE PASS: flat bundle self-resolves, enumerates CPU, and imports a compiled blob"
```

- [ ] **Step 3: Write the Windows fixture gate**

Create `test/openvino_fixture_run-windows.sh`. It mirrors the Linux three-stage structure exactly;
the only differences are the DLL name, `cygpath` conversion, and `PATH` stripping in place of
`env -u LD_LIBRARY_PATH`:

```bash
#!/usr/bin/env bash
# Windows end-to-end gate -- sibling of test/openvino_fixture_run.sh. Same three stages, same
# reasoning (see that file's header for why stages 1 and 2 must be separate PROCESSES: the
# delegate resolves the runtime behind a std::call_once with no retry).
#
# Windows-specific: OPENVINO_LIB_PATH points at openvino_c.dll and MUST be absolute -- the backend
# passes it to LoadLibraryExW with LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, which is only meaningful for
# an absolute path. PATH is stripped rather than LD_LIBRARY_PATH unset.
#
# The fixture .pte is the SAME Linux-exported artifact the Linux gate uses. That is not a
# shortcut: export_model() was shown to produce byte-identical blobs on Linux and Windows across
# different CPU vendors and capability sets, which is why ov_fixtures_name has no platform axis.
#
# Usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>
# Must run under the VS dev shell via build-runtime.ps1.
set -euo pipefail
PREFIX="${1:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
BUNDLE="${2:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
FIXTURES="${3:?usage: openvino_fixture_run-windows.sh <et-prefix> <bundle-dir> <fixture-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$(cd "$PREFIX" && pwd)"; BUNDLE="$(cd "$BUNDLE" && pwd)"; FIXTURES="$(cd "$FIXTURES" && pwd)"

lib="$BUNDLE/lib/openvino_c.dll"
pte="$FIXTURES/openvino_tiny.pte"; inbin="$FIXTURES/in.bin"; refbin="$FIXTURES/out.bin"
shapefile="$FIXTURES/shape"
for f in "$lib" "$pte" "$inbin" "$refbin" "$shapefile"; do
  [ -e "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

ov_in="$(sed -n 's/^OV_IN=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
ov_out="$(sed -n 's/^OV_OUT=\([0-9][0-9]*\)$/\1/p' "$shapefile")"
if [ -z "$ov_in" ] || [ -z "$ov_out" ]; then
  echo "FAIL: could not read OV_IN/OV_OUT from $shapefile" >&2; cat "$shapefile" >&2; exit 1
fi

SCRATCH="$(mktemp -d)"
echo "== Building ov_runner against $PREFIX =="
cmake -B "$SCRATCH/build" -S "$HERE/openvino" -G Ninja \
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl \
  -DCMAKE_PREFIX_PATH="$(cygpath -m "$PREFIX")"
cmake --build "$SCRATCH/build" --target ov_runner
runner="$SCRATCH/build/ov_runner.exe"

export OV_IN="$ov_in" OV_OUT="$ov_out"
minpath="$(cygpath -w "$SYSTEMROOT")\\System32;$(cygpath -w "$SYSTEMROOT")"

echo "== Stage 1: negative control -- no OPENVINO_LIB_PATH (must FAIL) =="
if env -u OPENVINO_LIB_PATH PATH="$minpath" "$runner" "$pte" "$inbin" "$SCRATCH/neg.bin" \
     2>"$SCRATCH/neg.err"; then
  echo "FAIL: the fixture ran WITHOUT OPENVINO_LIB_PATH -- it is not reaching the OpenVINO" >&2
  echo "  delegate at all, so stage 2 would pass vacuously." >&2
  exit 1
fi
sed 's/^/  /' "$SCRATCH/neg.err" >&2 || true
echo "ok: load fails without OPENVINO_LIB_PATH, as documented"

echo "== Stage 2: execute against the bundle, PATH stripped =="
PATH="$minpath" OPENVINO_LIB_PATH="$(cygpath -w "$lib")" \
  "$runner" "$pte" "$inbin" "$SCRATCH/got.bin" || {
  echo "FAIL: the fixture failed to run against the bundle" >&2
  echo "  If the failure is at method init, suspect the bundle member list before the .pte:" >&2
  echo "  a bundle missing openvino_ir_frontend.dll enumerates CPU but imports no model." >&2
  echo "  Error 126 with everything present means a MISSING DEPENDENCY -- most often the MSVC" >&2
  echo "  redistributable, which the wheel's /MD DLLs import from System32." >&2
  exit 1; }
echo "ok: fixture executed through the OpenVINO delegate"

echo "== Stage 3: compare delegated output to the eager golden =="
# Same 1e-2 tolerance and same reasoning as the Linux gate: OpenVINO picks inference precision
# from the CPU it lands on, and the runner pool is mixed. See openvino_fixture_run.sh.
python3 "$HERE/openvino/compare.py" "$SCRATCH/got.bin" "$refbin" 1e-2

echo "GATE PASS: fixture .pte runs on the vendored Windows bundle and matches the eager golden"
```

- [ ] **Step 4: Register the recipes in the PowerShell shim's header**

In `build-runtime.ps1`, extend the list in the header comment:

```
# Peer to build-runtime.sh: on Windows every bash recipe (build-runtime.sh,
# test/relocatability-windows.sh, test/openvino_smoke-windows.sh,
# test/openvino_fixture_run-windows.sh, scripts/check-windows-crt.sh) must run
# under the Visual Studio dev shell via Git-Bash.
```

- [ ] **Step 5: Set permissions and run the suite**

```bash
chmod 755 test/openvino_smoke-windows.sh test/openvino_fixture_run-windows.sh
chmod 664 test/openvino/win_origin_probe.c
bash test/run.sh
```

`test/exec_perms.test.sh` enforces the executable bit on gate scripts — if it fails, it is telling
you a mode is wrong, not that the script is broken.

- [ ] **Step 6: Commit**

```bash
git add test/openvino_smoke-windows.sh test/openvino_fixture_run-windows.sh \
  test/openvino/win_origin_probe.c build-runtime.ps1
git commit -m "test(openvino): Windows siblings of the two runtime gates

Bash under Git-Bash via build-runtime.ps1, matching relocatability-windows.sh
rather than the PowerShell mirrors issue #37 originally suggested.

The smoke gate has a third cell the Linux one does not need: a plain-LoadLibrary
negative control. Linux either self-resolves via RPATH=\$ORIGIN or does not,
while Windows will satisfy a load from PATH, the app dir or System32 -- so
without it a passing acceptance cell could just mean the runner had OpenVINO
installed."
```

---

## Task 4: Run the Windows gates in CI

**Files:**
- Modify: `.github/workflows/extras-gate.yml`
- Create: `test/lib/extras_gate_ov_windows.py`, `test/extras_gate_ov_windows.test.sh`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: CI coverage; no shell interface.

- [ ] **Step 1: Upload the packaged tarball from the Windows build**

Add to `full-build-windows`, after its Package step:

```yaml
      - uses: actions/upload-artifact@v7
        with:
          name: win-tarball-${{ matrix.platform }}
          path: dist/*.tar.gz
          retention-days: 1
```

- [ ] **Step 2: Write the failing structural test**

Create `test/lib/extras_gate_ov_windows.py`:

```python
"""Structural assertions on the Windows OpenVINO gate job.

The job only means something if it runs BOTH gate scripts against a bundle it vendored and a
prefix taken from the PACKAGED tarball. Each of those is a property a well-meaning edit could
drop while leaving the job green, so each is asserted here.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
JOB = "full-gates-windows"


def main() -> int:
    gate = yaml.safe_load((ROOT / ".github/workflows/extras-gate.yml").read_text())
    fails = []
    if JOB not in gate["jobs"]:
        print(f"FAIL: extras-gate has no {JOB} job")
        return 1
    job = gate["jobs"][JOB]
    steps = yaml.dump(job["steps"])

    if not str(job.get("runs-on", "")).startswith("windows"):
        fails.append(f"{JOB} must run on a windows runner")
    needs = job.get("needs") or []
    for n in ("full-build-windows", "full-aot"):
        if n not in needs:
            fails.append(f"{JOB} must depend on {n}")
    if "full" not in str(job.get("if", "")):
        fails.append(f"{JOB} must be gated on mode == 'full'")

    for needle, why in [
        ("openvino_smoke-windows.sh", "must run the bundle smoke gate"),
        ("openvino_fixture_run-windows.sh", "must run the end-to-end fixture gate"),
        ("vendor-openvino.sh", "must vendor the win_amd64 bundle it tests"),
        ("--platform windows-x86_64", "must vendor the WINDOWS bundle, not the linux one"),
        ("build-runtime.ps1", "gate scripts need the VS dev shell"),
        ("tar -xzf", "must test the PACKAGED tarball, not the build tree"),
    ]:
        if needle not in steps:
            fails.append(f"{JOB} {why} (missing {needle})")

    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"ok: {JOB} vendors a windows bundle and runs both gates on the packaged tarball")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Create `test/extras_gate_ov_windows.test.sh`:

```bash
#!/usr/bin/env bash
# Thin invoker: the real checks parse workflow YAML and live in test/lib/extras_gate_ov_windows.py.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/lib/extras_gate_ov_windows.py"
exit $?
```

- [ ] **Step 3: Run it to verify it fails**

```bash
chmod 755 test/extras_gate_ov_windows.test.sh && chmod 644 test/lib/extras_gate_ov_windows.py
bash test/extras_gate_ov_windows.test.sh
```

Expected: `FAIL: extras-gate has no full-gates-windows job`, exit 1.

- [ ] **Step 4: Add the job**

Append to `.github/workflows/extras-gate.yml`:

```yaml
  # The Windows half of full-gates, and the first thing anywhere that puts the three verified
  # pieces in one process: a win_amd64 bundle, the MSVC-built delegate, and a Linux-exported
  # fixture .pte. Until this job existed, each was proven only in isolation.
  #
  # Runs against the PACKAGED tarball rather than the build tree, so a packaging fault (a lib/
  # member lost during staging) fails here rather than at a consumer.
  #
  # Only windows-x86_64 (/MD). The static CRT is covered where it differs -- compilation and
  # packaging, both in full-build-windows -- and the delegate's runtime behaviour cannot vary by
  # our CRT choice: every OpenVINO allocation is freed through an OpenVINO-side function, so no
  # CRT object crosses the DLL boundary. Running both here would double the slowest gate arm to
  # re-prove that analysis.
  full-gates-windows:
    needs: [classify, full-build-windows, full-aot]
    if: needs.classify.outputs.mode == 'full'
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with:
          name: win-tarball-windows-x86_64
          path: winpkg
      - uses: actions/download-artifact@v8
        with:
          name: full-fixtures
          path: fixtures-dryrun
      - name: Unpack the packaged tarball
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p prefix
          tar -xzf winpkg/*.tar.gz -C prefix --strip-components=1
          [ -f prefix/lib/openvino_backend.lib ] \
            || { echo "::error::packaged tarball has no openvino_backend.lib"; exit 1; }
      - name: Vendor the win_amd64 bundle
        shell: bash
        run: |
          set -euo pipefail
          python -m pip install -U pip >/dev/null
          ./scripts/vendor-openvino.sh --platform windows-x86_64 --out "$PWD/ovstage-win"
      - name: OpenVINO bundle smoke (resolve + enumerate + blob import)
        shell: pwsh
        run: |
          pip install -r requirements/openvino-runtime.txt
          $stem = "openvino-runtime-2025.4.1-windows-x86_64"
          & pwsh -File build-runtime.ps1 test/openvino_smoke-windows.sh "$PWD/ovstage-win/$stem"
          if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
      - name: OpenVINO end-to-end (fixture .pte through the delegate)
        shell: pwsh
        run: |
          $stem = "openvino-runtime-2025.4.1-windows-x86_64"
          & pwsh -File build-runtime.ps1 test/openvino_fixture_run-windows.sh `
            "$PWD/prefix" "$PWD/ovstage-win/$stem" "$PWD/fixtures-dryrun/openvino"
          if ($LASTEXITCODE -ne 0) { throw "fixture gate failed (exit $LASTEXITCODE)" }
```

The bundle stem is spelled literally here rather than via `ov_asset_stem` because these steps are
`pwsh`, not bash. If that bothers you, compute it in a prior `shell: bash` step and pass it through
`$GITHUB_ENV` — do **not** hand-maintain a second copy of the naming rule anywhere else.

- [ ] **Step 5: Add the new files to the paths filter**

In `.github/workflows/extras-gate.yml`'s `paths:` block, beside the existing OpenVINO gate entries:

```yaml
      - 'test/openvino_smoke-windows.sh'
      - 'test/openvino_fixture_run-windows.sh'
```

`test/openvino/**` already covers `win_origin_probe.c`, and `classify-gate.sh` already routes
`test/openvino(_smoke\.sh|_fixture_run\.sh|/.*)` to `full` — extend that regex to match the
`-windows` suffixes too, or the new scripts start a workflow that routes to tier1 and never runs
them.

- [ ] **Step 6: Run the tests and commit**

```bash
bash test/extras_gate_ov_windows.test.sh && bash test/run.sh
git add .github/workflows/extras-gate.yml test/lib/extras_gate_ov_windows.py \
  test/extras_gate_ov_windows.test.sh scripts/classify-gate.sh
git commit -m "ci(gate): run the OpenVINO gates on Windows

First time anywhere the three verified pieces meet in one process: a win_amd64
bundle, the MSVC-built delegate, and a Linux-exported fixture .pte. Each was
previously proven only in isolation.

Tests the packaged tarball rather than the build tree, so a staging fault fails
here instead of at a consumer."
```

- [ ] **Step 7: Push, open the PR, and verify the gate proved what it claims**

```bash
git push -u origin feature/openvino-windows-bundle
gh pr create --fill
```

In `full-gates-windows`, confirm all four:

1. `ok: plain load fails, as it must without $ORIGIN` — the negative control. If this cell *passes* the load, every result below it is meaningless.
2. `DEVICE CPU` and `IMPORT OK` from cell 2, with **no** `[OUTSIDE]` module lines.
3. `ok: load fails without OPENVINO_LIB_PATH, as documented` — the fixture gate's own negative control, and the proof the delegate is genuinely linked in.
4. `compare.py: 8 values match` followed by `GATE PASS`.

Item 4 is the one that has never happened before on Windows. Everything prior to this PR proved a
piece of the chain; this is the chain.

---

## What this does NOT deliver

- **The Windows bundle is still not published.** `release.yml`'s `openvino` job hardcodes `linux-x86_64` and `gen-pin.sh` emits no Windows OpenVINO rows, so the standing risk from PR #43 persists: a tag ships Windows tarballs advertising `openvino_version=2025.4.1` with no bundle asset to pair them with. Write the step 6 plan next.
- **No upstream ExecuTorch PR.** Deferred by decision (see the Decision Record). Once this lands, the argument for the patch is a working gated implementation rather than a proposal.
- **`windows-x86_64-static` is not gated at runtime**, only at compile and packaging. See the job comment for why that is a considered choice rather than an oversight.
