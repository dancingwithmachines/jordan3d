#version 300 es
// Depth-map parallax ("3D photo").
//
// The colour plate is a flat quad, so the illusion comes entirely from where
// we *sample* it. For a view offset `off`, a pixel at depth d should be read
// from uv + off * (d - focus): near pixels slide with the camera, far pixels
// lag, and anything at the focus depth stays pinned.
//
// That is implicit — the depth we need lives at the displaced uv, not the
// original one. Fixed-point iteration solves it in a few passes on smooth
// depth, but at a silhouette the gradient is near-vertical and consecutive
// passes land on opposite sides of the cliff, which reads as ragged, crawling
// edges around a foreground subject.
//
// So instead we search along the view ray. Writing s = d - focus, every
// candidate sample sits at uv(s) = base + off * s, and we want the s where the
// surface actually is: depthAt(uv(s)) - focus == s. Marching from near to far
// and taking the *first* crossing is what makes this stable — the nearest
// surface wins, so a foreground edge cleanly occludes what lies behind it
// rather than the two fighting over the pixel.

precision highp float;

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uColor;
uniform sampler2D uDepth;

uniform vec2  uUvScale;     // cover-fit aspect correction, times the crop zoom
uniform vec2  uUvOffset;    // cover-fit recentring
uniform vec2  uParallax;    // -1..1 view offset from pointer / gyro / drift
uniform vec2  uTexel;       // 1.0 / depth map size

uniform float uDepthScale;  // parallax strength, in uv units
uniform float uFocus;       // depth value that stays pinned (0 far .. 1 near)
uniform float uInvert;      // 1.0 when the map is near-dark instead of near-light
uniform float uSmooth;      // depth blur radius, in texels
uniform float uDilate;      // 0..1 push the near surface over the far one
uniform int   uSteps;       // linear search steps along the view ray
uniform int   uRefine;      // binary steps that tighten the bracket
uniform vec3  uBackground;  // shown beside the plate when fitting to contain

float tap(vec2 uv) {
  float d = texture(uDepth, uv).r;
  return mix(d, 1.0 - d, uInvert);
}

// Blurring depth softens the stair-stepping that a low-res or heavily
// compressed map produces along edges. Dilating it biases the result toward
// the nearer of the neighbours, so the background stops smearing outward
// across a foreground silhouette.
float depthAt(vec2 uv) {
  float c = tap(uv);
  if (uSmooth <= 0.0) return c;

  vec2 r = uTexel * uSmooth;
  float n = tap(uv + vec2( r.x, 0.0));
  float s = tap(uv + vec2(-r.x, 0.0));
  float e = tap(uv + vec2(0.0,  r.y));
  float w = tap(uv + vec2(0.0, -r.y));

  float mean = (c * 2.0 + n + s + e + w) / 6.0;
  float peak = max(max(n, s), max(e, w));
  return mix(mean, max(mean, peak), uDilate);
}

void main() {
  vec2 base = (vUv - 0.5) * uUvScale + 0.5 + uUvOffset;
  vec2 off  = uParallax * uDepthScale;

  // g(s) is how far the surface sits in front of the ray at s. It starts
  // negative at the near end and ends positive at the far end, so the first
  // sign change walking outward is the nearest surface along the ray.
  float sNear = 1.0 - uFocus;
  float sFar  = -uFocus;

  float sA = sNear;
  float gA = depthAt(base + off * sNear) - uFocus - sNear;
  float sB = sFar;
  float gB = 0.0;
  bool found = false;

  for (int i = 1; i <= uSteps; i++) {
    float s = mix(sNear, sFar, float(i) / float(uSteps));
    float g = depthAt(base + off * s) - uFocus - s;
    if (g >= 0.0) { sB = s; gB = g; found = true; break; }
    sA = s; gA = g;
  }

  // Bisect the bracket, so edge placement is not quantised to the step size.
  if (found) {
    for (int j = 0; j < uRefine; j++) {
      float sM = 0.5 * (sA + sB);
      float gM = depthAt(base + off * sM) - uFocus - sM;
      if (gM >= 0.0) { sB = sM; gB = gM; } else { sA = sM; gA = gM; }
    }
  }

  float denom = gA - gB;
  float t = abs(denom) > 1e-6 ? clamp(gA / denom, 0.0, 1.0) : 0.0;
  float sHit = found ? mix(sA, sB, t) : sFar;
  vec2 uv = base + off * sHit;

  // Fitting to contain leaves slack beside the plate. Test the *undisplaced*
  // uv so the letterbox edge stays put instead of wobbling with the parallax.
  vec2 inside = step(vec2(0.0), base) * step(base, vec2(1.0));
  float plate = inside.x * inside.y;

  fragColor = vec4(mix(uBackground, texture(uColor, uv).rgb, plate), 1.0);
}
