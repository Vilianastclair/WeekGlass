#include "vortex_transition.h"
#include "vortex_timing.h"
#include "single_instance.h"
#include <dwmapi.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <thread>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT_PTR kCaptureTimer = 0x57475654;
constexpr UINT kRequestRestore = WM_APP + 146;
constexpr UINT kTaskbarReady = WM_APP + 147;
constexpr UINT kGpuReady = WM_APP + 148;
constexpr UINT kFrameReady = WM_APP + 149;
constexpr UINT kCheckCover = WM_APP + 150;
constexpr UINT kForegroundReturn = WM_APP + 151;
constexpr UINT kDirectMinimize = WM_APP + 152;
constexpr unsigned kCaptureDeadlineMs = 350;
constexpr unsigned kAnchorGraceMs = 65;
thread_local VortexTransition* ui_transition = nullptr;

UINT_PTR NextToken() {
  static std::atomic<UINT_PTR> counter{0};
  return ++counter;
}

LONGLONG Counter() {
  LARGE_INTEGER time{};
  QueryPerformanceCounter(&time);
  return time.QuadPart;
}

double Milliseconds(LONGLONG ticks) {
  static const double scale = [] {
    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    return 1000. / static_cast<double>(frequency.QuadPart);
  }();
  return static_cast<double>(ticks) * scale;
}

RECT ClientBounds(HWND window) {
  RECT r{};
  if (!GetClientRect(window, &r)) return {};
  MapWindowPoints(window, nullptr, reinterpret_cast<POINT*>(&r), 2);
  return r;
}
bool IsMinimizeCommand(UINT command) {
  return command == SW_MINIMIZE || command == SW_SHOWMINIMIZED ||
         command == SW_SHOWMINNOACTIVE;
}
bool IsOwnThread(DWORD id) {
  if (!id) return false;
  if (id == GetCurrentThreadId()) return true;
  const HANDLE thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, id);
  if (!thread) return false;
  const bool own = GetProcessIdOfThread(thread) == GetCurrentProcessId();
  CloseHandle(thread);
  return own;
}
template<class T> const T* Field(const Map& fields, const char* key) {
  auto it = fields.find(Value(key));
  return it == fields.end() ? nullptr : std::get_if<T>(&it->second);
}
}

VortexTransition::VortexTransition(HWND window, flutter::BinaryMessenger* messenger,
                                   AnchorQuery taskbar_query)
    : window_(window),
      instance_token_(NextToken()),
      channel_(messenger, "weekglass/vortex", &flutter::StandardMethodCodec::GetInstance()),
      taskbar_query_(std::move(taskbar_query)) {
  // A taskbar or a window-manager client may call ShowWindow directly,
  // bypassing WM_SYSCOMMAND. Intercept only this HWND on its own UI thread.
  if (!ui_transition) {
    minmax_hook_ = SetWindowsHookExW(WH_CBT, OnMinMax, nullptr, GetCurrentThreadId());
    if (minmax_hook_) ui_transition = this;
  }
  if (CanAnimate()) renderer_.Warm(window_, kGpuReady, instance_token_);
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "minimize") {
      Minimize();
    } else if (call.method_name() == "setCaptureAllowed") {
      const auto allowed = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!allowed) { result->Error("invalid_arguments", "Expected a boolean"); return; }
      capture_allowed_ = *allowed;
      if (!capture_allowed_) {
        if (phase_ != Phase::idle) System(target_);
        else Reset(false);
      }
    } else { result->NotImplemented(); return; }
    result->Success();
  });
}
VortexTransition::~VortexTransition() {
  if (minmax_hook_) {
    ui_transition = nullptr;
    UnhookWindowsHookEx(minmax_hook_);
  }
  lifetime_.reset();
  channel_.SetMethodCallHandler(nullptr);
  Reset(false);
  if (frame_wait_) CloseThreadpoolWait(frame_wait_);
}

LRESULT CALLBACK VortexTransition::OnMinMax(int code, WPARAM hwnd, LPARAM command) {
  auto* self = ui_transition;
  if (code == HCBT_MINMAX && self && reinterpret_cast<HWND>(hwnd) == self->window_ &&
      !self->native_ && self->first_frame_ && IsMinimizeCommand(LOWORD(command)) &&
      self->CanAnimate() && PostMessageW(self->window_, kDirectMinimize, LOWORD(command), 0)) {
    return 1;
  }
  return CallNextHookEx(nullptr, code, hwnd, command);
}

bool VortexTransition::CanAnimate() const {
  BOOL enabled = FALSE;
  ANIMATIONINFO animations{sizeof(ANIMATIONINFO), 0};
  return capture_allowed_ && mode_ != Mode::system &&
      SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0) && enabled &&
      SystemParametersInfoW(SPI_GETANIMATION, sizeof(animations), &animations, 0) &&
      animations.iMinAnimate;
}
bool VortexTransition::SetMode(const std::string& name) {
  if (name == "liquidGlass") mode_ = Mode::liquid;
  else if (name == "gentle") mode_ = Mode::gentle;
  else if (name == "system") mode_ = Mode::system;
  else return false;
  if (mode_ == Mode::system) {
    if (phase_ != Phase::idle) System(target_); else Reset(false);
  }
  return true;
}
void VortexTransition::FirstFrame() {
  if (first_frame_) return;
  first_frame_ = true;
  if (parked_ != Target::open || IsWindowVisible(window_)) return;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &info)) {
    System(Target::open); return;
  }
  Request(Target::open, POINT{(info.rcMonitor.left + info.rcMonitor.right) / 2,
                              (info.rcMonitor.top + info.rcMonitor.bottom) / 2}, false);
}

void VortexTransition::Minimize() { MinimizeWithCommand(SW_MINIMIZE); }
void VortexTransition::MinimizeWithCommand(int command) {
  minimize_command_ = command;
  if (phase_ == Phase::playing) { Redirect(Target::minimized); return; }
  if (phase_ == Phase::waiting && target_ == Target::minimized) return;
  if (IsIconic(window_) || !IsWindowVisible(window_)) {
    if (phase_ == Phase::waiting && target_ == Target::open) System(Target::minimized);
    return;
  }
  Request(Target::minimized, {}, true);
}
void VortexTransition::HideToTray(std::optional<POINT> icon) {
  if (phase_ == Phase::playing) { Redirect(Target::tray); return; }
  if (target_ == Target::tray && phase_ == Phase::waiting) return;
  if (IsIconic(window_) || !IsWindowVisible(window_)) { System(Target::tray); return; }
  Request(Target::tray, icon, false);
}
void VortexTransition::Open() {
  if (!first_frame_) return;  // The first Flutter frame owns launch visibility.
  if (phase_ == Phase::waiting) {
    if (target_ != Target::open) System(Target::open);
    return;
  }
  if (phase_ == Phase::playing) { Redirect(Target::open); return; }
  if (parked_ == Target::open && IsWindowVisible(window_) && !IsIconic(window_)) {
    // Reopening a running instance requests real activation first. Windows can
    // decline it. Only a successful return from an overlapping app animates.
    if (GetForegroundWindow() != window_) {
      CheckCover();
      if (cover_) background_ = true;
      SingleInstance::Activate(window_);
    }
    return;
  }
  if (parked_ != Target::open && renderer_.frame_ready() && anchor_ && CanAnimate() &&
      monitor_ == MonitorFromRect(&bounds_, MONITOR_DEFAULTTONULL)) {
    target_ = Target::open;
    open_foreground_ = GetForegroundWindow();
    if (Play(0.f, true)) return;
  }
  if (CanAnimate() && (IsIconic(window_) || !IsWindowVisible(window_))) {
    // A monitor change or failed earlier readback invalidates the parked
    // texture. Restore the real geometry under a cloak and sample today's
    // planner; never replay stale pixels or capture another window.
    Request(Target::open, {}, false, true);
    return;
  }
  System(Target::open);
}

void VortexTransition::Request(Target target, std::optional<POINT> anchor, bool find_taskbar,
                               bool foreground_return) {
  Reset(false);
  target_ = target;
  foreground_return_ = foreground_return;
  if (target == Target::open) open_foreground_ = GetForegroundWindow();
  if (!CanAnimate()) { System(target); return; }
  if (foreground_return_) {
    // The live planner is or will be raised. Drawing a transparent sheet over
    // its opaque rectangle would show no silhouette. Cloak only its DWM
    // visual, leaving its window placement, taskbar identity and input intact.
    const BOOL cloak = TRUE;
    if (!SetNativeTransitions() ||
        FAILED(DwmSetWindowAttribute(window_, DWMWA_CLOAK, &cloak, sizeof(cloak)))) {
      System(target); return;
    }
    cloaked_ = true;
    if (IsIconic(window_) || !IsWindowVisible(window_)) Apply(Target::open);
  }
  bounds_ = ClientBounds(window_);
  monitor_ = MonitorFromRect(&bounds_, MONITOR_DEFAULTTONULL);
  if (!monitor_ || IsRectEmpty(&bounds_)) { System(target); return; }
  anchor_ = anchor;
  renderer_.Warm(window_, kGpuReady, instance_token_);
  // No visible button (overflow, auto-hide, or a slow accessibility provider)
  // means an in-window reveal, never a guessed position on someone else's icon.
  if (!anchor_) anchor_ = POINT{(bounds_.left+bounds_.right)/2, (bounds_.top+bounds_.bottom)/2};
  if (find_taskbar && (!query_ || query_->ready.load())) {
    // An unavailable accessibility provider must neither stall the UI thread
    // nor accumulate worker threads on successive clicks.
    query_ = std::make_shared<Query>();
    wchar_t title[256]{};
    GetWindowTextW(window_, title, 256);
    try {
      std::thread([q = query_, monitor = monitor_, title = std::wstring(title), fn = taskbar_query_,
                   window = window_, token = request_id_, alive = std::weak_ptr<int>(lifetime_)] {
        try { q->anchor = fn(monitor, title); } catch (...) { q->anchor.reset(); }
        q->ready.store(true);
        if (!alive.expired()) PostMessageW(window, kTaskbarReady, token, 0);
      }).detach();
      fetching_anchor_ = true;
    } catch (...) { query_.reset(); }
  }
  if (!SetTimer(window_, kCaptureTimer, fetching_anchor_ ? kAnchorGraceMs : kCaptureDeadlineMs, nullptr)) { System(target); return; }
  phase_ = Phase::waiting;
  started_ = Counter();
  Capture();
}

void VortexTransition::Capture() {
  // A canceled transition can still be finishing its Flutter readback. Ask
  // for new pixels once that reply arrives instead of racing the renderer.
  if (phase_ != Phase::waiting || capture_in_flight_) return;
  capture_in_flight_ = true;
  auto receive = [this, alive = std::weak_ptr<int>(lifetime_), id = request_id_](const Value* result) {
    if (!alive.expired()) Received(id, result);
  };
  channel_.InvokeMethod("captureFrame", nullptr,
    std::make_unique<flutter::MethodResultFunctions<Value>>(receive,
      [receive](const auto&, const auto&, const auto*) { receive(nullptr); },
      [receive]() { receive(nullptr); }));
}

void VortexTransition::Received(uint64_t id, const Value* reply) {
  capture_in_flight_ = false;
  if (request_id_ != id || phase_ != Phase::waiting) {
    if (phase_ == Phase::waiting && Milliseconds(Counter() - started_) < kCaptureDeadlineMs) Capture();
    return;
  }
  auto fields = reply ? std::get_if<Map>(reply) : nullptr;
  if (!fields || !capture_allowed_) { System(target_); return; }
  auto w = Field<int32_t>(*fields, "width");
  auto h = Field<int32_t>(*fields, "height");
  auto rgba = Field<std::vector<uint8_t>>(*fields, "rgba");
  if (!w || !h || *w <= 0 || *h <= 0 || *w > 1600 || *h > 1600 ||
      !rgba || rgba->size() != static_cast<size_t>(*w) * *h * 4) {
    System(target_); return;
  }
  frame_.width = *w; frame_.height = *h;
  frame_.rgba = *rgba;
  Advance();
}
bool VortexTransition::SetNativeTransitions() {
  if (native_transitions_changed_) return true;
  // DWMWA_TRANSITIONS_FORCEDISABLED is write-only. This runner owns it;
  // its idle value is FALSE. Do not modify the global animation preference.
  const BOOL disable = TRUE;
  if (FAILED(DwmSetWindowAttribute(window_, DWMWA_TRANSITIONS_FORCEDISABLED,
                                   &disable, sizeof(disable)))) return false;
  native_transitions_changed_ = true;
  return true;
}
bool VortexTransition::Play(float start, bool reuse) {
  if (!anchor_ || (!reuse && !renderer_.Prepare(window_, bounds_, *anchor_, frame_.rgba.data(),
                                               frame_.width, frame_.height)) ||
      !SetNativeTransitions()) return false;
  frame_ = {};  // Only the current swap chain needs the immutable snapshot now.
  KillTimer(window_, kCaptureTimer);
  phase_ = Phase::playing;
  playback_.Start(start, target_ == Target::open, mode_ == Mode::gentle);
  first_present_ = true;
  return AwaitFrame();
}

void VortexTransition::Advance() {
  if (phase_ != Phase::waiting) return;
  const auto elapsed = Milliseconds(Counter() - started_);
  if (elapsed >= kCaptureDeadlineMs) { System(target_); return; }
  if (fetching_anchor_) {
    if (query_->ready.load()) {
      if (query_->anchor) anchor_ = query_->anchor;
    } else if (elapsed < kAnchorGraceMs) {
      return;
    }
    fetching_anchor_ = false;
  }
  if (frame_.rgba.empty() || !anchor_ || renderer_.warming()) return;
  RECT now = ClientBounds(window_);
  if (!EqualRect(&now, &bounds_) || !Play(target_ == Target::open ? 0.f : 1.f)) System(target_);
}

bool VortexTransition::AwaitFrame() {
  const HANDLE ready = renderer_.frame_ready();
  if (!ready) return false;
  if (!frame_wait_) frame_wait_ = CreateThreadpoolWait(FrameReady, this, nullptr);
  if (!frame_wait_) return false;
  frame_wait_token_.store(request_id_);
  // DXGI should free one buffer each refresh. A stalled compositor should
  // return the real HWND instead of keeping it behind a frozen overlay.
  constexpr uint64_t delay = static_cast<uint64_t>(-2000000LL);  // 200 ms
  FILETIME timeout{static_cast<DWORD>(delay), static_cast<DWORD>(delay >> 32)};
  SetThreadpoolWait(frame_wait_, ready, &timeout);
  return true;
}

void CALLBACK VortexTransition::FrameReady(PTP_CALLBACK_INSTANCE, void* context,
                                           PTP_WAIT, TP_WAIT_RESULT result) {
  const auto* self = static_cast<VortexTransition*>(context);
  // One shot; only the UI thread can arm another frame after this message.
  PostMessageW(self->window_, kFrameReady, self->frame_wait_token_.load(), result);
}

void VortexTransition::CancelFrameWait() {
  if (!frame_wait_) return;
  SetThreadpoolWait(frame_wait_, nullptr, nullptr);
  // Callback only posts a message; no compositor or GPU work runs in it.
  WaitForThreadpoolWaitCallbacks(frame_wait_, TRUE);
}

void VortexTransition::PresentFrame(bool ready) {
  if (phase_ != Phase::playing) return;
  if (!ready) { System(target_); return; }
  const auto now = Counter();
  const bool opening = target_ == Target::open;
  const float phase = static_cast<float>(playback_.At(
      first_present_ ? 0. : Milliseconds(now - started_)).phase);
  const bool gentle = playback_.gentle();
  const auto result = renderer_.Draw(gentle ? phase : vortex_timing::Openness(phase), gentle);
  if (result == VortexRenderer::Result::unavailable) { System(target_); return; }
  if (result == VortexRenderer::Result::presented) {
    if (first_present_) {
      first_present_ = false;
      started_ = Counter();
      if (!opening) Apply(target_);
    }
    if ((opening && phase >= 1.f) || (!opening && phase <= 0.f)) {
      Finish(!opening);
      return;
    }
  }
  if (!AwaitFrame()) System(target_);
}
void VortexTransition::Redirect(Target target) {
  if (target_ == target) return;
  const bool was_opening = target_ == Target::open;
  const bool opening = target == Target::open;
  target_ = target;
  if (opening) open_foreground_ = GetForegroundWindow();
  // Keep the same sheet and path through a reversal. If an opposite request
  // arrives before the first DXGI tick, no hidden-owner handoff has happened.
  if (!first_present_ && !opening && parked_ != target) Apply(target);
  if (opening != was_opening) {
    const auto now = Counter();
    const auto at = playback_.At(first_present_ ? 0. : Milliseconds(now - started_));
    // No frame of the old direction has appeared yet: start directly.
    if (first_present_) playback_.Start(at.phase, opening, playback_.gentle());
    else playback_.Reverse(at, opening);
    started_ = now;
  }
}
void VortexTransition::Apply(Target target) {
  native_ = true;
  if (target == Target::open) {
    // Do not take focus at the *end* of an animation if the user switched
    // to a different app in the meantime. A foreground return already has
    // its final HWND state; it needs only the uncloak in Reset.
    const HWND foreground = GetForegroundWindow();
    if (!foreground_return_ || IsIconic(window_) || !IsWindowVisible(window_)) {
      if (open_foreground_ && foreground && foreground != open_foreground_ && foreground != window_) {
        if (IsIconic(window_) || !IsWindowVisible(window_)) ShowWindow(window_, SW_SHOWNOACTIVATE);
      } else SingleInstance::Activate(window_);
    }
  }
  else if (target == Target::tray) ShowWindow(window_, SW_HIDE);
  else if (!IsIconic(window_)) ShowWindow(window_, minimize_command_);
  native_ = false;
  parked_ = target;
}
void VortexTransition::Finish(bool retain) {
  Apply(target_);
  Reset(retain);
}
void VortexTransition::Reset(bool retain) {
  request_id_ = NextToken();
  phase_ = Phase::idle;
  KillTimer(window_, kCaptureTimer);
  CancelFrameWait();
  fetching_anchor_ = false;
  foreground_return_ = false;
  open_foreground_ = nullptr;
  if (cloaked_) {
    const BOOL cloak = FALSE;
    DwmSetWindowAttribute(window_, DWMWA_CLOAK, &cloak, sizeof(cloak));
    cloaked_ = false;
  }
  renderer_.Reset(retain);
  frame_ = {};
  if (native_transitions_changed_) {
    const BOOL enable_native = FALSE;
    DwmSetWindowAttribute(window_, DWMWA_TRANSITIONS_FORCEDISABLED,
                          &enable_native, sizeof(enable_native));
    native_transitions_changed_ = false;
  }
  if (!retain) {
    anchor_.reset();
  }
}
void VortexTransition::System(Target target) {
  const bool leave_focus = foreground_return_ && target == Target::open &&
      IsWindowVisible(window_) && !IsIconic(window_);
  const HWND foreground = target == target_ ? open_foreground_ : nullptr;
  Reset(false);
  target_ = target;
  open_foreground_ = foreground;
  if (!leave_focus) Apply(target);
  open_foreground_ = nullptr;
}

bool VortexTransition::CoveredBy(HWND other) const {
  if (!other || !IsWindowVisible(other) || IsIconic(other) ||
      other == GetShellWindow() || GetAncestor(other, GA_ROOTOWNER) == window_ ||
      (GetWindowLongPtrW(other, GWL_EXSTYLE) & WS_EX_TOOLWINDOW))
    return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(other, &pid);
  if (!pid || pid == GetCurrentProcessId()) return false;
  DWORD cloaked = 0;
  if (SUCCEEDED(DwmGetWindowAttribute(other, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked)
    return false;
  wchar_t cls[64]{};
  GetClassNameW(other, cls, ARRAYSIZE(cls));
  if (!wcscmp(cls,L"WorkerW") || !wcscmp(cls,L"Progman") || !wcscmp(cls,L"Shell_TrayWnd") ||
      !wcscmp(cls,L"Shell_SecondaryTrayWnd")) return false;
  RECT other_bounds{}, intersect{};
  const RECT ours = ClientBounds(window_);
  if (FAILED(DwmGetWindowAttribute(other, DWMWA_EXTENDED_FRAME_BOUNDS, &other_bounds, sizeof(other_bounds))) &&
      !GetWindowRect(other, &other_bounds)) return false;
  if (!IntersectRect(&intersect, &ours, &other_bounds)) return false;
  const auto area = [](RECT r) { return static_cast<int64_t>(r.right-r.left)*(r.bottom-r.top); };
  // Small overlaps at snapped edges don't turn ordinary side-by-side editing
  // into an opening transition.
  return area(intersect) * 4 >= area(ours);
}

void VortexTransition::CheckCover() {
  cover_ = nullptr;
  for (HWND h = GetWindow(window_, GW_HWNDPREV); h; h = GetWindow(h, GW_HWNDPREV)) {
    if (CoveredBy(h)) { cover_ = h; return; }
  }
}

std::optional<LRESULT> VortexTransition::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_TIMER && wparam == kCaptureTimer) { Advance(); return 0; }
  if (message == kTaskbarReady) { if (wparam == request_id_) Advance(); return 0; }
  if (message == kGpuReady) { if (wparam == instance_token_) Advance(); return 0; }
  if (message == kFrameReady) {
    if (wparam == request_id_) PresentFrame(lparam == WAIT_OBJECT_0);
    return 0;
  }
  if (native_) return {};
  if (message == kDirectMinimize) {
    if (IsMinimizeCommand(static_cast<UINT>(wparam))) MinimizeWithCommand(static_cast<int>(wparam));
    return 0;
  }
  if (message == WM_ACTIVATEAPP && IsOwnThread(static_cast<DWORD>(lparam))) return {};
  if (message == WM_ACTIVATEAPP && !wparam) {
    pending_reentry_ = false;
    if (foreground_return_ && target_ == Target::open && phase_ != Phase::idle) Reset(false);
    background_ = first_frame_ && parked_ == Target::open && IsWindowVisible(window_) && !IsIconic(window_);
    cover_ = nullptr;
    if (background_) PostMessageW(window_, kCheckCover, 0, 0);
  }
  if (message == kCheckCover) { if (background_) CheckCover(); return 0; }
  if (background_ && message == WM_WINDOWPOSCHANGING &&
      !(reinterpret_cast<WINDOWPOS*>(lparam)->flags & SWP_NOZORDER)) {
    // Check the actual order *before* the shell raises the planner.
    CheckCover();
  }
  if (message == WM_ACTIVATEAPP && wparam && background_) {
    background_ = false;
    pending_reentry_ = CoveredBy(cover_);
    if (pending_reentry_) PostMessageW(window_, kForegroundReturn, request_id_, 0);
    cover_ = nullptr;
  }
  if (message == WM_ENTERMENULOOP) pending_reentry_ = false;
  if (message == kForegroundReturn) {
    GUITHREADINFO gui{sizeof(GUITHREADINFO)};
    const bool reenter = std::exchange(pending_reentry_, false);
    if (reenter && !background_ && wparam == request_id_ && phase_ == Phase::idle && parked_ == Target::open &&
        IsWindowVisible(window_) && !IsIconic(window_) && IsWindowEnabled(window_) &&
        GetActiveWindow() == window_ && GetGUIThreadInfo(GetCurrentThreadId(), &gui) &&
        !(gui.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_SYSTEMMENUMODE | GUI_INMOVESIZE)) &&
        CanAnimate()) Request(Target::open, {}, false, true);
    return 0;
  }
  if (message == kRequestRestore) { if (IsIconic(window_)) Open(); return 0; }
  if (message == WM_SYSCOMMAND) {
    if ((wparam & 0xfff0) == SC_MINIMIZE) { Minimize(); return 0; }
    if ((wparam & 0xfff0) == SC_RESTORE &&
        (IsIconic(window_) || (phase_ != Phase::idle && target_ != Target::open))) { Open(); return 0; }
  }
  if (message == WM_QUERYOPEN && first_frame_ && IsIconic(window_) && CanAnimate() &&
      PostMessageW(window_, kRequestRestore, 0, 0)) {
    return FALSE;
  }
  if (message == WM_DISPLAYCHANGE || message == WM_DPICHANGED ||
      (message == WM_SETTINGCHANGE && !CanAnimate())) {
    if (phase_ != Phase::idle) System(target_); else Reset(false);
  }
  // A direct OS show/placement may bypass SC_RESTORE. Never replay an old
  // sampled frame after the live window is already visible.
  if (message == WM_SIZE && wparam != SIZE_MINIMIZED && IsWindowVisible(window_) &&
      parked_ != Target::open && !IsIconic(window_)) {
    parked_ = Target::open;
    Reset(false);
  }
  return {};
}
