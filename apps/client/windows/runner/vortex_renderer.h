#ifndef RUNNER_VORTEX_RENDERER_H_
#define RUNNER_VORTEX_RENDERER_H_

#include <windows.h>
#include <cstdint>
#include <memory>

// UI-thread object. The source is an opaque, top-down RGBA snapshot of this
// application's window. The source rectangle and anchor are in screen pixels.
class VortexRenderer {
 public:
  VortexRenderer();
  ~VortexRenderer();
  VortexRenderer(const VortexRenderer&) = delete;
  VortexRenderer& operator=(const VortexRenderer&) = delete;

  // Device and immutable shaders can warm up while Flutter prepares a frame.
  void Warm(HWND owner, UINT ready_message, WPARAM token);
  bool warming() const;
  bool Prepare(HWND owner, RECT bounds, POINT anchor, const uint8_t* rgba,
               int width, int height);
  HANDLE frame_ready() const;
  // 0 is the taskbar point; 1 is the original window. Either order is valid.
  enum class Result { presented, busy, unavailable };
  Result Draw(float openness, bool reduced);
  void Reset(bool retain = false);
  void Release();

 private:
  struct State;
  struct Warmup;
  std::unique_ptr<State> state_;
  std::shared_ptr<Warmup> warmup_;
};

#endif  // RUNNER_VORTEX_RENDERER_H_
