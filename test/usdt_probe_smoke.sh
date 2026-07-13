#!/usr/bin/env bash
# Build-environment smoke (NOT in run.sh): compile a tiny TU that uses etnp_usdt.h,
# link it, and assert the probe notes survive via scripts/check-usdt-notes.sh.
# Requires: g++, binutils (readelf), and systemtap-sdt-devel (<sys/sdt.h>).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
hdr_dir="$root/extras/lstm/runtime"
tmp="$(mktemp -d)"
cat > "$tmp/smoke.cpp" <<'CPP'
#include "etnp_usdt.h"
int main() {
  ETNP_LSTM_CACHE_PROBE_HIT(1u, 2u, 3u, 16u);
  ETNP_LSTM_CACHE_PROBE_MISS(1u, 2u, 3u, 16u);
  ETNP_LSTM_CACHE_PROBE_EVICT(1u, 2u, 16u, 16u, 4u, 5u, 42ull);
  return 0;
}
CPP

echo "== USDT enabled: notes must be present =="
g++ -O2 -fPIC -DETNP_USDT_ENABLED=1 -I"$hdr_dir" "$tmp/smoke.cpp" -o "$tmp/smoke_on"
bash "$root/scripts/check-usdt-notes.sh" --expect on "$tmp/smoke_on"

echo "== USDT disabled: notes must be absent =="
g++ -O2 -fPIC -I"$hdr_dir" "$tmp/smoke.cpp" -o "$tmp/smoke_off"
bash "$root/scripts/check-usdt-notes.sh" --expect off "$tmp/smoke_off"

echo "USDT PROBE SMOKE PASS"
