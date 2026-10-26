// Dtype sweep for the .ptd writer: one tensor per scalar type, plus a 0-d scalar and a
// zero-element tensor. Saves them all in one .ptd at alignment 128 and reads every one back
// through the installed reader, asserting scalar type, sizes, dim order and bytes per key.
//
// A dtype or shape that save_ptd or the loader rejects is a FAIL line naming the key, never a
// silently dropped case: a dropped case is how a format gap ships.
//
// Usage: ptd_dtype_sweep <out-dir>
#include <executorch/extension/data_loader/file_data_loader.h>
#include <executorch/extension/flat_tensor/flat_tensor_data_map.h>
#include <executorch/extension/flat_tensor/serialize/serialize.h>
#include <executorch/extension/tensor/tensor_ptr.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;

using executorch::aten::ScalarType;
using executorch::extension::FileDataLoader;
using executorch::extension::FlatTensorDataMap;
using executorch::extension::TensorPtr;
using executorch::extension::flat_tensor::save_ptd;
using executorch::runtime::Error;

namespace {

int failures = 0;

struct Case {
  std::string key;
  ScalarType type;
  std::vector<int32_t> sizes;
  std::vector<uint8_t> bytes;
};

size_t numel_of(const std::vector<int32_t>& sizes) {
  size_t n = 1;
  for (int32_t d : sizes) {
    n *= static_cast<size_t>(d);
  }
  return n;
}

// Distinct, non-zero bytes (Bool must stay 0/1). The writer and reader are byte-transparent, so a
// recognizable pattern catches an accidental reinterpretation or a truncated segment.
std::vector<uint8_t> pattern(ScalarType type, const std::vector<int32_t>& sizes) {
  const size_t nbytes = numel_of(sizes) * executorch::aten::elementSize(type);
  std::vector<uint8_t> bytes(nbytes);
  for (size_t i = 0; i < nbytes; ++i) {
    bytes[i] = static_cast<uint8_t>(0x11 + (i * 7) % 0x40);
  }
  if (type == ScalarType::Bool) {
    for (auto& byte : bytes) {
      byte &= 1;
    }
  }
  return bytes;
}

} // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::printf("usage: ptd_dtype_sweep <out-dir>\n");
    return 2;
  }
  const std::string out_dir = argv[1];
  std::error_code ec;
  fs::create_directories(out_dir, ec);

  const std::vector<std::pair<std::string, ScalarType>> typed = {
      {"float", ScalarType::Float},
      {"double", ScalarType::Double},
      {"half", ScalarType::Half},
      {"bfloat16", ScalarType::BFloat16},
      {"char", ScalarType::Char},
      {"byte", ScalarType::Byte},
      {"int", ScalarType::Int},
      {"long", ScalarType::Long},
      {"bool", ScalarType::Bool},
  };

  std::vector<Case> cases;
  for (const auto& [key, type] : typed) {
    cases.push_back({key, type, {2, 3}, pattern(type, {2, 3})});
  }
  // A 0-d scalar (sizes {}) has one element; a zero-element tensor has none. Both exercise layout
  // and segment-size edges that a fixed 2-d sweep never reaches.
  cases.push_back({"scalar_0d", ScalarType::Float, {}, pattern(ScalarType::Float, {})});
  cases.push_back({"empty", ScalarType::Float, {0, 3}, pattern(ScalarType::Float, {0, 3})});

  std::vector<TensorPtr> keep_alive;
  std::map<std::string, executorch::aten::Tensor> tensors;
  for (const auto& c : cases) {
    auto ptr = executorch::extension::make_tensor_ptr(c.sizes, c.bytes, {}, {}, c.type);
    keep_alive.push_back(ptr);
    tensors.emplace(c.key, *ptr);
  }

  const std::string path = out_dir + "/dtypes.ptd";
  const Error saved = save_ptd(path, tensors, 128);
  if (saved != Error::Ok) {
    std::printf(
        "FAIL: dtype sweep save rejected: error %d\n", static_cast<int>(saved));
    return 1;
  }

  auto loader = FileDataLoader::from(path.c_str());
  if (!loader.ok()) {
    std::printf(
        "FAIL: dtype sweep loader rejected: error %d\n",
        static_cast<int>(loader.error()));
    return 1;
  }
  auto map = FlatTensorDataMap::load(&loader.get());
  if (!map.ok()) {
    std::printf(
        "FAIL: dtype sweep FlatTensorDataMap rejected: error %d\n",
        static_cast<int>(map.error()));
    return 1;
  }
  auto num_keys = map->get_num_keys();
  if (!num_keys.ok() || num_keys.get() != cases.size()) {
    std::printf(
        "FAIL: dtype sweep key count: got %u want %zu\n",
        num_keys.ok() ? num_keys.get() : 0u,
        cases.size());
    return 1;
  }

  for (const auto& c : cases) {
    // Compare against what the tensor layer actually produced (dim order is derived there), not
    // against the empty override we passed in.
    const auto& tensor = tensors.at(c.key);
    std::vector<int32_t> want_sizes(tensor.sizes().begin(), tensor.sizes().end());
    std::vector<uint8_t> want_order(tensor.dim_order().begin(), tensor.dim_order().end());

    auto layout = map->get_tensor_layout(c.key);
    if (!layout.ok()) {
      std::printf(
          "FAIL: %s rejected: layout error %d\n",
          c.key.c_str(),
          static_cast<int>(layout.error()));
      // Keep going: one rejected dtype must not hide the status of every later one.
      ++failures;
      continue;
    }
    auto data = map->get_data(c.key);
    if (!data.ok()) {
      std::printf(
          "FAIL: %s rejected: data error %d\n",
          c.key.c_str(),
          static_cast<int>(data.error()));
      ++failures;
      continue;
    }

    std::vector<int32_t> got_sizes(layout->sizes().begin(), layout->sizes().end());
    std::vector<uint8_t> got_order(
        layout->dim_order().begin(), layout->dim_order().end());
    std::vector<uint8_t> got_bytes;
    if (data->size() > 0) {
      const auto* bytes = static_cast<const uint8_t*>(data->data());
      got_bytes.assign(bytes, bytes + data->size());
    }

    std::string detail;
    if (layout->scalar_type() != c.type) {
      detail = "scalar type";
    } else if (got_sizes != want_sizes) {
      detail = "sizes";
    } else if (got_order != want_order) {
      detail = "dim order";
    } else if (got_bytes != c.bytes) {
      detail = "bytes";
    }

    if (detail.empty()) {
      std::printf("ok: %s\n", c.key.c_str());
    } else {
      std::printf("FAIL: %s: %s differs\n", c.key.c_str(), detail.c_str());
      ++failures;
    }
  }

  if (failures != 0) {
    std::printf("RESULT: FAIL (%d)\n", failures);
    return 1;
  }
  std::printf("RESULT: PASS (%zu dtypes/shapes)\n", cases.size());
  return 0;
}
