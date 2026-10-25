// Round-trip gate for the .ptd writer, built against an INSTALLED ExecuTorch prefix only. It must
// fail to configure or link if extension_flat_tensor_serialize, or any of the four installed
// headers, is missing from the tarball.
//
// Checks:
//   baseline              Module(pte, exporter-written ptd) reproduces the eager golden
//   write_both_overloads  save_ptd(path) and save_ptd(stream) agree byte for byte, into a
//                         directory whose name contains a space (common on Windows)
//   reload_single         Module(pte, written-ptd) reproduces the doubled golden
//   reload_merged         Module(pte, {written-ptd}) (MergedDataMap path) reproduces it too
//   cross_writer_content  written file and the Python-written reference agree per key
//   alignment_128         the header's segment base offset honours the requested alignment
//   overwrite_truncates   a smaller checkpoint over a larger one truncates and reloads
//   missing_key_fails     a .ptd missing a key the .pte needs is a reported error, not garbage
//   unopenable_path       saving into a nonexistent directory is documented behaviour, not a crash
//
// Usage: ptd_roundtrip <fixture-dir> <out-dir>
#include <executorch/extension/data_loader/file_data_loader.h>
#include <executorch/extension/flat_tensor/flat_tensor_data_map.h>
#include <executorch/extension/flat_tensor/serialize/flat_tensor_header.h>
#include <executorch/extension/flat_tensor/serialize/serialize.h>
#include <executorch/extension/module/module.h>
#include <executorch/extension/named_data_map/merged_data_map.h>
#include <executorch/extension/tensor/tensor_ptr.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;

using executorch::aten::ScalarType;
using executorch::extension::FileDataLoader;
using executorch::extension::FlatTensorDataMap;
using executorch::extension::FlatTensorHeader;
using executorch::extension::Module;
using executorch::extension::TensorPtr;
using executorch::extension::flat_tensor::save_ptd;
using executorch::runtime::Error;

namespace {

int failures = 0;

// One line per check, ok: or FAIL:, so the gate log reads like the other behavioural gates.
bool check(bool pass, const std::string& name, const std::string& detail = "") {
  if (pass) {
    std::printf("ok: %s\n", name.c_str());
  } else {
    std::printf("FAIL: %s%s%s\n", name.c_str(), detail.empty() ? "" : " -- ", detail.c_str());
    ++failures;
  }
  return pass;
}

struct Blob {
  std::vector<int32_t> sizes;
  std::vector<uint8_t> dim_order;
  ScalarType type = ScalarType::Float;
  std::vector<uint8_t> bytes;
};

std::vector<uint8_t> read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return std::vector<uint8_t>(
      std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// Reads every key of a .ptd through the installed reader API.
bool load_blobs(const std::string& path, std::map<std::string, Blob>& out) {
  auto loader = FileDataLoader::from(path.c_str());
  if (!loader.ok()) {
    return false;
  }
  auto map = FlatTensorDataMap::load(&loader.get());
  if (!map.ok()) {
    return false;
  }
  auto num_keys = map->get_num_keys();
  if (!num_keys.ok()) {
    return false;
  }
  for (uint32_t i = 0; i < num_keys.get(); ++i) {
    auto key = map->get_key(i);
    if (!key.ok()) {
      return false;
    }
    auto layout = map->get_tensor_layout(key.get());
    if (!layout.ok()) {
      return false;
    }
    auto data = map->get_data(key.get());
    if (!data.ok()) {
      return false;
    }
    Blob blob;
    blob.sizes.assign(layout->sizes().begin(), layout->sizes().end());
    blob.dim_order.assign(layout->dim_order().begin(), layout->dim_order().end());
    blob.type = layout->scalar_type();
    const auto* bytes = static_cast<const uint8_t*>(data->data());
    if (data->size() > 0) {
      blob.bytes.assign(bytes, bytes + data->size());
    }
    out.emplace(std::string(key.get()), std::move(blob));
  }
  return true;
}

// The TensorPtrs own the bytes; keep them alive for as long as the tensor map is used.
std::map<std::string, executorch::aten::Tensor> to_tensor_map(
    const std::map<std::string, Blob>& blobs,
    std::vector<TensorPtr>& keep_alive) {
  std::map<std::string, executorch::aten::Tensor> tensors;
  for (const auto& [key, blob] : blobs) {
    auto ptr = executorch::extension::make_tensor_ptr(
        std::vector<int32_t>(blob.sizes.begin(), blob.sizes.end()),
        blob.bytes,
        std::vector<uint8_t>(blob.dim_order.begin(), blob.dim_order.end()),
        {},
        blob.type);
    keep_alive.push_back(ptr);
    tensors.emplace(key, *ptr);
  }
  return tensors;
}

void double_float_bytes(Blob& blob) {
  for (size_t i = 0; i + sizeof(float) <= blob.bytes.size(); i += sizeof(float)) {
    float value;
    std::memcpy(&value, blob.bytes.data() + i, sizeof(float));
    value *= 2.0f;
    std::memcpy(blob.bytes.data() + i, &value, sizeof(float));
  }
}

std::vector<float> floats_from_file(const std::string& path) {
  std::vector<uint8_t> bytes = read_file(path);
  std::vector<float> values(bytes.size() / sizeof(float));
  std::memcpy(values.data(), bytes.data(), values.size() * sizeof(float));
  return values;
}

bool match(const std::vector<float>& got, const std::vector<float>& want) {
  if (got.size() != want.size()) {
    return false;
  }
  for (size_t i = 0; i < got.size(); ++i) {
    if (std::fabs(got[i] - want[i]) > 1e-6f) {
      return false;
    }
  }
  return true;
}

// Runs the model on the fixture input and returns the outputs, or empty on any error.
std::vector<float> run(Module& module) {
  auto input = executorch::extension::make_tensor_ptr(
      {1, 3}, std::vector<float>{1.0f, 1.0f, 1.0f});
  auto result = module.forward(input);
  if (!result.ok() || result.get().empty()) {
    return {};
  }
  const auto& tensor = result.get()[0].toTensor();
  const float* data = tensor.const_data_ptr<float>();
  return std::vector<float>(data, data + tensor.numel());
}

bool same_content(const std::map<std::string, Blob>& a, const std::map<std::string, Blob>& b,
                  std::string& detail) {
  if (a.size() != b.size()) {
    detail = "key count differs: " + std::to_string(a.size()) + " vs " +
        std::to_string(b.size());
    return false;
  }
  for (const auto& [key, left] : a) {
    auto it = b.find(key);
    if (it == b.end()) {
      detail = "missing key " + key;
      return false;
    }
    const Blob& right = it->second;
    if (left.type != right.type) {
      detail = key + ": scalar type differs";
      return false;
    }
    if (left.sizes != right.sizes) {
      detail = key + ": sizes differ";
      return false;
    }
    if (left.dim_order != right.dim_order) {
      detail = key + ": dim order differs";
      return false;
    }
    if (left.bytes != right.bytes) {
      detail = key + ": data bytes differ";
      return false;
    }
  }
  return true;
}

} // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::printf("usage: ptd_roundtrip <fixture-dir> <out-dir>\n");
    return 2;
  }
  const std::string fixtures = argv[1];
  const std::string out_dir = argv[2];
  const std::string pte = fixtures + "/linear.pte";
  const std::string exporter_ptd = fixtures + "/linear.ptd";
  const std::string reference_ptd = fixtures + "/linear_x2.ptd";

  std::error_code ec;
  fs::create_directories(out_dir, ec);
  // Deliberately a directory with a space in it: Windows home directories routinely have one, and
  // the stream/path overloads must both handle it.
  const std::string spaced = out_dir + "/dir with space";
  fs::create_directories(spaced, ec);

  // 1. Baseline: the exporter's .ptd is readable and reproduces the eager golden.
  {
    Module module(pte, exporter_ptd);
    check(match(run(module), floats_from_file(fixtures + "/out_base.bin")), "baseline");
  }

  // 2. Read the exporter's .ptd, double every tensor, and write it back through both overloads.
  std::map<std::string, Blob> doubled;
  if (!load_blobs(exporter_ptd, doubled)) {
    check(false, "write_both_overloads", "could not read " + exporter_ptd);
    return 1;
  }
  for (auto& [key, blob] : doubled) {
    if (blob.type != ScalarType::Float) {
      check(false, "write_both_overloads", key + " is not float");
      return 1;
    }
    double_float_bytes(blob);
  }

  const std::string written_path = spaced + "/written_path.ptd";
  const std::string written_stream = spaced + "/written_stream.ptd";
  std::vector<TensorPtr> keep_alive;
  auto doubled_tensors = to_tensor_map(doubled, keep_alive);
  {
    Error path_error = save_ptd(written_path, doubled_tensors, 128);
    std::ofstream stream(written_stream, std::ios::binary);
    Error stream_error = save_ptd(stream, doubled_tensors, 128);
    stream.close();

    const std::vector<uint8_t> from_path = read_file(written_path);
    const std::vector<uint8_t> from_stream = read_file(written_stream);
    check(
        path_error == Error::Ok && stream_error == Error::Ok && !from_path.empty() &&
            from_path == from_stream,
        "write_both_overloads",
        "path=" + std::to_string(static_cast<int>(path_error)) + " stream=" +
            std::to_string(static_cast<int>(stream_error)) + " sizes=" +
            std::to_string(from_path.size()) + "/" + std::to_string(from_stream.size()));
  }

  // 3. Both Module constructors reload the written file to the doubled output.
  {
    Module module(pte, written_path);
    check(match(run(module), floats_from_file(fixtures + "/out_x2.bin")), "reload_single");
  }
  {
    Module module(pte, std::vector<std::string>{written_path});
    check(match(run(module), floats_from_file(fixtures + "/out_x2.bin")), "reload_merged");
  }

  // 4. Cross-writer content: the Python-written reference for the same doubled weights. Compare
  //    per key, never whole files: alignment and padding may legitimately differ between writers.
  {
    std::map<std::string, Blob> mine;
    std::map<std::string, Blob> reference;
    std::string detail;
    bool read_ok = load_blobs(written_path, mine) && load_blobs(reference_ptd, reference);
    check(
        read_ok && same_content(mine, reference, detail),
        "cross_writer_content",
        read_ok ? detail : "could not read a file");
  }

  // 5. The requested alignment is honoured. FlatTensorHeader exposes the segment base offset only;
  //    per-segment offsets live in the flatbuffer, whose generated headers are deliberately not
  //    installed, so the base offset is the reachable assertion.
  {
    const std::vector<uint8_t> head = read_file(written_path);
    std::string detail = "file too short";
    bool pass = false;
    if (head.size() >= FlatTensorHeader::kNumHeadBytes) {
      auto header = FlatTensorHeader::Parse(head.data(), FlatTensorHeader::kNumHeadBytes);
      if (!header.ok()) {
        detail = "header parse failed";
      } else {
        pass = header->segment_base_offset % 128 == 0;
        detail = "segment_base_offset=" + std::to_string(header->segment_base_offset);
      }
    }
    check(pass, "alignment_128", detail);
  }

  // 6. Overwriting a larger checkpoint with a smaller one must truncate: this is the shape a
  //    training loop hits on every step, and it pins that the binary-mode fix kept truncation.
  {
    Blob pad;
    pad.sizes = {4096};
    pad.type = ScalarType::Float;
    pad.bytes.assign(4096 * sizeof(float), 0x01);
    std::map<std::string, Blob> larger = doubled;
    larger["pad"] = pad;

    const std::string path = out_dir + "/overwrite.ptd";
    std::vector<TensorPtr> larger_keep_alive;
    auto larger_tensors = to_tensor_map(larger, larger_keep_alive);
    Error first = save_ptd(path, larger_tensors, 128);
    const size_t larger_size = fs::file_size(path, ec);
    Error second = save_ptd(path, doubled_tensors, 128);
    const size_t final_size = fs::file_size(path, ec);

    Module module(pte, path);
    bool reloads = match(run(module), floats_from_file(fixtures + "/out_x2.bin"));
    check(
        first == Error::Ok && second == Error::Ok && larger_size > final_size &&
            final_size == read_file(written_stream).size() && reloads,
        "overwrite_truncates",
        "sizes " + std::to_string(larger_size) + " then " + std::to_string(final_size));
  }

  // 7. A .ptd missing a key the .pte needs must produce an error, never garbage output.
  {
    std::map<std::string, Blob> partial;
    partial.emplace("lin.weight", doubled.at("lin.weight"));
    const std::string path = out_dir + "/missing_key.ptd";
    std::vector<TensorPtr> partial_keep_alive;
    auto partial_tensors = to_tensor_map(partial, partial_keep_alive);
    Error saved = save_ptd(path, partial_tensors, 128);

    Module module(pte, path);
    auto input = executorch::extension::make_tensor_ptr(
        {1, 3}, std::vector<float>{1.0f, 1.0f, 1.0f});
    auto result = module.forward(input);
    check(
        saved == Error::Ok && !result.ok(),
        "missing_key_fails",
        "saved=" + std::to_string(static_cast<int>(saved)) +
            " forward_ok=" + std::to_string(static_cast<int>(result.ok())));
  }

  // 8. Upstream's path overload never checks that the file opened. Record, rather than assume,
  //    what that means: Ok-with-no-file is the expected quirk, an error is also acceptable, but Ok
  //    WITH a file is not. The consumer doc states whichever this observes.
  {
    const std::string path = out_dir + "/no/such/dir/x.ptd";
    Error saved = save_ptd(path, doubled_tensors, 128);
    const bool exists = fs::exists(path, ec);
    if (saved == Error::Ok && !exists) {
      check(true, "unopenable_path", "save_ptd returned Ok and wrote no file (documented)");
    } else if (saved != Error::Ok && !exists) {
      check(
          true,
          "unopenable_path",
          "save_ptd returned " + std::to_string(static_cast<int>(saved)) + " and wrote no file");
    } else {
      check(false, "unopenable_path", "returned Ok and created the file, or error with a file");
    }
  }

  if (failures != 0) {
    std::printf("RESULT: FAIL (%d)\n", failures);
    return 1;
  }
  std::printf("RESULT: PASS\n");
  return 0;
}
