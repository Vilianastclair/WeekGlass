#include "timetable_ocr.h"
#include "timetable_ocr_core.h"

#include <flutter/standard_method_codec.h>
#include <cstring>
#include <stdexcept>
#include <winrt/base.h>

namespace {
constexpr UINT kOcrFinished = WM_APP + 117;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

Value Encode(const TimetableOcrResult& result) {
  List lines;
  for (const auto& line : result.lines) {
    List words;
    for (const auto& word : line.words) {
      words.emplace_back(Map{{Value("text"), Value(word.text)},
        {Value("x"), Value(word.x)}, {Value("y"), Value(word.y)},
        {Value("width"), Value(word.width)}, {Value("height"), Value(word.height)}});
    }
    lines.emplace_back(Map{{Value("text"), Value(line.text)},
                           {Value("words"), Value(words)}});
  }
  return Value(Map{{Value("language"), Value(result.language)},
    {Value("width"), Value(static_cast<int32_t>(result.width))},
    {Value("height"), Value(static_cast<int32_t>(result.height))},
    {Value("lines"), Value(lines)}});
}

std::vector<uint8_t> ClipboardImage(HWND window) {
  if (!OpenClipboard(window)) throw std::runtime_error("clipboard_busy");
  struct Close { ~Close() { CloseClipboard(); } } close;
  const UINT png = RegisterClipboardFormatW(L"PNG");
  const bool is_png = IsClipboardFormatAvailable(png) != FALSE;
  const UINT format = is_png ? png : IsClipboardFormatAvailable(CF_DIBV5)
      ? CF_DIBV5 : CF_DIB;
  if (!IsClipboardFormatAvailable(format)) return {};
  const auto handle = GetClipboardData(format);
  if (!handle) throw std::runtime_error("clipboard_unavailable");
  const SIZE_T size = GlobalSize(handle);
  if (!size || size > 25 * 1024 * 1024) throw std::runtime_error("image_size");
  const auto data = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!data) throw std::runtime_error("clipboard_unavailable");
  struct Unlock { HANDLE handle; ~Unlock() { GlobalUnlock(handle); } } unlock{handle};
  if (is_png) return std::vector<uint8_t>(data, data + size);
  if (size < sizeof(BITMAPINFOHEADER)) throw std::runtime_error("image_format");
  BITMAPINFOHEADER info{};
  std::memcpy(&info, data, sizeof(info));
  if (info.biSize < sizeof(BITMAPINFOHEADER) || info.biSize > size) {
    throw std::runtime_error("image_format");
  }
  const auto colors = info.biClrUsed ? info.biClrUsed :
      info.biBitCount <= 8 ? (1u << info.biBitCount) : 0u;
  const auto masks = info.biSize == sizeof(BITMAPINFOHEADER) &&
      info.biCompression == BI_BITFIELDS ? 3u * sizeof(DWORD) : 0u;
  const size_t offset = sizeof(BITMAPFILEHEADER) + info.biSize + masks +
      static_cast<size_t>(colors) * sizeof(RGBQUAD);
  if (offset > sizeof(BITMAPFILEHEADER) + size) throw std::runtime_error("image_format");
  BITMAPFILEHEADER header{};
  header.bfType = 0x4d42;
  header.bfSize = static_cast<DWORD>(size + sizeof(header));
  header.bfOffBits = static_cast<DWORD>(offset);
  std::vector<uint8_t> bytes(size + sizeof(header));
  std::memcpy(bytes.data(), &header, sizeof(header));
  std::memcpy(bytes.data() + sizeof(header), data, size);
  return bytes;
}
}

TimetableOcr::TimetableOcr(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "weekglass/timetable_ocr", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "clipboardImage") {
      try { result->Success(Value(ClipboardImage(window_))); }
      catch (const std::exception& error) { result->Error(error.what(), "Clipboard image unavailable"); }
      return;
    }
    if (call.method_name() != "recognize") { result->NotImplemented(); return; }
    const auto bytes = call.arguments()
        ? std::get_if<std::vector<uint8_t>>(call.arguments()) : nullptr;
    if (!bytes) { result->Error("image_format", "Expected image bytes"); return; }
    if (pending_) { result->Error("busy", "An image is already being recognized"); return; }
    if (bytes->empty() || bytes->size() > 25 * 1024 * 1024) {
      result->Error("image_size", "Image must be between 1 byte and 25 MB"); return;
    }
    pending_ = std::move(result);
    error_.clear();
    worker_ = std::thread([this, bytes = *bytes]() {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment { ~Apartment() { winrt::uninit_apartment(); } } apartment;
        output_ = Encode(RecognizeTimetableImage(bytes));
      } catch (const winrt::hresult_error&) {
        error_ = "ocr_unavailable";
      } catch (const std::exception& error) {
        error_ = error.what();
      } catch (...) {
        error_ = "ocr_unavailable";
      }
      PostMessageW(window_, kOcrFinished, 0, 0);
    });
  });
}

TimetableOcr::~TimetableOcr() {
  channel_->SetMethodCallHandler(nullptr);
  if (worker_.joinable()) worker_.join();
}

std::optional<LRESULT> TimetableOcr::Handle(UINT message) {
  if (message != kOcrFinished) return std::nullopt;
  if (worker_.joinable()) worker_.join();
  if (pending_) {
    if (error_.empty()) pending_->Success(output_);
    else pending_->Error(error_, "Local image recognition could not finish");
    pending_.reset();
    output_ = Value();
  }
  return 0;
}
