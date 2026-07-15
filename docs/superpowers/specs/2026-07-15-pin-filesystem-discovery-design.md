# Pin job — filesystem discovery of release rows

**Date:** 2026-07-15
**Status:** Approved (design); implementation plan to follow
**Scope:** Refactor the `release.yml` `pin` job from a hardcoded `platform × variant` loop to
filesystem discovery of the built artifacts. **Prerequisite** for Windows-artifact support
(`2026-07-15-windows-amd64-artifacts-design.md`), but independently useful and shippable.

## Why

The `pin` job today (`release.yml:118-129`) loops a hardcoded
`for platform in $PLATFORMS × for variant in bare logging devtools` and reads each
`dist/executorch-runtime-${etver}-${variant}-${platform}.tar.gz.sha256`. This assumes **every
platform ships every variant**. The moment a platform ships a *subset* (Windows v1 ships `logging`
only), the loop reads a nonexistent sha and fails.

This refactor produces the **same set of pin rows (order-independent) for today's Linux-only,
all-variants matrix**, so it can land and be verified by an ordinary Linux release **before** any
Windows job exists — keeping the "change shipping behavior" diff separate from the "add a platform"
diff. (`EtRuntimePin.cmake` is a flat list of independent `set(ET_RUNTIME_URL_<variant>_<platform> ...)`
variables read by name, so row *order* has no semantic effect — the discovery output is sorted
deterministically for stable diffs, but equivalence is defined on the row *set*, not byte order.
Reproducing the old hardcoded loop's exact emission order would require re-encoding `$PLATFORMS`
ordering + a variant priority list into the discovery script, re-coupling to precisely what the
refactor removes.)

## Design

Replace the hardcoded double loop with **discovery over the merged `dist/`**: enumerate the
`*.tar.gz.sha256` files actually present and emit one pin row per discovered `(variant, platform)`.

### Extracted, testable script

Discovery + row assembly moves into a small script (working name **`scripts/discover-pin-rows.sh`**)
that reuses `scripts/lib/naming.sh`, rather than living inline in YAML. Matches the repo's
SSOT-scripts + `*.test.sh` conventions and makes the parsing unit-testable.

**Contract:**
- **Input:** a `--dir <dist>` containing the merged sha files, and `--etver <etver>` (from
  `derive-version.sh`).
- **Output (stdout):** one line per discovered artifact, `variant<TAB>platform<TAB>sha`, suitable for
  feeding straight into `gen-pin.sh --row`. (Exact wire format finalized in the plan; TSV chosen so
  the workflow can read it without re-globbing.)
- **Discovery:** glob `<dir>/executorch-runtime-<etver>-*.tar.gz.sha256`.
- **Parsing (robust to `-` inside the platform string):** strip the known prefix
  `executorch-runtime-<etver>-` and known suffix `.tar.gz.sha256`, leaving `<variant>-<platform>`;
  split on the **first** `-` (variants never contain `-`; platforms like `linux-x86_64`,
  `windows-x86_64` do). The stem/naming is owned by `naming.sh` (`asset_stem`), so the script derives
  its match pattern from there rather than hardcoding a second copy of the naming scheme.
- **sha extraction:** `cut -d' ' -f1` of the sha file (unchanged from current logic).
- **Determinism:** sort the emitted rows (e.g. by `platform` then `variant`) so `EtRuntimePin.cmake`
  output is stable regardless of filesystem glob order.

The `pin` job then becomes: `derive-version.sh` → `discover-pin-rows.sh` → feed rows to
`gen-pin.sh` (unchanged) → write `dist/EtRuntimePin.cmake` + step summary. The
`for variant in bare logging devtools` hardcode and the `$PLATFORMS` dependency in `pin` are removed.

### Tests

New `test/discover_pin_rows.test.sh` (hermetic, following the existing `*.test.sh` pattern),
covering:
- single platform, all three variants → three rows, correct order;
- multiple platforms with **asymmetric** variant coverage (e.g. Linux ×3 + Windows ×1) → only the
  present artifacts appear;
- correct `(variant, platform)` split for a platform string containing `-`;
- correct sha extraction;
- deterministic ordering regardless of input glob order.

Registered in `test/run.sh`.

## Scope boundaries

**In scope:** the `pin` job discovery refactor, the extracted script, its unit test, and removing the
now-dead hardcoded variant list / `$PLATFORMS` use in `pin`.

**Out of scope:** any Windows job or platform string (that's the Windows spec); `gen-pin.sh` output
format (`EtRuntimePin.cmake` contract C6) — reused unchanged; the release/build/attest jobs.

## Reuse summary

| Component | Treatment |
|---|---|
| `naming.sh` | Reused as the source of the stem/match pattern |
| `gen-pin.sh`, `derive-version.sh` | Reused verbatim |
| `release.yml` `pin` job | Hardcoded loop → `discover-pin-rows.sh`; `$PLATFORMS` dep removed |
| `scripts/discover-pin-rows.sh` | New, testable |
| `test/discover_pin_rows.test.sh` | New, registered in `test/run.sh` |
