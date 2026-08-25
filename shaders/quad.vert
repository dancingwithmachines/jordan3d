#version 300 es
// One oversized triangle covering the viewport (cheaper than two). aPos is in
// clip space; vUv is 0..1 across the visible area, origin bottom-left, which
// matches textures uploaded with UNPACK_FLIP_Y.
in vec2 aPos;
out vec2 vUv;

void main() {
  vUv = aPos * 0.5 + 0.5;
  gl_Position = vec4(aPos, 0.0, 1.0);
}
