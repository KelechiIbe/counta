// The practice's own emails, asked for by the database (private.practice_mail -> messaging hook {action: 'practice_mail',
// kind, id}): what svc_practice_mail answers, made into the emails to send. The words, the link and the code are the
// database's, minted as the email goes, so neither is ever queued in the clear. Letters and director requests go in the
// firm's name only; TaxStreem's reviewers (director_admin, `to` a list) each get their own email, at most 20, and may
// have no address to reply to.
import { displayName, type Msg, senderAddress } from './wording.ts';

export const PRACTICE_MAIL_KINDS = ['letter_sign', 'letter_code', 'letter_done', 'director_confirm', 'director_code', 'director_admin'];

export type PracticeMailDeps = {
  emailOn: () => Promise<boolean>; // not paused by TaxStreem
  configured: () => Promise<boolean>; // the Resend key and sending address are set
  write: (kind: string, id: string) => Promise<{ data: any; error: { message: string } | null }>; // svc_practice_mail
  send: (m: Msg, fromName: string) => Promise<unknown>;
};

// Sends a practice email. Everything that would stop it is checked before svc_practice_mail is asked, since asking mints
// a fresh link or code (replacing the last): nothing is minted that cannot be sent. Sent from the firm's name alone.
// {ok, sent_to} (a list when the database gave a list), {ok: true, skipped: true} when there is nothing to send.
export async function practiceMail(kind: string, id: string, d: PracticeMailDeps): Promise<Record<string, unknown>> {
  if (!PRACTICE_MAIL_KINDS.includes(kind) || !/^[0-9a-f-]{36}$/i.test(id)) return { ok: false, error: 'Unknown practice email.' };
  if (!(await d.emailOn())) return { ok: false, error: 'Email is paused by TaxStreem for now.' };
  if (!(await d.configured())) return { ok: false, reason: 'not_configured', error: 'Email is not switched on yet. TaxStreem is setting it up.' };
  const { data: r, error } = await d.write(kind, id);
  if (error) return { ok: false, error: error.message };
  if (!r) return { ok: true, skipped: true };
  const msgs = practiceMailMessages(kind, id, r);
  if (!msgs.length) return { ok: false, error: 'The email has no address to go to.' };
  const sent: string[] = [], failed: string[] = [];
  for (const m of msgs) {
    try {
      await d.send(m, displayName(String(r.from_name || 'Counta'), true));
      sent.push(m.to_address);
    } catch (e) {
      failed.push((e as Error).message);
    }
  }
  const sentTo = Array.isArray(r.to) ? sent : sent[0] ?? null;
  return failed.length ? { ok: false, error: failed[0], sent_to: sentTo } : { ok: true, sent_to: sentTo };
}

export function practiceMailMessages(kind: string, id: string, r: Record<string, any>, stamp: number = Date.now()): Msg[] {
  const to = [...new Set((Array.isArray(r.to) ? r.to : [r.to])
    .map((x: unknown) => (typeof x === 'string' ? senderAddress(x) : ''))
    .filter(Boolean))].slice(0, 20) as string[];
  const lines = (Array.isArray(r.lines) ? r.lines : []).map((l: unknown) => String(l ?? '').trim()).filter(Boolean);
  // A one-time code goes on its own line, under the first.
  if (typeof r.code === 'string' && /^\d{4,10}$/.test(r.code)) lines.splice(1, 0, `Your code: ${r.code}`);
  const replyTo = typeof r.reply_to === 'string' && senderAddress(r.reply_to) ? r.reply_to.trim() : undefined;
  const cc = typeof r.cc === 'string' && senderAddress(r.cc) ? [r.cc.trim()] : [];
  const from = String(r.from_name || 'Counta');
  return to.map((addr, i): Msg => ({
    id: `practice-${kind}-${id}-${stamp}-${i}`, channel: 'email', to_address: addr, template: 'practice', subject: String(r.subject || ''),
    params: { heading: r.heading, greet: r.greet, lines, button: r.button, link: r.link, from_name: from, business: from, white_label: r.white_label === true,
      reply_to: replyTo, cc },
    org: { name: from, reply_to_email: replyTo },
  }));
}
