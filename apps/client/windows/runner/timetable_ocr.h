#ifndef RUNNER_TIMETABLE_OCR_H_
#define RUNNER_TIMETABLE_OCR_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
#include <thread>

class TimetableOcr {
 public:
  TimetableOcr(HWND window, flutter::BinaryMessenger* messenger);
  ~TimetableOcr();
  std::optional<LRESULT> Handle(UINT message);

 private:
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_;
  std::thread worker_;
  flutter::EncodableValue output_;
  std::string error_;
};
#endif
