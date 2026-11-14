#include <flutter/runtime_effect.glsl>

// The same clear body and reflection as desktop, with two broad currents
// instead of a sampled noise field. No texture reads on the phone's full
// viewport, even while scrolling with a finger down.
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
out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / resolution;
  vec2 p = uv;
  float ripple = 0.;
  if (hover > .001) {
    vec2 delta = uv - pointer;
    vec2 local = delta * resolution / min(resolution.x, resolution.y);
    float weight = max(0., 1. - dot(local, local) * 5.);
    p += (delta * .16 + wake * .65) * weight * weight * hover;
  }
  if (pressAge >= 0. && pressAge < .85) {
    vec2 delta = (uv - press) * resolution;
    float life = 1. - pressAge / .85;
    float radius = 7. + 115. * (1. - life * life);
    // A soft ring with a darker inner edge, measured in logical pixels.
    float band = length(delta) - radius;
    float crest = max(0., 1. - abs(band) * .10);
    float trough = max(0., 1. - abs(band + 9.) * .12);
    ripple = (crest * crest - trough * trough * .48) * life;
    p += delta / resolution * ripple * .07;
  }
  vec2 q = vec2(p.x, 1. - p.y);
  float pool = .5 + .5 * sin(q.x * 3.8 - q.y * 3. + phase - time * .72);
  float current = sin(q.y * 5.2 + q.x * 1.9 + pool * 2.6 - time * .65);
  float ribbon = max(current, 0.);
  ribbon *= ribbon * ribbon;
  float sheen = max(sin(q.x * 3.6 - q.y * 4.8 + pool + time * .43), 0.);
  sheen *= sheen;
  sheen *= sheen;

  vec3 ice = mix(vec3(.76, .89, 1.), vec3(.65, .81, 1.), night);
  vec3 color = mix(tint * mix(.80, 1., night), ice, .14 + .30 * pool);
  color = mix(color, vec3(1.), ribbon * mix(.08, .29, night) + sheen * .10);
  float alpha = .019 + pool * mix(.059, .139, night)
      + ribbon * mix(.146, .082, night) + sheen * .018 + ripple * .042;
  alpha = max(0., alpha) * strength * mix(1., 1.12, night) * mix(1., .58, background);
  fragColor = vec4(color * alpha, alpha);
}
