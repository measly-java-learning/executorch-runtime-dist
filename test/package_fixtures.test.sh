#!/usr/bin/env bash
# Packages a fixtures dir into etnp-lstm-fixtures-<etver>.tar.gz + .sha256 (flat layout).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# a fake fixtures dir with the 4 expected members
mkdir -p "$tmp/fx"
printf 'PTE'   > "$tmp/fx/lstm.pte"
printf 'IN'    > "$tmp/fx/in.bin"
printf 'OUT'   > "$tmp/fx/out.bin"
printf 'LSTM_T=5\n' > "$tmp/fx/shape"

out="$("$root/scripts/package-fixtures.sh" --dir "$tmp/fx" --etver 1.3.1 --outdir "$tmp/out")" \
  || { echo "package-fixtures.sh failed"; exit 1; }

tb="$tmp/out/etnp-lstm-fixtures-1.3.1.tar.gz"
[ "$out" = "$tb" ] || { echo "stdout path mismatch: $out"; fail=1; }
[ -f "$tb" ] || { echo "MISSING tarball"; fail=1; }
[ -f "$tb.sha256" ] || { echo "MISSING sha256"; fail=1; }
( cd "$tmp/out" && sha256sum -c "etnp-lstm-fixtures-1.3.1.tar.gz.sha256" >/dev/null ) \
  || { echo "sha256 does not verify"; fail=1; }
# flat layout: files at tar root, no leading directory
names="$(tar -tzf "$tb" | sort | tr '\n' ' ')"
[ "$names" = "in.bin lstm.pte out.bin shape " ] || { echo "bad tar members: $names"; fail=1; }
# missing --dir fails non-zero
"$root/scripts/package-fixtures.sh" --dir "$tmp/nope" --etver 1.3.1 --outdir "$tmp/out" 2>/dev/null \
  && { echo "expected failure on missing dir"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: package-fixtures" || exit 1
