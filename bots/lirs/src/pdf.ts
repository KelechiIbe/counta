// Files for e-Tax: what a file is from its first bytes, and several files made into one PDF where e-Tax's form has a
// single file field for them.
import { PDFDocument } from 'pdf-lib';

export type Kind = 'pdf' | 'jpeg' | 'png' | 'other';
export function kindOf(b: Buffer): Kind {
  if (b.length > 4 && b.subarray(0, 5).toString('latin1') === '%PDF-') return 'pdf';
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpeg';
  if (b.length > 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  return 'other';
}
export const typeOf = (k: Kind) => (k === 'pdf' ? 'application/pdf' : k === 'jpeg' ? 'image/jpeg' : k === 'png' ? 'image/png' : 'application/octet-stream');
export const extOf = (k: Kind) => (k === 'jpeg' ? 'jpg' : k);

const A4 = { w: 595.28, h: 841.89 };

// One PDF from PDFs and pictures, in the order given. Pictures are fitted on A4 pages with a margin.
export async function mergeToPdf(files: Buffer[]): Promise<Buffer> {
  const out = await PDFDocument.create();
  for (const b of files) {
    const k = kindOf(b);
    if (k === 'pdf') {
      const src = await PDFDocument.load(b, { ignoreEncryption: true });
      const pages = await out.copyPages(src, src.getPageIndices());
      pages.forEach((p) => out.addPage(p));
    } else if (k === 'jpeg' || k === 'png') {
      const img = k === 'jpeg' ? await out.embedJpg(b) : await out.embedPng(b);
      const page = out.addPage([A4.w, A4.h]);
      const m = 28, s = Math.min((A4.w - 2 * m) / img.width, (A4.h - 2 * m) / img.height, 1);
      const w = img.width * s, h = img.height * s;
      page.drawImage(img, { x: (A4.w - w) / 2, y: (A4.h - h) / 2, width: w, height: h });
    } else {
      throw new Error('a file is neither a PDF nor a JPEG or PNG picture');
    }
  }
  return Buffer.from(await out.save());
}
