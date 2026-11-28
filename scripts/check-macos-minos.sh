#!/usr/bin/env bash
# Assert deployment-target consistency across an installed macOS prefix (release gate). This is
# macOS's counterpart to check-windows-crt.sh.
#
# Every Mach-O object records LC_BUILD_VERSION: platform, minos (minimum OS) and sdk. An object built
# with a higher minos than the consumer's target produces only a linker WARNING ("was built for newer
# macOS version than being linked"), and the binary can then crash on older systems when it calls an
# API that does not exist there. The risk, as with Windows CRTs, is a dependency that ignores the
# top-level setting. The first macOS build proved it is real: the extras phase, a separate CMake
# project, defaulted to the host SDK and shipped libetnp_ops_lstm.a and libhwy.a at minos 26.0 inside
# a 14.0 tarball (spike/2026-11-27-macos-arm64-spike.md finding 1).
#
# The check is POSITIVE, per archive MEMBER: each object must CARRY an LC_BUILD_VERSION for macOS
# with minos <= the target. An object with no LC_BUILD_VERSION (only the legacy
# LC_VERSION_MIN_MACOSX, or nothing) fails. Absence of evidence is not a pass. Each archive must also
# contain exactly the target architecture (no fat archive, no stray x86_64 slice).
#
# The target minos and arch come from the caller, normally from macos_deployment_target/macos_arch
# in scripts/lib/configure-base.sh, so this gate and the build read one SSOT.
#
# Test hooks: MINOS_OTOOL and MINOS_LIPO name the commands run in place of `otool` and `lipo`,
# called exactly as `$MINOS_OTOOL -l <archive>` and `$MINOS_LIPO -archs <archive>`. That lets the
# hermetic test feed canned output on any host.
#
# Usage: check-macos-minos.sh <install-prefix> <minos> <arch>
set -euo pipefail
usage_err() { echo "usage: check-macos-minos.sh <install-prefix> <minos> <arch>" >&2; exit 2; }
PREFIX="${1:-}"; [ -n "$PREFIX" ] || usage_err
MINOS="${2:-}";  [ -n "$MINOS" ]  || usage_err
ARCH="${3:-}";   [ -n "$ARCH" ]   || usage_err
case "$MINOS" in *[!0-9.]*|.*|*.|*..*) echo "FAIL: minos must look like 14.0 (got '$MINOS')" >&2; exit 2 ;; esac
OTOOL="${MINOS_OTOOL:-otool}"
LIPO="${MINOS_LIPO:-lipo}"

command -v "$OTOOL" >/dev/null 2>&1 || { echo "FAIL: $OTOOL not on PATH (Xcode Command Line Tools)" >&2; exit 1; }
command -v "$LIPO"  >/dev/null 2>&1 || { echo "FAIL: $LIPO not on PATH (Xcode Command Line Tools)" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

# Reads `otool -l <archive>` and prints one line per member: "<member> <platform> <minos>", or
# "<member> NONE -" when the member has no LC_BUILD_VERSION. otool prints the platform as a number
# (1 = macOS) in current cctools and as a name in some older ones; both are passed through.
parse_members() {
  awk '
    function flush() { if (m != "") print m, (have ? plat " " min : "NONE -") }
    /^[^ ].*\(.*\):$/ { flush(); m = $0; sub(/^.*\(/, "", m); sub(/\):$/, "", m); have = 0; inbv = 0; next }
    /^[[:space:]]*cmd LC_BUILD_VERSION$/ { inbv = 1; next }
    /^[[:space:]]*cmd / { inbv = 0; next }
    inbv && $1 == "platform" { plat = $2; next }
    inbv && $1 == "minos"    { min = $2; have = 1; inbv = 0; next }
    END { flush() }'
}

# Is version $1 <= version $2? Compares numeric components (14.0 vs 13.5 vs 14.0.1).
version_le() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { p = (i <= na ? x[i] + 0 : 0); q = (i <= nb ? y[i] + 0 : 0)
      if (p < q) exit 0; if (p > q) exit 1 }
    exit 0 }'
}

echo "== deployment-target scan: every object must be macOS, minos <= $MINOS, arch $ARCH only =="
total=0; objs=0; bad=0; failed=0
shopt -s nullglob
for lib in "$PREFIX"/lib/*.a; do
  total=$((total+1))
  name="$(basename "$lib")"

  # Do NOT `|| true` the tool calls: a failing otool/lipo is exactly what this gate must notice.
  set +e
  archs="$("$LIPO" -archs "$lib" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then echo "  ERROR $name -> lipo exited $rc: $archs"; failed=$((failed+1)); continue; fi
  if [ "$archs" != "$ARCH" ]; then echo "  ARCH  $name -> contains [$archs], expected exactly [$ARCH]"; bad=$((bad+1)); fi

  set +e
  out="$("$OTOOL" -l "$lib" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then echo "  ERROR $name -> otool exited $rc"; failed=$((failed+1)); continue; fi
  members="$(parse_members <<< "$out")"
  if [ -z "$members" ]; then echo "  INDET $name -> no archive members found in otool output"; failed=$((failed+1)); continue; fi

  while read -r member plat min; do
    objs=$((objs+1))
    case "$plat" in
      NONE) echo "  INDET $name($member) -> no LC_BUILD_VERSION (legacy LC_VERSION_MIN_MACOSX or none)"; bad=$((bad+1)); continue ;;
      1|MACOS|macos|macOS) ;;
      *) echo "  PLAT  $name($member) -> platform $plat, expected macOS (1)"; bad=$((bad+1)); continue ;;
    esac
    if ! version_le "$min" "$MINOS"; then
      echo "  MINOS $name($member) -> minos $min > $MINOS"; bad=$((bad+1))
    fi
  done <<< "$members"
done

if [ "$total" -eq 0 ]; then echo "FAIL: no lib/*.a under $PREFIX — nothing to check" >&2; exit 1; fi
echo "   archives: $total  objects: $objs  violations: $bad  tool errors: $failed"
if [ "$bad" -ne 0 ] || [ "$failed" -ne 0 ]; then
  echo "FAIL: deployment-target scan found problems (see above)" >&2
  exit 1
fi
echo "PASS: every object is macOS, minos <= $MINOS, $ARCH only"
