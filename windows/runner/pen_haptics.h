#ifndef RUNNER_PEN_HAPTICS_H_
#define RUNNER_PEN_HAPTICS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <commctrl.h>
#include <winrt/Windows.Devices.Haptics.h>

#include <memory>

// Observe the Flutter child HWND, where WM_POINTER messages actually arrive.
// Never consume messages or pass Flutter's synthetic pointer IDs to WinRT.
class PenHaptics {
 public:
  PenHaptics(HWND window, flutter::BinaryMessenger* messenger);
  ~PenHaptics();
  void Stop() noexcept;

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR subclass_id,
                                    DWORD_PTR data);
  void Contact(UINT32 pointer_id) noexcept;
  void Start() noexcept;
  void Release() noexcept;

  HWND window_;
  UINT32 pointer_id_ = 0;
  bool in_contact_ = false;
  winrt::Windows::Devices::Haptics::SimpleHapticsController controller_{nullptr};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PEN_HAPTICS_H_
