// Pictures and pages for the tests (never deployed): a PNG of any size, a JPEG header of any size, and a blank letterhead
// page as a PDF, made here so no file is checked in.
import { zlibSync } from 'npm:fflate@0.8.3';
import { PDFDocument, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(b: Uint8Array) {
  let c = 0xffffffff;
  for (const x of b) c = CRC[(c ^ x) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Uint8Array) {
  const out = new Uint8Array(12 + data.length);
  const v = new DataView(out.buffer);
  v.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  v.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

// An RGB PNG of w x h, white with a coloured band across the top (a header), or a solid colour.
export function makePng(w: number, h: number, colour: [number, number, number] = [11, 59, 117]): Uint8Array {
  const ihdr = new Uint8Array(13);
  const v = new DataView(ihdr.buffer);
  v.setUint32(0, w); v.setUint32(4, h);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const raw = new Uint8Array(h * (1 + w * 3));
  for (let y = 0; y < h; y++) {
    const band = y < Math.max(1, Math.round(h * 0.08)) || y > h - Math.max(1, Math.round(h * 0.04));
    for (let x = 0; x < w; x++) {
      const o = y * (1 + w * 3) + 1 + x * 3;
      const [r, g, b] = band ? colour : [255, 255, 255];
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  const sig = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const parts = [sig, chunk('IHDR', ihdr), chunk('IDAT', zlibSync(raw)), chunk('IEND', new Uint8Array())];
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// The start of a JPEG whose frame header says w x h (enough for the size check; not a picture anyone can draw).
export function jpegHeader(w: number, h: number): Uint8Array {
  return new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 0xff, w >> 8, w & 0xff, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xd9]);
}

// A blank letterhead page as a firm would save it from Word: its name across the top, a footer line, nothing else.
export async function letterheadPdf(size: [number, number] = [595.28, 841.89], name = 'HEAD PARTNERS'): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const f = await doc.embedFont(StandardFonts.HelveticaBold);
  const p = doc.addPage(size);
  p.drawRectangle({ x: 0, y: size[1] - 110, width: size[0], height: 110, color: rgb(0.04, 0.23, 0.46) });
  p.drawText(name, { x: 56, y: size[1] - 70, font: f, size: 24, color: rgb(1, 1, 1) });
  p.drawRectangle({ x: 0, y: 0, width: size[0], height: 60, color: rgb(0.9, 0.92, 0.95) });
  p.drawText('3 Test Avenue, Ikoyi, Lagos   |   office@head.example.test', { x: 56, y: 26, font: f, size: 9, color: rgb(0.2, 0.2, 0.2) });
  return await doc.save();
}
