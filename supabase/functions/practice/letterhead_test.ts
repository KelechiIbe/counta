// The checks on a firm's letterhead files before they go into a letter.
import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { checkLetterheadFile, jpegSize, letterheadFiles } from './letterhead.ts';
import type { Letterhead, LetterheadFile } from './pdf.ts';
import { sha256Hex, UserError } from './util.ts';
import { jpegHeader, letterheadPdf, makePng } from './test_images.ts';

const file = async (kind: 'pdf' | 'png' | 'jpg', bytes: Uint8Array, w: number, h: number, path = `practice/p/letterhead/x.${kind}`): Promise<LetterheadFile> =>
  ({ path, sha256: await sha256Hex(bytes), kind, w, h });
const refused = (p: Promise<unknown>, like: string) => assertRejects(() => p, UserError, like);

Deno.test('letterhead_jpeg_size', () => {
  assertEquals(jpegSize(jpegHeader(2480, 3508)), { width: 2480, height: 3508 });
  assertEquals(jpegSize(new Uint8Array([0x89, 0x50, 0x4e, 0x47])), null);
  assertEquals(jpegSize(new Uint8Array([0xff, 0xd8, 0x00])), null);
});

Deno.test('letterhead_file_checks', async () => {
  const pdf = await letterheadPdf();
  await checkLetterheadFile(await file('pdf', pdf, 595.28, 841.89), 'first', pdf);
  // Not the file saved, or not the size saved.
  await refused(checkLetterheadFile({ ...(await file('pdf', pdf, 595.28, 841.89)), sha256: 'ab'.repeat(32) }, 'first', pdf), 'not the file that was saved');
  await refused(checkLetterheadFile(await file('pdf', pdf, 612, 792), 'first', pdf), 'not the size that was saved');
  // Not a PDF, a page on its side, or too large.
  const notPdf = new TextEncoder().encode('hello');
  await refused(checkLetterheadFile(await file('pdf', notPdf, 595.28, 841.89), 'first', notPdf), 'the letterhead page is not a PDF');
  const wide = await letterheadPdf([841.89, 595.28]);
  await refused(checkLetterheadFile(await file('pdf', wide, 841.89, 595.28), 'next', wide), 'the page for the following pages is not an upright');
  const big = new Uint8Array(5 * 1048576 + 1);
  await refused(checkLetterheadFile(await file('pdf', big, 595.28, 841.89), 'first', big), 'larger than 5 MB');
  // Pictures: a whole page, or a logo, of a size Counta can print.
  const page = makePng(1240, 1754);
  await checkLetterheadFile(await file('png', page, 1240, 1754), 'first', page);
  const jpg = jpegHeader(2550, 3300);
  await checkLetterheadFile(await file('jpg', jpg, 2550, 3300), 'first', jpg);
  const tiny = makePng(400, 560);
  await refused(checkLetterheadFile(await file('png', tiny, 400, 560), 'first', tiny), 'not a size Counta can print');
  const logo = makePng(300, 100);
  await checkLetterheadFile(await file('png', logo, 300, 100), 'logo', logo);
  await refused(checkLetterheadFile(await file('png', page, 1240, 1754), 'logo', page), 'the logo is not a size Counta can print');
  await refused(checkLetterheadFile(await file('png', jpg, 2550, 3300), 'first', jpg), 'not a PNG picture');
  await refused(checkLetterheadFile(await file('pdf', pdf, 595.28, 841.89), 'logo', pdf), 'the logo is not a PDF');
  const bigLogo = new Uint8Array(2 * 1048576 + 1);
  await refused(checkLetterheadFile(await file('png', bigLogo, 300, 100), 'logo', bigLogo), 'larger than 2 MB');
});

Deno.test('letterhead_files_read', async () => {
  const pdf = await letterheadPdf(), next = await letterheadPdf([595.28, 841.89], 'HP'), logo = makePng(300, 100);
  const store = new Map<string, Uint8Array>([['practice/p/letterhead/first.pdf', pdf], ['practice/p/letterhead/next.pdf', next], ['practice/p/letterhead/logo.png', logo]]);
  const read = (p: string) => Promise.resolve(store.get(p) ?? null);
  const first = await file('pdf', pdf, 595.28, 841.89, 'practice/p/letterhead/first.pdf');
  const nextF = await file('pdf', next, 595.28, 841.89, 'practice/p/letterhead/next.pdf');
  const up: Letterhead = { mode: 'upload', font: 'helvetica', color: '#111827', page: [595.28, 841.89], first, next_mode: 'same',
    margins: { first_top: 150, first_bottom: 80, next_top: 150, next_bottom: 80, left: 56, right: 56 } };
  assertEquals(Object.keys(await letterheadFiles(up, read)), ['first']);
  assertEquals(Object.keys(await letterheadFiles({ ...up, next_mode: 'upload', next: nextF }, read)), ['first', 'next']);
  assertEquals(await letterheadFiles(null, read), {});
  const built: Letterhead = { mode: 'built', font: 'times', color: '#0B3B75', page: [595.28, 841.89], logo: await file('png', logo, 300, 100, 'practice/p/letterhead/logo.png') };
  assertEquals(Object.keys(await letterheadFiles(built, read)), ['logo']);
  assertEquals(await letterheadFiles({ ...built, logo: null }, read), {});
  // A file not there.
  await refused(letterheadFiles({ ...up, first: { ...first, path: 'practice/p/letterhead/gone.pdf' } }, read), 'the letterhead page was not found');
  await refused(letterheadFiles({ ...up, first: undefined }, read), 'the letterhead page is missing');
});
