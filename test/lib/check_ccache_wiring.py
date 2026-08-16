#!/usr/bin/env python3
"""Assert the full-aot ccache wiring is intact.

Usage: check_ccache_wiring.py <path to extras-gate.yml>

Every assertion here protects against a change that leaves the gate GREEN but the cache useless -
the failure mode is a slow gate nobody investigates, not a red X.
"""
import sys

import yaml


def main(path: str) -> int:
    fails = 0

    def ok(cond, msg):
        nonlocal fails
        if cond:
            print(f"ok: {msg}")
        else:
            print(f"FAIL: {msg}", file=sys.stderr)
            fails += 1

    jobs = yaml.safe_load(open(path))["jobs"]
    aot = jobs["full-aot"]
    steps = aot["steps"]
    runs = "\n".join(str(s.get("run", "")) for s in steps)

    ok("./scripts/install-ccache.sh" in runs, "full-aot installs the pinned ccache")
    ok("ccache -z" in runs, "counters zeroed, so stats measure THIS run not the restored lifetime")
    ok("ccache -M" in runs, "cache size is capped (the 10GB repo budget is shared)")
    ok("./scripts/ccache-stats.sh" in runs, "hit rate is reported")

    # The tokenizers sub-build is the ~5min one and is NOT covered by ExecuTorch's find_program.
    ok("CMAKE_CXX_COMPILER_LAUNCHER=ccache" in runs,
       "launcher injected for the tokenizers sub-build")

    # The threshold must NOT live in a file the cache key hashes, or tuning it invalidates
    # every cache.
    env = aot.get("env", {})
    ok("CCACHE_MIN_HIT_RATE" in env, "threshold lives in workflow env, not scripts/lib")
    ok(str(env.get("CCACHE_DIR", "")).endswith(".ccache"), "CCACHE_DIR is under the workspace")

    restore = [s for s in steps if "actions/cache/restore" in str(s.get("uses", ""))]
    save = [s for s in steps if "actions/cache/save" in str(s.get("uses", ""))]
    ok(len(restore) == 1, "exactly one cache restore step")
    ok(len(save) == 1, "exactly one cache save step")
    # The COMBINED action exposes only cache-hit, which cannot express the condition below.
    combined = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache@")]
    ok(not combined, "uses the restore/save split, not the combined actions/cache")

    if restore:
        with_ = restore[0]["with"]
        key = str(with_["key"])
        ok("github.sha" in key, "key has a unique suffix (a cache key is write-once)")
        ok("hashFiles" in key, "key tracks the build inputs")
        ok("restore-keys" in with_, "prefix fallback exists so a novel key still starts warm")
        # OVER-hashing costs a ~20 minute rebuild for a change that cannot affect a single object
        # full-aot compiles: it never runs build-runtime.sh and never applies patches/*.
        ok("build-runtime.sh" not in key,
           "key does NOT hash build-runtime.sh (full-aot never runs it)")
        ok("patches/" not in key, "key does NOT hash patches/* (full-aot never applies them)")
        ok("scripts/lib/*.sh" not in key,
           "key does NOT glob scripts/lib (openvino.sh/naming.sh do not affect compilation)")

    # Enforcement must key off WHICH key matched, not cache-hit: the primary key ends in the sha,
    # so cache-hit is true only when re-running an identical commit and would never fire on a PR.
    stats = [s for s in steps if "ccache-stats.sh" in str(s.get("run", ""))]
    ok(bool(stats), "a stats step exists")
    if stats:
        blob = str(stats[0].get("env", {})) + str(stats[0].get("run", ""))
        ok("cache-matched-key" in blob,
           "enforcement compares the MATCHED key, so it can actually fire on a PR")
        ok("cache-hit" not in blob,
           "enforcement does not use cache-hit (exact match incl. sha = never fires)")

    # Scope discipline: full-build is deliberately NOT wired - it is not on the critical path,
    # so caching it buys zero wall clock. See the plan's global constraints.
    build_runs = "\n".join(str(s.get("run", "")) for s in jobs["full-build"]["steps"])
    ok("install-ccache.sh" not in build_runs,
       "full-build is deliberately NOT cached (see the plan's scope constraint)")

    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
