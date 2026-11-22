-- Counta on WhatsApp (20261210000100_whatsapp_everywhere.sql): books inbox alerts (a push as questions land, one email and one
-- WhatsApp each morning to everyone who keeps the books); the approval PIN for tax returns; what Martina may call as a person;
-- the daily report (who gets it, what each role sees, the hourly queue); customers talking to Martina for a business (found
-- by the number the business wrote to, their own records only, a word that they paid, a hand-off to the team, the team's
-- reply). Only fake people (example.test addresses, 0803 000 numbers).
begin;

-- Fixture: Ada owns Ikeja Grocers Ltd and keeps its books; Bisi is a cashier who records sales; Tunde keeps the books.
-- Ada and Tunde linked WhatsApp to Martina. Two customers. TaxStreem's number is connected. Kola owns another business.
do $$
declare o uuid; o2 uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@ikeja.example.test', 'Ada Owner'));
  perform tests.remember('bisi', tests.user('bisi.cashier@ikeja.example.test', 'Bisi Cashier'));
  perform tests.remember('tunde', tests.user('tunde.books@ikeja.example.test', 'Tunde Books'));
  perform tests.remember('kola', tests.user('kola.owner@other.example.test', 'Kola Owner'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Ikeja Grocers Ltd'));
  o2 := tests.remember('o2', tests.org(tests.id('kola'), 'Other Shop Ltd'));
  perform tests.remember('bisi_m', tests.member(o, tests.id('bisi'), 'cashier'));
  perform tests.remember('tunde_m', tests.member(o, tests.id('tunde'), 'accountant'));
  update members set email = 'ada.owner@ikeja.example.test' where org_id = o and user_id = tests.id('ada');
  insert into whatsapp_sessions (id, kind, status, phone, name) values ('counta', 'counta', 'ready', '2349000000001', 'counta')
  on conflict (id) do update set status = 'ready', phone = excluded.phone;
  insert into chat_links (user_id, org_id, channel, phone, status, linked_at) values (tests.id('ada'), o, 'whatsapp', '2348030000001', 'active', now());
  perform tests.remember('ada_link', (select id from chat_links where phone = '2348030000001' and status = 'active'));
  insert into chat_links (user_id, org_id, channel, phone, status, linked_at) values (tests.id('tunde'), o, 'whatsapp', '2348030000002', 'active', now());
  perform tests.as_user(tests.id('ada'));
  perform tests.remember('chidi', public.save_customer(o, '{"name": "Chidi Stores", "phone": "0803 000 1111", "email": "chidi@example.test"}'));
  perform tests.remember('ngozi', public.save_customer(o, '{"name": "Ngozi Foods", "phone": "0803 000 2222"}'));
  perform tests.as_user(tests.id('kola'));
  perform tests.remember('kola_cu', public.save_customer(o2, '{"name": "Chidi at Other", "phone": "0803 000 1111"}'));
  perform tests.as_postgres();
end $$;

create function pg_temp.invoice(p_org uuid, p_customer uuid, p_amount numeric default 50000) returns jsonb language sql as $f$
  select public.save_sale_doc(p_org, jsonb_build_object('customer_id', p_customer, 'status', 'issue',
    'lines', jsonb_build_array(jsonb_build_object('description', 'Rice bags', 'qty', 1, 'unit_price', p_amount, 'vat_treatment', 'standard'))))
$f$;
create function pg_temp.question(p_org uuid, p_title text, p_kind text default 'bank_line_account') returns uuid language sql as $f$
  insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount)
  values (p_org, 'bookkeeper', p_kind, 'test', gen_random_uuid(), p_title, p_title, '{}'::jsonb, 0.5, 'test', 'test', 'pending', 12000)
  returning id
$f$;

-- test: wa_worthy_changes
-- A payment to match waits for the morning message; a customer waiting for a person goes to WhatsApp at once.
do $$
begin
  assert not private.wa_worthy('bank', 'Which invoice does ₦5,000.00 pay?'), 'wa_worthy_changes: matches wait for the morning';
  assert not private.wa_worthy('books_inbox', 'A question in the books inbox'), 'wa_worthy_changes: inbox pushes stay off WhatsApp';
  assert private.wa_worthy('customer_chat', 'Chidi on WhatsApp needs a reply'), 'wa_worthy_changes: customer chats go at once';
  assert private.wa_worthy('bill', 'A supplier invoice to review') and private.wa_worthy('banking', 'Sign in again'), 'wa_worthy_changes: the rest as before';
end $$;

-- test: inbox_push_on_arrival
-- A new question pushes to everyone who keeps the books (not the cashier); a burst makes one push each; a customer's
-- word that they paid, and a payment to match, push on their own already.
do $$
declare o uuid := tests.id('o'); n0 int;
begin
  n0 := (select count(*) from notifications where org_id = o and kind = 'books_inbox');
  perform pg_temp.question(o, 'Which account is ₦12,000 out to Ikeja Electric?');
  perform pg_temp.question(o, 'Which account is ₦3,000 out to MTN?');
  assert (select count(*) from notifications where org_id = o and kind = 'books_inbox') - n0 = 2,
    format('inbox_push_on_arrival: one push each for Ada and Tunde, got %s', (select count(*) from notifications where org_id = o and kind = 'books_inbox') - n0);
  assert not exists (select 1 from notifications where org_id = o and kind = 'books_inbox' and user_id = tests.id('bisi')), 'inbox_push_on_arrival: not the cashier';
  assert (select title from notifications where org_id = o and kind = 'books_inbox' and user_id = tests.id('ada') order by created_at desc limit 1) like '%question%',
    'inbox_push_on_arrival: the title counts the questions';
  n0 := (select count(*) from notifications where org_id = o and kind = 'books_inbox');
  perform pg_temp.question(o, 'Customer says they paid', 'payment_claim');
  assert (select count(*) from notifications where org_id = o and kind = 'books_inbox') = n0, 'inbox_push_on_arrival: claims push on their own';
end $$;

-- test: inbox_digest_morning
-- Each person who keeps the books gets one email (if they have an address) and one WhatsApp (if linked), once a day; the
-- WhatsApp says a reply of "inbox" goes through them with Martina; the cashier gets nothing.
do $$
declare o uuid := tests.id('o'); v int; m public.messages;
begin
  v := private.inbox_digest(o);
  assert v = 2, format('inbox_digest_morning: Ada and Tunde, got %s', v);
  assert exists (select 1 from messages where org_id = o and channel = 'email' and template = 'alert' and to_address = 'ada.owner@ikeja.example.test'
                 and params->>'kind' = 'books_inbox'), 'inbox_digest_morning: Ada''s email';
  select * into m from messages where org_id = o and channel = 'whatsapp' and template = 'alert' and to_address = '+2348030000001' and params->>'kind' = 'books_inbox';
  assert m.id is not null and m.params->>'reply_line' like '%inbox%' and (m.params->>'reply_hint')::boolean, 'inbox_digest_morning: Ada''s WhatsApp with the reply line';
  assert jsonb_array_length(m.params->'lines') >= 2 and m.params->>'heading' like '%questions wait in the books inbox', 'inbox_digest_morning: what waits';
  assert exists (select 1 from messages where org_id = o and channel = 'whatsapp' and to_address = '+2348030000002' and params->>'kind' = 'books_inbox'),
    'inbox_digest_morning: Tunde''s WhatsApp';
  assert not exists (select 1 from messages where org_id = o and params->>'kind' = 'books_inbox' and to_address like '%bisi%'), 'inbox_digest_morning: not Bisi';
  assert private.inbox_digest(o) = 0, 'inbox_digest_morning: once a day';
  update ai_proposals set status = 'approved' where org_id = o and status = 'pending';
  assert private.inbox_digest(o) = 0, 'inbox_digest_morning: nothing waiting, nothing sent';
  assert (private.inbox_digest_tick()->>'people')::int >= 0, 'inbox_digest_morning: the tick runs';
end $$;

-- test: approval_pin
-- Six digits, not a run or one digit repeated; only a hash is kept; a wrong PIN counts down, the fifth locks it for an
-- hour and tells the person; setting it again unlocks it.
do $$
declare l uuid := tests.id('ada_link'); r jsonb; i int;
begin
  perform tests.as_user(tests.id('ada'));
  assert not (public.approval_pin_status()->>'set')::boolean, 'approval_pin: none yet';
  perform tests.throws($q$select public.set_approval_pin('123456')$q$, '%harder to guess%');
  perform tests.throws($q$select public.set_approval_pin('777777')$q$, '%harder to guess%');
  perform tests.throws($q$select public.set_approval_pin('98765')$q$, '%six digits%');
  r := public.set_approval_pin('284619');
  assert (r->>'set')::boolean, 'approval_pin: set';
  perform tests.as_postgres();
  assert (select pin_hash from approval_pins where user_id = tests.id('ada')) not like '%284619%', 'approval_pin: hashed';
  r := public.svc_check_pin(l, '284619');
  assert (r->>'ok')::boolean, 'approval_pin: right';
  r := public.svc_check_pin(l, '111111');
  assert r->>'reason' = 'wrong' and (r->>'left')::int = 4, format('approval_pin: four left, got %s', r);
  for i in 1..4 loop r := public.svc_check_pin(l, '000000'); end loop;
  assert r->>'reason' = 'locked', format('approval_pin: locked on the fifth, got %s', r);
  assert (public.svc_check_pin(l, '284619')->>'reason') = 'locked', 'approval_pin: the right PIN waits too';
  assert exists (select 1 from notifications where user_id = tests.id('ada') and tag = 'pin-locked'), 'approval_pin: told';
  perform tests.as_user(tests.id('ada'));
  perform public.set_approval_pin('530172');
  perform tests.as_postgres();
  assert (public.svc_check_pin(l, '530172')->>'ok')::boolean, 'approval_pin: a new PIN unlocks';
  assert (public.svc_check_pin(tests.id('o'), '530172')->>'reason') = 'no_link', 'approval_pin: only through a link';
end $$;

-- test: pending_needs_pin
do $$
declare l uuid := tests.id('ada_link'); a uuid; p jsonb;
begin
  a := public.svc_chat_pending_set(l, '{"kind": "tax_return", "title": "Approve VAT", "read_back": "Approve the VAT return", "payload": {"tax": "vat"}, "needs_pin": true}');
  p := public.svc_chat_pending(l);
  assert (p->>'needs_pin')::boolean and (p->>'action_id')::uuid = a, 'pending_needs_pin: kept';
  a := public.svc_chat_pending_set(l, '{"kind": "order_confirm", "title": "Confirm", "read_back": "Confirm SO-1", "payload": {}}');
  assert not (public.svc_chat_pending(l)->>'needs_pin')::boolean, 'pending_needs_pin: a yes is enough for the rest';
  perform tests.throws(format('select public.svc_chat_pending_set(%L, %L)', l, '{"kind": "pay_out", "title": "x", "read_back": "x", "payload": {}}'), '%chat_pending_kind_check%');
  perform public.svc_chat_pending_take(l, null);
end $$;

-- test: chat_rpc_scope
-- Martina's calls run as the person, in the link's business only: a record from another business is refused before its
-- function runs; existing records are not changed from the chat; the new calls answer.
do $$
declare l uuid := tests.id('ada_link'); o2 uuid := tests.id('o2'); s jsonb; r jsonb; other uuid;
begin
  perform tests.as_user(tests.id('kola'));
  other := (pg_temp.invoice(o2, tests.id('kola_cu'))->>'id')::uuid;
  perform tests.as_postgres();
  perform tests.throws(format('select public.svc_chat_rpc(%L, %L, %L)', l, 'get_sale', jsonb_build_object('sale_id', other)), '%not in this business%');
  perform tests.throws(format('select public.svc_chat_rpc(%L, %L, %L)', l, 'confirm_order', jsonb_build_object('sale_id', other)), '%not in this business%');
  perform tests.throws(format('select public.svc_chat_rpc(%L, %L, %L)', l, 'save_customer', jsonb_build_object('customer', jsonb_build_object('id', tests.id('kola_cu'), 'name', 'X'))),
    '%change existing ones in Counta%');
  perform tests.throws(format('select public.svc_chat_rpc(%L, %L, %L)', l, 'create_payment_request', '{}'), '%cannot do that here%');
  r := public.svc_chat_rpc(l, 'stock_waiting', '{}');
  assert r ? 'transfers' and r ? 'counts', 'chat_rpc_scope: stock waiting';
  r := public.svc_chat_rpc(l, 'approvals_list', '{}');
  assert r ? 'items', 'chat_rpc_scope: approvals';
  s := public.svc_chat_rpc(l, 'save_sale_doc', jsonb_build_object('doc', jsonb_build_object('customer_id', tests.id('chidi'), 'status', 'issue',
    'lines', jsonb_build_array(jsonb_build_object('description', 'Beans', 'qty', 2, 'unit_price', 10000, 'vat_treatment', 'standard')))));
  r := public.svc_chat_rpc(l, 'get_sale', jsonb_build_object('sale_id', s->>'id'));
  assert r->>'number' = s->>'number', 'chat_rpc_scope: own sale';
  r := public.svc_chat_rpc(l, 'sale_creditable', jsonb_build_object('sale_id', s->>'id'));
  assert jsonb_array_length(r->'lines') >= 1, 'chat_rpc_scope: what can be credited';
end $$;

-- test: daily_report_prefs
-- By default the owner and whoever keeps the books get it at 19:00; a cashier does not until they turn it on; anyone may
-- choose for themselves, between 6:00 and 22:00.
do $$
declare o uuid := tests.id('o'); r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  r := public.get_daily_report_prefs(o);
  assert (r->>'enabled')::boolean and (r->>'hour')::int = 19 and not (r->>'explicit')::boolean and (r->>'whatsapp_linked')::boolean, format('daily_report_prefs: owner on, got %s', r);
  assert r->'parts' ? 'money' and r->'parts' ? 'books' and not (r->'parts' ? 'people'), format('daily_report_prefs: the owner sees everything but who did what (no activity log here), got %s', r);
  perform tests.as_user(tests.id('bisi'));
  r := public.get_daily_report_prefs(o);
  assert not (r->>'enabled')::boolean and r->'parts' ? 'sales' and not (r->'parts' ? 'money') and not (r->'parts' ? 'people'), format('daily_report_prefs: cashier off, sales only, got %s', r);
  perform tests.throws(format('select public.save_daily_report_prefs(%L, %L)', o, '{"enabled": true, "hour": 23}'), '%between 6:00 and 22:00%');
  r := public.save_daily_report_prefs(o, '{"enabled": true, "hour": 18, "email": false}');
  assert (r->>'enabled')::boolean and (r->>'hour')::int = 18 and not (r->>'email')::boolean and (r->>'explicit')::boolean, 'daily_report_prefs: Bisi turned it on';
  perform tests.as_postgres();
end $$;

-- test: daily_report_data
-- The day's figures, each part as the role sees it; a day with nothing is empty.
do $$
declare o uuid := tests.id('o'); ada public.members; bisi public.members; d jsonb; v_day date;
begin
  perform tests.as_user(tests.id('ada'));
  perform pg_temp.invoice(o, tests.id('chidi'), 40000);
  perform tests.as_postgres();
  v_day := private.local_day(o, now());
  select * into ada from members where org_id = o and user_id = tests.id('ada');
  select * into bisi from members where org_id = o and user_id = tests.id('bisi');
  d := private.daily_report_data(o, ada, v_day);
  assert not (d->>'empty')::boolean and (d->'sales'->>'count')::int >= 1 and d ? 'money' and d ? 'books' and d ? 'tax', format('daily_report_data: the owner''s day, got %s', d);
  assert (d->'sales'->>'invoiced')::numeric >= 40000, 'daily_report_data: invoiced';
  -- Who did what only where Counta keeps the activity log (a business a practice runs, or one gone read-only).
  assert not (d ? 'people'), 'daily_report_data: no activity log, no who did what';
  update orgs set read_only_at = now() where id = o;
  d := private.daily_report_data(o, ada, v_day);
  update orgs set read_only_at = null where id = o;
  assert d ? 'people', format('daily_report_data: who did what from the activity log, got %s', d);
  d := private.daily_report_data(o, bisi, v_day);
  assert d ? 'sales' and d ? 'orders' and not (d ? 'money') and not (d ? 'books') and not (d ? 'people'), format('daily_report_data: the cashier''s day, got %s', d);
  d := private.daily_report_data(o, ada, v_day - 400);
  assert (d->>'empty')::boolean, 'daily_report_data: an empty day';
end $$;

-- test: daily_report_queue
-- The hourly tick queues each report due now once and asks the messaging function for it; Martina may ask for one; the
-- messaging function gets what to make and records how it went.
do $$
declare o uuid := tests.id('o'); v_hour int; id1 uuid; r jsonb; n int;
begin
  v_hour := extract(hour from now() at time zone 'Africa/Lagos')::int;
  update orgs set timezone = 'Africa/Lagos' where id = o;
  insert into daily_report_prefs (org_id, user_id, enabled, hour) values (o, tests.id('ada'), true, greatest(6, least(22, v_hour)))
  on conflict (org_id, user_id) do update set enabled = true, hour = excluded.hour;
  delete from daily_report_prefs where org_id = o and user_id = tests.id('bisi');
  if v_hour between 6 and 22 then
    perform private.daily_report_tick();
    select id into id1 from daily_reports where org_id = o and user_id = tests.id('ada') and kind = 'scheduled';
    assert id1 is not null and exists (select 1 from net._requests where url like '%/messaging' and body->>'action' = 'daily_report' and body->>'id' = id1::text),
      'daily_report_queue: queued and asked for';
    perform private.daily_report_tick();
    assert (select count(*) from daily_reports where org_id = o and user_id = tests.id('ada') and kind = 'scheduled') = 1, 'daily_report_queue: once a day';
    assert not exists (select 1 from daily_reports where org_id = o and user_id = tests.id('bisi')), 'daily_report_queue: not the cashier';
    r := public.svc_daily_report(id1);
    assert r->>'kind' = 'scheduled' and r->'person'->>'email' = 'ada.owner@ikeja.example.test' and r->'person'->>'whatsapp' = '2348030000001'
       and r->'data' ? 'sales', format('daily_report_queue: what to make, got %s', r - 'data');
    perform public.svc_daily_report_done(id1, '{"status": "sent", "channels": ["whatsapp", "email"], "path": "x/reports/daily/a.pdf"}');
    assert (select status = 'sent' and channels = array['whatsapp', 'email'] from daily_reports where id = id1), 'daily_report_queue: recorded';
    assert public.svc_daily_report(id1) is null, 'daily_report_queue: not made twice';
  end if;
  id1 := public.svc_daily_report_ask(tests.id('ada_link'), null);
  r := public.svc_daily_report(id1);
  assert r->>'kind' = 'asked' and r->'person'->>'email' is null and r->'person'->>'whatsapp' = '2348030000001', 'daily_report_queue: asked on WhatsApp goes to WhatsApp';
  for n in 1..9 loop perform public.svc_daily_report_ask(tests.id('ada_link'), null); end loop;
  perform tests.throws(format('select public.svc_daily_report_ask(%L, null)', tests.id('ada_link')), '%ten reports today%');
end $$;

-- test: customer_chat_found
-- A customer writing back to TaxStreem's number reaches the business that last sent them a document there; a number no
-- business wrote to is nobody's; the business's own number answers only when it turned that on.
do $$
declare o uuid := tests.id('o'); s jsonb; c jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  s := pg_temp.invoice(o, tests.id('chidi'), 50000);
  perform tests.as_postgres();
  perform tests.remember('chidi_inv', (s->>'id')::uuid);
  insert into messages (org_id, channel, to_address, template, params, sale_id, customer_id, status, created_at)
  values (o, 'whatsapp', '+2348030001111', 'document', '{}', (s->>'id')::uuid, tests.id('chidi'), 'sent', now() - interval '1 hour');
  c := public.svc_customer_chat_find('2348030001111', 'counta', 'Chidi');
  assert c->>'org_id' = o::text and c->>'customer_id' = tests.id('chidi')::text and c->>'business' = 'Ikeja Grocers Ltd' and not (c->>'paused')::boolean,
    format('customer_chat_found: Chidi at Ikeja Grocers, got %s', c);
  perform tests.remember('chat', (c->>'chat_id')::uuid);
  assert public.svc_customer_chat_find('2348039999999', 'counta', null) is null, 'customer_chat_found: a stranger';
  insert into whatsapp_sessions (id, kind, org_id, status, phone, name) values ('org-ikeja', 'business', o, 'ready', '2349000000002', 'org-ikeja');
  assert public.svc_customer_chat_find('2348030002222', 'org-ikeja', null) is null, 'customer_chat_found: own number off by default';
  perform tests.as_user(tests.id('ada'));
  perform public.save_customer_chat_settings(o, '{"own_number": true}');
  perform tests.as_postgres();
  c := public.svc_customer_chat_find('2348030002222', 'org-ikeja', 'Ngozi');
  assert c->>'via' = 'own' and c->>'customer_id' = tests.id('ngozi')::text, 'customer_chat_found: on the own number once allowed';
  perform tests.as_user(tests.id('ada'));
  perform public.save_customer_chat_settings(o, '{"on": false}');
  perform tests.as_postgres();
  assert public.svc_customer_chat_find('2348030001111', 'counta', null) is null, 'customer_chat_found: switched off';
  perform tests.as_user(tests.id('ada'));
  perform public.save_customer_chat_settings(o, '{"on": true, "own_number": false}');
  perform tests.as_postgres();
end $$;

-- test: customer_chat_own_records
-- The customer sees their own documents with links and nothing of anyone else's; the business's contact details; no shop.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('chat'); v jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  perform pg_temp.invoice(o, tests.id('ngozi'), 77000);
  perform tests.as_postgres();
  v := public.svc_customer_view(c, 'documents', '{}');
  assert (v->>'customer_known')::boolean and jsonb_array_length(v->'documents') >= 1, 'customer_chat_own_records: theirs';
  assert not exists (select 1 from jsonb_array_elements(v->'documents') x where (x->>'total')::numeric = 77000 + 77000 * 0.075), 'customer_chat_own_records: not Ngozi''s';
  assert (select bool_and(x->>'link' like '%/p/%') from jsonb_array_elements(v->'documents') x), 'customer_chat_own_records: links';
  assert (v->>'owed')::numeric > 0, 'customer_chat_own_records: what they owe';
  v := public.svc_customer_view(c, 'documents', '{"unpaid": true}');
  assert (select bool_and((x->>'owed')::numeric > 0) from jsonb_array_elements(v->'documents') x), 'customer_chat_own_records: unpaid only';
  assert not (public.svc_customer_view(c, 'products', '{}')->>'shop')::boolean, 'customer_chat_own_records: no shop';
  assert public.svc_customer_view(c, 'business', '{}')->>'name' = 'Ikeja Grocers Ltd', 'customer_chat_own_records: the business';
  perform tests.throws(format('select public.svc_customer_view(%L, %L, %L)', c, 'everything', '{}'), '%Unknown view%');
end $$;

-- test: customer_chat_claim
-- "I have paid": which invoice and how much are asked when unclear; without a payment request the people who keep the books
-- are asked to check the bank, once; the question closes itself when the invoice is paid.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('chat'); r jsonb; inv public.sales; p public.ai_proposals;
begin
  select * into inv from sales where id = tests.id('chidi_inv');
  r := public.svc_customer_claim(c, jsonb_build_object('number', inv.number));
  assert r->>'reason' = 'amount', format('customer_chat_claim: how much, got %s', r);
  r := public.svc_customer_claim(c, jsonb_build_object('number', 'INV-NOPE', 'amount', 100));
  assert r->>'reason' = 'which' and jsonb_array_length(r->'numbers') >= 1, 'customer_chat_claim: which one';
  r := public.svc_customer_claim(c, jsonb_build_object('number', inv.number, 'amount', 53750, 'name', 'CHIDI OKAFOR', 'proof_path', o || '/chats/x/slip.jpg'));
  assert (r->>'ok')::boolean and r->>'mode' = 'asked', format('customer_chat_claim: asked, got %s', r);
  select * into p from ai_proposals where org_id = o and kind = 'payment_claim' and source_type = 'customer_chat' and source_id = inv.id;
  assert p.status = 'pending' and p.proposal->>'proof_path' like '%slip.jpg' and (p.proposal->>'chat_id')::uuid = c, 'customer_chat_claim: in the books inbox';
  assert exists (select 1 from notifications where org_id = o and kind = 'payment' and tag = 'cclaim-' || inv.id and user_id = tests.id('tunde')), 'customer_chat_claim: told';
  r := public.svc_customer_claim(c, jsonb_build_object('number', inv.number, 'amount', 53750));
  assert (select count(*) from ai_proposals where org_id = o and kind = 'payment_claim' and source_id = inv.id) = 1, 'customer_chat_claim: once';
  update sales set status = 'paid' where id = inv.id;
  assert (select status from ai_proposals where id = p.id) = 'superseded', 'customer_chat_claim: closes when paid';
  update sales set status = 'open' where id = inv.id;
end $$;

-- test: customer_chat_team
-- A hand-off waits for the team and tells everyone who records sales (WhatsApp included); the team sees the chat and
-- answers on WhatsApp from the number the customer wrote to; Martina stays quiet in that chat for twelve hours; people who
-- do not record sales, and other businesses, cannot read it; the menu counts chats waiting.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('chat'); r jsonb; m public.messages;
begin
  perform public.svc_customer_chat_log(c, 'customer', 'Can I return two bags?', null, '{}');
  perform public.svc_customer_handoff(c, 'Wants to return two bags of rice');
  assert (select status from customer_chats where id = c) = 'needs_reply', 'customer_chat_team: waits';
  assert exists (select 1 from notifications where org_id = o and kind = 'customer_chat' and user_id = tests.id('bisi')), 'customer_chat_team: the cashier hears';
  assert exists (select 1 from messages where org_id = o and template = 'alert' and channel = 'whatsapp' and params->>'kind' = 'customer_chat' and to_address = '+2348030000001'),
    'customer_chat_team: on Ada''s WhatsApp';
  perform tests.as_user(tests.id('ada'));
  assert (public.get_attention(o)->>'customer_chats')::int = 1, 'customer_chat_team: counted beside the menu';
  r := public.get_customer_chats(o, '{}');
  assert jsonb_array_length(r->'chats') >= 1 and (r->'chats'->0->>'status') = 'needs_reply' and (r->>'can_change')::boolean, 'customer_chat_team: listed';
  r := public.get_customer_chat(c);
  assert jsonb_array_length(r->'turns') >= 1, 'customer_chat_team: the conversation';
  r := public.customer_chat_reply(c, 'Yes, bring them on Monday.');
  perform tests.as_postgres();
  assert (select unread from customer_chats where id = c) = 0, 'customer_chat_team: read';
  select * into m from messages where id = (r->>'message_id')::uuid;
  assert m.template = 'chat' and m.channel = 'whatsapp' and m.to_address = '+2348030001111' and m.params->>'via' = 'counta' and m.params->>'text' = 'Yes, bring them on Monday.',
    format('customer_chat_team: the reply, got %s', to_jsonb(m) - 'org_id');
  assert (select status = 'open' and martina_paused_until > now() + interval '11 hours' from customer_chats where id = c), 'customer_chat_team: Martina waits';
  assert (public.svc_customer_chat_find('2348030001111', 'counta', null)->>'paused')::boolean, 'customer_chat_team: the chat knows';
  perform tests.as_user(tests.id('tunde'));
  perform tests.throws(format('select public.get_customer_chat(%L)', c), '%record sales%');
  perform tests.as_user(tests.id('kola'));
  perform tests.throws(format('select public.get_customer_chat(%L)', c), '%not a member%');
  perform tests.as_user(tests.id('ada'));
  r := public.customer_chat_set(c, '{"martina": "resume", "status": "closed"}');
  assert r->'chat'->>'status' = 'closed' and r->'chat'->>'paused_until' is null, 'customer_chat_team: handed back and closed';
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.save_customer_chat_settings(%L, %L)', o, '{"on": false}'), '%Only the owner%');
  perform tests.as_postgres();
  perform public.svc_customer_chat_log(c, 'customer', 'Thank you', null, '{}');
  assert (select status from customer_chats where id = c) = 'open', 'customer_chat_team: a new message reopens it';
end $$;

-- test: customer_chat_order
-- With the online shop on, Martina places an order for the customer from it; without a shop she cannot.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('chat'); it uuid; loc uuid; r jsonb; v jsonb;
begin
  perform tests.throws(format('select public.svc_customer_order(%L, %L)', c, '{}'), '%does not take orders here%');
  perform tests.as_user(tests.id('ada'));
  perform public.import_inventory(o, '[{"name": "Golden Penny Semovita 1kg", "price": 1800, "cost": 1400, "vat_treatment": "zero"}]'::jsonb, '{}'::jsonb);
  perform tests.as_postgres();
  it := (select id from items where org_id = o and name = 'Golden Penny Semovita 1kg');
  loc := (select id from locations where org_id = o order by is_main desc limit 1);
  insert into stock_levels (item_id, location_id, org_id, qty) values (it, loc, o, 40) on conflict (item_id, location_id) do update set qty = 40;
  update orgs set shop_enabled = true, shop_slug = 'ikeja-grocers-test', shop_pickup = true, shop_delivery = false where id = o;
  v := public.svc_customer_view(c, 'products', '{"q": "semo"}');
  assert (v->>'shop')::boolean and (v->'products'->0->>'in_stock')::boolean, 'customer_chat_order: the shop''s products';
  r := public.svc_customer_order(c, jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', it, 'qty', 3)), 'delivery_method', 'pickup', 'payment', 'now',
    'client_uuid', gen_random_uuid()));
  assert r->>'number' is not null and r->>'link' like '%/p/%', format('customer_chat_order: placed, got %s', r);
  assert exists (select 1 from sales where org_id = o and doc_type = 'order' and number = r->>'number' and customer_phone = '+2348030001111' and notes like '%WhatsApp with Martina%'),
    'customer_chat_order: an order from this number';
end $$;

-- test: whatsapp_everywhere_grants
do $$
begin
  assert not has_function_privilege('anon', 'public.svc_customer_view(uuid, text, jsonb)', 'execute')
     and not has_function_privilege('authenticated', 'public.svc_customer_view(uuid, text, jsonb)', 'execute')
     and has_function_privilege('service_role', 'public.svc_customer_view(uuid, text, jsonb)', 'execute'), 'whatsapp_everywhere_grants: customer views are the server''s';
  assert not has_function_privilege('authenticated', 'public.svc_check_pin(uuid, text)', 'execute'), 'whatsapp_everywhere_grants: the PIN check';
  assert not has_function_privilege('authenticated', 'public.svc_chat_rpc(uuid, text, jsonb)', 'execute'), 'whatsapp_everywhere_grants: Martina''s calls';
  assert not has_function_privilege('anon', 'public.get_customer_chats(uuid, jsonb)', 'execute')
     and has_function_privilege('authenticated', 'public.get_customer_chats(uuid, jsonb)', 'execute'), 'whatsapp_everywhere_grants: the team''s chats';
  assert not has_function_privilege('authenticated', 'private.daily_report_data(uuid, public.members, date)', 'execute'), 'whatsapp_everywhere_grants: report data';
  assert not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
    and table_name in ('customer_chats', 'customer_chat_turns', 'approval_pins', 'daily_reports', 'daily_report_prefs') and grantee in ('anon', 'authenticated')),
    'whatsapp_everywhere_grants: tables closed';
end $$;

rollback;
