# ExecuTorch Runtime Dist

The purpose of this repository is to provide PIC assets for desktop builds of [ExecuTorch](https://github.com/pytorch/executorch) for use with JNI.  
Meta has a JNI interface layer for ExecuTorch, but it is focused on Android and requires fbjni.  The default build configuration for ExecuTorch is *not* to build with `-fPIC`, making it difficult to link into a JVM via JNI.

This repository hosts CI infrastructure to create and attest these builds such that they can be safely and responsibly consumed elsewhere.

## Variants

Each release builds three variants of the runtime for `linux-x86_64`:

- `bare` — logging off (smallest).
- `logging` — logging on. **Ship default.**
- `devtools` — devtools + event tracer (profiling/debug).

Each tarball unpacks to a single top-level directory containing:

```
lib/                   # includes lib/cmake/ExecuTorch/executorch-config.cmake
include/
LICENSE
THIRD-PARTY-NOTICES/
BUILDINFO
```

## Bundled first-party op & dependencies

This runtime ships the custom `etnp::lstm.out` operator in every variant (see
`docs/lstm-op-consumer-guide.md`). Building it pulls one additional pinned
dependency beyond ExecuTorch's own third-party set:

- **Google Highway 1.4.0** (SIMD; SHA256 `e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c`)
  — fetched by the `extras/` build and linked into `libetnp_ops_lstm.a`. Its license
  is passed through into the tarball's `THIRD-PARTY-NOTICES/`.

XNNPACK (already part of ExecuTorch) is reused from the built prefix; no new XNNPACK
dependency is introduced.

## Cutting a release

Releases are built once per ExecuTorch version and published as attested,
hash-pinned tarballs. Pushing a version tag is the **only** CI trigger.

1. Pick the tag `v<etver>-<pkgrev>` (e.g. `v1.3.1-1`; bump `<pkgrev>` to re-roll
   the same ExecuTorch version, for example after a recipe fix).
2. Push the tag:

   ```bash
   git tag v1.3.1-1
   git push origin v1.3.1-1
   ```

3. `.github/workflows/release.yml` takes it from there: it checks out this repo
   and a matching checkout of `pytorch/executorch` (with submodules) at the
   derived ExecuTorch tag, builds all three variants (`bare`/`logging`/`devtools`)
   for `linux-x86_64` inside `quay.io/pypa/manylinux_2_28_x86_64`, attests each
   tarball's build provenance, and publishes a GitHub Release containing:
   - the 3 tarballs and their matching `.sha256` files
   - a ready-to-paste `EtRuntimePin.cmake`

## Building locally

`build-runtime.sh` is the single entrypoint for the build recipe.
It must run **inside** the `quay.io/pypa/manylinux_2_28_x86_64` container, and
it never clones ExecuTorch itself — the caller always supplies the source tree:

```
build-runtime.sh --variant <bare|logging|devtools> --prefix <install-dir> \
                  --et-src <et-checkout> [--et-tag <label>] [--build-dir <dir>]
```

- `--et-src` must point at a checkout of `pytorch/executorch` at the target tag,
  **with submodules** — CI supplies this via a second `actions/checkout`; locally
  you provide it yourself (e.g. a mounted directory).
- `--et-tag` is just the version label recorded alongside the build (default `v1.3.1`).
- `--build-dir` is the CMake build tree; it defaults to
  `<dirname of --prefix>/et-build-<variant>`, and is left in place (not deleted)
  so it can be inspected or reused for an incremental rebuild.
- `SKIP_ET_BUILD=1` (env var) reuses an existing `--prefix` install and skips the
  ~10-minute ExecuTorch compile — useful when only re-packaging.

To build locally with the same recipe CI uses, mount both the repo and an
ExecuTorch checkout (with submodules, at the tag you want) into the manylinux
container — the mount stands in for CI's `actions/checkout` of ExecuTorch:

```bash
docker run --rm -v "$PWD":/work -v /path/to/executorch:/executorch \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant logging --prefix /work/out --et-src /executorch'
```

## Verifying an artifact

Each release asset ships with a `.sha256` file and a build-provenance attestation.
Verify both before consuming a tarball:

```bash
sha256sum -c executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz.sha256
gh attestation verify executorch-runtime-1.3.1-logging-linux-x86_64.tar.gz \
  --repo measly-java-learning/executorch-runtime-dist
```

## Consuming downstream

Downstream projects (e.g. an engine embedding ExecuTorch via JNI) should not
build this recipe themselves. Instead, pull a specific release's generated
`EtRuntimePin.cmake` from the GitHub Release page and paste it into the
consuming project (e.g. as `cmake/EtRuntimePin.cmake`), then `FetchContent`
the pinned, hash-verified tarball it points at:

```cmake
include(cmake/EtRuntimePin.cmake)

include(FetchContent)
FetchContent_Declare(et_runtime
  URL       "${ET_RUNTIME_URL_logging_linux-x86_64}"
  URL_HASH  "SHA256=${ET_RUNTIME_SHA256_logging_linux-x86_64}"
)
FetchContent_MakeAvailable(et_runtime)

find_package(ExecuTorch REQUIRED
  PATHS "${et_runtime_SOURCE_DIR}/lib/cmake/ExecuTorch" NO_DEFAULT_PATH)
```

Because the pin file records both the download URL and the SHA-256 hash for
every variant/platform pair, `FetchContent` re-verifies the tarball on every
build — the same guarantee `sha256sum -c` gives you locally.
