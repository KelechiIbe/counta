// Onboarding: the business profile (CAC through Mono, the web through Gemini), the questions, the compliance score,
// the CAC document, Martina's checklist and the Nigerian voices. Every write goes through the database's own checks.
import { useQuery } from '@tanstack/react-query';
import { ai, cleanError, rpc, supabase } from './supabase';
import { edge } from './api';
import type { Mode } from './wording';

// ---------------------------------------------------------------- types
export interface Candidate { id: number | string; name: string; rc_number?: string; classification?: string; active?: boolean; registered_on?: string; address?: string; state?: string; city?: string }
export interface Person { name: string; appointed?: string | null; chairman?: boolean; status?: string | null }
export interface Holder { name: string; shares?: number | null; type?: string | null }
export interface Business {
  name: string; cac_id?: number | string | null; rc_number?: string | null; classification?: string | null; company_type?: string | null; registered_on?: string | null;
  commenced_on?: string | null; active?: boolean | null; objectives?: string | null; nature?: string | null; address?: string | null; branch_address?: string | null;
  state?: string | null; email?: string | null; share_capital?: number | null; issued_shares?: number | null; tax_id?: string | null;
  directors: Person[]; shareholders: Holder[]; psc: Holder[]; secretary?: string | null;
  tin?: { taxpayer_name?: string | null; nrs_tin?: string | null; tax_office?: string | null; tin_type?: string | null } | null;
}
export interface WebInsights {
  found_online: boolean; summary: string | null; website: string | null; socials: { platform: string; url: string }[]; sells: string[];
  offering_guess: 'goods' | 'services' | 'both' | null; category_guess: string | null; confidence: number | null; observations: string[];
  sources: { title: string; url: string }[]; searched_web?: boolean; at?: string;
}
export type Filing = 'always' | 'sometimes' | 'never' | 'not_sure' | 'not_applicable';
export interface Answers {
  offering?: 'goods' | 'services' | 'both'; category?: string; revenue_band?: '0_50m' | '50_100m' | 'over_100m';
  receive_methods?: string[]; pay_methods?: string[]; reasons?: string[]; reason_note?: string; examples?: string[];
  filing?: { vat?: Filing; wht?: Filing; cit?: Filing }; charges_vat?: boolean;
}
export interface Kyc {
  id: string; status: 'draft' | 'submitted'; source: 'cac' | 'manual' | null; org_id: string | null;
  search: { query: string | null; candidates: Candidate[]; at: string | null };
  business: Business | null; web: WebInsights | null; answers: Answers; missing: string[];
  category: { id: string; label: string; industry: string } | null;
  doc: { kind: string; file_name: string; path: string; read: boolean; extract: any; checks: { id: string; ok: boolean; note: string }[] | null; at: string } | null;
  submitted_at: string | null; updated_at: string;
  // The company is on Counta already (one company, one business): who holds it, masked, and the person's recovery of it.
  taken?: { name: string; masked_email: string | null; yours: boolean; recovery_id: string | null } | null;
}
export interface ScoreItem { id: string; label: string; ok: boolean; text: string; action: string | null }
export interface Score { score: number; total: number; items: ScoreItem[]; next: ScoreItem | null }
export interface GuideStep { id: string; phase: 'profile' | 'first_steps'; optional: boolean; done: boolean; skipped: boolean }
export interface GuideState {
  steps: GuideStep[]; done: number; total: number; next: string | null; completed: boolean; dismissed: boolean;
  org: { id: string; name: string; industry: string; voice_id: string | null; voice_lang: 'en' | 'pcm'; is_owner: boolean; created_at: string } | null;
  first_name: string; language: 'en' | 'pcm'; marks: Record<string, string>; call: { consent: boolean; phone: string | null; status: string };
}
export interface Category { id: string; label: string; kind: 'goods' | 'services' | 'both'; industry: string; sort: number }
export interface Voice { voice_id: string; name: string; gender: string | null; age: string | null; accent: string | null; description: string | null }

// ---------------------------------------------------------------- labels
export const OFFERING = [
  { id: 'goods', label: 'Goods', hint: 'Things people can hold' },
  { id: 'services', label: 'Services', hint: 'Work, skills or time' },
  { id: 'both', label: 'Both', hint: 'A bit of each' },
] as const;
export const REVENUE = [
  { id: '0_50m', label: 'Up to ₦50 million', hint: 'a year' },
  { id: '50_100m', label: '₦50m to ₦100 million', hint: 'a year' },
  { id: 'over_100m', label: 'Above ₦100 million', hint: 'a year' },
] as const;
export const RECEIVE = [
  { id: 'cash', label: 'Cash' }, { id: 'bank_transfer', label: 'Bank transfer' }, { id: 'pos', label: 'POS' }, { id: 'payment_links', label: 'Payment links' },
  { id: 'ussd', label: 'USSD' }, { id: 'mobile_money', label: 'Mobile money' }, { id: 'cheque', label: 'Cheque' }, { id: 'crypto', label: 'Crypto' }, { id: 'other', label: 'Something else' },
];
export const PAY = [
  { id: 'bank_transfer', label: 'Bank transfer' }, { id: 'cash', label: 'Cash' }, { id: 'card', label: 'Card' }, { id: 'pos', label: 'POS' },
  { id: 'mobile_money', label: 'Mobile money' }, { id: 'cheque', label: 'Cheque' }, { id: 'other', label: 'Something else' },
];
export const REASONS = [
  { id: 'track_sales', label: 'Track my sales' }, { id: 'manage_stock', label: 'Manage stock' }, { id: 'get_paid', label: 'Get paid faster' },
  { id: 'bookkeeping', label: 'Keep proper books' }, { id: 'tax_compliance', label: 'Sort out my taxes' }, { id: 'financial_statements', label: 'Financial statements' },
  { id: 'loans', label: 'Get a loan' }, { id: 'pay_suppliers', label: 'Pay suppliers and staff' }, { id: 'team', label: 'Manage my team' }, { id: 'other', label: 'Something else' },
];
export const FILING: { id: Filing; label: string }[] = [
  { id: 'always', label: 'Always' }, { id: 'sometimes', label: 'Sometimes' }, { id: 'never', label: 'Never' }, { id: 'not_sure', label: 'Not sure' }, { id: 'not_applicable', label: "Doesn't apply" },
];
export const TAXES = [
  { id: 'vat', label: 'VAT returns', q: 'Do you file VAT returns?', hint: 'Monthly, by the 21st' },
  { id: 'wht', label: 'Withholding tax', q: 'Do you deduct and file withholding tax?', hint: 'When you pay for services, rent and contracts' },
  { id: 'cit', label: 'Income tax', q: 'Do you file your income tax return?', hint: 'Once a year' },
] as const;
type Tax = { id: 'vat' | 'wht' | 'cit'; label: string; q: string; hint: string };
// How the business's profit is taxed: a company pays companies income tax; a business name (and a business not registered
// yet) pays none, and its profit is taxed as its owners' personal income tax. The same rule as private.income_tax_kind.
export type IncomeTax = 'company' | 'personal' | 'unknown';
export function incomeTaxOf(b: Pick<Business, 'classification'> | null | undefined, source?: Kyc['source']): IncomeTax {
  const c = String(b?.classification || '').toUpperCase();
  if (c.startsWith('COMPANY')) return 'company';
  if (c === 'BUSINESS_NAME' || c === 'LP' || source === 'manual') return 'personal';
  return 'unknown';
}
// The three tax questions, the income tax one in the business's own terms.
export function taxesFor(kind: IncomeTax): Tax[] {
  return TAXES.map((t): Tax => t.id !== 'cit' ? t
    : kind === 'company' ? { id: 'cit', label: 'Companies income tax', q: 'Do you file your companies income tax return?', hint: 'Once a year, within six months of your year end' }
    : kind === 'personal' ? { id: 'cit', label: 'Personal income tax', q: "Do the owners file personal income tax returns on the business's profit?",
        hint: "A business name pays no companies income tax. Its profit is taxed as its owners' income, with the state, by 31 March every year." }
    : t);
}
// The onboarding questions in the order Martina asks them; the screen shows one at a time in the same order.
export const QUESTION_ORDER = ['offering', 'category', 'revenue_band', 'receive_methods', 'pay_methods', 'reasons', 'examples', 'filing_vat', 'filing_wht', 'filing_cit'] as const;
export type QuestionId = (typeof QUESTION_ORDER)[number];
// The questions this business is asked: a business that sells services only is not asked for products it sells.
export const questionsFor = (a: Partial<Answers>): QuestionId[] => QUESTION_ORDER.filter((q) => !(q === 'examples' && a.offering === 'services'));
// Whether a question has its answer (the same rules as the database's list of what is missing).
export function answered(id: string, a: Partial<Answers>): boolean {
  switch (id) {
    case 'offering': case 'category': case 'revenue_band': return Boolean((a as any)[id]);
    case 'examples': return a.offering === 'services' || Boolean((a.examples || []).length);
    case 'receive_methods': case 'pay_methods': return Boolean(((a as any)[id] || []).length);
    case 'reasons': return Boolean((a.reasons || []).length || String(a.reason_note || '').trim());
    case 'filing_vat': case 'filing_wht': case 'filing_cit': return Boolean(a.filing?.[id.slice(7) as 'vat' | 'wht' | 'cit']);
    default: return false;
  }
}
export const QUESTION_LABEL: Record<string, string> = {
  offering: 'Goods or services', category: 'Category', revenue_band: 'Yearly sales', receive_methods: 'How customers pay you', pay_methods: 'How you pay others',
  reasons: 'Why Counta', examples: 'What you sell', filing_vat: 'VAT returns', filing_wht: 'Withholding tax', filing_cit: 'Income tax',
};
export const STEP_TEXT: Record<string, { title: string; body: string; cta: string; to?: string }> = {
  find_business: { title: 'Find your business', body: 'On the CAC register, or tell us it is not registered yet.', cta: 'Find it', to: '/onboarding' },
  questions: { title: 'A few questions', body: 'So Counta fits the way you sell and get paid.', cta: 'Answer', to: '/onboarding' },
  submitted: { title: 'Check and set up', body: 'Review the summary and set up the business.', cta: 'Review', to: '/onboarding' },
  cac_document: { title: 'Your CAC status report', body: 'Counta can fetch it from CAC, or you upload it.', cta: 'Add it', to: '/onboarding?screen=document' },
  account_number: { title: 'Your business account number', body: 'Customers pay into it and every payment lands in your books.', cta: 'Get it' },
  voice: { title: 'Choose the voice that announces payments', body: 'A Nigerian voice says "payment received" the moment money lands.', cta: 'Choose' },
  first_sale: { title: 'Record your first sale', body: 'At the till, by invoice, or just by talking.', cta: 'Open the till', to: '/sell/till' },
  bank_connect: { title: 'Connect your bank account', body: 'Bank lines flow in and match your sales and bills.', cta: 'Connect', to: '/accounting/banking' },
  bank_statement: { title: 'Upload a bank statement', body: 'A PDF or Excel from any Nigerian bank.', cta: 'Upload', to: '/accounting/banking' },
  products: { title: 'Add your products', body: 'Type a few, scan barcodes, or import a spreadsheet.', cta: 'Add', to: '/inventory/items' },
  team: { title: 'Invite your team', body: 'Each person sees only what their role allows.', cta: 'Invite', to: '/inventory/locations' },
};
// A step in the business's own terms: a professional services firm issues its first invoice; a services business without
// walk-in customers records its first sale by invoice or receipt, with no till.
export function stepText(id: string, mode: Mode): { title: string; body: string; cta: string; to?: string } | undefined {
  if (id === 'first_sale' && mode.professional) return { title: 'Issue your first invoice', body: 'To a client, for work you have done. Counta posts it to your books.', cta: 'New invoice', to: '/sell/sales?new=invoice' };
  if (id === 'first_sale' && !mode.till) return { title: 'Record your first sale', body: 'By invoice or receipt, or just by talking.', cta: 'New invoice', to: '/sell/sales?new=invoice' };
  if (id === 'first_sale' && mode.walkIn) return { title: 'Record your first sale', body: 'At the till, by invoice, or just by talking.', cta: 'Open the till', to: '/sell/till' };
  return STEP_TEXT[id];
}

// ---------------------------------------------------------------- reads
export function useKyc(orgId?: string | null, enabled = true) {
  return useQuery({
    queryKey: ['kyc', orgId || 'mine'],
    enabled,
    queryFn: () => rpc<Kyc>('kyc_draft', orgId ? { p_org: orgId } : {}),
    staleTime: 10_000,
  });
}
// The person's progress; for a business they are in, that business (else the newest one they own).
export function useGuide(enabled = true, orgId?: string | null) {
  return useQuery({ queryKey: ['guide', orgId || 'auto'], enabled, queryFn: () => rpc<GuideState>('guide_state', orgId ? { p_org: orgId } : {}), staleTime: 15_000 });
}
export function useCategories() {
  return useQuery({
    queryKey: ['business-categories'], staleTime: 3600_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('business_categories').select('id, label, kind, industry, sort').order('sort');
      if (error) throw new Error(cleanError(error));
      return (data || []) as Category[];
    },
  });
}
export function useScore(orgId: string | null | undefined) {
  return useQuery({ queryKey: ['compliance', orgId], enabled: !!orgId, queryFn: () => rpc<Score>('compliance_score', { p_org: orgId }) });
}
export function useVoices(enabled = true) {
  return useQuery({
    queryKey: ['tts-voices'], enabled, staleTime: 10 * 60_000,
    queryFn: async () => {
      const r = await edge<{ voices: Voice[]; configured: boolean }>('voice', { action: 'voices' });
      return { configured: r.configured !== false && r.ok !== false, voices: (r.voices || []) as Voice[] };
    },
  });
}

// ---------------------------------------------------------------- writes
const must = <T>(r: T & { ok?: boolean; error?: string }) => { if (r && r.ok === false) throw new Error(r.error || 'Something went wrong.'); return r; };
export const cacConfig = () => edge<{ lookup: boolean }>('mono', { action: 'cac_config' });
// org: the business being completed (/onboarding?org=…). A business a practice runs under full mandate has its own profile,
// so every call about it names it; without org, the person's own profile.
// Callers that do not say (the onboarding screens, Martina) mean the business on the onboarding page's address, if any.
export function onboardOrg(): string | null {
  try { return window.location.pathname.startsWith('/onboarding') ? new URLSearchParams(window.location.search).get('org') : null; } catch { return null; }
}
const forOrg = (org?: string | null) => { const o = org === undefined ? onboardOrg() : org; return o ? { org_id: o } : {}; };
export const cacSearch = async (query: string, org?: string | null) => must(await edge<{ kyc: Kyc }>('mono', { action: 'cac_search', query, ...forOrg(org) })).kyc;
export const cacSelect = async (cac_id: string | number, org?: string | null) =>
  must(await edge<{ kyc: Kyc; tax_note: string | null }>('mono', { action: 'cac_select', cac_id, ...forOrg(org) }));
export const cacStatusReport = async (org_id: string) => must(await edge<{ kyc: Kyc; document: { path: string; file_name: string } }>('mono', { action: 'cac_status_report', org_id }));
export const webInsights = async (org_id?: string | null) => must(await ai<{ kyc: Kyc; insights: WebInsights }>('business_insights', org_id ? { org_id } : {}));
export const readCacDocument = async (org_id: string) => must(await ai<{ kyc: Kyc; extract: any; checks: { id: string; ok: boolean; note: string }[] }>('read_cac_document', { org_id }));
export const kycManual = (p: { name: string; kind: string; address?: string; state?: string; rc_number?: string }, org?: string | null) =>
  rpc<Kyc>('kyc_manual', { p: { ...p, ...forOrg(org) } });
export const kycAnswer = (p: Partial<Answers>, org?: string | null) => rpc<Kyc>('kyc_answer', { p: { ...p, ...forOrg(org) } });
// A business a practice runs is refused, without an error, when the company is already someone else's on Counta: TaxStreem
// is told and nothing is submitted. So is an owner's own profile of a company an accounting firm already runs for its owner.
export const DUPLICATE_COMPANY = 'This company is already on Counta under someone else, so the profile was not submitted. TaxStreem has been told and will contact the firm.';
export const MANAGED_ELSEWHERE = 'This company is already on Counta: an accounting firm runs it for its owner. Ask the firm to hand it over to you. TaxStreem has been told.';
// A company already on Counta (reason 'exists'): what the person is told, with how to recover it.
export const existsText = (business: string, masked: string | null, yours: boolean) => yours
  ? `You run ${business} on Counta already. Open it from your businesses instead of setting it up again.`
  : `${business} is already on Counta${masked ? `, under the account ${masked}` : ''}. A company is on Counta once. If you are a director on its CAC record, recover it instead.`;
export class CompanyExists extends Error {
  constructor(readonly business: string, readonly masked: string | null, readonly yours: boolean) { super(existsText(business, masked, yours)); }
}
export async function kycSubmit(p: Record<string, unknown>, org?: string | null) {
  const r = await rpc<{ ok?: boolean; reason?: string; org_id: string; name: string; compliance: Score; business?: string; masked_email?: string | null; yours?: boolean }>(
    'kyc_submit', { p: { ...p, ...forOrg(org) } });
  if (r && r.ok === false) {
    if (r.reason === 'exists') throw new CompanyExists(String(r.business || 'This company'), r.masked_email ?? null, r.yours === true);
    throw new Error(r.reason === 'duplicate' ? DUPLICATE_COMPANY : r.reason === 'managed_elsewhere' ? MANAGED_ELSEWHERE : 'The profile could not be submitted just now.');
  }
  return r;
}
export const kycDoc = (org: string, path: string, kind: string, fileName?: string) => rpc<Kyc>('kyc_doc', { p_org: org, p_path: path, p_kind: kind, p_file_name: fileName ?? null });
export const guideMark = (mark: string) => rpc<GuideState>('guide_mark', { p_mark: mark });
export const guideLanguage = (lang: 'en' | 'pcm') => rpc<GuideState>('guide_language', { p_lang: lang });
export const guideConsent = (consent: boolean, phone?: string | null) => rpc<GuideState>('guide_consent', { p_consent: consent, p_phone: phone ?? null });
export const saveVoice = (org: string, p: Record<string, unknown>) => rpc('save_voice_settings', { p_org: org, p });
export const openWallet = async (org_id: string) => must(await edge<{ wallet: { account_number: string | null; bank_name: string | null; account_name: string | null; status: string } }>('payments', { action: 'open_wallet', org_id })).wallet;

// The CAC document the owner picks, into the owner-only CAC folder, then read.
export async function uploadCacDocument(org: string, file: File, kind: string) {
  if (file.size > 15 * 1024 * 1024) throw new Error('That file is larger than 15 MB. Upload just the status report pages.');
  if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(file.type)) throw new Error('Upload a PDF or a photo (JPG or PNG).');
  const ext = file.type === 'application/pdf' ? 'pdf' : file.type.split('/')[1].replace('jpeg', 'jpg');
  const path = `${org}/kyc/${kind.replace('_', '-')}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw new Error(cleanError(error));
  return await kycDoc(org, path, kind, file.name);
}

// ---------------------------------------------------------------- small helpers
// "PLOT 5, ALLEN AVENUE" becomes "Plot 5, Allen Avenue"; codes such as LTD, MSTO and FCT, and initials like O.K., stay in capitals.
const CAPS = new Set(['LTD', 'PLC', 'LLC', 'MSTO', 'LTO', 'MTO', 'FCT', 'LGA', 'NRS', 'FIRS', 'CAC', 'RC', 'BN', 'NG', 'UK', 'USA', 'UAE', 'GTB', 'UBA', 'FCMB', 'POS',
  'VAT', 'WHT', 'CIT', 'II', 'III', 'IV', 'ICT', 'NGO', 'HQ']);
export const titleCase = (s?: string | null) => String(s || '').replace(/\p{L}[\p{L}'.]*/gu, (w) => {
  const bare = w.replace(/\.$/, '');
  if (CAPS.has(bare.toUpperCase()) || /^(\p{L}\.){2,}$/u.test(w)) return w.toUpperCase();
  return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
});
export const classLabel = (c?: string | null) => ({ COMPANY: 'Limited company', BUSINESS_NAME: 'Business name', IT: 'Incorporated trustees', LP: 'Limited partnership' } as Record<string, string>)[String(c || '').toUpperCase()]
  || (c === 'unregistered' ? 'Not registered yet' : c === 'pending' ? 'Registration in progress' : c ? titleCase(c.replace(/_/g, ' ')) : '');
export const naira = (n?: number | null) => n == null ? '' : '₦' + Number(n).toLocaleString('en-NG', { maximumFractionDigits: 0 });
export const longDate = (d?: string | null) => d ? new Date(d + (d.length === 10 ? 'T12:00:00Z' : '')).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }) : '';
export const yearsSince = (d?: string | null) => { if (!d) return null; const y = (Date.now() - Date.parse(d)) / (365.25 * 86400_000); return y >= 1 ? Math.floor(y) : null; };
