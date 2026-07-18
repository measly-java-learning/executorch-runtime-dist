#!/usr/bin/env bash
# SPIKE (throwaway). The DEFINITIVE CRT-propagation verdict: scan every installed static lib's
# embedded linker directives (dumpbin /directives) and prove they all request the expected CRT.
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

case "$CRT" in
  MultiThreaded)    want="static (LIBCMT/LIBCPMT)";  bad_re='MSVCRT|MSVCPRT' ;;   # want /MT; MSVC*RT = a /MD leak
  MultiThreadedDLL) want="dynamic (MSVCRT/MSVCPRT)"; bad_re='LIBCMT|LIBCPMT' ;;   # want /MD; LIB*MT = a /MT leak
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL" >&2; exit 2 ;;
esac

echo "== CRT directive scan: expecting $want across $PREFIX/lib =="
leaks=0; scanned=0
# ET's static archives live directly in lib/ (portable_kernels, xnnpack_backend, pthreadpool, cpuinfo,
# flatccrt, executorch(_core), extension_*, XNNPACK, tokenizers, pcre2, ...).
while IFS= read -r lib; do
  scanned=$((scanned+1))
  dir="$(dumpbin /nologo /directives "$lib" 2>/dev/null || true)"
  hit="$(printf '%s' "$dir" | grep -Eio "$bad_re" | sort -u | paste -sd, - || true)"
  if [ -n "$hit" ]; then
    echo "  LEAK  $(basename "$lib")  -> requests $hit"
    leaks=$((leaks+1))
  fi
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.lib')

echo "-- scanned $scanned static libs, $leaks with a wrong-CRT directive --"
if [ "$leaks" -ne 0 ]; then
  echo "CRT CHECK: FAIL — $leaks lib(s) did not honor CRT=$CRT. Propagation is NOT clean; see names above." >&2
  exit 1
fi
echo "CRT CHECK: PASS — all $scanned libs request $want. Propagation is clean for CRT=$CRT."
