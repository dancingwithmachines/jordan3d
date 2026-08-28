// Tuned values live here. The controls panel (press `d`) edits this object
// live and "copy config" prints it back in this shape — paste over `params`
// to make a look permanent.

export const paths = {
  color: 'assets/Jordan_Dunk.jpg',
  depth: 'assets/depth.png',

  // Layered mode. Built by tools/split_layers.sh.
  bg: 'assets/bg.jpg',
  sprite: 'assets/subject.png',

  // Used only if the two above are missing, so the page is never blank.
  // Regenerate with: python3 tools/make_test_scene.py
  fallbackColor: 'assets/test-color.png',
  fallbackDepth: 'assets/test-depth.png',
};

export const params = {
  // 'layers' composites a rigid subject sprite over a pre-filled background —
  // no dis-occlusion smear and no width clamp on thin features.
  // 'depth' is the original single-plate march. Switchable in the panel.
  mode: 'layers',

  // --- framing ---
  fit: 'contain',    // 'contain' shows the whole plate; 'cover' fills the canvas
  crop: 1.05,        // zoom in slightly so displacement never samples past the edge
  stageHeight: 1200, // stage height in CSS px; width follows the plate's aspect

  // --- the parallax itself ---
  depthScale: 0.045, // how far the near plane slides, in uv units
  focus: 0.5,        // depth that stays pinned: 0 = far, 1 = near
  steps: 24,         // ray-march steps; more = finer edge placement
  refine: 4,         // binary steps tightening the hit, cheap and worth it
  smooth: 0.0,       // depth blur in texels. 0 because the map is pre-softened
  dilate: 0.0,       // 0..1 bias edges nearer; the march handles occlusion now
  invert: 0,         // 1 if your map is near-dark / far-light

  // --- layered mode ---
  spriteDepth: 0.86, // one depth for the whole subject, so it travels rigidly
  bgTop: 0.26,       // must match what tools/make_depth.sh was given
  bgBottom: 0.34,

  // --- motion ---
  amplitude: 1.0,    // multiplies whatever the input source gives us
  damping: 0.09,     // 0..1 per-frame approach; lower = heavier, slower
  autoSpeed: 0.18,   // drift cycles per second
  autoAmount: 0.5,   // drift reach, as a fraction of full deflection
};

// Painted beside the plate when fitting to contain.
export const background = [0.04, 0.04, 0.04];

export const motionMode = 'both'; // pointer | auto | both | gyro

// Drives the slider list, in panel order.
export const schema = [
  { key: 'depthScale', label: 'depth',     min: 0,    max: 0.25, step: 0.001 },
  { key: 'focus',      label: 'focus',     min: 0,    max: 1,    step: 0.01 },
  { key: 'crop',       label: 'crop',      min: 1,    max: 1.4,  step: 0.005 },
  { key: 'stageHeight', label: 'height',   min: 400,  max: 2400, step: 10 },
  { key: 'fit',        label: 'fit',       options: ['contain', 'cover'] },
  { key: 'mode',       label: 'mode',      options: ['layers', 'depth'] },
  { key: 'spriteDepth', label: 'subject Z', min: 0.4, max: 1,  step: 0.005 },
  { key: 'bgTop',      label: 'bg top',    min: 0,    max: 0.8, step: 0.01 },
  { key: 'bgBottom',   label: 'bg btm',    min: 0,    max: 0.8, step: 0.01 },
  { key: 'steps',      label: 'steps',     min: 4,    max: 64,   step: 1 },
  { key: 'refine',     label: 'refine',    min: 0,    max: 8,    step: 1 },
  { key: 'smooth',     label: 'smooth',    min: 0,    max: 6,    step: 0.1 },
  { key: 'dilate',     label: 'dilate',    min: 0,    max: 1,    step: 0.01 },
  { key: 'invert',     label: 'invert',    min: 0,    max: 1,    step: 1 },
  { key: 'amplitude',  label: 'amplitude', min: 0,    max: 3,    step: 0.05 },
  { key: 'damping',    label: 'damping',   min: 0.01, max: 1,    step: 0.01 },
  { key: 'autoSpeed',  label: 'drift spd', min: 0,    max: 1,    step: 0.01 },
  { key: 'autoAmount', label: 'drift amt', min: 0,    max: 1,    step: 0.01 },
];
