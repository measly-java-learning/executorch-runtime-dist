Verbatim copies of ExecuTorch v1.5.1 (commit 3b60683) and its vendored XNNPACK sources (92a7ad5), used as
hermetic fixtures for test/patch_et_sources.test.sh. They exist so the patch test runs against the
real anchor text without needing a multi-GB ET checkout. The `Xnn*`/`XNN*`/`xnnpack.h`/`runtime.c`
files back the workspace-size patches; `OpenvinoApi.h`, `OpenvinoBackend.cpp` and
`openvino-CMakeLists.txt` back the OpenVINO/Windows patch (the last is renamed because this is a
flat directory and a bare `CMakeLists.txt` would be ambiguous).

Refresh these when the ET pin moves, in the same commit that refreshes patches/*.patch — a stale
fixture makes the patch test pass while the real build fails.
