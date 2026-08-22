// Windows counterpart to devices_probe.c + blob_probe.c, and the experiment that settled the
// central design question for Windows OpenVINO support:
// https://github.com/measly-java-learning/executorch-runtime-dist/issues/37 (blocker 2).
//
// Wired into test/openvino_smoke-windows.sh, which compiles it with cl and runs BOTH the `plain`
// negative control and the `dllload` acceptance cell. See that script for the gate contract.
//
// WHAT IT TESTS. The Linux bundle self-resolves because the wheel's libs carry RPATH=$ORIGIN, so
// dlopen by absolute path finds openvino.so's siblings in the same directory. Windows has no
// $ORIGIN. The substitute is LoadLibraryExW with LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, and this probe
// runs the same sequence under three load modes so the claim is measured rather than assumed:
//
//   plain    LoadLibraryW(abs)                              EXPECT FAIL     (demonstrates the gap)
//   dllonly  LoadLibraryExW(.., SEARCH_DLL_LOAD_DIR)        EXPECT FAIL     (see BOTH FLAGS below)
//   dllload  LoadLibraryExW(.., DLL_LOAD_DIR|DEFAULT_DIRS)  EXPECT FULLY OK (the fix)
//
// `plain` IS A NEGATIVE CONTROL AND IS THE POINT. Windows also resolves DLLs from PATH, the app
// directory and System32, so if `plain` SUCCEEDS the environment is contaminated -- some other
// OpenVINO is being found -- and the `dllload` result proves nothing. Run from a directory that is
// not the bundle and with PATH stripped to System32. This is the analogue of `env -u
// LD_LIBRARY_PATH` in openvino_smoke.sh, and for exactly the same reason.
//
// BOTH FLAGS ARE LOAD-BEARING; `dllonly` proves it. Passing any LOAD_LIBRARY_SEARCH_* flag switches
// the loader to the alternate search order, which drops System32 -- where the wheel's /MD CRT
// (MSVCP140, VCRUNTIME140, VCRUNTIME140_1) lives. Simplifying to the one flag that looks relevant
// fails with the same opaque error 126 as the negative control.
//
// LOADING IS NOT SUFFICIENT ON ITS OWN, for the reason openvino_smoke.sh documents at length: three
// different resolution mechanisms are in play and the load flags govern only the first.
//   1. openvino_c.dll -> openvino.dll -> tbb12.dll   static imports, resolved by the LOADER
//   2. the CPU plugin and the IR frontend            loaded by OPENVINO's own code via its own
//                                                    module-relative logic; those LoadLibrary calls
//                                                    do NOT inherit our flags (verified: they still
//                                                    resolve from the bundle)
//   3. tbbbind_2_5.dll                               loaded by TBB by BARE NAME (see the note in
//                                                    scripts/lib/openvino.sh); predicted to miss in
//                                                    a flat bundle, but it resolves -- so the
//                                                    Windows member set keeps it and NUMA-aware
//                                                    binding is preserved
// So the probe runs both gate stages: enumerate devices (forces 2's plugin) and import a blob
// (forces 2's IR frontend, whose absence leaves enumeration working while every delegated .pte
// fails at load with status=-1). It then lists loaded modules, which measures 3 directly and flags
// any member that resolved from OUTSIDE the bundle.
//
// BUILD (winbox, from a vcvars64 shell; /MT instead of /MD also passes, which is what makes
// windows-x86_64-static viable against the wheel's /MD DLLs):
//   cl /nologo /W3 /O2 /D_CRT_SECURE_NO_WARNINGS win_origin_probe.c /Fe:win_origin_probe.exe psapi.lib
//
// RUN:
//   win_origin_probe.exe <plain|dllonly|dllload> <abs\path\to\openvino_c.dll> [blob]
// Set ETNP_ALL_MODULES=1 to list every loaded module rather than just the OpenVINO/TBB ones -- that
// is how the /MD CRT dependency on the consumer machine was found.
// exit 0 = fully OK, 1 = a stage failed, 2 = usage/setup problem.
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct ov_core ov_core_t;
typedef struct { char** devices; size_t size; } ov_available_devices_t;
typedef struct ov_compiled_model ov_compiled_model_t;
typedef int (*fn_core_create)(ov_core_t**);
typedef int (*fn_devices)(const ov_core_t*, ov_available_devices_t*);
typedef int (*fn_get_property)(const ov_core_t*, const char*, const char*, char**);
typedef void (*fn_ov_free)(const char*);
typedef int (*fn_import)(const ov_core_t*, const char*, size_t, const char*, ov_compiled_model_t**);

static void print_last_error(const wchar_t* what) {
  DWORD e = GetLastError();
  wchar_t* msg = NULL;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 NULL, e, 0, (wchar_t*)&msg, 0, NULL);
  // 126 is ERROR_MOD_NOT_FOUND: the named DLL was found but one of its DEPENDENCIES was not. That
  // is the whole missing-$ORIGIN symptom, and it is indistinguishable from a genuinely absent file.
  wprintf(L"%ls: GetLastError=%lu %ls", what, (unsigned long)e, msg ? msg : L"\n");
  if (msg) LocalFree(msg);
}

// Which of the bundle's members actually made it into the process, and from WHERE. A member
// resolved from outside bundle_dir means the flat bundle is not what got tested.
static void report_modules(const wchar_t* bundle_dir) {
  HMODULE mods[512];
  DWORD needed = 0;
  if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) {
    wprintf(L"  (module enumeration failed)\n");
    return;
  }
  size_t n = needed / sizeof(HMODULE);
  for (size_t i = 0; i < n; i++) {
    wchar_t path[MAX_PATH];
    if (!GetModuleFileNameW(mods[i], path, MAX_PATH)) continue;
    if (!_wgetenv(L"ETNP_ALL_MODULES") &&
        !wcsstr(path, L"openvino") && !wcsstr(path, L"tbb")) continue;
    int inside = _wcsnicmp(path, bundle_dir, wcslen(bundle_dir)) == 0;
    wprintf(L"  [%ls] %ls\n", inside ? L"bundle" : L"OUTSIDE", path);
  }
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 3) { wprintf(L"usage: win_origin_probe <plain|dllonly|dllload> <openvino_c.dll> [blob]\n"); return 2; }
  const wchar_t* mode = argv[1];
  const wchar_t* lib = argv[2];

  wchar_t bundle_dir[MAX_PATH];
  wcsncpy_s(bundle_dir, MAX_PATH, lib, _TRUNCATE);
  wchar_t* slash = wcsrchr(bundle_dir, L'\\');
  if (!slash) { wprintf(L"pass an ABSOLUTE path to openvino_c.dll\n"); return 2; }
  *slash = L'\0';

  wprintf(L"mode       %ls\n", mode);
  wprintf(L"library    %ls\n", lib);
  wprintf(L"bundle dir %ls\n", bundle_dir);
  wprintf(L"PATH       %ls\n\n", _wgetenv(L"PATH") ? _wgetenv(L"PATH") : L"(empty)");

  HMODULE h = NULL;
  if (wcscmp(mode, L"plain") == 0) {
    // No flags: the loader searches the app dir, System32 and PATH -- but NOT the directory the
    // DLL itself lives in. This is precisely the missing-$ORIGIN behaviour.
    h = LoadLibraryW(lib);
  } else if (wcscmp(mode, L"dllonly") == 0) {
    // Minimal-flag cell. Fails: see BOTH FLAGS ARE LOAD-BEARING above.
    h = LoadLibraryExW(lib, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR);
  } else if (wcscmp(mode, L"dllload") == 0) {
    // SEARCH_DLL_LOAD_DIR temporarily prepends the loaded DLL's OWN directory to the search path
    // for its dependencies -- the $ORIGIN substitute. DEFAULT_DIRS restores System32 and the app
    // dir; note it deliberately does NOT include PATH, so this is STRICTER than the plain call.
    h = LoadLibraryExW(lib, NULL,
                       LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  } else {
    wprintf(L"unknown mode %ls\n", mode); return 2;
  }

  if (!h) {
    print_last_error(L"LOAD FAILED");
    wprintf(L"\nRESULT %ls: LOAD FAILED\n", mode);
    return 1;
  }
  wprintf(L"LOAD OK\n");

  fn_core_create create = (fn_core_create)GetProcAddress(h, "ov_core_create");
  fn_devices devs = (fn_devices)GetProcAddress(h, "ov_core_get_available_devices");
  if (!create || !devs) { wprintf(L"GetProcAddress FAILED\n"); return 1; }

  ov_core_t* core = NULL;
  if (create(&core) != 0) { wprintf(L"ov_core_create FAILED\n"); return 1; }
  wprintf(L"ov_core_create OK\n");

  ov_available_devices_t d = {0};
  if (devs(core, &d) != 0) { wprintf(L"get_available_devices FAILED\n"); return 1; }
  int saw_cpu = 0;
  for (size_t i = 0; i < d.size; i++) {
    printf("DEVICE %s\n", d.devices[i]);
    if (strncmp(d.devices[i], "CPU", 3) == 0) saw_cpu = 1;
  }
  if (!saw_cpu) { wprintf(L"FAIL: CPU not enumerated (plugin not found from the flat bundle)\n"); return 1; }

  // Diagnostic, not pass/fail -- same treatment as report() in devices_probe.c.
  fn_get_property getp = (fn_get_property)GetProcAddress(h, "ov_core_get_property");
  fn_ov_free ovfree = (fn_ov_free)GetProcAddress(h, "ov_free");
  if (getp) {
    char* val = NULL;
    if (getp(core, "CPU", "OPTIMIZATION_CAPABILITIES", &val) == 0 && val) {
      printf("CAPABILITIES %s\n", val);
      if (ovfree) ovfree(val);
    }
  }

  int blob_ok = 1;
  if (argc >= 4) {
    FILE* f = _wfopen(argv[3], L"rb");
    if (!f) { wprintf(L"blob open failed\n"); return 2; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char* buf = (char*)malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { wprintf(L"blob read failed\n"); fclose(f); return 2; }
    fclose(f);
    fn_import imp = (fn_import)GetProcAddress(h, "ov_core_import_model");
    ov_compiled_model_t* cm = NULL;
    int st = imp ? imp(core, buf, (size_t)n, "CPU", &cm) : -1;
    free(buf);
    if (st == 0 && cm) printf("IMPORT OK (%ld bytes)\n", n);
    else { printf("IMPORT FAILED status=%d\n", st); blob_ok = 0; }
  }

  wprintf(L"\nloaded modules:\n");
  report_modules(bundle_dir);

  wprintf(L"\nRESULT %ls: %ls\n", mode, blob_ok ? L"FULLY OK" : L"IMPORT FAILED");
  return blob_ok ? 0 : 1;
}
