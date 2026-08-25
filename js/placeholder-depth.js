// A stand-in depth map derived from luminance, so the pipeline can be checked
// before a real map exists. It is NOT depth — bright regions simply read as
// near. Useful for confirming motion, damping and crop; useless for judging
// the actual 3D read of a photograph. Replace it with a real map.

export function placeholderDepth(img, maxSize = 512) {
  const s = Math.min(1, maxSize / Math.max(img.width, img.height));
  const w = Math.max(1, Math.round(img.width * s));
  const h = Math.max(1, Math.round(img.height * s));

  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const ctx = c.getContext('2d');

  // Heavy blur keeps it from behaving like an embossing filter on texture
  // detail; the low resolution above does most of that work already.
  ctx.filter = `grayscale(1) blur(${Math.max(2, Math.round(w / 90))}px) contrast(1.15)`;
  ctx.drawImage(img, 0, 0, w, h);
  return c;
}
