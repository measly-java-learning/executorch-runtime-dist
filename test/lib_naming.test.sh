#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/naming.sh"
assert_eq "$(asset_stem 1.3.1 logging linux-x86_64)"   "executorch-runtime-1.3.1-logging-linux-x86_64"            "asset_stem"
assert_eq "$(tarball_name 1.3.1 logging linux-x86_64)" "executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz"      "tarball_name"
assert_eq "$(sha_name 1.3.1 bare linux-x86_64)"        "executorch-runtime-1.3.1-bare-linux-x86_64.tar.gz.sha256"  "sha_name"
exit "$ASSERT_FAILS"
