# LSTM XnnLinearCache USDT tracepoints

The `etnp::lstm.out` op packs XNNPACK fully-connected operators in a process-wide
LRU cache (`kMaxEntries = 16`). On **Linux** builds, the runtime emits USDT probes
so you can observe cache behavior in production — with **zero linked dependency**
and **zero cost when untraced** (each probe is a `nop` + a `.note.stapsdt` note).
Only your tracing tool (bpftrace / perf) needs privileges; the shipped library does not.

## Probe contract

Provider **`etnp`**. Probe names are **stable** (a rename is a breaking change).
Argument sets are documented but best-effort (may gain trailing args). All args are
`uint32_t` except `evicted_age` (`uint64_t`).

| Probe | Args (in order) |
|-------|-----------------|
| `etnp:lstm_xnn_cache__hit`   | `in_ch, out_ch, occupancy, capacity` |
| `etnp:lstm_xnn_cache__miss`  | `in_ch, out_ch, occupancy, capacity` |
| `etnp:lstm_xnn_cache__evict` | `in_ch, out_ch, occupancy, capacity, evicted_in_ch, evicted_out_ch, evicted_age` |

- `in_ch`/`out_ch` — FC dims of the current operation's key (on `__evict`, the *incoming* key).
- `occupancy` — cache entries after the event's mutation (`== capacity` on `__evict`).
- `capacity` — the compile-time cap (currently 16).
- `evicted_in_ch`/`evicted_out_ch` — FC dims of the evicted victim.
- `evicted_age` — LRU tick delta (`current_tick - victim_last_use_tick`): how many cache
  operations elapsed since the victim was last touched. Large = cold victim (working set
  fits); small = churn.

`__miss` fires once per successful (re)pack, so it tracks `s.misses` except on the rare
XNNPACK-create failure (which packs nothing).

## Is 16 enough? bpftrace recipes

Whether the probes are present in a build: `readelf --notes <your-binary> | grep etnp`.
Point bpftrace at the binary/library that linked the runtime (shown as `$BIN` below).

Hit/miss ratio over 10s:
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__hit  { @hit  = count(); }
             usdt:$BIN:etnp:lstm_xnn_cache__miss { @miss = count(); }
             interval:s:10 { print(@hit); print(@miss); exit(); }'
```

Eviction pressure + victim staleness (the "too small" signal):
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__evict {
               @evicts = count(); @age = hist(arg6);   /* evicted_age */ }'
```
Frequent evictions with small `evicted_age` (and occupancy pinned at capacity) means the
working set exceeds 16.

Occupancy distribution:
```
bpftrace -e 'usdt:$BIN:etnp:lstm_xnn_cache__hit { @occ = hist(arg2); }'
```

## Build toggle

Probes are on by default on Linux for all variants (`bare`/`logging`/`devtools`) and
compiled out on non-Linux. To build without them: configure the extras with
`-DETNP_ENABLE_USDT=OFF`. The shipped `BUILDINFO` records `usdt=on|off`.
