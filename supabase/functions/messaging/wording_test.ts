import { assert, assertEquals } from 'jsr:@std/assert@1';
import { displayName, emailHtml, emailText, type Msg, waText } from './wording.ts';

const m = { id: '1', channel: 'email', to_address: 'c@example.test', template: 'document', params: { doc_label: 'Invoice', number: 'INV-1', total: 100 }, org: { name: 'Ada Foods Ltd', white_label: true } } as Msg;

Deno.test('display_name_white_label', () => {
  assertEquals(displayName('Ada Foods Ltd', true), 'Ada Foods Ltd');
  assertEquals(displayName('Ada Foods Ltd', false), 'Ada Foods Ltd via Counta');
});
Deno.test('email_white_label_has_no_counta', () => {
  assert(!emailHtml(m).includes('Counta') && !emailText(m).includes('Counta') && !waText(m).includes('Counta'));
});
Deno.test('email_branded_by_default', () => { assert(emailHtml({ ...m, org: { name: 'Ada Foods Ltd' } }).includes('Sent for Ada Foods Ltd by Counta')); });
