// Consumer probe for the relocatability / PIC / CRT gates.
//
// This TU MUST reference a real ExecuTorch symbol. Static-archive linking is lazy — the linker
// extracts an archive member only to resolve an undefined symbol — so a self-contained probe
// (`return 0;`) pulls in NO ET object and makes every gate built on it vacuous:
//   * the Linux PIC gate links a non-PIC archive without complaint, and
//   * the Windows CRT gate passes a /MT artifact against a /MD consumer.
// Both were verified to pass on artifacts they should have rejected before this reference existed.
//
// runtime_init() is chosen because it is public, torch-free, and defined in the core archive
// (libexecutorch_core.a / executorch_core.lib), so referencing it forces object extraction. It is
// never called at runtime — the LINK is the test.
#include <executorch/runtime/platform/runtime.h>

extern "C" int et_pic_probe() {
  ::executorch::runtime::runtime_init();
  return 0;
}
