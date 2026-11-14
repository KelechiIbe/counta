import { assert, assertEquals } from 'jsr:@std/assert@1';
import { decodePDFRawStream, PDFArray, PDFDocument, PDFRawStream } from 'npm:pdf-lib@1.17.1';
import { appendCompletion, type Completion, pdfSafe, renderLetterPdf } from './pdf.ts';
import type { RenderedBlock } from '../_shared/letter.ts';

// A 1 x 1 PNG, as a drawn signature would arrive (decoded from its data URL).
const PNG = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0));

const blocks: RenderedBlock[] = [
  { id: 'scope', kind: 'heading', level: 1, number: '1.', ref: '1', text: 'Scope of Engagement' },
  { id: 'scope_services', kind: 'clause', level: 2, number: '1.1', ref: '1.1', text: 'Our role will include the services below.' },
  { id: 'svc', kind: 'list', level: 3, number: '(a)', ref: '1.1(a)', text: 'Bookkeeping for Ọlá Àdé Foods Ltd.' },
  { id: 'signature_firm', kind: 'signature', level: 1, number: null, ref: null, text: 'firm' },
  { id: 'signature_client', kind: 'signature', level: 1, number: null, ref: null, text: 'client' },
];
const meta = { title: 'Letter of engagement: Ọlá Àdé Foods Ltd', firmName: 'Ṣọlá & Co', partnerName: 'Ṣọlá Ìyá', partnerTitle: 'Partner', partnerSignature: 'Ṣọlá Ìyá' };
const completion: Completion = {
  title: meta.title, originalSha256: 'ab'.repeat(32),
  firm: { name: 'Ṣọlá & Co', partnerName: 'Ṣọlá Ìyá', partnerEmail: 'partner@firm.example.test', signedAt: '2026-11-12T09:30:00.123456+00:00', ip: '198.51.100.7', ua: 'Mozilla/5.0 (Test)' },
  client: { name: 'Ada Obi', email: 'ada@client.example.test', title: 'Director', signedAt: new Date('2026-11-13T10:05:00Z'), ip: '203.0.113.9', ua: 'Mozilla/5.0 (Phone)',
    typedName: 'Ada Obi', signaturePng: PNG },
};

Deno.test('pdf_diacritics_do_not_throw', async () => {            // Review Focus 1
  const bytes = await renderLetterPdf([{ id: 'p', kind: 'paragraph', level: 1, number: null, ref: null, text: 'Ọlá Àdé Foods Ltd pays ₦250,000 – “monthly”…' }],
    { title: 'Letter', firmName: 'Ṣọlá & Co', partnerName: 'Ṣọlá Ìyá', partnerTitle: 'Partner' });
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), '%PDF-');
  assertEquals(pdfSafe('Ọlá Àdé ₦5'), 'Ola Ade NGN 5');
});
// The text drawn on each page, one line per text operation (the standard fonts write it as hex WinAnsi strings).
async function pageTexts(bytes: Uint8Array): Promise<string[]> {
  const doc = await PDFDocument.load(bytes);
  return doc.getPages().map((p) => {
    const c = p.node.Contents();
    const streams = c instanceof PDFArray ? c.asArray().map((r) => doc.context.lookup(r)) : [c];
    let text = '';
    for (const s of streams) {
      if (!(s instanceof PDFRawStream)) continue;
      const ops = new TextDecoder('latin1').decode(decodePDFRawStream(s).decode());
      for (const m of ops.matchAll(/<([0-9A-Fa-f]*)>\s*Tj/g)) text += m[1].replace(/../g, (h) => String.fromCharCode(parseInt(h, 16))) + '\n';
    }
    return text;
  });
}

Deno.test('pdf_completion_certificate', async () => {
  const base = await renderLetterPdf(blocks, meta);
  const out = await appendCompletion(base, completion);   // completion.originalSha256 = 'ab'.repeat(32)
  assertEquals((await PDFDocument.load(out)).getPageCount(), (await PDFDocument.load(base)).getPageCount() + 2);
  // What the pages say: both parties' names, emails, Lagos times, IP addresses and browsers, the verified email and the
  // original SHA-256 (names folded for the standard fonts).
  const pages = await pageTexts(out);
  const [signature, certificate] = pages.slice(-2);
  for (const want of ['Signature page', 'For Sola & Co', 'Signed electronically by Sola Iya on 12 Nov 2026, 10:30 (Africa/Lagos).', 'Ada Obi', 'Director',
    'Signed electronically by Ada Obi on 13 Nov 2026, 11:05 (Africa/Lagos).']) {
    assert(signature.includes(want), `signature page: ${want}`);
  }
  for (const want of ['Completion certificate', `Original document SHA-256: ${'ab'.repeat(32)}`, 'Sola & Co', 'Sola Iya', 'partner@firm.example.test',
    '12 Nov 2026, 10:30 (Africa/Lagos)', '198.51.100.7', 'Mozilla/5.0 (Test)', 'Ada Obi, Director', 'ada@client.example.test',
    'Email verified by a one-time code', '13 Nov 2026, 11:05 (Africa/Lagos)', '203.0.113.9', 'Mozilla/5.0 (Phone)']) {
    assert(certificate.includes(want), `certificate: ${want}`);
  }
  assert(!pages.join('\n').includes('Counta'), 'the firm only');
});

// ------------------------------------------------------------------ the firm's letterhead
import { PDFDict, PDFName, rgb } from 'npm:pdf-lib@1.17.1';
import { firmLines, hexColour, type Letterhead } from './pdf.ts';
import bodyJson from '../_shared/default_letter.json' with { type: 'json' };
import { deriveMerge, type LetterBody, renderModel } from '../_shared/letter.ts';
import { letterheadPdf, makePng } from './test_images.ts';

// Each piece of text drawn on each page with where it starts (x, y) and whether it is turned.
async function placed(bytes: Uint8Array): Promise<{ x: number; y: number; text: string; turned: boolean }[][]> {
  const doc = await PDFDocument.load(bytes);
  return doc.getPages().map((p) => {
    const c = p.node.Contents();
    const streams = c instanceof PDFArray ? c.asArray().map((r) => doc.context.lookup(r)) : [c];
    const out: { x: number; y: number; text: string; turned: boolean }[] = [];
    for (const s of streams) {
      if (!(s instanceof PDFRawStream)) continue;
      const ops = new TextDecoder('latin1').decode(decodePDFRawStream(s).decode());
      for (const m of ops.matchAll(/(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) Tm\s*<([0-9A-Fa-f]*)>\s*Tj/g)) {
        out.push({ x: Number(m[5]), y: Number(m[6]), turned: m[1] !== '1', text: m[7].replace(/../g, (h) => String.fromCharCode(parseInt(h, 16))) });
      }
    }
    return out;
  });
}
// The XObjects a page draws (an embedded letterhead page or a picture), by count.
async function xobjects(bytes: Uint8Array): Promise<number[]> {
  const doc = await PDFDocument.load(bytes);
  return doc.getPages().map((p) => {
    const x = p.node.Resources()?.lookup(PDFName.of('XObject'));
    return x instanceof PDFDict ? x.keys().length : 0;
  });
}
// The fonts the first page uses, by their base names.
async function fontNames(bytes: Uint8Array): Promise<string[]> {
  const doc = await PDFDocument.load(bytes);
  const fonts = doc.getPage(0).node.Resources()?.lookup(PDFName.of('Font'));
  if (!(fonts instanceof PDFDict)) return [];
  return fonts.keys().map((k) => String((fonts.lookup(k) as PDFDict).get(PDFName.of('BaseFont'))).replace(/^\//, ''));
}
const longLetter = renderModel(bodyJson as LetterBody, deriveMerge({ 'client.name': 'Dayo Foods Ltd', 'fees.amount': 250000, 'service.bookkeeping': true,
  'service.monthly': true, 'service.annual': true, 'service.advisory': true }), 'involved');
const firm = { name: 'Head Partners', address: '3 Test Avenue, Ikoyi', state: 'Lagos', phone: '+234 1 000 0001', email: 'office@head.example.test',
  firm_reg: 'BN 445566' };
const lmeta = { title: 'Letter of engagement: Dayo Foods Ltd', firmName: 'Head Partners', partnerName: 'Bisi Partner', partnerTitle: 'Partner',
  partnerSignature: 'Bisi Partner', firm };
const file = (kind: 'pdf' | 'png' | 'jpg', w: number, h: number) => ({ path: `practice/x/letterhead/a.${kind}`, sha256: 'ab'.repeat(32), kind, w, h });

Deno.test('pdf_letterhead_uploaded_page', async () => {
  const page = await letterheadPdf();
  const lh: Letterhead = { mode: 'upload', font: 'times', color: '#0B3B75', page: [595.28, 841.89], first: file('pdf', 595.28, 841.89), next_mode: 'same',
    margins: { first_top: 150, first_bottom: 80, next_top: 150, next_bottom: 80, left: 60, right: 56 } };
  const bytes = await renderLetterPdf(longLetter, lmeta, { settings: lh, files: { first: page } });
  const doc = await PDFDocument.load(bytes);
  assert(doc.getPageCount() >= 3, 'a long letter runs on');
  for (const p of doc.getPages()) assertEquals([p.getWidth(), p.getHeight()], [595.28, 841.89]);
  assert((await xobjects(bytes)).every((n) => n === 1), 'the letterhead is under every page');
  const pages = await placed(bytes);
  for (const [i, texts] of pages.entries()) {
    for (const t of texts) {
      assert(t.y <= 841.89 - 150 + 0.01, `page ${i + 1}: "${t.text}" is below the space kept at the top (${t.y})`);
      assert(t.y >= 80 + 4 - 0.01, `page ${i + 1}: "${t.text}" is above the space kept at the bottom (${t.y})`);
      assert(t.x >= 60 - 0.01, `page ${i + 1}: "${t.text}" keeps the left side (${t.x})`);
    }
    // The page number sits just above the space kept at the bottom.
    assert(texts.some((t) => t.text === `Page ${i + 1} of ${pages.length}` && Math.abs(t.y - 84) < 0.01), `page ${i + 1}: its number`);
  }
  // No firm-name heading of its own: the letterhead carries the name.
  assert(!pages[0].some((t) => t.text === 'Head Partners'), 'no heading over the letterhead');
  assert((await fontNames(bytes)).includes('Times-Roman'), 'set in Times');
});

Deno.test('pdf_letterhead_following_pages', async () => {
  const first = await letterheadPdf(), next = await letterheadPdf([595.28, 841.89], 'HP');
  const base: Letterhead = { mode: 'upload', font: 'helvetica', color: '#111827', page: [595.28, 841.89], first: file('pdf', 595.28, 841.89),
    margins: { first_top: 150, first_bottom: 80, next_top: 90, next_bottom: 60, left: 56, right: 56 } };
  // A page of its own for the following pages, with its own margins.
  let bytes = await renderLetterPdf(longLetter, lmeta, { settings: { ...base, next_mode: 'upload', next: file('pdf', 595.28, 841.89) }, files: { first, next } });
  let pages = await placed(bytes);
  assert((await xobjects(bytes)).every((n) => n === 1));
  assert(pages[1].every((t) => t.y <= 841.89 - 90 + 0.01 && t.y >= 64 - 0.01), 'the following pages keep their own margins');
  assert(pages[1].some((t) => t.y > 841.89 - 150), 'and use the room the first page keeps for its letterhead');
  // None on the following pages.
  bytes = await renderLetterPdf(longLetter, lmeta, { settings: { ...base, next_mode: 'none' }, files: { first } });
  assertEquals((await xobjects(bytes)).map((n) => n > 0), (await xobjects(bytes)).map((_, i) => i === 0));
  pages = await placed(bytes);
  assert(pages.length >= 2);
});

Deno.test('pdf_letterhead_picture_and_letter_size', async () => {
  // A whole-page picture (PNG) laid under a US Letter page.
  const png = makePng(1275, 1650);
  const lh: Letterhead = { mode: 'upload', font: 'helvetica', color: '#111827', page: [612, 792], first: file('png', 1275, 1650), next_mode: 'same',
    margins: { first_top: 120, first_bottom: 70, next_top: 120, next_bottom: 70, left: 56, right: 56 } };
  const bytes = await renderLetterPdf(longLetter, lmeta, { settings: lh, files: { first: png } });
  const doc = await PDFDocument.load(bytes);
  for (const p of doc.getPages()) assertEquals([p.getWidth(), p.getHeight()], [612, 792]);
  assert((await xobjects(bytes)).every((n) => n === 1));
  // The pages a client's signature adds are the letter's size too.
  const signed = await PDFDocument.load(await appendCompletion(bytes, completion));
  for (const p of signed.getPages()) assertEquals([p.getWidth(), p.getHeight()], [612, 792]);
});

Deno.test('pdf_letterhead_built', async () => {
  const logo = makePng(300, 100, [157, 23, 77]);
  const lh: Letterhead = { mode: 'built', font: 'helvetica', color: '#9D174D', page: [595.28, 841.89], logo: file('png', 300, 100), layout: 'left',
    show: { address: true, phone: true, email: true, firm_reg: true, website: true }, website: 'www.head.example.test',
    footer: 'Partners: Bisi Partner FCA, Kunle Partner ACA\nRegulated by ICAN' };
  const bytes = await renderLetterPdf(longLetter, lmeta, { settings: lh, files: { logo } });
  const pages = await placed(bytes);
  const first = pages[0].map((t) => t.text);
  for (const want of ['Head Partners', '3 Test Avenue, Ikoyi, Lagos', 'Registration no. BN 445566', 'Partners: Bisi Partner FCA, Kunle Partner ACA',
    'Regulated by ICAN']) {
    assert(first.includes(want), `first page: ${want}`);
  }
  for (const want of ['Tel +234 1 000 0001', 'office@head.example.test', 'www.head.example.test']) {
    assert(first.some((t) => t.includes(want)), `first page: ${want}`);
  }
  // Beside the logo the name sits on the right.
  const name = pages[0].find((t) => t.text === 'Head Partners')!;
  assert(name.x > 300, 'name on the right of the logo');
  assertEquals((await xobjects(bytes))[0], 1);
  // The following pages: the firm's name small at the top, and the footer.
  for (const p of pages.slice(1)) {
    assert(p.some((t) => t.text === 'Head Partners' && t.y > 800), 'name at the top of a following page');
    assert(p.some((t) => t.text === 'Regulated by ICAN'), 'footer on a following page');
    assert(p.filter((t) => !['Head Partners', 'Regulated by ICAN', 'Partners: Bisi Partner FCA, Kunle Partner ACA'].includes(t.text))
      .every((t) => t.y >= 24 - 0.01 && t.y <= 841.89 - 62), 'text between the header and the footer');
  }
  // Centred, without a logo.
  const centred = await placed(await renderLetterPdf(longLetter, lmeta, { settings: { ...lh, layout: 'center', logo: null }, files: {} }));
  const c = centred[0].find((t) => t.text === 'Head Partners')!;
  assert(Math.abs(c.x - (595.28 - c.x - 0)) > 0 && c.x > 150 && c.x < 300, 'name centred');
});

Deno.test('pdf_letterhead_pieces', () => {
  assertEquals(firmLines(firm, { show: { address: true, phone: false, email: true, firm_reg: false, website: false }, website: 'x.ng' }),
    ['3 Test Avenue, Ikoyi, Lagos', 'office@head.example.test']);
  assertEquals(firmLines({ name: 'Solo' }, { show: { address: true, phone: true, email: true, firm_reg: true, website: true }, website: null }), []);
  const c = hexColour('#0B3B75');
  assertEquals([c.red, c.green, c.blue].map((x) => Math.round(x * 255)), [11, 59, 117]);
  assertEquals(hexColour('blue'), rgb(0.1, 0.12, 0.15));
});

Deno.test('pdf_preview_marked_and_unsigned', async () => {
  const bytes = await renderLetterPdf(longLetter, { ...lmeta, preview: true });
  const pages = await placed(bytes);
  assert(pages.every((p) => p.some((t) => t.text === 'PREVIEW' && t.turned)), 'every page is marked');
  const all = pages.flat().map((t) => t.text);
  assert(all.some((t) => t.startsWith('To be signed electronically for Head Partners by Bisi Partner')), 'not signed');
  assert(!all.includes('Bisi Partner'), 'no typed signature');
  // A signed letter is never marked.
  assert(!(await placed(await renderLetterPdf(longLetter, lmeta))).flat().some((t) => t.text === 'PREVIEW'));
});

Deno.test('pdf_plain_letter_unchanged', async () => {
  // Without a letterhead: A4, Helvetica, the firm's name heading the first page, numbers on the 28 pt line.
  const bytes = await renderLetterPdf(longLetter, lmeta);
  const doc = await PDFDocument.load(bytes);
  for (const p of doc.getPages()) assertEquals([p.getWidth(), p.getHeight()], [595.28, 841.89]);
  const pages = await placed(bytes);
  assertEquals(pages[0][0], { x: 50, y: 841.89 - 50 - 14 * 1.45, text: 'Head Partners', turned: false });
  assert(pages.every((p, i) => p.some((t) => t.text === `Page ${i + 1} of ${pages.length}` && t.y === 28)));
  assertEquals((await xobjects(bytes)).filter((n) => n > 0).length, 0);
});
