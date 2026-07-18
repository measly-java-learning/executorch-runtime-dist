#!/usr/bin/env bash
# SPIKE (throwaway). The DEFINITIVE CRT-propagation verdict: scan every installed static lib's
# embedded linker directives (dumpbin /directives) and prove they all request the expected CRT.
#
# CORRECTED 2026-07-18. The original version of this script produced a FALSE PASS: dumpbin was
# failing on every lib (rc=157) because Git-Bash's MSYS path conversion rewrote `/nologo` into
# `C:\Program Files\Git\nologo`, and the negative-only check read the resulting silence as success.
# Flags are now passed in `-dash` form and the assertion is POSITIVE. See FINDINGS.md.
#
# MSVC records the CRT choice per-object as /DEFAULTLIB directives:
#   /MT  (static) -> LIBCMT  / LIBCPMT
#   /MD  (dynamic)-> MSVCRT  / MSVCPRT
# A clean /MT build shows ONLY the static markers. If ANY lib requests MSVCRT/MSVCPRT while we asked
# for /MT, that subproject hardcoded /MD and our flag did NOT propagate — the go/no-go signal, and it
# names exactly which lib to chase (or which upstream patch we'd have to carry).
#
# Run inside Git-Bash from an activated VS dev shell.
# Usage: check-crt.sh <install-prefix> [MultiThreaded|MultiThreadedDLL]
set -euo pipefail
PREFIX="${1:?usage: check-crt.sh <install-prefix> [MultiThreaded|MultiThreadedDLL]}"
CRT="${2:-MultiThreaded}"
command -v dumpbin >/dev/null 2>&1 || { echo "FAIL: dumpbin not on PATH — run inside an activated VS dev shell" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

# Markers are mixed-case in real output (LIBCMT but libcpmt) -> match -i. C-only libs carry LIBCMT
# with no LIBCPMT, so the expected pattern is an OR, never a requirement for both.
case "$CRT" in
  MultiThreaded)    want_re='LIBCMT|LIBCPMT'; bad_re='MSVCRT|MSVCPRT'; want="static (LIBCMT/LIBCPMT)" ;;
  MultiThreadedDLL) want_re='MSVCRT|MSVCPRT'; bad_re='LIBCMT|LIBCPMT'; want="dynamic (MSVCRT/MSVCPRT)" ;;
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL" >&2; exit 2 ;;
esac

echo "== CRT directive scan: every lib must carry $want across $PREFIX/lib =="
ok=0; leaks=0; indeterminate=0; failed=0; scanned=0
while IFS= read -r lib; do
  scanned=$((scanned+1))
  name="$(basename "$lib")"
  # -nologo -directives, NOT /nologo /directives: MSYS rewrites a leading '/' to a Windows path.
  # No `|| true` here — a dumpbin failure is precisely what this gate must notice.
  set +e
  out="$(dumpbin -nologo -directives "$lib" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  ERROR $name -> dumpbin exited $rc"; printf '%s\n' "$out" | sed 's/^/          /' | head -3
    failed=$((failed+1)); continue
  fi
  if printf '%s' "$out" | grep -Eqi "$bad_re"; then
    echo "  LEAK  $name -> requests $(printf '%s' "$out" | grep -Eoi "$bad_re" | sort -u | paste -sd, -)"
    leaks=$((leaks+1))
  elif printf '%s' "$out" | grep -Eqi "$want_re"; then
    ok=$((ok+1))
  else
    echo "  INDET $name -> no CRT directive at all"; indeterminate=$((indeterminate+1))
  fi
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.lib')

echo "-- scanned $scanned: ok=$ok leaks=$leaks indeterminate=$indeterminate dumpbin_failures=$failed --"
[ "$scanned" -gt 0 ]       || { echo "FAIL: no .lib files under $PREFIX/lib" >&2; exit 1; }
[ "$failed" -eq 0 ]        || { echo "FAIL: dumpbin failed on $failed lib(s); the scan proved nothing." >&2; exit 1; }
[ "$leaks" -eq 0 ]         || { echo "FAIL: $leaks lib(s) request the wrong CRT for $CRT." >&2; exit 1; }
[ "$indeterminate" -eq 0 ] || { echo "FAIL: $indeterminate lib(s) carry no CRT directive; cannot certify." >&2; exit 1; }
[ "$ok" -eq "$scanned" ]   || { echo "FAIL: only $ok/$scanned libs positively confirmed." >&2; exit 1; }
echo "CRT CHECK: PASS — all $scanned libs positively carry $want."
