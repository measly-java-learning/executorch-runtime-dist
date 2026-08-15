#!/usr/bin/env bash
# Hermetic: packaging logic only. Stubs the four fixture members rather than running a real
# torch export, which needs the heavy AOT venv and belongs in CI.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/openvino.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fx"
printf 'PTE-STUB\n' > "$tmp/fx/openvino_tiny.pte"
printf 'IN\n'  > "$tmp/fx/in.bin"
printf 'OUT\n' > "$tmp/fx/out.bin"
printf 'OV_IN=8\nOV_OUT=8\n' > "$tmp/fx/shape"

tb="$(bash "$here/../scripts/package-openvino-fixtures.sh" --dir "$tmp/fx" --etver 1.3.1 --outdir "$tmp/out")" \
  || { echo "FAIL: packaging exited non-zero"; exit 1; }
assert_eq "$(basename "$tb")" "$(ov_fixtures_name 1.3.1)" "tarball uses the C10 fixtures name"
[ -f "$tb.sha256" ] && printf 'ok: sha256 sidecar written\n' \
  || { printf 'FAIL: sha256 sidecar missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# Flat layout (files at tar root), matching etnp-lstm-fixtures.
members="$(tar -tzf "$tb" | sort | tr '\n' ' ')"
assert_eq "$members" "in.bin openvino_tiny.pte out.bin shape " "flat member list"

# A missing member must abort rather than ship an incomplete fixture set.
rm "$tmp/fx/out.bin"
bash "$here/../scripts/package-openvino-fixtures.sh" --dir "$tmp/fx" --etver 1.3.1 --outdir "$tmp/out2" >/dev/null 2>&1
assert_eq "$?" "1" "missing fixture member aborts"
exit "$ASSERT_FAILS"
