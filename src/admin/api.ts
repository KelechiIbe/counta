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
    mono: { url: string }; whatsapp: { url: string; last: string | null }; flux: { url: string } };
};
export const useKeys = () => useQuery({ queryKey: ['admin-keys'], queryFn: () => edge<KeysStatus>('admin', { action: 'status' }) });

export type Settings = {
  martina: { tone: 'calm' | 'warm' | 'lively'; default_voice_id: string | null };
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
];
export const featureLabel = (id: string) => FEATURES.find((f) => f.id === id)?.label || id;

export const GROUPS: { id: string; title: string; what: string; test?: boolean }[] = [
  { id: 'gemini', title: 'Google Gemini', what: 'Reads invoices, statements, product photos, CAC documents and NIN slips; the bookkeeper and Martina\'s typed answers.', test: true },
  { id: 'elevenlabs', title: 'ElevenLabs', what: 'The Nigerian voices, Martina by voice, and phone calls through the connected Twilio number.', test: true },
  { id: 'flutterwave', title: 'Flutterwave', what: 'Business account numbers, payment links, QR codes and payouts.', test: true },
  { id: 'mono', title: 'Mono', what: 'Bank feeds, and the CAC, Tax ID and NIN lookups in onboarding.', test: true },
  { id: 'email', title: 'Email (Resend)', what: 'Invoices, receipts, reminders, invitations and these admin alerts.', test: true },
  { id: 'whatsapp', title: 'WhatsApp Business', what: 'Invoices, receipts and reminders by WhatsApp.', test: true },
  { id: 'numens', title: 'Numens', what: 'TaxStreem\'s tax model for the VAT treatment of items. Gemini stands in without it.', test: true },
  { id: 'taxstreem', title: 'TaxStreem', what: 'Single sign-on from TaxStreem, and Flux, which files returns on Rev360.', test: true },
  { id: 'counta', title: 'Counta', what: 'The web address in links, the contact for push notifications, and where word of a NIN slip to review goes.' },
];

export const pct = (v: number | null | undefined, dp = 2) => (v == null ? '—' : `${(Math.round(Number(v) * 100 * 10 ** dp) / 10 ** dp).toString()}%`);
export const tidyError = (e: unknown) => String((e as Error)?.message || e || 'Something went wrong.');
