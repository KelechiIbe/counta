// Reads and labels for the tax returns: companies income tax by accounting year, VAT by month, and withholding tax (and VAT
// withheld) by month and tax authority.
import { useQuery } from '@tanstack/react-query';
import { rpc, supabase } from './supabase';
import { useSession } from '../state/session';

function useOrgQ<T>(key: unknown[], fn: (org: string) => Promise<T>, enabled = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: [...key, orgId], enabled: !!orgId && enabled, queryFn: () => fn(orgId!) });
}

export const useCitYears = (enabled = true) => useOrgQ<any>(['cit-years'], (o) => rpc('cit_years', { p_org: o }), enabled);
export const useCitYear = (year: number | null) => useOrgQ<any>(['cit-year', year], (o) => rpc('cit_year', { p_org: o, p_year: year }), !!year);
// Personal income tax for business names and partnerships, by accounting year (2025 accounts onwards).
export const usePitYears = (enabled = true) => useOrgQ<any>(['pit-years'], (o) => rpc('pit_years', { p_org: o }), enabled);
export const usePitYear = (year: number | null) => useOrgQ<any>(['pit-year', year], (o) => rpc('pit_year', { p_org: o, p_year: year }), !!year);
export const useTaxProfile = (enabled = true) => useOrgQ<any>(['tax-profile'], (o) => rpc('tax_profile', { p_org: o }), enabled);
export const useVatPosition = (from: string, to: string, enabled = true) =>
  useOrgQ<any>(['vat-position', from, to], (o) => rpc('vat_position', { p_org: o, p: { from, to } }), enabled);
export const useWithholding = (from: string, to: string, enabled = true) =>
  useOrgQ<any>(['withholding', from, to], (o) => rpc('withholding_overview', { p_org: o, p: { from, to } }), enabled);
export const useWhtReceipts = (filter: Record<string, unknown>, enabled = true) =>
  useOrgQ<any[]>(['wht-receipts', JSON.stringify(filter)], (o) => rpc('wht_receipts', { p_org: o, p: filter }), enabled);
export const useVendorTax = (vendor: string | null) => useOrgQ<any>(['vendor-tax', vendor], (o) => rpc('vendor_tax_details', { p_org: o, p_vendor: vendor }), !!vendor);
export const useVatSchedule = (period: string | null) => useOrgQ<any>(['vat-schedule', period], (o) => rpc('vat_schedule', { p_org: o, p_period: period }), !!period);
export const useCustoms = (from?: string, to?: string) =>
  useOrgQ<any[]>(['customs', from, to], (o) => rpc('customs_entries_list', { p_org: o, p: { from: from || null, to: to || null } }));

// Nigeria's states and local government areas as the NRS VAT template spells them (static, so read once).
export type NgPlaces = { states: string[]; lgas: Record<string, string[]> };
export const useNgPlaces = () => useQuery({ queryKey: ['ng-places'], staleTime: Infinity, gcTime: Infinity, queryFn: () => rpc<NgPlaces>('ng_places') });
// The NRS VAT return's descriptions of zero-rated and exempt supplies, spelt as the template has them, and the Act's words for
// the exempt goods its list lacks (on_template false).
export type NrsLabel = { label: string; treatment: 'zero' | 'exempt'; on_template?: boolean };
export const useNrsLabels = () => useQuery({ queryKey: ['nrs-labels'], staleTime: Infinity, gcTime: Infinity, queryFn: async () => {
  const { data, error } = await supabase.from('nrs_vat_labels').select('*').order('label');
  if (error) throw error;
  return (data || []) as NrsLabel[];
} });

// Everything a tax action can change.
export const TAX_KEYS = ['cit-years', 'cit-year', 'pit-years', 'pit-year', 'tax-profile', 'vat-position', 'withholding', 'wht-receipts', 'vendor-tax', 'bills', 'bill', 'fs-pack', 'report', 'ledger', 'inbox',
  'vat-schedule', 'customs', 'customers', 'inv', 'item-nrs'];

export const CIT_STATUS: Record<string, { label: string; tone: string }> = {
  draft: { label: 'Draft', tone: 't-grey' }, approved: { label: 'Approved', tone: 't-blue' }, sent: { label: 'With Flux', tone: 't-amber' },
  filed: { label: 'Filed', tone: 't-green' }, rejected: { label: 'Sent back', tone: 't-red' },
};
// How the business pays income tax, from what CAC says it is (through Mono) and what the owner has told Counta: a company
// files companies income tax; an NGO (incorporated trustees, or a company limited by guarantee) is exempt unless it trades;
// a business name, partnership or unregistered business pays personal income tax through its people.
export type IncomeTaxKind = 'cit' | 'pit' | 'exempt';
export function incomeTaxKind(org: { legal_form?: string | null; cit_profile?: Record<string, unknown> | null } | null | undefined): IncomeTaxKind {
  const cp = (org?.cit_profile || {}) as Record<string, unknown>;
  if (org?.legal_form === 'ngo' || cp.limited_by_guarantee) return cp.ngo_trades ? 'cit' : 'exempt';
  if (!org?.legal_form || org.legal_form === 'company') return 'cit';
  return 'pit';
}
export const INCOME_TAX_LABEL: Record<IncomeTaxKind, string> = { cit: 'Companies income tax', pit: 'Personal income tax', exempt: 'Income tax' };
export const PIT_STATE: Record<string, { label: string; tone: string }> = {
  draft: { label: 'Draft', tone: 't-grey' }, approved: { label: 'Approved', tone: 't-blue' }, sent: { label: 'With Flux', tone: 't-amber' },
  filed: { label: 'Filed', tone: 't-green' }, rejected: { label: 'Sent back', tone: 't-red' }, filed_outside: { label: 'Filed outside Counta', tone: 't-green' },
};
export const pitLaw = (regime?: string | null) => (regime === 'PITA' ? 'Personal Income Tax Act (old law)' : 'Nigeria Tax Act 2025');
export const RELIEFS: { id: string; label: string; law: 'both' | 'nta' | 'pita'; hint?: string }[] = [
  { id: 'pension', label: 'Pension contributions', law: 'both', hint: 'Under the Pension Reform Act, paid by the person' },
  { id: 'nhf', label: 'National Housing Fund', law: 'both' },
  { id: 'nhis', label: 'Health insurance (NHIS or an HMO)', law: 'both' },
  { id: 'life_insurance', label: 'Life insurance or deferred annuity premiums', law: 'both', hint: 'For the person or their spouse' },
  { id: 'home_loan_interest', label: 'Interest on a loan for a home they live in', law: 'both' },
  { id: 'gratuity', label: 'Gratuity', law: 'pita' },
  { id: 'rent_paid', label: 'Rent paid for their home this year', law: 'nta', hint: '20% of it comes off, at most ₦500,000. Leave out any part claimed as business rent.' },
];
// Each choice is a kind of income for the rule book and, where the state portal splits it, the line it goes on (field).
export const OTHER_INCOME: { id: string; label: string; hint?: string; kind?: string; field?: string }[] = [
  { id: 'employment', label: 'Salary from a job', hint: 'With the PAYE taken off' },
  { id: 'employment:commission', kind: 'employment', field: 'commission', label: 'Commission from a job', hint: 'With the PAYE taken off' },
  { id: 'employment:allowance', kind: 'employment', field: 'allowance', label: 'Allowances from a job', hint: 'Housing, transport and other allowances, with the PAYE taken off' },
  { id: 'rent', label: 'Rent received', hint: 'After the costs of letting, with any WHT taken off' },
  { id: 'dividend', label: 'Dividends', hint: 'Taxed in full where WHT was taken off' },
  { id: 'interest', label: 'Interest', hint: 'Taxed in full where WHT was taken off' },
  { id: 'royalty', label: 'Royalties' },
  { id: 'foreign_earned', label: 'Fees or pay earned abroad', hint: 'Enter the foreign tax paid as tax deducted' },
  { id: 'foreign_investment', label: 'Foreign dividends, interest, rent or royalties through a domiciliary account', hint: 'Exempt' },
  { id: 'gov_bond_interest', label: 'Interest on government bonds', hint: 'Exempt' },
  { id: 'pension_gratuity', label: 'Pension or gratuity received', hint: 'Exempt' },
  { id: 'pension_gratuity:annuity', kind: 'pension_gratuity', field: 'annuity', label: 'Annuity received', hint: 'Exempt when paid under the Pension Reform Act' },
  { id: 'other', label: 'Other income' },
];
// The choice an income line shows, from its kind and the portal line it goes on, and back.
export const incomeChoice = (l: { kind: string; field?: string | null }) =>
  OTHER_INCOME.find((x) => (x.kind || x.id) === l.kind && (x.field || null) === (l.field && !['salary', 'pension'].includes(l.field) ? l.field : null))?.id || l.kind;
export const incomeOf = (choice: string) => { const x = OTHER_INCOME.find((o) => o.id === choice); return { kind: x?.kind || choice, field: x?.field || null }; };
// The accommodation the state portal asks about before anything else on the return.
export const HOME_TYPES: { id: string; label: string }[] = [
  { id: 'flat', label: 'Flat or apartment' }, { id: 'room', label: 'Room or self-contained' }, { id: 'bungalow', label: 'Bungalow' }, { id: 'duplex', label: 'Duplex' },
  { id: 'terrace', label: 'Terrace house' }, { id: 'detached', label: 'Detached house' }, { id: 'other', label: 'Other' },
];
export const OCCUPANCY: { id: string; label: string }[] = [
  { id: 'tenant', label: 'Rents it (tenant)' }, { id: 'owner', label: 'Owns it (landlord)' }, { id: 'employer', label: 'Provided by an employer' },
  { id: 'family', label: 'Lives with family, pays no rent' },
];
export const lawShort = (regime?: string | null) => (regime === 'LEGACY_CITA' ? 'CITA' : 'NTA 2025');
export const lawLong = (regime?: string | null) => (regime === 'LEGACY_CITA' ? 'Companies Income Tax Act (as amended to 2023)' : 'Nigeria Tax Act 2025');

export const SECTIONS: { id: string; sheet: string; label: string }[] = [
  { id: 'revenue', sheet: 'INCOME_STATEMENT', label: 'Revenue by sector' },
  { id: 'cost_of_sales', sheet: 'INCOME_STATEMENT', label: 'Cost of sales' },
  { id: 'other_income', sheet: 'OTHER_INCOME', label: 'Other income' },
  { id: 'admin', sheet: 'ADMINISTRATIVE_EXPENSES', label: 'Administrative and operating expenses' },
  { id: 'pl', sheet: 'INCOME_STATEMENT', label: 'Finance costs, taxation and retained earnings' },
  { id: 'oci', sheet: 'INCOME_STATEMENT', label: 'Other comprehensive income' },
  { id: 'sofp_assets', sheet: 'STATEMENT_OF_FINANCIAL_POSITION', label: 'Assets' },
  { id: 'sofp_liabilities', sheet: 'STATEMENT_OF_FINANCIAL_POSITION', label: 'Current liabilities' },
  { id: 'sofp_noncurrent', sheet: 'STATEMENT_OF_FINANCIAL_POSITION', label: 'Non-current liabilities' },
  { id: 'sofp_equity', sheet: 'STATEMENT_OF_FINANCIAL_POSITION', label: 'Equity' },
];

export const SOURCE_LABEL: Record<string, { label: string; tone: string }> = {
  books: { label: 'Books', tone: 't-grey' }, override: { label: 'Changed', tone: 't-amber' }, manual: { label: 'Entered', tone: 't-blue' },
  afs: { label: 'Audited accounts', tone: 't-purple' }, trial_balance: { label: 'Trial balance', tone: 't-purple' }, imported: { label: 'Imported', tone: 't-purple' },
  adjustment: { label: 'Adjustment', tone: 't-grey' },
};

// The Rev360 asset categories (the template's config list), which decide the capital allowance class and rate.
export const CA_CATEGORIES = [
  'Building Industrial', 'Building Non-Industrial', 'Plants (excluding Furniture and fittings)', 'Furnitures & Fittings expenditure', 'Motor vehicles expenditure',
  'Public Transport motor vehicles', 'software', 'Agricultural plants expenditure', 'Plantation equipments expenditure',
  'Construction Plants expenditure (excluding furniture & fittings)', 'research and development expenditure', 'Housing estate expenditure', 'ranching and plantation',
  'Others', 'Land',
];

export const WVAT_AGENTS: { id: string; label: string }[] = [
  { id: 'bank', label: 'A bank or other financial institution' }, { id: 'telecom', label: 'A telecommunications company' },
  { id: 'oil_gas', label: 'An oil and gas company' }, { id: 'government', label: 'A government ministry, department or agency' },
  { id: 'digital_platform', label: 'A digital platform or marketplace' }, { id: 'other', label: 'Another company the NRS appointed' },
];

export const ENTITY_TYPES: { id: string; label: string; corporate: boolean }[] = [
  { id: 'company', label: 'Limited company (Ltd)', corporate: true }, { id: 'plc', label: 'Public company (Plc)', corporate: true },
  { id: 'llp', label: 'Limited liability partnership (LLP)', corporate: true }, { id: 'ltd_gte', label: 'Company limited by guarantee', corporate: true },
  { id: 'ngo', label: 'NGO or incorporated trustees', corporate: true }, { id: 'government', label: 'Government body (exempt)', corporate: true },
  { id: 'business_name', label: 'Business name (Enterprises, Ventures...)', corporate: false }, { id: 'sole_proprietor', label: 'Sole trader', corporate: false },
  { id: 'partnership', label: 'Partnership', corporate: false }, { id: 'lp', label: 'Limited partnership (LP)', corporate: false },
  { id: 'individual', label: 'Individual', corporate: false },
];

// The rate on the NRS table for a supplier: company or not, in Nigeria or not.
export function matrixRate(r: any, corporate: boolean, resident: boolean): number | null {
  if (!r) return null;
  if (r.exemption) return 0;
  const v = corporate ? (resident ? r.rate_corp_res : r.rate_corp_nonres) : (resident ? r.rate_ind_res : r.rate_ind_nonres);
  return v == null ? null : Number(v);
}
export const pct = (r: number | null | undefined, dp = 1) => (r == null ? 'n/a' : `${(Number(r) * 100).toFixed(dp).replace(/\.0+$/, '')}%`);

export const monthName = (d: string | null | undefined) => (d ? new Date(d.slice(0, 7) + '-15T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }) : '');
export const monthShort = (d: string | null | undefined) => (d ? new Date(d.slice(0, 7) + '-15T12:00:00Z').toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' }) : '');
export const addMonths = (d: string, n: number) => { const x = new Date(d.slice(0, 7) + '-01T12:00:00Z'); x.setUTCMonth(x.getUTCMonth() + n); return x.toISOString().slice(0, 10); };

export function authorityLabel(code: string | null | undefined, list?: { code: string; short_name?: string | null; name: string; state?: string | null }[]) {
  if (!code) return 'Not known';
  if (code === 'NRS') return 'NRS';
  const a = list?.find((x) => x.code === code);
  return a ? (a.state ? `${a.state} (${a.short_name || a.name})` : a.short_name || a.name) : 'the state revenue service';
}
