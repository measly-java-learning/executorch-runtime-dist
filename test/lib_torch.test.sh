#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/torch.sh"
root="$(cd "$here/.." && pwd)"

for p in linux-x86_64 linux-aarch64 windows-x86_64 windows-x86_64-static; do
  assert_eq "$(torch_version_for_platform "$p")" "${TORCH_RELEASE}+cpu" "$p installs the +cpu wheel"
done
# The macOS wheel on the CPU index has no local version; `+cpu` would match nothing.
assert_eq "$(torch_version_for_platform macos-arm64)" "$TORCH_RELEASE" "macos-arm64 installs the plain-version wheel"
torch_version_for_platform bogus-plat >/dev/null 2>&1; assert_eq "$?" "2" "unknown platform returns 2"
torch_version_for_platform >/dev/null 2>&1;            assert_eq "$?" "2" "missing platform returns 2"
assert_eq "$TORCH_INDEX_URL" "https://download.pytorch.org/whl/cpu" "every platform uses the CPU index"

# SSOT: no script spells the torch version out itself. build-runtime.sh and package.sh must go
# through torch.sh, which is the point of this file (BUILDINFO said +cpu on macOS before it existed).
stray="$(grep -nE 'torch==[0-9]|TORCH_VERSION="[0-9]|TORCH_SPEC=' "$root/build-runtime.sh" "$root/scripts/package.sh" || true)"
assert_eq "$stray" "" "build-runtime.sh and package.sh do not hardcode a torch version"
grep -q 'torch_version_for_platform' "$root/build-runtime.sh"; assert_eq "$?" "0" "build-runtime.sh installs via torch.sh"
grep -q 'torch_version_for_platform' "$root/scripts/package.sh"; assert_eq "$?" "0" "package.sh records via torch.sh"
exit "$ASSERT_FAILS"
