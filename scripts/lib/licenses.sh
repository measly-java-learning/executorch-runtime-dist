#!/usr/bin/env bash
# Third-party license passthrough into a built prefix's THIRD-PARTY-NOTICES/ (contract C2).
# Single source of truth: build-runtime.sh sources this rather than inlining a find/cp loop, so the
# sweep is reachable by the hermetic unit suite without a 15-minute ExecuTorch compile.
# Source me.

# ExecuTorch source dirs swept for notice files, i.e. every vendoring root. `kernels` is here
# because Eigen is vendored at kernels/optimized/third-party/eigen and libeigen_blas.a ships in
# every Linux tarball; `extension` is here because the tokenizers dependency stack is vendored at
# extension/llm/tokenizers/third-party/. Each root is swept wholesale rather than pinned to one
# path, so a dep vendored elsewhere under it is caught too.
ET_NOTICE_ROOTS='third-party backends kernels extension'

# Directory names pruned from the sweep. Each entry here is justified by a concrete notice file
# that would otherwise claim a license obligation the artifact does not carry: `bench` prunes
# kernels/optimized/third-party/eigen/bench/btl/COPYING, the GPLv2 notice of Eigen's benchmark
# harness, which is not compiled into the shipped lib/; `build` prunes a vendored dep's build tree,
# untracked output that exists only in a checkout that was built in, so sweeping it would make the
# notice set depend on whether the checkout was built in.
ET_NOTICE_PRUNE_DIRS='bench build'

# Copy every LICENSE*/COPYING* under ET_NOTICE_ROOTS into <prefix>/THIRD-PARTY-NOTICES/, named by
# its path relative to the source tree with slashes turned into underscores, so two deps' LICENSE
# files cannot collide. COPYING* is swept alongside LICENSE* because Eigen carries its notices as
# COPYING.APACHE/BSD/MINPACK/MPL2/README, and COPYING.README is the file that says which portions
# are under which license.
install_third_party_notices() { # <et_src> <prefix>
  local et_src="$1" prefix="$2" d prune_expr=() name rel
  for name in $ET_NOTICE_PRUNE_DIRS; do
    [ ${#prune_expr[@]} -eq 0 ] || prune_expr+=(-o)
    prune_expr+=(-name "$name")
  done
  mkdir -p "$prefix/THIRD-PARTY-NOTICES"
  for d in $ET_NOTICE_ROOTS; do
    # guard each dir (a future ET tag may drop/rename one) so a bare `find | while` can't abort the
    # recipe under set -e/pipefail with its stderr masked; `|| true` covers any residual find failure.
    [ -d "$et_src/$d" ] || continue
    find "$et_src/$d" \( -type d \( "${prune_expr[@]}" \) -prune \) -o \
      \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -type f -print | while read -r lf; do
      rel="${lf#"$et_src"/}"
      cp "$lf" "$prefix/THIRD-PARTY-NOTICES/${rel//\//_}"
    done || true
  done
}

# Archives that carry a notice obligation, as <archive-basename>|<notice-substring>. Keyed off what
# is installed, never off the platform: Windows ships no eigen_blas.lib today only because
# configure-base.sh omits KERNELS_OPTIMIZED, and the day it does not, this covers it unchanged.
# libeigen_blas.a is MPL-2.0 Eigen, reached through optimized_kernels -> cpublas -> eigen_blas, which
# is the chain behind optimized_native_cpu_ops_lib — the ops lib consumers are told to whole-archive.
# Tokenizer-stack archives. Each needle is a <dep>_<noticefile> tail rather than a full path, so it
# survives a vendoring-path move: the notice lands in THIRD-PARTY-NOTICES/ under a path-derived name,
# and the needle matches whatever path upstream vendors the dep under. libre2.a uses _re2_LICENSE
# specifically because a bare `re2` also matches the pcre2 notice (pcre2's name ends in "re2"), which
# would let a missing re2 notice pass whenever pcre2's is present.
_ET_LICENSED_ARCHIVES='libeigen_blas.a|eigen eigen_blas.lib|eigen
libabsl_base.a|abseil-cpp_LICENSE
libsentencepiece.a|sentencepiece_LICENSE
libre2.a|_re2_LICENSE
libpcre2-8.a|pcre2_COPYING
libtokenizers.a|tokenizers_LICENSE'

# Fail when an archive above is installed and the sweep landed no matching notice. The whole point
# is that a `find` matching nothing is loud: without this, a moved upstream vendoring path silently
# produces an unlicensed tarball, which is what issue #45 was.
assert_shipped_archive_notices() { # <prefix>
  local prefix="$1" entry archive needle fail=0
  for entry in $_ET_LICENSED_ARCHIVES; do
    archive="${entry%%|*}"; needle="${entry##*|}"
    [ -f "$prefix/lib/$archive" ] || continue
    if [ -z "$(find "$prefix/THIRD-PARTY-NOTICES" -maxdepth 1 -type f -iname "*$needle*" 2>/dev/null | head -n1)" ]; then
      echo ">> ERROR: lib/$archive is installed but no *$needle* notice landed in" >&2
      echo "   $prefix/THIRD-PARTY-NOTICES/ — refusing to ship it without its license." >&2
      echo "   The upstream vendoring path likely moved. Locate it with:" >&2
      echo "     find \$ET_SRC -ipath '*$needle*' \\( -iname 'LICENSE*' -o -iname 'COPYING*' \\)" >&2
      echo "   then add its root to ET_NOTICE_ROOTS in scripts/lib/licenses.sh." >&2
      fail=1
    fi
  done
  [ "$fail" -eq 0 ]
}
