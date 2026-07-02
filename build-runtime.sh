#!/usr/bin/env bash
# build-runtime.sh — ExecuTorch runtime recipe entrypoint (contract C8).
# MUST run INSIDE manylinux_2_28 (quay.io/pypa/manylinux_2_28_x86_64); the caller owns the container.
# Produces a relocatable, position-independent et-install tree at --prefix.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/variants.sh"

DEFAULT_ET_TAG="v1.3.1"
PLATFORM="linux-x86_64"          # C4; single platform for now
TORCH_SPEC="torch==2.12.0+cpu"

usage() {
  cat <<'EOF'
Usage: build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> [--et-tag <tag>]
       build-runtime.sh --print-flags --variant <variant>    # dry: print effective cmake flags, no build
Must run inside manylinux_2_28. --et-tag defaults to v1.3.1.
EOF
}

VARIANT=""; PREFIX=""; ET_TAG="$DEFAULT_ET_TAG"; PRINT_FLAGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --prefix)  PREFIX="${2:-}"; shift 2 ;;
    --et-tag)  ET_TAG="${2:-}"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "--variant required" >&2; exit 2; }
VARIANT_FLAGS="$(variant_flags "$VARIANT")"   # returns 2 on unknown -> set -e aborts with code 2

if [ "$PRINT_FLAGS" -eq 1 ]; then
  printf '%s\n' "$VARIANT_FLAGS"
  exit 0
fi

[ -n "$PREFIX" ] || { echo "--prefix required" >&2; exit 2; }

# ---- Task 3 appends the real build below this line ----
