-- Release 5 (20261129000100_prior_years_assets.sql): earlier years and assets from the bank. A bank line whose money ends up in
-- a fixed asset account opens a register record to confirm, and money in there waits to be matched to the asset sold;
-- corrections move or withdraw what they opened. Personal income tax from 2024 accounts. A filing-only business's year says
-- where it starts before its return is approved. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Haulage Ltd (logistics, on the free plan) with Bola on the staff and Chidi as accountant. Femi owns
-- Femi Motors Ltd (a car dealer, filing-only, incorporated 2019). Kemi owns Kemi Stores, a business name.
do $$
declare o uuid; f uuid; k uuid; u uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@haulage.example.test', 'Ada Owner'));
  perform tests.remember('bola', tests.user('bola.staff@haulage.example.test', 'Bola Staff'));
  perform tests.remember('chidi', tests.user('chidi.books@haulage.example.test', 'Chidi Books'));
  perform tests.remember('femi', tests.user('femi.owner@motors.example.test', 'Femi Owner'));
  perform tests.remember('kemi', tests.user('kemi.owner@stores.example.test', 'Kemi Owner'));

  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Haulage Ltd'));
  update orgs set legal_form = 'company', category_id = 'logistics', offering = 'services', capitalisation_threshold = 100000,
    principal_activity = 'Haulage of goods by road', incorporation_date = '2018-05-02' where id = o;
  perform tests.remember('bola_seat', tests.member(o, tests.id('bola'), 'staff'));
  perform tests.remember('chidi_seat', tests.member(o, tests.id('chidi'), 'accountant'));
  insert into kyc_profiles (user_id, org_id, status, source, answers)
  values (tests.id('ada'), o, 'submitted', 'manual', '{"examples": ["Haulage", "Container delivery"]}');

  f := tests.remember('f', tests.org(tests.id('femi'), 'Femi Motors Ltd'));
  update orgs set legal_form = 'company', filing_only = true, category_id = 'auto', offering = 'both', incorporation_date = '2019-03-01' where id = f;
  k := tests.remember('k', tests.org(tests.id('kemi'), 'Kemi Stores'));
  update orgs set legal_form = 'enterprise', commenced_on = '2023-06-01' where id = k;

  perform tests.as_user(tests.id('ada'));
  perform tests.remember('acct', (public.open_bank_account(o, 'bank', 'GTBank current', '{"bank_name": "GTBank", "account_number": "0123456789"}')->>'id')::uuid);
  perform public.import_bank_lines(o, tests.id('acct'), jsonb_build_array(
    jsonb_build_object('date', '2026-03-05', 'amount', -450000, 'description', 'TRF SLOT SYSTEMS LAPTOPS', 'reference', 'R1'),
    jsonb_build_object('date', '2026-03-20', 'amount', 300000, 'description', 'TRF FROM JOHN DOE HILUX SALE', 'reference', 'R2'),
    jsonb_build_object('date', '2026-04-02', 'amount', -120000, 'description', 'CUSTOMS DUTY LAPTOPS', 'reference', 'R3'),
    jsonb_build_object('date', '2026-04-10', 'amount', -2000000, 'description', 'TOYOTA NIGERIA NEW HIACE', 'reference', 'R4'),
    jsonb_build_object('date', '2026-04-12', 'amount', -30000, 'description', 'OFFICE CHAIR', 'reference', 'R5'),
    jsonb_build_object('date', '2026-04-15', 'amount', 50000, 'description', 'TRF FROM TUNDE REFUND', 'reference', 'R6')),
    '{"file_name": "march-april.csv", "source": "csv"}');
  perform tests.as_postgres();
  for u in select id from bank_lines where org_id = o loop
    perform tests.remember('l_' || (select reference from bank_lines where id = u), u);
  end loop;
  insert into storage.buckets (id, name) values ('documents', 'documents') on conflict do nothing;
end $$;

-- The bookkeeper's answer for a line, as the atlas function sends it.
create function pg_temp.classify(p_line uuid, p_code text, p_conf numeric, p_title text default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_service();
  r := public.svc_classify_line(p_line, jsonb_build_object('account_code', p_code, 'confidence', p_conf, 'title', coalesce(p_title, 'Line'),
    'rationale', 'test', 'kind', 'asset', 'question', case when p_conf < 0.8 then 'What was this for?' end));
  perform tests.as_postgres();
  return r;
end $f$;
create function pg_temp.asset_of(p_line uuid) returns public.fixed_assets language sql as $f$
  select * from fixed_assets where bank_line_id = p_line order by created_at desc limit 1
$f$;
create function pg_temp.ledger(p_org uuid, p_code text) returns numeric language sql as $f$
  select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = p_code
$f$;
create function pg_temp.register(p_org uuid, p_code text) returns numeric language sql as $f$
  select coalesce(sum(cost), 0) from fixed_assets where org_id = p_org and class_account = p_code and status in ('active', 'pending_confirmation')
$f$;

-- test: bank_purchase_opens_record
-- The bookkeeper posts a payment to an asset account: a register record waits for confirmation, named by the bookkeeper's
-- title, dated the day of the payment, linked to the line. A person moving it to another asset account moves the record.
do $$
declare o uuid := tests.id('o'); a public.fixed_assets; pr public.ai_proposals; ib jsonb;
begin
  perform pg_temp.classify(tests.id('l_R1'), '1517', 0.95, 'Laptops for the dispatch team');
  a := pg_temp.asset_of(tests.id('l_R1'));
  assert a.id is not null and a.status = 'pending_confirmation' and a.cost = 450000 and a.class_account = '1517' and a.line_class = '1517'
    and a.available_date = '2026-03-05' and a.life_months = 36 and a.name = 'Laptops for the dispatch team' and a.journal_id is not null,
    'bank_purchase: a record waits, from the payment';
  assert pg_temp.ledger(o, '1517') = 450000 and pg_temp.register(o, '1517') = 450000, 'bank_purchase: the register agrees with the ledger';
  perform tests.as_user(tests.id('ada'));
  ib := public.get_books_inbox(o);
  assert (ib->>'assets_to_confirm')::int = 1 and (ib->>'asset_sales_to_match')::int = 0, 'bank_purchase: the inbox counts it';
  assert (select x->'bank_line'->>'narration' from jsonb_array_elements(public.get_assets(o)->'assets') x where x->>'id' = a.id::text) = 'TRF SLOT SYSTEMS LAPTOPS',
    'bank_purchase: the register shows the payment';
  -- Wrong account: office equipment. The same record moves with the money.
  select * into pr from ai_proposals where source_id = tests.id('l_R1') and source_type = 'bank_line';
  perform public.resolve_proposal(pr.id, '{"action": "change", "account_code": "1514"}');
  perform tests.as_postgres();
  assert (select count(*) from fixed_assets where bank_line_id = tests.id('l_R1')) = 1, 'bank_purchase: one record';
  a := pg_temp.asset_of(tests.id('l_R1'));
  assert a.status = 'pending_confirmation' and a.class_account = '1514' and a.line_class = '1514' and a.life_months = 48 and a.cost = 450000,
    'bank_purchase: the record moved to office equipment';
  assert pg_temp.ledger(o, '1517') = 0 and pg_temp.ledger(o, '1514') = 450000 and pg_temp.register(o, '1514') = 450000, 'bank_purchase: the ledger moved too';
end $$;

-- test: bank_question_answered
-- A payment the bookkeeper was unsure of waits in suspense with no record; the person's answer, an asset account, opens one.
-- A second payment for the same asset (customs duty) joins it, and the joined asset is confirmed.
do $$
declare o uuid := tests.id('o'); pr public.ai_proposals; a public.fixed_assets; b public.fixed_assets; r jsonb;
begin
  perform pg_temp.classify(tests.id('l_R3'), '1517', 0.5);
  assert pg_temp.asset_of(tests.id('l_R3')) is null, 'bank_question: nothing while it is a question';
  select * into pr from ai_proposals where source_id = tests.id('l_R3') and source_type = 'bank_line';
  perform tests.as_user(tests.id('chidi'));
  perform public.resolve_proposal(pr.id, '{"action": "approve", "account_code": "1514"}');
  perform tests.as_postgres();
  a := pg_temp.asset_of(tests.id('l_R3'));
  assert a.status = 'pending_confirmation' and a.cost = 120000 and a.class_account = '1514', 'bank_question: the answer opened a record';
  b := pg_temp.asset_of(tests.id('l_R1'));
  -- Bola keeps no books.
  perform tests.as_user(tests.id('bola'));
  perform tests.throws(format('select public.merge_asset(%L, %L)', a.id, b.id), '42501:%');
  perform tests.as_user(tests.id('chidi'));
  perform tests.throws(format('select public.merge_asset(%L, %L)', a.id, a.id), '%Choose the asset this belongs to%');
  r := public.merge_asset(a.id, b.id);
  assert (r->>'cost')::numeric = 570000, 'bank_question: the duty joined the laptops';
  r := public.confirm_asset(b.id, '{"life_months": 36, "available_date": "2026-04-03", "name": "Dispatch laptops"}');
  perform tests.throws(format('select public.merge_asset(%L, %L)', a.id, b.id), '%Only an asset waiting for confirmation%');
  perform tests.as_postgres();
  select * into a from fixed_assets where id = a.id;
  assert a.status = 'rejected' and a.merged_into = b.id and a.confirmed_by is not null, 'bank_question: the duty record closed into the laptops';
  assert (select status from fixed_assets where id = b.id) = 'active' and pg_temp.register(o, '1514') = 570000 and pg_temp.ledger(o, '1514') = 570000,
    'bank_question: confirmed, and the register agrees';
  -- Moving either payment away now would leave the register wrong, so it is refused.
  perform tests.throws(format($q$select private.post_entry(%L, 'move', 'reclass', %L, null, null, private.reclass_pair('6209', '1514', 450000, null), now())$q$,
    o, tests.id('l_R1')), '%FA-0001 in the asset register comes from this payment%');
  perform tests.throws(format($q$select private.post_entry(%L, 'move', 'reclass', %L, null, null, private.reclass_pair('6209', '1514', 120000, null), now())$q$,
    o, tests.id('l_R3')), '%FA-0001 in the asset register comes from this payment%');
end $$;

-- test: bank_purchase_expensed
-- A small item the bookkeeper took for an asset is treated as an expense from the register; the record stays closed even when
-- the line's journals are looked at again. A payment moved away from an asset account before confirmation withdraws its
-- record, and moving it back brings the record back.
do $$
declare o uuid := tests.id('o'); a public.fixed_assets;
begin
  perform pg_temp.classify(tests.id('l_R5'), '1519', 0.9, 'Office chair');
  a := pg_temp.asset_of(tests.id('l_R5'));
  assert a.status = 'pending_confirmation' and a.cost = 30000, 'bank_expensed: a record for the chair';
  perform tests.as_user(tests.id('chidi'));
  perform public.reject_asset(a.id, '6212');
  perform tests.as_postgres();
  perform private.bank_asset_sync(tests.id('l_R5'));
  assert (select count(*) from fixed_assets where bank_line_id = tests.id('l_R5')) = 1 and (select status from fixed_assets where id = a.id) = 'rejected',
    'bank_expensed: expensed once, not reopened';
  assert pg_temp.ledger(o, '1519') = 0 and pg_temp.ledger(o, '6212') = 30000, 'bank_expensed: in the expense account';
  -- R4 (the new bus) goes to furniture by mistake, then away, then to buses.
  perform pg_temp.classify(tests.id('l_R4'), '1519', 0.9, 'Toyota Hiace bus');
  a := pg_temp.asset_of(tests.id('l_R4'));
  perform private.post_entry(o, 'move', 'reclass', tests.id('l_R4'), null, null, private.reclass_pair('9001', '1519', 2000000, null), now());
  assert (select status from fixed_assets where id = a.id) = 'rejected' and (select notes from fixed_assets where id = a.id) like '%moved to another account%',
    'bank_expensed: withdrawn with the money';
  perform private.post_entry(o, 'move back', 'reclass', tests.id('l_R4'), null, null, private.reclass_pair('1512', '9001', 2000000, null), now());
  select * into a from fixed_assets where id = a.id;
  assert a.status = 'pending_confirmation' and a.class_account = '1512' and a.line_class = '1512' and a.cost = 2000000 and a.life_months = 60
    and coalesce(a.notes, '') not like '%moved%' and (select count(*) from fixed_assets where bank_line_id = tests.id('l_R4')) = 1,
    'bank_expensed: the same record back, in buses';
end $$;

-- test: bank_sale_matched
-- Money in to an asset account waits to be matched to the asset sold; the month cannot close until it is. Matching runs
-- depreciation to the day of the sale, takes the asset out at its carrying amount and posts the loss; the asset account clears.
do $$
declare o uuid := tests.id('o'); s public.asset_sales; h jsonb; r jsonb; v jsonb; v_bus uuid := (pg_temp.asset_of(tests.id('l_R4'))).id;
begin
  perform tests.as_user(tests.id('ada'));
  h := public.add_asset(o, '{"name": "Toyota Hilux", "class_account": "1511", "cost": 2000000, "accumulated": 1200000, "funding": "opening",
    "date": "2025-12-31", "available_date": "2023-01-01", "life_months": 48}');
  perform tests.as_postgres();
  perform pg_temp.classify(tests.id('l_R2'), '1511', 0.9, 'Sale of the old Hilux');
  select * into s from asset_sales where bank_line_id = tests.id('l_R2');
  assert s.status = 'pending' and s.amount = 300000 and s.class_account = '1511', 'bank_sale: waits to be matched';
  perform tests.as_user(tests.id('ada'));
  assert (public.get_books_inbox(o)->>'asset_sales_to_match')::int = 1, 'bank_sale: the inbox counts it';
  v := (select x from jsonb_array_elements(public.close_checklist(o, '2026-03-31')->'steps') x where x->>'key' = 'assets_confirmed');
  assert not (v->>'ok')::boolean, 'bank_sale: the month waits for it';
  v := (select x from jsonb_array_elements(public.get_assets(o)->'reconciliation') x where x->>'class' = '1511');
  assert (v->>'unmatched_sales')::numeric = 300000 and (v->>'ledger_cost')::numeric = 1700000 and (v->>'register_cost')::numeric = 2000000,
    'bank_sale: the reconciliation explains the difference';
  perform tests.as_user(tests.id('bola'));
  perform tests.throws(format('select public.match_asset_sale(%L, %L)', s.id, jsonb_build_object('asset_id', h->>'id')), '42501:%');
  perform tests.as_user(tests.id('chidi'));
  perform tests.throws(format('select public.match_asset_sale(%L, %L)', s.id, jsonb_build_object('asset_id', v_bus)),
    '%Confirm FA-% in the register first%');
  r := public.match_asset_sale(s.id, jsonb_build_object('asset_id', h->>'id'));
  perform tests.throws(format('select public.match_asset_sale(%L, %L)', s.id, jsonb_build_object('asset_id', h->>'id')), '%already matched%');
  perform tests.as_postgres();
  assert r->>'status' = 'disposed' and (r->>'proceeds')::numeric = 300000 and r->>'disposed_at' = '2026-03-20', 'bank_sale: the Hilux is disposed of';
  -- 41,666.67 a month from 1 January: two months and 20 days of March, so 110,215.05; carrying 689,784.95; loss 389,784.95.
  assert (r->>'gain')::numeric = -389784.95, 'bank_sale: the loss';
  assert pg_temp.ledger(o, '1511') = 0 and pg_temp.ledger(o, '1560') = 0 and pg_temp.ledger(o, '6804') = 389784.95, 'bank_sale: the accounts clear';
  select * into s from asset_sales where id = s.id;
  assert s.status = 'matched' and s.asset_id = (h->>'id')::uuid and s.journal_id is not null and s.decided_by = tests.id('chidi_seat'), 'bank_sale: matched';
  perform tests.as_user(tests.id('ada'));
  v := (select x from jsonb_array_elements(public.close_checklist(o, '2026-03-31')->'steps') x where x->>'key' = 'assets_confirmed');
  assert (v->>'ok')::boolean, 'bank_sale: nothing waiting for March';
  perform tests.as_postgres();
  perform tests.throws(format($q$select private.post_entry(%L, 'move', 'reclass', %L, null, null, private.reclass_pair('1511', '4516', 300000, null), now())$q$,
    o, tests.id('l_R2')), '%matched to the sale of FA-%');
end $$;

-- test: bank_sale_elsewhere
-- Money the bookkeeper took for an asset sale that was something else moves to its own account; the wait ends.
do $$
declare o uuid := tests.id('o'); s public.asset_sales; r jsonb;
begin
  perform pg_temp.classify(tests.id('l_R6'), '1517', 0.9, 'Sold laptop');
  select * into s from asset_sales where bank_line_id = tests.id('l_R6');
  assert s.status = 'pending' and s.amount = 50000, 'sale_elsewhere: waits';
  perform tests.as_user(tests.id('chidi'));
  perform tests.throws(format('select public.asset_sale_elsewhere(%L, %L)', s.id, '1514'), '%other than a fixed asset account%');
  perform tests.throws(format('select public.asset_sale_elsewhere(%L, %L)', s.id, '1101'), '%only through its own documents%');
  perform tests.throws(format('select public.asset_sale_elsewhere(%L, %L)', s.id, '9001'), '%only through its own documents%');
  r := public.asset_sale_elsewhere(s.id, '4516', 'A refund from Tunde');
  perform tests.throws(format('select public.asset_sale_elsewhere(%L, %L)', s.id, '4516'), '%already moved to another account%');
  perform tests.as_postgres();
  select * into s from asset_sales where id = s.id;
  assert r->>'status' = 'moved' and s.status = 'dismissed' and s.decided_by = tests.id('chidi_seat'), 'sale_elsewhere: dismissed';
  assert pg_temp.ledger(o, '1517') = 0 and pg_temp.ledger(o, '4516') = -50000, 'sale_elsewhere: other income';
end $$;

-- test: part_exchange
-- The new bus is confirmed with the old one taken in part exchange: the old one leaves at the value agreed (a gain here) and
-- that value is part of the new bus's cost. The register agrees with the ledger.
do $$
declare o uuid := tests.id('o'); a public.fixed_assets; old jsonb; r jsonb;
begin
  a := (select x from fixed_assets x where bank_line_id = tests.id('l_R4') and status = 'pending_confirmation');
  perform tests.as_user(tests.id('ada'));
  old := public.add_asset(o, '{"name": "Old Hiace", "class_account": "1512", "cost": 5000000, "accumulated": 4000000, "funding": "opening",
    "date": "2025-12-31", "available_date": "2021-01-01", "life_months": 60}');
  perform tests.throws(format('select public.confirm_asset(%L, %L)', a.id, jsonb_build_object('available_date', '2026-04-10',
    'trade_in', jsonb_build_object('asset_id', old->>'id'))), '%Enter the value the seller gave for FA-%');
  r := public.confirm_asset(a.id, jsonb_build_object('available_date', '2026-04-10', 'trade_in', jsonb_build_object('asset_id', old->>'id', 'value', 1500000)));
  perform tests.throws(format('select public.confirm_asset(%L, %L)', a.id, jsonb_build_object('trade_in', jsonb_build_object('asset_id', old->>'id', 'value', 1))),
    '%recorded when the new asset is confirmed%');
  perform tests.as_postgres();
  assert (r->>'cost')::numeric = 3500000 and r->>'notes' like '%taken in part exchange%', 'part_exchange: the new bus cost 3,500,000';
  assert (select status = 'disposed' and proceeds = 1500000 and disposed_at = '2026-04-10' from fixed_assets where id = (old->>'id')::uuid), 'part_exchange: the old bus left';
  assert pg_temp.ledger(o, '1512') = 3500000 and pg_temp.register(o, '1512') = 3500000, 'part_exchange: the register agrees';
  -- Depreciation of 83,333.33 a month from 1 January to 10 April (3 months and 10 days): 277,777.78; carrying 722,222.22; gain 777,777.78.
  assert pg_temp.ledger(o, '4508') = -777777.78, 'part_exchange: the gain';
end $$;

-- test: director_paid
-- An asset a director paid for personally: the business owes the director.
do $$
declare o uuid := tests.id('o'); r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  r := public.add_asset(o, '{"name": "Generator", "class_account": "1513", "cost": 800000, "funding": "director", "date": "2026-05-01", "available_date": "2026-05-01"}');
  perform tests.throws($q$select public.add_asset(tests.id('o'), '{"name": "X", "class_account": "1513", "cost": 1, "accumulated": 1, "funding": "director"}')$q$,
    '%no depreciation yet%');
  perform tests.as_postgres();
  assert pg_temp.ledger(o, '2106') = -800000 and pg_temp.ledger(o, '1513') = 800000 and r->>'status' = 'active', 'director_paid: owed to the director';
end $$;

-- test: dispose_by_hand
-- Dispose still works as before: proceeds to the bank account chosen.
do $$
declare o uuid := tests.id('o'); r jsonb; a jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  a := public.add_asset(o, '{"name": "Old printer", "class_account": "1514", "cost": 100000, "accumulated": 100000, "funding": "opening", "date": "2025-12-31",
    "available_date": "2020-01-01"}');
  r := public.dispose_asset((a->>'id')::uuid, jsonb_build_object('date', '2026-05-02', 'proceeds', 5000, 'bank_account_id', tests.id('acct'), 'reason', 'Sold for scrap'));
  perform tests.as_postgres();
  assert (r->>'gain')::numeric = 5000 and r->>'status' = 'disposed', 'dispose_by_hand: a gain of 5,000';
  assert (select j.memo from journals j where j.id = (r->>'disposal_journal_id')::uuid) like 'Disposal of FA-% · Old printer · Sold for scrap', 'dispose_by_hand: the memo';
  assert exists (select 1 from journal_lines where journal_id = (r->>'disposal_journal_id')::uuid and debit = 5000
                 and account_code = (select ledger_code from bank_accounts where id = tests.id('acct'))), 'dispose_by_hand: proceeds to the bank';
end $$;

-- test: bookkeeper_context
-- The bookkeeper is told the business's trade, its capitalisation threshold and the assets in use.
do $$
declare o uuid := tests.id('o'); c jsonb; q jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.import_bank_lines(o, tests.id('acct'), '[{"date": "2026-06-01", "amount": -5000, "description": "DIESEL", "reference": "R7"}]', '{"file_name": "june.csv"}');
  perform tests.as_service();
  c := public.svc_lines_for_ai(o, 40);
  q := public.svc_questions_for_ai(o, 40);
  perform tests.as_postgres();
  assert c->'org'->'trade'->>'category' = 'Logistics, haulage and transport' and c->'org'->'trade'->>'sells' = 'services'
     and c->'org'->'trade'->>'activity' = 'Haulage of goods by road' and c->'org'->'trade'->'examples' = '["Haulage", "Container delivery"]'
     and (c->'org'->>'capitalisation_threshold')::numeric = 100000, 'bookkeeper_context: the trade and the threshold';
  assert (select count(*) from jsonb_array_elements(c->'assets') x where x->>'name' = 'Dispatch laptops' and x->>'class' = '1514'
          and (x->>'carrying')::numeric = 570000) = 1, 'bookkeeper_context: the assets in use';
  assert not exists (select 1 from jsonb_array_elements(c->'assets') x where x->>'name' in ('Toyota Hilux', 'Old Hiace')), 'bookkeeper_context: not the ones sold';
  assert q->'org'->'trade' = c->'org'->'trade' and q->'assets' = c->'assets', 'bookkeeper_context: the questions get the same';
end $$;

-- test: backfill
-- Payments posted to an asset account before the release get their records; those in closed months are left alone.
do $$
declare o uuid := tests.id('o'); v_old uuid; v_closed uuid; n int;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.import_bank_lines(o, tests.id('acct'), '[{"date": "2026-06-03", "amount": -250000, "description": "SHELVING", "reference": "R8"},
    {"date": "2026-01-15", "amount": -400000, "description": "OLD DESKS", "reference": "R9"}]', '{"file_name": "more.csv"}');
  perform tests.as_postgres();
  v_old := (select id from bank_lines where org_id = o and reference = 'R8');
  v_closed := (select id from bank_lines where org_id = o and reference = 'R9');
  alter table public.journal_lines disable trigger journal_lines_assets;
  perform private.post_bank_line(v_old, '1519', null, null, 'Shelving', 'user', '{}'::jsonb);
  perform private.post_bank_line(v_closed, '1519', null, null, 'Desks', 'user', '{}'::jsonb);
  alter table public.journal_lines enable trigger journal_lines_assets;
  insert into period_closes (org_id, period_end, status) values (o, '2026-01-31', 'closed');
  assert pg_temp.asset_of(v_old) is null and pg_temp.asset_of(v_closed) is null, 'backfill: none before';
  n := private.bank_asset_backfill();
  assert n = 1 and (pg_temp.asset_of(v_old)).status = 'pending_confirmation' and (pg_temp.asset_of(v_old)).cost = 250000 and pg_temp.asset_of(v_closed) is null,
    'backfill: the open month only';
  assert private.bank_asset_backfill() = 0, 'backfill: once';
  delete from period_closes where org_id = o;
end $$;

-- test: pit_from_2024
-- Personal income tax starts from 2024 accounts, under the PITA rule book now marked as covering 2024 and 2025.
do $$
declare k uuid := tests.id('k'); a public.tax_rulebooks; b public.tax_rulebooks; strip text[] := array['meta', 'configurable_flags']; v jsonb;
begin
  perform tests.as_user(tests.id('kemi'));
  perform public.import_bank_lines(k, (public.open_bank_account(k, 'bank', 'Access', '{}')->>'id')::uuid,
    '[{"date": "2024-02-01", "amount": 10000, "description": "Sales", "reference": "K1"}]', '{"file_name": "k.csv"}');
  perform tests.as_postgres();
  update orgs set books_start = '2024-01-01' where id = k;
  assert private.pit_first_year(k) = 2024, 'pit_from_2024: the first year';
  update orgs set books_start = '2023-01-01' where id = k;
  assert private.pit_first_year(k) = 2024, 'pit_from_2024: never before 2024';
  b := private.pit_rulebook(2024);
  assert b.id = 'ng-pit-pita-legacy@1.2.0' and b.status = 'approved' and (private.pit_rulebook(2025)).id = b.id
    and (private.pit_rulebook(2026)).id = 'ng-pit-nta-2025@1.1.0', 'pit_from_2024: 2024 and 2025 on PITA, 2026 on the NTA';
  select * into a from tax_rulebooks where id = 'ng-pit-pita-legacy@1.1.0';
  assert a.status = 'retired' and b.config - strip = a.config - strip and b.config->'meta'->>'applies_to' like 'Accounts for years ending in 2024 and 2025%'
    and b.config->'configurable_flags'->'flags'->'P-1'->>'title' = 'Old law for 2024 and 2025'
    and b.config->'configurable_flags'->'flags'->'P-8'->>'reading' like '%2024 and 2025 accounts use the old initial%'
    and (b.config->'configurable_flags'->'flags') - array['P-1', 'P-8', 'P-9'] = (a.config->'configurable_flags'->'flags') - array['P-1', 'P-8', 'P-9'],
    'pit_from_2024: the same rules, relabelled';
  assert private.pit_due(k, 2024) = '2025-03-31', 'pit_from_2024: due on 31 March 2025';
  update orgs set books_start = '2024-01-01' where id = k;
  perform private.post_entry(k, 'Sales', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', (select ledger_code from bank_accounts where org_id = k limit 1), 'debit', 5000000), jsonb_build_object('code', '4101', 'credit', 5000000)),
    '2024-05-01 12:00+01');
  perform private.post_entry(k, 'Rent', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '6201', 'debit', 1000000), jsonb_build_object('code', (select ledger_code from bank_accounts where org_id = k limit 1), 'credit', 1000000)),
    '2024-06-01 12:00+01');
  perform tests.as_user(tests.id('kemi'));
  assert (select count(*) from jsonb_array_elements(public.pit_years(k)->'years') x where (x->>'year')::int = 2024) = 1, 'pit_from_2024: in the list';
  v := public.pit_year(k, 2024)->'computation';
  assert v->>'regime' = 'PITA' and v->'rulebook'->>'id' = 'ng-pit-pita-legacy@1.2.0' and (v->>'yoa')::int = 2025 and v->>'due' = '2025-03-31'
    and v->'business'->'ca'->>'regime' = 'LEGACY_CITA'
    and (select (r->>'amount')::numeric from jsonb_array_elements(v->'business'->'rows') r where r->>'id' = 'A') = 4000000, 'pit_from_2024: the 2024 computation';
  perform tests.throws(format('select public.pit_year(%L, 2023)', k), '%from 2024 accounts%');
  perform tests.as_postgres();
end $$;

-- test: filing_opening
-- Femi Motors (filing-only, incorporated 2019) has paid for 2024 and 2025. 2025 waits for 2024's approval; 2024 needs its
-- start: figures from last year's accounts (posted the day before, the assets joining the register with their depreciation,
-- the rest left as opening balances to be confirmed), replaced, then a declaration that no figures exist, which the
-- statements say. A year that began in the period, or books moved in at the start, needs nothing.
do $$
declare f uuid := tests.id('f'); s jsonb; y jsonb; j public.journals; v jsonb; v_ids uuid[];
begin
  insert into filing_orders (org_id, year, kind, status, amount, paid_at, counted) values
    (f, 2024, 'cit', 'paid', 1000, now(), 3), (f, 2025, 'cit', 'paid', 1000, now(), 3);
  insert into cit_years (org_id, accounting_year, period_from, period_to) values (f, 2024, '2024-01-01', '2024-12-31'), (f, 2025, '2025-01-01', '2025-12-31');
  assert private.filing_opening(f, 2024)->>'needed' = 'true' and private.filing_opening(f, 2024)->>'done' = 'false' and private.filing_opening(f, 2024)->>'as_of' = '2023-12-31',
    'filing_opening: 2024 needs its start';
  assert private.filing_opening(f, 2025)->>'source' = 'previous_year' and private.filing_opening(f, 2025)->>'done' = 'false', 'filing_opening: 2025 waits for 2024';
  perform tests.throws(format($q$update cit_years set status = 'approved' where org_id = %L and accounting_year = 2025$q$, f), '%Approve the 2024 return first%');
  perform tests.throws(format($q$update cit_years set status = 'approved' where org_id = %L and accounting_year = 2024$q$, f), '%Say where 2024 starts%');
  perform tests.as_user(tests.id('femi'));
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2025, '{"kind": "bank_only"}')$q$, f), '%2025 starts where 2024 ends in Counta%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "maybe"}')$q$, f), '%Say where 2024 starts%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "figures", "lines": [{"key": "cash", "amount": 1}]}')$q$, f), '%Unknown line%cash%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "figures", "lines": [{"key": "trade_payables", "amount": -5}]}')$q$, f), '%without a minus sign%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "figures", "assets": [{"class_account": "1511", "name": "Car", "cost": 10, "accumulated": 11}]}')$q$, f),
    '%between zero and its cost%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "figures", "assets": [{"class_account": "1511", "name": "Car", "cost": 10, "in_use_from": "2024-02-01"}]}')$q$, f),
    '%in use by 31 December 2023%');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "figures"}')$q$, f), '%at least one figure%');
  s := public.filing_opening_save(f, 2024, '{"kind": "figures", "lines": [{"key": "inventory", "amount": 4000000}, {"key": "trade_payables", "amount": 1500000},
    {"key": "share_capital", "amount": 1000000}, {"key": "retained_earnings", "amount": -300000}, {"key": "trade_receivables", "amount": 0}],
    "assets": [{"class_account": "1511", "name": "Showroom pickup", "cost": 6000000, "accumulated": 3000000, "in_use_from": "2021-07-01"}]}');
  perform tests.as_postgres();
  y := (select x from jsonb_array_elements(s->'years') x where (x->>'year')::int = 2024);
  assert y->'opening'->>'source' = 'figures' and (y->'opening'->>'done')::boolean and y->'opening'->>'by_name' = 'Femi Owner' and (y->'opening'->>'assets')::int = 1
    and y->'opening'->>'journal_ref' is not null and jsonb_array_length(y->'opening'->'lines') = 4
    and y->'opening'->'asset_rows' = '[{"cost": 6000000.00, "name": "Showroom pickup", "accumulated": 3000000.00, "in_use_from": "2021-07-01", "class_account": "1511"}]',
    'filing_opening: figures entered';
  select * into j from journals where org_id = f and source_type = 'opening';
  assert j.entry_date = '2023-12-31', 'filing_opening: the day before the year';
  -- Debits 4,000,000 + 6,000,000 and retained earnings 300,000; credits 1,500,000 + 1,000,000 + 3,000,000: 4,800,000 left as opening balances.
  assert pg_temp.ledger(f, '1203') = 4000000 and pg_temp.ledger(f, '2101') = -1500000 and pg_temp.ledger(f, '3001') = -1000000 and pg_temp.ledger(f, '3005') = 300000
     and pg_temp.ledger(f, '1511') = 6000000 and pg_temp.ledger(f, '1560') = -3000000 and pg_temp.ledger(f, '3999') = -4800000, 'filing_opening: the journal';
  assert (select status = 'active' and opening_accumulated = 3000000 and available_date = '2021-07-01' and depreciate_from = '2024-01-01' and journal_id = j.id
          from fixed_assets where org_id = f and name = 'Showroom pickup'), 'filing_opening: the pickup joins the register';
  -- Entered again: the first set is taken back.
  perform tests.as_user(tests.id('femi'));
  s := public.filing_opening_save(f, 2024, '{"kind": "figures", "lines": [{"key": "inventory", "amount": 3500000}]}');
  perform tests.as_postgres();
  assert pg_temp.ledger(f, '1203') = 3500000 and pg_temp.ledger(f, '1511') = 0 and pg_temp.ledger(f, '3999') = -3500000
     and (select status from fixed_assets where org_id = f and name = 'Showroom pickup') = 'rejected', 'filing_opening: replaced';
  -- No figures after all: what was entered goes, and the statements say where the year started.
  perform tests.as_user(tests.id('femi'));
  s := public.filing_opening_save(f, 2024, '{"kind": "no_figures"}');
  perform tests.as_postgres();
  assert pg_temp.ledger(f, '1203') = 0 and pg_temp.ledger(f, '3999') = 0, 'filing_opening: the figures taken back';
  y := (select x from jsonb_array_elements(s->'years') x where (x->>'year')::int = 2024);
  assert y->'opening'->>'source' = 'no_figures' and (y->'opening'->>'done')::boolean, 'filing_opening: declared';
  v := private.note_rows(f, '2024-01-01', '2024-12-31', null, null);
  assert exists (select 1 from jsonb_array_elements(v) x where x->>'line' like 'No financial statements were available for the period before 1 January 2024.%'),
    'filing_opening: the statements say so';
  assert not exists (select 1 from jsonb_array_elements(private.note_rows(f, '2025-01-01', '2025-12-31', '2024-01-01', '2024-12-31')) x
                     where x->>'line' like 'No financial statements were available%'), 'filing_opening: only the first year';
  update cit_years set status = 'approved' where org_id = f and accounting_year = 2024;
  perform tests.as_user(tests.id('femi'));
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "bank_only"}')$q$, f), '%2024 return is approved%');
  perform tests.as_postgres();
  update cit_years set status = 'approved' where org_id = f and accounting_year = 2025;
  assert (select status from cit_years where org_id = f and accounting_year = 2025) = 'approved', 'filing_opening: 2025 after 2024';
  -- A business that began in the year needs nothing; nor do books moved in at the start of the year.
  update orgs set incorporation_date = '2024-03-01' where id = f;
  assert private.filing_opening(f, 2024)->>'source' = 'began' and (private.filing_opening(f, 2024)->>'done')::boolean, 'filing_opening: began in the year';
  update orgs set incorporation_date = '2019-03-01' where id = f;
  insert into books_migrations (org_id, source, as_of, status) values (f, 'other', '2022-12-31', 'posted');
  assert private.filing_opening(f, 2023)->>'source' = 'moved', 'filing_opening: books moved in';
  -- Not on filing-only.
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2025, '{"kind": "bank_only"}')$q$, tests.id('o')), '%not on filing-only%');
  perform tests.as_postgres();
end $$;

-- test: filing_opening_depreciated
-- Figures whose assets have been depreciated are changed under Fixed assets, not replaced.
do $$
declare f uuid := tests.id('f'); s jsonb;
begin
  update cit_years set status = 'draft' where org_id = f;
  perform tests.as_user(tests.id('femi'));
  s := public.filing_opening_save(f, 2024, '{"kind": "figures", "assets": [{"class_account": "1514", "name": "Office printer", "cost": 240000, "accumulated": 0,
    "in_use_from": "2023-06-01"}]}');
  perform public.run_depreciation(f, '2024-01-31');
  perform tests.throws(format($q$select public.filing_opening_save(%L, 2024, '{"kind": "bank_only"}')$q$, f), '%Change them under Fixed assets instead%');
  perform tests.as_postgres();
end $$;

-- test: filing_state_late
-- The Filing page shows each year's start and whether its return is late.
do $$
declare f uuid := tests.id('f'); s jsonb; y jsonb;
begin
  perform tests.as_user(tests.id('femi'));
  s := public.filing_state(f);
  perform tests.as_postgres();
  y := (select x from jsonb_array_elements(s->'years') x where (x->>'year')::int = 2023);
  assert (y->>'late')::boolean and y->>'due' = '2024-06-30' and y->'opening'->>'source' = 'moved', 'filing_state: 2023 late, and its start';
  y := (select x from jsonb_array_elements(s->'years') x where (x->>'year')::int = 2025);
  assert y->>'due' = '2026-06-30' and (y->>'late')::boolean and y->'opening'->>'source' = 'previous_year', 'filing_state: 2025';
end $$;

rollback;
