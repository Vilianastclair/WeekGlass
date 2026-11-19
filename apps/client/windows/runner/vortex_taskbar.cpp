#include "vortex_taskbar.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <cwctype>
#include <filesystem>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
struct Text {
  BSTR value = nullptr;
  ~Text() { SysFreeString(value); }
  std::wstring Read() const { return value ? std::wstring(value, SysStringLen(value)) : L""; }
};
class Apartment {
 public:
  const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  ~Apartment() { if (SUCCEEDED(hr)) CoUninitialize(); }
};
bool IsNamed(const std::wstring& actual, const std::wstring& expected) {
  if (expected.empty() || _wcsnicmp(actual.c_str(), expected.c_str(), expected.size())) return false;
  if (actual.size() == expected.size()) return true;
  const wchar_t c = actual[expected.size()];
  if (iswspace(c)) {
    const auto end = actual.find_first_not_of(L" \t", expected.size());
    if (end == std::wstring::npos) return false;
    if (actual[end] == L'-') {
      const auto count = actual.find_first_not_of(L" \t", end + 1);
      return count != std::wstring::npos && iswdigit(actual[count]);
    }
    return iswdigit(actual[end]) || actual[end] == L'(';
  }
  return c == L',' || c == L':' || c == 0xFF0C || c == 0xFF1A;
}
BOOL CALLBACK FindLegacyList(HWND item, LPARAM out) {
  wchar_t cls[64]{};
  GetClassNameW(item, cls, 64);
  if (wcscmp(cls, L"MSTaskListWClass")) return TRUE;
  *reinterpret_cast<HWND*>(out) = item;
  return FALSE;
}
std::optional<POINT> FindOnBar(IUIAutomation* automation, HWND bar, bool legacy,
                               const std::wstring& title) {
  ComPtr<IUIAutomationElement> root;
  if (FAILED(automation->ElementFromHandle(bar, &root))) return {};
  // Win11 names this class Taskbar.TaskListButtonAutomationPeer. Win10 has
  // MSAA children inside MSTaskListWClass; don't search Explorer's tray icons.
  VARIANT v{};
  if (!legacy) {
    v.vt = VT_BSTR; v.bstrVal = SysAllocString(L"Taskbar.TaskListButtonAutomationPeer");
  } else {
    v.vt = VT_I4; v.lVal = UIA_ButtonControlTypeId;
  }
  ComPtr<IUIAutomationCondition> condition;
  HRESULT hr = automation->CreatePropertyCondition(
      legacy ? UIA_ControlTypePropertyId : UIA_ClassNamePropertyId, v, &condition);
  VariantClear(&v);
  if (FAILED(hr)) return {};
  ComPtr<IUIAutomationElementArray> matches;
  if (FAILED(root->FindAll(TreeScope_Descendants, condition.Get(), &matches))) return {};
  RECT bar_rect{};
  if (!GetWindowRect(bar, &bar_rect)) return {};
  wchar_t exe[32768]{};
  GetModuleFileNameW(nullptr, exe, static_cast<DWORD>(std::size(exe)));
  const std::filesystem::path image(exe);
  const auto file_name = image.filename().wstring();
  const auto product = image.stem().wstring();
  std::optional<POINT> point;
  int count = 0;
  matches->get_Length(&count);
  for (int i = 0; i < count; ++i) {
    ComPtr<IUIAutomationElement> element;
    if (FAILED(matches->GetElement(i, &element))) continue;
    Text id;
    element->get_CurrentAutomationId(&id.value);
    const auto automation_id = id.Read();
    bool our_executable = false;
    if (_wcsnicmp(automation_id.c_str(), L"Appid: ", 7) == 0) {
      const wchar_t* path = automation_id.c_str() + 7;
      if ((wcslen(path) > 2 && path[1] == L':') || (path[0] == L'\\' && path[1] == L'\\')) {
        // Explorer canonicalizes junctions and 8.3 paths in AppIDs. Compare
        // file identity for the same exe name, not a workspace alias string.
        if (_wcsicmp(path, exe) != 0) {
          const std::filesystem::path shell_image(path);
          if (_wcsicmp(shell_image.filename().c_str(), file_name.c_str())) continue;
          std::error_code ec;
          if (!std::filesystem::equivalent(image, shell_image, ec)) continue;
        }
        our_executable = true;
      }
    }
    Text name;
    if (FAILED(element->get_CurrentName(&name.value))) continue;
    const auto label = name.Read();
    if (!our_executable && !IsNamed(label, title) && !IsNamed(label, product) &&
        !IsNamed(label, file_name)) continue;
    RECT r{}, visible{};
    BOOL offscreen = TRUE;
    if (FAILED(element->get_CurrentIsOffscreen(&offscreen)) || offscreen ||
        FAILED(element->get_CurrentBoundingRectangle(&r)) ||
        !IntersectRect(&visible, &r, &bar_rect) || !EqualRect(&visible, &r)) continue;
    POINT center{(r.left + r.right) / 2, (r.top + r.bottom) / 2};
    if (!MonitorFromPoint(center, MONITOR_DEFAULTTONULL) || point) return {};
    point = center;
  }
  return point;
}
}

std::optional<POINT> FindTaskbarAnchor(HMONITOR monitor, const std::wstring& title) {
  Apartment apartment;
  if (FAILED(apartment.hr)) return {};
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&automation)))) return {};
  std::vector<HWND> bars;
  if (auto main = FindWindowW(L"Shell_TrayWnd", nullptr)) bars.push_back(main);
  for (HWND h = nullptr; (h = FindWindowExW(nullptr, h, L"Shell_SecondaryTrayWnd", nullptr));)
    bars.push_back(h);
  // Respect per-monitor taskbar buttons; use the primary only when it actually
  // contains our button. Never invent a position at the screen's lower edge.
  for (int pass = 0; pass < 2; ++pass) {
    for (auto bar : bars) {
      if ((MonitorFromWindow(bar, MONITOR_DEFAULTTONEAREST) == monitor) != (pass == 0)) continue;
      if (auto found = FindOnBar(automation.Get(), bar, false, title)) return found;
      HWND list = nullptr;
      EnumChildWindows(bar, FindLegacyList, reinterpret_cast<LPARAM>(&list));
      if (list) if (auto found = FindOnBar(automation.Get(), list, true, title)) return found;
    }
  }
  return {};
}
