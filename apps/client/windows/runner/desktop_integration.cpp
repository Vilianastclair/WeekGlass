#include "desktop_integration.h"

#include <algorithm>
#include <flutter/standard_method_codec.h>

#include "resource.h"
#include "vortex_transition.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 101;
constexpr UINT kOpen = 1;
constexpr UINT kExit = 2;
constexpr GUID kTrayGuid = {0xf8e92736, 0x7103, 0x4981,
                           {0x91, 0xe6, 0x40, 0x1b, 0xf6, 0x51, 0x1e, 0x20}};
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const auto size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                      static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), size);
  return result;
}
template <size_t N>
void CopyText(wchar_t (&destination)[N], const std::wstring& value) {
  size_t length = std::min(value.size(), N - 1);
  if (length && value[length - 1] >= 0xD800 && value[length - 1] <= 0xDBFF) --length;
  wmemcpy(destination, value.data(), length);
  destination[length] = 0;
}
std::string StringArg(const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return {};
  const auto value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string{};
}
}

DesktopIntegration::DesktopIntegration(HWND window, VortexTransition& vortex, flutter::BinaryMessenger* messenger)
    : window_(window), vortex_(vortex), taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  // LoadImage works with the standard Windows activation context. LoadIconMetric
  // requires common-controls v6 and can prevent the whole app from loading.
  icon_ = static_cast<HICON>(LoadImageW(GetModuleHandle(nullptr),
    MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
    GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.guidItem = kTrayGuid;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = icon_;
  CopyText(tray_.szTip, L"WeekGlass \u5468\u8ba1\u5212");
  AddTray();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    messenger, "weekglass/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setWindowMotion") {
      const auto mode = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!mode || !vortex_.SetMode(*mode)) {
        result->Error("invalid_arguments", "Unknown window motion"); return;
      }
      result->Success();
    } else if (call.method_name() == "notify") {
      const auto args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args) { result->Error("invalid_arguments", "Expected notification fields"); return; }
      result->Success(flutter::EncodableValue(Notify(StringArg(*args, "title"),
        StringArg(*args, "body"), StringArg(*args, "eventId"))));
    } else {
      result->NotImplemented();
    }
  });
}

DesktopIntegration::~DesktopIntegration() {
  channel_->SetMethodCallHandler(nullptr);
  tray_.uFlags = NIF_GUID;
  if (added_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  if (icon_) DestroyIcon(icon_);
}

bool DesktopIntegration::AddTray() {
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_GUID | NIF_SHOWTIP;
  added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (added_) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  }
  return added_;
}

bool DesktopIntegration::Notify(const std::string& title, const std::string& body,
                                const std::string& event_id) {
  if ((!added_ && !AddTray()) || body.empty()) return false;
  auto notification = tray_;
  notification.uFlags = NIF_GUID | NIF_INFO | NIF_REALTIME;
  notification.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND | NIIF_RESPECT_QUIET_TIME;
  CopyText(notification.szInfoTitle, Wide(title));
  CopyText(notification.szInfo, Wide(body));
  if (!Shell_NotifyIconW(NIM_MODIFY, &notification)) return false;
  notification_event_ = event_id;
  return true;
}

void DesktopIntegration::OpenWindow() {
  vortex_.Open();
  channel_->InvokeMethod("openApp", nullptr);
}

void DesktopIntegration::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kOpen, L"\u6253\u5f00 WeekGlass");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExit, L"\u9000\u51fa WeekGlass");
  SetMenuDefaultItem(menu, kOpen, FALSE);
  POINT position{};
  GetCursorPos(&position);
  SetForegroundWindow(window_);
  const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY |
    TPM_RIGHTBUTTON, position.x, position.y, 0, window_, nullptr);
  DestroyMenu(menu);
  if (action == kExit) {
    DestroyWindow(window_);
  } else {
    if (action == kOpen) OpenWindow();
    PostMessageW(window_, WM_NULL, 0, 0);
  }
}

std::optional<LRESULT> DesktopIntegration::Handle(UINT message, WPARAM wparam,
                                                  LPARAM lparam) {
  if (message == taskbar_created_) { added_ = false; AddTray(); return 0; }
  if (message == WM_CLOSE && (added_ || AddTray())) {
    NOTIFYICONIDENTIFIER id{};
    id.cbSize = sizeof(id); id.hWnd = window_; id.uID = tray_.uID; id.guidItem = kTrayGuid;
    RECT r{};
    std::optional<POINT> icon;
    if (SUCCEEDED(Shell_NotifyIconGetRect(&id, &r)) && !IsRectEmpty(&r)) {
      POINT p{(r.left + r.right) / 2, (r.top + r.bottom) / 2};
      if (MonitorFromPoint(p, MONITOR_DEFAULTTONULL)) icon = p;
    }
    vortex_.HideToTray(icon);
    return 0;
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_CONTEXTMENU: ShowMenu(); break;
      case NIN_SELECT:
      case NIN_KEYSELECT: OpenWindow(); break;
      case NIN_BALLOONUSERCLICK:
        vortex_.Open();
        channel_->InvokeMethod("openEvent",
          std::make_unique<flutter::EncodableValue>(notification_event_));
        break;
    }
    return 0;
  }
  return std::nullopt;
}
