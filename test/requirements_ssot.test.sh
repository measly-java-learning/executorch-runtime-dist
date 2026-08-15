#!/usr/bin/env bash
# requirements/openvino-*.txt are GENERATED from scripts/lib/openvino.sh. Assert they are current.
#
# The failure this prevents: someone bumps OV_VERSION for the vendored bundle and does not
# regenerate, so fixtures get exported with one OpenVINO wheel and replayed against a bundle built
# from another. That mismatch usually still loads, so no gate would notice.
#
# Also asserts no workflow spells an OpenVINO/NNCF version literally - a hardcoded `openvino==...`
# in CI would reintroduce the second source of truth this file exists to remove.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
root="$(cd "$here/.." && pwd)"

if "$root/scripts/gen-requirements.sh" --check >/dev/null 2>&1; then
  echo "ok: requirements/openvino-*.txt match the openvino.sh SSOT"
else
  echo "FAIL: requirements/openvino-*.txt are stale (run scripts/gen-requirements.sh)" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# The generator must be able to FAIL, or the check above is decorative.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$root/requirements/openvino-aot.txt" "$tmp/backup"
sed -i 's/^openvino==.*/openvino==0.0.0/' "$root/requirements/openvino-aot.txt"
if "$root/scripts/gen-requirements.sh" --check >/dev/null 2>&1; then
  echo "FAIL: --check passed on a tampered requirements file" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: --check detects a drifted version"
fi
cp "$tmp/backup" "$root/requirements/openvino-aot.txt"

# No literal OpenVINO/NNCF pins outside the generated files.
stray="$(grep -rn 'openvino==\|nncf==' "$root/.github" 2>/dev/null || true)"
if [ -n "$stray" ]; then
  echo "FAIL: workflows pin an OpenVINO/NNCF version literally; use requirements/openvino-*.txt" >&2
  printf '%s\n' "$stray" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: no literal openvino/nncf pins in .github"
fi

exit "$ASSERT_FAILS"
