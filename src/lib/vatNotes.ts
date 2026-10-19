// Why a product, sale line or bill line carries the VAT it does: a few plain sentences and the part of the Nigeria Tax
// Act 2025 it rests on. Shown behind the small information icon beside a VAT treatment, so screens stay uncluttered.
// Sections: s.148 the 7.5% rate; s.151 non-resident suppliers and the reverse charge; s.156 input VAT; s.186 exempt
// supplies; s.187 zero-rated supplies (exports included).
import { vatPct } from './vat';
import type { Item } from './types';

export type VatSide = 'sale' | 'purchase';
export type VatNoteInput = {
  side: VatSide;
  treatment: string | null | undefined;  // standard | zero | exempt | none
  name?: string | null;                  // the product or line, for the sentence
  subject?: string;                      // or a phrase used as it is, such as "These sales"
  day?: string | null;                   // the document's date, for the rate in force that day
  item?: Pick<Item, 'vat_basis' | 'vat_review'> | null;
  vatRegistered?: boolean;               // the business charges VAT on its sales
  recoverable?: boolean;                 // purchases: the VAT can be claimed back
  exportSale?: boolean;                  // sales to a customer outside Nigeria
  foreignVendor?: boolean;               // purchases from a vendor outside Nigeria
  nrsLabel?: string | null;              // the NRS VAT return's description of a zero-rated or exempt supply
};
export type VatNote = { title: string; body: string[]; law: string | null; basis: string | null };

const ACT = 'Nigeria Tax Act 2025';
const tidyName = (n?: string | null) => {
  const t = String(n ?? '').replace(/\s+/g, ' ').trim();
  return t ? `"${t.length > 60 ? t.slice(0, 57) + '...' : t}"` : 'This';
};
const cleanLabel = (l?: string | null) => String(l ?? '').replace(/;\s*$/, '').replace(/\s+/g, ' ').trim();

// Who decided the item's treatment, in a line.
function basisLine(item?: VatNoteInput['item']): string | null {
  const b = item?.vat_basis;
  if (!b) return null;
  const sure = typeof b.confidence === 'number' ? `, ${Math.round(b.confidence * 100)}% sure` : '';
  const why = b.reason ? ` ${String(b.reason).trim().replace(/\.?$/, '.')}` : '';
  if (b.source === 'manual') return `Set by ${b.by || 'someone on your team'}${b.at ? ` on ${new Date(b.at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}` : ''}.${why}`;
  if (b.source === 'numens') return `Numens, TaxStreem's tax model, decided this${sure}.${why}`;
  if (b.source === 'gemini') return `Counta's AI decided this${sure}${item?.vat_review ? ' and asked for a person to confirm' : ''}.${why}`;
  if (b.source === 'import') return `Brought in with your product list.${why}`;
  return why.trim() || null;
}

export function vatNote(i: VatNoteInput): VatNote {
  const t = i.treatment || 'standard';
  const what = i.subject || tidyName(i.name);
  const many = !!i.subject && /^(these|those)\b/i.test(i.subject);
  const is = many ? 'are' : 'is';
  const it = many ? 'them' : 'it';
  const rate = vatPct(i.day || undefined);
  const label = cleanLabel(i.nrsLabel);
  const basis = basisLine(i.item);

  if (i.side === 'sale') {
    if (i.vatRegistered === false) {
      return { title: 'No VAT charged', basis, law: null, body: [
        `Your business is not registered to charge VAT, so ${what === 'This' ? 'this sale carries' : `${what} ${many ? 'carry' : 'carries'}`} no VAT and nothing goes to the NRS from ${it}.`,
        'A small company (yearly sales up to ₦100 million and fixed assets up to ₦250 million, and not a professional services firm) does not charge VAT. If your sales pass that level, register and add VAT to standard-rated sales.',
      ] };
    }
    if (i.exportSale) {
      return { title: 'Zero-rated export', basis, law: `${ACT}, s.187 (oil and gas exports: s.186)`, body: [
        `Goods and services sold to a customer outside Nigeria are zero-rated, so ${what === 'This' ? 'this line' : what} ${is} charged VAT at 0% even if ${many ? 'they are' : 'it is'} normally ${t === 'exempt' ? 'exempt' : 'taxed'} at home.`,
        'The sale still goes on your VAT return, and you can claim back the VAT you paid on the purchases behind it. Oil and gas exports are exempt instead.',
      ] };
    }
    if (t === 'zero') {
      return { title: 'Zero-rated: VAT at 0%', basis, law: `${ACT}, s.187`, body: [
        `${what} ${is} on the zero-rated list${label ? ` as "${label}"` : ''}, so the customer pays no VAT on ${it}.`,
        `${many ? 'They still appear' : 'The sale still appears'} on your monthly VAT return, and the VAT you paid on the purchases behind ${it} can still be claimed back.`,
      ] };
    }
    if (t === 'exempt') {
      return { title: 'Exempt from VAT', basis, law: `${ACT}, s.186`, body: [
        `${what} ${is} on the exempt list${label ? ` as "${label}"` : ''}, so no VAT is added and the invoice says the supply is exempt.`,
        'VAT you pay on purchases used for exempt sales cannot be claimed back. It stays in your costs.',
      ] };
    }
    return { title: `Standard-rated: VAT at ${rate}`, basis, law: `${ACT}, s.148`, body: [
      `${what} ${is} not on the zero-rated or exempt lists, so VAT is added at ${rate}${i.day ? `, the rate in force on ${many ? 'those dates' : 'the date of the sale'}` : ''}.`,
      'The VAT you collect belongs to the NRS. It goes on your VAT return for the month, due by the 21st of the following month, less the VAT you paid on purchases.',
    ] };
  }

  // Purchases.
  if (i.foreignVendor && (t === 'none' || t === 'standard')) {
    return { title: 'Bought from outside Nigeria', basis, law: `${ACT}, s.151`, body: [
      `A vendor outside Nigeria usually does not add Nigerian VAT. For services and digital supplies you account for the ${rate} yourself on your VAT return (the reverse charge) and, if you are VAT-registered, claim it back as input VAT in the same return.`,
      'Imported goods have their VAT collected by Customs at the port, shown on the customs papers.',
    ] };
  }
  if (t === 'none') {
    return { title: 'No VAT on this bill', basis, law: null, body: [
      'The vendor did not add VAT, often because it is a small business that is not registered for VAT. There is nothing to claim back.',
      'If the vendor should have charged VAT, ask for a corrected invoice before you pay.',
    ] };
  }
  if (t === 'zero') {
    return { title: 'Zero-rated purchase', basis, law: `${ACT}, s.187`, body: [
      `${what} ${is} zero-rated, so the vendor charged VAT at 0% and there is no VAT to claim back on ${it}.`,
    ] };
  }
  if (t === 'exempt') {
    return { title: 'Exempt purchase', basis, law: `${ACT}, s.186`, body: [
      `${what} ${is} exempt from VAT, so the vendor added none and there is nothing to claim back.`,
    ] };
  }
  if (i.recoverable === false || i.vatRegistered === false) {
    return { title: 'VAT you cannot claim back', basis, law: `${ACT}, s.156`, body: [
      `The vendor charged VAT at ${rate}, but it ${i.vatRegistered === false ? 'cannot be claimed back because your business is not registered for VAT' : 'is marked as not recoverable, for example because the purchase is used for exempt sales or is not for the business'}.`,
      'It is added to the cost of the purchase instead of reducing the VAT you owe.',
    ] };
  }
  return { title: 'Input VAT you can claim back', basis, law: `${ACT}, s.156`, body: [
    `The vendor charged VAT at ${rate}. Your business is VAT-registered and uses this purchase for taxable sales, so the VAT is input VAT.`,
    'It comes off the VAT you owe on your monthly return, provided you keep the vendor\'s VAT invoice.',
  ] };
}
