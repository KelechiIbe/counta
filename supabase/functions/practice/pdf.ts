// The engagement letter as a PDF (what the partner signs), and the pages added when the client signs: a signature page
// and a completion certificate. pdf-lib's standard fonts (Helvetica, or Times when the firm chose it) only hold the Windows
// Latin characters, so every piece of text goes through pdfSafe first: the naira sign becomes NGN, accented letters
// (Yoruba and Igbo names among them) lose their accents, and anything else the fonts cannot draw becomes "?" instead of
// failing the letter. Nothing here names Counta: a full-mandate client sees only the firm.
//
// The letter carries the firm's letterhead when it has one (practices.letterhead): its own blank page laid under every page
// (or a second page under the following ones), with the space it keeps clear; or a header built from its logo, name and
// details, in its colour, with a footer line. Without one, the firm's name heads the first page.
import { degrees, PDFDocument, type PDFEmbeddedPage, type PDFFont, PDFImage, type PDFPage, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';
import type { RenderedBlock } from '../_shared/letter.ts';
import { PNG_MAX_HEIGHT, PNG_MAX_WIDTH, pngSize } from './util.ts';

const A4: [number, number] = [595.28, 841.89];
const MARGIN = 50;
const INK = rgb(0.1, 0.12, 0.15);
const MUTED = rgb(0.4, 0.43, 0.47);
const RULE = rgb(0.75, 0.78, 0.8);
type Colour = ReturnType<typeof rgb>;
// A colour from a hex code (#0B3B75), or ink when it is not one.
export function hexColour(hex: string | null | undefined): Colour {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(hex || ''));
  return m ? rgb(parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255) : INK;
}

// ------------------------------------------------------------------ text the standard fonts can draw
// Windows Latin (WinAnsi) beyond ASCII: 0xA0 to 0xFF, and these from 0x80 to 0x9F.
const WIN_ANSI_EXTRA = new Set(Array.from('\u20AC\u201A\u0192\u201E\u2026\u2020\u2021\u02C6\u2030\u0160\u2039\u0152\u017D\u2018\u2019\u201C\u201D\u2022\u2013\u2014\u02DC\u2122\u0161\u203A\u0153\u017E\u0178'));
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
    .replace(/\u20A6\s*/g, 'NGN ')
    .replace(/[\u2018\u2019\u201A\u201B\u2032]/g, "'")
    .replace(/[\u201C\u201D\u201E\u201F\u2033\u00AB\u00BB]/g, '"')
    .replace(/[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/g, '-')
    .replace(/\u2026/g, '...')
    .replace(/\r\n?/g, '\n')
    .replace(/[\t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/g, ' ');
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

// ------------------------------------------------------------------ the page: size, margins and what is drawn on it first
// A page's frame: the space kept clear at each side, and the line the page number sits on.
export type Frame = { top: number; bottom: number; left: number; right: number; foot: number };
// How every page looks: its size, the first page's frame and the following pages', and what goes on a new page before the
// text (a letterhead under it, a header above it). decorate answers where the text starts, when not at the frame's top.
type Look = { W: number; H: number; first: Frame; next: Frame; decorate?: (page: PDFPage, index: number) => number | void };

const plainFrame: Frame = { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN, foot: 28 };
const plainLook = (size: [number, number] = A4): Look => ({ W: size[0], H: size[1], first: plainFrame, next: plainFrame });

// Writes down the pages, starting a new page when the next lines do not fit.
class Writer {
  page!: PDFPage;
  y = 0;
  frame!: Frame;
  frames: Frame[] = [];
  constructor(private doc: PDFDocument, readonly f: Fonts, readonly look: Look = plainLook()) { this.newPage(); }
  get left() { return this.frame.left; }
  get right() { return this.look.W - this.frame.right; }
  newPage() {
    const i = this.frames.length;
    this.frame = i === 0 ? this.look.first : this.look.next;
    this.frames.push(this.frame);
    this.page = this.doc.addPage([this.look.W, this.look.H]);
    const start = this.look.decorate?.(this.page, i);
    this.y = typeof start === 'number' ? start : this.look.H - this.frame.top;
  }
  ensure(h: number) {
    if (this.y - h < this.frame.bottom) this.newPage();
  }
  // Lines of text at x (with a label, such as "1.1", at labelX on the first line); keep: lines kept together.
  text(text: string, o: { x?: number; label?: string | null; labelX?: number; font?: PDFFont; size?: number; color?: Colour;
    gap?: number; keep?: number; width?: number } = {}) {
    const x = o.x ?? this.left, font = o.font ?? this.f.regular, size = o.size ?? 10, lh = size * 1.45;
    const lines = wrap(pdfSafe(text), font, size, o.width ?? this.right - x);
    this.y -= o.gap ?? 0;
    this.ensure(lh * Math.max(1, Math.min(lines.length, o.keep ?? 1)));
    lines.forEach((l, i) => {
      this.ensure(lh);
      this.y -= lh;
      if (i === 0 && o.label) this.page.drawText(pdfSafe(o.label), { x: o.labelX ?? this.left, y: this.y, font, size, color: o.color ?? INK });
      if (l) this.page.drawText(l, { x, y: this.y, font, size, color: o.color ?? INK });
    });
  }
  rule(x1: number, x2: number, color: Colour = RULE, thickness = 0.6) {
    this.page.drawLine({ start: { x: x1, y: this.y }, end: { x: x2, y: this.y }, thickness, color });
  }
}

async function fonts(doc: PDFDocument, family: 'helvetica' | 'times' = 'helvetica'): Promise<Fonts> {
  if (family === 'times') {
    return { regular: await doc.embedFont(StandardFonts.TimesRoman), bold: await doc.embedFont(StandardFonts.TimesRomanBold),
      italic: await doc.embedFont(StandardFonts.TimesRomanItalic) };
  }
  return { regular: await doc.embedFont(StandardFonts.Helvetica), bold: await doc.embedFont(StandardFonts.HelveticaBold),
    italic: await doc.embedFont(StandardFonts.HelveticaOblique) };
}

// A footer at the foot of a page: text on the left (cut to fit), and on the right, on the frame's page-number line.
function footer(page: PDFPage, f: Fonts, left: string, right: string, fr: Frame = plainFrame) {
  const size = 8, rightText = pdfSafe(right), W = page.getWidth();
  const rw = f.regular.widthOfTextAtSize(rightText, size);
  const max = W - fr.left - fr.right - rw - 20;
  let l = pdfSafe(left).replace(/\n/g, ' ');
  if (f.regular.widthOfTextAtSize(l, size) > max) {
    while (l && f.regular.widthOfTextAtSize(l + '...', size) > max) l = l.slice(0, -1);
    l += '...';
  }
  page.drawText(l, { x: fr.left, y: fr.foot, font: f.regular, size, color: MUTED });
  page.drawText(rightText, { x: W - fr.right - rw, y: fr.foot, font: f.regular, size, color: MUTED });
}

// ------------------------------------------------------------------ the firm's letterhead
export type LetterheadFile = { path: string; sha256: string; kind: 'pdf' | 'png' | 'jpg'; w: number; h: number };
// As the database keeps it (private.letterhead_norm).
export type Letterhead = {
  mode: 'upload' | 'built'; font: 'helvetica' | 'times'; color: string; page: [number, number];
  first?: LetterheadFile; next?: LetterheadFile | null; next_mode?: 'same' | 'upload' | 'none';
  margins?: { first_top: number; first_bottom: number; next_top: number; next_bottom: number; left: number; right: number };
  logo?: LetterheadFile | null; layout?: 'left' | 'center';
  show?: { address: boolean; phone: boolean; email: boolean; firm_reg: boolean; website: boolean };
  website?: string | null; footer?: string | null;
};
// The bytes of its files, read and checked by the caller (letterhead.ts).
export type LetterheadFiles = { first?: Uint8Array; next?: Uint8Array; logo?: Uint8Array };
export type Firm = { name: string; address?: string | null; state?: string | null; phone?: string | null; email?: string | null; firm_reg?: string | null };

type Art = PDFEmbeddedPage | PDFImage;
async function embedArt(doc: PDFDocument, f: LetterheadFile | null | undefined, bytes: Uint8Array | undefined): Promise<Art | null> {
  if (!f || !bytes) return null;
  if (f.kind === 'pdf') return (await doc.embedPdf(bytes, [0]))[0];
  return f.kind === 'png' ? await doc.embedPng(bytes) : await doc.embedJpg(bytes);
}
// A letterhead page laid under the whole page.
function drawUnder(page: PDFPage, art: Art) {
  const o = { x: 0, y: 0, width: page.getWidth(), height: page.getHeight() };
  if (art instanceof PDFImage) page.drawImage(art, o); else page.drawPage(art, o);
}

// The firm's details as a built letterhead prints them under its name.
export function firmLines(firm: Firm, lh: Pick<Letterhead, 'show' | 'website'>): string[] {
  const s = lh.show || { address: true, phone: true, email: true, firm_reg: true, website: false };
  const address = s.address ? [firm.address, firm.state].map((x) => String(x || '').trim()).filter(Boolean).join(', ') : '';
  const contact = [s.phone && firm.phone ? `Tel ${firm.phone}` : '', s.email && firm.email ? String(firm.email) : '',
    s.website && lh.website ? String(lh.website) : ''].filter(Boolean).join(' · ');
  const reg = s.firm_reg && firm.firm_reg ? `Registration no. ${firm.firm_reg}` : '';
  return [address, contact, reg].filter(Boolean);
}

// The look of a letter with the firm's letterhead.
async function letterheadLook(doc: PDFDocument, f: Fonts, lh: Letterhead, files: LetterheadFiles, firm: Firm): Promise<Look> {
  const [W, H] = lh.page;
  const accent = hexColour(lh.color);
  if (lh.mode === 'upload') {
    const m = lh.margins!;
    const first = await embedArt(doc, lh.first, files.first);
    const next = lh.next_mode === 'upload' ? await embedArt(doc, lh.next, files.next) : lh.next_mode === 'none' ? null : first;
    // The page number sits just above the space kept clear at the bottom, and the text stops above it.
    const frame = (top: number, bottom: number): Frame => ({ top, bottom: bottom + 18, left: m.left, right: m.right, foot: bottom + 4 });
    return {
      W, H, first: frame(m.first_top, m.first_bottom), next: frame(m.next_top, m.next_bottom),
      decorate: (page, i) => {
        const art = i === 0 ? first : next;
        if (art) drawUnder(page, art);
      },
    };
  }

  // Built in Counta: the logo with the firm's name and details, a rule in its colour, and its footer on every page.
  const logo = await embedArt(doc, lh.logo, files.logo);
  const lines = firmLines(firm, lh);
  const foot = wrap(pdfSafe(String(lh.footer || '')), f.regular, 7.5, W - 2 * MARGIN).filter(Boolean).slice(0, 3);
  const bottom = 46 + foot.length * 9.5;
  const frame: Frame = { top: 62, bottom, left: MARGIN, right: MARGIN, foot: 24 };
  const name = pdfSafe(firm.name);
  return {
    W, H, first: frame, next: frame,
    decorate: (page, i) => {
      foot.forEach((l, k) => {
        const w = f.regular.widthOfTextAtSize(l, 7.5);
        page.drawText(l, { x: (W - w) / 2, y: 38 + (foot.length - 1 - k) * 9.5, font: f.regular, size: 7.5, color: MUTED });
      });
      if (i > 0) {
        // The following pages: the firm's name and a thin rule.
        page.drawText(name, { x: MARGIN, y: H - 36, font: f.bold, size: 9, color: accent });
        page.drawLine({ start: { x: MARGIN, y: H - 43 }, end: { x: W - MARGIN, y: H - 43 }, thickness: 0.8, color: accent });
        return H - 62;
      }
      const top = H - 42, width = W - 2 * MARGIN;
      let y: number;
      if (lh.layout === 'center') {
        y = top;
        if (logo) {
          const sc = Math.min(200 / logo.width, 60 / logo.height);
          const lw = logo.width * sc, lhh = logo.height * sc;
          drawLogo(page, logo, (W - lw) / 2, y - lhh, lw, lhh);
          y -= lhh + 10;
        }
        for (const l of wrap(name, f.bold, 16, width)) {
          y -= 16;
          page.drawText(l, { x: (W - f.bold.widthOfTextAtSize(l, 16)) / 2, y, font: f.bold, size: 16, color: accent });
          y -= 3;
        }
        for (const l of lines.flatMap((x) => wrap(pdfSafe(x), f.regular, 8.5, width))) {
          y -= 11;
          page.drawText(l, { x: (W - f.regular.widthOfTextAtSize(l, 8.5)) / 2, y, font: f.regular, size: 8.5, color: MUTED });
        }
      } else {
        let lw = 0, lhh = 0;
        if (logo) {
          const sc = Math.min(170 / logo.width, 56 / logo.height);
          lw = logo.width * sc; lhh = logo.height * sc;
          drawLogo(page, logo, MARGIN, top - lhh, lw, lhh);
        }
        // Beside a logo the name and details sit on the right; without one, on the left.
        const avail = logo ? width - lw - 24 : width;
        const at = (l: string, font: PDFFont, size: number) => (logo ? W - MARGIN - font.widthOfTextAtSize(l, size) : MARGIN);
        let ty = top;
        for (const l of wrap(name, f.bold, 15, avail)) {
          ty -= 15;
          page.drawText(l, { x: at(l, f.bold, 15), y: ty, font: f.bold, size: 15, color: accent });
          ty -= 3;
        }
        for (const l of lines.flatMap((x) => wrap(pdfSafe(x), f.regular, 8.5, avail))) {
          ty -= 11;
          page.drawText(l, { x: at(l, f.regular, 8.5), y: ty, font: f.regular, size: 8.5, color: MUTED });
        }
        y = Math.min(ty, top - lhh);
      }
      y -= 10;
      page.drawLine({ start: { x: MARGIN, y }, end: { x: W - MARGIN, y }, thickness: 1.2, color: accent });
      return y - 8;
    },
  };
}
function drawLogo(page: PDFPage, art: Art, x: number, y: number, width: number, height: number) {
  if (art instanceof PDFImage) page.drawImage(art, { x, y, width, height }); else page.drawPage(art, { x, y, width, height });
}

// A preview's mark on every page, so it is never mistaken for a signed letter.
function previewMark(page: PDFPage, f: Fonts) {
  const W = page.getWidth(), H = page.getHeight(), text = 'PREVIEW', size = 96;
  const w = f.bold.widthOfTextAtSize(text, size);
  page.drawText(text, { x: W / 2 - (w / 2) * Math.cos(Math.PI / 5), y: H / 2 - (w / 2) * Math.sin(Math.PI / 5), font: f.bold, size,
    color: rgb(0.85, 0.2, 0.2), opacity: 0.12, rotate: degrees(36) });
}

const INDENT = [0, 0, 30, 55, 80]; // by level

export type LetterMeta = { title: string; firmName: string; partnerName: string; partnerTitle: string; partnerSignature?: string; firm?: Firm;
  preview?: boolean };

// The letter as the partner signs it: the firm's letterhead (or its name heading the first page, on A4 with 50 pt
// margins), numbered blocks with hanging numbers, the firm's typed signature in its signature block, and "Page n of m" on
// every page. A preview is marked as one on every page and carries no signature.
export async function renderLetterPdf(blocks: RenderedBlock[], meta: LetterMeta,
  letterhead?: { settings: Letterhead; files: LetterheadFiles } | null): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.setTitle(meta.title);
  doc.setAuthor(meta.firmName);
  doc.setCreator(meta.firmName);
  doc.setProducer(meta.firmName);
  const lh = letterhead?.settings ?? null;
  const f = await fonts(doc, lh?.font === 'times' ? 'times' : 'helvetica');
  const look = lh ? await letterheadLook(doc, f, lh, letterhead!.files, meta.firm ?? { name: meta.firmName }) : plainLook();
  const accent = lh ? hexColour(lh.color) : INK;
  const w = new Writer(doc, f, look);

  if (!lh) {
    w.text(meta.firmName, { font: f.bold, size: 14 });
    w.y -= 8;
    w.rule(w.left, w.right);
    w.y -= 6;
  }

  for (const b of blocks) {
    const level = Math.min(Math.max(Math.round(Number(b.level) || 1), 1), 4);
    const L = w.left;
    switch (b.kind) {
      case 'heading':
        w.text(b.text, { label: b.number, labelX: L, x: L + 30, font: f.bold, size: 11, gap: 12, keep: 3, color: accent });
        break;
      case 'clause':
        w.text(b.text, { label: b.number, labelX: L, x: L + 30, gap: 6, keep: 2 });
        break;
      case 'list': {
        const at = level >= 4 ? 55 : 30;
        w.text(b.text, { label: b.number, labelX: L + at, x: L + at + 25, gap: 4, keep: 2 });
        break;
      }
      case 'signature':
        w.y -= 12;
        w.ensure(70);
        if (b.text === 'firm') {
          w.y -= 24;
          if (meta.partnerSignature && !meta.preview) {
            w.page.drawText(pdfSafe(meta.partnerSignature), { x: w.left, y: w.y, font: f.italic, size: 18, color: INK });
          }
          w.y -= 6;
          w.rule(w.left, w.left + 220);
          w.text(`${meta.preview ? 'To be signed electronically' : 'Signed electronically'} for ${meta.firmName} by ${meta.partnerName}, ${meta.partnerTitle}`,
            { size: 8.5, color: MUTED, width: 300 });
        } else {
          w.y -= 30;
          w.rule(w.left, w.left + 220);
          w.text('For the client', { size: 8.5, color: MUTED });
        }
        break;
      default:
        w.text(b.text, { x: w.left + INDENT[level], gap: 6, keep: 2 });
    }
  }

  const pages = doc.getPages();
  pages.forEach((p, i) => {
    footer(p, f, meta.title, `Page ${i + 1} of ${pages.length}`, w.frames[i]);
    if (meta.preview) previewMark(p, f);
  });
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

// Whether a PNG's image data inflates to no more than a picture of its size can hold (16-bit RGBA, every row's filter byte
// and Adam7's extra rows allowed for): a small file that inflates to a huge one is refused before it is decoded.
export async function pngInflatesSafely(png: Uint8Array): Promise<boolean> {
  const size = pngSize(png);
  const data = size && pngData(png);
  return !!data && await inflatesWithin(data, size!.height * (size!.width * 8 + 8) + 1024);
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
  // The pages added are the size of the letter's own pages (A4 unless its letterhead is US Letter).
  const first = doc.getPageCount() ? doc.getPage(0).getSize() : { width: A4[0], height: A4[1] };
  const look = plainLook([first.width, first.height]);

  // Signature page
  const w = new Writer(doc, f, look);
  w.text('Signature page', { font: f.bold, size: 14 });
  w.text(c.title, { size: 10, color: MUTED, gap: 4 });
  w.y -= 10;
  w.rule(w.left, w.right);

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
  const v = new Writer(doc, f, look);
  v.text('Completion certificate', { font: f.bold, size: 14 });
  v.text(c.title, { size: 10, color: MUTED, gap: 4 });
  v.y -= 10;
  v.rule(v.left, v.right);
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
