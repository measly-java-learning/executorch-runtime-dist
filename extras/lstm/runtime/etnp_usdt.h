// USDT (userland statically-defined tracing) probes for the LSTM XnnLinearCache.
// Each probe compiles to a single nop + a non-allocated .note.stapsdt ELF note:
// no linked runtime dependency, zero cost when untraced. Provider/probe names and
// argument widths are a committed contract (see docs/lstm-xnn-cache-usdt.md); the
// POST_BUILD readelf guard enforces them.
//
// Gating: real probes only when ETNP_USDT_ENABLED is defined truthy (set by the
// extras CMake on Linux when ETNP_ENABLE_USDT=ON) AND compiling for __linux__.
// Otherwise every macro is a no-op, so non-Linux/opt-out builds compile cleanly.
#pragma once

#if defined(ETNP_USDT_ENABLED) && ETNP_USDT_ENABLED && defined(__linux__)

#include <cstdint>
#include <sys/sdt.h>

// Widths are pinned (the note records each arg's byte size): u32 for
// channels/occupancy/capacity, u64 for the LRU tick delta.
#define ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, occ, cap)                 \
  DTRACE_PROBE4(etnp, lstm_xnn_cache__hit,                                 \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap))

#define ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, occ, cap)                \
  DTRACE_PROBE4(etnp, lstm_xnn_cache__miss,                                \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap))

#define ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, occ, cap, ein, eout, age) \
  DTRACE_PROBE7(etnp, lstm_xnn_cache__evict,                               \
                (uint32_t)(in_ch), (uint32_t)(out_ch),                     \
                (uint32_t)(occ), (uint32_t)(cap),                          \
                (uint32_t)(ein), (uint32_t)(eout), (uint64_t)(age))

#else  // disabled or non-Linux: no-ops

#define ETNP_LSTM_CACHE_PROBE_HIT(in_ch, out_ch, occ, cap) ((void)0)
#define ETNP_LSTM_CACHE_PROBE_MISS(in_ch, out_ch, occ, cap) ((void)0)
#define ETNP_LSTM_CACHE_PROBE_EVICT(in_ch, out_ch, occ, cap, ein, eout, age) ((void)0)

#endif
