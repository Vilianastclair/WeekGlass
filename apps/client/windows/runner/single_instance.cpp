#include "single_instance.h"

SingleInstance::SingleInstance() {
  mutex_ = CreateMutexW(nullptr, FALSE,
                        L"Local\\Viliana.WeekGlass.SingleInstance.v1");
}

SingleInstance::~SingleInstance() {
  if (owns_mutex_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}

UINT SingleInstance::ActivationMessage() {
  static const UINT message =
      RegisterWindowMessageW(L"Viliana.WeekGlass.Activate.v1");
  return message;
}

bool SingleInstance::AcquireOrActivate() {
  if (!mutex_) return false;
  // A rapid double launch may reach here before the first window exists.
  // Recheck the mutex as well: an exiting/crashed owner must not block restart.
  const ULONGLONG deadline = GetTickCount64() + 10000;
  do {
    const DWORD result = WaitForSingleObject(mutex_, 0);
    if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
      owns_mutex_ = true;
      return true;
    }
    if (result == WAIT_FAILED) return false;
    if (HWND window = FindWindowW(kWeekGlassWindowClass, nullptr)) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(window, &process_id);
      AllowSetForegroundWindow(process_id);
      PostMessageW(window, ActivationMessage(), 0, 0);
      return false;
    }
    Sleep(50);
  } while (GetTickCount64() < deadline);
  // Never create a second engine/database connection while the owner exists.
  return false;
}

void SingleInstance::Activate(HWND window) {
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else if (!IsWindowVisible(window)) {
    ShowWindow(window, SW_SHOW);
  }
  if (!SetForegroundWindow(window)) {
    FLASHWINFO flash{sizeof(FLASHWINFO), window, FLASHW_TRAY, 2, 0};
    FlashWindowEx(&flash);
  }
}
