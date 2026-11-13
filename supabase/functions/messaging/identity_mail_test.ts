import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { IDENTITY_MAIL_KINDS, identityMail, type IdentityMailDeps, termiiBalance, termiiSend } from './identity_mail.ts';
import { emailText, type Msg } from './wording.ts';

const ID = '33333333-3333-4333-8333-333333333333', ORG = '44444444-4444-4444-8444-444444444444';
const CODE = { to: 'ada.cac@director.example.test', reply_to: null, from_name: 'Counta', org_id: ORG, purpose: 'recovery', subject: 'Your Counta code to recover Kano Steel Ltd',
  heading: 'Your recovery code', greet: 'Ada', lines: ['Enter this code in Counta to prove you are a director of Kano Steel Ltd and recover it. It works for ten minutes.'],
  button: null, link: null, code: '042917', white_label: false,
  sms: { to: '2348031234567', text: '042917 is your Counta code to recover Kano Steel Ltd. It expires in 10 minutes. Do not share it.' } };

function idDeps(answer: unknown, o: { email?: boolean; sms?: boolean; smsFails?: boolean } = {}) {
  const asked: string[] = [], mails: { m: Msg; from: string }[] = [], texts: { to: string; text: string }[] = [], metered: [string | null, string][] = [];
  const d: IdentityMailDeps = {
    emailOn: async () => o.email ?? true, configured: async () => true, smsConfigured: async () => o.sms ?? true,
    write: async (kind) => { asked.push(kind); return { data: answer, error: null }; },
    send: async (m, from) => { mails.push({ m, from }); return 'id'; },
    sendSms: async (to, text) => { if (o.smsFails) throw new Error('Termii: Insufficient balance'); texts.push({ to, text }); return 'mid'; },
    meter: (org, item) => { metered.push([org, item]); },
  };
  return { d, asked, mails, texts, metered };
}

Deno.test('identity_mail_code_by_email_and_sms', async () => {
  const x = idDeps(CODE);
  const r = await identityMail('identity_code', ID, x.d);
  assertEquals(r, { ok: true, sent_to: 'ada.cac@director.example.test', sms_to: '2348031234567' });
  assertEquals(x.texts, [{ to: '2348031234567', text: CODE.sms.text }]);
  assertEquals(x.metered, [[ORG, 'recovery']]);
  assertEquals(x.mails[0].from, 'Counta');
  assert(emailText(x.mails[0].m).includes('042917'));
});

Deno.test('identity_mail_mints_nothing_when_nothing_can_go', async () => {
  const x = idDeps(CODE, { email: false, sms: false });
  assertEquals((await identityMail('identity_code', ID, x.d)).reason, 'not_configured');
  assertEquals(x.asked, []);
  // An email-only message with email paused: the database is not asked either.
  const y = idDeps({ to: ['a@b.example.test'] }, { email: false });
  assertEquals((await identityMail('recovery_owner', ID, y.d)).reason, 'not_configured');
  assertEquals(y.asked, []);
  assertEquals((await identityMail('director_confirm', ID, y.d)).ok, false);
  assertEquals((await identityMail('identity_code', 'nope', y.d)).ok, false);
});

Deno.test('identity_mail_sms_failure_is_reported_and_email_still_goes', async () => {
  const x = idDeps(CODE, { smsFails: true });
  const r = await identityMail('identity_code', ID, x.d);
  assertEquals([r.ok, r.error, r.sent_to, r.sms_to], [false, 'Termii: Insufficient balance', 'ada.cac@director.example.test', null]);
  assertEquals(x.metered, []);
  // A code for SMS only (no CAC email): no email at all.
  const y = idDeps({ ...CODE, to: null });
  assertEquals(await identityMail('identity_code', ID, y.d), { ok: true, sent_to: null, sms_to: '2348031234567' });
  assertEquals(y.mails.length, 0);
  // A malformed SMS number from anywhere is not sent.
  const z = idDeps({ ...CODE, to: null, sms: { to: '+1 555 0100', text: 'x' } });
  assertEquals((await identityMail('identity_code', ID, z.d)).ok, false);
  assertEquals(z.texts, []);
});

Deno.test('identity_mail_lists_and_nothing_to_send', async () => {
  const x = idDeps({ to: ['bisi@firm.example.test', 'office@firm.example.test'], from_name: 'Counta', subject: 'A director asked to take over Lokoja Foods Ltd on Counta',
    heading: 'A director asked for the business', lines: ['…'], button: 'Open Counta', link: 'https://app.example.test/practice/clients', white_label: false });
  assertEquals(await identityMail('recovery_owner', ID, x.d), { ok: true, sent_to: ['bisi@firm.example.test', 'office@firm.example.test'], sms_to: null });
  assertEquals((await identityMail('recovery_done', ID, idDeps(null).d)), { ok: true, skipped: true });
  assertEquals(IDENTITY_MAIL_KINDS.length, 8);
});

Deno.test('termii_send_and_balance', async () => {
  const seen: { url: string; body: any }[] = [];
  const ok = (async (url: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(url), body: init?.body ? JSON.parse(String(init.body)) : null });
    return new Response(String(url).includes('get-balance') ? JSON.stringify({ user: 'TaxStreem', balance: 1520.5, currency: 'NGN' })
      : JSON.stringify({ code: 'ok', message_id: '9122821270554876574', message: 'Successfully Sent', balance: 9, user: 'TaxStreem' }), { status: 200 });
  }) as typeof fetch;
  assertEquals(await termiiSend({ key: 'k', sender: 'TaxStreem' }, '2348031234567', 'hi', ok), '9122821270554876574');
  assertEquals(seen[0], { url: 'https://api.ng.termii.com/api/sms/send',
    body: { api_key: 'k', to: '2348031234567', from: 'TaxStreem', sms: 'hi', type: 'plain', channel: 'dnd' } });
  await termiiSend({ key: 'k', sender: 'S', base: 'https://v3.api.termii.com/', channel: 'Generic' }, '2348031234567', 'hi', ok);
  assertEquals([seen[1].url, seen[1].body.channel], ['https://v3.api.termii.com/api/sms/send', 'generic']);
  assertEquals(await termiiBalance({ key: 'k', sender: 'S' }, ok), { balance: 1520.5, currency: 'NGN' });
  const bad = (async () => new Response(JSON.stringify({ message: 'Invalid sender id' }), { status: 400 })) as typeof fetch;
  const e = await assertRejects(() => termiiSend({ key: 'k', sender: 'S' }, '2348031234567', 'hi', bad));
  assertEquals((e as Error).message, 'Termii: Invalid sender id');
});

Deno.test('identity_mail_approval_link_and_code_go_by_sms_too', async () => {
  const link = { to: 'dayo@director.example.test', reply_to: 'partner@firm.example.test', from_name: 'Fifteen Partners', org_id: ORG, purpose: 'approval',
    subject: 'Fifteen Partners asks you to approve one item for Managed Foods Ltd', heading: 'Waiting for your approval', greet: 'Dayo',
    lines: ['Fifteen Partners keeps the books of Managed Foods Ltd under your full mandate, and asks you to approve: Invoice INV-0001 to Chika Foods.'],
    button: 'Review and approve', link: 'https://counta.example.test/approve/ap_' + 'ab'.repeat(24), code: null, white_label: true,
    sms: { to: '2348031110000', text: 'Fifteen Partners asks you to approve one item for Managed Foods Ltd on Counta. The link is in your email d***@d***.test.' } };
  const x = idDeps(link);
  assertEquals(await identityMail('approval_link', ID, x.d), { ok: true, sent_to: 'dayo@director.example.test', sms_to: '2348031110000' });
  assertEquals(x.asked, ['approval_link']);
  assertEquals([x.mails[0].from, x.mails[0].m.subject], ['Fifteen Partners', link.subject]);
  assert(emailText(x.mails[0].m).includes('/approve/ap_'));
  assertEquals(x.metered, [[ORG, 'approval']]);
  const y = idDeps({ ...CODE, purpose: 'approval', sms: { to: '2348031110000', text: '042917 is your code to approve for Managed Foods Ltd on Counta.' } });
  assertEquals((await identityMail('approval_code', ID, y.d)).sms_to, '2348031110000');
  assert(IDENTITY_MAIL_KINDS.includes('approval_link') && IDENTITY_MAIL_KINDS.includes('approval_code'));
  // Email-only kinds never text, whatever the database answers.
  const z = idDeps({ to: 'support@example.test', sms: { to: '2348031110000', text: 'x' } });
  assertEquals((await identityMail('support_case', ID, z.d)).sms_to, null);
  assertEquals(z.texts, []);
});
