Verbatim copies of ExecuTorch v1.3.1 (commit e2f18eb) and its vendored XNNPACK sources, used as
hermetic fixtures for test/patch_et_xnnpack_workspace.test.sh. They exist so the patch test runs
against the real anchor text without needing a multi-GB ET checkout.

Refresh these when the ET pin moves, in the same commit that refreshes patches/*.patch — a stale
fixture makes the patch test pass while the real build fails.
