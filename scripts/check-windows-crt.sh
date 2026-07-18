#!/usr/bin/env bash
# Assert CRT consistency across an installed Windows prefix (release gate).
#
# MSVC records the CRT choice per-object as /DEFAULTLIB directives:
#   /MT  (static)  -> LIBCMT  / LIBCPMT
#   /MD  (dynamic) -> MSVCRT  / MSVCPRT
# Every statically-linked object in a downstream DLL must agree, so one lib requesting the wrong CRT
# makes the artifact unlinkable for its intended consumer (LNK4098/LNK2005).
#
# This check is deliberately POSITIVE: each lib must CARRY the expected marker. An earlier
# negative-only version ("no wrong marker found") reported PASS on 18 libs while dumpbin was failing
# on every one of them — absence of evidence read as evidence of absence.
#
# NOTE: flags are passed as -nologo -directives, NOT /nologo /directives. Under Git-Bash, MSYS path
# conversion rewrites a leading '/' into a Windows path (/nologo -> C:\Program Files\Git\nologo), so
# the slash form silently feeds dumpbin a garbage filename. MSVC accepts '-' for all options.
#
# Run inside Git-Bash from an activated VS dev shell (needs dumpbin).
# Usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>
set -euo pipefail
PREFIX="${1:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
CRT="${2:?usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>}"
command -v dumpbin >/dev/null 2>&1 || { echo "FAIL: dumpbin not on PATH — run inside an activated VS dev shell" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

# Markers are mixed-case in real dumpbin output (LIBCMT but libcpmt), so all matching is -i.
# A C-only lib (cpuinfo, pthreadpool, xnnpack-microkernels-prod) carries LIBCMT with no LIBCPMT,
# so the expected pattern is an OR, never a requirement for both.
case "$CRT" in
  MultiThreaded)    want_re='LIBCMT|LIBCPMT';  bad_re='MSVCRT|MSVCPRT'; want="static (LIBCMT/LIBCPMT)" ;;
  MultiThreadedDLL) want_re='MSVCRT|MSVCPRT';  bad_re='LIBCMT|LIBCPMT'; want="dynamic (MSVCRT/MSVCPRT)" ;;
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL (got '$CRT')" >&2; exit 2 ;;
esac

echo "== CRT directive scan: every lib must carry $want =="
ok=0; leaks=0; indeterminate=0; failed=0; total=0
while IFS= read -r lib; do
  total=$((total+1))
  name="$(basename "$lib")"
  # Capture stdout+stderr AND the exit status. Do NOT `|| true` here: a dumpbin failure is exactly
  # the condition this gate exists to notice, and swallowing it is what made the old scan useless.
  set +e
  out="$(dumpbin -nologo -directives "$lib" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  ERROR $name -> dumpbin exited $rc:"
    printf '%s\n' "$out" | sed 's/^/          /' | head -5
    failed=$((failed+1)); continue
  fi
  if printf '%s' "$out" | grep -Eqi "$bad_re"; then
    echo "  LEAK  $name -> requests $(printf '%s' "$out" | grep -Eoi "$bad_re" | sort -u | paste -sd, -)"
    leaks=$((leaks+1))
  elif printf '%s' "$out" | grep -Eqi "$want_re"; then
    ok=$((ok+1))
  else
    echo "  INDET $name -> no CRT directive at all (expected $want)"
    indeterminate=$((indeterminate+1))
  fi
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.lib')

echo "-- scanned $total: ok=$ok leaks=$leaks indeterminate=$indeterminate dumpbin_failures=$failed --"
[ "$total" -gt 0 ]        || { echo "FAIL: no .lib files under $PREFIX/lib — wrong prefix?" >&2; exit 1; }
[ "$failed" -eq 0 ]       || { echo "FAIL: dumpbin failed on $failed lib(s); the scan proved nothing." >&2; exit 1; }
[ "$leaks" -eq 0 ]        || { echo "FAIL: $leaks lib(s) request the wrong CRT for $CRT." >&2; exit 1; }
[ "$indeterminate" -eq 0 ] || { echo "FAIL: $indeterminate lib(s) carry no CRT directive; cannot certify." >&2; exit 1; }
[ "$ok" -eq "$total" ]    || { echo "FAIL: only $ok/$total libs positively confirmed." >&2; exit 1; }
echo "CRT CHECK: PASS — all $total libs positively carry $want."
