// Mirrors exactly what ExecuTorch's OpenvinoBackend::ensure_loaded does:
//   dlopen(path, RTLD_NOW|RTLD_LOCAL) then dlsym the C API.
// Enumerating devices is the real test: it forces OpenVINO to locate and load its PLUGIN .so
// files, which is the part a flat-bundle layout can get wrong. A dlopen that merely succeeds
// proves nothing about the plugins.
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>

typedef struct ov_core ov_core_t;
typedef struct { char** devices; size_t size; } ov_available_devices_t;
typedef int (*fn_core_create)(ov_core_t**);
typedef int (*fn_core_free)(ov_core_t*);
typedef int (*fn_devices)(const ov_core_t*, ov_available_devices_t*);
typedef int (*fn_get_property)(const ov_core_t*, const char*, const char*, char**);
typedef void (*fn_ov_free)(const char*);

// Report a CPU property, or "(unavailable)" if the plugin does not answer. Deliberately NOT fatal:
// these are diagnostics, and a probe that aborts on an optional property turns information into an
// outage. The caller's pass/fail rests on device enumeration, which is checked separately.
static void report(fn_get_property getp, fn_ov_free ovfree, const ov_core_t* core,
                   const char* label, const char* key) {
  char* val = NULL;
  if (getp && getp(core, "CPU", key, &val) == 0 && val) {
    printf("%s %s\n", label, val);
    if (ovfree) ovfree(val);
  } else {
    printf("%s (unavailable)\n", label);
  }
}

int main(int argc, char** argv) {
  if (argc < 2) { printf("usage: devices_probe <libopenvino_c.so>\n"); return 2; }
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("DLOPEN FAIL: %s\n", dlerror()); return 1; }

  fn_core_create create = (fn_core_create)dlsym(h, "ov_core_create");
  fn_core_free   freec  = (fn_core_free)dlsym(h, "ov_core_free");
  fn_devices     devs   = (fn_devices)dlsym(h, "ov_core_get_available_devices");
  if (!create || !freec || !devs) { printf("DLSYM FAIL\n"); return 1; }

  ov_core_t* core = NULL;
  if (create(&core) != 0) { printf("ov_core_create FAILED\n"); return 1; }

  ov_available_devices_t d = {0};
  if (devs(core, &d) != 0) { printf("get_available_devices FAILED\n"); return 1; }
  for (size_t i = 0; i < d.size; i++) printf("DEVICE %s\n", d.devices[i]);

  // Which precision the CPU plugin will actually infer at, and what it could use. This is the
  // datum that explains a numeric gate result: OpenVINO selects precision from the executing CPU,
  // so a bf16-capable runner computes the same model in bf16 and lands ~2.5e-3 from an f32 golden
  // while a runner without those instructions lands at ~6e-8. Both are correct; without this line
  // the difference looks like a regression in the artifact. Resolved by dlsym like everything
  // else, so an older bundle lacking the symbol degrades to "(unavailable)" rather than failing.
  fn_get_property getp = (fn_get_property)dlsym(h, "ov_core_get_property");
  fn_ov_free ovfree = (fn_ov_free)dlsym(h, "ov_free");
  report(getp, ovfree, core, "PRECISION", "INFERENCE_PRECISION_HINT");
  report(getp, ovfree, core, "CAPABILITIES", "OPTIMIZATION_CAPABILITIES");

  freec(core);
  return 0;
}
