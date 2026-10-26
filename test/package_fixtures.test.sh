#!/usr/bin/env bash
# Packages a fixtures dir into etnp-lstm-fixtures-<etver>.tar.gz + .sha256 (flat layout).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# a fake fixtures dir with the 9 expected members (4 forward + 5 training)
mkdir -p "$tmp/fx"
printf 'PTE'   > "$tmp/fx/lstm.pte"
printf 'IN'    > "$tmp/fx/in.bin"
printf 'OUT'   > "$tmp/fx/out.bin"
printf 'LSTM_T=5\n' > "$tmp/fx/shape"
printf 'TPTE'  > "$tmp/fx/train.pte"
printf 'TPTD'  > "$tmp/fx/train.ptd"
printf 'TIN'   > "$tmp/fx/train_in.bin"
printf 'TOUT'  > "$tmp/fx/train_out.bin"
printf 'TRAIN_T=8\n' > "$tmp/fx/train_shape"

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
want="in.bin lstm.pte out.bin shape train.ptd train.pte train_in.bin train_out.bin train_shape "
[ "$names" = "$want" ] || { echo "bad tar members: $names"; fail=1; }
# a missing training member is a hard failure, not a silently forward-only fixture set
mv "$tmp/fx/train.ptd" "$tmp/fx/train.ptd.gone"
"$root/scripts/package-fixtures.sh" --dir "$tmp/fx" --etver 1.3.1 --outdir "$tmp/out" 2>/dev/null \
  && { echo "expected failure on missing train.ptd"; fail=1; }
mv "$tmp/fx/train.ptd.gone" "$tmp/fx/train.ptd"
# missing --dir fails non-zero
"$root/scripts/package-fixtures.sh" --dir "$tmp/nope" --etver 1.3.1 --outdir "$tmp/out" 2>/dev/null \
  && { echo "expected failure on missing dir"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: package-fixtures" || exit 1
