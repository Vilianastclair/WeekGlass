#ifndef RUNNER_VORTEX_PLAYBACK_H_
#define RUNNER_VORTEX_PLAYBACK_H_

#include <algorithm>
#include <cmath>

// Phase is the underlying clock, not the shader's eased openness. Speeds
// are in phases per millisecond. A new command can sample this same clock
// even between presents or halfway through a previous reversal.
class VortexPlayback {
 public:
  struct Sample { double phase, speed; };

  void Start(double phase, bool open, bool gentle) {
    gentle_ = gentle;
    target_speed_ = Speed(open);
    start_ = {phase, target_speed_};
    turn_ms_ = 0.;
  }
  bool gentle() const { return gentle_; }
  void Reverse(Sample at, bool open) {
    start_ = at;
    target_speed_ = Speed(open);
    // Brake on the same path, then pick up in the new direction. Shorten
    // the brake near an end so a reversal never clips against it or pauses.
    const double room = at.speed > 0. ? 1. - at.phase : at.phase;
    turn_ms_ = gentle_ ? 0. : std::min(54., room / std::max(1e-9, std::abs(at.speed)));
  }
  Sample At(double ms) const {
    if (turn_ms_ > 0. && ms < turn_ms_) {
      const double u = ms / turn_ms_;
      const double diff = target_speed_ - start_.speed;
      const double integral = u*u*u*(1. - .5*u);
      return {std::clamp(start_.phase + start_.speed*ms + diff*turn_ms_*integral, 0., 1.),
              start_.speed + diff*u*u*(3. - 2.*u)};
    }
    const double p = start_.phase + .5*(start_.speed + target_speed_)*turn_ms_
                     + target_speed_*(ms - turn_ms_);
    return {std::clamp(p, 0., 1.), target_speed_};
  }
 private:
  double Speed(bool open) const { return (open ? 1. : -1.) / (gentle_ ? 250. : 490.); }
  Sample start_{};
  double target_speed_ = 0., turn_ms_ = 0.;
  bool gentle_ = false;
};

#endif  // RUNNER_VORTEX_PLAYBACK_H_
