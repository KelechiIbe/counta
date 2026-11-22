// The daily report: the day's figures (from svc_daily_report, each part only as the person's role sees it) as a one or two
// page PDF, with a short caption for WhatsApp and the same lines for the email. pdf-lib's standard fonts only hold Windows
// Latin characters, so all text goes through pdfSafe (the naira sign becomes NGN), as in practice/pdf.ts.
import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';

export type Report = {
  id: string; kind: 'scheduled' | 'asked'; day: string; org_id: string;
  business: { name: string; brand_color?: string | null; white_label?: boolean; timezone?: string };
  person: { name?: string | null; email?: string | null; whatsapp?: string | null; link_id?: string | null };
  channels: { email: boolean; whatsapp: boolean }; app_url: string; data: Record<string, any>;
};
type Row = [string, string];
export type Section = { heading: string; rows: Row[]; list?: string[] };

const n2 = (v: unknown) => {
  const n = Number(v);
  return (n < 0 ? '-₦' : '₦') + Math.abs(Number.isFinite(n) ? n : 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
};
const n0 = (v: unknown) => Number(v || 0).toLocaleString('en-NG');
const pl = (n: number, one: string, many = one + 's') => `${n0(n)} ${n === 1 ? one : many}`;
export const dayWords = (d: string) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });
const shortDay = (d: string) => new Date(String(d).slice(0, 10) + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const METHOD: Record<string, string> = { cash: 'Cash', transfer: 'Transfers', card: 'Card', pos: 'POS', flutterwave: 'Online payments', rail: 'Online payments', cheque: 'Cheques', other: 'Other' };
const MOVE: Record<string, string> = { sale: 'Sold', voice_sale: 'Sold by voice', receipt: 'Received from suppliers', transfer_out: 'Sent to other branches',
  transfer_in: 'Received from other branches', adjustment: 'Count differences', write_off: 'Written off', issue: 'Issued to jobs', issue_return: 'Returned from jobs',
  production_in: 'Made', sale_return: 'Returned by customers', purchase_return: 'Returned to suppliers', opening: 'Opening stock', quarantine: 'Set aside' };

// The report's parts, in order. Each appears only when the person's role sees it.
export function sections(d: Record<string, any>): Section[] {
  const out: Section[] = [];
  if (d.sales) {
    const s = d.sales, prev = Number(s.previous_day || 0), tot = Number(s.total || 0);
    const change = prev > 0 ? Math.round(((tot - prev) / prev) * 100) : null;
    out.push({ heading: 'Sales', rows: [
      ['Sales recorded', `${pl(Number(s.count || 0), 'sale')} (${pl(Number(s.receipts || 0), 'receipt')}, ${pl(Number(s.invoices || 0), 'invoice')})`],
      ['Value, VAT included', n2(tot)],
      ['The day before', `${n2(prev)}${change != null ? ` (${change >= 0 ? 'up' : 'down'} ${Math.abs(change)}%)` : ''}`],
      ['VAT on sales', n2(s.vat)],
      ['Invoices paid in full today', n0(s.paid_in_full)],
      ['Overdue invoices', `${n0(s.overdue?.count)}, ${n2(s.overdue?.owed)} owed`],
    ], list: (s.top || []).map((t: any) => `${t.name}: ${Number(t.qty).toLocaleString('en-NG')} sold, ${n2(t.value)}`) });
  }
  if (d.money) {
    const m = d.money;
    const ins = Object.entries(m.in || {}).map(([k, v]) => [`In by ${(METHOD[k] || k).toLowerCase()}`, n2(v)] as Row);
    out.push({ heading: 'Money', rows: [['Money in', n2(m.in_total)], ...ins, ['Bills paid', n2(m.out_bills)], ['Other payments out', n2(m.out_payouts)],
      ['Cash and bank in the books now', n2(m.cash_and_bank)], ['Payments waiting for approval', n0(m.payouts_waiting)]] });
  }
  if (d.orders) {
    const o = d.orders;
    out.push({ heading: 'Orders and deliveries', rows: [['New orders', `${n0(o.new?.count)}, ${n2(o.new?.total)}`], ['Orders waiting to be confirmed', n0(o.to_confirm)],
      ['Deliveries dispatched today', n0(o.dispatched)], ['Delivered today', n0(o.delivered)], ['Waiting to go', n0(o.waiting)], ['Failed in the last week', n0(o.failed)]] });
  }
  if (d.stock) {
    const k = d.stock;
    const moves = Object.entries(k.moves || {}).map(([t, c]) => [MOVE[t] || t.replace(/_/g, ' '), pl(Number(c), 'movement')] as Row);
    out.push({ heading: 'Stock', rows: [...(moves.length ? moves : [['Stock movements', 'none'] as Row]),
      ...(k.received_value != null ? [['Value received from suppliers', n2(k.received_value)] as Row] : []),
      ['Counts waiting for approval', n0(k.counts_waiting)], ['Transfers on the way', n0(k.transfers_waiting)]],
      list: [...(k.out || []).map((x: string) => `Out of stock: ${x}`), ...(k.low || []).map((x: string) => `Running low: ${x}`)] });
  }
  if (d.books) {
    const b = d.books;
    out.push({ heading: 'Books', rows: [['Questions in the books inbox', n0(b.questions)], ['Posted by Atlas today', n0(b.posted_by_atlas)],
      ['Supplier bills to approve', n0(b.bills_to_approve)], ...(b.approvals != null ? [['Requests waiting for approval', n0(b.approvals)] as Row] : [])] });
  }
  if (d.tax) {
    const t: any[] = d.tax || [];
    out.push({ heading: 'Tax coming due', rows: t.length ? t.map((x) => [`${x.label}, ${new Date(String(x.period).slice(0, 10) + 'T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })}`,
      `due ${shortDay(x.due)}${x.amount != null ? `, ${n2(x.amount)}` : ''}`] as Row) : [['Nothing due in the next 30 days', '']] });
  }
  if (d.people) {
    const p = d.people;
    out.push({ heading: 'Who did what', rows: [['Actions recorded', n0(p.actions)], ...(p.by || []).map((x: any) => [x.name, pl(Number(x.actions), 'action')] as Row)] });
  }
  return out;
}

// One short paragraph for the WhatsApp caption and the top of the email.
export function headline(r: Report): string[] {
  const d = r.data || {}, bits: string[] = [];
  if (d.sales) bits.push(`Sales ${n2(d.sales.total)} from ${pl(Number(d.sales.count || 0), 'sale')}.`);
  if (d.money) bits.push(`Money in ${n2(d.money.in_total)}, out ${n2(Number(d.money.out_bills || 0) + Number(d.money.out_payouts || 0))}.`);
  if (d.orders && Number(d.orders.to_confirm) > 0) bits.push(`${pl(Number(d.orders.to_confirm), 'order')} to confirm.`);
  if (d.books && Number(d.books.questions) > 0) bits.push(`${pl(Number(d.books.questions), 'question')} in the books inbox.`);
  if (d.stock && (d.stock.out || []).length) bits.push(`${pl((d.stock.out || []).length, 'product')} out of stock.`);
  return bits;
}

// ------------------------------------------------------------------ text the standard fonts can draw (as practice/pdf.ts)
export function pdfSafe(s: string): string {
  const t = String(s ?? '').replace(/\u20a6\s*/g, 'NGN ').replace(/[\u2018\u2019\u201a\u201b]/g, "'").replace(/[\u201c\u201d\u201e\u201f]/g, '"')
    .replace(/[\u2010-\u2015\u2212]/g, '-').replace(/\u2026/g, '...').replace(/[\t\u00a0\u2000-\u200a\u202f]/g, ' ');
  let out = '';
  for (const ch of t) {
    const c = ch.codePointAt(0)!;
    if ((c >= 0x20 && c <= 0x7e) || ch === '\n') { out += ch; continue; }
    if (/\p{M}|\p{C}/u.test(ch)) continue;
    const folded = ch.normalize('NFD').replace(/\p{M}/gu, '');
    out += /^[\x20-\x7e]+$/.test(folded) ? folded : (c >= 0xa0 && c <= 0xff ? ch : '?');
  }
  return out;
}

const A4: [number, number] = [595.28, 841.89];
const M = 40;
const INK = rgb(0.1, 0.12, 0.15), MUTED = rgb(0.4, 0.43, 0.47), RULE = rgb(0.85, 0.87, 0.9);
function colour(hex?: string | null) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(hex || ''));
  return m ? rgb(parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255) : rgb(0, 0.447, 0.961);
}
// Text broken into lines that fit a width, at most `max` of them (the last cut with an ellipsis).
function wrap(t: string, f: PDFFont, size: number, w: number, max: number) {
  const lines: string[] = [];
  let cur = '';
  for (const word of pdfSafe(t).split(/\s+/).filter(Boolean)) {
    const next = cur ? `${cur} ${word}` : word;
    if (f.widthOfTextAtSize(next, size) <= w || !cur) { cur = next; continue; }
    lines.push(cur);
    cur = word;
  }
  if (cur) lines.push(cur);
  return lines.length > max ? [...lines.slice(0, max - 1), fit(lines.slice(max - 1).join(' '), f, size, w)] : lines.map((l) => fit(l, f, size, w));
}
// Text cut to fit a width, with an ellipsis.
function fit(t: string, f: PDFFont, size: number, w: number) {
  let s = pdfSafe(t);
  if (f.widthOfTextAtSize(s, size) <= w) return s;
  while (s.length > 1 && f.widthOfTextAtSize(s + '...', size) > w) s = s.slice(0, -1);
  return s + '...';
}

export async function reportPdf(r: Report, at = new Date()): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const reg = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const brand = colour(r.business.brand_color);
  doc.setTitle(pdfSafe(`Daily report ${r.day} - ${r.business.name}`));
  doc.setAuthor(pdfSafe(r.business.name));
  doc.setProducer(r.business.white_label ? pdfSafe(r.business.name) : 'Counta');
  let page: PDFPage = doc.addPage(A4);
  let y = A4[1] - M;
  const w = A4[0] - 2 * M;
  const time = at.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: r.business.timezone || 'Africa/Lagos' });
  const footer = (p: PDFPage) => p.drawText(pdfSafe(`${r.business.white_label ? 'Prepared' : 'Prepared by Counta'} at ${time} on ${dayWords(r.day)}. Figures are from the books as they stood then.`),
    { x: M, y: 28, size: 8, font: reg, color: MUTED });
  const need = (h: number) => {
    if (y - h >= M + 6) return;
    footer(page);
    page = doc.addPage(A4);
    y = A4[1] - M;
  };
  page.drawText(fit(r.business.name, bold, 18, w), { x: M, y, size: 18, font: bold, color: brand });
  y -= 22;
  page.drawText(pdfSafe(`Daily report for ${dayWords(r.day)}`), { x: M, y, size: 12, font: reg, color: INK });
  y -= 15;
  if (r.person?.name) { page.drawText(fit(`For ${r.person.name}`, reg, 9, w), { x: M, y, size: 9, font: reg, color: MUTED }); y -= 12; }
  const head = wrap(headline(r).join(' '), reg, 10, w - 16, 3);
  if (head.length) {
    y -= 6;
    const h = 12 + head.length * 13;
    page.drawRectangle({ x: M, y: y - h + 4, width: w, height: h, color: rgb(0.96, 0.97, 0.98) });
    head.forEach((line, i) => page.drawText(line, { x: M + 8, y: y - 13 - i * 13, size: 10, font: reg, color: INK }));
    y -= h + 8;
  }
  // A normal day fits one page: 9.5 point rows 13 points apart.
  for (const s of sections(r.data || {})) {
    need(36 + s.rows.length * 13);
    y -= 6;
    page.drawText(pdfSafe(s.heading), { x: M, y, size: 11, font: bold, color: brand });
    y -= 5;
    page.drawLine({ start: { x: M, y }, end: { x: M + w, y }, thickness: 0.6, color: RULE });
    y -= 13;
    for (const [label, value] of s.rows) {
      need(13);
      page.drawText(fit(label, reg, 9.5, w * 0.58), { x: M, y, size: 9.5, font: reg, color: INK });
      const v = fit(value, bold, 9.5, w * 0.4);
      page.drawText(v, { x: M + w - bold.widthOfTextAtSize(v, 9.5), y, size: 9.5, font: bold, color: INK });
      y -= 13;
    }
    for (const item of (s.list || []).slice(0, 10)) {
      need(12);
      page.drawText(fit(`- ${item}`, reg, 8.5, w - 6), { x: M + 6, y, size: 8.5, font: reg, color: MUTED });
      y -= 12;
    }
    y -= 3;
  }
  // The way back to Counta sits just above the footer of the last page, so it never takes a page of its own.
  page.drawText(fit(`Open Counta for the detail: ${r.app_url.replace(/\/$/, '')}/home`, reg, 9, w), { x: M, y: 40, size: 9, font: reg, color: MUTED });
  footer(page);
  return await doc.save();
}

export function reportFileName(r: Report) {
  const safe = pdfSafe(r.business.name).replace(/[^A-Za-z0-9 ]+/g, '').trim().replace(/\s+/g, '-').slice(0, 40) || 'Business';
  return `Daily-report-${safe}-${r.day}.pdf`;
}

export function reportCaption(r: Report) {
  const head = headline(r);
  return [`*Daily report, ${dayWords(r.day)}*`, head.join(' ') || 'Here is the day in Counta.'].join('\n').slice(0, 900);
}
