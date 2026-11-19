#ifndef RUNNER_VORTEX_TASKBAR_H_
#define RUNNER_VORTEX_TASKBAR_H_
#include <windows.h>
#include <optional>
#include <string>

// Called on a worker. Read only the shell's task-list accessibility provider.
// Coordinates are physical screen pixels, not the notification-area icon.
std::optional<POINT> FindTaskbarAnchor(HMONITOR monitor, const std::wstring& title);
#endif
