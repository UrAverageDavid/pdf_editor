#include "flutter_window.h"

#include <tpcshrd.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kTabletPenServiceProperty[] =
    L"MicrosoftTabletPenServiceProperty";

bool DisablePenPressAndHold(HWND window) {
  // Keep any existing tablet settings and opt this HWND out of Windows'
  // press-and-hold right-click recognition before the first pen contact.
  const auto flags = reinterpret_cast<ULONG_PTR>(
      GetPropW(window, kTabletPenServiceProperty));
  return SetPropW(
             window, kTabletPenServiceProperty,
             reinterpret_cast<HANDLE>(flags | TABLET_DISABLE_PRESSANDHOLD)) != 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // Tablet settings are per HWND: the Flutter child receives pen input, while
  // the top-level window hosts the rest of the app's native window surface.
  if (!DisablePenPressAndHold(GetHandle()) ||
      !DisablePenPressAndHold(flutter_controller_->view()->GetNativeWindow())) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  pen_haptics_ = std::make_unique<PenHaptics>(
      flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger());
  wet_ink_ = std::make_unique<WetInk>(
      flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger(),
      [this](std::function<void()> callback) {
        flutter_controller_->engine()->SetNextFrameCallback(std::move(callback));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  wet_ink_.reset();
  pen_haptics_.reset();
  if (flutter_controller_) {
    if (flutter_controller_->view()) {
      RemovePropW(flutter_controller_->view()->GetNativeWindow(),
                  kTabletPenServiceProperty);
    }
    flutter_controller_ = nullptr;
  }
  if (GetHandle()) RemovePropW(GetHandle(), kTabletPenServiceProperty);

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Win32Window clears its HWND before invoking OnDestroy for WM_DESTROY.
  if (message == WM_DESTROY) RemovePropW(hwnd, kTabletPenServiceProperty);
  if (message == WM_ACTIVATEAPP && !wparam && pen_haptics_) {
    pen_haptics_->Stop();
  }
  if (message == WM_ACTIVATEAPP && !wparam && wet_ink_) wet_ink_->Cancel();
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
