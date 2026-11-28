#!/usr/bin/env bash
# torch pin (SSOT). Sourced by build-runtime.sh (what gets installed) and package.sh (what BUILDINFO
# records as torch_version), so provenance can never disagree with the install. Bump TORCH_RELEASE
# here when the ET pin moves; nothing else spells the version out.
#
# Every platform installs from PyTorch's CPU index. The index publishes the SAME release under two
# spellings: Linux and Windows wheels carry the `+cpu` local version (torch-2.14.0+cpu-...-
# manylinux_2_28_x86_64.whl), while the macOS wheel has no local version (torch-2.14.0-...-
# macosx_14_0_arm64.whl), because macOS has no CUDA build to tell apart from. pip matches the local
# version exactly, so `torch==2.14.0+cpu` finds nothing on macOS. The macOS wheel's own minimum,
# macOS 14.0, matches macos_deployment_target.
# Source me.

TORCH_RELEASE="2.14.0"
TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"

# The exact version string pip installs, and BUILDINFO records, for <platform>. An unknown platform
# fails instead of defaulting to a spelling that may not exist for it.
torch_version_for_platform() { # <platform>
  case "${1:-}" in
    linux-*|windows-*) printf '%s+cpu' "$TORCH_RELEASE" ;;
    macos-*)           printf '%s' "$TORCH_RELEASE" ;;
    *) echo "torch_version_for_platform: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}
