// What the admin portal reads and writes. Every call carries the person's own session, which the database checks for a
// TaxStreem admin who entered an authenticator code (aal2); the admin edge function checks the same.
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { edge } from '../lib/api';

export type AdminMe = { admin: boolean; reviewer: boolean; staff: boolean; aal2: boolean };
export const useAdminMe = (enabled = true) =>
  useQuery({ queryKey: ['admin-me'], enabled, staleTime: 60_000, queryFn: () => rpc<AdminMe>('admin_me').catch(() => ({ admin: false, reviewer: false, staff: false, aal2: false })) });

export type KeyRow = {
  name: string; group: string; label: string; secret: boolean; hint: string | null; set: boolean; shown: string | null; set_at: string | null; set_by: string | null;
  env: boolean;
};
export type KeysStatus = {
  ok: boolean; error?: string; keys: KeyRow[];
  webhooks: { flutterwave: { url: string; last: { rail: string; event: string; received_at: string; outcome: string | null; error: string | null } | null };
    mono: { url: string }; whatsapp: { url: string; last: string | null }; flux: { url: string }; openwa?: { messaging: string; chat: string } };
  whatsapp?: { counta: { id: string; status: string; phone: string | null; status_at: string; last_error: string | null } | null;
    businesses: { id: string; org_id: string; business: string; status: string; phone: string | null; status_at: string; sender: string }[];
    links: number; siri: number; turns_today: number } | null;
};
export const useKeys = () => useQuery({ queryKey: ['admin-keys'], queryFn: () => edge<KeysStatus>('admin', { action: 'status' }) });

export type Settings = {
  martina: { tone: 'calm' | 'warm' | 'lively'; default_voice_id: string | null; voice_model?: 'eleven_v4_turbo' | 'eleven_turbo_v2_5' | 'eleven_flash_v2_5' };
  limits: Record<string, any>; switches: Record<string, boolean>;
  defaults: { martina: any; limits: Record<string, any>; switches: Record<string, boolean> };
  voices: { voice_id: string; name: string; gender: string | null; age: string | null; accent: string | null; description: string | null; preview_url: string | null;
    source: string; active: boolean; sort: number; businesses: number }[];
  overrides: { org_id: string; business: string; feature: string; enabled: boolean; note: string | null; set_at: string }[];
  updated: Record<string, { at: string; by: string | null }>;
};
export const useSettings = () => useQuery({ queryKey: ['admin-settings'], queryFn: () => rpc<Settings>('admin_settings') });

export type Overview = {
  admin: boolean; reviews: number; businesses: { total: number; week: number; locked: number } | null; people: { total: number; week: number } | null;
  failures_day: number | null; paused: string[] | null; business_overrides: number | null;
};
export const useOverview = () => useQuery({ queryKey: ['admin-overview'], queryFn: () => rpc<Overview>('admin_overview') });

export const FEATURES: { id: string; label: string; what: string }[] = [
  { id: 'new_businesses', label: 'New businesses', what: 'People can sign up and set up a new business. The sample business and TaxStreem sign-ins always work.' },
  { id: 'martina', label: 'Martina', what: 'The onboarding guide and the assistant, by voice and typing.' },
  { id: 'phone_calls', label: 'Phone calls', what: 'Martina phoning suppliers with orders, staff with reminders, and people who asked for a follow-up.' },
  { id: 'payment_voice', label: 'Spoken announcements', what: '"Payment received" and sales read back in the business\'s Nigerian voice.' },
  { id: 'ai_reading', label: 'AI reading', what: 'Invoice and statement reading, product photos, CAC documents, NIN slips and the bookkeeper.' },
  { id: 'email', label: 'Email to customers', what: 'Invoices, receipts, statements and reminders by email. Invitations to the team still go.' },
  { id: 'whatsapp', label: 'WhatsApp to customers', what: 'The same messages by WhatsApp.' },
  { id: 'payments', label: 'Payments', what: 'Business account numbers, payment links, QR codes and payouts. Money already on its way is still recorded.' },
  { id: 'bulk_payments', label: 'Bulk payments', what: 'Paying many people at once from a spreadsheet, contractors included. Single payouts still work.' },
  { id: 'bank_feeds', label: 'Bank feeds', what: 'Linking bank accounts through Mono. Accounts already linked keep their history.' },
  { id: 'supplier_portal', label: 'Supplier invoice portal', what: 'The link suppliers use to upload invoices. Invoices can still be uploaded by the business.' },
];
export const featureLabel = (id: string) => FEATURES.find((f) => f.id === id)?.label || id;

export const GROUPS: { id: string; title: string; what: string; test?: boolean; noKeys?: string }[] = [
  { id: 'gemini', title: 'Google Gemini', what: 'Reads invoices, statements, product photos, CAC documents and NIN slips; the bookkeeper and Martina\'s typed answers.', test: true },
  { id: 'elevenlabs', title: 'ElevenLabs', what: 'The Nigerian voices, Martina by voice, and phone calls through the connected Twilio number.', test: true },
  { id: 'flutterwave', title: 'Flutterwave', what: 'Business account numbers, payment links, QR codes, payouts, and Counta plans paid by card or from the wallet.', test: true },
  { id: 'mono', title: 'Mono', what: 'Bank feeds, and the CAC, Tax ID and NIN lookups in onboarding.', test: true },
  { id: 'email', title: 'Email (Resend)', what: 'Invoices, receipts, reminders, invitations and these admin alerts.', test: true },
  { id: 'whatsapp', title: 'WhatsApp Business (official API)', what: 'Invoices, receipts and reminders through Meta\'s official API, when "Which WhatsApp sends" below is meta.', test: true },
  { id: 'openwa', title: 'WhatsApp through OpenWA', what: 'TaxStreem\'s own WhatsApp number on its OpenWA server: invoices, receipts, reminders and alerts, and Martina on WhatsApp. Unofficial: WhatsApp may restrict a number linked to it.', test: true },
  { id: 'numens', title: 'Numens', what: 'TaxStreem\'s tax model for the VAT treatment of items. Gemini stands in without it.', test: true },
  { id: 'taxstreem', title: 'TaxStreem', what: 'Single sign-on from TaxStreem; Prism, which sends bills and partners\' invoices and hears back how each invoice went with NRS; and Flux, which files returns on Rev360.', test: true },
  { id: 'nrs', title: 'NRS e-invoicing (MBS)', what: 'TaxStreem as System Integrator and Access Point Provider on the NRS Merchant Buyer Solution. The test copies NRS\'s code lists, reads TaxStreem\'s entity record, checks the QR code keys and tries the exchange between access points (with the APP key and secret from NRS\'s APP portal, Developer section).', test: true },
  { id: 'kms', title: 'Google Cloud HSM', what: 'The hardware security module keys that hold each business\'s NRS credentials (nrs-credentials) and sign invoices (invoice-signing).', test: true,
    noKeys: 'Signs in as the Gemini service account' },
  { id: 'counta', title: 'Counta', what: 'The web address in links, the contact for push notifications, and where word of a NIN slip to review goes.' },
];

export const pct = (v: number | null | undefined, dp = 2) => (v == null ? '—' : `${(Math.round(Number(v) * 100 * 10 ** dp) / 10 ** dp).toString()}%`);
// The database's own wording for a refused value, in words an admin can act on. Anything not listed is shown as it came.
const PLAIN: [RegExp, string][] = [
  [/plans_code_check/, 'The plan code must start with a letter and use 2 to 30 lowercase letters, numbers or hyphens.'],
  [/plans_code_key/, 'Another plan already uses that code. Choose a different one.'],
  [/plans_name_check/, 'A plan name has 2 to 40 characters.'],
  [/plan_modules_key_check/, 'A module key must start with a letter and use 2 to 40 lowercase letters, numbers or underscores.'],
  [/plan_modules_name_check/, 'A module name has 2 to 60 characters.'],
  [/invalid input syntax for type (numeric|integer)/, 'One of the numbers is not written as a number. Use digits only, like 35000.'],
];
export const tidyError = (e: unknown) => {
  const m = String((e as Error)?.message || e || 'Something went wrong.');
  return PLAIN.find(([re]) => re.test(m))?.[1] ?? m;
};
