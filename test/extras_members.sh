#!/usr/bin/env bash
# Asserts a built prefix ships the extras members and that ETNPExtras.cmake is
# relocatable (no absolute build-prefix leaked). PREFIX defaults to out-logging.
#
# NOT named *.test.sh on purpose: it needs a BUILT PREFIX and so is not hermetic, which is the
# same reason build_smoke.sh, relocatability.sh, usdt_probe_smoke.sh, openvino_smoke.sh and
# xnnpack_workspace_run.sh are excluded from test/run.sh's glob. It carried the .test.sh name for
# months and therefore failed run.sh in any checkout without a build — a standing red that trained
# everyone to read "1 test file(s) FAILED" as normal. See issue #24.
#
# Run it against a real prefix:  PREFIX=/path/to/out bash test/extras_members.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$here/../out-logging}"
fail=0
for m in lib/libetnp_ops_lstm.a lib/libhwy.a include/etnp/lstm.h lib/cmake/ETNPExtras/ETNPExtras.cmake \
         THIRD-PARTY-NOTICES/highway_LICENSE; do
  if [ ! -e "$PREFIX/$m" ]; then echo "MISSING: $m"; fail=1; fi
done
# libeigen_blas.a is MPL-2.0 Eigen and ships in every Linux tarball that builds the optimized
# kernels. Its notice is named after the upstream vendoring path, so match the dep rather than a
# path a future ET tag can move. Presence-driven, so a prefix without the archive is silent.
if [ -f "$PREFIX/lib/libeigen_blas.a" ] && \
   [ -z "$(find "$PREFIX/THIRD-PARTY-NOTICES" -maxdepth 1 -type f -iname '*eigen*' 2>/dev/null | head -n1)" ]; then
  echo "MISSING: THIRD-PARTY-NOTICES entry for libeigen_blas.a (Eigen, MPL-2.0)"; fail=1
fi
# op name baked into the header matches the frozen contract
grep -q 'etnp::lstm.out' "$PREFIX/include/etnp/lstm.h" || { echo "op-name constant missing"; fail=1; }
# relocatable: no absolute prefix path in the shipped config
if grep -q "$(cd "$PREFIX" && pwd)" "$PREFIX/lib/cmake/ETNPExtras/ETNPExtras.cmake" 2>/dev/null; then
  echo "ETNPExtras.cmake leaked an absolute prefix path"; fail=1
fi
[ "$fail" -eq 0 ] && echo "OK: extras members present + relocatable" || exit 1
