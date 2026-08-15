// Imports a precompiled OpenVINO blob through ov_core_import_model — the SAME call
// ExecuTorch's OpenvinoBackend makes when it initializes a delegated method
// (backends/openvino/runtime/OpenvinoBackend.cpp).
//
// This is the stage that catches a bundle which loads and enumerates devices but cannot
// actually deserialize a model — e.g. a missing libopenvino_ir_frontend, which leaves device
// enumeration working while every delegated .pte fails at load with status=-1.
//
//   blob_probe <libopenvino_c.so> <blob-file>
// exit 0 = imported, 1 = import failed, 2 = usage/dlopen/dlsym problem.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

typedef struct ov_core ov_core_t;
typedef struct ov_compiled_model ov_compiled_model_t;
typedef int (*fn_core_create)(ov_core_t**);
typedef int (*fn_import)(const ov_core_t*, const char*, size_t, const char*, ov_compiled_model_t**);

int main(int argc, char** argv) {
  if (argc < 3) { printf("usage: blob_probe <libopenvino_c.so> <blob>\n"); return 2; }

  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("DLOPEN FAIL: %s\n", dlerror()); return 2; }

  fn_core_create create = (fn_core_create)dlsym(h, "ov_core_create");
  fn_import imp = (fn_import)dlsym(h, "ov_core_import_model");
  if (!create || !imp) { printf("DLSYM FAIL\n"); return 2; }

  FILE* f = fopen(argv[2], "rb");
  if (!f) { printf("blob open failed: %s\n", argv[2]); return 2; }
  if (fseek(f, 0, SEEK_END) != 0) { printf("blob seek failed\n"); fclose(f); return 2; }
  long n = ftell(f);
  if (n <= 0) { printf("blob is empty\n"); fclose(f); return 2; }
  rewind(f);
  char* buf = (char*)malloc((size_t)n);
  if (!buf) { printf("oom\n"); fclose(f); return 2; }
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) { printf("blob read failed\n"); fclose(f); free(buf); return 2; }
  fclose(f);

  ov_core_t* core = NULL;
  if (create(&core) != 0) { printf("ov_core_create FAILED\n"); free(buf); return 2; }

  ov_compiled_model_t* cm = NULL;
  int st = imp(core, buf, (size_t)n, "CPU", &cm);
  free(buf);
  if (st == 0 && cm) { printf("IMPORT OK (%ld bytes)\n", n); return 0; }
  printf("IMPORT FAILED status=%d\n", st);
  return 1;
}
