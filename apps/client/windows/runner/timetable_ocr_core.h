#ifndef RUNNER_TIMETABLE_OCR_CORE_H_
#define RUNNER_TIMETABLE_OCR_CORE_H_

#include <cstdint>
#include <string>
#include <vector>

struct TimetableOcrWord {
  std::string text;
  double x, y, width, height;
};
struct TimetableOcrLine {
  std::string text;
  std::vector<TimetableOcrWord> words;
};
struct TimetableOcrResult {
  std::string language;
  uint32_t width, height;
  std::vector<TimetableOcrLine> lines;
};

// Called on a background thread with a WinRT MTA initialized. Never uses the
// network, a user's calendar, or an external process.
TimetableOcrResult RecognizeTimetableImage(const std::vector<uint8_t>& bytes);

#endif
