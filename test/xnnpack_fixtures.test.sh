#!/usr/bin/env bash
# The emitter needs torch + executorch, which the hermetic suite does not have. What IS checkable
# without them is the contract that makes the fixture worth having: that it asserts the delegate
# was applied, that its model allocates a real workspace, and that its member names match what the
# gate script reads.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
src="$(cat "$here/../scripts/emit-xnnpack-fixtures.py")"

assert_contains "$src" 'XnnpackPartitioner' "uses the XNNPACK partitioner"
# Without this guard a partitioner that declined every node yields a valid .pte that allocates no
# workspace -- the gate would then pass against a completely broken accessor.
assert_contains "$src" 'b"XnnpackBackend" not in pte' "asserts the delegate was actually applied"
# The fixture model must ALLOCATE a real workspace. A Linear+ReLU delegates but needs no workspace
# on the pinned ET (direct GEMM, statically packed weights), so the gate would read 0 after load and
# fail on a CORRECT build -- the exact vacuous-fixture defect this gate exists to prevent.
assert_contains "$src" 'Conv2d' "fixture model allocates a real workspace"
case "$src" in
  *'torch.nn.Linear'*) printf 'FAIL: fixture must not use the vacuous Linear model\n' >&2
                       ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: fixture avoids the vacuous Linear model\n' ;;
esac
for m in 'xnnpack_tiny.pte' 'in.bin' 'out.bin' 'shape' 'XNN_IN_DIMS=' 'XNN_OUT_DIMS='; do
  assert_contains "$src" "$m" "emits $m"
done
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$here/../scripts/emit-xnnpack-fixtures.py"
assert_eq "$?" "0" "emitter parses as python"
exit "$ASSERT_FAILS"
