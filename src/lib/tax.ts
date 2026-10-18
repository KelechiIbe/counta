// Reads and labels for the tax returns: companies income tax by accounting year, VAT by month, and withholding tax (and VAT
// withheld) by month and tax authority.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { useSession } from '../state/session';

function useOrgQ<T>(key: unknown[], fn: (org: string) => Promise<T>, enabled = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: [...key, orgId], enabled: !!orgId && enabled, queryFn: () => fn(orgId!) });
}

export const useCitYears = (enabled = true) => useOrgQ<any>(['cit-years'], (o) => rpc('cit_years', { p_org: o }), enabled);
export const useCitYear = (year: number | null) => useOrgQ<any>(['cit-year', year], (o) => rpc('cit_year', { p_org: o, p_year: year }), !!year);
export const useTaxProfile = (enabled = true) => useOrgQ<any>(['tax-profile'], (o) => rpc('tax_profile', { p_org: o }), enabled);
export const useVatPosition = (from: string, to: string, enabled = true) =>
  useOrgQ<any>(['vat-position', from, to], (o) => rpc('vat_position', { p_org: o, p: { from, to } }), enabled);
export const useWithholding = (from: string, to: string, enabled = true) =>
  useOrgQ<any>(['withholding', from, to], (o) => rpc('withholding_overview', { p_org: o, p: { from, to } }), enabled);
export const useWhtReceipts = (filter: Record<string, unknown>, enabled = true) =>
  useOrgQ<any[]>(['wht-receipts', JSON.stringify(filter)], (o) => rpc('wht_receipts', { p_org: o, p: filter }), enabled);
export const useVendorTax = (vendor: string | null) => useOrgQ<any>(['vendor-tax', vendor], (o) => rpc('vendor_tax_details', { p_org: o, p_vendor: vendor }), !!vendor);

// Everything a tax action can change.
export const TAX_KEYS = ['cit-years', 'cit-year', 'tax-profile', 'vat-position', 'withholding', 'wht-receipts', 'vendor-tax', 'bills', 'bill', 'fs-pack', 'report', 'ledger', 'inbox'];

export const CIT_STATUS: Record<string, { label: string; tone: string }> = {
  draft: { label: 'Draft', tone: 't-grey' }, approved: { label: 'Approved', tone: 't-blue' }, sent: { label: 'With Flux', tone: 't-amber' },
  filed: { label: 'Filed', tone: 't-green' }, rejected: { label: 'Sent back', tone: 't-red' },
};
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
