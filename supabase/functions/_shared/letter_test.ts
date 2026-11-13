import { assert, assertEquals } from 'jsr:@std/assert@1';
import { deriveMerge, docxXmlToBlocks, type LetterBody, renderModel } from './letter.ts';
// The default letter as private.letter_default_body() returns it (Task 20 regenerates the file and compares it with the SQL).
import bodyJson from './default_letter.json' with { type: 'json' };

const body = bodyJson as unknown as LetterBody;

Deno.test('render_numbering_full', () => {
  const r = renderModel(body, { 'service.advisory': true, 'service.bookkeeping': true }, 'full');
  assertEquals(r.find((b) => b.id === 'scope')!.number, '1.');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(b)');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.ref, '1.1(b)');
  assertEquals(r.find((b) => b.id === 'term')!.ref, '13');
  assert(r.some((b) => b.text.includes('paragraph 1.1(b) applies')));
});
Deno.test('render_renumbers_when_services_off', () => {
  const r = renderModel(body, { 'service.advisory': false, 'service.bookkeeping': true }, 'involved');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(a)');
  assert(r.some((b) => b.text.includes('paragraph 1.1(a) applies')));
  assert(!r.some((b) => b.text.startsWith('Full mandate.')));            // 2.2 dropped, 2.3 becomes 2.2
  assert(!renderModel(body, { 'service.bookkeeping': false }, 'full').some((b) => b.text.includes('paragraph 1.1(')));
});
Deno.test('render_inline_and_fields', () => {
  const t = renderModel(body, { 'client.name': 'Ada Foods Ltd', 'proposal.date': '' }, 'involved').map((b) => b.text).join('\n');
  assert(t.includes('act for Ada Foods Ltd') && !t.includes('our proposal dated'));
});
Deno.test('derive_merge_amounts', () => {
  const m = deriveMerge({ 'fees.amount': 250000, 'client.name': 'Ada Foods Ltd' });
  assertEquals(m['fees.amount'], 'NGN 250,000.00'); assertEquals(m['fees.amount_words'], 'two hundred and fifty thousand naira only'); assertEquals(m['client.name_upper'], 'ADA FOODS LTD');
});

Deno.test('docx_xml_to_blocks', () => {
  const xml = '<w:document><w:body>'
    + '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>1. Scope</w:t></w:r></w:p>'
    + '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>(a) Keep the </w:t></w:r><w:r><w:t>{{client.</w:t></w:r><w:r><w:t>name}} books</w:t></w:r></w:p>'
    + '<w:p/></w:body></w:document>';
  const b = docxXmlToBlocks(xml);
  assertEquals(b.blocks.map((x) => [x.kind, x.level, x.text]), [['heading', 1, 'Scope'], ['list', 3, 'Keep the {{client.name}} books']]);
});

Deno.test('docx_xml_to_blocks_entities_levels_and_paragraphs', () => {
  const xml = '<w:body>'
    + '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t xml:space="preserve">1.1 Fees &amp; expenses</w:t></w:r></w:p>'
    + '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>(iv) Nested</w:t><w:tab/><w:t>item &lt;b&gt;</w:t></w:r></w:p>'
    + '<w:p><w:r><w:t>Plain text</w:t></w:r></w:p></w:body>';
  const b = docxXmlToBlocks(xml);
  assertEquals(b.blocks.map((x) => [x.id, x.kind, x.level, x.text]),
    [['b1', 'clause', 2, 'Fees & expenses'], ['b2', 'list', 4, 'Nested item b'], ['b3', 'paragraph', 1, 'Plain text']]);
});
