// PDFs Counta makes when a document is opened in Documents: a sales document (invoice, receipt, quote, order or credit
// note) as the customer's copy shows it, a day's walk-in till receipts, and the slip for a PRN Rev360 gave. Nothing is
// stored; the same data always draws the same file. jsPDF's Helvetica covers Latin-1 only, so ₦ is written NGN.
import type { DocData } from '../components/InvoiceDoc';
import { cleanHex, inkOf, onColor } from '../components/InvoiceDoc';
import { latin1 } from './exporters';
import { amountInWords } from './format';
import { addressLines, countryName } from './countries';
import { vatPct } from './vat';
import { photoUrl } from './supabase';

const TITLE: Record<string, string> = { receipt: 'Receipt', invoice: 'Invoice', quote: 'Quotation', order: 'Order', credit_note: 'Credit note' };
const money = (n: unknown) => Number(n || 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (d?: string | null) => {
  if (!d) return '';
  const x = new Date(d.length === 10 ? d + 'T12:00:00Z' : d);
  return Number.isNaN(x.getTime()) ? d : x.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', timeZone: d.length === 10 ? 'UTC' : 'Africa/Lagos' });
};
const when = (d?: string | null) => {
  if (!d) return '';
  const x = new Date(d);
  return Number.isNaN(x.getTime()) ? d : x.toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Africa/Lagos' });
};
const time = (d?: string | null) => (d ? new Date(d).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Africa/Lagos' }) : '');
const rgb = (hex: string): [number, number, number] => { const h = cleanHex(hex).slice(1); return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]; };
const T = (v: unknown) => latin1(String(v ?? ''));

async function lib() {
  const [{ jsPDF }, { autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  return { jsPDF, autoTable };
}

// The business's logo as a data URL, fetched once a session. A logo that will not load is left out.
const logos = new Map<string, Promise<string | null>>();
function logoData(path?: string | null): Promise<string | null> {
  if (!path) return Promise.resolve(null);
  if (!logos.has(path)) {
    logos.set(path, (async () => {
      try {
        const url = photoUrl(path);
        if (!url) return null;
        const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
        if (!res.ok) return null;
        const blob = await res.blob();
        if (!/^image\/(png|jpe?g)$/.test(blob.type)) return null;
        return await new Promise<string>((ok, bad) => { const r = new FileReader(); r.onload = () => ok(String(r.result)); r.onerror = bad; r.readAsDataURL(blob); });
      } catch { return null; }
    })());
  }
  return logos.get(path)!;
}

type Doc = InstanceType<Awaited<ReturnType<typeof lib>>['jsPDF']>;
// Headings and totals line up with their column (autoTable aligns only the body by itself).
const alignHead = (cols: Record<number, { halign?: string }>) => (data: any) => {
  if ((data.section === 'head' || data.section === 'foot') && cols[data.column.index]?.halign) data.cell.styles.halign = cols[data.column.index].halign;
};
const METHOD: Record<string, string> = { cash: 'Cash', transfer: 'Transfer', pos: 'POS', card: 'Card', flutterwave: 'Flutterwave', paystack: 'Paystack', wallet: 'Wallet', other: 'Other' };
const methods = (s?: string | null) => String(s || '').split(/,\s*/).filter(Boolean).map((m) => METHOD[m] || m.replace(/_/g, ' ')).join(', ');

function footer(doc: Doc, left: string) {
  const n = doc.getNumberOfPages(), W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(156, 163, 175);
    doc.text(T(left), 40, H - 20, { maxWidth: W - 140 });
    doc.text(`Page ${i} of ${n}`, W - 40, H - 20, { align: 'right' });
  }
}

// The business at the top left: logo, name, address, contact and its tax numbers. Answers where the block ends.
async function orgBlock(doc: Doc, o: Record<string, any>, y: number): Promise<number> {
  const logo = await logoData(o.logo_path);
  if (logo) {
    try {
      const p = doc.getImageProperties(logo);
      const h = Math.min(44, p.height), w = Math.min(130, (p.width / p.height) * h);
      doc.addImage(logo, p.fileType, 40, y, w, (w / p.width) * p.height);
      y += (w / p.width) * p.height + 8;
    } catch { /* a logo jsPDF cannot read is left out */ }
  }
  doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.setTextColor(17, 24, 39);
  doc.text(T(o.name || ''), 40, y + 10); y += 16;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(75, 85, 99);
  const lines = [...String(o.address || '').split(/\n+/).map((l) => l.trim()).filter(Boolean),
    [o.phone, o.email, o.website ? String(o.website).replace(/^https?:\/\//, '') : ''].filter(Boolean).join(' · '),
    [o.tin ? `Tax ID ${String(o.tin).replace(/^(TIN|Tax ID)[\s:]*/i, '')}` : '', o.rc_number ? `RC ${String(o.rc_number).replace(/^RC[\s:]*/i, '')}` : ''].filter(Boolean).join(' · ')].filter(Boolean);
  for (const l of lines) { doc.text(T(l), 40, y + 8, { maxWidth: 300 }); y += 11; }
  return y;
}

// ------------------------------------------------------------------ a sales document
export async function salePdf(d: DocData & { status?: string; original_number?: string | null }): Promise<Blob> {
  const { jsPDF, autoTable } = await lib();
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const W = doc.internal.pageSize.getWidth();
  const o = d.org || {};
  const brand = rgb(o.brand_color || '#0072F5'), ink = rgb(inkOf(o.brand_color || '#0072F5')), on = onColor(cleanHex(o.brand_color || '#0072F5')) === '#FFFFFF' ? 255 : 17;
  const show = { tin: true, rc_number: true, vat_status: true, amount_in_words: true, ...(o.invoice_show || {}) };
  const title = TITLE[d.doc_type] || 'Invoice';
  doc.setFillColor(...brand); doc.rect(0, 0, W, 5, 'F');

  let y = await orgBlock(doc, show.tin && show.rc_number ? o : { ...o, tin: show.tin ? o.tin : null, rc_number: show.rc_number ? o.rc_number : null }, 34);
  // Title and the document's facts on the right.
  doc.setFont('helvetica', 'bold'); doc.setFontSize(20); doc.setTextColor(...ink);
  doc.text(T(title.toUpperCase()), W - 40, 52, { align: 'right' });
  const facts: [string, string][] = [[`${title} no.`, d.number], ['Date', day(d.issue_date)]];
  if (d.due_date && d.doc_type !== 'receipt') facts.push([d.doc_type === 'quote' ? 'Valid until' : 'Due', day(d.due_date)]);
  if (d.reference) facts.push(['Reference', String(d.reference)]);
  if (d.original_number) facts.push(['For', String(d.original_number)]);
  let fy = 70;
  doc.setFontSize(8.5);
  for (const [k, v] of facts) {
    doc.setFont('helvetica', 'normal'); doc.setTextColor(107, 114, 128); doc.text(T(k), W - 190, fy);
    doc.setFont('helvetica', 'bold'); doc.setTextColor(17, 24, 39); doc.text(T(v), W - 40, fy, { align: 'right' });
    fy += 12;
  }
  y = Math.max(y, fy) + 14;

  // Who it is for.
  doc.setDrawColor(229, 231, 235); doc.line(40, y, W - 40, y); y += 16;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(107, 114, 128);
  doc.text(d.doc_type === 'credit_note' ? 'CREDIT TO' : d.doc_type === 'receipt' ? 'RECEIVED FROM' : 'BILL TO', 40, y); y += 13;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5); doc.setTextColor(17, 24, 39); doc.text(T(d.customer_name || 'Walk-in customer'), 40, y); y += 13;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(75, 85, 99);
  const cust = [d.customer?.contact_person ? `Attn: ${d.customer.contact_person}` : '',
    ...addressLines({ address: d.customer_address, city: d.customer?.city, state: d.customer?.state, country: d.customer?.country || d.customer_country }),
    d.customer_email || '', d.customer_phone || '', d.customer_tin ? `Tax ID ${d.customer_tin}` : ''].filter(Boolean);
  for (const l of cust) { doc.text(T(l), 40, y, { maxWidth: 320 }); y += 11; }
  y += 8;

  const head = ['Description', 'Qty', 'Unit price', ...(show.vat_status ? ['VAT status'] : []), 'VAT', d.prices_include_vat ? 'Amount incl. VAT' : 'Amount'];
  const st = (t?: string) => (t === 'exempt' ? 1 : t === 'zero' ? 2 : 0);
  const body = (d.lines || []).map((l) => [
    T(l.description) + (Number(l.discount) > 0 ? T(`\nless ${money(l.discount)} discount`) : ''),
    T(`${Number(l.qty)}${l.unit_label && l.unit_label !== 'unit' ? ` ${l.unit_label}` : ''}`), money(l.unit_price),
    ...(show.vat_status ? [String(st(l.vat_treatment))] : []),
    l.vat_treatment === 'standard' || !l.vat_treatment ? money(l.vat) : '-',
    money(d.prices_include_vat ? l.gross : (l.net ?? l.gross)),
  ]);
  const saleCols: Record<number, any> = Object.fromEntries(head.map((h, i) => [i, i === 0 ? { cellWidth: 'auto' } : { halign: h === 'VAT status' ? 'center' : 'right', cellWidth: 72 }]));
  autoTable(doc as any, {
    startY: y, head: [head], body, theme: 'plain', margin: { left: 40, right: 40, bottom: 44 },
    styles: { font: 'helvetica', fontSize: 8.5, cellPadding: { top: 5, bottom: 5, left: 4, right: 4 }, textColor: [31, 41, 55], overflow: 'linebreak' },
    headStyles: { fillColor: brand, textColor: on, fontStyle: 'bold', fontSize: 8 },
    alternateRowStyles: { fillColor: [249, 250, 251] },
    columnStyles: saleCols as any, didParseCell: alignHead(saleCols),
  });
  y = ((doc as any).lastAutoTable?.finalY || y) + 14;

  // Totals.
  const exempt = (d.lines || []).filter((l) => l.vat_treatment === 'exempt');
  const allExempt = d.lines.length > 0 && exempt.length === d.lines.length;
  const balance = Number(d.balance ?? Number(d.total) - Number(d.amount_paid || 0) - Number(d.credited || 0));
  const owes = ['invoice', 'order'].includes(d.doc_type) && balance > 0.004 && !['void', 'cancelled'].includes(String(d.status));
  const totals: [string, string, boolean?][] = [[d.prices_include_vat ? 'Total before VAT' : 'Subtotal', money(d.subtotal)]];
  if (!allExempt) totals.push([`VAT${Number(d.vat_total) > 0 ? ` at ${vatPct(d.issue_date)}` : ''}${d.prices_include_vat ? ' (included)' : ''}`, money(d.vat_total)]);
  totals.push(['Total (NGN)', `NGN ${money(d.total)}`, true]);
  if (Number(d.amount_paid) > 0) totals.push(['Paid', money(d.amount_paid)]);
  if (Number(d.credited) > 0) totals.push(['Credited', money(d.credited)]);
  if (owes && Math.abs(balance - Number(d.total)) > 0.004) totals.push(['Balance due', `NGN ${money(balance)}`, true]);
  if (y > doc.internal.pageSize.getHeight() - 160) { doc.addPage(); y = 50; }
  for (const [k, v, strong] of totals) {
    doc.setFont('helvetica', strong ? 'bold' : 'normal'); doc.setFontSize(strong ? 10 : 8.5); doc.setTextColor(17, 24, 39);
    doc.text(T(k), W - 230, y); doc.text(T(v), W - 40, y, { align: 'right' });
    y += strong ? 15 : 12;
  }
  y += 6;
  const notes: string[] = [];
  if (show.amount_in_words) notes.push(`Amount in words: ${amountInWords(Number(d.total))}`);
  if (d.export) notes.push(`Zero-rated export. Supplied to a customer in ${countryName(d.customer?.country || d.customer_country)}. VAT is charged at 0% (VAT status 2).`);
  if (exempt.length) notes.push(allExempt ? 'This supply is exempted from VAT.' : `This supply is exempted from VAT: ${exempt.slice(0, 3).map((l) => l.description).join(', ')}${exempt.length > 3 ? ` and ${exempt.length - 3} more` : ''}.`);
  if (show.vat_status) notes.push(`VAT status: 0 VATable (${vatPct(d.issue_date)}) · 1 Exempt · 2 Zero-rated`);
  const pay = String(o.payment_details || '').trim(), terms = String(d.terms || '').trim();
  const blocks: [string, string][] = [];
  if (pay) blocks.push(['Payment details', pay]);
  if (d.notes || (terms && terms !== pay)) blocks.push(['Notes and terms', [d.notes, terms !== pay ? terms : ''].filter(Boolean).join('\n')]);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(75, 85, 99);
  for (const n of notes) {
    const lines = doc.splitTextToSize(T(n), W - 80);
    if (y + lines.length * 10 > doc.internal.pageSize.getHeight() - 50) { doc.addPage(); y = 50; }
    doc.text(lines, 40, y); y += lines.length * 10 + 3;
  }
  for (const [k, v] of blocks) {
    const lines = doc.splitTextToSize(T(v), W - 80);
    if (y + 14 + lines.length * 10 > doc.internal.pageSize.getHeight() - 50) { doc.addPage(); y = 50; }
    y += 6; doc.setFont('helvetica', 'bold'); doc.setFontSize(7.5); doc.setTextColor(107, 114, 128); doc.text(T(k.toUpperCase()), 40, y); y += 11;
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(31, 41, 55); doc.text(lines, 40, y); y += lines.length * 10.5;
  }
  // The NRS e-invoice: the QR code NRS's MBS 360 app reads, and the IRN.
  const e = d.einvoice;
  if (e?.irn && (e.signed === true || e.state === 'signed' || (e.kind === 'report' && ['waiting', 'sending'].includes(String(e.state))))) {
    if (y + 90 > doc.internal.pageSize.getHeight() - 50) { doc.addPage(); y = 50; }
    y += 8;
    let x = 40;
    if (e.qr) {
      try {
        const QR = (await import('qrcode')).default;
        doc.addImage(await QR.toDataURL(e.qr, { margin: 0, width: 240, errorCorrectionLevel: 'M' }), 'PNG', 40, y, 72, 72);
        x = 122;
      } catch { /* the IRN alone */ }
    }
    doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5); doc.setTextColor(17, 24, 39);
    doc.text(T(`NRS e-invoice${e.signed === true || e.state === 'signed' ? ', signed by NRS' : ''}`), x, y + 12);
    doc.setFont('courier', 'normal'); doc.setFontSize(8); doc.text(T(`IRN ${e.irn}`), x, y + 25);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(107, 114, 128); doc.text(T('Scan with NRS\'s MBS 360 app to check it.'), x, y + 37);
    y += e.qr ? 80 : 44;
  }
  if (o.invoice_footer) {
    const lines = doc.splitTextToSize(T(o.invoice_footer), W - 80);
    if (y + lines.length * 10 + 10 > doc.internal.pageSize.getHeight() - 40) { doc.addPage(); y = 50; }
    y += 10; doc.setFontSize(7.5); doc.setTextColor(107, 114, 128); doc.text(lines, 40, y);
  }
  if (String(d.status) === 'void') {
    const n = doc.getNumberOfPages();
    for (let i = 1; i <= n; i++) {
      doc.setPage(i); doc.setFont('helvetica', 'bold'); doc.setFontSize(80); doc.setTextColor(239, 68, 68);
      doc.text('VOID', W / 2, doc.internal.pageSize.getHeight() / 2, { align: 'center', angle: 30 });
    }
  }
  footer(doc, `${title} ${d.number} · ${o.name || ''} · made by Counta`);
  return doc.output('blob');
}

// ------------------------------------------------------------------ a day's walk-in till receipts
export type TillDay = { day: string; org: Record<string, any>; sales: { number: string; at: string; total: number; vat: number; channel?: string | null; location?: string | null;
  cashier?: string | null; paid?: string | null; lines: { description: string; qty: number; gross: number }[] }[] };

export async function tillPdf(t: TillDay): Promise<Blob> {
  const { jsPDF, autoTable } = await lib();
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const W = doc.internal.pageSize.getWidth();
  const o = t.org || {};
  const brand = rgb(o.brand_color || '#0072F5'), ink = rgb(inkOf(o.brand_color || '#0072F5')), on = onColor(cleanHex(o.brand_color || '#0072F5')) === '#FFFFFF' ? 255 : 17;
  doc.setFillColor(...brand); doc.rect(0, 0, W, 5, 'F');
  let y = await orgBlock(doc, o, 34);
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(...ink);
  doc.text('TILL RECEIPTS', W - 40, 52, { align: 'right' });
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(17, 24, 39);
  doc.text(T(day(t.day)), W - 40, 68, { align: 'right' });
  const total = t.sales.reduce((s, x) => s + Number(x.total || 0), 0), vat = t.sales.reduce((s, x) => s + Number(x.vat || 0), 0);
  doc.setFontSize(8.5); doc.setTextColor(75, 85, 99);
  doc.text(T(`${t.sales.length} ${t.sales.length === 1 ? 'sale' : 'sales'} · NGN ${money(total)} · VAT NGN ${money(vat)}`), W - 40, 82, { align: 'right' });
  y = Math.max(y, 90) + 12;
  autoTable(doc as any, {
    startY: y, theme: 'plain', margin: { left: 40, right: 40, bottom: 44 },
    head: [['Receipt', 'Time', 'Branch', 'Cashier', 'Paid by', 'VAT', 'Total']],
    body: t.sales.map((s) => [T(s.number), time(s.at), T(s.location || ''), T(s.cashier || ''), T(methods(s.paid) || s.channel || ''), money(s.vat), money(s.total)]),
    foot: [['Total', '', '', '', '', money(vat), money(total)]], showFoot: 'lastPage',
    styles: { font: 'helvetica', fontSize: 8.5, cellPadding: 4, textColor: [31, 41, 55] },
    headStyles: { fillColor: brand, textColor: on, fontStyle: 'bold', fontSize: 8 }, footStyles: { fillColor: [243, 244, 246], textColor: [17, 24, 39], fontStyle: 'bold' },
    alternateRowStyles: { fillColor: [249, 250, 251] }, columnStyles: { 5: { halign: 'right' }, 6: { halign: 'right' } }, didParseCell: alignHead({ 5: { halign: 'right' }, 6: { halign: 'right' } }),
  });
  y = ((doc as any).lastAutoTable?.finalY || y) + 22;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(17, 24, 39);
  if (y > doc.internal.pageSize.getHeight() - 90) { doc.addPage(); y = 50; }
  doc.text('What each receipt holds', 40, y); y += 8;
  const rows: any[] = [];
  for (const s of t.sales) {
    rows.push([{ content: T(`${s.number} · ${time(s.at)}`), colSpan: 2, styles: { fontStyle: 'bold', fillColor: [243, 244, 246] } }, { content: money(s.total), styles: { fontStyle: 'bold', halign: 'right', fillColor: [243, 244, 246] } }]);
    for (const l of s.lines || []) rows.push([T(l.description), { content: String(Number(l.qty)), styles: { halign: 'right' } }, { content: money(l.gross), styles: { halign: 'right' } }]);
  }
  autoTable(doc as any, {
    startY: y + 4, theme: 'plain', margin: { left: 40, right: 40, bottom: 44 }, head: [['Item', 'Qty', 'Amount']], body: rows,
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 3.5, textColor: [31, 41, 55] }, headStyles: { textColor: [107, 114, 128], fontStyle: 'bold' },
    columnStyles: { 1: { cellWidth: 50, halign: 'right' }, 2: { cellWidth: 90, halign: 'right' } }, didParseCell: alignHead({ 1: { halign: 'right' }, 2: { halign: 'right' } }),
  });
  footer(doc, `Till receipts ${day(t.day)} · ${o.name || ''} · made by Counta`);
  return doc.output('blob');
}

// ------------------------------------------------------------------ the slip for a PRN
const TAX_NAME: Record<string, string> = { vat: 'VAT', wht: 'Withholding tax', wvat: 'Withholding VAT', cit: 'Companies income tax' };
const PART: Record<string, string> = { tax: 'Tax on the return', credit_applied: 'Credit taken off', penalty: 'Penalty', interest: 'Interest',
  late_filing_penalty: 'Late filing penalty', charges: 'Payment charges' };
const STATUS: Record<string, string> = { received: 'Received from Flux', paying: 'Being paid', paid: 'Paid', needs_approval: 'Waiting for the owner\'s approval',
  confirmed: 'Paid and confirmed by Rev360', expired: 'The account expired', renewing: 'Waiting for a new account from Rev360', replaced: 'Replaced by a newer PRN',
  cancelled: 'Cancelled' };

export async function prnPdf(p: Record<string, any>): Promise<Blob> {
  const { jsPDF, autoTable } = await lib();
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const W = doc.internal.pageSize.getWidth();
  const o = p.org || {};
  const brand = rgb(o.brand_color || '#0072F5'), ink = rgb(inkOf(o.brand_color || '#0072F5'));
  doc.setFillColor(...brand); doc.rect(0, 0, W, 5, 'F');
  let y = await orgBlock(doc, o, 34);
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(...ink);
  doc.text('PRN AND PAYMENT', W - 40, 52, { align: 'right' });
  const period = p.tax === 'cit' ? `for ${p.accounting_year || String(p.period || '').slice(0, 4)}`
    : `for ${new Date(String(p.period).slice(0, 10) + 'T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })}`;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(17, 24, 39);
  doc.text(T(`${TAX_NAME[p.tax] || String(p.tax || '').toUpperCase()} ${period}`), W - 40, 68, { align: 'right' });
  y = Math.max(y, 80) + 12;
  const pay = p.payment || {};
  const rows: [string, string][] = [
    ['Payment reference number (PRN)', p.prn], ['Revenue service', p.authority], ['Amount', `NGN ${money(p.amount)}`],
    ['Pay into', [p.bank_name, p.account_number].filter(Boolean).join(', ')], ['Account name on the payment page', p.account_name],
    ['Name the bank gave for the account', p.resolved_name], ['Where it stands', STATUS[String(p.status)] || String(p.status || '').replace(/_/g, ' ')],
    ['Received from Flux', when(p.received_at)], ['Account open until', when(p.expires_at)], ['Rev360 confirmed the payment', when(p.confirmed_at)],
    ['Rev360 receipt reference', p.receipt_ref], ['Paid outside Counta', p.paid_outside ? 'Yes' : ''],
    ['Counta transfer reference', pay.reference], ['Counta transfer', [pay.status ? String(pay.status).replace(/_/g, ' ') : '', when(pay.completed_at)].filter(Boolean).join(', ')],
  ].filter(([, v]) => v != null && String(v).trim() !== '') as [string, string][];
  autoTable(doc as any, {
    startY: y, theme: 'plain', margin: { left: 40, right: 40, bottom: 44 }, body: rows.map(([k, v]) => [T(k), T(v)]),
    styles: { font: 'helvetica', fontSize: 9, cellPadding: 5, textColor: [31, 41, 55] },
    columnStyles: { 0: { cellWidth: 200, textColor: [107, 114, 128] }, 1: { fontStyle: 'bold' } }, alternateRowStyles: { fillColor: [249, 250, 251] },
  });
  y = ((doc as any).lastAutoTable?.finalY || y) + 18;
  const b = p.breakdown && typeof p.breakdown === 'object' ? p.breakdown : null;
  if (b && Object.keys(b).length) {
    doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(17, 24, 39); doc.text('What the amount is made of', 40, y);
    // In the order the amount is worked out, whatever order the stored breakdown keeps its keys in.
    const order = Object.keys(PART);
    const parts = Object.entries(b).filter(([, v]) => v != null && v !== '' && !Number.isNaN(Number(v)))
      .sort(([x], [y]) => (order.indexOf(x) < 0 ? 99 : order.indexOf(x)) - (order.indexOf(y) < 0 ? 99 : order.indexOf(y)));
    autoTable(doc as any, {
      startY: y + 6, theme: 'plain', margin: { left: 40, right: 40, bottom: 44 },
      body: parts.map(([k, v]) => [T(PART[k] || k.replace(/_/g, ' ')), { content: `${k === 'credit_applied' && Number(v) ? '- ' : ''}${money(v)}`, styles: { halign: 'right' } }]),
      foot: [['Amount to pay', { content: `NGN ${money(p.amount)}`, styles: { halign: 'right' } }]], showFoot: 'lastPage',
      styles: { font: 'helvetica', fontSize: 9, cellPadding: 5, textColor: [31, 41, 55] }, footStyles: { fillColor: [243, 244, 246], textColor: [17, 24, 39], fontStyle: 'bold' },
      columnStyles: { 0: { cellWidth: 260 } }, didParseCell: alignHead({ 1: { halign: 'right' } }),
    });
    y = ((doc as any).lastAutoTable?.finalY || y) + 18;
  }
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(107, 114, 128);
  doc.text(doc.splitTextToSize(T('Counta made this record from what TaxStreem Flux reported from Rev360 and from Counta\'s own payment. Rev360\'s receipt, when Flux sends it, is kept beside it under Payment receipts.'), W - 80), 40, y);
  footer(doc, `PRN ${p.prn} · ${o.name || ''} · made by Counta`);
  return doc.output('blob');
}
