#ifndef RUNNER_WET_INK_H_
#define RUNNER_WET_INK_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <commctrl.h>
#include <d2d1_1.h>
#include <dcomp.h>
#include <wrl/client.h>

#include <atomic>
#include <map>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "ink_prediction.h"
#include "ink_handoff.h"

// A transient native ink surface above the Flutter child. WM_POINTER input and
// DirectComposition commits stay on the Windows platform thread, independent of
// Dart's UI/raster pipeline. This is a custom renderer, not an InkCanvas host.
class WetInk {
 public:
  using NextFrame = std::function<void(std::function<void()>)>;
  WetInk(HWND window, flutter::BinaryMessenger* messenger, NextFrame next_frame);
  ~WetInk();
  void Cancel() noexcept;

 private:
  using Point = ink::Point;
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  bool Initialize();
  bool EnsureBuffers(UINT width, UINT height);
  void ReleaseBuffers() noexcept;
  bool Begin(const flutter::EncodableMap& args);
  void ReadPoints(UINT32 pointer, bool ending);
  void Append(Point point);
  bool Paint();
  void Segment(ID2D1DeviceContext* context, const ink::StrokeView& points, size_t index);
  float Width(const ink::StrokeView& points, size_t index) const;
  void ArmPredictionExpiry();
  void Freeze();
  void Clear() noexcept;
  void Fail() noexcept;
  void Retire(int64_t token);
  void Archive();
  void Discard(int64_t token);
  void ArmRetirement();
  flutter::EncodableValue Samples() const;
  struct CompletedStroke {
    Microsoft::WRL::ComPtr<IDCompositionVisual2> visual;
    Microsoft::WRL::ComPtr<IDCompositionSurface> surface;
    flutter::EncodableValue samples;
    uint64_t pixels;
  };
  std::map<int64_t, CompletedStroke> completed_;
  ink::HandoffQueue handoff_;
  float reference_x_ = 0, reference_y_ = 0, reference_width_ = 1, reference_height_ = 1;

  HWND window_;
  HWND target_window_;
  NextFrame next_frame_;
  std::shared_ptr<std::atomic_bool> alive_ = std::make_shared<std::atomic_bool>(true);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  UINT32 pointer_ = 0;
  bool contact_ = false;
  bool frozen_ = false;
  bool clipped_ = false;
  bool surface_initialized_ = false;
  int64_t token_ = 0;
  UINT64 last_counter_ = 0;
  DWORD last_time_ = 0;
  std::vector<Point> pending_;
  std::vector<Point> points_;
  Point raw_{};
  ink::Predictor predictor_;
  ink::Prediction prediction_, painted_prediction_;
  ULONGLONG last_sample_arrival_ = 0;
  double vx_ = 0, vy_ = 0, fast_vx_ = 0, fast_vy_ = 0;
  size_t next_segment_ = 1;
  float width_ = 1, dpr_ = 1, sensitivity_ = 0, sharpness_ = 0;
  std::string type_;
  D2D1_RECT_F clip_{};
  D2D1_COLOR_F color_{};
  UINT surface_width_ = 0, surface_height_ = 0;
  Microsoft::WRL::ComPtr<ID2D1Factory1> factory_;
  Microsoft::WRL::ComPtr<ID2D1DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
  Microsoft::WRL::ComPtr<ID2D1StrokeStyle> stroke_style_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> stable_;
  Microsoft::WRL::ComPtr<IDCompositionDesktopDevice> composition_;
  Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
  Microsoft::WRL::ComPtr<IDCompositionVisual2> root_;
  Microsoft::WRL::ComPtr<IDCompositionVisual2> visual_;
  Microsoft::WRL::ComPtr<IDCompositionEffectGroup> opacity_;
  Microsoft::WRL::ComPtr<IDCompositionSurface> surface_;
};

#endif  // RUNNER_WET_INK_H_
