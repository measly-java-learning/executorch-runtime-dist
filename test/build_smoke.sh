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
# .ptd writer: the archive, the four consumer headers, and the exported target. Structural only --
# the behavioural proof is test/ptd_writer_run.sh, which the gates run. Both archive spellings:
# POSIX names static libs lib<name>.a, MSVC <name>.lib.
check "serialize archive shipped" \
  "[ -f '$p/lib/libextension_flat_tensor_serialize.a' ] || [ -f '$p/lib/extension_flat_tensor_serialize.lib' ]"
check "serialize.h installed" \
  "[ -f '$p/include/executorch/extension/flat_tensor/serialize/serialize.h' ]"
check "flat_tensor_header.h installed" \
  "[ -f '$p/include/executorch/extension/flat_tensor/serialize/flat_tensor_header.h' ]"
check "flat_tensor_data_map.h installed" \
  "[ -f '$p/include/executorch/extension/flat_tensor/flat_tensor_data_map.h' ]"
check "merged_data_map.h installed" \
  "[ -f '$p/include/executorch/extension/named_data_map/merged_data_map.h' ]"
check "writer target exported" \
  "grep -q 'extension_flat_tensor_serialize' '$p/lib/cmake/ExecuTorch/ExecuTorchTargets.cmake'"
# nm is POSIX-only; on an MSVC prefix dumpbin would be the equivalent and this manual smoke is not
# run there (the shipped Windows behaviour is gated by test/ptd_writer_run-windows.sh).
if command -v nm >/dev/null 2>&1 && [ -f "$p/lib/libextension_flat_tensor_serialize.a" ]; then
  check "save_ptd symbol defined" \
    "nm -C --defined-only '$p/lib/libextension_flat_tensor_serialize.a' 2>/dev/null | grep -q 'save_ptd'"
fi
if [ "$fails" -eq 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL ($fails)" >&2; exit 1; fi
