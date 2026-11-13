// Identity messages, asked for by the database (private.identity_mail -> messaging hook {action: 'identity_mail', kind,
// id}): what svc_identity_mail answers, sent by email (Resend) and, for a code, by SMS (Termii).
//
//   identity_code      a director's or a recovering director's code: email to their CAC address and SMS to the NIN's phone
//                      (or the CAC phone), as the database chose. A director's code goes in the firm's name only.
//   recovery_owner     the holder of a business told a director proved who they are (30 minutes to answer)
//   recovery_handover  the director's link to take the business
//   recovery_done      the previous owner told the business has a new owner
//   recovery_admin     TaxStreem's reviewers asked to check a recovery
//   support_case       a support request, to the support address (replies go to the person)
//   approval_link      the director of a full-mandate client told what the firm asks them to approve, with the link to
//                      /approve (by email; an SMS says where the link is, or carries it when there is no email)
//   approval_code      the code that opens that page, by email and SMS
//
// The code is minted by svc_identity_mail as the message goes, so nothing usable is ever queued: everything that would
// stop a send is checked before the database is asked. Where the code goes is wiped by the database once it is right, or
// within the hour.
import { displayName, type Msg } from './wording.ts';
import { practiceMailMessages } from './practice_mail.ts';

export const IDENTITY_MAIL_KINDS = ['identity_code', 'recovery_owner', 'recovery_handover', 'recovery_done', 'recovery_admin', 'support_case',
  'approval_link', 'approval_code'];
// The kinds that also go by SMS.
const SMS_KINDS = ['identity_code', 'approval_link', 'approval_code'];

export type IdentityMailDeps = {
  emailOn: () => Promise<boolean>; // not paused by TaxStreem
  configured: () => Promise<boolean>; // the Resend key and sending address are set
  smsConfigured: () => Promise<boolean>; // the Termii key and sender ID are set
  write: (kind: string, id: string) => Promise<{ data: any; error: { message: string } | null }>; // svc_identity_mail
  send: (m: Msg, fromName: string) => Promise<unknown>;
  sendSms: (to: string, text: string) => Promise<string>;
  meter?: (orgId: string | null, item: string) => void; // an SMS sent, for TaxStreem's costs (never waits, never fails)
};

const SMS_TO = /^234[789][01]\d{8}$/;

// {ok, sent_to, sms_to} (masked nowhere: the hook's answer stays in the logs of TaxStreem's own function), or {ok: false,
// error} with whatever did go recorded. {ok: true, skipped: true} when there is nothing to send.
export async function identityMail(kind: string, id: string, d: IdentityMailDeps): Promise<Record<string, unknown>> {
  if (!IDENTITY_MAIL_KINDS.includes(kind) || !/^[0-9a-f-]{36}$/i.test(id)) return { ok: false, error: 'Unknown identity message.' };
  const emailOk = (await d.emailOn()) && (await d.configured());
  const smsOk = SMS_KINDS.includes(kind) && (await d.smsConfigured());
  if (!emailOk && !smsOk) return { ok: false, reason: 'not_configured', error: 'Neither email nor SMS can go just now.' };
  const { data: r, error } = await d.write(kind, id);
  if (error) return { ok: false, error: error.message };
  if (!r) return { ok: true, skipped: true };
  const msgs = r.to ? practiceMailMessages(kind, id, r) : [];
  const sms = r.sms && typeof r.sms === 'object' && typeof r.sms.to === 'string' && SMS_TO.test(r.sms.to) && typeof r.sms.text === 'string' ? r.sms : null;
  if (!msgs.length && !sms) return { ok: false, error: 'The message has no address to go to.' };
  const sent: string[] = [], errors: string[] = [];
  let smsTo: string | null = null;
  if (msgs.length && !emailOk) errors.push('Email is not switched on just now.');
  if (emailOk) {
    for (const m of msgs) {
      try {
        await d.send(m, displayName(String(r.from_name || 'Counta'), true));
        sent.push(m.to_address);
      } catch (e) {
        errors.push((e as Error).message);
      }
    }
  }
  if (sms && !smsOk) errors.push('SMS is not switched on yet.');
  if (sms && smsOk) {
    try {
      await d.sendSms(sms.to, String(sms.text).slice(0, 300));
      smsTo = sms.to;
      d.meter?.(typeof r.org_id === 'string' ? r.org_id : null, String(r.purpose || kind).slice(0, 40));
    } catch (e) {
      errors.push((e as Error).message);
    }
  }
  const sentTo = Array.isArray(r.to) ? sent : sent[0] ?? null;
  return errors.length ? { ok: false, error: errors[0], sent_to: sentTo, sms_to: smsTo } : { ok: true, sent_to: sentTo, sms_to: smsTo };
}

export type TermiiConfig = { key: string; sender: string; base?: string; channel?: string };

// One SMS through Termii (POST {base}/api/sms/send). The route is dnd unless TERMII_CHANNEL says generic: dnd reaches
// numbers on the do-not-disturb list, which a code must. Termii's message id, or an error naming what Termii said.
export async function termiiSend(cfg: TermiiConfig, to: string, text: string, call: typeof fetch = fetch): Promise<string> {
  const base = (cfg.base || 'https://api.ng.termii.com').replace(/\/$/, '');
  const channel = /^(dnd|generic|whatsapp)$/i.test(cfg.channel || '') ? cfg.channel!.toLowerCase() : 'dnd';
  const res = await call(`${base}/api/sms/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ api_key: cfg.key, to, from: cfg.sender, sms: text, type: 'plain', channel }),
    signal: AbortSignal.timeout(20_000),
  });
  const raw = await res.text();
  let body: any = null;
  try { body = JSON.parse(raw); } catch { /* not json */ }
  if (!res.ok || !body || (body.code && String(body.code).toLowerCase() !== 'ok')) {
    const msg = String(body?.message || body?.error || raw || res.status).replace(/\s+/g, ' ').slice(0, 200);
    throw new Error(`Termii: ${msg}`);
  }
  return String(body.message_id || body.messageId || '');
}

// The Termii balance (GET {base}/api/get-balance), for the admin portal's test: {balance, currency}.
export async function termiiBalance(cfg: TermiiConfig, call: typeof fetch = fetch): Promise<{ balance: number | null; currency: string | null }> {
  const base = (cfg.base || 'https://api.ng.termii.com').replace(/\/$/, '');
  const res = await call(`${base}/api/get-balance?${new URLSearchParams({ api_key: cfg.key })}`, { headers: { accept: 'application/json' },
    signal: AbortSignal.timeout(15_000) });
  const raw = await res.text();
  let body: any = null;
  try { body = JSON.parse(raw); } catch { /* not json */ }
  if (!res.ok || !body) throw new Error(`Termii: ${String(body?.message || raw || res.status).slice(0, 200)}`);
  const n = Number(body.balance);
  return { balance: Number.isFinite(n) ? n : null, currency: typeof body.currency === 'string' ? body.currency : null };
}
