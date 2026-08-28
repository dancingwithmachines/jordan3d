#version 300 es
// Layered ("2.5D") parallax.
//
// The single-plate path has to invent pixels: nothing exists behind the
// subject, so when the background slides out from behind him the march repeats
// edge pixels and they streak. And a thin near feature cannot displace further
// than it is wide, because the ray loses the feature and finds background.
//
// Two textures remove both problems:
//
//   * the sprite is displaced as a whole, so a fingertip travels exactly as far
//     as the palm it belongs to. There is no per-pixel search to lose.
//   * the background it uncovers was filled in offline, so there is real
//     texture to reveal and nothing has to be invented per frame.
//
// The background's own depth is the analytic vertical ramp used when building
// the depth map, so it needs no texture: shallow and monotonic, it does not
// need the implicit solve the single-plate path uses.

precision highp float;

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uBg;
uniform sampler2D uSprite;
uniform sampler2D uSubjDepth;   // smooth depth *within* the subject

uniform vec2  uUvScale;
uniform vec2  uUvOffset;
uniform vec2  uParallax;

uniform float uDepthScale;
uniform float uFocus;
uniform float uBgTop;        // background depth at the top of the frame
uniform float uBgBottom;     // ...and at the bottom
uniform float uSpriteDepth;  // the flat fallback, when relief is 0
uniform float uRelief;       // 0 = flat cutout, 1 = full subject depth
uniform vec3  uBackground;

void main() {
  vec2 base = (vUv - 0.5) * uUvScale + 0.5 + uUvOffset;

  // vUv counts up; the ramp was authored top-down, so flip for the lookup.
  float bgDepth = mix(uBgTop, uBgBottom, 1.0 - base.y);
  vec2 bgUv = base + uParallax * uDepthScale * (bgDepth - uFocus);

  // Depth inside the sprite is smooth — the hard subject/background edge is
  // alpha's job here, not depth's — so this needs no search along the ray and
  // therefore cannot clamp a thin feature the way the single-plate march does.
  // One refinement pass is plenty on a field this gentle.
  vec2 off = uParallax * uDepthScale;
  float sd = mix(uSpriteDepth, texture(uSubjDepth, base).r, uRelief);
  vec2 spUv = base + off * (sd - uFocus);
  sd = mix(uSpriteDepth, texture(uSubjDepth, spUv).r, uRelief);
  spUv = base + off * (sd - uFocus);

  vec3 bg = texture(uBg, bgUv).rgb;

  // The sprite's colour is extended past its alpha edge when it is built, so
  // filtering here can never drag a transparent black in and leave a fringe.
  vec4 sp = texture(uSprite, spUv);

  vec3 lit = mix(bg, sp.rgb, sp.a);

  vec2 inside = step(vec2(0.0), base) * step(base, vec2(1.0));
  float plate = inside.x * inside.y;
  fragColor = vec4(mix(uBackground, lit, plate), 1.0);
}
