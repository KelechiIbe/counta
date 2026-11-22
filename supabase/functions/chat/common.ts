// What Martina's tools share on WhatsApp and Siri: who she is talking with, how each step reaches the database (as the
// person, through svc_chat_rpc), and holding an action until the person says yes.
import { naira } from './words.ts';

export type Ctx = { link_id: string; channel: 'whatsapp' | 'siri'; org_id: string; user_id: string; first_name: string; role: string; business: string;
  offering: string | null; category: string | null; category_id: string | null; language: string; sample: boolean; perms: Record<string, boolean>;
  businesses: { id: string; name: string }[]; app_url: string };
export type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<any>;
// call: another of Counta's functions, with the hook secret (the messaging function for a report, tax-files for Flux).
export type Env = { ctx: Ctx; rpc: Rpc; svc: Rpc; said: string; switched?: (c: Ctx) => void; call?: (fn: string, body: Record<string, unknown>) => Promise<any> };

export async function findCustomer(e: Env, name: string) {
  const r = await e.rpc('get_customers');
  const all: any[] = (r?.customers || []).filter((c: any) => !c.archived && !c.is_walk_in);
  const n = name.trim().toLowerCase();
  if (!n) return { none: true } as const;
  const exact = all.filter((c) => c.name.toLowerCase() === n);
  if (exact.length === 1) return { customer: exact[0] };
  const part = all.filter((c) => c.name.toLowerCase().includes(n) || n.includes(c.name.toLowerCase()));
  if (part.length === 1) return { customer: part[0] };
  if (part.length > 1) return { choose: part.slice(0, 6).map((c) => c.name) };
  return { none: true } as const;
}

// One of a list by name: exact first, then the only one containing the words. { choose } when several fit.
export function pickByName<T extends { name: string }>(list: T[], name: string): { one?: T; choose?: string[] } {
  const n = String(name || '').trim().toLowerCase();
  if (!n) return {};
  const exact = list.filter((x) => x.name.toLowerCase() === n);
  if (exact.length === 1) return { one: exact[0] };
  const part = list.filter((x) => x.name.toLowerCase().includes(n) || n.includes(x.name.toLowerCase()));
  if (part.length === 1) return { one: part[0] };
  if (part.length > 1) return { choose: part.slice(0, 6).map((x) => x.name) };
  return {};
}

// Holds an action until the person says yes (or, with needsPin, types their approval PIN).
export async function hold(e: Env, kind: string, title: string, lines: string[], total: number | null, note: string, payload: unknown, needsPin = false) {
  const read_back = [title, ...lines, total != null ? `Total ${naira(total)}` : '', note].filter(Boolean).join('. ');
  const action_id = await e.svc('svc_chat_pending_set', { p_link: e.ctx.link_id, p: { kind, title, read_back, payload, needs_pin: needsPin } });
  return needsPin
    ? { waiting_for_pin: true, action_id, read_back,
      next: 'Send this read-back, then ask them to type their six-digit Counta approval PIN as a message on its own to approve it, or to say no. Never ask for the PIN in a voice note, and never repeat a PIN back. Counta checks the PIN itself.' }
    : { waiting_for_approval: true, action_id, read_back,
      next: 'Send this read-back and ask whether to go ahead. Call confirm_action only after their next message is a yes; call cancel_action if they say no.' };
}

export const url = (e: Env, path: string) => `${e.ctx.app_url.replace(/\/$/, '')}${path}`;
export const can = (e: Env, k: string) => Boolean(e.ctx.perms?.[k]);
export const roundN = (n: unknown) => (n == null || !Number.isFinite(Number(n)) ? null : Math.round(Number(n) * 100) / 100);
