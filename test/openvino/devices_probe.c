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
  freec(core);
  return 0;
}
