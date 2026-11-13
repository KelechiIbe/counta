import { assert, assertEquals } from 'jsr:@std/assert@1';
import { PRACTICE_MAIL_KINDS, practiceMail, type PracticeMailDeps, practiceMailMessages } from './practice_mail.ts';
import { emailHtml, emailText, type Msg } from './wording.ts';

const ID = '33333333-3333-4333-8333-333333333333';

Deno.test('practice_mail_one_email_per_reviewer', () => {
  const reviewers = Array.from({ length: 25 }, (_, i) => `reviewer${i}@taxstreem.example.test`);
  const r = { to: [...reviewers, 'not an address', reviewers[0]], reply_to: null, from_name: 'Counta', subject: 'A director declined: Ada Foods Ltd',
    heading: 'A director declined', greet: null, lines: ['Firm: Sola & Co.', 'Business: Ada Foods Ltd.'], button: 'Open mandates',
    link: 'https://app.example.test/admin/mandates', white_label: false };
  const ms = practiceMailMessages('director_admin', ID, r, 1);
  assertEquals(ms.length, 20);
  assertEquals(ms.map((m) => m.to_address), reviewers.slice(0, 20));
  assertEquals(new Set(ms.map((m) => m.id)).size, 20);
  assert(ms.every((m) => m.template === 'practice' && m.params.reply_to === undefined && m.org.reply_to_email === undefined));
});

Deno.test('practice_mail_code_and_white_label', () => {
  const r = { to: 'ada@client.example.test', reply_to: 'sola@firm.example.test', from_name: 'Sola & Co', subject: 'Your code to sign the letter of engagement',
    heading: 'Your signing code', greet: 'Ada', lines: ['Enter this code to sign the letter of engagement from Sola & Co. It works for ten minutes.',
      'If you did not ask for a code, you can ignore this email.'], button: null, link: null, code: '042917', white_label: true };
  const [m, ...rest] = practiceMailMessages('letter_code', ID, r);
  assertEquals(rest.length, 0);
  assertEquals([m.to_address, m.params.reply_to, m.params.white_label], ['ada@client.example.test', 'sola@firm.example.test', true]);
  assert(emailText(m).includes('042917') && emailHtml(m).includes('042917'));
  assert(!emailHtml(m).includes('Counta') && !emailText(m).includes('Counta'));
  // An involved client's letter says who sent it.
  const done = practiceMailMessages('letter_done', ID, { ...r, cc: 'sola@firm.example.test', code: undefined, white_label: false })[0];
  assertEquals(done.params.cc, ['sola@firm.example.test']);
  assert(emailText(done).includes('Sent by Counta for Sola & Co'));
  assertEquals(PRACTICE_MAIL_KINDS, ['letter_sign', 'letter_code', 'letter_done', 'director_confirm', 'director_code', 'director_admin']);
});

// A stand-in for the messaging function's parts: whether email may go, the database's answer, and what was sent.
function mailDeps(answer: unknown, o: { on?: boolean; configured?: boolean; failFor?: string } = {}) {
  const asked: string[] = [], sent: { to: string; from: string; m: Msg }[] = [];
  const d: PracticeMailDeps = {
    emailOn: async () => o.on ?? true,
    configured: async () => o.configured ?? true,
    write: async (kind) => { asked.push(kind); return { data: answer, error: null }; },
    send: async (m, from) => { if (m.to_address === o.failFor) throw new Error('Resend: rejected'); sent.push({ to: m.to_address, from, m }); return 'id'; },
  };
  return { d, asked, sent };
}
const letterSign = { to: 'ada@client.example.test', reply_to: 'sola@firm.example.test', from_name: 'Sola & Co', subject: 'Letter of engagement from Sola & Co to sign',
  heading: 'Your letter of engagement', greet: 'Ada', lines: ['Sola & Co has signed its letter of engagement.'], button: 'Read and sign',
  link: 'https://app.example.test/sign/es_x', white_label: false };

Deno.test('practice_mail_mints_nothing_unless_it_can_send', async () => {
  for (const o of [{ on: false }, { configured: false }]) {
    const { d, asked, sent } = mailDeps(letterSign, o);
    const r = await practiceMail('letter_sign', ID, d);
    assertEquals([r.ok, asked.length, sent.length], [false, 0, 0], JSON.stringify(o));
  }
  const unknown = mailDeps(letterSign);
  assertEquals((await practiceMail('letter_unknown', ID, unknown.d)).ok, false);
  assertEquals(unknown.asked.length, 0);
  const one = mailDeps(letterSign);
  assertEquals(await practiceMail('letter_sign', ID, one.d), { ok: true, sent_to: 'ada@client.example.test' });
  assertEquals([one.asked, one.sent.map((s) => s.from)], [['letter_sign'], ['Sola & Co']]); // the firm's name alone, no "via Counta"
  assertEquals(await practiceMail('letter_sign', ID, mailDeps(null).d), { ok: true, skipped: true });
});

Deno.test('practice_mail_reviewers_each_and_footer', async () => {
  const admin = { to: ['r1@taxstreem.example.test', 'r2@taxstreem.example.test', 'r3@taxstreem.example.test'], reply_to: null, from_name: 'Counta',
    subject: 'A director declined: Ada Foods Ltd', heading: 'A director declined', greet: null, lines: ['Firm: Sola & Co.'], button: 'Open mandates',
    link: 'https://app.example.test/admin/mandates', white_label: false };
  const all = mailDeps(admin);
  assertEquals(await practiceMail('director_admin', ID, all.d), { ok: true, sent_to: admin.to });
  assertEquals(all.sent.map((s) => [s.to, s.from]), admin.to.map((t) => [t, 'Counta']));
  const text = emailText(all.sent[0].m);
  assert(text.includes('Sent by Counta. If you were not expecting this') && !text.includes('for Counta'));
  const some = mailDeps(admin, { failFor: 'r2@taxstreem.example.test' });
  assertEquals(await practiceMail('director_admin', ID, some.d), { ok: false, error: 'Resend: rejected', sent_to: [admin.to[0], admin.to[2]] });
});
