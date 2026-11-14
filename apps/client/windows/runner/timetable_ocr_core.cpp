#include "timetable_ocr_core.h"

#include <algorithm>
#include <stdexcept>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

TimetableOcrResult RecognizeTimetableImage(const std::vector<uint8_t>& bytes) {
  using namespace winrt::Windows;
  using namespace Graphics::Imaging;
  using namespace Media::Ocr;
  using namespace Storage::Streams;
  if (bytes.empty() || bytes.size() > 25 * 1024 * 1024) {
    throw std::runtime_error("image_size");
  }
  OcrEngine engine{nullptr};
  for (const auto& language : OcrEngine::AvailableRecognizerLanguages()) {
    if (std::wstring_view(language.LanguageTag()).substr(0, 2) == L"zh") {
      engine = OcrEngine::TryCreateFromLanguage(language);
      if (engine) break;
    }
  }
  if (!engine) throw std::runtime_error("chinese_unavailable");

  InMemoryRandomAccessStream stream;
  DataWriter writer(stream);
  writer.WriteBytes(bytes);
  writer.StoreAsync().get();
  writer.FlushAsync().get();
  writer.DetachStream();
  stream.Seek(0);
  const auto decoder = BitmapDecoder::CreateAsync(stream).get();
  const auto width = decoder.PixelWidth();
  const auto height = decoder.PixelHeight();
  if (!width || !height || static_cast<uint64_t>(width) * height > 80000000) {
    throw std::runtime_error("image_dimensions");
  }
  const auto limit = OcrEngine::MaxImageDimension();
  const auto scale = std::min(1.0, static_cast<double>(limit) /
      static_cast<double>(std::max(width, height)));
  BitmapTransform transform;
  transform.ScaledWidth(std::max(1u, static_cast<uint32_t>(width * scale)));
  transform.ScaledHeight(std::max(1u, static_cast<uint32_t>(height * scale)));
  const auto bitmap = decoder.GetSoftwareBitmapAsync(
      BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore, transform,
      ExifOrientationMode::RespectExifOrientation,
      ColorManagementMode::DoNotColorManage).get();
  const auto recognized = engine.RecognizeAsync(bitmap).get();
  TimetableOcrResult result{winrt::to_string(engine.RecognizerLanguage().LanguageTag()),
      static_cast<uint32_t>(bitmap.PixelWidth()),
      static_cast<uint32_t>(bitmap.PixelHeight()), {}};
  for (const auto& line : recognized.Lines()) {
    TimetableOcrLine output{winrt::to_string(line.Text()), {}};
    for (const auto& word : line.Words()) {
      const auto box = word.BoundingRect();
      output.words.push_back({winrt::to_string(word.Text()), box.X, box.Y,
                             box.Width, box.Height});
    }
    result.lines.push_back(std::move(output));
  }
  return result;
}
