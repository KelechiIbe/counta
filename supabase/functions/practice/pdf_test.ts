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
