import { assert, assertEquals } from 'jsr:@std/assert@1';
import { displayName, emailHtml, emailText, mandateBlocked, type Msg, waText, wording } from './wording.ts';

const m = { id: '1', channel: 'email', to_address: 'c@example.test', template: 'document', params: { doc_label: 'Invoice', number: 'INV-1', total: 100 }, org: { name: 'Ada Foods Ltd', white_label: true } } as Msg;

Deno.test('display_name_white_label', () => {
  assertEquals(displayName('Ada Foods Ltd', true), 'Ada Foods Ltd');
  assertEquals(displayName('Ada Foods Ltd', false), 'Ada Foods Ltd via Counta');
});
Deno.test('email_white_label_has_no_counta', () => {
  assert(!emailHtml(m).includes('Counta') && !emailText(m).includes('Counta') && !waText(m).includes('Counta'));
});
Deno.test('email_branded_by_default', () => { assert(emailHtml({ ...m, org: { name: 'Ada Foods Ltd' } }).includes('Sent for Ada Foods Ltd by Counta')); });
Deno.test('wa_text_branded_by_default', () => {
  const t = waText({ ...m, org: { name: 'Ada Foods Ltd' } });
  assert(t.includes('Sent for Ada Foods Ltd by Counta'));
  assert(!waText(m).includes('Sent for'));
});
Deno.test('deliver_fail_closed_predicate', () => {
  assertEquals(mandateBlocked({ managed: true, alert_to_allowed: false }), true);
  assertEquals(mandateBlocked({ managed: true }), true);
  assertEquals(mandateBlocked({ managed: true, alert_to_allowed: true }), false);
  assertEquals(mandateBlocked({ managed: false }), false);
  assertEquals(mandateBlocked({}), false);
});
Deno.test('alert_practice_footers_white_label', () => {
  const alert = { ...m, template: 'alert', params: { heading: 'Return due', lines: ['VAT is due'] } } as Msg;
  assertEquals((wording(alert) as { footer?: string }).footer, 'Sent for Ada Foods Ltd. Choose which alerts you get in Settings, Alerts.');
  assertEquals((wording({ ...alert, org: { name: 'Ada Foods Ltd' } }) as { footer?: string }).footer, 'Counta sends these for Ada Foods Ltd. Choose which you get in Settings, Alerts.');
  const prac = { ...m, template: 'practice', params: { heading: 'Hi', lines: ['x'], from_name: 'Firm LLP' }, org: { name: 'Firm LLP' } } as Msg;
  const exp = 'If you were not expecting this, you can ignore the email.';
  assertEquals((wording({ ...prac, org: { name: 'Firm LLP', white_label: true } }) as { footer?: string }).footer, exp);
  assertEquals((wording({ ...prac, params: { ...prac.params, white_label: true } }) as { footer?: string }).footer, exp);
  assertEquals((wording(prac) as { footer?: string }).footer, `Sent by Counta for Firm LLP. ${exp}`);
  assert(!emailHtml(alert).includes('Counta sends these'));
});
Deno.test('invoice_issues_neutral_when_white_label', () => {
  const inv = { ...m, template: 'invoice_issues', params: { number: 'S-1', issues: ['Tax ID missing'] } } as Msg;
  assert(!emailHtml(inv).includes('Counta') && emailHtml({ ...inv, org: { name: 'Ada Foods Ltd' } }).includes('Counta checked it'));
});
