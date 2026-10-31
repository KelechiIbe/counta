// A branded A4 document (invoice, receipt, quote, order or credit note) in one of three templates:
// Classic, Modern or Minimal. The same component draws the customer's copy, the back-office preview,
// the print and PDF, and the template previews in Settings.
import { useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { photoUrl } from '../lib/supabase';
import { amountInWords, fmtDay } from '../lib/format';
import { addressLines, countryName } from '../lib/countries';
import { useVatRate, vatPct } from '../lib/vat';
import { EinvoiceStamp, showStamp } from './Einvoice';

export type Template = 'classic' | 'modern' | 'minimal';
export const TEMPLATES: { id: Template; name: string; blurb: string }[] = [
  { id: 'classic', name: 'Classic', blurb: 'Logo and details on the left, the title in your colour, a tinted table.' },
  { id: 'modern', name: 'Modern', blurb: 'A band of your colour across the top and a bold total.' },
  { id: 'minimal', name: 'Minimal', blurb: 'Quiet and spacious. Your colour on the title and total only.' },
];
const TITLE: Record<string, string> = { receipt: 'Receipt', invoice: 'Invoice', quote: 'Quotation', order: 'Order', credit_note: 'Credit note' };

// ------------------------------------------------------------------ colour helpers
export function cleanHex(h?: string | null): string {
  const v = String(h || '').trim();
  return /^#[0-9a-f]{6}$/i.test(v) ? v.toUpperCase() : '#0072F5';
}
export function tint(hex: string, alpha: number): string {
  const h = cleanHex(hex);
  return `rgba(${parseInt(h.slice(1, 3), 16)}, ${parseInt(h.slice(3, 5), 16)}, ${parseInt(h.slice(5, 7), 16)}, ${alpha})`;
}
// Black or white, whichever reads better on the colour.
export function onColor(hex: string): string {
  const h = cleanHex(hex);
  const [r, g, b] = [1, 3, 5].map((i) => {
    const c = parseInt(h.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  const L = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return L > 0.42 ? '#111827' : '#FFFFFF';
}
// A darker shade of the colour for text on white, so pale brand colours stay legible.
export function inkOf(hex: string): string {
  const h = cleanHex(hex);
  if (onColor(h) === '#FFFFFF') return h;
  const d = (i: number) => Math.round(parseInt(h.slice(i, i + 2), 16) * 0.55).toString(16).padStart(2, '0');
  return `#${d(1)}${d(3)}${d(5)}`;
}

const money = (n: unknown) => Number(n || 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const statusOf = (t?: string) => (t === 'exempt' ? 1 : t === 'zero' ? 2 : 0);
const STATUS_LABEL = ['VATable', 'Exempt', 'Zero-rated'];

export interface DocData {
  doc_type: string; number: string; status?: string; issue_date: string; due_date?: string | null; reference?: string | null;
  customer_name?: string | null; customer_tin?: string | null; customer_address?: string | null; customer_email?: string | null; customer_phone?: string | null;
  customer?: { city?: string | null; state?: string | null; country?: string | null; contact_person?: string | null } | null;
  export?: boolean; customer_country?: string | null; prices_include_vat?: boolean;
  lines: { description: string; qty: number; unit_label?: string; unit_price: number; discount?: number; vat_treatment?: string; vat?: number; net?: number; gross: number; kind?: string }[];
  subtotal: number; vat_total: number; total: number; amount_paid?: number; credited?: number; balance?: number; notes?: string | null; terms?: string | null;
  org: Record<string, any>;
  // The NRS e-invoice: its IRN and QR code, once the document may reach the buyer.
  einvoice?: { irn?: string | null; qr?: string | null; state?: string; kind?: string; signed?: boolean } | null;
}

export function InvoiceDoc({ d, template, style, fixed }: { d: DocData; template?: Template; style?: CSSProperties; fixed?: boolean }) {
  useVatRate();
  const o = d.org || {};
  const t: Template = template || (['classic', 'modern', 'minimal'].includes(o.invoice_template) ? o.invoice_template : 'classic');
  const brand = cleanHex(o.brand_color);
  const ink = inkOf(brand);
  const show = { tin: true, rc_number: true, vat_status: true, amount_in_words: true, signature: false, ...(o.invoice_show || {}) };
  const logo = o.logo_path ? photoUrl(o.logo_path) : null;
  const title = TITLE[d.doc_type] || 'Invoice';
  const custLines = addressLines({ address: d.customer_address, city: d.customer?.city, state: d.customer?.state, country: d.customer?.country || d.customer_country });
  const orgIds = [show.tin && o.tin ? `Tax ID ${String(o.tin).replace(/^(TIN|Tax ID)[\s:]*/i, '')}` : '', show.rc_number && o.rc_number ? `RC ${String(o.rc_number).replace(/^RC[\s:]*/i, '')}` : ''].filter(Boolean);
  const orgContact = [o.phone, o.email, o.website ? String(o.website).replace(/^https?:\/\//, '') : ''].filter(Boolean);
  const balance = Number(d.balance ?? Number(d.total) - Number(d.amount_paid || 0) - Number(d.credited || 0));
  const pay = String(o.payment_details || '').trim();
  const terms = String(d.terms || '').trim();
  const owes = ['invoice', 'order'].includes(d.doc_type) && balance > 0.004 && !['void', 'cancelled'].includes(String(d.status));
  const facts: [string, ReactNode][] = [
    [`${title} no.`, d.number],
    ['Date', fmtDay(d.issue_date)],
    ...(d.due_date && d.doc_type !== 'receipt' ? [[d.doc_type === 'quote' ? 'Valid until' : 'Due', fmtDay(d.due_date)] as [string, ReactNode]] : []),
    ...(d.reference ? [['Reference', d.reference] as [string, ReactNode]] : []),
  ];

  const billTo = (
    <div className="inv-bill">
      <div className="inv-k">{d.doc_type === 'credit_note' ? 'Credit to' : d.doc_type === 'receipt' ? 'Received from' : 'Bill to'}</div>
      <div className="inv-cust">{d.customer_name || 'Walk-in customer'}</div>
      {d.customer?.contact_person && <div>Attn: {d.customer.contact_person}</div>}
      {custLines.map((l, i) => <div key={i}>{l}</div>)}
      {d.customer_email && <div>{d.customer_email}</div>}
      {d.customer_phone && <div>{d.customer_phone}</div>}
      {d.customer_tin && <div>Tax ID {d.customer_tin}</div>}
    </div>
  );
  const factsBlock = (
    <div className="inv-facts">
      {facts.map(([k, v]) => <div key={k} className="inv-fact"><span className="inv-k">{k}</span><span>{v}</span></div>)}
    </div>
  );
  const table = (
    <table className="inv-table">
      <thead>
        <tr>
          <th style={{ width: '46%' }}>Description</th>
          <th className="r">Qty</th>
          <th className="r">Unit price</th>
          {show.vat_status && <th className="c" title="0 VATable · 1 Exempt · 2 Zero-rated">VAT status</th>}
          <th className="r">VAT</th>
          <th className="r">{d.prices_include_vat ? 'Amount incl. VAT' : 'Amount'}</th>
        </tr>
      </thead>
      <tbody>
        {d.lines.map((l, i) => (
          <tr key={i}>
            <td>
              <div className="inv-desc">{l.description}</div>
              <div className="inv-sub">
                <span className="inv-m">{Number(l.qty)} {l.unit_label || ''} × {money(l.unit_price)}</span>
                {Number(l.discount) > 0 && <span> · less {money(l.discount)} discount</span>}
              </div>
            </td>
            <td className="r inv-d">{Number(l.qty)} {l.unit_label && l.unit_label !== 'unit' ? <span className="inv-u">{l.unit_label}</span> : null}</td>
            <td className="r inv-d">{money(l.unit_price)}</td>
            {show.vat_status && <td className="c"><span className="inv-vs" title={STATUS_LABEL[statusOf(l.vat_treatment)]}>{statusOf(l.vat_treatment)}</span></td>}
            <td className="r inv-d">{l.vat_treatment === 'standard' || !l.vat_treatment ? money(l.vat) : '–'}</td>
            <td className="r">{money(d.prices_include_vat ? l.gross : (l.net ?? l.gross))}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
  // An exempt supply carries no VAT line and says so (VAT rule book, exempt supplies, rule 2).
  const exemptLines = d.lines.filter((l) => l.vat_treatment === 'exempt');
  const allExempt = d.lines.length > 0 && exemptLines.length === d.lines.length;
  const exemptNote = !exemptLines.length ? null : allExempt ? 'This supply is exempted from VAT.'
    : `This supply is exempted from VAT: ${exemptLines.slice(0, 3).map((l) => l.description).join(', ')}${exemptLines.length > 3 ? ` and ${exemptLines.length - 3} more` : ''}.`;
  const totals = (
    <div className="inv-totals">
      <div className="inv-tr"><span>{d.prices_include_vat ? 'Total before VAT' : 'Subtotal'}</span><span>{money(d.subtotal)}</span></div>
      {!allExempt && <div className="inv-tr"><span>VAT{Number(d.vat_total) > 0 ? ` at ${vatPct(d.issue_date)}` : ''}{d.prices_include_vat ? ' (included)' : ''}</span><span>{money(d.vat_total)}</span></div>}
      <div className="inv-tr inv-total"><span>Total (NGN)</span><span>₦{money(d.total)}</span></div>
      {Number(d.amount_paid) > 0 && <div className="inv-tr"><span>Paid</span><span>{money(d.amount_paid)}</span></div>}
      {Number(d.credited) > 0 && <div className="inv-tr"><span>Credited</span><span>{money(d.credited)}</span></div>}
      {owes && Math.abs(balance - Number(d.total)) > 0.004 && <div className="inv-tr inv-due"><span>Balance due</span><span>₦{money(balance)}</span></div>}
    </div>
  );
  const afterTable = (
    <>
      {show.amount_in_words && <div className="inv-words"><span className="inv-k">Amount in words</span> {amountInWords(Number(d.total))}</div>}
      {d.export && (
        <div className="inv-note">
          <b>Zero-rated export.</b> Supplied to a customer in {countryName(d.customer?.country || d.customer_country)}. VAT is charged at 0% (VAT status 2).
        </div>
      )}
      {exemptNote && <div className="inv-note">{exemptNote}</div>}
      {show.vat_status && <div className="inv-legend">VAT status: 0 VATable ({vatPct(d.issue_date)}) · 1 Exempt · 2 Zero-rated</div>}
      {(pay || terms || d.notes) && (
        <div className="inv-cols">
          {pay && <div className="inv-box"><div className="inv-k">Payment details</div><div className="inv-pre">{pay}</div></div>}
          {(terms && terms !== pay) || d.notes ? (
            <div className="inv-box">
              <div className="inv-k">Notes and terms</div>
              {d.notes && <div className="inv-pre">{d.notes}</div>}
              {terms && terms !== pay && <div className="inv-pre">{terms}</div>}
            </div>
          ) : null}
        </div>
      )}
      {show.signature && (
        <div className="inv-sign">
          <div className="inv-sigline" />
          <div>Authorised signatory, for {o.name}</div>
        </div>
      )}
      {d.einvoice && showStamp(d.einvoice) && (
        <div className="inv-einv" style={{ margin: '14px 0 4px' }}>
          <EinvoiceStamp irn={String(d.einvoice.irn)} qr={d.einvoice.qr} signed={d.einvoice.signed === true || d.einvoice.state === 'signed'} size={88} />
        </div>
      )}
      <div className="inv-foot">
        {o.invoice_footer && <div className="inv-pre">{o.invoice_footer}</div>}
        <div>{[o.name, ...orgIds, o.website ? String(o.website).replace(/^https?:\/\//, '') : ''].filter(Boolean).join(' · ')}</div>
      </div>
    </>
  );
  const vars = { '--b': brand, '--bi': ink, '--bt': tint(brand, 0.08), '--bt2': tint(brand, 0.16), '--on': onColor(brand) } as CSSProperties;
  const logoImg = (size: number) => logo ? <img className="inv-logo" src={logo} alt="" style={{ maxHeight: size, maxWidth: size * 2.6 }}
    onError={(e) => { const box = (e.currentTarget.parentElement?.classList.contains('inv-logo-box') ? e.currentTarget.parentElement : e.currentTarget) as HTMLElement; box.style.display = 'none'; }} /> : null;

  return (
    <div className={`inv-doc inv-${t}${fixed ? '' : ' inv-fluid'}`} style={{ ...vars, ...style }}>
      <style>{CSS}</style>
      {t === 'modern' ? (
        <>
          <div className="inv-band">
            <div className="inv-band-l">
              {logo && <div className="inv-logo-box">{logoImg(46)}</div>}
              <div>
                <div className="inv-org">{o.name}</div>
                {o.address && <div className="inv-band-sub inv-pre">{o.address}</div>}
              </div>
            </div>
            <div className="inv-band-r">
              <div className="inv-title">{title}</div>
              <div className="inv-band-sub">{d.number}</div>
            </div>
          </div>
          <div className="inv-strip">
            {billTo}
            {factsBlock}
            <div className="inv-from">
              <div className="inv-k">From</div>
              {orgContact.map((x) => <div key={x}>{x}</div>)}
              {orgIds.map((x) => <div key={x}>{x}</div>)}
            </div>
          </div>
          <div className="inv-body">{table}{totals}{afterTable}</div>
        </>
      ) : t === 'minimal' ? (
        <div className="inv-body">
          <div className="inv-head">
            <div>
              {logoImg(40)}
              <div className="inv-org">{o.name}</div>
              <div className="inv-small">
                {o.address && <div className="inv-pre">{o.address}</div>}
                {orgContact.length > 0 && <div>{orgContact.join(' · ')}</div>}
                {orgIds.length > 0 && <div>{orgIds.join(' · ')}</div>}
              </div>
            </div>
            <div className="inv-title">{title.toLowerCase()}</div>
          </div>
          <div className="inv-parties">{billTo}{factsBlock}</div>
          {table}{totals}{afterTable}
        </div>
      ) : (
        <div className="inv-body">
          <div className="inv-head">
            <div className="inv-head-l">
              {logoImg(64)}
              <div>
                <div className="inv-org">{o.name}</div>
                <div className="inv-small">
                  {o.address && <div className="inv-pre">{o.address}</div>}
                  {orgContact.length > 0 && <div>{orgContact.join(' · ')}</div>}
                  {orgIds.length > 0 && <div>{orgIds.join(' · ')}</div>}
                </div>
              </div>
            </div>
            <div className="inv-head-r">
              <div className="inv-title">{title}</div>
              {factsBlock}
            </div>
          </div>
          <div className="inv-rule" />
          <div className="inv-parties">{billTo}</div>
          {table}{totals}{afterTable}
        </div>
      )}
    </div>
  );
}

// Lays the document out at A4 width and shrinks it to fit, for previews.
export function ScaledDoc({ children, width = 794 }: { children: ReactNode; width?: number }) {
  const outer = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState<{ s: number; h?: number }>({ s: 1 });
  useLayoutEffect(() => {
    const measure = () => {
      const w = outer.current?.clientWidth || width;
      const s = Math.min(1, w / width);
      setBox({ s, h: (inner.current?.offsetHeight || 0) * s });
    };
    measure();
    const ro = new ResizeObserver(measure);
    if (outer.current) ro.observe(outer.current);
    if (inner.current) ro.observe(inner.current);
    return () => ro.disconnect();
  }, [width]);
  return (
    <div ref={outer} style={{ width: '100%', height: box.h, overflow: 'hidden' }}>
      <div ref={inner} style={{ width, transform: `scale(${box.s})`, transformOrigin: 'top left' }}>{children}</div>
    </div>
  );
}

// Puts a copy of the document straight under <body> so printing shows only the document, on A4.
export function PrintPortal({ children }: { children: ReactNode }) {
  if (typeof document === 'undefined') return null;
  return createPortal(<div className="print-only">{children}</div>, document.body);
}

// Sample data for the template previews in Settings.
export function sampleDoc(org: Record<string, any>): DocData {
  return {
    doc_type: 'invoice', number: 'INV-0042', status: 'open', issue_date: new Date().toISOString().slice(0, 10),
    due_date: new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10), reference: 'PO-7781',
    customer_name: 'Adaeze Foods Limited', customer_tin: '23456789-0001', customer_address: '14 Admiralty Way, Lekki Phase 1', customer_email: 'accounts@adaezefoods.ng',
    customer: { city: 'Lagos', state: 'Lagos', country: 'NG', contact_person: 'Mrs Adaeze Okafor' }, export: false, prices_include_vat: false,
    lines: [
      { description: 'Bookkeeping and monthly management accounts', qty: 1, unit_label: 'month', unit_price: 250000, vat_treatment: 'standard', net: 250000, vat: 18750, gross: 268750 },
      { description: 'Payroll processing (25 staff)', qty: 25, unit_label: 'staff', unit_price: 3000, vat_treatment: 'standard', net: 75000, vat: 5625, gross: 80625 },
      { description: 'Medical supplies (exempt)', qty: 2, unit_label: 'carton', unit_price: 18000, vat_treatment: 'exempt', net: 36000, vat: 0, gross: 36000 },
    ],
    subtotal: 361000, vat_total: 24375, total: 385375, amount_paid: 0, credited: 0, balance: 385375,
    notes: 'Thank you for your business.', terms: null, org,
  };
}

const CSS = `
.inv-doc { background: #fff; color: #1F2937; font-family: Inter, 'Helvetica Neue', Arial, sans-serif; font-size: 13px; line-height: 1.5; border-radius: 6px;
  box-shadow: 0 1px 3px rgba(16,24,40,.08), 0 8px 24px rgba(16,24,40,.06); overflow: hidden; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.inv-doc * { box-sizing: border-box; }
.inv-body { padding: 36px 40px 28px; }
.inv-pre { white-space: pre-wrap; }
.inv-k { font-size: 10.5px; font-weight: 600; letter-spacing: .07em; text-transform: uppercase; color: #6B7280; }
.inv-org { font-weight: 700; font-size: 17px; color: #111827; }
.inv-small { font-size: 12px; color: #4B5563; margin-top: 2px; }
.inv-logo { display: block; object-fit: contain; }
.inv-head { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; }
.inv-head-l { display: flex; gap: 14px; align-items: flex-start; min-width: 0; }
.inv-head-r { text-align: right; flex: none; }
.inv-title { font-size: 30px; font-weight: 700; letter-spacing: .02em; color: var(--bi); line-height: 1.1; }
.inv-facts { display: grid; gap: 3px; margin-top: 10px; }
.inv-fact { display: flex; gap: 14px; justify-content: space-between; }
.inv-fact .inv-k { padding-top: 2px; }
.inv-fact span:last-child { font-weight: 600; color: #111827; }
.inv-rule { height: 3px; background: var(--b); margin: 22px 0 18px; border-radius: 2px; }
.inv-parties { display: flex; justify-content: space-between; gap: 24px; margin-bottom: 18px; }
.inv-bill { font-size: 12.5px; color: #374151; }
.inv-cust { font-weight: 700; font-size: 14.5px; color: #111827; margin: 2px 0; }
.inv-table { width: 100%; border-collapse: collapse; margin-top: 4px; }
.inv-table th { font-size: 10.5px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; text-align: left; padding: 9px 10px; }
.inv-table td { padding: 10px; border-bottom: 1px solid #EEF0F3; vertical-align: top; }
.inv-table tr { break-inside: avoid; }
.inv-table .r { text-align: right; white-space: nowrap; }
.inv-table .c { text-align: center; }
.inv-desc { font-weight: 600; color: #111827; }
.inv-sub { font-size: 11.5px; color: #6B7280; }
.inv-sub .inv-m { display: none; }
.inv-u { color: #9CA3AF; font-size: 11px; }
.inv-vs { display: inline-block; min-width: 22px; padding: 1px 6px; border-radius: 6px; background: var(--bt); color: var(--bi); font-weight: 700; font-size: 11.5px; }
.inv-totals { margin: 14px 0 0 auto; width: 300px; max-width: 100%; }
.inv-tr { display: flex; justify-content: space-between; padding: 5px 10px; font-variant-numeric: tabular-nums; }
.inv-total { font-weight: 700; font-size: 15px; color: #111827; border-top: 2px solid var(--b); margin-top: 4px; padding-top: 9px; }
.inv-due { font-weight: 700; color: #B42318; }
.inv-words { margin-top: 16px; font-size: 12.5px; color: #374151; }
.inv-note { margin-top: 12px; padding: 10px 12px; border-radius: 8px; background: var(--bt); color: #1F2937; font-size: 12.5px; }
.inv-legend { margin-top: 10px; font-size: 11px; color: #6B7280; }
.inv-cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-top: 18px; }
.inv-box { border: 1px solid #EEF0F3; border-radius: 8px; padding: 10px 12px; font-size: 12.5px; break-inside: avoid; }
.inv-box .inv-k { margin-bottom: 4px; }
.inv-sign { margin-top: 36px; width: 240px; font-size: 12px; color: #4B5563; break-inside: avoid; }
.inv-sigline { border-bottom: 1px solid #9CA3AF; height: 40px; margin-bottom: 6px; }
.inv-foot { margin-top: 26px; padding-top: 12px; border-top: 1px solid #EEF0F3; font-size: 11px; color: #6B7280; text-align: center; display: grid; gap: 4px; }

/* Classic */
.inv-classic .inv-table thead tr { background: var(--bt); }
.inv-classic .inv-table thead th { color: var(--bi); }

/* Modern */
.inv-band { background: var(--b); color: var(--on); padding: 26px 40px; display: flex; justify-content: space-between; gap: 20px; align-items: center; }
.inv-band-l { display: flex; gap: 14px; align-items: center; min-width: 0; }
.inv-logo-box { background: #fff; border-radius: 10px; padding: 6px; flex: none; }
.inv-modern .inv-org { color: var(--on); font-size: 19px; }
.inv-band-sub { font-size: 12px; opacity: .85; }
.inv-band-r { text-align: right; flex: none; }
.inv-modern .inv-title { color: var(--on); text-transform: uppercase; letter-spacing: .14em; font-size: 24px; }
.inv-strip { display: grid; grid-template-columns: 1.2fr 1fr 1fr; gap: 20px; padding: 20px 40px; background: #F8FAFC; border-bottom: 1px solid #EEF0F3; font-size: 12.5px; }
.inv-modern .inv-facts { margin-top: 0; }
.inv-modern .inv-from { color: #374151; }
.inv-modern .inv-table thead tr { background: var(--b); }
.inv-modern .inv-table thead th { color: var(--on); }
.inv-modern .inv-table tbody tr:nth-child(even) td { background: #FAFBFC; }
.inv-modern .inv-total { background: var(--b); color: var(--on); border: 0; border-radius: 8px; padding: 10px 12px; }

/* Minimal */
.inv-minimal .inv-body { padding: 44px 48px 32px; }
.inv-minimal .inv-head { border-top: 3px solid var(--b); padding-top: 18px; }
.inv-minimal .inv-logo { margin-bottom: 8px; }
.inv-minimal .inv-title { font-weight: 300; font-size: 40px; letter-spacing: -.01em; }
.inv-minimal .inv-parties { margin: 30px 0 22px; }
.inv-minimal .inv-table thead th { color: #6B7280; border-bottom: 1px solid #111827; padding-left: 0; }
.inv-minimal .inv-table td { padding-left: 0; }
.inv-minimal .inv-vs { background: transparent; border: 1px solid #D1D5DB; color: #374151; }
.inv-minimal .inv-total { border-top: 1px solid #111827; color: var(--bi); font-size: 17px; }
.inv-minimal .inv-note { background: transparent; border-left: 3px solid var(--b); border-radius: 0; }

/* Phones: the table folds into one column per line. */
@media screen and (max-width: 620px) {
  .inv-fluid .inv-body, .inv-minimal.inv-fluid .inv-body { padding: 22px 18px 18px; }
  .inv-fluid .inv-band { padding: 20px 18px; flex-direction: column; align-items: flex-start; }
  .inv-fluid .inv-band-r { text-align: left; }
  .inv-fluid .inv-strip { grid-template-columns: 1fr; padding: 16px 18px; gap: 12px; }
  .inv-fluid .inv-head { flex-direction: column; }
  .inv-fluid .inv-head-r { text-align: left; width: 100%; }
  .inv-fluid .inv-parties { flex-direction: column; }
  .inv-fluid .inv-table .inv-d { display: none; }
  .inv-fluid .inv-table th:nth-child(2), .inv-fluid .inv-table th:nth-child(3), .inv-fluid .inv-table th:nth-last-child(2) { display: none; }
  .inv-fluid .inv-sub .inv-m { display: inline; }
  .inv-fluid .inv-title { font-size: 24px; }
  .inv-minimal.inv-fluid .inv-title { font-size: 30px; }
}

/* Printing: only the document, on A4, colours kept. */
.print-only { display: none; }
@media print {
  @page { size: A4; margin: 12mm; }
  body:has(> .print-only) > *:not(.print-only) { display: none !important; }
  .print-only { display: block !important; }
  .print-only .inv-doc { box-shadow: none; border-radius: 0; }
  .print-only .inv-band { margin: 0; }
  html, body { background: #fff !important; height: auto !important; overflow: visible !important; }
}
`;
