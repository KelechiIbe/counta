-- Payments to the business wallet that a customer cut short (20261205000100_wallet_matching.sql): a waiting pay request is
-- settled by what is owed less WHT, the NCD levy or VAT withheld, with or without the reference; the customer's word that
-- they paid helps match it and, unanswered, reaches the business once; the books inbox answer "a customer paying what they
-- owe" settles that customer's invoices; a named customer's transfer that fits one open invoice is settled; requests close
-- whenever their invoice is settled. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Clinic Ltd (VAT-registered, with a Tax ID, paid through its own Flutterwave wallet). Customers:
-- Bola Stores Ltd, Chika Ventures Ltd and Femi Okafor (all businesses buying services).
do $$
declare o uuid; w uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@clinic.example.test', 'Ada Owner'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Clinic Ltd'));
  update orgs set vat_registered = true, payment_rail = 'flutterwave', payment_methods = '{account,link,qr}', identity_status = 'verified', tin = '12345678-0001'
  where id = o;
  perform tests.as_user(tests.id('ada'));
  perform tests.remember('bola', public.save_customer(o, '{"name": "Bola Stores Ltd", "email": "bola@example.test", "kind": "business"}'));
  perform tests.remember('chika', public.save_customer(o, '{"name": "Chika Ventures Ltd", "email": "chika@example.test", "kind": "business"}'));
  perform tests.remember('femi', public.save_customer(o, '{"name": "Femi Okafor Enterprises", "email": "femi@example.test", "kind": "business"}'));
  perform tests.remember('dayo', public.save_customer(o, '{"name": "Dayo Farms Ltd", "email": "dayo@example.test", "kind": "business"}'));
  perform tests.as_postgres();
  insert into wallets (org_id, rail) values (o, 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, '{"account_ref": "ACC-ADA", "account_number": "9911223344", "bank_name": "Test Bank", "account_name": "Ada Clinic Ltd"}');
  perform tests.remember('w', w);
  perform tests.remember('wbank', (select bank_account_id from wallets where id = w));
end $$;

-- An issued invoice for one line of p_amt (VAT at 7.5% unless exempt).
create function pg_temp.inv(p_customer uuid, p_amt numeric, p_vat text default 'standard') returns uuid language plpgsql as $f$
declare s jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  s := public.save_sale_doc(tests.id('o'), jsonb_build_object('customer_id', p_customer, 'status', 'draft', 'prices_include_vat', false, 'doc_type', 'invoice',
    'lines', jsonb_build_array(jsonb_build_object('description', 'Consulting', 'qty', 1, 'unit_price', p_amt, 'vat_treatment', p_vat))));
  perform public.issue_invoice((s->>'id')::uuid, null);
  perform tests.as_postgres();
  return (s->>'id')::uuid;
end $f$;
-- The customer's page asks to pay by transfer: a request on the business's own number, for all or part of what is owed.
create function pg_temp.req(p_sale uuid, p_amount numeric default null) returns public.payment_requests language sql as $f$
  select private.open_request(tests.id('o'), p_sale, null, 'account', p_amount,
    (select mm from members mm where mm.org_id = tests.id('o') and mm.user_id = tests.id('ada')), true, null)
$f$;
-- Money reaching the wallet as the statement shows it.
create function pg_temp.land(p_amt numeric, p_ref text, p_narration text default 'NIP TRANSFER', p_sender text default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_service();
  r := public.svc_wallet_inflow('flutterwave', 'ACC-ADA', jsonb_build_object('amount', p_amt, 'reference', p_ref, 'narration', p_narration,
    'sender', case when p_sender is null then '{}'::jsonb else jsonb_build_object('name', p_sender) end));
  perform tests.as_postgres();
  return r;
end $f$;
create function pg_temp.sale(p_sale uuid) returns public.sales language sql as $f$ select * from sales where id = p_sale $f$;
create function pg_temp.request(p_id uuid) returns public.payment_requests language sql as $f$ select * from payment_requests where id = p_id $f$;
-- What the customer kept back on a sale, by method (wht_credit, ncd_levy, wvat_credit).
create function pg_temp.kept(p_sale uuid, p_method text) returns numeric language sql as $f$
  select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id
  where a.sale_id = p_sale and c.method = p_method and c.status = 'confirmed'
$f$;
-- The customer's receivables in the ledger, and what their open invoices say they owe: the two must agree.
create function pg_temp.ledger_owed(p_customer uuid) returns numeric language sql as $f$
  select coalesce(sum(debit - credit), 0) from journal_lines where org_id = tests.id('o') and account_code ~ '^110[12]' and party_id = p_customer
$f$;
create function pg_temp.invoices_owed(p_customer uuid) returns numeric language sql as $f$
  select coalesce(sum(total - amount_paid - credited), 0) from sales where org_id = tests.id('o') and customer_id = p_customer and status in ('open', 'partially_paid')
    and journal_id is not null
$f$;
create function pg_temp.notified(p_title text) returns int language sql as $f$
  select count(*)::int from notifications where org_id = tests.id('o') and title like p_title
$f$;
-- A bank line Atlas could not explain, waiting in the books inbox as a question (money held in suspense).
create function pg_temp.question(p_line uuid) returns uuid language plpgsql as $f$
begin
  perform tests.as_service();
  perform public.svc_classify_line(p_line, '{"title": "Money from an unknown sender", "confidence": 0.3, "question": "Who sent this?"}');
  perform tests.as_postgres();
  return (select id from ai_proposals where source_id = p_line and status = 'pending');
end $f$;
create function pg_temp.answer(p_proposal uuid, p jsonb) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_user(tests.id('ada'), 'aal2');
  r := public.resolve_proposal(p_proposal, p);
  perform tests.as_postgres();
  return r;
end $f$;

-- test: wallet_short_by_wht
-- ₦107,500 owed (₦100,000 and VAT), ₦102,500 lands with no reference: 5% WHT on the value before VAT. The request is paid,
-- the invoice is paid with ₦5,000 as a WHT credit, the line is matched to the request and the customer's page shows paid.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), 100000); r public.payment_requests := pg_temp.req(v); res jsonb; bl public.bank_lines;
begin
  assert r.direct and r.amount = 107500 and r.pay_ref = (pg_temp.sale(v)).number, format('wallet_short_by_wht: request, got %s', to_jsonb(r));
  res := pg_temp.land(102500, 'FLW-A1');
  assert res->>'matched' = 'true', format('wallet_short_by_wht: matched, got %s', res);
  assert (pg_temp.request(r.id)).status = 'paid' and (pg_temp.request(r.id)).paid_amount = 102500, 'wallet_short_by_wht: request paid';
  assert (pg_temp.sale(v)).status = 'paid' and (pg_temp.sale(v)).amount_paid = 107500, format('wallet_short_by_wht: invoice paid, got %s', to_jsonb(pg_temp.sale(v)));
  assert pg_temp.kept(v, 'wht_credit') = 5000, 'wallet_short_by_wht: 5,000 WHT credit';
  assert (select wht_rate from collections c join collection_allocations a on a.collection_id = c.id where a.sale_id = v and c.method = 'wht_credit') = 0.05,
    'wallet_short_by_wht: at 5%';
  select * into bl from bank_lines where id = (res->>'bank_line')::uuid;
  assert bl.status = 'matched' and bl.stage = 'wallet_request' and bl.confidence = 1 and bl.journal_id is not null, format('wallet_short_by_wht: line, got %s', to_jsonb(bl));
  assert public.public_payment_status((pg_temp.sale(v)).public_token)->>'status' = 'paid', 'wallet_short_by_wht: the customer''s page shows paid';
  assert pg_temp.notified((pg_temp.sale(v)).number || ' settled in full') = 1, 'wallet_short_by_wht: the business is told what was kept back';
  assert pg_temp.ledger_owed(tests.id('bola')) = pg_temp.invoices_owed(tests.id('bola')), 'wallet_short_by_wht: ledger and invoices agree';
end $$;

-- test: wallet_short_by_wht_and_ncd
-- ₦215,000 owed (₦200,000 and VAT), ₦209,000 lands: 2% WHT and the 1% NCD levy on the value before VAT. Both are booked
-- and the customer is marked as one who deducts the levy.
do $$
declare v uuid := pg_temp.inv(tests.id('chika'), 200000); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(209000, 'FLW-B1', 'TRF FRM CHIKA');
  assert (pg_temp.request(r.id)).status = 'paid' and (pg_temp.sale(v)).status = 'paid', format('wallet_short_by_wht_and_ncd: paid, got %s', res);
  assert pg_temp.kept(v, 'wht_credit') = 4000 and pg_temp.kept(v, 'ncd_levy') = 2000, 'wallet_short_by_wht_and_ncd: 4,000 WHT and 2,000 levy';
  assert (select ncd_levy from customers where id = tests.id('chika')), 'wallet_short_by_wht_and_ncd: the customer now deducts the levy';
end $$;

-- test: wallet_wht_on_total
-- 5% worked out on the total with VAT (₦5,375 of ₦107,500): accepted, booked as WHT, and the business is told the credit
-- note should show that amount.
do $$
declare v uuid := pg_temp.inv(tests.id('femi'), 100000); r public.payment_requests := pg_temp.req(v); res jsonb; n text;
begin
  assert private.customer_short_split(v, 107500, 102125)->>'wht_base' = 'total', 'wallet_wht_on_total: the split says the base';
  assert private.customer_short_split(v, 107500, 102500)->>'wht_base' = 'net', 'wallet_wht_on_total: the usual base still comes first';
  res := pg_temp.land(102125, 'FLW-C1');
  assert (pg_temp.request(r.id)).status = 'paid' and (pg_temp.sale(v)).status = 'paid', format('wallet_wht_on_total: paid, got %s', res);
  assert pg_temp.kept(v, 'wht_credit') = 5375, 'wallet_wht_on_total: 5,375 WHT credit';
  assert (select c.note from collections c join collection_allocations a on a.collection_id = c.id where a.sale_id = v and c.method = 'wht_credit')
    like 'Worked out on the total with VAT%', 'wallet_wht_on_total: the credit says so';
  select body into n from notifications where org_id = tests.id('o') and title = (pg_temp.sale(v)).number || ' settled in full';
  assert n like '%5% of the total with VAT%' and n like '%a WHT credit note for ₦5,375.00%', format('wallet_wht_on_total: notice, got %s', n);
end $$;

-- test: split_bases
-- Without VAT there is no second base; a walk-in customer keeps nothing back; a discount makes the lines a base too.
do $$
declare v uuid := pg_temp.inv(tests.id('femi'), 100000, 'exempt');
begin
  assert private.customer_short_split(v, 100000, 95000)->>'wht_base' = 'net', 'split_bases: exempt, 5%';
  assert private.customer_short_split(v, 100000, 94625) is null, 'split_bases: no total base without VAT';
  assert private.customer_short_split(v, 100000, 100000) is null, 'split_bases: nothing kept back';
end $$;

-- test: wallet_exact_before_split
-- Two requests wait: one for exactly ₦102,500 (an exempt invoice) and one for ₦107,500. ₦102,500 lands: the exact one is paid,
-- the other still waits.
do $$
declare a uuid := pg_temp.inv(tests.id('dayo'), 102500, 'exempt'); b uuid := pg_temp.inv(tests.id('dayo'), 100000);
  ra public.payment_requests := pg_temp.req(a); rb public.payment_requests := pg_temp.req(b); res jsonb;
begin
  res := pg_temp.land(102500, 'FLW-D1');
  assert (pg_temp.request(ra.id)).status = 'paid' and (pg_temp.sale(a)).status = 'paid', format('wallet_exact_before_split: exact paid, got %s', res);
  assert (pg_temp.request(rb.id)).status = 'pending' and (pg_temp.sale(b)).status = 'open', 'wallet_exact_before_split: the other waits';
  -- Now ₦102,500 again: the ₦107,500 request less WHT.
  res := pg_temp.land(102500, 'FLW-D2');
  assert (pg_temp.request(rb.id)).status = 'paid' and (pg_temp.sale(b)).status = 'paid', format('wallet_exact_before_split: then the split, got %s', res);
end $$;

-- test: wallet_named_first
-- Two of Bola's invoices of the same amount wait. The narration names the newer one: it is paid, the older waits, and no
-- one is asked to check.
do $$
declare a uuid := pg_temp.inv(tests.id('bola'), 300000); b uuid := pg_temp.inv(tests.id('bola'), 300000);
  ra public.payment_requests := pg_temp.req(a); rb public.payment_requests := pg_temp.req(b); res jsonb;
begin
  res := pg_temp.land(316500, 'FLW-E1', 'PAYMENT FOR ' || (pg_temp.sale(b)).number);
  assert (pg_temp.request(rb.id)).status = 'paid' and (pg_temp.request(ra.id)).status = 'pending', format('wallet_named_first: the named one, got %s', res);
  assert (select confidence from bank_lines where id = (res->>'bank_line')::uuid) = 1, 'wallet_named_first: sure';
  assert not exists (select 1 from ai_proposals where kind = 'wallet_payment_check' and source_id = (res->>'bank_line')::uuid), 'wallet_named_first: no check';
  perform tests.remember('e_older', a);
end $$;

-- test: wallet_two_fit_oldest_checked
-- Two of Chika's invoices of the same amount wait and the narration names neither: the oldest is paid and someone checks.
do $$
declare a uuid := pg_temp.inv(tests.id('chika'), 400000); b uuid := pg_temp.inv(tests.id('chika'), 400000);
  ra public.payment_requests := pg_temp.req(a); rb public.payment_requests := pg_temp.req(b); res jsonb; p public.ai_proposals;
begin
  update payment_requests set created_at = created_at - interval '1 hour' where id = ra.id;
  -- 2% WHT and the levy Chika now deducts: 430,000 less 8,000 and 4,000.
  res := pg_temp.land(418000, 'FLW-F1');
  assert (pg_temp.request(ra.id)).status = 'paid' and (pg_temp.request(rb.id)).status = 'pending', format('wallet_two_fit_oldest_checked: oldest, got %s', res);
  select * into p from ai_proposals where kind = 'wallet_payment_check' and source_id = (res->>'bank_line')::uuid;
  assert p.status = 'info' and p.question like '2 payments waiting could take this ₦418,000.00 once what the customer kept back is allowed for%',
    format('wallet_two_fit_oldest_checked: check, got %s', to_jsonb(p));
  assert (select confidence from bank_lines where id = (res->>'bank_line')::uuid) = 0.8, 'wallet_two_fit_oldest_checked: less sure';
end $$;

-- test: wallet_part_request
-- A request for part of what is owed (a deposit): money short of it is not taken as WHT on it.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 500000); r public.payment_requests := pg_temp.req(v, 100000); res jsonb;
begin
  assert private.request_split(r.id, 95000) is null, 'wallet_part_request: no split on a part';
  res := pg_temp.land(95000, 'FLW-G1');
  assert (pg_temp.request(r.id)).status = 'pending' and (pg_temp.sale(v)).status = 'open', format('wallet_part_request: request waits, got %s', res);
  assert (select stage is distinct from 'wallet_request' from bank_lines where id = (res->>'bank_line')::uuid), 'wallet_part_request: not the request';
end $$;

-- test: wallet_nothing_fits
-- An amount that fits no request and no invoice is left to the matcher and Atlas, as before.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 600000); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(33333, 'FLW-H1');
  assert res->>'matched' = 'false' and (pg_temp.request(r.id)).status = 'pending', format('wallet_nothing_fits: unmatched, got %s', res);
  assert (select status from bank_lines where id = (res->>'bank_line')::uuid) = 'unmatched', 'wallet_nothing_fits: line waits';
  assert exists (select 1 from net._requests where url like '%/atlas' and body->>'action' = 'classify_lines'), 'wallet_nothing_fits: Atlas is asked';
  perform tests.remember('h_sale', v);
  perform tests.remember('h_req', r.id);
end $$;

-- test: claim_rules
-- The customer's word from the document page: a bad token, no request waiting, no amount and too much are refused; a
-- good one is kept with the name tidied; ten tries at most. Only the service role calls it.
do $$
declare v uuid := tests.id('h_sale'); tok text := (pg_temp.sale(tests.id('h_sale'))).public_token; other uuid := pg_temp.inv(tests.id('dayo'), 1000);
  r jsonb; i int;
begin
  perform tests.as_service();
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', 'not-a-token', '{"amount": 1}'), '%Document not found.%');
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', (pg_temp.sale(other)).public_token, '{"amount": 1075}'),
    '%Choose how you are paying first, then tell us once you have paid.%');
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', tok, '{"amount": 0}'), '%Enter the amount you sent.%');
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', tok, '{"amount": 645001}'), '%That is more than the ₦645,000.00 owed.%');
  r := public.svc_public_claim(tok, '{"amount": "600,000", "name": "  Dayo   Farms  "}');
  perform tests.as_postgres();
  assert r->>'id' = tests.id('h_req')::text and (r->>'direct')::boolean and r->>'wallet_id' = tests.id('w')::text, format('claim_rules: request, got %s', r);
  assert (pg_temp.request(tests.id('h_req'))).claim->>'name' = 'Dayo Farms' and ((pg_temp.request(tests.id('h_req'))).claim->>'amount')::numeric = 600000
    and (pg_temp.request(tests.id('h_req'))).claimed_at is not null, format('claim_rules: kept, got %s', (pg_temp.request(tests.id('h_req'))).claim);
  assert (public.public_payment_status(tok)->'request'->>'claim_amount')::numeric = 600000
    and public.public_payment_status(tok)->'request'->>'claim_flagged' = 'false', 'claim_rules: the page sees it';
  perform tests.as_service();
  for i in 2..10 loop perform public.svc_public_claim(tok, '{"amount": 600000}'); end loop;
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', tok, '{"amount": 600000}'), '%Your payment is noted. Ada Clinic Ltd will confirm it once it arrives.%');
  perform tests.as_anon();
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', tok, '{"amount": 1}'), '%permission denied%');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.svc_public_claim(%L, %L)', tok, '{"amount": 1}'), '%permission denied%');
  perform tests.as_postgres();
end $$;

-- test: claim_unanswered_then_paid
-- Ten minutes on, nothing matched: the work list shows it, the business is asked once (inbox and notices), and the money
-- of the claimed amount landing later pays the request (part of what is owed, so the business is told) and answers it.
do $$
declare tok text := (pg_temp.sale(tests.id('h_sale'))).public_token; w jsonb; r jsonb; p public.ai_proposals; res jsonb;
begin
  perform tests.as_service();
  w := public.svc_work('claims');
  perform tests.as_postgres();
  assert jsonb_array_length(w) = 0, format('claim_unanswered_then_paid: not yet, got %s', w);
  update payment_requests set claimed_at = now() - interval '11 minutes' where id = tests.id('h_req');
  perform tests.as_service();
  w := public.svc_work('claims');
  assert jsonb_array_length(w) = 1 and w->0->>'id' = tests.id('h_req')::text and w->0->>'wallet_id' = tests.id('w')::text, format('claim_unanswered_then_paid: listed, got %s', w);
  r := public.svc_claim_unmatched(tests.id('h_req'));
  assert r->>'asked' = 'true', 'claim_unanswered_then_paid: asked';
  r := public.svc_claim_unmatched(tests.id('h_req'));
  assert r->>'asked' = 'false', 'claim_unanswered_then_paid: once';
  w := public.svc_work('claims');
  perform tests.as_postgres();
  assert jsonb_array_length(w) = 0, 'claim_unanswered_then_paid: off the list';
  select * into p from ai_proposals where kind = 'payment_claim' and source_id = tests.id('h_req');
  assert p.status = 'pending' and p.title = 'Dayo Farms Ltd says they paid ' || (pg_temp.sale(tests.id('h_sale'))).number
    and p.question like '%that they sent ₦600,000.00 from an account named Dayo Farms, and it has not reached the wallet.%', format('claim_unanswered_then_paid: question, got %s', to_jsonb(p));
  assert pg_temp.notified('Dayo Farms Ltd says they paid%') >= 1, 'claim_unanswered_then_paid: notified';
  assert public.public_payment_status(tok)->'request'->>'claim_flagged' = 'true', 'claim_unanswered_then_paid: the page knows';
  -- The money arrives: the amount Dayo said, not a recognised deduction.
  res := pg_temp.land(600000, 'FLW-H2');
  assert (pg_temp.request(tests.id('h_req'))).status = 'paid' and (pg_temp.sale(tests.id('h_sale'))).status = 'partially_paid',
    format('claim_unanswered_then_paid: paid by the claim, got %s', res);
  assert (select status from ai_proposals where id = p.id) = 'approved' and (select decision->>'auto' from ai_proposals where id = p.id) = 'paid',
    'claim_unanswered_then_paid: the question answers itself';
  assert pg_temp.notified((pg_temp.sale(tests.id('h_sale'))).number || ' part paid') = 1, 'claim_unanswered_then_paid: the gap is reported';
end $$;

-- test: settled_elsewhere_closes
-- A payment recorded by hand settles the invoice: the waiting request closes and the customer's page shows paid.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 20000); r public.payment_requests := pg_temp.req(v); paid public.payment_requests;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.record_payment(tests.id('o'), jsonb_build_object('sale_id', v, 'amount', 21500, 'method', 'transfer', 'confirmed', true, 'bank_account_id', tests.id('wbank')));
  perform tests.as_postgres();
  assert (pg_temp.sale(v)).status = 'paid', 'settled_elsewhere_closes: paid';
  assert (pg_temp.request(r.id)).status = 'cancelled' and (pg_temp.request(r.id)).error = 'Settled another way', format('settled_elsewhere_closes: closed, got %s', to_jsonb(pg_temp.request(r.id)));
  assert public.public_payment_status((pg_temp.sale(v)).public_token)->>'status' = 'paid', 'settled_elsewhere_closes: page paid';
  -- A request already paid is left as it is.
  select * into paid from payment_requests where status = 'paid' limit 1;
  perform private.refresh_sale(paid.sale_id);
  assert (pg_temp.request(paid.id)).status = 'paid', 'settled_elsewhere_closes: paid stays paid';
end $$;

-- test: claim_answered_by_hand
-- The business was asked about a customer's word that they paid; recording the payment by hand settles the invoice and
-- answers the question.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 30000); r public.payment_requests := pg_temp.req(v); p public.ai_proposals;
begin
  perform tests.as_service();
  perform public.svc_public_claim((pg_temp.sale(v)).public_token, '{"amount": 32250, "name": "Dayo Farms"}');
  perform tests.as_postgres();
  update payment_requests set claimed_at = now() - interval '12 minutes' where id = r.id;
  perform tests.as_service();
  perform public.svc_claim_unmatched(r.id);
  perform tests.as_postgres();
  select * into p from ai_proposals where kind = 'payment_claim' and source_id = r.id;
  assert p.status = 'pending', 'claim_answered_by_hand: asked';
  perform tests.as_user(tests.id('ada'));
  perform public.record_payment(tests.id('o'), jsonb_build_object('sale_id', v, 'amount', 32250, 'method', 'transfer', 'confirmed', true, 'bank_account_id', tests.id('wbank')));
  perform tests.as_postgres();
  assert (pg_temp.sale(v)).status = 'paid' and (pg_temp.request(r.id)).status = 'cancelled', 'claim_answered_by_hand: settled and closed';
  assert (select status = 'approved' and decision->>'auto' = 'settled' from ai_proposals where id = p.id), 'claim_answered_by_hand: the question answers itself';
end $$;

-- test: inbox_customer_answer_fits
-- Femi owes ₦105,350 (₦98,000 and VAT) and ₦103,390 lands from an unknown sender: the inbox asks whether it pays that invoice.
-- The person says "No, it was something else" and answers "a customer paying what they owe: Femi". The invoice it fits less
-- 2% WHT is paid, the WHT booked, the answer names the invoice, and ledger and invoices agree.
do $$
declare v uuid := pg_temp.inv(tests.id('femi'), 98000); res jsonb; p uuid; v_susp numeric;
begin
  res := pg_temp.land(103390, 'FLW-I1', 'NIP TRF', 'K. ADEYEMI');
  p := pg_temp.question((res->>'bank_line')::uuid);
  assert p is not null and (select proposal->>'kind' from ai_proposals where id = p) = 'invoice_match', format('inbox_customer_answer_fits: asked, got %s', res);
  assert (pg_temp.sale(v)).status = 'open', 'inbox_customer_answer_fits: nothing settled yet';
  select coalesce(sum(debit - credit), 0) into v_susp from journal_lines where org_id = tests.id('o') and account_code = '9001';
  res := pg_temp.answer(p, jsonb_build_object('action', 'change', 'account_code', '1101', 'party_type', 'customer', 'party_id', tests.id('femi'), 'remember', false));
  assert res->>'status' = 'approved' and res->>'settled' = (pg_temp.sale(v)).number and res->>'journal_ref' is not null, format('inbox_customer_answer_fits: answer, got %s', res);
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wht_credit') = 1960, format('inbox_customer_answer_fits: paid with WHT, got %s', to_jsonb(pg_temp.sale(v)));
  assert (select status from bank_lines where id = (select source_id from ai_proposals where id = p)) = 'matched', 'inbox_customer_answer_fits: line matched';
  -- Money in waits as a credit in suspense; the answer takes it back out.
  assert (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = tests.id('o') and account_code = '9001') - v_susp = 103390,
    'inbox_customer_answer_fits: out of suspense';
  assert pg_temp.ledger_owed(tests.id('femi')) = pg_temp.invoices_owed(tests.id('femi')), 'inbox_customer_answer_fits: ledger and invoices agree';
  assert (select decision->'chosen'->>'kind' from ai_proposals where id = p) = 'sale', 'inbox_customer_answer_fits: the choice is kept';
end $$;

-- test: inbox_customer_answer_oldest
-- Gbenga owes on two invoices (₦107,500 and ₦215,000) and ₦150,000 lands that fits neither: answered as Gbenga paying what
-- they owe, the oldest is paid and the next part paid. A customer with nothing owed: held as their credit. No customer named:
-- refused.
do $$
declare g uuid; a uuid; b uuid; res jsonb; p uuid; v_credit numeric;
begin
  perform tests.as_user(tests.id('ada'));
  g := tests.remember('gbenga', public.save_customer(tests.id('o'), '{"name": "Gbenga Motors Ltd", "email": "gbenga@example.test", "kind": "business"}'));
  perform tests.as_postgres();
  a := pg_temp.inv(g, 100000); b := pg_temp.inv(g, 200000);
  update sales set issue_date = issue_date - 10, due_date = coalesce(due_date, issue_date) - 10 where id = a;
  res := pg_temp.land(150000, 'FLW-J1', 'TRANSFER', 'GOLDEN TRADING CO');
  p := pg_temp.question((res->>'bank_line')::uuid);
  assert p is not null, format('inbox_customer_answer_oldest: asked, got %s', res);
  perform tests.throws(format('select pg_temp.answer(%L, %L)', p, '{"action": "change", "account_code": "1101", "party_type": "customer"}'), '%Say which customer.%');
  res := pg_temp.answer(p, jsonb_build_object('action', 'change', 'account_code', '1101', 'party_type', 'customer', 'party_id', g, 'remember', true));
  assert res->>'settled' = (pg_temp.sale(a)).number || ', ' || (pg_temp.sale(b)).number, format('inbox_customer_answer_oldest: both named, got %s', res);
  assert (pg_temp.sale(a)).status = 'paid' and (pg_temp.sale(b)).status = 'partially_paid' and (pg_temp.sale(b)).amount_paid = 42500,
    format('inbox_customer_answer_oldest: oldest first, got %s / %s', to_jsonb(pg_temp.sale(a)), to_jsonb(pg_temp.sale(b)));
  assert pg_temp.ledger_owed(g) = pg_temp.invoices_owed(g), 'inbox_customer_answer_oldest: ledger and invoices agree';
  -- The rule learned from that answer: Golden Trading's next payment goes to Gbenga's invoices, less 5% WHT on what is left.
  assert exists (select 1 from entity_rules where org_id = tests.id('o') and customer_id = g and account_code = '1101'), 'inbox_customer_answer_oldest: rule learned';
  res := pg_temp.land(172500 - 10000, 'FLW-J2', 'TRANSFER', 'GOLDEN TRADING CO');
  assert (select stage from bank_lines where id = (res->>'bank_line')::uuid) = 'rule', format('inbox_customer_answer_oldest: by the rule, got %s', res);
  assert (pg_temp.sale(b)).status = 'paid' and pg_temp.kept(b, 'wht_credit') = 10000, format('inbox_customer_answer_oldest: rule settles less WHT, got %s', to_jsonb(pg_temp.sale(b)));
  assert pg_temp.ledger_owed(g) = 0 and pg_temp.invoices_owed(g) = 0, 'inbox_customer_answer_oldest: nothing owed';
  -- Nothing owed now: ₦7,000 more from the same customer, answered by hand, is held as credit.
  res := pg_temp.land(7000, 'FLW-J3', 'NIP', 'SOMEONE ELSE');
  p := pg_temp.question((res->>'bank_line')::uuid);
  res := pg_temp.answer(p, jsonb_build_object('action', 'change', 'account_code', '1101', 'party_type', 'customer', 'party_id', g, 'remember', false));
  assert (res->>'credit')::numeric = 7000 and res->>'settled' is null, format('inbox_customer_answer_oldest: credit, got %s', res);
  select coalesce(sum(credit - debit), 0) into v_credit from journal_lines where org_id = tests.id('o') and account_code like '2107%' and party_id = g;
  assert v_credit = 7000, format('inbox_customer_answer_oldest: held in 2107, got %s', v_credit);
end $$;

-- test: matcher_named_customer_fits
-- No request waiting. Bola's transfer names Bola and fits one open invoice less 5% WHT: settled without asking. When two of
-- Bola's invoices fit, a person is asked, as before.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), 250000); a uuid; b uuid; res jsonb;
begin
  res := pg_temp.land(256250, 'FLW-K1', 'TRANSFER', 'BOLA STORES LTD');
  assert (select stage from bank_lines where id = (res->>'bank_line')::uuid) = 'customer_invoice', format('matcher_named_customer_fits: settled, got %s', res);
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wht_credit') = 12500, 'matcher_named_customer_fits: paid with WHT';
  a := pg_temp.inv(tests.id('bola'), 50000); b := pg_temp.inv(tests.id('bola'), 50000);
  res := pg_temp.land(51250, 'FLW-K2', 'TRANSFER', 'BOLA STORES LTD');
  assert (select stage from bank_lines where id = (res->>'bank_line')::uuid) = 'customer', format('matcher_named_customer_fits: two fit, asked, got %s', res);
  assert (pg_temp.sale(a)).status = 'open' and (pg_temp.sale(b)).status = 'open', 'matcher_named_customer_fits: neither settled';
end $$;

-- test: direct_tick
-- The one-minute run asks the payments function only while a transfer to the business's own number is waiting.
do $$
declare n int;
begin
  perform private.payments_direct_tick();
  assert exists (select 1 from net._requests where url like '%/payments' and body->>'action' = 'poll_direct'), 'direct_tick: asked';
  update payment_requests set status = 'expired' where direct and status = 'pending';
  select count(*) into n from net._requests where body->>'action' = 'poll_direct';
  perform private.payments_direct_tick();
  assert (select count(*) from net._requests where body->>'action' = 'poll_direct') = n, 'direct_tick: quiet when nothing waits';
end $$;

-- test: privileges
-- The new helpers are not callable by app users; the service functions only by the service role.
do $$
declare f text;
begin
  foreach f in array array['private.request_split(uuid,numeric)', 'private.customer_pick(uuid,uuid,numeric)', 'private.payments_direct_tick()',
    'public.svc_public_claim(text,jsonb)', 'public.svc_claim_unmatched(uuid)', 'public.svc_wallet_inflow(text,text,jsonb)'] loop
    assert not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute'), 'privileges: closed ' || f;
  end loop;
  assert has_function_privilege('service_role', 'public.svc_public_claim(text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.svc_claim_unmatched(uuid)', 'execute'), 'privileges: service role';
  assert has_function_privilege('anon', 'public.public_payment_status(text)', 'execute'), 'privileges: the document page reads its status';
end $$;
rollback;
