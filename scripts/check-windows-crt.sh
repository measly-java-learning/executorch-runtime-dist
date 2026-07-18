#!/usr/bin/env bash
# Assert CRT consistency across an installed Windows prefix (release gate).
#
# MSVC records the CRT choice per-object as /DEFAULTLIB directives:
#   /MT  (static)  -> LIBCMT  / LIBCPMT
#   /MD  (dynamic) -> MSVCRT  / MSVCPRT
# Every statically-linked object in a downstream DLL must agree, but a mismatch is NOT reliably
# caught at link time — measured on a real /MT prefix, a /MD consumer linked cleanly against it with
# no LNK2005 and not even an LNK4098 warning. The real hazard is at runtime: two CRTs, two heaps, and
# corruption when an allocation crosses the boundary. That is why this scan inspects /DEFAULTLIB
# directives directly instead of relying on the linker to notice.
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
# bash's ${x:?} exits 1 on a missing argument; repo convention reserves 2 for usage errors (matches
# build-runtime.sh/package.sh/gen-pin.sh), so usage is checked explicitly instead.
usage_err() { echo "usage: check-windows-crt.sh <install-prefix> <MultiThreaded|MultiThreadedDLL>" >&2; exit 2; }
PREFIX="${1:-}"; [ -n "$PREFIX" ] || usage_err
CRT="${2:-}"; [ -n "$CRT" ] || usage_err
# Argument validation must precede environment checks, so a bad CRT value reports the actionable
# "CRT must be ..." error (rc=2) rather than an unrelated environment guard failure (rc=1).
# Markers are mixed-case in real dumpbin output (LIBCMT but libcpmt), so all matching is -i.
# A C-only lib (cpuinfo, pthreadpool, xnnpack-microkernels-prod) carries LIBCMT with no LIBCPMT,
# so the expected pattern is an OR, never a requirement for both.
case "$CRT" in
  MultiThreaded)    want_re='LIBCMT|LIBCPMT';  bad_re='MSVCRT|MSVCPRT'; want="static (LIBCMT/LIBCPMT)" ;;
  MultiThreadedDLL) want_re='MSVCRT|MSVCPRT';  bad_re='LIBCMT|LIBCPMT'; want="dynamic (MSVCRT/MSVCPRT)" ;;
  *) echo "FAIL: CRT must be MultiThreaded or MultiThreadedDLL (got '$CRT')" >&2; exit 2 ;;
esac

command -v dumpbin >/dev/null 2>&1 || { echo "FAIL: dumpbin not on PATH — run inside an activated VS dev shell" >&2; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "FAIL: no lib/ under $PREFIX" >&2; exit 1; }

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
    # head is the producer here (bounded to 5 lines) and sed is a non-early-exiting consumer that
    # reads all of head's output before exiting, so there is no writer left upstream to take SIGPIPE.
    head -5 <<< "$out" | sed 's/^/          /'
    failed=$((failed+1)); continue
  fi
  # Herestring on purpose: piping printf's output into `grep -q` is broken under `set -o pipefail`.
  # grep -q exits on its first match and closes the read end, so on large output printf can still be
  # writing when it takes SIGPIPE; pipefail then promotes that SIGPIPE (141) to the pipeline's exit
  # status, misreading a real match as no-match.
  if grep -Eqi "$bad_re" <<< "$out"; then
    echo "  LEAK  $name -> requests $(grep -Eoi "$bad_re" <<< "$out" | sort -u | paste -sd, -)"
    leaks=$((leaks+1))
  elif grep -Eqi "$want_re" <<< "$out"; then
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
# Redundant backstop: every iteration increments exactly one of ok/leaks/indeterminate/failed, and
# the three checks above already require leaks/indeterminate/failed to be zero, so ok==total always
# holds here. Kept as a defensive invariant in case the counting logic above ever stops being
# mutually exclusive.
[ "$ok" -eq "$total" ]    || { echo "FAIL: only $ok/$total libs positively confirmed." >&2; exit 1; }
echo "CRT CHECK: PASS — all $total libs positively carry $want."
