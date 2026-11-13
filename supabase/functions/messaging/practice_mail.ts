// The practice's own emails, asked for by the database (private.practice_mail -> messaging hook {action: 'practice_mail',
// kind, id}): what svc_practice_mail answers, made into the emails to send. The words, the link and the code are the
// database's, minted as the email goes, so neither is ever queued in the clear. Letters and director requests go in the
// firm's name only; TaxStreem's reviewers (director_admin, `to` a list) each get their own email, at most 20, and may
// have no address to reply to.
import { type Msg, senderAddress } from './wording.ts';

export const PRACTICE_MAIL_KINDS = ['letter_sign', 'letter_code', 'letter_done', 'director_confirm', 'director_code', 'director_admin'];

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
