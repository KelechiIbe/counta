// An invoice as UBL 2.1 XML in Peppol's specification for Nigeria, PINT NG Billing 1.0.0 (customization
// urn:peppol:pint:billing-1@ng-1, published by OpenPeppol in August 2026). Peppol BIS Billing 3.0 has no electronic address
// scheme for a Nigerian Tax ID; PINT NG does (0244), and adds Nigeria's own rules: both parties' Tax IDs, addresses with
// state and LGA codes, HS and service codes on every line, NRS's VAT exemption codes.
//
// The same facts NRS's JSON is written from (invoice.ts) are written here. What PINT NG needs and the invoice lacks is
// listed in `missing`, in words a person can act on; the XML is only given when nothing is missing.
import { type Facts, unitCode } from './invoice.ts';

export const PINT_NG = 'urn:peppol:pint:billing-1@ng-1';
export const PINT_PROFILE = 'urn:peppol:bis:billing';

const r2 = (v: unknown) => Math.round((Number(v) || 0) * 100) / 100;
const amt = (v: number) => r2(v).toFixed(2);
// A unit price to six places, without trailing zeros (at least two places).
const price = (v: number) => {
  const s = (Math.round(v * 1e6) / 1e6).toFixed(6).replace(/0+$/, '');
  return /\.\d$/.test(s) ? s + '0' : s.endsWith('.') ? s + '00' : s;
};
const esc = (v: unknown) => String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
const text = (v: unknown, n: number) => {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, n) : '';
};
const el = (tag: string, v: unknown, attrs = '') => (String(v ?? '') === '' ? '' : `<${tag}${attrs}>${esc(v)}</${tag}>`);
const money = (tag: string, v: number, cur: string) => `<${tag} currencyID="${esc(cur)}">${amt(v)}</${tag}>`;

// How a payment was made, as UNCL4461 codes it.
const MEANS: Record<string, string> = { cash: '10', cheque: '20', transfer: '30', account: '30', link: '30', qr: '30', card: '48', pos: '48', other: 'ZZZ' };

type Cat = { id: 'S' | 'Z' | 'E'; percent: number; exemption?: string };

export type UblInput = {
  docId: string;              // the invoice's id in Counta (a UUID), its unique identifier (BTNG-001)
  kind: 'clear' | 'report';
  doc: 'invoice' | 'receipt' | 'credit_note';
  irn: string | null;
  facts: Facts;
  units?: Set<string> | null; // NRS's quantity codes, when Counta has them
};

export function pintNg(x: UblInput): { xml: string | null; missing: string[]; root: 'Invoice' | 'CreditNote' } {
  const f = x.facts, s = f.sale, o = f.org, c = f.customer;
  const cur = String(s.currency || 'NGN').toUpperCase();
  const credit = x.doc === 'credit_note';
  const root = credit ? 'CreditNote' : 'Invoice';
  const missing: string[] = [];
  const need = (ok: unknown, what: string) => { if (!ok) missing.push(what); };

  if (x.kind !== 'clear') missing.push("the buyer's Tax ID: PINT NG is for invoices to businesses and government, and this one is to a consumer");
  need(text(o.name, 200), "the business's name");
  need(text(o.tin, 30), "the business's Tax ID");
  const addr = (p: Record<string, any>, who: string) => {
    need(text(p.street, 200), `${who} street address`);
    need(text(p.city, 100), `${who} city`);
    need(text(p.postcode, 20), `${who} postcode`);
    need(p.place?.state, `${who} state`);
    need(p.place?.lga, `${who} LGA`);
  };
  addr(o, "the business's");
  if (x.kind === 'clear') {
    need(text(c.name, 200), "the buyer's name");
    need(text(c.tin, 30), "the buyer's Tax ID");
    addr(c, "the buyer's");
  }

  const lines = (f.lines || []).filter((l) => Number(l.qty) > 0);
  if (!lines.length) missing.push('at least one line');
  const lineCats: Cat[] = [];
  for (const [i, l] of lines.entries()) {
    const label = `line ${i + 1} (${text(l.description, 40) || 'item'})`;
    const t = String(l.vat_treatment || 'standard');
    let cat: Cat;
    if (t === 'zero') cat = { id: 'Z', percent: 0 };
    else if (t === 'exempt') {
      cat = { id: 'E', percent: 0, exemption: l.hs_code ? String(l.hs_code) : undefined };
      if (!cat.exemption) missing.push(`${label}: the HS code from NRS's list of VAT exemptions`);
    } else {
      const rate = Number(l.vat_rate);
      const pct = rate > 0 && rate < 1 ? Math.round(rate * 10000) / 100 : rate >= 1 ? rate : (Number(l.vat) > 0 ? 7.5 : 0);
      if (!(pct > 0)) missing.push(`${label}: a VAT rate (PINT NG has no category for a seller not registered for VAT)`);
      cat = { id: 'S', percent: pct > 0 ? pct : 7.5 };
    }
    lineCats.push(cat);
    const isService = l.kind === 'service' || l.kind === 'delivery' || l.item_type === 'service' || (l.kind !== 'goods' && !l.hs_code);
    if (isService ? !o.service_code : !l.hs_code) missing.push(`${label}: ${isService ? "the business's service code" : 'an HS code'}`);
  }
  if (credit && !f.original?.number) missing.push('the invoice this credit note corrects');
  if (missing.length) return { xml: null, missing, root };

  // VAT by category, worked out from the line amounts as PINT's rules do; any kobo of difference from Counta's VAT goes to
  // the rounding amount, so the amount payable is the invoice's total.
  const groups = new Map<string, { cat: Cat; taxable: number }>();
  lines.forEach((l, i) => {
    const cat = lineCats[i];
    const k = `${cat.id}:${cat.percent}`;
    const g = groups.get(k) || { cat, taxable: 0 };
    g.taxable = r2(g.taxable + r2(l.net));
    groups.set(k, g);
  });
  const order = ['S', 'Z', 'E'];
  const subs = [...groups.values()].sort((a, b) => order.indexOf(a.cat.id) - order.indexOf(b.cat.id) || b.cat.percent - a.cat.percent)
    .map((g) => ({ ...g, tax: g.cat.id === 'S' ? r2(g.taxable * g.cat.percent / 100) : 0 }));
  const net = r2(lines.reduce((a, l) => a + r2(l.net), 0));
  const tax = r2(subs.reduce((a, g) => a + g.tax, 0));
  const inclusive = r2(net + tax);
  const total = r2(s.total);
  const prepaid = credit ? 0 : Math.min(r2(s.amount_paid ?? (s.paid ? s.total : 0)), total);
  const rounding = r2(total - inclusive);
  const payable = r2(inclusive - prepaid + rounding);

  const taxScheme = '<cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>';
  const country = (code: unknown) => `<cac:Country><cbc:IdentificationCode>${esc(String(code || 'NG').toUpperCase())}</cbc:IdentificationCode></cac:Country>`;
  const party = (p: Record<string, any>, description?: string) => {
    const tin = text(p.tin, 30), phone = text(p.phone, 30), email = text(p.email, 100);
    return '<cac:Party>'
      + `<cbc:EndpointID schemeID="0244">${esc(tin)}</cbc:EndpointID>`
      + (description ? `<cbc:IndustryClassificationCode name="BusinessDescription">${esc(text(description, 200))}</cbc:IndustryClassificationCode>` : '')
      + `<cac:PartyName>${el('cbc:Name', text(p.name, 200))}</cac:PartyName>`
      + '<cac:PostalAddress>' + el('cbc:StreetName', text(p.street, 200)) + el('cbc:CityName', text(p.city, 100)) + el('cbc:PostalZone', text(p.postcode, 20))
      + el('cbc:CountrySubentity', p.place?.state) + el('cbc:CountrySubentityCode', p.place?.lga) + country(p.country) + '</cac:PostalAddress>'
      // The Tax ID (TIN) under a tax scheme other than VAT, as PINT NG asks.
      + `<cac:PartyTaxScheme><cbc:CompanyID>${esc(tin)}</cbc:CompanyID><cac:TaxScheme><cbc:ID>GST</cbc:ID></cac:TaxScheme></cac:PartyTaxScheme>`
      + `<cac:PartyLegalEntity>${el('cbc:RegistrationName', text(p.name, 200))}</cac:PartyLegalEntity>`
      // A contact needs a phone number in PINT NG; without one there is none.
      + (phone ? `<cac:Contact>${el('cbc:Telephone', phone)}${el('cbc:ElectronicMail', email)}</cac:Contact>` : '')
      + '</cac:Party>';
  };
  const category = (tag: string, cat: Cat, inSubtotal: boolean) => `<cac:${tag}><cbc:ID>${cat.id}</cbc:ID>`
    + (cat.id === 'E' && inSubtotal ? '' : `<cbc:Percent>${cat.percent}</cbc:Percent>`)
    + (cat.id === 'E' && cat.exemption ? `<cbc:TaxExemptionReasonCode>${esc(cat.exemption)}</cbc:TaxExemptionReasonCode>` : '')
    + `${taxScheme}</cac:${tag}>`;
  const due = s.due_date || s.issue_date;
  const means = [...new Set((f.payments || []).map((m) => MEANS[m]).filter(Boolean))];
  const lineTag = credit ? 'CreditNoteLine' : 'InvoiceLine';
  const qtyTag = credit ? 'CreditedQuantity' : 'InvoicedQuantity';

  const body = [
    `<cbc:CustomizationID>${PINT_NG}</cbc:CustomizationID>`,
    `<cbc:ProfileID>${PINT_PROFILE}</cbc:ProfileID>`,
    el('cbc:ID', s.number),
    el('cbc:UUID', x.docId),
    el('cbc:IssueDate', s.issue_date),
    credit ? '' : el('cbc:DueDate', due),
    credit ? '<cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>' : '<cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>',
    el('cbc:Note', text(s.notes, 500)),
    el('cbc:DocumentCurrencyCode', cur),
    el('cbc:BuyerReference', text(s.reference, 100) || text(c.tin, 30)),
    credit ? `<cac:BillingReference><cac:InvoiceDocumentReference>${el('cbc:ID', f.original!.number)}${el('cbc:IssueDate', f.original!.issue_date)}</cac:InvoiceDocumentReference></cac:BillingReference>` : '',
    x.irn ? `<cac:AdditionalDocumentReference>${el('cbc:ID', x.irn)}<cbc:DocumentDescription>NRS Invoice Reference Number (IRN)</cbc:DocumentDescription></cac:AdditionalDocumentReference>` : '',
    `<cac:AccountingSupplierParty>${party(o, o.description || undefined)}</cac:AccountingSupplierParty>`,
    `<cac:AccountingCustomerParty>${party(c)}</cac:AccountingCustomerParty>`,
    ...(credit
      ? [`<cac:PaymentMeans><cbc:PaymentMeansCode>${means[0] || '30'}</cbc:PaymentMeansCode>${el('cbc:PaymentDueDate', due)}</cac:PaymentMeans>`]
      : means.map((m) => `<cac:PaymentMeans><cbc:PaymentMeansCode>${m}</cbc:PaymentMeansCode></cac:PaymentMeans>`)),
    credit ? `<cac:PaymentTerms><cbc:Note>${esc(`Credit against ${f.original!.number}`)}</cbc:Note></cac:PaymentTerms>` : '',
    `<cac:TaxTotal>${money('cbc:TaxAmount', tax, cur)}${subs.map((g) => `<cac:TaxSubtotal>${money('cbc:TaxableAmount', g.taxable, cur)}${money('cbc:TaxAmount', g.tax, cur)}${category('TaxCategory', g.cat, true)}</cac:TaxSubtotal>`).join('')}</cac:TaxTotal>`,
    '<cac:LegalMonetaryTotal>' + money('cbc:LineExtensionAmount', net, cur) + money('cbc:TaxExclusiveAmount', net, cur) + money('cbc:TaxInclusiveAmount', inclusive, cur)
      + (prepaid ? money('cbc:PrepaidAmount', prepaid, cur) : '') + (rounding ? money('cbc:PayableRoundingAmount', rounding, cur) : '')
      + money('cbc:PayableAmount', payable, cur) + '</cac:LegalMonetaryTotal>',
    ...lines.map((l, i) => {
      const qty = Number(l.qty), lnet = r2(l.net);
      const isService = l.kind === 'service' || l.kind === 'delivery' || l.item_type === 'service' || (l.kind !== 'goods' && !l.hs_code);
      const code = isService ? String(o.service_code) : String(l.hs_code);
      const codeLabel = isService ? (text(o.service_label, 200) || code) : (text(l.hs_label, 200) || code);
      return `<cac:${lineTag}>`
        + `<cbc:ID>${i + 1}</cbc:ID>`
        + `<cbc:${qtyTag} unitCode="${esc(unitCode(l.unit_label, x.units))}">${qty}</cbc:${qtyTag}>`
        + money('cbc:LineExtensionAmount', lnet, cur)
        + '<cac:Item>'
        + el('cbc:Description', text(l.item_description, 300))
        + el('cbc:Name', text(l.description, 200) || 'Item')
        + (l.sku ? `<cac:SellersItemIdentification>${el('cbc:ID', text(l.sku, 100))}</cac:SellersItemIdentification>` : '')
        + `<cac:CommodityClassification>${el('cbc:CommodityCode', code)}<cbc:ItemClassificationCode listID="MP">${esc(codeLabel)}</cbc:ItemClassificationCode></cac:CommodityClassification>`
        + category('ClassifiedTaxCategory', lineCats[i], false)
        + '</cac:Item>'
        + `<cac:Price><cbc:PriceAmount currencyID="${esc(cur)}">${price(qty ? lnet / qty : lnet)}</cbc:PriceAmount></cac:Price>`
        + `</cac:${lineTag}>`;
    }),
  ].filter(Boolean).join('');
  const ns = credit ? 'urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2' : 'urn:oasis:names:specification:ubl:schema:xsd:Invoice-2';
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<${root} xmlns="${ns}" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">${body}</${root}>\n`;
  return { xml, missing: [], root };
}
