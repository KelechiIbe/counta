-- WHT worked out line by line (20261207000200_wht_by_line.sql): an invoice with technical services and medical services at
-- 5% and nappies at 2% settles when the customer keeps back ₦8.30, on the value before VAT or on the totals with VAT; a
-- single rate still settles; lines without a type take the usual rate; a person's choice on a line wins over Numens and
-- is kept for those words; a person or walk-in keeps nothing; a rate set on the invoice overrides the lines; the sweep
-- asks about each set of words once at a time. Only fake people (example.test addresses).
begin;

-- Fixture: Tola owns Line Tech Ltd (a company with a Tax ID, VAT-registered). Customers Symbol Solutions Ltd and Ngozi
-- Okafor (a person).
do $$
declare o uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('tola', tests.user('tola.owner@linetech.example.test', 'Tola Owner'));
  o := tests.remember('o', tests.org(tests.id('tola'), 'Line Tech Ltd'));
  update orgs set vat_registered = true, tin = '22222222-0001', legal_form = 'company' where id = o;
  perform tests.as_user(tests.id('tola'));
  perform tests.remember('sym', public.save_customer(o, '{"name": "Symbol Solutions Ltd", "email": "symbol@example.test", "kind": "business"}'));
  perform tests.remember('ngozi', public.save_customer(o, '{"name": "Ngozi Okafor", "email": "ngozi@example.test", "kind": "individual"}'));
  perform tests.as_postgres();
  -- What Numens said for the words of the three lines.
  perform public.svc_line_wht_store(o, '[{"description": "Technology Implementation Services", "category": "professional", "confidence": 0.93, "reason": "Technical services"},
    {"description": "Medical services", "category": "professional", "confidence": 0.88, "reason": "Professional medical services"},
    {"description": "Supply of Huggies Diapers", "category": "goods", "confidence": 0.95, "reason": "Supply of goods"}]'::jsonb);
end $$;

-- An issued invoice: lines are [description, net, VAT treatment], prices before VAT.
create function pg_temp.inv(p_customer uuid, p_lines jsonb) returns uuid language plpgsql as $f$
declare s jsonb; ln jsonb := '[]'::jsonb; x jsonb;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    ln := ln || jsonb_build_object('description', x->>0, 'qty', 1, 'unit_price', (x->>1)::numeric, 'vat_treatment', x->>2);
  end loop;
  perform tests.as_user(tests.id('tola'));
  s := public.save_sale_doc(tests.id('o'), jsonb_build_object('customer_id', p_customer, 'status', 'draft', 'prices_include_vat', false, 'doc_type', 'invoice', 'lines', ln));
  perform public.issue_invoice((s->>'id')::uuid, null);
  perform tests.as_postgres();
  return (s->>'id')::uuid;
end $f$;
create function pg_temp.mixed() returns uuid language sql as $f$
  select pg_temp.inv(tests.id('sym'), '[["Technology Implementation Services", 100, "standard"], ["Medical services", 50, "zero"], ["Supply of Huggies Diapers", 40, "exempt"]]')
$f$;
create function pg_temp.pay(p_sale uuid, p_amt numeric) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_user(tests.id('tola'));
  r := public.record_payment(tests.id('o'), jsonb_build_object('sale_id', p_sale, 'amount', p_amt, 'method', 'cash'));
  perform tests.as_postgres();
  return r;
end $f$;
create function pg_temp.kept(p_sale uuid) returns numeric language sql as $f$
  select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id
  where a.sale_id = p_sale and c.method = 'wht_credit' and c.status = 'confirmed'
$f$;
create function pg_temp.sale(p_sale uuid) returns public.sales language sql as $f$ select * from sales where id = p_sale $f$;

-- test: expected_by_line
-- ₦197.50 (₦190 and ₦7.50 VAT): 5% of ₦100, 5% of ₦50 and 2% of ₦40 is ₦8.30.
do $$
declare v uuid := pg_temp.mixed(); e jsonb := private.expected_wht(v);
begin
  assert (pg_temp.sale(v)).total = 197.50, 'expected_by_line: the invoice';
  assert e->>'source' = 'lines' and (e->>'amount')::numeric = 8.30 and (e->>'missing')::int = 0, format('expected_by_line: 8.30 by line, got %s', e);
  assert (e->>'amount_total')::numeric = 8.68, format('expected_by_line: 8.68 on the totals with VAT, got %s', e->'amount_total');
end $$;

-- test: paid_less_mixed_wht
-- ₦189.20 paid: settled in full with ₦8.30 WHT; the customer's single usual rate is not set from it.
do $$
declare v uuid := pg_temp.mixed(); r jsonb;
begin
  r := pg_temp.pay(v, 189.20);
  assert (pg_temp.sale(v)).status = 'paid', format('paid_less_mixed_wht: paid, got %s', r);
  assert pg_temp.kept(v) = 8.30, format('paid_less_mixed_wht: 8.30 kept, got %s', pg_temp.kept(v));
  assert r->'withheld'->>'wht_base' = 'by_line' and jsonb_array_length(r->'withheld'->'wht_lines') = 3, format('paid_less_mixed_wht: by line, got %s', r->'withheld');
  assert (select wht_rate from customers where id = tests.id('sym')) is null, 'paid_less_mixed_wht: no single rate remembered';
end $$;

-- test: paid_less_mixed_wht_on_totals
-- The customer worked it out on each line with VAT (₦8.68): ₦188.82 settles too.
do $$
declare v uuid := pg_temp.mixed(); r jsonb;
begin
  r := pg_temp.pay(v, 188.82);
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v) = 8.68, format('paid_less_mixed_wht_on_totals: paid with 8.68, got %s', r);
  assert r->'withheld'->>'wht_base' = 'by_line_total', format('paid_less_mixed_wht_on_totals: on totals, got %s', r->'withheld');
end $$;

-- test: single_rate_still_settles
-- The customer kept 2% of everything (₦3.80): still recognised, as before.
do $$
declare v uuid := pg_temp.mixed(); r jsonb;
begin
  r := pg_temp.pay(v, 193.70);
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v) = 3.80, format('single_rate_still_settles: paid with 3.80, got %s', r);
  assert r->'withheld'->>'wht_base' = 'net' and (r->'withheld'->>'wht_rate')::numeric = 0.02, format('single_rate_still_settles: 2%% on the value, got %s', r->'withheld');
  update customers set wht_rate = null where id = tests.id('sym');
end $$;

-- test: untyped_line_takes_usual_rate
-- A line Numens has not answered yet takes the business's usual rate for its work beside the typed lines.
do $$
declare v uuid := pg_temp.inv(tests.id('sym'), '[["Technology Implementation Services", 100, "standard"], ["Something new entirely", 100, "standard"]]'); e jsonb;
  usual numeric := (private.org_wht_rate(tests.id('o'))->>'rate')::numeric;
begin
  e := private.expected_wht(v);
  assert e->>'source' = 'lines' and (e->>'missing')::int = 1, format('untyped_line_takes_usual_rate: one missing, got %s', e);
  assert (e->>'amount')::numeric = 5 + round(100 * usual, 2), format('untyped_line_takes_usual_rate: 5 plus the usual, got %s', e->'amount');
end $$;

-- test: person_changes_a_line
-- The owner sets the medical services line to other services (2%): ₦6.80 expected, the choice is kept for those words and
-- Numens' later answer does not replace it.
do $$
declare v uuid := pg_temp.mixed(); v2 uuid; ln uuid; w jsonb;
begin
  select id into ln from sale_lines where sale_id = v and description = 'Medical services';
  perform tests.as_user(tests.id('tola'));
  w := public.set_sale_line_wht(ln, 'services');
  perform tests.as_postgres();
  assert (w->'expected'->>'amount')::numeric = 6.80, format('person_changes_a_line: 6.80, got %s', w->'expected');
  assert (select source || ':' || category from line_wht where org_id = tests.id('o') and key = 'medical services') = 'person:services', 'person_changes_a_line: kept for the words';
  perform public.svc_line_wht_store(tests.id('o'), '[{"description": "Medical services", "category": "professional", "confidence": 0.99}]'::jsonb);
  assert (select category from line_wht where org_id = tests.id('o') and key = 'medical services') = 'services', 'person_changes_a_line: Numens does not replace it';
  v2 := pg_temp.mixed();
  assert (private.expected_wht(v2)->>'amount')::numeric = 6.80, format('person_changes_a_line: the next invoice takes it, got %s', private.expected_wht(v2));
  -- Back to Numens.
  perform tests.as_user(tests.id('tola'));
  perform public.set_sale_line_wht(ln, null);
  perform tests.as_postgres();
  perform public.svc_line_wht_store(tests.id('o'), '[{"description": "Medical services", "category": "professional", "confidence": 0.88}]'::jsonb);
  assert (private.expected_wht(v)->>'amount')::numeric = 8.30, 'person_changes_a_line: back to Numens';
end $$;

-- test: person_customer_keeps_nothing
do $$
declare v uuid := pg_temp.inv(tests.id('ngozi'), '[["Technology Implementation Services", 100, "standard"]]');
begin
  assert private.expected_wht(v)->>'source' = 'person' and (private.expected_wht(v)->>'amount')::numeric = 0, 'person_customer_keeps_nothing';
end $$;

-- test: invoice_rate_overrides_lines
-- A rate a person set on the invoice wins; setting a line hands it back to the lines.
do $$
declare v uuid := pg_temp.mixed(); ln uuid;
begin
  perform tests.as_user(tests.id('tola'));
  perform public.set_sale_wht_rate(v, 0.05);
  perform tests.as_postgres();
  assert private.expected_wht(v)->>'source' = 'invoice' and (private.expected_wht(v)->>'amount')::numeric = 9.50, 'invoice_rate_overrides_lines: 5% of 190';
  select id into ln from sale_lines where sale_id = v and description = 'Supply of Huggies Diapers';
  perform tests.as_user(tests.id('tola'));
  perform public.set_sale_line_wht(ln, 'goods');
  perform tests.as_postgres();
  assert private.expected_wht(v)->>'source' = 'lines' and (pg_temp.sale(v)).wht_rate is null, 'invoice_rate_overrides_lines: back to the lines';
end $$;

-- test: no_tax_id_doubles
do $$
declare v uuid;
begin
  update orgs set tin = null where id = tests.id('o');
  v := pg_temp.mixed();
  assert (private.expected_wht(v)->>'amount')::numeric = 16.60, format('no_tax_id_doubles: 16.60, got %s', private.expected_wht(v));
  update orgs set tin = '22222222-0001' where id = tests.id('o');
end $$;

-- test: screen_lists_lines_and_types
do $$
declare v uuid := pg_temp.mixed(); w jsonb;
begin
  perform tests.as_user(tests.id('tola'));
  w := public.sale_withholding(v, null);
  perform tests.as_postgres();
  assert jsonb_array_length(w->'lines') = 3 and (w->>'wht')::numeric = 8.30 and (w->>'can_change')::boolean, format('screen_lists_lines_and_types: got %s', w);
  assert exists (select 1 from jsonb_array_elements(w->'types') t where t->>'code' = 'professional' and (t->>'rate')::numeric = 0.05)
     and not exists (select 1 from jsonb_array_elements(w->'types') t where t->>'code' in ('none', 'dividend', 'directors_fees')), 'screen_lists_lines_and_types: the types';
end $$;

-- test: sweep_asks_once
-- New words on an open invoice are listed for the model once, then not again for twenty minutes; answered words never.
do $$
declare v uuid := pg_temp.inv(tests.id('sym'), '[["Cloud migration workshop", 300, "standard"]]'); a jsonb; b jsonb;
begin
  a := public.svc_lines_for_wht(60);
  assert exists (select 1 from jsonb_array_elements(a) g, jsonb_array_elements_text(g->'lines') d where (g->>'org_id')::uuid = tests.id('o') and d = 'Cloud migration workshop'),
    format('sweep_asks_once: listed, got %s', a);
  b := public.svc_lines_for_wht(60);
  assert not exists (select 1 from jsonb_array_elements(b) g, jsonb_array_elements_text(g->'lines') d where d = 'Cloud migration workshop'), 'sweep_asks_once: not again at once';
  perform public.svc_line_wht_store(tests.id('o'), '[{"description": "Cloud migration workshop", "category": "professional", "confidence": 0.9}]'::jsonb);
  assert (private.expected_wht(v)->>'amount')::numeric = 15, 'sweep_asks_once: answered';
end $$;

-- test: wallet_payment_less_mixed_wht
-- The case from production: a pay-by-transfer request for INV-0001's ₦197.50, and ₦189.20 lands in the business wallet. It
-- settles the invoice with ₦8.30 WHT, where before it waited in the Books inbox.
do $$
declare v uuid; w uuid; r jsonb;
begin
  update orgs set payment_rail = 'flutterwave', payment_methods = '{account,link,qr}', identity_status = 'verified' where id = tests.id('o');
  insert into wallets (org_id, rail) values (tests.id('o'), 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, '{"account_ref": "PSA-LINE", "account_number": "9922334455", "bank_name": "Flutterwave MFB", "account_name": "Line Tech Ltd"}');
  v := pg_temp.mixed();
  perform private.open_request(tests.id('o'), v, null, 'account', null,
    (select mm from members mm where mm.org_id = tests.id('o') and mm.user_id = tests.id('tola')), true, null);
  perform tests.as_service();
  r := public.svc_wallet_inflow('flutterwave', '9922334455', jsonb_build_object('amount', 189.20, 'reference', 'FUND-LINES', 'narration', 'Received Money from A Customer'));
  perform tests.as_postgres();
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v) = 8.30, format('wallet_payment_less_mixed_wht: paid with 8.30 WHT, got %s and %s', r, pg_temp.sale(v));
end $$;

-- test: permissions
do $$
begin
  perform tests.as_anon();
  perform tests.throws($q$select public.set_sale_line_wht(gen_random_uuid(), 'goods')$q$, '%permission denied%');
  perform tests.throws($q$select public.svc_lines_for_wht(5)$q$, '%permission denied%');
  perform tests.as_postgres();
end $$;

rollback;
