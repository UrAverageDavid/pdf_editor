#ifndef RUNNER_INK_PREDICTION_H_
#define RUNNER_INK_PREDICTION_H_

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <optional>
#include <vector>

namespace ink {

struct Point { float x, y, pressure; double time; };

struct Prediction {
  std::array<Point, 2> points{};
  size_t count = 0;
};

// Coordinates are physical pixels; thresholds are logical screen pixels. This
// mirrors the Flutter preview's conservative predictor without altering input.
class Predictor {
 public:
  static constexpr unsigned kExpiryMs = 32;

  void Reset() { previous_.reset(); velocity_.reset(); }

  Prediction Add(const Point& raw, float filtered_pressure, float dpr) {
    const auto previous = previous_;
    const auto previous_velocity = velocity_;
    previous_ = raw;
    velocity_.reset();
    if (!previous || !std::isfinite(dpr) || dpr <= 0) return {};
    const double dt = raw.time - previous->time;
    if (!std::isfinite(dt) || dt < .001 || dt > .05) return {};
    const double dx = (raw.x - previous->x) / dpr;
    const double dy = (raw.y - previous->y) / dpr;
    const Velocity velocity{dx / dt, dy / dt};
    const double speed = std::hypot(velocity.x, velocity.y);
    if (!std::isfinite(speed)) return {};
    velocity_ = velocity;
    if (!previous_velocity || speed < 25 || std::hypot(dx, dy) < .35) return {};
    const double previous_speed = std::hypot(previous_velocity->x, previous_velocity->y);
    if (previous_speed < 25) return {};
    const double alignment = std::clamp(
        (velocity.x * previous_velocity->x + velocity.y * previous_velocity->y) /
            (speed * previous_speed), 0.0, 1.0);
    const double slowing = std::min(1.0, speed / previous_speed);
    const double change = std::hypot(velocity.x - previous_velocity->x,
        velocity.y - previous_velocity->y) * .015 / (dt * std::max(speed, 100.0));
    const double horizon = .015 * alignment * alignment * slowing * slowing / (1 + 2 * change);
    const double lead = std::min(24.0, speed * horizon);
    if (lead < .35) return {};
    const double duration = lead / speed;
    Prediction prediction;
    prediction.count = prediction.points.size();
    for (size_t i = 0; i < prediction.count; ++i) {
      const double time = duration * static_cast<double>(i + 1) / 2;
      prediction.points[i] = {raw.x + static_cast<float>(velocity.x * time * dpr),
          raw.y + static_cast<float>(velocity.y * time * dpr), filtered_pressure, raw.time + time};
    }
    return prediction;
  }

 private:
  struct Velocity { double x, y; };
  std::optional<Point> previous_;
  std::optional<Velocity> velocity_;
};

// A read-only concatenation keeps speculative samples out of the stable raster
// and the authoritative input vector, without copying a long stroke each frame.
class StrokeView {
 public:
  explicit StrokeView(const std::vector<Point>& confirmed) : confirmed_(confirmed) {}
  StrokeView(const std::vector<Point>& confirmed, const Prediction& prediction)
      : confirmed_(confirmed), prediction_(&prediction) {}
  size_t size() const { return confirmed_.size() + (prediction_ ? prediction_->count : 0); }
  const Point& operator[](size_t index) const {
    return index < confirmed_.size() ? confirmed_[index] : prediction_->points[index - confirmed_.size()];
  }

 private:
  const std::vector<Point>& confirmed_;
  const Prediction* prediction_ = nullptr;
};

// Both tips belong in the damage rectangle: a shorter or expired prediction
// must erase the pixels that the previous, longer prediction occupied.
struct Bounds {
  float left, top, right, bottom;
  explicit Bounds(const Point& point) : left(point.x), top(point.y), right(point.x), bottom(point.y) {}
  void Include(const Point& point) {
    left = std::min(left, point.x); right = std::max(right, point.x);
    top = std::min(top, point.y); bottom = std::max(bottom, point.y);
  }
  void Include(const Prediction& prediction) {
    for (size_t i = 0; i < prediction.count; ++i) Include(prediction.points[i]);
  }
};

}  // namespace ink

#endif  // RUNNER_INK_PREDICTION_H_
