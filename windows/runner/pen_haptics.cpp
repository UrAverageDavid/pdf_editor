#include "pen_haptics.h"

#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Input.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.Metadata.h>

using winrt::Windows::Devices::Haptics::KnownSimpleHapticsControllerWaveforms;
using winrt::Windows::Devices::Input::PenDevice;
using winrt::Windows::Foundation::Metadata::ApiInformation;

PenHaptics::PenHaptics(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  SetWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this),
                    reinterpret_cast<DWORD_PTR>(this));
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "papertrail/pen_haptics",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "start") {
          Start();
          result->Success();
        } else if (call.method_name() == "stop") {
          Stop();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

PenHaptics::~PenHaptics() {
  channel_->SetMethodCallHandler(nullptr);
  Release();
  if (window_) {
    RemoveWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this));
  }
}

void PenHaptics::Contact(UINT32 pointer_id) noexcept {
  Release();
  pointer_id_ = pointer_id;
  in_contact_ = true;
  try {
    // Windows 10 and non-haptic pens continue to work without feedback.
    if (!ApiInformation::IsPropertyPresent(
            L"Windows.Devices.Input.PenDevice", L"SimpleHapticsController")) {
      return;
    }
    const auto pen = PenDevice::GetFromPointerId(pointer_id);
    if (pen) controller_ = pen.SimpleHapticsController();
  } catch (const winrt::hresult_error&) {
    controller_ = nullptr;
  }
}

void PenHaptics::Start() noexcept {
  if (!in_contact_ || !controller_) return;
  try {
    for (const auto& feedback : controller_.SupportedFeedback()) {
      if (feedback.Waveform() == KnownSimpleHapticsControllerWaveforms::InkContinuous()) {
        if (controller_.IsIntensitySupported()) {
          controller_.SendHapticFeedback(feedback, 0.45);
        } else {
          controller_.SendHapticFeedback(feedback);
        }
        break;
      }
    }
  } catch (const winrt::hresult_error&) {
    Stop();
  }
}

void PenHaptics::Stop() noexcept {
  in_contact_ = false;
  try {
    if (controller_) controller_.StopFeedback();
  } catch (const winrt::hresult_error&) {
    // A device can disconnect at any point during a stroke.
  }
}

void PenHaptics::Release() noexcept {
  Stop();
  controller_ = nullptr;
  in_contact_ = false;
  pointer_id_ = 0;
}

LRESULT CALLBACK PenHaptics::WindowProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam, UINT_PTR subclass_id,
                                      DWORD_PTR data) {
  auto* self = reinterpret_cast<PenHaptics*>(data);
  const auto pointer_id = GET_POINTERID_WPARAM(wparam);
  if (message == WM_POINTERDOWN) {
    POINTER_INPUT_TYPE type;
    if (GetPointerType(pointer_id, &type) && type == PT_PEN) {
      self->Contact(pointer_id);
    }
  } else if ((message == WM_POINTERUP || message == WM_POINTERLEAVE ||
              message == WM_POINTERCAPTURECHANGED) &&
             pointer_id == self->pointer_id_) {
    self->Release();
  } else if (message == WM_POINTERUPDATE && pointer_id == self->pointer_id_) {
    if (IS_POINTER_CANCELED_WPARAM(wparam)) self->Release();
  } else if (message == WM_KILLFOCUS || message == WM_CANCELMODE) {
    self->Release();
  } else if (message == WM_NCDESTROY) {
    self->Release();
    RemoveWindowSubclass(window, WindowProc, subclass_id);
    self->window_ = nullptr;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}
