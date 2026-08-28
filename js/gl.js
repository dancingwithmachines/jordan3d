// Thin WebGL2 helpers. No dependencies, no build step.

export function initGL(canvas) {
  const gl = canvas.getContext('webgl2', {
    antialias: false,          // we render one full-screen quad; MSAA buys nothing
    alpha: false,
    depth: false,
    stencil: false,
    powerPreference: 'high-performance',
    preserveDrawingBuffer: true, // so "save png" can read the canvas back
  });
  if (!gl) throw new Error('WebGL2 is unavailable in this browser.');
  return gl;
}

function compile(gl, type, src, label) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(`${label} failed to compile:\n${gl.getShaderInfoLog(sh)}`);
  }
  return sh;
}

export async function loadProgram(gl, vertUrl, fragUrl) {
  const [vertSrc, fragSrc] = await Promise.all(
    [vertUrl, fragUrl].map(async (u) => {
      const res = await fetch(u);
      if (!res.ok) throw new Error(`${u}: ${res.status} ${res.statusText}`);
      return res.text();
    })
  );

  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, vertSrc, vertUrl));
  gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, fragSrc, fragUrl));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    throw new Error(`link failed:\n${gl.getProgramInfoLog(prog)}`);
  }

  // Cache every uniform location up front so the draw loop stays allocation-free.
  const uniforms = {};
  const count = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < count; i++) {
    const { name } = gl.getActiveUniform(prog, i);
    uniforms[name] = gl.getUniformLocation(prog, name);
  }
  return { prog, uniforms };
}

export function createQuad(gl, prog) {
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'aPos');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  gl.bindVertexArray(null);
  return vao;
}

export function createTexture(gl, source) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
  // CLAMP_TO_EDGE matters: displacement can push a sample just past the plate,
  // and clamping smears the border pixel instead of wrapping the far side in.
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  return { tex, width: source.width, height: source.height };
}

// Loading with ?fresh on the page URL appends a cache-buster. Browsers hold on
// to a regenerated depth map hard, and measuring a stale one sends you chasing
// bugs that are already fixed.
export function loadImage(url) {
  const fresh = typeof location !== 'undefined'
    && new URLSearchParams(location.search).has('fresh');
  const src = fresh ? `${url}${url.includes('?') ? '&' : '?'}cb=${Date.now()}` : url;
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`could not load ${url}`));
    img.src = src;
  });
}

// Sizes the drawing buffer to the element's real pixel footprint. Capped at
// 2x DPR — beyond that we are paying for pixels nobody can see.
export function fitCanvas(gl, canvas, maxDpr = 2) {
  const dpr = Math.min(window.devicePixelRatio || 1, maxDpr);
  const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  gl.viewport(0, 0, canvas.width, canvas.height);
  return { w: canvas.width, h: canvas.height };
}

// Returns the uv rect of the image to sample, then zooms in by `crop`.
//
//   cover   — fill the canvas, cropping the overhanging axis. Scale <= 1, so
//             every sample lands on the plate.
//   contain — show the whole image, leaving slack beside it. Scale > 1 on the
//             slack axis, so uv runs outside 0..1 there and the shader paints
//             background instead.
export function fitUv(canvasW, canvasH, imgW, imgH, crop = 1, fit = 'cover') {
  const ca = canvasW / canvasH;
  const ia = imgW / imgH;

  let su, sv;
  if (fit === 'contain') {
    su = ca > ia ? ca / ia : 1;
    sv = ca > ia ? 1 : ia / ca;
  } else {
    su = ca < ia ? ca / ia : 1;
    sv = ca < ia ? 1 : ia / ca;
  }
  return { scale: [su / crop, sv / crop], offset: [0, 0] };
}
