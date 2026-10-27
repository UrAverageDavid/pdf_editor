// Portable tests for the exact predictor and stroke view used by wet_ink.cpp.
// clang++ -std=c++20 -Wall -Wextra -Werror tool/native_ink_test.cpp -o /tmp/native_ink_test
#include "../windows/runner/ink_prediction.h"
#include "../windows/runner/ink_handoff.h"

#include <cstdlib>
#include <iostream>
#include <limits>

namespace {
void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
void Near(double actual, double expected, const char* message) {
  Check(std::abs(actual - expected) < .001, message);
}

ink::Prediction Moving(ink::Predictor& predictor, float dpr = 1, double speed = 500,
                      double hz = 100) {
  ink::Prediction prediction;
  for (int i = 0; i <= 4; ++i) {
    prediction = predictor.Add({static_cast<float>(speed * i / hz * dpr),
        0, .9f, i / hz}, .6f, dpr);
  }
  return prediction;
}

void SteadyMotion() {
  for (const float dpr : {.5f, 1.0f, 1.5f, 2.0f, 3.0f}) {
    for (const double hz : {60.0, 120.0, 240.0}) {
      ink::Predictor predictor;
      const auto prediction = Moving(predictor, dpr, 500, hz);
      Check(prediction.count == 2, "Steady motion should predict two points");
      const double x = 500 * 4 / hz * dpr;
      Near((prediction.points[0].x - x) / dpr, 3.75, "Half-horizon should be 3.75 logical pixels");
      Near((prediction.points[1].x - x) / dpr, 7.5, "Full horizon should be 7.5 logical pixels");
      Near(prediction.points[1].time - 4 / hz, .015, "Prediction should project 15 ms");
      Near(prediction.points[1].pressure, .6, "Use filtered pressure, not raw pressure");
    }
  }
  ink::Predictor fast;
  const auto prediction = Moving(fast, 2, 10000);
  Near((prediction.points[1].x - 800) / 2, 24, "Fast motion must respect the logical pixel cap");
}

void ChangingMotion() {
  ink::Predictor corner;
  Moving(corner);
  Check(corner.Add({20, 5, .75f, .05}, .75f, 1).count == 0,
      "Right angle should retract the predicted tip");
  ink::Predictor reverse;
  Moving(reverse);
  Check(reverse.Add({15, 0, .75f, .05}, .75f, 1).count == 0,
      "Reversal should retract the predicted tip");
  ink::Predictor stop;
  Moving(stop);
  Check(stop.Add({20, 0, .75f, .05}, .75f, 1).count == 0,
      "Stationary sample should retract the predicted tip");
  ink::Predictor slowing;
  Moving(slowing);
  const auto short_tip = slowing.Add({24, 0, .75f, .05}, .75f, 1);
  Check(short_tip.count == 2 && short_tip.points[1].x - 24 < 6,
      "Deceleration must reduce the horizon, not just the velocity");
  ink::Predictor slight_turn;
  Moving(slight_turn);
  const auto turn_tip = slight_turn.Add({24, 3, .75f, .05}, .75f, 1);
  Check(turn_tip.count == 2 && std::hypot(turn_tip.points[1].x - 24, turn_tip.points[1].y - 3) < 7.5,
      "A gentle turn should shorten the tip");
  ink::Predictor jitter;
  for (int i = 0; i < 20; ++i) {
    Check(jitter.Add({static_cast<float>(i % 2) * .1f, 0, .75f, i * .005}, .75f, 1).count == 0,
        "Subpixel jitter should not predict");
  }
}

void InvalidTimingAndReset() {
  for (const double time : {.04, .039, .0405, .1, std::numeric_limits<double>::quiet_NaN()}) {
    ink::Predictor predictor;
    Moving(predictor);
    Check(predictor.Add({25, 0, .75f, time}, .75f, 1).count == 0,
        "Duplicate, out-of-order, too-close, invalid, or paused samples must not predict");
  }
  ink::Predictor predictor;
  Moving(predictor);
  predictor.Reset();
  Check(predictor.Add({0, 0, .75f, 1}, .75f, 1).count == 0, "New stroke needs a first velocity");
  Check(predictor.Add({5, 0, .75f, 1.01}, .75f, 1).count == 0, "New stroke needs a second velocity");
  Check(predictor.Add({10, 0, .75f, 1.02}, .75f, 1).count == 2, "Predict after two fresh velocities");
}

void PreviewIsolationAndDamage() {
  const std::vector<ink::Point> saved{{0, 0, .75f, 0}, {5, 0, .7f, .01}, {10, 0, .6f, .02}};
  ink::Predictor predictor;
  ink::Prediction prediction;
  for (const auto& point : saved) prediction = predictor.Add(point, point.pressure, 1);
  const ink::StrokeView confirmed(saved);
  const ink::StrokeView preview(saved, prediction);
  Check(confirmed.size() == 3 && preview.size() == 5, "Prediction belongs only to the preview view");
  Check(&preview[0] == &saved[0] && &preview[3] == &prediction.points[0], "Views must not copy the stroke");
  Near(preview[4].x, 17.5, "Preview should include the predicted endpoint");
  ink::Bounds damage(saved.back());
  damage.Include(prediction);
  const auto shorter = predictor.Add({12, 0, .6f, .03}, .6f, 1);
  damage.Include(shorter);
  Near(damage.right, 17.5, "Retraction must repaint the old tip's furthest pixels");
  prediction = {};
  Check(preview.size() == 3 && saved.size() == 3 && saved.back().x == 10,
      "Expiry must reveal only the original input, without modifying it");
  ink::Bounds vertical(saved.back());
  ink::Prediction previous_tip;
  previous_tip.count = 2;
  previous_tip.points = {{{-4, -9, .6f, .03}, {20, 12, .6f, .04}}};
  vertical.Include(previous_tip);
  Check(vertical.left == -4 && vertical.top == -9 && vertical.right == 20 && vertical.bottom == 12,
      "Damage must cover old prediction in every direction");
}
void RapidStrokeHandoffs() {
  ink::HandoffQueue queue;
  Check(queue.Arm() == 0, "No frame requested without a committed stroke");
  queue.Request(1);
  Check(queue.Arm() == 1, "First stroke arms the single callback slot");
  queue.Request(2);
  queue.Request(1);
  Check(queue.Arm() == 0, "Rapid second stroke cannot overwrite an in-flight callback");
  Check(queue.Complete(99) == 0 && queue.Arm() == 0, "Stale callback cannot release another stroke");
  Check(queue.Complete(1) == 0, "An already-in-flight frame must not retire ink");
  Check(queue.Arm() == 1, "A fresh frame is required for the same stroke");
  Check(queue.Complete(1) == 1, "Retire only after the barrier frame");
  Check(queue.Arm() == 2, "Newer stroke survives earlier retirement");
  Check(queue.Complete(1) == 0 && queue.Arm() == 0, "Old duplicate cannot retire the active token");
  Check(queue.Complete(2) == 0, "Second stroke has its own frame barrier");
  Check(queue.Arm() == 2 && queue.Complete(2) == 2, "Second stroke retires independently");
  Check(queue.Arm() == 0, "Duplicate request must not leave an orphan retirement");
}
}  // namespace

int main() {
  RapidStrokeHandoffs();
  SteadyMotion();
  ChangingMotion();
  InvalidTimingAndReset();
  PreviewIsolationAndDamage();
  std::cout << "Native ink prediction, sample isolation, damage bounds, and rapid handoffs passed.\n";
}
