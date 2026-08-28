import { paths, params as defaults, motionMode as defaultMode, schema, background } from './config.js';
import { initGL, loadProgram, createQuad, createTexture, loadImage, fitCanvas, fitUv } from './gl.js';
import { placeholderDepth } from './placeholder-depth.js';

const canvas   = document.getElementById('stage');
const dropzone = document.getElementById('dropzone');
const debugEl  = document.getElementById('debug');
const hud      = document.getElementById('hud');
const toastEl  = document.getElementById('toast');

const P = { ...defaults };
let mode = defaultMode;

let color = null;          // { tex, width, height }
let depth = null;
let bg = null;             // layered mode: pre-filled background plate
let sprite = null;         // layered mode: subject cut-out, with alpha
let placeholder = false;   // depth is luminance-derived, not real
let inspect = null;        // { cx, cy, z } magnifier, for checking edge artefacts

function toast(msg, ms = 1800) {
  toastEl.textContent = msg;
  toastEl.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { toastEl.hidden = true; }, ms);
}

function fail(msg) {
  dropzone.hidden = false;
  dropzone.innerHTML = `<h1>Jordan3D</h1><p>${msg}</p>`;
}

// ---------------------------------------------------------------- textures

function setColor(gl, source) {
  if (color) gl.deleteTexture(color.tex);
  color = createTexture(gl, source);
  dropzone.hidden = true;
  sizeStage();
  if (!depth || placeholder) setPlaceholder(gl, source);
}

// Match the element to the plate's aspect ratio. Because the stage and the
// image then agree, 'contain' and 'cover' resolve to the same framing: no bars,
// no distortion, whatever the window is doing.
function sizeStage() {
  if (!color) return;
  const h = P.stageHeight;
  canvas.style.height = `${h}px`;
  canvas.style.width = `${Math.round(h * (color.width / color.height))}px`;
}

function setDepth(gl, source) {
  if (depth) gl.deleteTexture(depth.tex);
  depth = createTexture(gl, source);
  placeholder = false;
}

function setBg(gl, source) {
  if (bg) gl.deleteTexture(bg.tex);
  bg = createTexture(gl, source);
}

function setSprite(gl, source) {
  if (sprite) gl.deleteTexture(sprite.tex);
  sprite = createTexture(gl, source);
}

function setPlaceholder(gl, source) {
  if (depth) gl.deleteTexture(depth.tex);
  depth = createTexture(gl, placeholderDepth(source));
  placeholder = true;
}

// ------------------------------------------------------------------ input

const pointer = [0, 0];
const target  = [0, 0];
const view    = [0, 0];   // damped, this is what the shader sees
let gyro = null;
let hasPointer = false;

addEventListener('pointermove', (e) => {
  hasPointer = true;
  pointer[0] = (e.clientX / innerWidth) * 2 - 1;
  pointer[1] = -((e.clientY / innerHeight) * 2 - 1);  // flip to uv-up
});

// Leaving the window eases back to centre rather than freezing off-axis.
addEventListener('pointerout', (e) => { if (!e.relatedTarget) hasPointer = false; });
addEventListener('blur', () => { hasPointer = false; });

addEventListener('deviceorientation', (e) => {
  if (e.gamma == null) return;
  // gamma: left/right tilt, beta: front/back. 25 degrees reaches full deflection.
  gyro = [
    Math.max(-1, Math.min(1, e.gamma / 25)),
    Math.max(-1, Math.min(1, (e.beta - 45) / 25)),
  ];
});

// iOS needs an explicit grant, and only from a gesture.
addEventListener('pointerdown', function askGyro() {
  const D = window.DeviceOrientationEvent;
  if (D && typeof D.requestPermission === 'function') D.requestPermission().catch(() => {});
  removeEventListener('pointerdown', askGyro);
});

function updateTarget(t) {
  let x = 0, y = 0;

  if (mode === 'pointer' || mode === 'both') {
    if (hasPointer) { x += pointer[0]; y += pointer[1]; }
  }
  if (mode === 'auto' || mode === 'both') {
    // Two incommensurate frequencies, so the path never visibly repeats.
    const w = t * Math.PI * 2 * P.autoSpeed;
    const idle = mode === 'both' && hasPointer ? 0.25 : 1;
    x += Math.sin(w) * P.autoAmount * idle;
    y += Math.sin(w * 0.73 + 1.3) * P.autoAmount * 0.6 * idle;
  }
  if (mode === 'gyro' && gyro) { x = gyro[0]; y = gyro[1]; }

  target[0] = Math.max(-1.5, Math.min(1.5, x)) * P.amplitude;
  target[1] = Math.max(-1.5, Math.min(1.5, y)) * P.amplitude;
}

// ------------------------------------------------------------------- main

async function main() {
  let gl, single, layered;
  try {
    gl = initGL(canvas);
    // Both paths are built up front so switching mode is just a program bind.
    single = await loadProgram(gl, 'shaders/quad.vert', 'shaders/parallax.frag');
    single.vao = createQuad(gl, single.prog);
    layered = await loadProgram(gl, 'shaders/quad.vert', 'shaders/layers.frag');
    layered.vao = createQuad(gl, layered.prog);
  } catch (err) {
    fail(err.message);
    return;
  }

  // Depth is optional at load — we synthesise a placeholder from the colour
  // plate so there is something to look at either way.
  try {
    setColor(gl, await loadImage(paths.color));
    try {
      setDepth(gl, await loadImage(paths.depth));
    } catch {
      toast('no depth map — showing a luminance placeholder', 4000);
    }
  } catch {
    try {
      setColor(gl, await loadImage(paths.fallbackColor));
      setDepth(gl, await loadImage(paths.fallbackDepth));
      toast('no plate in assets/ — this is the synthetic test scene', 5000);
    } catch {
      // Nothing to show; the dropzone stays up and drag-and-drop still works.
    }
  }

  // Layered assets are optional — without them the mode falls back.
  try {
    const [bgImg, spriteImg] = await Promise.all([loadImage(paths.bg), loadImage(paths.sprite)]);
    setBg(gl, bgImg);
    setSprite(gl, spriteImg);
  } catch {
    if (P.mode === 'layers') {
      P.mode = 'depth';
      toast('no layer assets — run tools/split_layers.sh', 5000);
    }
  }

  gl.useProgram(single.prog);
  gl.uniform1i(single.uniforms.uColor, 0);
  gl.uniform1i(single.uniforms.uDepth, 1);
  gl.uniform3f(single.uniforms.uBackground, background[0], background[1], background[2]);

  gl.useProgram(layered.prog);
  gl.uniform1i(layered.uniforms.uBg, 0);
  gl.uniform1i(layered.uniforms.uSprite, 1);
  gl.uniform3f(layered.uniforms.uBackground, background[0], background[1], background[2]);

  let last = performance.now();
  let fps = 60;

  // Draws exactly one frame from the current `view`. Kept separate from the
  // loop so it can be called directly — see window.J3D below.
  function draw() {
    const { w, h } = fitCanvas(gl, canvas);

    if (!color) {
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      return { w, h };
    }

    let { scale, offset } = fitUv(w, h, color.width, color.height, P.crop, P.fit);

    // Magnifier: shrink the sampled rect and recentre it, so a silhouette can
    // be examined at the pixel level without touching the parallax maths.
    if (inspect) {
      scale = [scale[0] * inspect.z, scale[1] * inspect.z];
      offset = [inspect.cx - 0.5, inspect.cy - 0.5];
    }

    const useLayers = P.mode === 'layers' && bg && sprite;
    const { prog, uniforms, vao } = useLayers ? layered : single;
    gl.useProgram(prog);
    gl.bindVertexArray(vao);

    if (useLayers) {
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, bg.tex);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, sprite.tex);
      gl.uniform1f(uniforms.uBgTop, P.bgTop);
      gl.uniform1f(uniforms.uBgBottom, P.bgBottom);
      gl.uniform1f(uniforms.uSpriteDepth, P.spriteDepth);
    } else {
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, color.tex);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, depth.tex);
      gl.uniform2f(uniforms.uTexel, 1 / depth.width, 1 / depth.height);
      gl.uniform1f(uniforms.uInvert, P.invert);
      gl.uniform1f(uniforms.uSmooth, P.smooth);
      gl.uniform1f(uniforms.uDilate, P.dilate);
      gl.uniform1i(uniforms.uSteps, Math.round(P.steps));
      gl.uniform1i(uniforms.uRefine, Math.round(P.refine));
    }

    gl.uniform2f(uniforms.uUvScale, scale[0], scale[1]);
    gl.uniform2f(uniforms.uUvOffset, offset[0], offset[1]);
    gl.uniform2f(uniforms.uParallax, view[0], view[1]);
    gl.uniform1f(uniforms.uDepthScale, P.depthScale);
    gl.uniform1f(uniforms.uFocus, P.focus);

    gl.drawArrays(gl.TRIANGLES, 0, 3);
    return { w, h };
  }

  function frame(now) {
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    fps += ((1 / Math.max(dt, 1e-4)) - fps) * 0.05;

    if (color) {
      updateTarget(now / 1000);
      // Frame-rate independent approach, so damping means the same thing at
      // 60 and 120 Hz.
      const k = 1 - Math.pow(1 - P.damping, dt * 60);
      view[0] += (target[0] - view[0]) * k;
      view[1] += (target[1] - view[1]) * k;
    }

    const { w, h } = draw();
    if (!debugEl.hidden && color) readout(fps, w, h);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  buildUI(gl);
  wireDrop(gl);

  // Debug / scripting handle. `poke` renders synchronously at an explicit view
  // offset, bypassing input and damping — handy for driving the effect from a
  // timeline later, and the only way to verify it where rAF is throttled.
  window.J3D = {
    params: P,
    view,
    draw,
    poke(x, y) {
      view[0] = target[0] = x;
      view[1] = target[1] = y;
      return draw();
    },
    get mode() { return mode; },
    set mode(m) { mode = m; },

    // Magnify a point on the plate. cx/cy are uv (y counts up), z < 1 zooms in.
    // inspect(null) clears it.
    inspect(cx, cy, z = 0.25) {
      inspect = cx === null ? null : { cx, cy, z };
      return draw();
    },
  };
}

// --------------------------------------------------------------------- ui

const readoutEl = document.getElementById('readout');

function readout(fps, w, h) {
  readoutEl.textContent =
    `${w}x${h}  ${fps.toFixed(0)} fps\n` +
    `plate ${color.width}x${color.height}\n` +
    `mode  ${P.mode}${P.mode === 'layers' && (!bg || !sprite) ? ' (unavailable)' : ''}\n` +
    `depth ${depth.width}x${depth.height}${placeholder ? '  (placeholder)' : ''}\n` +
    `view  ${view[0].toFixed(3)}, ${view[1].toFixed(3)}`;
}

function buildUI(gl) {
  const host = document.getElementById('sliders');

  for (const s of schema) {
    const row = document.createElement('div');
    row.className = 'row';

    if (s.options) {
      row.innerHTML = `<label for="p-${s.key}">${s.label}</label>` +
        `<select id="p-${s.key}" style="flex:1">` +
        s.options.map((o) => `<option value="${o}">${o}</option>`).join('') +
        `</select>`;
      const sel = row.querySelector('select');
      const syncSel = () => { sel.value = P[s.key]; };
      sel.addEventListener('change', () => { P[s.key] = sel.value; });
      syncSel();
      s.sync = syncSel;
      host.appendChild(row);
      continue;
    }

    row.innerHTML =
      `<label for="p-${s.key}">${s.label}</label>` +
      `<input id="p-${s.key}" type="range" min="${s.min}" max="${s.max}" step="${s.step}">` +
      `<output></output>`;
    const input = row.querySelector('input');
    const out = row.querySelector('output');
    const sync = () => {
      input.value = P[s.key];
      out.textContent = s.step >= 1 ? P[s.key] : Number(P[s.key]).toFixed(3);
    };
    input.addEventListener('input', () => {
      P[s.key] = parseFloat(input.value);
      if (s.key === 'stageHeight') sizeStage();
      sync();
    });
    sync();
    s.sync = sync;
    host.appendChild(row);
  }

  const modeSel = document.getElementById('motionMode');
  modeSel.value = mode;
  modeSel.addEventListener('change', () => { mode = modeSel.value; });

  document.getElementById('reset').addEventListener('click', () => {
    Object.assign(P, defaults);
    schema.forEach((s) => s.sync());
    sizeStage();
    toast('reset to config.js');
  });

  document.getElementById('copy').addEventListener('click', async () => {
    const body = schema
      .map((s) => {
        const v = s.options ? `'${P[s.key]}'`
                : s.step >= 1 ? P[s.key]
                : Number(P[s.key]).toFixed(3);
        return `  ${s.key}: ${v},`;
      })
      .join('\n');
    const text = `export const params = {\n${body}\n};`;
    try {
      await navigator.clipboard.writeText(text);
      toast('config copied — paste over params in js/config.js');
    } catch {
      readoutEl.textContent = text;   // clipboard blocked; show it instead
    }
  });

  document.getElementById('grab').addEventListener('click', () => {
    canvas.toBlob((blob) => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `jordan3d-${Date.now()}.png`;
      a.click();
      URL.revokeObjectURL(a.href);
    }, 'image/png');
  });

  const toggle = (on) => {
    debugEl.hidden = !on;
    hud.hidden = on;
  };
  document.getElementById('close').addEventListener('click', () => toggle(false));

  addEventListener('keydown', (e) => {
    if (e.key === 'd') toggle(debugEl.hidden);
    if (e.key === 'Escape') toggle(false);
    if (e.key === 'r') { Object.assign(P, defaults); schema.forEach((s) => s.sync()); sizeStage(); }
  });
}

function wireDrop(gl) {
  const stop = (e) => { e.preventDefault(); e.stopPropagation(); };

  addEventListener('dragover', (e) => { stop(e); document.body.classList.add('dragging'); });
  addEventListener('dragleave', (e) => { stop(e); document.body.classList.remove('dragging'); });

  addEventListener('drop', async (e) => {
    stop(e);
    document.body.classList.remove('dragging');

    for (const file of e.dataTransfer.files) {
      if (!file.type.startsWith('image/')) continue;
      const url = URL.createObjectURL(file);
      try {
        const img = await loadImage(url);
        // Filename is the only signal we have for which slot a drop belongs to.
        if (/depth|disp|dmap/i.test(file.name)) {
          setDepth(gl, img);
          toast(`depth: ${file.name}`);
        } else {
          setColor(gl, img);
          toast(`plate: ${file.name}`);
        }
      } catch (err) {
        toast(err.message);
      } finally {
        URL.revokeObjectURL(url);
      }
    }
  });
}

main();
