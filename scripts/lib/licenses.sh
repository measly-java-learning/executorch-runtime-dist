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
