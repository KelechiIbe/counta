import { assert, assertEquals } from 'jsr:@std/assert@1';
import { PRACTICE_MAIL_KINDS, practiceMailMessages } from './practice_mail.ts';
import { emailHtml, emailText } from './wording.ts';

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
