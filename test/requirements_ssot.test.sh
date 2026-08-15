#!/usr/bin/env bash
# requirements/ has three layers and this asserts they agree:
#   scripts/lib/openvino.sh  ->  requirements/openvino-*.in  ->  requirements/*.txt (compiled lock)
#
# The failure this prevents: someone bumps OV_VERSION for the vendored bundle and does not
# regenerate/recompile, so fixtures get exported with one OpenVINO wheel and replayed against a
# bundle built from another. That mismatch usually still loads, so no gate would notice.
#
# HERMETIC BY CONSTRUCTION: a true lock-freshness check means re-running `uv pip compile`, which
# needs uv and the network - neither belongs in test/run.sh. So this checks the invariant that
# actually matters and is checkable offline: every version the SSOT pins appears verbatim in the
# compiled lock. A lock left stale after an OV_VERSION bump fails here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"
. "$root/scripts/lib/openvino.sh"

# 1. The generated .in files match the SSOT.
if "$root/scripts/gen-requirements.sh" --check >/dev/null 2>&1; then
  echo "ok: requirements/openvino-*.in match the openvino.sh SSOT"
else
  echo "FAIL: requirements/openvino-*.in are stale (run scripts/gen-requirements.sh)" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 2. That check must be able to FAIL, or step 1 is decorative.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$root/requirements/openvino-aot.in" "$tmp/backup"
sed -i 's/^openvino==.*/openvino==0.0.0/' "$root/requirements/openvino-aot.in"
if "$root/scripts/gen-requirements.sh" --check >/dev/null 2>&1; then
  echo "FAIL: --check passed on a tampered .in file" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: --check detects a drifted version"
fi
cp "$tmp/backup" "$root/requirements/openvino-aot.in"

# 3. The COMPILED LOCKS carry the SSOT versions. This is the one that catches "regenerated the .in
#    but forgot to recompile" - CI installs the .txt, so a stale lock is what would actually ship.
for f in openvino-runtime openvino-aot; do
  if grep -qx "openvino==${OV_VERSION}" "$root/requirements/$f.txt" 2>/dev/null; then
    echo "ok: $f.txt locks openvino==${OV_VERSION}"
  else
    echo "FAIL: $f.txt does not lock openvino==${OV_VERSION} (run scripts/compile-requirements.sh)" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
done
if grep -qx "nncf==${OV_NNCF_VERSION}" "$root/requirements/openvino-aot.txt" 2>/dev/null; then
  echo "ok: openvino-aot.txt locks nncf==${OV_NNCF_VERSION}"
else
  echo "FAIL: openvino-aot.txt does not lock nncf==${OV_NNCF_VERSION} (run scripts/compile-requirements.sh)" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 4. Every .in has a corresponding lock, so adding a source file cannot silently go uncompiled.
for f in "$root"/requirements/*.in; do
  lock="${f%.in}.txt"
  if [ -f "$lock" ]; then
    echo "ok: $(basename "$f") has a compiled lock"
  else
    echo "FAIL: $(basename "$f") has no lock (run scripts/compile-requirements.sh)" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
done

# 5. No literal OpenVINO/NNCF pins in CI - that would be a second source of truth.
stray="$(grep -rn 'openvino==\|nncf==' "$root/.github" 2>/dev/null || true)"
if [ -n "$stray" ]; then
  echo "FAIL: workflows pin an OpenVINO/NNCF version literally; use requirements/*.txt" >&2
  printf '%s\n' "$stray" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: no literal openvino/nncf pins in .github"
fi

# 6. CI must install the LOCK, never the .in.
if grep -rn 'pip install -r requirements/[a-z-]*\.in' "$root/.github" >/dev/null 2>&1; then
  echo "FAIL: CI installs a .in source; it must install the compiled .txt lock" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: CI installs compiled locks, not .in sources"
fi

exit "$ASSERT_FAILS"
