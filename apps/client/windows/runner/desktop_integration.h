#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
#include <string>

class DesktopIntegration {
 public:
  DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopIntegration();
  void OpenWindow();
  std::optional<LRESULT> Handle(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  bool AddTray();
  void ShowMenu();
  bool Notify(const std::string& title, const std::string& body,
              const std::string& event_id);
  HWND window_;
  HICON icon_ = nullptr;
  NOTIFYICONDATAW tray_{};
  bool added_ = false;
  UINT taskbar_created_;
  std::string notification_event_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
