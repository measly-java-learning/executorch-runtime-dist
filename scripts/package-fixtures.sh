#!/usr/bin/env bash
# Package the arch-independent LSTM fixture set (lstm.pte, in.bin, out.bin, shape)
# into etnp-lstm-fixtures-<etver>.tar.gz + .sha256 (flat: files at tar root).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"

DIR=""; ETVER=""; OUTDIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    DIR="$2"; shift 2 ;;
    --etver)  ETVER="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIR" ] && [ -n "$ETVER" ] || { echo "--dir and --etver required" >&2; exit 2; }
[ -d "$DIR" ] || { echo "package-fixtures.sh: --dir '$DIR' not a directory" >&2; exit 1; }
for m in lstm.pte in.bin out.bin shape; do
  [ -s "$DIR/$m" ] || { echo "package-fixtures.sh: missing fixture member '$m' in $DIR" >&2; exit 1; }
done

mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(fixtures_name "$ETVER")"
tar -C "$DIR" -czf "$TARBALL" lstm.pte in.bin out.bin shape
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
