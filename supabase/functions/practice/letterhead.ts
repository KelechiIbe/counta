// The firm's letterhead files, read from storage and checked before they go into a letter: each must be the very file the
// practice saved (its SHA-256), of the kind and size it claims, and small enough to draw. Anything wrong is answered in
// words a partner can act on; nothing is drawn from a file that failed a check.
import { PDFDocument } from 'npm:pdf-lib@1.17.1';
import { type Letterhead, type LetterheadFile, type LetterheadFiles, pngInflatesSafely } from './pdf.ts';
import { pngSize, sha256Hex, UserError } from './util.ts';

const MB = 1048576;
type Role = 'first' | 'next' | 'logo';
const WHAT: Record<Role, string> = { first: 'the letterhead page', next: 'the page for the following pages', logo: 'the logo' };

// A JPEG's width and height from its first frame header (SOF0 to SOF15, not DHT, JPG or DAC), or null.
export function jpegSize(b: Uint8Array): { width: number; height: number } | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) return null;
    const m = b[i + 1];
    if (m === 0xff) { i += 1; continue; }
    if (m === 0x01 || (m >= 0xd0 && m <= 0xd8)) { i += 2; continue; }
    const len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return null;
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
      return { height: (b[i + 5] << 8) | b[i + 6], width: (b[i + 7] << 8) | b[i + 8] };
    }
    i += 2 + len;
  }
  return null;
}

const refuse = (role: Role, why: string) =>
  new UserError(`The letter could not be printed on the firm's letterhead: ${WHAT[role]} ${why}. A partner can upload it again under Practice, Letterhead.`);

// Checks one file's bytes against what the practice saved; throws a UserError saying what is wrong.
export async function checkLetterheadFile(f: LetterheadFile, role: Role, bytes: Uint8Array): Promise<void> {
  if (bytes.length > (role === 'logo' ? 2 : 5) * MB) throw refuse(role, `is larger than ${role === 'logo' ? 2 : 5} MB`);
  if ((await sha256Hex(bytes)) !== String(f.sha256).toLowerCase()) throw refuse(role, 'is not the file that was saved');
  const pageBounds = (w: number, h: number) => w >= 1000 && w <= 2600 && h >= 1300 && h <= 3700;
  if (f.kind === 'pdf') {
    if (role === 'logo' || new TextDecoder().decode(bytes.slice(0, 5)) !== '%PDF-') throw refuse(role, 'is not a PDF');
    let doc: PDFDocument;
    try { doc = await PDFDocument.load(bytes, { updateMetadata: false }); }
    catch { throw refuse(role, 'could not be opened (it may be protected by a password)'); }
    if (!doc.getPageCount()) throw refuse(role, 'has no pages');
    const { width, height } = doc.getPage(0).getSize();
    if (width < 400 || width > 700 || height < 500 || height > 1000 || height <= width) throw refuse(role, 'is not an upright A4 or US Letter page');
    if (Math.abs(width - f.w) > 3 || Math.abs(height - f.h) > 3) throw refuse(role, 'is not the size that was saved');
    return;
  }
  const size = f.kind === 'png' ? pngSize(bytes) : jpegSize(bytes);
  if (!size) throw refuse(role, `is not a ${f.kind === 'png' ? 'PNG' : 'JPG'} picture`);
  const ok = role === 'logo' ? size.width >= 16 && size.width <= 1200 && size.height >= 16 && size.height <= 1200 : pageBounds(size.width, size.height);
  if (!ok) throw refuse(role, 'is not a size Counta can print');
  if (f.kind === 'png' && !(await pngInflatesSafely(bytes))) throw refuse(role, 'could not be read');
}

// The bytes of every file the letterhead uses, each checked. read answers the stored file, or null when it is not there.
export async function letterheadFiles(lh: Letterhead | null | undefined, read: (path: string) => Promise<Uint8Array | null>): Promise<LetterheadFiles> {
  const out: LetterheadFiles = {};
  if (!lh) return out;
  const take = async (role: Role, f: LetterheadFile | null | undefined) => {
    if (!f) return;
    const bytes = await read(f.path);
    if (!bytes) throw refuse(role, 'was not found');
    await checkLetterheadFile(f, role, bytes);
    out[role] = bytes;
  };
  if (lh.mode === 'upload') {
    if (!lh.first) throw refuse('first', 'is missing');
    await take('first', lh.first);
    if (lh.next_mode === 'upload') await take('next', lh.next);
  } else {
    await take('logo', lh.logo);
  }
  return out;
}
