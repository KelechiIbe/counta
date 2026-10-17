// Pictures taken on phones are often 4 to 12 MB, and the photo bucket takes up to 5 MB. Before upload, a picture is
// redrawn at most `maxSide` pixels on its long side, which keeps it well under the limit and makes the shop and the
// documents load quickly. PNG and WebP keep their transparency (logos); everything else becomes a JPEG.
const MAX_BYTES = 5 * 1024 * 1024;

async function decode(f: File): Promise<{ img: CanvasImageSource; w: number; h: number; done: () => void }> {
  if ('createImageBitmap' in window) {
    try {
      const b = await createImageBitmap(f);
      return { img: b, w: b.width, h: b.height, done: () => b.close() };
    } catch { /* fall back to an <img> */ }
  }
  const url = URL.createObjectURL(f);
  try {
    const el = await new Promise<HTMLImageElement>((resolve, reject) => {
      const i = new Image();
      i.onload = () => resolve(i);
      i.onerror = () => reject(new Error('This picture could not be read. Choose a JPG or PNG.'));
      i.src = url;
    });
    return { img: el, w: el.naturalWidth, h: el.naturalHeight, done: () => URL.revokeObjectURL(url) };
  } catch (e) { URL.revokeObjectURL(url); throw e; }
}

export async function shrinkImage(f: File, maxSide = 1600, quality = 0.85): Promise<{ blob: Blob; type: string; ext: string }> {
  const clear = /^image\/(png|webp)$/.test(f.type);
  const extOf = (t: string) => (t === 'image/png' ? 'png' : t === 'image/webp' ? 'webp' : 'jpg');
  // Small, ordinary pictures go as they are.
  if (f.size <= 600 * 1024 && /^image\/(jpeg|png|webp)$/.test(f.type)) return { blob: f, type: f.type, ext: extOf(f.type) };
  let d: Awaited<ReturnType<typeof decode>>;
  try { d = await decode(f); }
  catch (e) {
    if (f.size <= MAX_BYTES && /^image\/(jpeg|png|webp)$/.test(f.type)) return { blob: f, type: f.type, ext: extOf(f.type) };
    throw e;
  }
  try {
    const scale = Math.min(1, maxSide / Math.max(d.w, d.h, 1));
    const w = Math.max(1, Math.round(d.w * scale)), h = Math.max(1, Math.round(d.h * scale));
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const ctx = c.getContext('2d');
    if (!ctx) throw new Error('This browser cannot prepare the picture. Try another browser.');
    const type = clear ? 'image/png' : 'image/jpeg';
    if (!clear) { ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, w, h); }
    ctx.drawImage(d.img, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((resolve) => c.toBlob(resolve, type, quality));
    if (!blob) throw new Error('This picture could not be prepared. Choose a JPG or PNG.');
    if (blob.size > MAX_BYTES) throw new Error('This picture is too large even after resizing. Choose a smaller one.');
    return { blob, type, ext: extOf(type) };
  } finally { d.done(); }
}
