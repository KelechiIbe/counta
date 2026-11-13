// The engagement letter as a PDF (what the partner signs), and the pages added when the client signs: a signature page
// and a completion certificate. pdf-lib's standard fonts (Helvetica) only hold the Windows Latin characters, so every piece
// of text goes through pdfSafe first: the naira sign becomes NGN, accented letters (Yoruba and Igbo names among them) lose
// their accents, and anything else the fonts cannot draw becomes "?" instead of failing the letter. Nothing here names
// Counta: a full-mandate client sees only the firm.
import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';
import type { RenderedBlock } from '../_shared/letter.ts';
import { PNG_MAX_HEIGHT, PNG_MAX_WIDTH, pngSize } from './util.ts';

const PAGE_W = 595.28, PAGE_H = 841.89; // A4
const MARGIN = 50;
const INK = rgb(0.1, 0.12, 0.15);
const MUTED = rgb(0.4, 0.43, 0.47);
const RULE = rgb(0.75, 0.78, 0.8);

// ------------------------------------------------------------------ text the standard fonts can draw
// Windows Latin (WinAnsi) beyond ASCII: 0xA0 to 0xFF, and these from 0x80 to 0x9F.
const WIN_ANSI_EXTRA = new Set(Array.from('€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ'));
const winAnsi = (ch: string) => {
  const c = ch.codePointAt(0)!;
  return (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) || WIN_ANSI_EXTRA.has(ch);
};
// Letters that no accent can be taken off.
const LETTER_MAP: Record<string, string> = {
  'Ł': 'L', 'ł': 'l', 'Đ': 'D', 'đ': 'd', 'Ð': 'D', 'ð': 'd', 'Ø': 'O', 'ø': 'o', 'Æ': 'AE', 'æ': 'ae', 'Œ': 'OE', 'œ': 'oe', 'ß': 'ss',
  'Þ': 'Th', 'þ': 'th', 'ı': 'i', 'Ħ': 'H', 'ħ': 'h', 'Ŧ': 'T', 'ŧ': 't', 'Ŋ': 'N', 'ŋ': 'n', 'Ɛ': 'E', 'ɛ': 'e', 'Ɔ': 'O', 'ɔ': 'o',
};
const MARK = /\p{M}/gu;

// Text as the PDF draws it: the naira sign as "NGN ", curly quotes straight, dashes as "-", "…" as "...", letters
// outside ASCII without their accents (decomposed, the combining marks dropped: "Ọlá" is "Ola"), and anything left
// that the fonts cannot draw as "?". Line breaks stay; tabs and unusual spaces are spaces; invisible characters go.
export function pdfSafe(s: string): string {
  const t = String(s ?? '')
    .replace(/₦\s*/g, 'NGN ')
    .replace(/[‘’‚‛′]/g, "'")
    .replace(/[“”„‟″«»]/g, '"')
    .replace(/[‐‑‒–—―−]/g, '-')
    .replace(/…/g, '...')
    .replace(/\r\n?/g, '\n')
    .replace(/[\t   -   　]/g, ' ');
  let out = '';
  for (const ch of t) {
    const c = ch.codePointAt(0)!;
    if ((c >= 0x20 && c <= 0x7e) || ch === '\n') { out += ch; continue; }
    if (/\p{M}|\p{C}/u.test(ch)) continue; // combining marks, controls, zero-width and soft hyphens
    if (/\p{L}/u.test(ch)) {
      const folded = Array.from(ch.normalize('NFD').replace(MARK, ''), (x) => LETTER_MAP[x] ?? x).join('');
      for (const f of folded) {
        if (winAnsi(f)) { out += f; continue; }
        const compat = f.normalize('NFKD').replace(MARK, ''); // ligatures and full-width letters
        out += Array.from(compat).every(winAnsi) && compat ? compat : '?';
      }
      continue;
    }
    out += winAnsi(ch) ? ch : '?';
  }
  return out;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// A moment as the certificate shows it, in Lagos time (UTC+1 all year): "13 Nov 2026, 11:05 (Africa/Lagos)".
export function lagosTime(v: string | Date | null | undefined): string {
  if (v === null || v === undefined || v === '') return '';
  const t = v instanceof Date ? v.getTime() : Date.parse(String(v));
  if (Number.isNaN(t)) return '';
  const d = new Date(t + 3600_000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${p(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${p(d.getUTCHours())}:${p(d.getUTCMinutes())} (Africa/Lagos)`;
}

// Text broken into lines that fit the width (explicit line breaks kept; a word wider than the line is cut).
function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const out: string[] = [];
  for (const para of text.split('\n')) {
    const words = para.split(' ').filter((w) => w !== '');
    if (!words.length) { out.push(''); continue; }
    let line = '';
    for (let w of words) {
      while (font.widthOfTextAtSize(w, size) > width) {
        let n = w.length - 1;
        while (n > 1 && font.widthOfTextAtSize(w.slice(0, n), size) > width) n--;
        if (line) { out.push(line); line = ''; }
        out.push(w.slice(0, n));
        w = w.slice(n);
      }
      if (!w) continue;
      const next = line ? `${line} ${w}` : w;
      if (font.widthOfTextAtSize(next, size) <= width) line = next;
      else { out.push(line); line = w; }
    }
    if (line) out.push(line);
  }
  return out;
}

type Fonts = { regular: PDFFont; bold: PDFFont; italic: PDFFont };

// Writes down the pages, starting a new A4 page when the next lines do not fit.
class Writer {
  page!: PDFPage;
  y = 0;
  constructor(private doc: PDFDocument, readonly f: Fonts) { this.newPage(); }
  newPage() {
    this.page = this.doc.addPage([PAGE_W, PAGE_H]);
    this.y = PAGE_H - MARGIN;
  }
  ensure(h: number) {
    if (this.y - h < MARGIN) this.newPage();
  }
  // Lines of text at x (with a label, such as "1.1", at labelX on the first line); keep: lines kept together.
  text(text: string, o: { x?: number; label?: string | null; labelX?: number; font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>;
    gap?: number; keep?: number; width?: number } = {}) {
    const x = o.x ?? MARGIN, font = o.font ?? this.f.regular, size = o.size ?? 10, lh = size * 1.45;
    const lines = wrap(pdfSafe(text), font, size, o.width ?? PAGE_W - MARGIN - x);
    this.y -= o.gap ?? 0;
    this.ensure(lh * Math.max(1, Math.min(lines.length, o.keep ?? 1)));
    lines.forEach((l, i) => {
      this.ensure(lh);
      this.y -= lh;
      if (i === 0 && o.label) this.page.drawText(pdfSafe(o.label), { x: o.labelX ?? MARGIN, y: this.y, font, size, color: o.color ?? INK });
      if (l) this.page.drawText(l, { x, y: this.y, font, size, color: o.color ?? INK });
    });
  }
  rule(x1: number, x2: number) {
    this.page.drawLine({ start: { x: x1, y: this.y }, end: { x: x2, y: this.y }, thickness: 0.6, color: RULE });
  }
}

async function fonts(doc: PDFDocument): Promise<Fonts> {
  return { regular: await doc.embedFont(StandardFonts.Helvetica), bold: await doc.embedFont(StandardFonts.HelveticaBold),
    italic: await doc.embedFont(StandardFonts.HelveticaOblique) };
}

// A footer at the foot of a page: text on the left (cut to fit), and on the right.
function footer(page: PDFPage, f: Fonts, left: string, right: string) {
  const size = 8, rightText = pdfSafe(right);
  const rw = f.regular.widthOfTextAtSize(rightText, size);
  const max = PAGE_W - 2 * MARGIN - rw - 20;
  let l = pdfSafe(left).replace(/\n/g, ' ');
  if (f.regular.widthOfTextAtSize(l, size) > max) {
    while (l && f.regular.widthOfTextAtSize(l + '...', size) > max) l = l.slice(0, -1);
    l += '...';
  }
  page.drawText(l, { x: MARGIN, y: 28, font: f.regular, size, color: MUTED });
  page.drawText(rightText, { x: PAGE_W - MARGIN - rw, y: 28, font: f.regular, size, color: MUTED });
}

const INDENT = [0, 0, 30, 55, 80]; // by level

// The letter as the partner signs it: A4, 50 pt margins, the firm's name at the head of the first page, numbered blocks
// with hanging numbers, the firm's typed signature in its signature block, and "Page n of m" on every page.
export async function renderLetterPdf(blocks: RenderedBlock[],
  meta: { title: string; firmName: string; partnerName: string; partnerTitle: string; partnerSignature?: string }): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.setTitle(meta.title);
  doc.setAuthor(meta.firmName);
  doc.setCreator(meta.firmName);
  doc.setProducer(meta.firmName);
  const f = await fonts(doc);
  const w = new Writer(doc, f);

  w.text(meta.firmName, { font: f.bold, size: 14 });
  w.y -= 8;
  w.rule(MARGIN, PAGE_W - MARGIN);
  w.y -= 6;

  for (const b of blocks) {
    const level = Math.min(Math.max(Math.round(Number(b.level) || 1), 1), 4);
    switch (b.kind) {
      case 'heading':
        w.text(b.text, { label: b.number, labelX: MARGIN, x: MARGIN + 30, font: f.bold, size: 11, gap: 12, keep: 3 });
        break;
      case 'clause':
        w.text(b.text, { label: b.number, labelX: MARGIN, x: MARGIN + 30, gap: 6, keep: 2 });
        break;
      case 'list': {
        const at = level >= 4 ? 55 : 30;
        w.text(b.text, { label: b.number, labelX: MARGIN + at, x: MARGIN + at + 25, gap: 4, keep: 2 });
        break;
      }
      case 'signature':
        w.y -= 12;
        w.ensure(70);
        if (b.text === 'firm') {
          w.y -= 24;
          if (meta.partnerSignature) w.page.drawText(pdfSafe(meta.partnerSignature), { x: MARGIN, y: w.y, font: f.italic, size: 18, color: INK });
          w.y -= 6;
          w.rule(MARGIN, MARGIN + 220);
          w.text(`Signed electronically for ${meta.firmName} by ${meta.partnerName}, ${meta.partnerTitle}`, { size: 8.5, color: MUTED, width: 300 });
        } else {
          w.y -= 30;
          w.rule(MARGIN, MARGIN + 220);
          w.text('For the client', { size: 8.5, color: MUTED });
        }
        break;
      default:
        w.text(b.text, { x: MARGIN + INDENT[level], gap: 6, keep: 2 });
    }
  }

  const pages = doc.getPages();
  pages.forEach((p, i) => footer(p, f, meta.title, `Page ${i + 1} of ${pages.length}`));
  return await doc.save();
}

export type Completion = {
  title: string;
  originalSha256: string;
  firm: { name: string; partnerName: string; partnerEmail: string; signedAt: string | Date; ip: string | null; ua: string | null };
  client: { name: string; email: string; title: string | null; signedAt: string | Date; ip: string | null; ua: string | null; typedName: string;
    signaturePng: Uint8Array };
};

// The image data of a PNG (its IDAT chunks, joined), or null when the chunks do not add up.
function pngData(png: Uint8Array): Uint8Array | null {
  const v = new DataView(png.buffer, png.byteOffset, png.byteLength);
  const parts: Uint8Array[] = [];
  for (let at = 8; at + 12 <= png.length;) {
    const len = v.getUint32(at), type = String.fromCharCode(png[at + 4], png[at + 5], png[at + 6], png[at + 7]);
    if (at + 12 + len > png.length) return null;
    if (type === 'IDAT') parts.push(png.subarray(at + 8, at + 8 + len));
    if (type === 'IEND') break;
    at += 12 + len;
  }
  if (!parts.length) return null;
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// Whether the zlib data inflates to at most max bytes (stopped as soon as it goes past).
async function inflatesWithin(data: Uint8Array, max: number): Promise<boolean> {
  const ds = new DecompressionStream('deflate');
  const w = ds.writable.getWriter();
  w.write(new Uint8Array(data)).catch(() => null);
  w.close().catch(() => null);
  const r = ds.readable.getReader();
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await r.read();
      if (done) return true;
      total += value.length;
      if (total > max) {
        await r.cancel().catch(() => null);
        return false;
      }
    }
  } catch {
    return false;
  }
}

// Whether a signature PNG can be drawn into a PDF (checked before the signer's code is used up): at most 2000 x 1000
// pixels by its header, image data that inflates to no more than such an image can hold (16-bit RGBA, every row's
// filter byte and Adam7's extra rows allowed for), so a small file that inflates to a huge one is refused before it is
// decoded; then drawn once.
export async function pngDrawable(png: Uint8Array): Promise<boolean> {
  const size = pngSize(png);
  if (!size || size.width < 1 || size.height < 1 || size.width > PNG_MAX_WIDTH || size.height > PNG_MAX_HEIGHT) return false;
  const data = pngData(png);
  if (!data || !(await inflatesWithin(data, size.height * (size.width * 8 + 8) + 1024))) return false;
  try {
    await (await PDFDocument.create()).embedPng(png);
    return true;
  } catch {
    return false;
  }
}

// Label and value rows, the value wrapped beside the label.
function rows(w: Writer, items: [string, string][]) {
  for (const [label, value] of items) {
    w.text(value || '-', { label, labelX: MARGIN + 10, x: MARGIN + 130, size: 9.5, gap: 3, keep: 1 });
  }
}

// The signed letter: the letter as the firm signed it, then a signature page (the firm's signature and the client's drawn
// signature with their typed name) and a completion certificate (both parties' names, emails, times in Lagos, IP
// addresses and browsers, the client's email verified by a one-time code, and the SHA-256 of the letter as the firm
// signed it).
export async function appendCompletion(pdf: Uint8Array, c: Completion): Promise<Uint8Array> {
  const doc = await PDFDocument.load(pdf, { updateMetadata: false });
  const f = await fonts(doc);
  const sig = await doc.embedPng(c.client.signaturePng);
  const clip = (s: string | null | undefined, n: number) => String(s ?? '').slice(0, n);

  // Signature page
  const w = new Writer(doc, f);
  w.text('Signature page', { font: f.bold, size: 14 });
  w.text(c.title, { size: 10, color: MUTED, gap: 4 });
  w.y -= 10;
  w.rule(MARGIN, PAGE_W - MARGIN);

  w.text(`For ${c.firm.name}`, { font: f.bold, size: 11, gap: 18 });
  w.text(`Signed electronically by ${clip(c.firm.partnerName, 120)} on ${lagosTime(c.firm.signedAt)}.`, { gap: 6 });

  w.text(`For the client`, { font: f.bold, size: 11, gap: 24 });
  const scale = Math.min(220 / sig.width, 80 / sig.height);
  const sw = sig.width * scale, sh = sig.height * scale;
  w.y -= 10;
  w.ensure(sh + 50);
  w.y -= sh;
  w.page.drawImage(sig, { x: MARGIN, y: w.y, width: sw, height: sh });
  w.y -= 6;
  w.rule(MARGIN, MARGIN + 220);
  w.text(clip(c.client.typedName, 120), { font: f.bold });
  if (c.client.title) w.text(clip(c.client.title, 80), { color: MUTED });
  w.text(`Signed electronically by ${clip(c.client.name, 120)} on ${lagosTime(c.client.signedAt)}.`, { gap: 6 });
  footer(w.page, f, c.title, 'Signature page');

  // Completion certificate
  const v = new Writer(doc, f);
  v.text('Completion certificate', { font: f.bold, size: 14 });
  v.text(c.title, { size: 10, color: MUTED, gap: 4 });
  v.y -= 10;
  v.rule(MARGIN, PAGE_W - MARGIN);
  v.text(`Original document SHA-256: ${c.originalSha256}`, { size: 9.5, gap: 14 });
  v.text('The SHA-256 fingerprint of the letter as the firm signed it, before this certificate and the signature page were added. '
    + 'It was checked against the stored letter before the client signed.', { size: 8.5, color: MUTED, gap: 4 });

  v.text('The firm', { font: f.bold, size: 11, gap: 18 });
  rows(v, [
    ['Firm', clip(c.firm.name, 160)],
    ['Signed by', clip(c.firm.partnerName, 120)],
    ['Email', clip(c.firm.partnerEmail, 254)],
    ['Signed on', lagosTime(c.firm.signedAt)],
    ['IP address', clip(c.firm.ip, 64)],
    ['Browser', clip(c.firm.ua, 300)],
  ]);

  v.text('The client', { font: f.bold, size: 11, gap: 18 });
  rows(v, [
    ['Signed by', clip(c.client.name, 120) + (c.client.title ? `, ${clip(c.client.title, 80)}` : '')],
    ['Typed name', clip(c.client.typedName, 120)],
    ['Email', clip(c.client.email, 254)],
    ['Verification', 'Email verified by a one-time code'],
    ['Signed on', lagosTime(c.client.signedAt)],
    ['IP address', clip(c.client.ip, 64)],
    ['Browser', clip(c.client.ua, 300)],
  ]);
  footer(v.page, f, c.title, 'Completion certificate');

  return await doc.save();
}
