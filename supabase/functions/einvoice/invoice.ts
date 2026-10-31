// A Counta sale as NRS's invoice (MBS API 1.1, the JSON form of its UBL schema). The database gives the facts
// (svc_einvoice_claim); this decides how they are written for NRS, so a change NRS asks for needs no database update.
//
// Who the buyer is decides the kind: B2B or B2G for a business or government customer, B2C for anyone else. Goods lines
// carry the item's HS code (hsn_code, product_category); service and delivery lines carry the business's ISIC service
// code (isic_code, service_category). Amounts are naira and kobo, VAT apart (line_extension_amount is before VAT).

export type Facts = {
  sale: Record<string, any>;
  lines: Record<string, any>[];
  org: Record<string, any>;
  customer: Record<string, any>;
  payments: string[];
  original: { number: string; issue_date: string; irn: string | null } | null;
  codes: { invoice: string; credit_note: string };
};
export type Claim = { kind: 'clear' | 'report'; doc: 'invoice' | 'receipt' | 'credit_note'; irn: string; facts: Facts; creds: { business_id: string | null } };

const r2 = (v: unknown) => Math.round((Number(v) || 0) * 100) / 100;
const text = (v: unknown, n: number) => {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, n) : undefined;
};

// NRS wants the country code first: 0803 123 4567 becomes +2348031234567.
export function intlPhone(v: unknown): string | undefined {
  const raw = String(v ?? '').trim();
  if (!raw) return undefined;
  const d = raw.replace(/[^\d]/g, '');
  if (raw.startsWith('+') && d.length >= 8) return '+' + d;
  if (d.startsWith('234') && d.length >= 12) return '+' + d;
  if (d.startsWith('0') && d.length === 11) return '+234' + d.slice(1);
  if (d.length === 10 && /^[789]/.test(d)) return '+234' + d;
  return undefined;
}

// The VAT category of a line, as NRS lists them.
export function taxCategory(treatment: string, rate: unknown): { id: string; percent: number } {
  if (treatment === 'zero') return { id: 'ZERO_VAT', percent: 0 };
  if (treatment === 'exempt') return { id: 'EXEMPTED', percent: 0 };
  const pct = Number(rate) > 0 && Number(rate) < 1 ? Math.round(Number(rate) * 10000) / 100 : 7.5;
  return { id: 'STANDARD_VAT', percent: pct };
}

// How a payment was made, as NRS codes it: 10 cash, 20 cheque, 30 credit transfer, 48 bank card, 97 other.
const MEANS: Record<string, string> = { cash: '10', cheque: '20', transfer: '30', account: '30', link: '30', qr: '30', card: '48', pos: '48', other: '97' };

function address(x: Record<string, any>, country: string) {
  const a: Record<string, unknown> = {
    street_name: text(x.street, 255), city_name: text(x.city, 100), postal_zone: text(x.postcode, 20),
    lga: x.place?.lga || undefined, state: x.place?.state || undefined, country: country || 'NG',
  };
  return Object.fromEntries(Object.entries(a).filter(([, v]) => v !== undefined && v !== null && v !== ''));
}

function party(x: Record<string, any>, country: string, description?: string) {
  const p: Record<string, unknown> = {
    party_name: text(x.name, 255), tin: text(x.tin, 20), email: text(x.email, 100), telephone: intlPhone(x.phone),
    business_description: text(description, 255), postal_address: address(x, country),
  };
  return Object.fromEntries(Object.entries(p).filter(([, v]) => v !== undefined));
}

export function invoiceKind(c: Claim): 'B2B' | 'B2G' | 'B2C' {
  if (c.kind === 'report') return 'B2C';
  return c.facts.customer.kind === 'government' ? 'B2G' : 'B2B';
}

export function buildInvoice(c: Claim): Record<string, unknown> {
  const f = c.facts, s = f.sale, cur = String(s.currency || 'NGN').toUpperCase();
  const lines = (f.lines || []).filter((l) => Number(l.qty) > 0);
  const service = f.org.service_code ? { isic_code: String(f.org.service_code), service_category: text(f.org.service_label, 255) || 'Services' } : null;

  const invoiceLine = lines.map((l) => {
    const net = r2(l.net), qty = Number(l.qty);
    const isService = l.kind === 'service' || l.kind === 'delivery' || (l.kind !== 'goods' && !l.hs_code) || l.item_type === 'service';
    const codes: Record<string, unknown> = isService && service ? { ...service }
      : l.hs_code ? { hsn_code: String(l.hs_code), product_category: text(l.hs_label, 255) || text(l.item_name, 255) || 'Goods' } : {};
    const item: Record<string, unknown> = { name: text(l.description, 255) || 'Item', description: text(l.item_description, 255) || text(l.description, 255) || 'Item' };
    if (l.sku) item.sellers_item_identification = text(l.sku, 100);
    return {
      ...codes,
      invoiced_quantity: qty,
      line_extension_amount: net,
      item,
      price: { price_amount: r2(qty ? net / qty : net), base_quantity: 1, price_unit: `${cur} per 1` },
    };
  });

  // VAT by category, in the order standard, zero, exempt.
  const groups = new Map<string, { cat: { id: string; percent: number }; taxable: number; tax: number }>();
  for (const l of lines) {
    const cat = taxCategory(String(l.vat_treatment || 'standard'), l.vat_rate);
    const k = `${cat.id}:${cat.percent}`;
    const g = groups.get(k) || { cat, taxable: 0, tax: 0 };
    g.taxable += Number(l.net) || 0; g.tax += Number(l.vat) || 0;
    groups.set(k, g);
  }
  const order = ['STANDARD_VAT', 'ZERO_VAT', 'EXEMPTED'];
  const subtotals = [...groups.values()].sort((a, b) => order.indexOf(a.cat.id) - order.indexOf(b.cat.id))
    .map((g) => ({ taxable_amount: r2(g.taxable), tax_amount: r2(g.tax), tax_category: g.cat }));
  const netTotal = r2(lines.reduce((a, l) => a + (Number(l.net) || 0), 0));
  const vatTotal = r2(lines.reduce((a, l) => a + (Number(l.vat) || 0), 0));

  const due = s.due_date || s.issue_date;
  const means = [...new Set((f.payments || []).map((m) => MEANS[m]).filter(Boolean))].map((code) => ({ payment_means_code: code, payment_due_date: due }));

  const out: Record<string, unknown> = {
    business_id: c.creds.business_id,
    irn: c.irn,
    issue_date: s.issue_date,
    issue_time: s.issue_time || undefined,
    due_date: c.doc === 'invoice' && s.due_date ? s.due_date : undefined,
    invoice_type_code: c.doc === 'credit_note' ? f.codes.credit_note : f.codes.invoice,
    invoice_kind: invoiceKind(c),
    payment_status: s.paid ? 'PAID' : 'PENDING',
    note: text(s.notes, 500),
    document_currency_code: cur,
    tax_currency_code: 'NGN',
    order_reference: text(s.reference, 100),
    billing_reference: c.doc === 'credit_note' && f.original?.irn ? [{ irn: f.original.irn, issue_date: f.original.issue_date }] : undefined,
    accounting_supplier_party: party(f.org, 'NG', f.org.description || undefined),
    payment_means: means.length ? means : undefined,
    tax_total: [{ tax_amount: vatTotal, tax_subtotal: subtotals }],
    legal_monetary_total: { line_extension_amount: netTotal, tax_exclusive_amount: netTotal, tax_inclusive_amount: r2(netTotal + vatTotal), payable_amount: r2(s.total) },
    invoice_line: invoiceLine,
  };
  // The buyer: always for a business or government; for a person, when Counta knows who they are.
  const buyer = f.customer;
  if (c.kind === 'clear' || (!buyer.walk_in && text(buyer.name, 255))) {
    out.accounting_customer_party = party(buyer, String(buyer.country || 'NG').toUpperCase());
  }
  return Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined));
}

// What a sale still lacks before NRS will take it, found without asking NRS: said in words a shop owner can act on.
export function missing(c: Claim): string[] {
  const f = c.facts, out: string[] = [];
  if (!c.creds.business_id) out.push('the Business ID');
  if (!f.org.tin) out.push('the business\'s Tax ID');
  if (!f.org.place?.state || !f.org.place?.lga) out.push('the state and LGA of the main branch');
  const goodsNoCode = (f.lines || []).filter((l) => l.kind === 'goods' && !l.hs_code && l.item_type !== 'service');
  const serviceNoCode = (f.lines || []).some((l) => (l.kind === 'service' || l.kind === 'delivery') && !f.org.service_code);
  if (goodsNoCode.length) out.push(`an HS code for ${goodsNoCode.slice(0, 3).map((l) => l.description).join(', ')}${goodsNoCode.length > 3 ? ' and others' : ''}`);
  if (serviceNoCode) out.push('the business\'s service code');
  return out;
}
