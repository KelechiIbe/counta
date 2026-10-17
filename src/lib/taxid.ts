// The Tax ID replaced the TIN: 13 digits, issued from the NIN for individuals and from the RC number for companies.
// A number typed in must have 13 digits; one already on file (an old TIN) keeps printing until someone replaces it.
export const TAX_ID_HINT = '13 digits. Individuals get theirs from their NIN and companies from their RC number on the NRS Tax ID portal.';

export const cleanTaxId = (v: string | null | undefined) => String(v ?? '').replace(/[\s\-./]/g, '');

// An error to show under the field, or null. `original` is the number on file, which is accepted unchanged.
export function taxIdError(v: string | null | undefined, original?: string | null): string | null {
  const c = cleanTaxId(v);
  if (!c) return null;
  if (original != null && c === cleanTaxId(original)) return null;
  if (!/^\d+$/.test(c)) return 'A Tax ID has digits only.';
  if (c.length !== 13) return `A Tax ID has 13 digits; this has ${c.length}.`;
  return null;
}

// True for a number on file that is not a 13-digit Tax ID (an old TIN).
export const isOldTin = (v: string | null | undefined) => Boolean(cleanTaxId(v)) && !/^\d{13}$/.test(cleanTaxId(v));
