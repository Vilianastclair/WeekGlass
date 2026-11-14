#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

inline constexpr wchar_t kWeekGlassWindowClass[] = L"Viliana.WeekGlass.Window";

// Keep this identity stable across versions and portable installation paths.
class SingleInstance {
 public:
  SingleInstance();
  ~SingleInstance();
  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  bool valid() const { return mutex_ != nullptr; }
  bool AcquireOrActivate();
  static UINT ActivationMessage();
  static void Activate(HWND window);

 private:
  HANDLE mutex_ = nullptr;
  bool owns_mutex_ = false;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
