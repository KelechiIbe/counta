// Engagement letters as blocks: numbering, references, merge fields and the amounts written in words. Plain TypeScript with
// no imports, shared by the practice edge function (the PDF a partner signs) and the browser (the portal's live preview), so
// the two always number and word a letter the same way.
//
// A body is { version: 1, blocks } (private.letter_body_ok checks it in the database). Each block has a kind: heading (level
// 1, numbered 1., 2., ...), clause (level 2, numbered 1.1 under the last heading), list (level 3, (a) under the last clause;
// level 4, (i) under the last level-3 item), paragraph (unnumbered, indented by its level) or signature (text "firm" or
// "client"). A block with a variant is only in that letter (full or involved); a block with optional is only there while
// that field is set. Numbers are never written into the text: renderModel numbers what remains. Text is plain, with
// {{field}}, sections {{#field}}...{{/field}} kept while the field is set, and references {{ref:id}} to a numbered block.

export type LetterBlock = {
  id: string;
  kind: 'heading' | 'clause' | 'paragraph' | 'list' | 'signature';
  level: number;
  text: string;
  variant?: 'full' | 'involved' | null;
  optional?: string | null;
};
export type LetterBody = { version: 1; blocks: LetterBlock[] };
export type MergeValues = Record<string, string | number | boolean | null>;
// number: the label printed beside the block (1., 1.1, (a), (i)); ref: the full reference (1, 1.1, 1.1(a), 1.1(a)(i)).
export type RenderedBlock = { id: string; kind: LetterBlock['kind']; level: number; number: string | null; ref: string | null; text: string };

// The merge fields of a letter, in the draft letter's order (private.letter_fields() in the database).
export const LETTER_FIELDS: string[] = [
  'letter.date', 'contact.title', 'contact.name', 'contact.salutation', 'client.name', 'client.address', 'client.name_upper',
  'client.reg_label', 'client.rc_number', 'client.description', 'engagement.title_upper', 'engagement.title_lower', 'engagement.start_date',
  'proposal.date', 'firm.name', 'firm.email', 'firm.phone', 'firm.city', 'fees.frequency', 'fees.amount', 'fees.amount_words', 'fees.deposit',
  'fees.deposit_words', 'fees.billing_day', 'fees.billing_period', 'fees.payment_days', 'fees.suspend_days', 'service.advisory',
  'service.bookkeeping', 'service.monthly', 'service.annual', 'service.other', 'service.other_text', 'service.days', 'partner.name',
  'partner.title', 'partner.email', 'team.assistant', 'conflicts.note', 'liability.cap_basis', 'retention.years', 'termination.notice_days',
  'termination.handover_days', 'arbitration.seat', 'signer.name', 'signer.title', 'signer.date', 'mode.full_mandate', 'signature.firm',
  'signature.client',
];

// ------------------------------------------------------------------ amounts
// An amount as a letter prints it: NGN, thousands separated by commas, two decimals (the naira sign is not in the PDF fonts).
export function nairaText(n: number): string {
  if (!Number.isFinite(n)) return '';
  const kobo = Math.round(Math.abs(n) * 100);
  const whole = String(Math.floor(kobo / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${n < 0 && kobo > 0 ? '-' : ''}NGN ${whole}.${String(kobo % 100).padStart(2, '0')}`;
}

const ONES = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
  'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
const SCALES = ['', ' thousand', ' million', ' billion', ' trillion', ' quadrillion'];

function below100(n: number): string {
  return n < 20 ? ONES[n] : TENS[Math.floor(n / 10)] + (n % 10 ? '-' + ONES[n % 10] : '');
}
function below1000(n: number): string {
  const h = Math.floor(n / 100), r = n % 100;
  if (!h) return below100(r);
  return `${ONES[h]} hundred${r ? ' and ' + below100(r) : ''}`;
}
// A whole number in British English words: 1,000,005 is "one million and five", 250,000 "two hundred and fifty thousand".
function wholeWords(n: number): string {
  if (n === 0) return 'zero';
  const groups: number[] = [];
  for (let x = n; x > 0; x = Math.floor(x / 1000)) groups.push(x % 1000);
  const parts: string[] = [];
  for (let g = groups.length - 1; g >= 0; g--) {
    if (groups[g]) parts.push(below1000(groups[g]) + (SCALES[g] ?? ''));
  }
  if (groups.length > 1 && groups[0] > 0 && groups[0] < 100) parts[parts.length - 1] = 'and ' + parts[parts.length - 1];
  return parts.join(' ');
}

// An amount in words, as a letter writes it after the figure: "two hundred and fifty thousand naira only", with kobo
// when there are any ("... naira and fifty kobo only").
export function amountWords(n: number): string {
  if (!Number.isFinite(n)) return '';
  const kobo = Math.round(Math.abs(n) * 100);
  const naira = Math.floor(kobo / 100), k = kobo % 100;
  return `${n < 0 && kobo > 0 ? 'minus ' : ''}${wholeWords(naira)} naira${k ? ` and ${below100(k)} kobo` : ''} only`;
}

// An amount given as a number or as text ("250000", "250,000.00", "NGN 250,000", "₦250,000"), or null when it is not one.
function amountOf(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v !== 'string') return null;
  const s = v.replace(/NGN|₦|,|\s/gi, '');
  return /^-?\d+(\.\d+)?$/.test(s) ? Number(s) : null;
}

// The merge values a letter is rendered with: as given, plus the values that follow from them, so they can never
// disagree: the client's name and the engagement's title in capitals, the fee and the deposit as NGN amounts with their
// words. A deposit of nothing leaves the deposit out (its clause and its mention drop).
export function deriveMerge(raw: MergeValues): MergeValues {
  const m: MergeValues = { ...raw };
  const name = raw['client.name'];
  if (typeof name === 'string' && name.trim()) m['client.name_upper'] = name.trim().toUpperCase();
  const title = raw['engagement.title_lower'];
  if (typeof title === 'string' && title.trim()) m['engagement.title_upper'] = title.trim().toUpperCase();
  const fee = amountOf(raw['fees.amount']);
  if (fee !== null) {
    m['fees.amount'] = nairaText(fee);
    m['fees.amount_words'] = amountWords(fee);
  }
  const deposit = amountOf(raw['fees.deposit']);
  if (deposit !== null) {
    m['fees.deposit'] = deposit > 0 ? nairaText(deposit) : null;
    m['fees.deposit_words'] = deposit > 0 ? amountWords(deposit) : null;
  }
  return m;
}

// ------------------------------------------------------------------ rendering
// Set: yes, a number other than 0, or text that is not blank.
function isSet(v: unknown): boolean {
  if (v === null || v === undefined || v === false) return false;
  if (typeof v === 'number') return v !== 0 && !Number.isNaN(v);
  if (typeof v === 'string') return v.trim() !== '';
  return true;
}
function valueText(v: unknown): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'boolean') return v ? 'yes' : 'no';
  return String(v);
}

function alpha(n: number): string {
  let s = '';
  for (let x = n; x > 0; x = Math.floor((x - 1) / 26)) s = String.fromCharCode(97 + ((x - 1) % 26)) + s;
  return s;
}
function roman(n: number): string {
  const table: [number, string][] = [[1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'], [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'],
    [4, 'iv'], [1, 'i']];
  let s = '', x = n;
  for (const [v, r] of table) while (x >= v) { s += r; x -= v; }
  return s;
}

// The innermost section, {{#field}}...{{/field}} with no other section tag inside.
const SECTION = /\{\{#([^{}]+)\}\}((?:(?!\{\{[#/])[\s\S])*?)\{\{\/\1\}\}/g;

// The letter as it is read: the blocks of this variant whose optional field is set, numbered, with sections, references
// and fields filled in. A reference to a block that is not in this letter (dropped with its service, or not numbered) is
// an error the partner must fix before signing: "Reference to a paragraph that is not in this letter: <id>".
export function renderModel(body: LetterBody, merge: MergeValues, variant: 'full' | 'involved'): RenderedBlock[] {
  if (!body || !Array.isArray(body.blocks)) throw new Error('The letter is not in the expected form.');
  const kept = body.blocks.filter((b) => (b.variant == null || b.variant === variant) && (b.optional == null || isSet(merge[b.optional])));

  let h = 0, c = 0, a = 0, i = 0;
  let headingRef = '', clauseRef = '', itemRef = '';
  const numbered = kept.map((b): RenderedBlock => {
    let number: string | null = null, ref: string | null = null;
    if (b.kind === 'heading') {
      h++; c = 0; a = 0; i = 0;
      headingRef = String(h); clauseRef = ''; itemRef = '';
      number = `${h}.`; ref = headingRef;
    } else if (b.kind === 'clause') {
      c++; a = 0; i = 0;
      clauseRef = `${h}.${c}`; itemRef = '';
      number = clauseRef; ref = clauseRef;
    } else if (b.kind === 'list' && b.level <= 3) {
      a++; i = 0;
      number = `(${alpha(a)})`;
      itemRef = `${clauseRef || headingRef}${number}`; ref = itemRef;
    } else if (b.kind === 'list') {
      i++;
      number = `(${roman(i)})`;
      ref = `${itemRef || clauseRef || headingRef}${number}`;
    }
    return { id: b.id, kind: b.kind, level: b.level, number, ref, text: String(b.text ?? '') };
  });

  const refs = new Map(numbered.map((b) => [b.id, b.ref]));
  return numbered.map((b) => {
    if (b.kind === 'signature') return b;
    let t = b.text;
    // Sections first, innermost out, so a reference inside a section that drops out is never looked up.
    for (let before = ''; before !== t;) {
      before = t;
      t = t.replace(SECTION, (_m, name: string, inner: string) => (isSet(merge[name.trim()]) ? inner : ''));
    }
    t = t.replace(/\{\{[#/][^{}]*\}\}/g, '');
    t = t.replace(/\{\{ref:([^{}]+)\}\}/g, (_m, id: string) => {
      const r = refs.get(id.trim());
      if (!r) throw new Error(`Reference to a paragraph that is not in this letter: ${id.trim()}`);
      return r;
    });
    // Fields last, in one pass, so nothing a value says is read as a tag.
    t = t.replace(/\{\{([^{}]+)\}\}/g, (_m, name: string) => valueText(merge[name.trim()]));
    // Lines left empty by fields not given (an addressee without a title) go.
    t = t.split('\n').map((l) => l.replace(/[ \t]+$/, '')).filter((l) => l.trim() !== '').join('\n').trim();
    return { ...b, text: t };
  });
}

// ------------------------------------------------------------------ Word import
// A firm's own letter as a Word file (word/document.xml, read out of the .docx in the browser) turned into blocks the
// database checks like any other body. Styles give the shape: Heading1 or Title a heading, Heading2 a clause, a numbered
// paragraph (w:numPr) a list item at its level (0 → level 3, deeper → level 4), anything else a paragraph. Numbers written
// into the text (1., 1.1, (a), (iv)) go, because the letter numbers itself; angle brackets go; empty paragraphs are skipped.
const XML_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
function xmlText(s: string): string {
  return s.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, (_m, e: string) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : XML_ENTITIES[e]);
}

export function docxXmlToBlocks(xml: string): LetterBody {
  const blocks: LetterBlock[] = [];
  const para = /<w:p(?=[\s>/])(?:[^>]*\/>|[^>]*>([\s\S]*?)<\/w:p>)/g;
  let m: RegExpExecArray | null;
  while ((m = para.exec(xml)) !== null) {
    const inner = m[1] || '';
    // Tabs and line breaks inside a paragraph read as spaces.
    const runs = inner.replace(/<w:(?:tab|br|cr)\b[^>]*\/>/g, '<w:t> </w:t>');
    let text = '';
    const t = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/g;
    let r: RegExpExecArray | null;
    while ((r = t.exec(runs)) !== null) text += xmlText(r[1]);
    text = text.replace(/[<>]/g, '').replace(/\s+/g, ' ').trim()
      .replace(/^\d+(\.\d+)*\.?\s+/, '').replace(/^\([a-z]+\)\s+/, '').replace(/^\([ivx]+\)\s+/, '').trim();
    if (!text) continue;
    const style = /<w:pStyle\b[^>]*w:val="([^"]+)"/.exec(inner)?.[1] || '';
    const numbered = /<w:numPr\b/.test(inner);
    const ilvl = Number(/<w:ilvl\b[^>]*w:val="(\d+)"/.exec(inner)?.[1] ?? 0);
    let kind: LetterBlock['kind'] = 'paragraph', level = 1;
    if (/^(Heading1|Title)$/i.test(style)) { kind = 'heading'; level = 1; }
    else if (/^Heading2$/i.test(style)) { kind = 'clause'; level = 2; }
    else if (numbered) { kind = 'list'; level = ilvl <= 0 ? 3 : 4; }
    blocks.push({ id: `b${blocks.length + 1}`, kind, level, text });
  }
  return { version: 1, blocks };
}
