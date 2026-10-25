# Consumer guide: writing and reading `.ptd` files

Every tarball this repo publishes exports ExecuTorch's flat-tensor serializer as the CMake target
`extension_flat_tensor_serialize`, plus the headers a consumer needs to write a `.ptd` and to
enumerate one. The writer is upstream `save_ptd` (issue
[#63](https://github.com/measly-java-learning/executorch-runtime-dist/issues/63)); the design and
the evidence live in
[`docs/superpowers/specs/2026-10-25-ptd-writer-design.md`](superpowers/specs/2026-10-25-ptd-writer-design.md).

A `.ptd` is how trained weights leave a training program: checkpoint, resume, or hand off to an
inference `.pte` that was exported with external constants. Reading through
`Module(pte, ptd)` already worked; this adds the write side and the reader headers.

## Linking

```cmake
find_package(ExecuTorch REQUIRED CONFIG)

target_link_libraries(my_target PRIVATE
  extension_flat_tensor_serialize   # save_ptd
  extension_flat_tensor             # FlatTensorDataMap (reader)
  extension_named_data_map          # MergedDataMap (Module multi-.ptd ctor)
  extension_module_static           # Module
  extension_data_loader             # FileDataLoader
  extension_tensor                  # make_tensor_ptr / TensorPtr
  executorch                        # the runtime
  portable_ops_lib)                 # registration for the .pte's aten ops
```

`portable_ops_lib` is the registration archive for the kernels an exported model names (for the
fixture here, `aten::addmm.out` and `aten::permute_copy.out`). Link it **normally**. Do **not**
whole-archive it on top of `executorch`: that registers the kernels twice and aborts at startup.
Add the delegate archive a delegated `.pte` needs (for example `xnnpack_backend`) the same way.

The installed headers are:

- `executorch/extension/flat_tensor/serialize/serialize.h` — `save_ptd`
- `executorch/extension/flat_tensor/serialize/flat_tensor_header.h` — `FlatTensorHeader`
- `executorch/extension/flat_tensor/flat_tensor_data_map.h` — `FlatTensorDataMap`
- `executorch/extension/named_data_map/merged_data_map.h` — `MergedDataMap`

## Loading a `.pte` with its `.ptd`

```cpp
#include <executorch/extension/module/module.h>

executorch::extension::Module module(pte_path, ptd_path);              // single file
executorch::extension::Module merged(pte_path, {ptd_a, ptd_b});        // vector<string> ctor
```

Both constructors are lazy: `forward()` (or `load()`) returns the first error. A `.ptd` that is
missing a key the `.pte` references makes load fail — it is never silently replaced with garbage.
The multi-file form goes through `MergedDataMap`; a duplicate key across files is an
`InvalidArgument` error, not a precedence rule, so split a checkpoint across files only into
disjoint key sets.

## Enumerating a `.ptd`

```cpp
#include <executorch/extension/data_loader/file_data_loader.h>
#include <executorch/extension/flat_tensor/flat_tensor_data_map.h>

auto loader = executorch::extension::FileDataLoader::from(ptd_path.c_str());
auto map = executorch::extension::FlatTensorDataMap::load(&loader.get());
// `loader` must outlive `map`; the map borrows the loader.

uint32_t n = map->get_num_keys().get();
for (uint32_t i = 0; i < n; ++i) {
  std::string key = map->get_key(i).get();
  auto layout = map->get_tensor_layout(key).get();   // scalar type, sizes, dim order
  auto data = map->get_data(key).get();              // read-only bytes
}
```

The reader accepts schema version 0 (`FlatTensorDataMap::kMaxSupportedSchemaVersion`) and returns
`Error::NotFound` for an unknown key. `FlatTensorHeader::Parse` over the first 64 bytes exposes the
file's offsets when you need to reason about alignment.

## Writing with `save_ptd`

```cpp
#include <executorch/extension/flat_tensor/serialize/serialize.h>

std::map<std::string, executorch::aten::Tensor> tensors;   // key -> tensor

// Path overload (binary mode — see the Windows note below).
executorch::runtime::Error e = save_ptd(path, tensors, 128);

// Stream overload. Open the stream yourself, in binary.
std::ofstream out(path, std::ios::binary);
e = save_ptd(out, tensors, 128);
```

- **Keys must match the names the `.pte` was exported with** (`lin.weight`, `lin.bias`, …). There is
  no lookup by position: the runtime resolves each external constant by name.
- **Use `tensor_alignment = 128`.** That is the default `segment_alignment` on both sides of
  upstream's pipeline (`ExecutorchBackendConfig` and `FlatTensorConfig` at ET v1.5.1), so a file
  written by the C++ writer and one written by the Python exporter agree on layout. `16` appears in
  upstream's examples only because those examples pass it.
- **Write in little-endian**, which is what the function does; it returns `Error::NotSupported` on a
  big-endian host.
- **Open the stream with `std::ios::binary`.** The stream overload cannot choose that for you.

### The path overload does not check that the file opened

Upstream's path overload calls `ofstream::open()` without checking it. Measured in the gate
(linux-x86_64): `save_ptd("<dir that does not exist>/x.ptd", tensors, 128)` returns `Error::Ok` and
writes **no file**. Create the target directory and/or check it yourself before calling:

```cpp
std::error_code ec;
std::filesystem::create_directories(std::filesystem::path(path).parent_path(), ec);
if (ec) { /* handle before saving */ }
```

That check is out of scope for the vendored patch; we fix only the corruption described next.

## Windows: the binary-mode patch

Upstream's path overload called `file.open(path)` with no `std::ios::binary`. MSVC's text mode
rewrites every `0x0A` byte as `0x0D 0x0A`, so a valid 376-byte `.ptd` became 385 bytes and the
runtime rejected it (`schema version … is newer` or `named_data is nullptr, malformed PTD`). This
repo vendors the one-line fix in `patches/et-flat-tensor-serialize-binary.patch`, so both overloads
write correct bytes on every platform. The stream overload was never affected. The patch is
destined for upstream and will be dropped when upstream lands a fix.

## `ET_EXPERIMENTAL`

`save_ptd` is declared `ET_EXPERIMENTAL`, which expands to
`[[deprecated("This API is experimental and may change without notice.")]]`. Every call therefore
emits `-Wdeprecated-declarations` (or C4996 under MSVC). A `-Werror` build must suppress it
locally; do not disable the warning project-wide:

```cmake
target_compile_options(my_target PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/wd4996>
  $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wno-deprecated-declarations>)
```

or, per call site:

```cpp
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4996)
#else
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
  auto e = save_ptd(path, tensors, 128);
#if defined(_MSC_VER)
#pragma warning(pop)
#else
#pragma GCC diagnostic pop
#endif
```

## Interchangeability with Python-written files

Files written here are interchangeable with the Python flat-tensor serializer
(`FlatTensorSerializer`, used by `export` with `external_constants=True`). The gate compares a
C++-written `.ptd` against a Python-written one **by content, not bytes**: same key set, and per key
the same scalar type, sizes, dim order and data bytes. Alignment and padding may legitimately
differ between writers, so a whole-file byte compare across writers is the wrong assertion (it is
only used between the two C++ overloads).

Measured dtype coverage (linux-x86_64, saved in one file and read back through
`FlatTensorDataMap`): `Float`, `Double`, `Half`, `BFloat16`, `Char`, `Byte`, `Int`, `Long`, `Bool`,
a 0-d `Float` scalar (`sizes = {}`), and a zero-element `Float` tensor (`sizes = {0, 3}`). All
round-trip with their type, shape, dim order and bytes intact; there are no known-rejected cases.

## Why `extension_training` is not shipped

We do **not** build upstream's `extension_training` (`TrainingModule`, the C++ `SGD`). Upstream
calls the extension experimental and a technical preview, and every public class is
`ET_EXPERIMENTAL`; only SGD exists at v1.5.1. The training consumer here runs its optimizer in
numpy and copies weights into the method, so an unstable C++ optimizer would add surface and upkeep
without a user. That is a product choice, not a build constraint (the spike showed it would compile
with no new dependency). `save_ptd` itself is also `ET_EXPERIMENTAL`, but we ship it because there
is no other writer in the runtime and its format is pinned by `kSchemaVersion` and checked by the
reader.

See [`docs/superpowers/specs/2026-10-25-ptd-writer-design.md`](superpowers/specs/2026-10-25-ptd-writer-design.md)
for the full design, and `test/ptd_writer_run.sh` for the behavioural gate that runs against every
shipped prefix.
