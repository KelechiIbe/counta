// Martina's instructions in two parts (martina.ts): RULES, the same for everyone and kept in Gemini's cache, and Counta's
// note about the person, which travels with their latest message.
// deno test --no-config -A martina_test.ts
import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { contextNote, type Ctx, NOTE_START, RULES, TOOLS } from './martina.ts';

const ada: Ctx = { link_id: 'l1', channel: 'whatsapp', org_id: 'o1', user_id: 'u1', first_name: 'Ada', role: 'owner', business: 'Ikeja Grocers Ltd',
  offering: 'goods', category: 'Retail', category_id: 'retail', language: 'en', sample: false, perms: { record_sales: true, keep_books: true },
  businesses: [{ id: 'o1', name: 'Ikeja Grocers Ltd' }], app_url: 'https://counta.example.test' };

Deno.test('rules_same_for_everyone: nothing about the person, the business or the day', () => {
  for (const word of ['Ada', 'Ikeja', 'owner)', 'Today is', 'action_id ']) assert(!RULES.includes(word), `RULES mentions ${word}`);
  assert(!/\$\{/.test(RULES));
  assertStringIncludes(RULES, "# Counta's note");
  assertStringIncludes(RULES, '# Where things are in Counta');
  // Both channels' manner, since the channel is only in the note.
  assertStringIncludes(RULES, 'On WhatsApp:');
  assertStringIncludes(RULES, 'On Siri');
});

Deno.test('note_says_who_and_what_waits', () => {
  const n = contextNote(ada, { read_back: 'Record a sale. Total ₦3,600.00', action_id: 'a-123' });
  assert(n.startsWith(NOTE_START) && n.endsWith(']'));
  for (const bit of ['Ada (owner) at Ikeja Grocers Ltd', 'on WhatsApp', 'Today is', 'record sales and raise invoices', 'Their role does not allow:',
    'Waiting for their yes: Record a sale. Total ₦3,600.00 (action_id a-123)']) assertStringIncludes(n, bit);
  assert(!n.includes('They are also on'), 'one business: no others listed');
  assertStringIncludes(contextNote(ada, null), 'Nothing is waiting for their yes.');
  const pin = contextNote({ ...ada, channel: 'siri', language: 'pcm', businesses: [...ada.businesses, { id: 'o2', name: 'Lekki Foods' }] },
    { read_back: 'Approve the VAT return for October 2026', action_id: 'a-9', needs_pin: true });
  for (const bit of ['by voice through Siri', 'They prefer Nigerian Pidgin.', 'They are also on: Lekki Foods.', 'Waiting for their approval PIN, typed on its own']) {
    assertStringIncludes(pin, bit);
  }
  assert(!pin.includes('a-9'), 'a PIN wait carries no action id to confirm');
});

Deno.test('tools_unchanged_by_the_split', () => {
  const names = TOOLS.map((t) => t.name);
  assertEquals(new Set(names).size, names.length);
  for (const t of ['confirm_action', 'cancel_action', 'approve_tax_return', 'books_inbox', 'switch_business', 'open_counta']) assert(names.includes(t), t);
});
