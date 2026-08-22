#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/licenses.sh"

has() { [ -f "$1" ] && printf 'yes' || printf 'no'; }

# A source tree shaped like ExecuTorch's: notices under the two long-swept roots, plus Eigen
# vendored under kernels/ where it names its files COPYING.* rather than LICENSE*, plus Eigen's
# benchmark harness (bench/btl), which carries its own GPLv2 COPYING that nothing in eigen_blas
# references.
src="$(mktemp -d)"; pfx="$(mktemp -d)"
mkdir -p "$src/third-party/xnnpack" "$src/third-party/gflags" \
         "$src/backends/xnnpack/third-party/FP16" \
         "$src/kernels/optimized/third-party/eigen" \
         "$src/kernels/optimized/third-party/eigen/bench/btl"
mkdir -p "$src/extension/llm/tokenizers/third-party/re2" \
         "$src/extension/llm/tokenizers/build/temp.linux-x86_64-cpython-312/_deps/pybind11-src"
: > "$src/third-party/xnnpack/LICENSE"
: > "$src/third-party/gflags/COPYING.txt"
: > "$src/backends/xnnpack/third-party/FP16/LICENSE"
: > "$src/kernels/optimized/third-party/eigen/LICENSE"
: > "$src/kernels/optimized/third-party/eigen/COPYING.MPL2"
: > "$src/kernels/optimized/third-party/eigen/COPYING.README"
: > "$src/kernels/optimized/third-party/eigen/bench/btl/COPYING"
: > "$src/extension/llm/tokenizers/third-party/re2/LICENSE"
: > "$src/extension/llm/tokenizers/build/temp.linux-x86_64-cpython-312/_deps/pybind11-src/LICENSE"

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

# bench/ is pruned: nothing in eigen_blas compiles the benchmark harness, so its GPLv2 notice must
# not land as if it covered shipped code.
assert_eq "$(has "$n/kernels_optimized_third-party_eigen_bench_btl_COPYING")" "no" "bench dirs are pruned from the sweep"

# The tokenizers dependency stack is vendored under extension/, outside the roots the sweep
# covered for third-party and backends.
assert_eq "$(has "$n/extension_llm_tokenizers_third-party_re2_LICENSE")" "yes" "extension root swept"
# A tokenizers build tree is untracked output: present in a checkout that has been built in,
# absent in a clean CI checkout. Sweeping it would make the notice set depend on that.
assert_eq "$(has "$n/extension_llm_tokenizers_build_temp.linux-x86_64-cpython-312__deps_pybind11-src_LICENSE")" \
  "no" "build residue is pruned"

# Names are path-derived, so two deps' LICENSE files cannot overwrite each other. Still 7: the
# pruned bench/btl notice above must not be among them.
assert_eq "$(ls "$n" | wc -l)" "7" "every notice landed under a distinct name, bench excluded"

# A root a future ET tag drops is skipped, not fatal.
src2="$(mktemp -d)"; pfx2="$(mktemp -d)"
mkdir -p "$src2/third-party/only/here"; : > "$src2/third-party/only/here/LICENSE"
install_third_party_notices "$src2" "$pfx2"; rc=$?
assert_eq "$rc" "0" "absent roots are skipped, not an error"
assert_eq "$(has "$pfx2/THIRD-PARTY-NOTICES/third-party_only_here_LICENSE")" "yes" "sweep continued past the absent roots"

rm -rf "$src" "$pfx" "$src2" "$pfx2"

# --- shipped-archive notice guard ---
# A silent `find` that matches nothing is exactly how the Eigen gap survived 36 notices and several
# releases, so the sweep landing nothing must fail the build rather than pass quietly.
mkprefix() { # <archive-or-empty> <notice-or-empty>  -> echoes the prefix path
  local p; p="$(mktemp -d)"; mkdir -p "$p/lib" "$p/THIRD-PARTY-NOTICES"
  [ -n "$1" ] && : > "$p/lib/$1"
  [ -n "$2" ] && : > "$p/THIRD-PARTY-NOTICES/$2"
  printf '%s' "$p"
}
guard() { assert_shipped_archive_notices "$1" >/dev/null 2>&1 && printf 'pass' || printf 'fail'; }

p_bad="$(mkprefix libeigen_blas.a '')"
assert_eq "$(guard "$p_bad")" "fail" "eigen archive with no notice is refused"

p_ok="$(mkprefix libeigen_blas.a kernels_optimized_third-party_eigen_COPYING.MPL2)"
assert_eq "$(guard "$p_ok")" "pass" "eigen archive with its notice is accepted"

# The notice name is path-derived, so the guard matches the dep, not a path a future tag can move.
p_moved="$(mkprefix libeigen_blas.a some_other_vendoring_path_eigen_LICENSE)"
assert_eq "$(guard "$p_moved")" "pass" "guard matches the dep, not one hard-coded notice path"

# No archive installed -> no obligation. This is what keeps the guard silent on Windows today
# without a platform test in it.
p_none="$(mkprefix '' '')"
assert_eq "$(guard "$p_none")" "pass" "no archive, no obligation"

# The Windows spelling of the same archive carries the same obligation, so enabling the optimized
# kernels on Windows cannot reintroduce the gap.
p_win="$(mkprefix eigen_blas.lib '')"
assert_eq "$(guard "$p_win")" "fail" "windows eigen_blas.lib with no notice is refused"

# The diagnostic has to name the archive; "refusing to ship" with no subject is not actionable.
msg="$(assert_shipped_archive_notices "$p_bad" 2>&1 >/dev/null || true)"
assert_contains "$msg" "libeigen_blas.a" "diagnostic names the offending archive"

rm -rf "$p_bad" "$p_ok" "$p_moved" "$p_none" "$p_win"
exit "$ASSERT_FAILS"
