#ifndef RUNNER_INK_HANDOFF_H_
#define RUNNER_INK_HANDOFF_H_

#include <algorithm>
#include <cstdint>
#include <deque>

namespace ink {
// Flutter exposes a single next-frame callback. Queue stroke ownership changes
// instead of replacing callbacks or clearing ink when the next contact starts.
class HandoffQueue {
 public:
  void Request(int64_t token) {
    if (token && std::find(tokens_.begin(), tokens_.end(), token) == tokens_.end())
      tokens_.push_back(token);
  }
  int64_t Arm() {
    if (armed_ || tokens_.empty()) return 0;
    armed_ = true;
    return tokens_.front();
  }
  // First frame drains work already in flight. The caller arms another callback
  // and requests another frame before transferring ownership of this stroke.
  int64_t Complete(int64_t token) {
    if (!armed_ || tokens_.empty() || tokens_.front() != token) return 0;
    armed_ = false;
    if (!barrier_) { barrier_ = true; return 0; }
    tokens_.pop_front();
    barrier_ = false;
    return token;
  }
 private:
  std::deque<int64_t> tokens_;
  bool armed_ = false;
  bool barrier_ = false;
};
}  // namespace ink
#endif  // RUNNER_INK_HANDOFF_H_
