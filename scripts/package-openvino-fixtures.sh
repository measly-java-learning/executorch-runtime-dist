#!/usr/bin/env bash
# Package the OpenVINO fixture set (openvino_tiny.pte, in.bin, out.bin, shape) into
# etnp-openvino-fixtures-<etver>-<ovver>.tar.gz + .sha256 (flat: files at tar root).
# Mirrors scripts/package-fixtures.sh; separate asset because this one is OpenVINO-version
# coupled and the LSTM one is not.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/openvino.sh"

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
[ -d "$DIR" ] || { echo "package-openvino-fixtures.sh: --dir '$DIR' not a directory" >&2; exit 1; }
for m in openvino_tiny.pte in.bin out.bin shape; do
  [ -s "$DIR/$m" ] || { echo "package-openvino-fixtures.sh: missing fixture member '$m' in $DIR" >&2; exit 1; }
done

mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
TARBALL="$OUTDIR/$(ov_fixtures_name "$ETVER")"
tar -C "$DIR" -czf "$TARBALL" openvino_tiny.pte in.bin out.bin shape
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
printf '%s\n' "$TARBALL"
