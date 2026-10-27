#include "wet_ink.h"

#include <flutter/standard_method_codec.h>
#include <d3d11.h>
#include <dxgi.h>

#include <algorithm>
#include <cmath>
#include <utility>

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
constexpr UINT kRetireInk = WM_APP + 0x317;
constexpr double kPi = 3.141592653589793;
double Number(const EncodableValue& value) {
  if (const auto* v = std::get_if<double>(&value)) return *v;
  if (const auto* v = std::get_if<int32_t>(&value)) return *v;
  if (const auto* v = std::get_if<int64_t>(&value)) return static_cast<double>(*v);
  return 0;
}
const EncodableValue& Field(const EncodableMap& map, const char* key) {
  static const EncodableValue empty;
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? empty : it->second;
}
float Scalar(const EncodableMap& map, const char* key) {
  return static_cast<float>(Number(Field(map, key)));
}
double Alpha(double cutoff, double dt) {
  return 1 / (1 + 1 / (2 * kPi * cutoff * dt));
}
}  // namespace

WetInk::WetInk(HWND window, flutter::BinaryMessenger* messenger, NextFrame next_frame)
    : window_(window), target_window_(GetAncestor(window, GA_ROOT)),
      next_frame_(std::move(next_frame)) {
  SetWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this),
                    reinterpret_cast<DWORD_PTR>(this));
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "papertrail/wet_ink", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "initialize") {
      const bool ready = Initialize();
      if (!ready) Fail();
      result->Success(EncodableValue(ready));
    } else if (call.method_name() == "begin") {
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      const bool accepted = args && Begin(*args);
      if (!accepted) { if (token_) Fail(); else Clear(); }
      result->Success(EncodableValue(accepted));
    } else if (call.method_name() == "freeze") {
      const auto token = call.arguments() ? static_cast<int64_t>(Number(*call.arguments())) : 0;
      if (token && token == token_) Archive();
      const auto it = completed_.find(token);
      if (it != completed_.end()) result->Success(it->second.samples);
      else result->Success();
    } else if (call.method_name() == "retire") {
      const auto token = call.arguments() ? static_cast<int64_t>(Number(*call.arguments())) : 0;
      if (completed_.count(token)) Retire(token);
      else channel_->InvokeMethod("retired", std::make_unique<EncodableValue>(token));
      result->Success();
    } else if (call.method_name() == "invalidate") {
      Cancel();
      result->Success();
    } else if (call.method_name() == "discard") {
      const auto token = call.arguments() ? static_cast<int64_t>(Number(*call.arguments())) : 0;
      if (token && token == token_) Clear();
      Discard(token);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

WetInk::~WetInk() {
  alive_->store(false);
  channel_->SetMethodCallHandler(nullptr);
  Clear();
  if (window_) RemoveWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this));
}

flutter::EncodableValue WetInk::Samples() const {
  flutter::EncodableList result;
  result.reserve(points_.size());
  const double first_time = points_.empty() ? 0 : points_.front().time;
  for (const auto& point : points_) {
    result.emplace_back(flutter::EncodableList{
      EncodableValue(static_cast<double>((point.x - reference_x_) / reference_width_)),
      EncodableValue(static_cast<double>((point.y - reference_y_) / reference_height_)),
      EncodableValue(static_cast<double>(point.pressure)),
      EncodableValue(static_cast<int64_t>(std::llround((point.time - first_time) * 1000000)))});
  }
  return EncodableValue(std::move(result));
}

void WetInk::Archive() {
  if (!token_) return;
  Freeze();
  if (!token_) return;  // Device loss during the final paint.
  completed_.emplace(token_, CompletedStroke{std::move(visual_), std::move(surface_), Samples(),
      static_cast<uint64_t>(surface_width_) * surface_height_});
  opacity_.Reset();
  // Completed visuals remain children of root_. Clear only the active state.
  Clear();
}

void WetInk::Discard(int64_t token) {
  const auto it = completed_.find(token);
  if (it == completed_.end()) return;
  if (root_ && it->second.visual) root_->RemoveVisual(it->second.visual.Get());
  completed_.erase(it);
  if (composition_) composition_->Commit();
}

void WetInk::Retire(int64_t token) {
  handoff_.Request(token);
  ArmRetirement();
}

void WetInk::ArmRetirement() {
  // The engine owns one callback slot. Serialize retirements, including strokes
  // completed while an older callback is already queued on the platform thread.
  auto token = handoff_.Arm();
  // Disposed editors no longer service requestFrame. Missing visuals need no
  // presentation barrier; drain those tokens without blocking the next owner.
  while (token && !completed_.count(token)) {
    if (handoff_.Complete(token))
      channel_->InvokeMethod("retired", std::make_unique<EncodableValue>(token));
    token = handoff_.Arm();
  }
  if (!token) return;
  const auto alive = alive_;
  const auto window = window_;
  next_frame_([alive, window, token] {
    if (alive->load()) PostMessage(window, kRetireInk, static_cast<WPARAM>(token), 0);
  });
  channel_->InvokeMethod("requestFrame", std::make_unique<EncodableValue>(token));
}

bool WetInk::Initialize() {
  if (composition_) return true;
  ComPtr<ID3D11Device> d3d;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
      &d3d, nullptr, nullptr))) return false;
  ComPtr<IDXGIDevice> dxgi;
  ComPtr<ID2D1Device> d2d;
  if (FAILED(d3d.As(&dxgi)) ||
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory_.GetAddressOf())) ||
      FAILED(factory_->CreateDevice(dxgi.Get(), &d2d)) ||
      FAILED(d2d->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context_))) return false;
  ComPtr<IDCompositionDesktopDevice> composition;
  if (FAILED(DCompositionCreateDevice2(d2d.Get(), IID_PPV_ARGS(&composition))) ||
      FAILED(composition->CreateTargetForHwnd(target_window_, TRUE, &target_)) ||
      FAILED(composition->CreateVisual(&root_)) ||
      FAILED(target_->SetRoot(root_.Get()))) return false;
  const auto properties = D2D1::StrokeStyleProperties(
      D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
      D2D1_LINE_JOIN_ROUND);
  if (FAILED(factory_->CreateStrokeStyle(properties, nullptr, 0, &stroke_style_))) return false;
  composition_ = std::move(composition);
  return true;
}

bool WetInk::Begin(const EncodableMap& args) {
  Archive();
  Clear();
  // Bound queued GPU surfaces without ever removing an unacknowledged stroke.
  // Flutter renders new contacts if the platform outruns raster presentation.
  if (completed_.size() >= 4) return false;
  const auto* bounds = std::get_if<flutter::EncodableList>(&Field(args, "clip"));
  const auto* type = std::get_if<std::string>(&Field(args, "type"));
  const auto* reference = std::get_if<flutter::EncodableList>(&Field(args, "reference"));
  if (pending_.empty() || !bounds || bounds->size() != 4 || !type ||
      !reference || reference->size() != 4) return false;
  POINT origin{};
  MapWindowPoints(window_, target_window_, &origin, 1);
  const float origin_x = static_cast<float>(origin.x);
  const float origin_y = static_cast<float>(origin.y);
  // Flutter pointer IDs differ from Windows IDs. Match the buffered native
  // contact by its down location instead, never by a synthetic Flutter ID.
  if (std::hypot(pending_.front().x - Scalar(args, "x") - origin_x,
                 pending_.front().y - Scalar(args, "y") - origin_y) > 4) return false;
  width_ = Scalar(args, "width");
  dpr_ = Scalar(args, "dpr");
  if (!std::isfinite(width_) || width_ <= 0 || !std::isfinite(dpr_) || dpr_ <= 0) return false;
  clip_ = D2D1::RectF(static_cast<float>(Number((*bounds)[0])) + origin_x,
      static_cast<float>(Number((*bounds)[1])) + origin_y,
      static_cast<float>(Number((*bounds)[2])) + origin_x,
      static_cast<float>(Number((*bounds)[3])) + origin_y);
  reference_x_ = static_cast<float>(Number((*reference)[0])) + origin_x;
  reference_y_ = static_cast<float>(Number((*reference)[1])) + origin_y;
  reference_width_ = static_cast<float>(Number((*reference)[2]));
  reference_height_ = static_cast<float>(Number((*reference)[3]));
  if (!std::isfinite(reference_width_) || !std::isfinite(reference_height_) ||
      reference_width_ <= 0 || reference_height_ <= 0) return false;
  RECT client{};
  GetClientRect(target_window_, &client);
  if (client.right <= 0 || client.bottom <= 0) return false;
  uint64_t pixels = static_cast<uint64_t>(client.right) * static_cast<uint64_t>(client.bottom);
  for (const auto& entry : completed_) {
    if (entry.second.surface) pixels += entry.second.pixels;
  }
  // At most 128 MiB of composition surfaces, plus the reusable stable bitmap.
  if (pixels > 32 * 1024 * 1024) return false;
  token_ = static_cast<int64_t>(Number(Field(args, "token")));
  if (!token_ || !Initialize()) return false;
  if (FAILED(composition_->CreateVisual(&visual_)) ||
      FAILED(root_->AddVisual(visual_.Get(), TRUE, nullptr))) return false;
  if (!EnsureBuffers(static_cast<UINT>(client.right), static_cast<UINT>(client.bottom))) return false;
  const auto color = static_cast<uint32_t>(Number(Field(args, "color")));
  color_ = D2D1::ColorF(color & 0xffffff, 1);
  type_ = *type;
  sensitivity_ = std::clamp(Scalar(args, "pressure"), 0.0f, 1.0f);
  sharpness_ = std::clamp(Scalar(args, "sharpness"), 0.0f, 1.0f);
  if (!brush_ && FAILED(context_->CreateSolidColorBrush(color_, &brush_))) return false;
  brush_->SetColor(color_);
  if (!opacity_ && FAILED(composition_->CreateEffectGroup(&opacity_))) return false;
  if (FAILED(visual_->SetContent(surface_.Get())) ||
      FAILED(opacity_->SetOpacity(type_ == "highlighter" ? .3f : static_cast<float>((color >> 24) & 255) / 255.0f)) ||
      FAILED(visual_->SetEffect(opacity_.Get()))) return false;
  context_->SetDpi(96, 96);
  context_->SetTarget(stable_.Get());
  context_->BeginDraw();
  context_->Clear(D2D1::ColorF(0, 0.0f));
  if (FAILED(context_->EndDraw())) return false;
  for (const auto& point : pending_) Append(point);
  if (!contact_) frozen_ = true;
  ArmPredictionExpiry();
  return Paint();
}

bool WetInk::EnsureBuffers(UINT width, UINT height) {
  if (stable_ && surface_ && width == surface_width_ && height == surface_height_) return true;
  // Allocate only on first use, resize, or device recovery. Each new stroke
  // still clears both retained targets before displaying them.
  ComPtr<ID2D1Bitmap1> stable;
  ComPtr<IDCompositionSurface> surface;
  const auto properties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
  if (stable_ && width == surface_width_ && height == surface_height_) stable = stable_;
  else if (FAILED(context_->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, properties, &stable))) return false;
  if (FAILED(composition_->CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM,
          DXGI_ALPHA_MODE_PREMULTIPLIED, &surface))) return false;
  stable_ = std::move(stable);
  surface_ = std::move(surface);
  surface_width_ = width;
  surface_height_ = height;
  surface_initialized_ = false;
  return true;
}

void WetInk::ReleaseBuffers() noexcept {
  if (context_) context_->SetTarget(nullptr);
  surface_.Reset();
  stable_.Reset();
  surface_width_ = surface_height_ = 0;
  surface_initialized_ = false;
}

void WetInk::ArmPredictionExpiry() {
  KillTimer(window_, reinterpret_cast<UINT_PTR>(this));
  const auto age = GetTickCount64() - last_sample_arrival_;
  if (frozen_ || clipped_ || age >= ink::Predictor::kExpiryMs) prediction_ = {};
  if (prediction_.count && !SetTimer(window_, reinterpret_cast<UINT_PTR>(this),
      static_cast<UINT>(ink::Predictor::kExpiryMs - age), nullptr)) prediction_ = {};
}

void WetInk::Freeze() {
  frozen_ = true;
  KillTimer(window_, reinterpret_cast<UINT_PTR>(this));
  predictor_.Reset();
  prediction_ = {};
  if (token_ && painted_prediction_.count && !Paint()) Fail();
}

void WetInk::Append(Point point) {
  if (clipped_) return;
  if (point.x < clip_.left || point.x >= clip_.right ||
      point.y < clip_.top || point.y >= clip_.bottom) {
    clipped_ = true;
    prediction_ = {};
    predictor_.Reset();
    return;
  }
  const auto raw = point;
  if (!points_.empty()) {
    const auto previous = points_.back();
    const double dt = std::clamp(point.time - raw_.time, 1.0 / 240, .05);
    const double vx = (point.x - raw_.x) / dpr_ / dt;
    const double vy = (point.y - raw_.y) / dpr_ / dt;
    vx_ += (vx - vx_) * Alpha(1, dt);
    vy_ += (vy - vy_) * Alpha(1, dt);
    const double fast_alpha = Alpha(10, dt);
    fast_vx_ += (vx - fast_vx_) * fast_alpha;
    fast_vy_ += (vy - fast_vy_) * fast_alpha;
    const double speed = std::max(std::hypot(vx_, vy_),
        std::hypot(fast_vx_, fast_vy_) - 2 * fast_alpha / dt);
    const double alpha = Alpha(1.5 + .04 * speed, dt);
    point.x = previous.x + static_cast<float>((point.x - previous.x) * alpha);
    point.y = previous.y + static_cast<float>((point.y - previous.y) * alpha);
    const float distance = std::hypot(point.x - raw.x, point.y - raw.y);
    if (distance > dpr_) {
      point.x = raw.x + (point.x - raw.x) * dpr_ / distance;
      point.y = raw.y + (point.y - raw.y) * dpr_ / distance;
    }
    point.pressure = previous.pressure + static_cast<float>(
        (point.pressure - previous.pressure) * Alpha(8, dt));
  }
  raw_ = raw;
  points_.push_back(point);
  prediction_ = predictor_.Add(raw, point.pressure, dpr_);
}

float WetInk::Width(const ink::StrokeView& points, size_t index) const {
  if (type_ == "highlighter") return width_;
  const float response = type_ == "ball" ? .3f : type_ == "brush" ? 1.3f : .8f;
  const float pressure = 1 + (points[index].pressure - .75f) * 2 * sensitivity_ * response;
  float nib = 1;
  if (type_ == "fountain" && points.size() > 1) {
    const auto a = points[index == 0 ? 0 : index - 1];
    const auto b = points[std::min(points.size() - 1, index + 1)];
    const auto angle = std::atan2(b.y - a.y, b.x - a.x);
    nib = 1 - sharpness_ * .65f * std::abs(std::cos(angle - static_cast<float>(kPi / 4)));
  } else if (type_ == "brush" && points.size() > 1) {
    const float edge = static_cast<float>(std::min(index, points.size() - 1 - index)) /
        std::min(6.0f, static_cast<float>(points.size()) / 2);
    nib = 1 - sharpness_ * .8f * (1 - std::clamp(edge, 0.0f, 1.0f));
  } else if (type_ == "ball") {
    nib = 1 - sharpness_ * .2f;
  }
  return width_ * std::max(.08f, pressure) * nib;
}

void WetInk::Segment(ID2D1DeviceContext* context, const ink::StrokeView& points, size_t index) {
  const auto a = points[index - 1];
  const auto b = points[index];
  if (type_ == "highlighter") {
    context->DrawLine(D2D1::Point2F(a.x, a.y), D2D1::Point2F(b.x, b.y),
        brush_.Get(), width_, stroke_style_.Get());
    return;
  }
  const auto start = index == 1 ? D2D1::Point2F(a.x, a.y) :
      D2D1::Point2F((points[index - 2].x + a.x) / 2, (points[index - 2].y + a.y) / 2);
  const auto end = index == points.size() - 1 ? D2D1::Point2F(b.x, b.y) :
      D2D1::Point2F((a.x + b.x) / 2, (a.y + b.y) / 2);
  ComPtr<ID2D1PathGeometry> path;
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(factory_->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) return;
  sink->BeginFigure(start, D2D1_FIGURE_BEGIN_HOLLOW);
  sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(D2D1::Point2F(a.x, a.y), end));
  sink->EndFigure(D2D1_FIGURE_END_OPEN);
  if (SUCCEEDED(sink->Close())) context->DrawGeometry(path.Get(), brush_.Get(),
      std::max(.1f * dpr_, (Width(points, index - 1) + Width(points, index)) / 2), stroke_style_.Get());
}

bool WetInk::Paint() {
  if (!token_ || points_.empty()) return false;
  RECT update{0, 0, static_cast<LONG>(surface_width_), static_cast<LONG>(surface_height_)};
  if (surface_initialized_) {
    // Include the previous tail and every newly received sample, including a
    // coalesced input burst. Stable pixels elsewhere never need to be copied.
    const size_t first = next_segment_ > 1 ? next_segment_ - 2 : 0;
    ink::Bounds bounds(points_[first]);
    for (size_t i = first + 1; i < points_.size(); ++i) bounds.Include(points_[i]);
    bounds.Include(prediction_);
    bounds.Include(painted_prediction_);
    const float padding = width_ * 3 + 2;
    update = {std::max(0L, static_cast<LONG>(std::floor(bounds.left - padding))),
      std::max(0L, static_cast<LONG>(std::floor(bounds.top - padding))),
      std::min(static_cast<LONG>(surface_width_), static_cast<LONG>(std::ceil(bounds.right + padding))),
      std::min(static_cast<LONG>(surface_height_), static_cast<LONG>(std::ceil(bounds.bottom + padding)))};
    if (update.right <= update.left || update.bottom <= update.top) return true;
  }
  // Stable ink is rasterized once; only the changing tail is rebuilt. This
  // keeps work bounded even for a very long stroke. Marker opacity is applied
  // to the visual, so overlapping segments never darken within one highlight.
  context_->SetTarget(stable_.Get());
  context_->BeginDraw();
  const size_t stable_end = type_ == "highlighter" ? points_.size() :
      points_.size() > 12 ? points_.size() - 8 : 1;
  const ink::StrokeView confirmed(points_);
  while (next_segment_ < stable_end) Segment(context_.Get(), confirmed, next_segment_++);
  if (FAILED(context_->EndDraw())) return false;
  context_->SetTarget(nullptr);
  ComPtr<ID2D1DeviceContext> draw;
  POINT offset{};
  if (FAILED(surface_->BeginDraw(&update, IID_PPV_ARGS(&draw), &offset))) return false;
  draw->SetDpi(96, 96);
  draw->SetTransform(D2D1::Matrix3x2F::Translation(
      static_cast<float>(offset.x - update.left), static_cast<float>(offset.y - update.top)));
  draw->PushAxisAlignedClip(D2D1::RectF(static_cast<float>(update.left), static_cast<float>(update.top),
      static_cast<float>(update.right), static_cast<float>(update.bottom)), D2D1_ANTIALIAS_MODE_ALIASED);
  draw->Clear(D2D1::ColorF(0, 0.0f));
  draw->PushAxisAlignedClip(clip_, D2D1_ANTIALIAS_MODE_ALIASED);
  draw->DrawBitmap(stable_.Get(), nullptr, 1.0f, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nullptr, nullptr);
  const ink::StrokeView preview(points_, prediction_);
  if (preview.size() == 1) {
    const auto point = points_.front();
    const float radius = Width(confirmed, 0) / 2;
    draw->FillEllipse(D2D1::Ellipse(D2D1::Point2F(point.x, point.y), radius, radius), brush_.Get());
  } else {
    for (size_t i = next_segment_; i < preview.size(); ++i) Segment(draw.Get(), preview, i);
  }
  draw->PopAxisAlignedClip();
  draw->PopAxisAlignedClip();
  const auto hr = surface_->EndDraw();
  surface_initialized_ = SUCCEEDED(hr);
  if (SUCCEEDED(hr)) painted_prediction_ = prediction_;
  return SUCCEEDED(hr) && SUCCEEDED(composition_->Commit());
}

void WetInk::ReadPoints(UINT32 pointer, bool ending) {
  UINT32 count = 0;
  std::vector<POINTER_PEN_INFO> history;
  if (GetPointerPenInfoHistory(pointer, &count, nullptr) && count > 0 && count <= 4096) {
    history.resize(count);
    if (!GetPointerPenInfoHistory(pointer, &count, history.data())) history.clear();
    else history.resize(count);
  }
  if (history.empty()) {
    POINTER_PEN_INFO point{};
    if (!GetPointerPenInfo(pointer, &point)) return;
    history.push_back(point);
  }
  LARGE_INTEGER frequency{};
  QueryPerformanceFrequency(&frequency);
  // Windows returns newest first; preserve chronological order and skip the
  // overlapping history delivered by successive messages.
  for (auto it = history.rbegin(); it != history.rend(); ++it) {
    const auto& info = it->pointerInfo;
    if ((info.PerformanceCount && info.PerformanceCount <= last_counter_) ||
        (!info.PerformanceCount && last_time_ && info.dwTime <= last_time_)) continue;
    last_counter_ = info.PerformanceCount;
    last_time_ = info.dwTime;
    if (!(info.pointerFlags & POINTER_FLAG_INCONTACT) && !ending) continue;
    last_sample_arrival_ = GetTickCount64();
    POINT position = info.ptPixelLocation;
    ScreenToClient(target_window_, &position);
    const double time = info.PerformanceCount ?
        static_cast<double>(info.PerformanceCount) / static_cast<double>(frequency.QuadPart) : info.dwTime / 1000.0;
    const float pressure = !(info.pointerFlags & POINTER_FLAG_INCONTACT) ?
        (points_.empty() ? .75f : points_.back().pressure) :
        (it->penMask & PEN_MASK_PRESSURE) ? std::clamp(static_cast<float>(it->pressure) / 1024.0f, .05f, 1.0f) : .75f;
    const Point point{static_cast<float>(position.x), static_cast<float>(position.y), pressure, time};
    if (token_) { if (!frozen_) Append(point); }
    else if (pending_.size() < 4096) pending_.push_back(point);
  }
  if (token_ && !frozen_) {
    if (ending) { prediction_ = {}; predictor_.Reset(); }
    ArmPredictionExpiry();
    if (!Paint()) Fail();
  }
}

void WetInk::Clear() noexcept {
  if (window_) KillTimer(window_, reinterpret_cast<UINT_PTR>(this));
  predictor_.Reset();
  prediction_ = painted_prediction_ = {};
  token_ = 0;
  frozen_ = false;
  clipped_ = false;
  surface_initialized_ = false;
  points_.clear();
  next_segment_ = 1;
  vx_ = vy_ = fast_vx_ = fast_vy_ = 0;
  if (root_ && visual_) root_->RemoveVisual(visual_.Get());
  visual_.Reset();
  opacity_.Reset();
  if (composition_) composition_->Commit();
  if (context_) context_->SetTarget(nullptr);
}

void WetInk::Fail() noexcept {
  const auto token = token_;
  Clear();
  // Drop the device as well: the next contact can recover after device loss.
  ReleaseBuffers();
  brush_.Reset(); opacity_.Reset();
  for (auto& entry : completed_) { entry.second.visual.Reset(); entry.second.surface.Reset(); }
  visual_.Reset(); root_.Reset(); target_.Reset(); composition_.Reset();
  context_.Reset(); factory_.Reset(); stroke_style_.Reset();
  if (token) channel_->InvokeMethod("failed", std::make_unique<EncodableValue>(token));
}

void WetInk::Cancel() noexcept {
  const auto token = token_;
  Archive();
  Clear();
  // View changes invalidate screen-space overlays, but retain confirmed samples
  // until Dart's freeze request arrives (focus loss can precede that request).
  for (auto& entry : completed_) {
    if (root_ && entry.second.visual) root_->RemoveVisual(entry.second.visual.Get());
    entry.second.visual.Reset();
    entry.second.surface.Reset();
  }
  if (composition_) composition_->Commit();
  // Routine cancellation should not destroy reusable GPU resources. Actual
  // graphics failures use Fail(), which also releases the device and buffers.
  if (token) channel_->InvokeMethod("failed", std::make_unique<EncodableValue>(token));
  contact_ = false;
  pointer_ = 0;
  pending_.clear();
}

LRESULT CALLBACK WetInk::WindowProc(HWND window, UINT message, WPARAM wparam,
    LPARAM lparam, UINT_PTR subclass_id, DWORD_PTR data) {
  auto* self = reinterpret_cast<WetInk*>(data);
  const auto pointer = GET_POINTERID_WPARAM(wparam);
  if (message == WM_TIMER && wparam == reinterpret_cast<UINT_PTR>(self)) {
    // KillTimer does not remove already queued messages. Check the newest
    // sample's age before expiring a prediction belonging to a later stroke.
    if (self->token_ && !self->frozen_ && self->prediction_.count) {
      self->ArmPredictionExpiry();
      if (!self->prediction_.count) {
        self->predictor_.Reset();
        if (!self->Paint()) self->Fail();
      }
    } else {
      KillTimer(window, wparam);
    }
    return 0;
  }
  if (message == kRetireInk) {
    const auto retired = self->handoff_.Complete(static_cast<int64_t>(wparam));
    if (retired) {
      self->Discard(retired);
      self->channel_->InvokeMethod("retired", std::make_unique<EncodableValue>(retired));
    }
    self->ArmRetirement();
    return 0;
  }
  if (message == WM_POINTERDOWN) {
    POINTER_PEN_INFO info{};
    if (GetPointerPenInfo(pointer, &info) && !(info.penFlags & (PEN_FLAG_INVERTED | PEN_FLAG_ERASER))) {
      self->Archive();
      self->Clear();
      self->pointer_ = pointer;
      self->contact_ = true;
      self->last_counter_ = 0;
      self->last_time_ = 0;
      self->pending_.clear();
      self->ReadPoints(pointer, false);
    }
  } else if ((message == WM_POINTERUPDATE || message == WM_POINTERUP) && pointer == self->pointer_) {
    if (IS_POINTER_CANCELED_WPARAM(wparam)) self->Cancel();
    else if (self->contact_) {
      self->ReadPoints(pointer, message == WM_POINTERUP);
      if (message == WM_POINTERUP) { self->contact_ = false; self->Freeze(); }
    }
  } else if ((message == WM_POINTERCAPTURECHANGED || message == WM_POINTERLEAVE) &&
      pointer == self->pointer_ && self->contact_) {
    self->Cancel();
  } else if (message == WM_KILLFOCUS || message == WM_CANCELMODE || message == WM_SIZE ||
      message == WM_DPICHANGED_AFTERPARENT) {
    self->Cancel();
    if (message == WM_SIZE || message == WM_DPICHANGED_AFTERPARENT) self->ReleaseBuffers();
  } else if (message == WM_NCDESTROY) {
    self->Cancel();
    RemoveWindowSubclass(window, WindowProc, subclass_id);
    self->window_ = nullptr;
  }
  // Native preview never consumes pen, touch, mouse, or eraser input.
  return DefSubclassProc(window, message, wparam, lparam);
}
