#ifndef RUNNER_VORTEX_TIMING_H_
#define RUNNER_VORTEX_TIMING_H_

namespace vortex_timing {

constexpr float kMidpointRelief = .56f;

// Both directions use the same normalized [0, 1] clock. Give the fast,
// still-visible middle of the curl more time without holding the endpoints.
constexpr float Openness(float phase) {
  return phase + kMidpointRelief * phase * (1.f - phase) * (.5f - phase);
}

}  // namespace vortex_timing

#endif  // RUNNER_VORTEX_TIMING_H_
