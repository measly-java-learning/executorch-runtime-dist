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
