#ifndef RUNNER_VORTEX_TRANSITION_H_
#define RUNNER_VORTEX_TRANSITION_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "vortex_playback.h"
#include "vortex_renderer.h"
#include "vortex_taskbar.h"

class VortexTransition {
 public:
  using AnchorQuery = std::function<std::optional<POINT>(HMONITOR, const std::wstring&)>;
  VortexTransition(HWND window, flutter::BinaryMessenger* messenger,
                   AnchorQuery taskbar_query = FindTaskbarAnchor);
  ~VortexTransition();
  void FirstFrame();
  void Open();
  void Minimize();
  void HideToTray(std::optional<POINT> icon);
  bool SetMode(const std::string& name);
  std::optional<LRESULT> Handle(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  enum class Phase { idle, waiting, playing };
  enum class Target { open, minimized, tray };
  enum class Mode { liquid, gentle, system };
  struct Frame {
    int width = 0, height = 0;
    std::vector<uint8_t> rgba;
  };
  struct Query {
    std::atomic<bool> ready{false};
    std::optional<POINT> anchor;
  };
  bool CanAnimate() const;
  void MinimizeWithCommand(int command);
  void Request(Target target, std::optional<POINT> anchor, bool find_taskbar,
               bool fresh_restore = false);
  void Capture();
  void Received(uint64_t id, const flutter::EncodableValue* reply);
  void Advance();
  bool Play(float start, bool reuse = false);
  bool AwaitFrame();
  void PresentFrame(bool ready);
  void CancelFrameWait();
  static void CALLBACK FrameReady(PTP_CALLBACK_INSTANCE, void*, PTP_WAIT, TP_WAIT_RESULT);
  void Redirect(Target target);
  void Apply(Target target);
  void Finish(bool retain);
  void Reset(bool retain);
  void System(Target target);
  bool SetNativeTransitions();
  static LRESULT CALLBACK OnMinMax(int code, WPARAM window, LPARAM command);
  HWND window_;
  HHOOK minmax_hook_ = nullptr;
  const UINT_PTR instance_token_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  AnchorQuery taskbar_query_;
  std::shared_ptr<Query> query_;
  std::shared_ptr<int> lifetime_ = std::make_shared<int>(0);
  UINT_PTR request_id_ = 0;
  LONGLONG started_ = 0;
  PTP_WAIT frame_wait_ = nullptr;
  std::atomic<UINT_PTR> frame_wait_token_{0};
  std::optional<POINT> anchor_;
  HMONITOR monitor_ = nullptr;
  RECT bounds_{};
  Frame frame_;
  Mode mode_ = Mode::liquid;
  int minimize_command_ = SW_MINIMIZE;
  Phase phase_ = Phase::idle;
  Target target_ = Target::open;
  Target parked_ = Target::open;
  VortexPlayback playback_;
  bool fetching_anchor_ = false, native_ = false, first_frame_ = false;
  bool first_present_ = false, capture_in_flight_ = false;
  bool capture_allowed_ = true, native_transitions_changed_ = false;
  bool fresh_restore_ = false, cloaked_ = false;
  HWND open_foreground_ = nullptr;
  VortexRenderer renderer_;
};
#endif
