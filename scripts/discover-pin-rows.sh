#!/usr/bin/env bash
# Discover built release artifacts in a dist dir and emit pin rows for gen-pin.sh.
# One line per <dir>/executorch-runtime-<etver>-<variant>-<platform>.tar.gz.sha256:
#   variant<TAB>platform<TAB>sha   (sorted platform then variant, deterministic)
# naming.sh owns the scheme; each parsed (variant,platform) is validated by reconstructing
# the expected basename via tarball_name and failing loudly on any mismatch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/naming.sh"

DIR=""; ETVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="${2:-}"; shift 2 ;;
    --etver) ETVER="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${DIR:?--dir required}"; : "${ETVER:?--etver required}"
[ -d "$DIR" ] || { echo "discover-pin-rows: --dir '$DIR' is not a directory" >&2; exit 1; }

prefix="executorch-runtime-${ETVER}-"
# Collect rows first so we can fail loudly on an empty result (a broken artifact
# download must abort the release, not ship an empty EtRuntimePin.cmake). A parse
# mismatch or malformed sha inside the subshell exits non-zero, which aborts the
# assignment under set -e.
rows="$(
  for sha in "$DIR"/*.tar.gz.sha256; do
    [ -e "$sha" ] || continue                 # glob no-match guard (set -e safe)
    b="$(basename "$sha")"
    rest="${b#"$prefix"}"                      # strip known prefix
    [ "$rest" != "$b" ] || continue           # different etver / not our scheme -> skip
    rest="${rest%.tar.gz.sha256}"             # -> <variant>-<platform>
    variant="${rest%%-*}"                     # variants never contain '-'
    platform="${rest#*-}"                     # platforms may (linux-x86_64, windows-x86_64)
    [ "$(tarball_name "$ETVER" "$variant" "$platform").sha256" = "$b" ] \
      || { echo "discover-pin-rows: parse mismatch for '$b'" >&2; exit 1; }
    sha_hex="$(cut -d' ' -f1 "$sha")"
    case "$sha_hex" in
      ""|*[!0-9a-f]*) echo "discover-pin-rows: '$b' has malformed sha256 ('$sha_hex')" >&2; exit 1 ;;
    esac
    [ "${#sha_hex}" -eq 64 ] \
      || { echo "discover-pin-rows: '$b' sha256 is not 64 hex chars ('$sha_hex')" >&2; exit 1; }
    printf '%s\t%s\t%s\n' "$variant" "$platform" "$sha_hex"
  done
)"
[ -n "$rows" ] \
  || { echo "discover-pin-rows: no artifacts matched '${prefix}*.tar.gz.sha256' in '$DIR'" >&2; exit 1; }
printf '%s\n' "$rows" | sort -t"$(printf '\t')" -k2,2 -k1,1
