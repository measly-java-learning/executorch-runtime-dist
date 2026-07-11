#!/usr/bin/env bash
# Asserts a built prefix ships the extras members and that ETNPExtras.cmake is
# relocatable (no absolute build-prefix leaked). PREFIX defaults to out-logging.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$here/../out-logging}"
fail=0
for m in lib/libetnp_ops_lstm.a include/etnp/lstm.h lib/cmake/ETNPExtras/ETNPExtras.cmake \
         THIRD-PARTY-NOTICES/highway_LICENSE; do
  if [ ! -e "$PREFIX/$m" ]; then echo "MISSING: $m"; fail=1; fi
done
# op name baked into the header matches the frozen contract
grep -q 'etnp::lstm.out' "$PREFIX/include/etnp/lstm.h" || { echo "op-name constant missing"; fail=1; }
# relocatable: no absolute prefix path in the shipped config
if grep -q "$(cd "$PREFIX" && pwd)" "$PREFIX/lib/cmake/ETNPExtras/ETNPExtras.cmake" 2>/dev/null; then
  echo "ETNPExtras.cmake leaked an absolute prefix path"; fail=1
fi
[ "$fail" -eq 0 ] && echo "OK: extras members present + relocatable" || exit 1
