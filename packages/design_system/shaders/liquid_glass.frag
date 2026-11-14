#include <flutter/runtime_effect.glsl>

// Clear lake material: a cached lattice keeps the optical field inexpensive.
uniform vec2 resolution;
uniform float time;
uniform float strength;
uniform float night;
uniform float hover;
uniform float phase;
uniform vec2 pointer;
uniform vec3 tint;
uniform float background;
uniform vec2 press;
uniform float pressAge;
uniform vec2 wake;
uniform sampler2D lattice;
out vec4 fragColor;

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3. - 2. * f);
  return texture(lattice, (mod(i, 128.) + f + .5) / 129.).r;
}
float field(vec2 p) { return .72 * noise(p) + .28 * noise(p * 1.83); }
void main() {
  vec2 uv = FlutterFragCoord().xy / resolution;
  uv.y = 1. - uv.y; // The approved WebGL specimen has a bottom-left origin.
  vec2 p = uv;
  p.x *= resolution.x / resolution.y;
  // These conditions are uniform across the surface: idle material does not
  // evaluate per-pixel hover/ripple math only to multiply the result by zero.
  if (hover > .00001) {
    vec2 touch = vec2(pointer.x, 1. - pointer.y);
    vec2 delta = uv - touch;
    vec2 aspect = vec2(resolution.x / resolution.y, 1.);
    vec2 local = delta * aspect;
    float vicinity = exp(-dot(local, local) * 9.) * hover;
    // The pointer displaces a reflection, rather than painting a light spot.
    p += (delta * .13 + vec2(wake.x, -wake.y) * .85) * vicinity;
  }
  float ripple = 0.;
  if (pressAge >= 0. && pressAge < 1.15) {
    vec2 fromPress = (uv - vec2(press.x, 1. - press.y)) * resolution;
    float distance = length(fromPress);
    float age = clamp(pressAge, 0., 1.15);
    float radius = 8. + 190. * (1. - pow(1. - age / 1.15, 2.));
    float band = (distance - radius) / 15.;
    ripple = exp(-band * band) * sin(band * 2.8) *
        max(0., 1. - pressAge / 1.15);
    p += fromPress / max(distance, 1.) * ripple * .065;
  }
  // The old field moved only .13 lattice cells in two seconds. Keep the same
  // eight cached-lattice samples, but let the two currents visibly pass each
  // other instead of leaving a nearly uniform category fill on light glass.
  float flow = time * 2.8 + phase;
  vec2 drift = vec2(flow * .055, -flow * .034);
  vec2 warp = vec2(field(p * 1.15 + drift), field(p * 1.2 - drift * .85 + 7.));
  float lake = field(p * 1.65 + warp * 1.25 + drift);
  float ribbon = sin(uv.y * 5.2 + uv.x * 1.9 + lake * 4.2 - time * .52);
  float reflected = pow(max(ribbon, 0.), 3.);
  float colorPool = smoothstep(.36, .66, lake);
  float sheen = pow(max(sin(uv.x * 2.8 - uv.y * 4. + lake * 3. + time * .38), 0.), 8.);
  vec3 ice = mix(vec3(.76, .89, 1.), vec3(.65, .81, 1.), night);
  vec3 color = mix(tint * mix(.80, 1., night), ice, .16 + .32 * field(p + drift * .6));
  color = mix(color, vec3(1.), reflected * mix(.08, .34, night) + sheen * .16 + max(ripple, 0.) * .13);
  // Redistribute opacity from the flat pool into broad passing reflections;
  // peak opacity remains below the original .275 (before touch/strength).
  float alpha = (.018 + colorPool * mix(.055, .16, night) + reflected * mix(.175, .07, night) + sheen * .025 + max(ripple, 0.) * .05) * strength;
  alpha *= mix(1., 1.12, night);
  alpha *= mix(1., .58, background);
  fragColor = vec4(color * alpha, alpha); // Flutter requires premultiplied RGB.
}
