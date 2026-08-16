#!/usr/bin/env python3
"""Assert the full-aot and full-build ccache wiring is intact.

Usage: check_ccache_wiring.py <path to extras-gate.yml>

Every assertion here protects against a change that leaves the gate GREEN but the cache useless -
the failure mode is a slow gate nobody investigates, not a red X.
"""
import sys

import yaml


def check_job(jobs, name, ok, launcher=False, hash_recipe=False):
    """Run the wiring checks shared by both cached jobs.

    `launcher`: job also needs the explicit CMAKE_CXX_COMPILER_LAUNCHER injection (full-aot's
    pytorch_tokenizers sub-build; full-build's ET core auto-detects ccache).
    `hash_recipe`: the cache key must hash the recipe inputs the job compiles from
    (full-build: build-runtime.sh, patches/*, scripts/lib/*). full-aot must NOT hash them.
    """
    job = jobs[name]
    steps = job["steps"]
    runs = "\n".join(str(s.get("run", "")) for s in steps)

    ok("./scripts/install-ccache.sh" in runs, f"{name} installs the pinned ccache")
    ok("ccache -z" in runs, f"{name}: counters zeroed, so stats measure THIS run not the restored lifetime")
    ok("ccache -M" in runs, f"{name}: cache size is capped (the 10GB repo budget is shared)")
    ok("./scripts/ccache-stats.sh" in runs, f"{name}: hit rate is reported")

    if launcher:
        # The tokenizers sub-build is the ~5min one and is NOT covered by ExecuTorch's find_program.
        ok("CMAKE_CXX_COMPILER_LAUNCHER=ccache" in runs,
           "launcher injected for the tokenizers sub-build")

    # The threshold must NOT live in a file the cache key hashes, or tuning it invalidates
    # every cache.
    env = job.get("env", {})
    ok("CCACHE_MIN_HIT_RATE" in env, f"{name}: threshold lives in workflow env, not scripts/lib")
    ok(str(env.get("CCACHE_DIR", "")).endswith(".ccache"), f"{name}: CCACHE_DIR is under the workspace")

    restore = [s for s in steps if "actions/cache/restore" in str(s.get("uses", ""))]
    save = [s for s in steps if "actions/cache/save" in str(s.get("uses", ""))]
    ok(len(restore) == 1, f"{name}: exactly one cache restore step")
    ok(len(save) == 1, f"{name}: exactly one cache save step")
    # The COMBINED action exposes only cache-hit, which cannot express the condition below.
    combined = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache@")]
    ok(not combined, f"{name}: uses the restore/save split, not the combined actions/cache")

    if restore:
        with_ = restore[0]["with"]
        key = str(with_["key"])
        ok("github.sha" in key, f"{name}: key has a unique suffix (a cache key is write-once)")
        ok("hashFiles" in key, f"{name}: key tracks the build inputs")
        ok("restore-keys" in with_, f"{name}: prefix fallback exists so a novel key still starts warm")
        if hash_recipe:
            # full-build compiles FROM the recipe: build-runtime.sh configures ET, patches/* are
            # applied before configure, and scripts/lib composes the cmake flags. The enforcement
            # floor requires a recipe change to change the inputs hash - otherwise an edit restores
            # an "identical-inputs" cache that then misses everything and fails the gate for doing
            # the right thing.
            ok("build-runtime.sh" in key, "full-build key hashes build-runtime.sh (it runs it)")
            ok("patches/" in key, "full-build key hashes patches/* (it applies them)")
            ok("scripts/lib" in key, "full-build key hashes the flag-composing scripts/lib")
        else:
            # OVER-hashing costs a ~20 minute rebuild for a change that cannot affect a single
            # object full-aot compiles: it never runs build-runtime.sh and never applies patches/*.
            ok("build-runtime.sh" not in key,
               "full-aot key does NOT hash build-runtime.sh (full-aot never runs it)")
            ok("patches/" not in key, "full-aot key does NOT hash patches/* (full-aot never applies them)")
            ok("scripts/lib/*.sh" not in key,
               "full-aot key does NOT glob scripts/lib (openvino.sh/naming.sh do not affect compilation)")

    # Enforcement must key off WHICH key matched, not cache-hit: the primary key ends in the sha,
    # so cache-hit is true only when re-running an identical commit and would never fire on a PR.
    stats = [s for s in steps if "ccache-stats.sh" in str(s.get("run", ""))]
    ok(bool(stats), f"{name}: a stats step exists")
    if stats:
        blob = str(stats[0].get("env", {})) + str(stats[0].get("run", ""))
        ok("cache-matched-key" in blob,
           f"{name}: enforcement compares the MATCHED key, so it can actually fire on a PR")
        ok("cache-hit" not in blob,
           f"{name}: enforcement does not use cache-hit (exact match incl. sha = never fires)")


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

    # Both compile-bound jobs are cached. Phase two landed once full-aot's measured 372s dropped
    # below full-build's 800-1080s band - see the spec's measured-results section.
    check_job(jobs, "full-aot", ok, launcher=True, hash_recipe=False)
    check_job(jobs, "full-build", ok, launcher=False, hash_recipe=True)

    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
