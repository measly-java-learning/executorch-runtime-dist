#!/usr/bin/env bash
# Structural smoke on a built et-install prefix. Usage: build_smoke.sh <prefix>
set -u
p="${1:?usage: build_smoke.sh <prefix>}"
fails=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fails=$((fails+1)); fi; }
check "cmake config present"        "[ -f '$p/lib/cmake/ExecuTorch/executorch-config.cmake' ]"
check "include dir present"         "[ -d '$p/include' ]"
check "lib dir present"             "[ -d '$p/lib' ]"
check "LICENSE shipped"             "[ -f '$p/LICENSE' ]"
check "THIRD-PARTY-NOTICES present" "[ -d '$p/THIRD-PARTY-NOTICES' ]"
check ".et_commit recorded"         "[ -s '$p/.et_commit' ]"
check "no absolute prefix in cmake" "! grep -rq '$p' '$p/lib/cmake'"
if [ "$fails" -eq 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL ($fails)" >&2; exit 1; fi
