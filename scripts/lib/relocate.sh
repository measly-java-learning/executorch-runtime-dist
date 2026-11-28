#!/usr/bin/env bash
# Relocatability scans over an installed prefix's exported CMake configs. Sourced by
# build-runtime.sh; the hermetic test drives the same function against a fake prefix.
# Source me.

# Absolute Apple SDK / toolchain paths in <dir>, one `file:line:match` per hit; empty means clean.
# Each consumer has a different Xcode or Command Line Tools install, and the SDK path even encodes
# its version (MacOSX26.5.sdk). A config that bakes one in breaks every consumer's link, the macOS
# analogue of the /usr/lib64/libm.so leak the Linux path rewrites. Spike-verified: ET v1.5.1 leaks
# none (nothing in the feature set links a framework), so build-runtime.sh treats any hit as a hard
# failure rather than rewriting it; when a future pin introduces one, decide its rewrite (-framework X,
# -l<name>) deliberately. The patterns are Apple-specific, so the scan is safe on every host.
# `|| true`: grep exits 1 on no match, which must not abort the caller under set -e/pipefail.
toolchain_path_leaks() { # <dir>
  [ -d "$1" ] || { echo "toolchain_path_leaks: not a directory: '$1'" >&2; return 2; }
  grep -rnoE '/Applications/Xcode[^/]*\.app/[^ ;"]*|/Library/Developer/CommandLineTools/[^ ;"]*|[^ ;"]*\.sdk(/[^ ;"]*)?' "$1" 2>/dev/null || true
}
