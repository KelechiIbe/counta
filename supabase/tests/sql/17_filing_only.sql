-- Release 4 of the identity work (20261128000100_filing_only.sql): filing-only. A business that wants only its annual
-- income tax return is on the Annual filing package (modules like any plan), counts the year's statement lines without AI,
-- pays a one-time fee by price band (itself, or its accounting firm with the firm's card), and only then is anything read by
-- AI or shown. Scans are priced by their pages and settled after they are read. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Traders Ltd (a company, filing-only) with Bimpe (admin) and Kola (staff); the firm Head Partners
-- (partner Bisi, staff Ife) keeps its books (involved). Femi owns Femi Stores, a business name (filing-only). Gbenga owns
-- Gbenga Foods Ltd on the free default plan. TaxStreem's admin Tayo sets small price bands for the tests.
do $$
declare o uuid; f uuid; g uuid; pr uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@ada.example.test', 'Ada Owner'));
  perform tests.remember('bimpe', tests.user('bimpe.admin@ada.example.test', 'Bimpe Admin'));
  perform tests.remember('kola', tests.user('kola.staff@ada.example.test', 'Kola Staff'));
  perform tests.remember('femi', tests.user('femi.owner@femi.example.test', 'Femi Owner'));
  perform tests.remember('gbenga', tests.user('gbenga.owner@gbenga.example.test', 'Gbenga Owner'));
  perform tests.remember('bisi', tests.user('bisi.partner@head.example.test', 'Bisi Partner'));
  perform tests.remember('ife', tests.user('ife.staff@head.example.test', 'Ife Staff'));
  perform tests.remember('tayo', tests.admin_user('tayo.admin@taxstreem.example.test'));

  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Traders Ltd'));
  update orgs set legal_form = 'company', filing_only = true where id = o;
  perform tests.remember('bimpe_seat', tests.member(o, tests.id('bimpe'), 'admin'));
  perform tests.remember('kola_seat', tests.member(o, tests.id('kola'), 'staff'));
  f := tests.remember('f', tests.org(tests.id('femi'), 'Femi Stores'));
  update orgs set legal_form = 'enterprise', filing_only = true where id = f;
  g := tests.remember('g', tests.org(tests.id('gbenga'), 'Gbenga Foods Ltd'));
  update orgs set legal_form = 'company' where id = g;

  pr := tests.remember('pr', tests.practice(tests.id('bisi'), 'Head Partners', true));
  perform tests.remember('ife_pm', tests.practice_member(pr, tests.id('ife'), 'staff'));
  perform tests.remember('o_client', tests.involved_client(pr, o));

  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform public.admin_filing_prices_save('{"kind": "cit", "bands": [{"up_to": 5, "price": 1000}, {"up_to": 50, "price": 3000}, {"price": 9000}]}');
  perform public.admin_filing_prices_save('{"kind": "pit", "bands": [{"up_to": 10, "price": 500}, {"price": 800}]}');

  perform tests.as_user(tests.id('ada'));
  perform tests.remember('acct', (public.open_bank_account(o, 'bank', 'GTBank current', '{"bank_name": "GTBank", "account_number": "0123456789"}')->>'id')::uuid);
  perform tests.as_user(tests.id('femi'));
  perform tests.remember('facct', (public.open_bank_account(f, 'bank', 'Access current', '{"bank_name": "Access", "account_number": "0987654321"}')->>'id')::uuid);
  perform tests.as_postgres();
  insert into storage.buckets (id, name) values ('documents', 'documents') on conflict do nothing;
end $$;

-- Statement lines as the browser sends them after reading a statement by its columns: n lines dated in one month.
create function pg_temp.lines(p_n int, p_month date, p_start int default 1) returns jsonb language sql as $f$
  select jsonb_agg(jsonb_build_object('date', p_month + (i % 27), 'amount', case when i % 2 = 0 then 1000 + i else -(500 + i) end,
    'description', 'Line ' || (p_start + i), 'reference', 'REF' || (p_start + i)))
  from generate_series(0, p_n - 1) i
$f$;
-- A held scan as the browser stores it (storage writes the object as itself, whoever uploads).
create function pg_temp.scan(p_org uuid, p_year int, p_name text, p_size bigint default 400000, p_mime text default 'application/pdf') returns text
language plpgsql security definer as $f$
declare v text := p_org || '/filing/' || p_year || '/' || p_name;
begin
  insert into storage.objects (bucket_id, name, metadata) values ('documents', v, jsonb_build_object('size', p_size, 'mimetype', p_mime));
  return v;
end $f$;

-- test: filing_package
-- The Annual filing package: hidden, never the default, made of modules; the new area modules leave every other plan as it
-- was. A filing-only business is on it; its areas are off by the plan, AI reading stays in it.
do $$
declare o uuid := tests.id('o'); g uuid := tests.id('g'); pl public.plans; ft jsonb;
begin
  select * into pl from plans where code = 'annual-filing';
  assert pl.kind = 'filing' and not pl.public and not pl.is_default, 'filing_package: hidden, not the default';
  assert private.org_plan_id(o) = pl.id and private.org_plan_id(g) = private.default_plan_id(), 'filing_package: who is on it';
  perform tests.as_user(tests.id('ada'));
  ft := public.org_features(o);
  assert ft->>'selling' = 'false' and ft->>'purchases' = 'false' and ft->>'inventory' = 'false' and ft->>'vat_wht' = 'false' and ft->>'payments' = 'false'
     and ft->>'bank_feeds' = 'false' and ft->>'martina' = 'false', 'filing_package: areas off';
  assert (ft->'_plan'->>'selling')::boolean and (ft->'_plan'->>'vat_wht')::boolean, 'filing_package: off by the plan';
  assert ft->>'email' = 'true' and ft->>'whatsapp' = 'true', 'filing_package: Counta''s own alerts still reach the business';
  perform tests.as_user(tests.id('gbenga'));
  ft := public.org_features(g);
  assert ft->>'selling' = 'true' and ft->>'purchases' = 'true' and ft->>'inventory' = 'true' and ft->>'vat_wht' = 'true' and ft->'_plan' = '{}'::jsonb,
    'filing_package: everyone else keeps every area';
  perform tests.as_postgres();
  -- The admin portal cannot offer it as a plan nor make it the default; a database rule backs that up.
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform tests.throws(format($q$select public.admin_save_plan(jsonb_build_object('id', %L, 'code', 'annual-filing', 'name', 'Annual filing', 'public', true))$q$, pl.id),
    '%not offered as a plan%');
  perform public.admin_save_plan(jsonb_build_object('id', pl.id, 'code', 'annual-filing', 'name', 'Annual filing', 'public', false, 'active', true,
    'entitlements', '[{"module": "martina", "included": true}]'::jsonb));
  assert (select included from plan_entitlements where plan_id = pl.id and module_key = 'martina'), 'filing_package: TaxStreem edits its modules';
  perform public.admin_save_plan(jsonb_build_object('id', pl.id, 'code', 'annual-filing', 'name', 'Annual filing', 'public', false, 'active', true,
    'entitlements', '[{"module": "martina", "included": false, "enforce": "block"}]'::jsonb));
  perform tests.as_postgres();
  perform tests.throws($q$update plans set public = true where code = 'annual-filing'$q$, '%plans_filing_hidden%');
end $$;

-- test: filing_ai_hold
-- Before any year is paid for, no AI: AI reading is off, the bookkeeper's queue leaves the business out, gives it no lines and
-- asks nothing about them, however long they wait.
do $$
declare o uuid := tests.id('o'); r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  r := public.import_bank_lines(o, tests.id('acct'), pg_temp.lines(4, '2025-03-01'), '{"file_name": "march.csv", "source": "csv"}');
  assert (r->>'added')::int = 4, 'filing_ai_hold: lines in';
  perform tests.as_postgres();
  update bank_lines set created_at = now() - interval '2 hours' where org_id = tests.id('o');
  assert private.filing_hold(o) and private.feature_on(o, 'ai_reading') = false, 'filing_ai_hold: AI reading off';
  assert not (public.svc_orgs_with_lines() @> to_jsonb(o)), 'filing_ai_hold: not in the bookkeeper''s queue';
  assert jsonb_array_length(public.svc_lines_for_ai(o)->'lines') = 0, 'filing_ai_hold: no lines for AI';
  assert public.svc_suspend_rest(o) = 0 and (select count(*) from bank_lines where org_id = o and status = 'unmatched') = 4, 'filing_ai_hold: nothing asked';
  -- Gbenga's lines go to the bookkeeper as always.
  perform tests.as_user(tests.id('gbenga'));
  perform public.import_bank_lines(tests.id('g'), (public.open_bank_account(tests.id('g'), 'bank', 'UBA', '{}')->>'id')::uuid, pg_temp.lines(2, '2025-03-01'),
    '{"file_name": "g.csv"}');
  perform tests.as_postgres();
  assert public.svc_orgs_with_lines() @> to_jsonb(tests.id('g')) and private.feature_on(tests.id('g'), 'ai_reading'), 'filing_ai_hold: others unchanged';
end $$;

-- test: filing_quote
-- The Filing page: the years that can be filed, the year's lines counted without AI, scans held at 35 lines a page, and the
-- band and fee. A business name files PIT at the PIT prices; an exempt body has nothing to file.
do $$
declare o uuid := tests.id('o'); f uuid := tests.id('f'); s jsonb; y jsonb; v_scan text;
begin
  perform tests.as_user(tests.id('ada'));
  s := public.filing_state(o);
  assert s->>'kind' = 'cit' and (s->>'filing_only')::boolean and (s->>'hold')::boolean and (s->>'can_pay')::boolean and (s->>'can_upload')::boolean,
    'filing_quote: the page';
  assert (select array_agg((x->>'year')::int) from jsonb_array_elements(s->'years') x) = array[2025, 2024, 2023], 'filing_quote: the years (CIT from 2023)';
  y := s->'years'->0;
  assert (y->>'lines')::int = 4 and (y->>'counted')::int = 4 and (y->>'band_up_to')::int = 5 and (y->>'price')::numeric = 1000 and y->'order' = 'null'::jsonb,
    'filing_quote: four lines, the first band';
  assert y->>'due' = '2026-06-30' and y->>'from' = '2025-01-01' and y->>'to' = '2025-12-31', 'filing_quote: the period and due date';
  assert jsonb_array_length(y->'statements') = 1 and y->'statements'->0->>'file_name' = 'march.csv', 'filing_quote: the statement';
  assert jsonb_array_length(s->'accounts') = 1 and s->'accounts'->0->>'last4' = '6789', 'filing_quote: the bank accounts';

  -- A scan held for the year: the order is opened first.
  v_scan := pg_temp.scan(o, 2025, 'scan-1.pdf');
  perform tests.throws(format($q$select public.filing_scan_hold(%L, jsonb_build_object('year', 2025, 'path', %L, 'pages', 1, 'bank_account_id', %L))$q$,
    o, v_scan, tests.id('acct')), '%Choose the year on the Filing page first%');
  s := public.filing_open(o, 2025);
  s := public.filing_scan_hold(o, jsonb_build_object('year', 2025, 'path', v_scan, 'pages', 1, 'bank_account_id', tests.id('acct'), 'file_name', 'May scan.pdf'));
  y := s->'years'->0;
  assert (y->>'scan_pages')::int = 1 and (y->>'estimate')::int = 35 and (y->>'counted')::int = 39 and (y->>'band_up_to')::int = 50 and (y->>'price')::numeric = 3000,
    'filing_quote: 35 lines a scanned page, the next band';
  assert y->'scans'->0->>'status' = 'held' and y->'scans'->0->>'file_name' = 'May scan.pdf' and y->'order'->>'status' = 'open', 'filing_quote: the scan held';
  -- Taken off, it no longer counts; held again.
  s := public.filing_scan_remove(o, (y->'scans'->0->>'id')::uuid);
  assert (s->'years'->0->>'counted')::int = 4, 'filing_quote: a scan taken off';
  perform public.filing_scan_hold(o, jsonb_build_object('year', 2025, 'path', pg_temp.scan(o, 2025, 'scan-2.pdf'), 'pages', 1, 'bank_account_id', tests.id('acct')));
  perform tests.as_user(tests.id('femi'));
  s := public.filing_state(f);
  assert s->>'kind' = 'pit' and (select array_agg((x->>'year')::int) from jsonb_array_elements(s->'years') x) = array[2025, 2024], 'filing_quote: PIT from 2024';
  perform public.import_bank_lines(f, tests.id('facct'), pg_temp.lines(12, '2025-06-01'), '{"file_name": "june.csv"}');
  y := public.filing_state(f)->'years'->0;
  assert y->>'kind' = 'pit' and (y->>'counted')::int = 12 and y->'band_up_to' = 'null'::jsonb and (y->>'price')::numeric = 800 and y->>'due' = '2026-03-31',
    'filing_quote: the PIT band above all';
  perform tests.as_postgres();
end $$;

-- test: filing_refused
-- Only someone who keeps the books uploads, only into the business's own filing folder, a PDF of a size Counta takes, for one
-- of its accounts; only a filing-only business opens a year it can file; exempt bodies file nothing.
do $$
declare o uuid := tests.id('o'); q text := 'select public.filing_scan_hold(%L, %L::jsonb)';
begin
  perform tests.as_user(tests.id('kola'));
  perform tests.throws(format('select public.filing_open(%L, 2025)', o), '42501: Your role does not allow this (keep books).');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', tests.id('g') || '/filing/2025/x.pdf', 'pages', 2, 'bank_account_id', tests.id('acct'))),
    '%not uploaded where expected%');
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', o || '/filing/2025/missing.pdf', 'pages', 2, 'bank_account_id', tests.id('acct'))),
    '%was not found%');
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', pg_temp.scan(o, 2025, 'big.pdf', 30 * 1048576), 'pages', 2, 'bank_account_id', tests.id('acct'))),
    '%up to 25 MB%');
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', pg_temp.scan(o, 2025, 'photo.pdf', 1000, 'image/png'), 'pages', 2,
    'bank_account_id', tests.id('acct'))), '%must be a PDF%');
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', pg_temp.scan(o, 2025, 'p0.pdf'), 'pages', 0, 'bank_account_id', tests.id('acct'))),
    '%1 to 500 pages%');
  perform tests.throws(format(q, o, jsonb_build_object('year', 2025, 'path', pg_temp.scan(o, 2025, 'acct.pdf'), 'pages', 1, 'bank_account_id', tests.id('facct'))),
    '%Choose the bank account%');
  perform tests.throws(format('select public.filing_open(%L, 2019)', o), '%Choose one of the years%');
  perform tests.as_user(tests.id('gbenga'));
  perform tests.throws(format('select public.filing_open(%L, 2025)', tests.id('g')), '%not on filing-only%');
  perform tests.as_postgres();
  update orgs set legal_form = 'ngo' where id = o;
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.filing_open(%L, 2024)', o), '%exempt from income tax%');
  perform tests.as_postgres();
  update orgs set legal_form = 'company' where id = o;
end $$;

-- test: filing_kind_changes
-- A year opened as a company's and paid after the business turned out to be a business name is charged at the personal
-- income tax prices, and a year that is exempt has nothing to pay.
do $$
declare v_u uuid; v_o uuid; v_a uuid; r jsonb;
begin
  v_u := tests.user('nkem.owner@nkem.example.test', 'Nkem Owner');
  v_o := tests.org(v_u, 'Nkem Ventures');
  update orgs set legal_form = 'company', filing_only = true where id = v_o;
  perform tests.as_user(v_u);
  v_a := (public.open_bank_account(v_o, 'bank', 'Zenith', '{}')->>'id')::uuid;
  perform public.import_bank_lines(v_o, v_a, pg_temp.lines(3, '2025-02-01'), '{"file_name": "feb.csv"}');
  perform public.filing_open(v_o, 2025);
  perform tests.as_postgres();
  assert (select kind from filing_orders where org_id = v_o and year = 2025) = 'cit', 'filing_kind_changes: opened as CIT';
  update orgs set legal_form = 'enterprise' where id = v_o;
  perform tests.as_user(v_u);
  r := public.filing_pay_start(v_o, 2025);
  assert (r->>'amount')::numeric = 500, 'filing_kind_changes: PIT prices';
  perform tests.as_postgres();
  assert (select kind from filing_orders where org_id = v_o and year = 2025) = 'pit', 'filing_kind_changes: the year is now PIT';
  update orgs set legal_form = 'ngo' where id = v_o;
  perform tests.as_user(v_u);
  perform tests.throws(format('select public.filing_pay_start(%L, 2025)', v_o), '%exempt from income tax for 2025%');
  perform tests.as_postgres();
end $$;

-- test: filing_hidden
-- Nothing is shown before payment: the year's return, its file and the financial statements answer that the year is not paid for.
do $$
declare o uuid := tests.id('o'); f uuid := tests.id('f'); r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  r := public.cit_year(o, 2025);
  assert (r->>'locked')::boolean and r->>'message' like 'Pay the filing fee for 2025%' and not (r ? 'computation'), 'filing_hidden: the return';
  assert (public.cit_pack(o, 2025)->>'locked')::boolean, 'filing_hidden: its file';
  assert (public.financial_statements_pack(o, '2025-01-01', '2025-12-31')->>'locked')::boolean, 'filing_hidden: the financial statements';
  assert (select bool_and((x->>'locked')::boolean and not (x->>'has_data')::boolean and x->'payable' = 'null'::jsonb and x->'total_tax' = 'null'::jsonb)
          from jsonb_array_elements(public.cit_years(o)->'years') x), 'filing_hidden: no figures in the list of years';
  perform tests.as_user(tests.id('femi'));
  assert (public.pit_year(f, 2025)->>'locked')::boolean and (public.pit_pack(f, 2025)->>'locked')::boolean, 'filing_hidden: the PIT return';
  assert (select bool_and((x->>'locked')::boolean and x->'tax' = 'null'::jsonb and x->'assessable' = 'null'::jsonb and (x->>'blocks')::int = 0)
          from jsonb_array_elements(public.pit_years(f)->'years') x), 'filing_hidden: no PIT figures in the list';
  -- Not to someone outside the business.
  perform tests.as_user(tests.id('gbenga'));
  perform tests.throws(format('select public.cit_year(%L, 2025)', o), '42501: You are not a member of this business.');
  -- Everyone else as before.
  assert not (public.cit_year(tests.id('g'), 2025) ? 'locked'), 'filing_hidden: others unchanged';
  perform tests.as_postgres();
end $$;

-- test: filing_pay
-- The owner pays for a year by card: the charge carries what was quoted, the same choice within half an hour reuses it, and
-- the payment records the year as paid. Then AI reads that year's lines only, and the year is shown; other years wait.
do $$
declare o uuid := tests.id('o'); r jsonb; r2 jsonb; c public.subscription_charges; fo public.filing_orders; ctx jsonb; v_old uuid;
begin
  perform tests.as_user(tests.id('kola'));
  perform tests.throws(format('select public.filing_pay_start(%L, 2025)', o), '42501: Your role does not allow this (manage settings).');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.filing_pay_start(%L, 2024)', o), '%Choose the year on the Filing page first%');
  perform public.filing_open(o, 2024);
  perform tests.throws(format('select public.filing_pay_start(%L, 2024)', o), '%Add the year''s bank statements first%');
  -- A line of 2024 waits; it is not part of 2025's count.
  perform public.import_bank_lines(o, tests.id('acct'), pg_temp.lines(1, '2024-11-01', 100), '{"file_name": "nov24.csv"}');
  r := public.filing_pay_start(o, 2025);
  assert r->>'action' = 'checkout' and (r->>'amount')::numeric = 3000 and r->>'tx_ref' ~ '^SUB-[0-9A-F]{16}$', 'filing_pay: a checkout for the band';
  r2 := public.filing_pay_start(o, 2025);
  assert r2->>'charge_id' = r->>'charge_id', 'filing_pay: the same charge again within half an hour';
  perform tests.as_postgres();
  select * into c from subscription_charges where id = (r->>'charge_id')::uuid;
  assert c.kind = 'filing' and c.billing = 'year' and c.plan_id = private.filing_plan_id() and c.filing_order_id is not null
     and (c.filing_quote->'quote'->>'counted')::int = 39 and (c.filing_quote->'quote'->>'lines')::int = 4, 'filing_pay: what was quoted is kept';
  perform tests.as_service();
  ctx := public.svc_subscription_charge(c.id);
  assert ctx->>'return_path' = '/filing' and ctx->>'description' = 'Companies income tax return for Ada Traders Ltd, 2025 accounts'
     and ctx->>'narration' = 'Counta annual filing 2025' and not (ctx->'charge' ? 'filing_quote'), 'filing_pay: Flutterwave''s page says what it is for';
  -- More lines before paying: a new charge for the new amount, the old one cancelled.
  perform tests.as_user(tests.id('ada'));
  perform public.import_bank_lines(o, tests.id('acct'), pg_temp.lines(20, '2025-04-01', 200), '{"file_name": "april.csv"}');
  r2 := public.filing_pay_start(o, 2025);
  perform tests.as_postgres();
  assert (r2->>'amount')::numeric = 9000 and r2->>'charge_id' <> r->>'charge_id'
     and (select status from subscription_charges where id = (r->>'charge_id')::uuid) = 'cancelled', 'filing_pay: a new count, a new charge';
  -- Flutterwave confirms the payment (with the card, kept for next year).
  perform tests.as_service();
  r := public.svc_subscription_charge_update(r2->>'tx_ref', '{"status": "successful", "amount": 9000, "currency": "NGN", "provider_ref": "flw-1",
    "card": {"token": "flw-t-ada", "last4": "4242", "brand": "VISA", "expiry": "09/29", "email": "ada.owner@ada.example.test"}}');
  assert r->>'status' = 'successful' and (r->>'year')::int = 2025, 'filing_pay: paid';
  perform tests.as_postgres();
  select * into fo from filing_orders where org_id = o and year = 2025;
  assert fo.status = 'paid' and fo.amount = 9000 and fo.lines = 24 and fo.scan_pages = 1 and fo.estimate = 35 and fo.counted = 59 and fo.band_up_to is null
     and fo.payer = 'business' and fo.charge_id = (r2->>'charge_id')::uuid and fo.true_count = 59 and fo.extra_due = 0, 'filing_pay: what was counted and paid';
  assert (select count(*) from subscription_cards where org_id = o and token = 'flw-t-ada') = 1, 'filing_pay: the card kept';
  assert not exists (select 1 from subscriptions where org_id = o) and private.org_plan_id(o) = private.filing_plan_id(), 'filing_pay: no plan was bought';
  assert (select count(*) from notifications where org_id = o and kind = 'books' and title = 'Filing 2025 paid: the books are being prepared') = 3,
    'filing_pay: Ada, Bimpe and the firm''s partner told';
  -- AI for 2025 only.
  assert not private.filing_hold(o) and private.feature_on(o, 'ai_reading') and public.svc_orgs_with_lines() @> to_jsonb(o), 'filing_pay: AI on';
  assert (select bool_and(extract(year from (x->>'date')::date) = 2025) and count(*) = 24 from jsonb_array_elements(public.svc_lines_for_ai(o, 100)->'lines') x),
    'filing_pay: the year''s lines, not 2024''s';
  update bank_lines set created_at = now() - interval '2 hours' where org_id = o;
  assert public.svc_suspend_rest(o) = 24 and exists (select 1 from bank_lines where org_id = o and status = 'unmatched' and line_date = '2024-11-01'),
    'filing_pay: 2024''s line waits, unasked';
  perform tests.as_user(tests.id('ada'));
  assert not (public.cit_year(o, 2025) ? 'locked') and (public.cit_year(o, 2024)->>'locked')::boolean, 'filing_pay: 2025 shown, 2024 not';
  assert (select not (x->>'locked')::boolean from jsonb_array_elements(public.cit_years(o)->'years') x where (x->>'year')::int = 2025)
     and (select (x->>'locked')::boolean from jsonb_array_elements(public.cit_years(o)->'years') x where (x->>'year')::int = 2026), 'filing_pay: the list too';
  assert not (public.financial_statements_pack(o, '2025-01-01', '2025-12-31') ? 'locked'), 'filing_pay: the statements shown';
  perform tests.throws(format('select public.filing_pay_start(%L, 2025)', o), '%2025 is paid for%');
  perform tests.throws(format($q$select public.filing_scan_hold(%L, jsonb_build_object('year', 2025, 'path', %L, 'pages', 1, 'bank_account_id', %L))$q$,
    o, pg_temp.scan(o, 2025, 'late.pdf'), tests.id('acct')), '%is paid for: upload the statement again%');
  perform tests.as_postgres();
end $$;

-- test: filing_scans_settled
-- The held scan is read after payment. Its real lines, in place of its estimate, put the year in a dearer band: the
-- difference is owed and the return cannot be approved until it is paid. Statements added after payment cost nothing.
do $$
declare o uuid := tests.id('o'); s public.filing_scans; imp uuid; fo public.filing_orders; r jsonb; c public.subscription_charges;
begin
  -- Prices go up after payment; the year was paid at the old ones and the difference uses the bands as they are now.
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform public.admin_filing_prices_save('{"kind": "cit", "bands": [{"up_to": 5, "price": 1000}, {"up_to": 50, "price": 3000}, {"up_to": 100, "price": 9000}, {"price": 15000}]}');
  perform tests.as_postgres();
  select * into s from filing_scans where org_id = o and status = 'held';
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.filing_scan_done(%L, %L, %L)', o, s.id, gen_random_uuid()), '%lines were not found%');
  imp := (public.import_bank_lines(o, tests.id('acct'), pg_temp.lines(80, '2025-05-01', 400), '{"file_name": "May scan.pdf", "source": "pdf", "read_by": "ai"}')->>'import_id')::uuid;
  r := public.filing_scan_done(o, s.id, imp);
  perform tests.as_postgres();
  select * into fo from filing_orders where org_id = o and year = 2025;
  assert fo.true_count = 104 and fo.extra_due = 6000, 'filing_scans_settled: 24 lines and 80 from the scan, a dearer band';
  assert (select status = 'read' and lines_found = 80 and import_id = imp from filing_scans where id = s.id), 'filing_scans_settled: the scan read';
  assert r->'years'->0->'order'->>'extra_due' = '6000.00', 'filing_scans_settled: the Filing page shows what is owed';
  assert (select count(*) from notifications where org_id = o and title = 'Filing 2025: ₦6,000.00 to pay') = 2, 'filing_scans_settled: Ada and Bimpe told';
  -- Read twice: nothing changes.
  perform tests.as_user(tests.id('ada'));
  perform public.filing_scan_done(o, s.id, imp);
  perform tests.as_postgres();
  assert (select extra_due from filing_orders where id = fo.id) = 6000, 'filing_scans_settled: once';
  -- The return waits for the difference.
  insert into cit_years (org_id, accounting_year, period_from, period_to) values (o, 2025, '2025-01-01', '2025-12-31') on conflict do nothing;
  perform tests.throws(format($q$update cit_years set status = 'approved' where org_id = %L and accounting_year = 2025$q$, o), '%Pay the difference of ₦6,000.00%');
  insert into cit_years (org_id, accounting_year, period_from, period_to) values (o, 2024, '2024-01-01', '2024-12-31') on conflict do nothing;
  perform tests.throws(format($q$update cit_years set status = 'approved' where org_id = %L and accounting_year = 2024$q$, o), '%Pay the filing fee for 2024%');
  -- The difference paid by the saved card.
  perform tests.as_user(tests.id('ada'));
  r := public.filing_pay_start(o, 2025);
  assert r->>'action' = 'charge_card' and (r->>'amount')::numeric = 6000, 'filing_pay: the difference on the saved card';
  perform tests.as_service();
  assert public.svc_subscription_charge((r->>'charge_id')::uuid)->>'description' like '% (the balance)', 'filing_scans_settled: called the balance';
  perform public.svc_subscription_charge_update(r->>'tx_ref', '{"status": "successful", "amount": 6000, "currency": "NGN"}');
  perform tests.as_postgres();
  select * into fo from filing_orders where id = fo.id;
  assert fo.extra_due = 0 and fo.extra_paid = 6000 and fo.extra_paid_at is not null and fo.amount = 9000, 'filing_scans_settled: settled';
  -- 2024 is not done in Counta, so 2025 needs its start (release 5).
  perform tests.throws(format($q$update cit_years set status = 'approved' where org_id = %L and accounting_year = 2025$q$, o), '%Say where 2025 starts%');
  perform tests.as_user(tests.id('ada'));
  perform public.filing_opening_save(o, 2025, '{"kind": "bank_only"}');
  perform tests.as_postgres();
  update cit_years set status = 'approved' where org_id = o and accounting_year = 2025;
  assert (select status from cit_years where org_id = o and accounting_year = 2025) = 'approved', 'filing_scans_settled: the return can be approved';
  update cit_years set status = 'draft' where org_id = o and accounting_year = 2025;
  -- A statement after payment: read at no charge.
  perform tests.as_user(tests.id('ada'));
  perform public.import_bank_lines(o, tests.id('acct'), pg_temp.lines(30, '2025-09-01', 900), '{"file_name": "sept.csv"}');
  perform tests.as_postgres();
  select * into fo from filing_orders where id = fo.id;
  assert fo.extra_due = 0 and fo.true_count = 104, 'filing_scans_settled: later statements cost nothing';
  perform tests.as_postgres();
end $$;

-- test: filing_firm_pays
-- A partner of the firm that works for the business pays with the firm's card; the firm's staff and other firms cannot.
do $$
declare f uuid := tests.id('f'); r jsonb; fo public.filing_orders; pr uuid := tests.id('pr');
begin
  -- Femi's business works with the firm too.
  perform tests.remember('f_client', tests.involved_client(pr, f));
  perform tests.as_user(tests.id('ife'));
  perform tests.throws(format('select public.practice_filing_pay_start(%L, 2025)', f), '%Only a partner or manager of a firm%');
  perform tests.as_user(tests.id('bisi'));
  assert public.filing_state(f)->'practice'->>'name' = 'Head Partners', 'filing_firm_pays: the Filing page offers the firm''s card';
  perform tests.throws(format('select public.practice_filing_pay_start(%L, 2025)', f), '%Choose the year on the Filing page first%');
  perform public.filing_open(f, 2025);
  r := public.practice_filing_pay_start(f, 2025);
  assert r->>'action' = 'checkout' and (r->>'amount')::numeric = 800, 'filing_firm_pays: the firm''s checkout';
  perform tests.as_service();
  assert public.svc_subscription_charge((r->>'charge_id')::uuid)->'payer'->>'name' = 'Head Partners'
     and public.svc_subscription_charge((r->>'charge_id')::uuid)->>'description' = 'Personal income tax return for Femi Stores, 2025 accounts',
    'filing_firm_pays: on the firm''s name';
  perform public.svc_subscription_charge_update(r->>'tx_ref', '{"status": "successful", "amount": 800, "currency": "NGN",
    "card": {"token": "flw-t-head", "last4": "1111", "brand": "MASTERCARD", "expiry": "01/30", "email": "office@head.example.test"}}');
  select * into fo from filing_orders where org_id = f and year = 2025;
  assert fo.status = 'paid' and fo.payer = 'practice' and fo.practice_id = pr, 'filing_firm_pays: paid by the firm';
  assert (select count(*) from subscription_cards where practice_id = pr and token = 'flw-t-head' and org_id is null) = 1, 'filing_firm_pays: the firm''s card kept';
  assert exists (select 1 from notifications n join practice_members pm on pm.user_id = n.user_id where pm.practice_id = pr and n.title = 'Filing 2025 paid for Femi Stores'),
    'filing_firm_pays: the firm told';
  -- The practice can check its own payment; the owner's own page shows who paid.
  perform tests.as_user(tests.id('bisi'));
  assert (public.practice_charge_check(r->>'tx_ref')->>'status') = 'successful', 'filing_firm_pays: the firm checks it';
  perform tests.as_user(tests.id('femi'));
  assert public.filing_state(f)->'years'->0->'order'->>'practice' = 'Head Partners', 'filing_firm_pays: the business sees who paid';
  perform tests.as_postgres();
end $$;

-- test: filing_start_and_end
-- An owner on the free plan switches to filing-only; one paying for a plan cannot until it ends; only the owner or an admin.
-- Choosing any plan ends filing-only; the years paid for stay paid. Annual filing is never chosen as a plan.
do $$
declare g uuid := tests.id('g'); o uuid := tests.id('o'); pl uuid; s jsonb; v_filing uuid := private.filing_plan_id(); v_free uuid := private.default_plan_id();
begin
  perform tests.as_user(tests.id('gbenga'));
  s := public.subscription_state(g);
  assert (s->>'can_file_only')::boolean and not (s->>'filing_only')::boolean
     and not exists (select 1 from jsonb_array_elements(s->'plans') x where x->>'kind' = 'filing'), 'filing_start_and_end: the choice offered';
  s := public.filing_start(g);
  assert (s->>'filing_only')::boolean and (s->>'hold')::boolean and s->>'kind' = 'cit', 'filing_start_and_end: filing-only, nothing read yet';
  assert public.subscription_state(g)->'plan'->>'code' = 'annual-filing' and not (public.subscription_state(g)->>'can_file_only')::boolean,
    'filing_start_and_end: Subscription shows the package';
  perform tests.throws(format($q$select public.subscription_start(%L, jsonb_build_object('plan_id', %L, 'billing', 'month', 'method', 'card'))$q$, g, v_filing),
    '%paid year by year on the Filing page%');
  -- Nor can TaxStreem put a business on it as a plan.
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform tests.throws(format($q$select public.admin_set_org_plan(%L, jsonb_build_object('plan_id', %L, 'comp', true))$q$, g, v_filing),
    '%Annual filing is not set as a plan%');
  perform tests.as_user(tests.id('gbenga'));
  -- Choosing the free plan ends it; Ada's paid year stays paid when she moves too.
  s := public.subscription_start(g, jsonb_build_object('plan_id', v_free, 'billing', 'month'));
  perform tests.as_postgres();
  assert not (select filing_only from orgs where id = g) and private.org_plan_id(g) = v_free, 'filing_start_and_end: a plan ends it';
  -- A business paying for a plan cannot switch until the plan ends.
  insert into plans (code, name, price_month) values ('growth-test', 'Growth', 75000) returning id into pl;
  update subscriptions set plan_id = pl, status = 'active', current_period_end = now() + interval '20 days' where org_id = g;
  perform tests.as_user(tests.id('gbenga'));
  perform tests.throws(format('select public.filing_start(%L)', g), '%on the Growth plan. Stop renewing it%');
  perform tests.as_user(tests.id('kola'));
  perform tests.throws(format('select public.filing_start(%L)', o), '42501: Your role does not allow this (manage settings).');
  perform tests.as_postgres();
  update orgs set filing_only = false where id = o;
  assert (select status from filing_orders where org_id = o and year = 2025) = 'paid' and not private.filing_unpaid(o, 2024), 'filing_start_and_end: paid years kept';
  update orgs set filing_only = true where id = o;
end $$;

-- test: filing_sign_up
-- At sign-up a business can be set up for filing only; a firm can set one up so under full mandate.
do $$
declare r jsonb; v_uid uuid; pr uuid := tests.id('pr'); i uuid; v_ans jsonb := '{"offering": "goods", "category": "food", "revenue_band": "0_50m",
  "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["flour"], "filing": {"vat": "never", "wht": "never", "cit": "always"}}';
begin
  v_uid := tests.remember('hauwa', tests.user('hauwa.owner@hauwa.example.test', 'Hauwa Owner'));
  perform tests.as_service();
  perform public.svc_kyc_store(v_uid, 'search', '{"query":"hauwa"}');
  perform public.svc_kyc_store(v_uid, 'cac', '{"cac_id": 77, "profile": {"approved_name": "HAUWA CONSULTING LIMITED", "rc_number": "7700077", "classification": "COMPANY",
    "directors": [{"firstname": "HAUWA", "surname": "OWNER"}]}}');
  perform tests.as_user(v_uid);
  perform public.kyc_answer(v_ans);
  r := public.kyc_submit('{"filing_only": true}');
  perform tests.as_postgres();
  assert (select filing_only from orgs where id = (r->>'org_id')::uuid), 'filing_sign_up: set up for filing only';
  -- Under full mandate, by the firm.
  i := tests.cleared_intake(pr, 'Kano Grains Ltd', 'full', 'RC 9900001');
  perform tests.as_user(tests.id('bisi'));
  perform public.practice_intake_declare(i, '{}');
  perform tests.as_postgres();
  perform tests.completed_letter(i);
  perform tests.as_user(tests.id('bisi'));
  r := public.practice_create_business(i, '{"email": "books@kano.example.test", "filing_only": true}');
  perform tests.as_postgres();
  assert (r->>'ok')::boolean and (select filing_only and managed_by = pr from orgs where id = (r->>'org_id')::uuid), 'filing_sign_up: by the firm';
end $$;

-- test: filing_firm_switch
-- A firm switches a business it runs under full mandate to filing-only from the portal (a partner or manager; not while
-- it pays for a plan); a business the firm only works with is switched by its owner. The portal shows which clients are
-- filing-only.
do $$
declare pr uuid := tests.id('pr'); m uuid; v_client uuid; v_inv uuid; b jsonb; pl uuid;
begin
  m := tests.managed_org(pr, 'Kaduna Oil Ltd');
  select id into v_client from practice_clients where org_id = m and practice_id = pr;
  select id into v_inv from practice_clients where org_id = tests.id('o') and practice_id = pr;
  perform tests.as_user(tests.id('ife'));
  perform tests.throws(format('select public.practice_filing_start(%L)', v_client), '%Only partners and managers%');
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.practice_filing_start(%L)', v_inv), '%owner switches it to filing-only%');
  -- While the firm pays for a plan, not yet.
  perform tests.as_postgres();
  insert into plans (code, name, price_month) values ('firm-growth-test', 'Firm Growth', 50000) returning id into pl;
  insert into subscriptions (org_id, plan_id, status, billing, current_period_end, paid_by) values (m, pl, 'active', 'month', now() + interval '10 days', pr);
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.practice_filing_start(%L)', v_client), '%on the Firm Growth plan. Stop paying for it%');
  perform tests.as_postgres();
  delete from subscriptions where org_id = m;
  perform tests.as_user(tests.id('bisi'));
  assert (public.practice_filing_start(v_client)->>'filing_only')::boolean, 'filing_firm_switch: switched';
  b := public.practice_billing(pr);
  assert exists (select 1 from jsonb_array_elements(b->'clients') x where x->>'org_id' = m::text and (x->>'filing_only')::boolean and (x->>'managed')::boolean
      and x->'plan'->>'name' = 'Annual filing'), 'filing_firm_switch: the portal shows it';
  assert exists (select 1 from jsonb_array_elements(b->'clients') x where x->>'org_id' = tests.id('o')::text and not (x->>'managed')::boolean),
    'filing_firm_switch: a client the firm works with is not run by it';
  -- The firm pays for it from the Filing page; the business has no owner to pay.
  assert public.filing_state(m)->'practice'->>'name' = 'Head Partners' and not (public.filing_state(m)->>'can_pay')::boolean, 'filing_firm_switch: the firm pays';
  perform tests.as_postgres();
  assert (select filing_only from orgs where id = m), 'filing_firm_switch: filing-only';
end $$;

-- test: filing_vat
-- A filing-only business whose sales pass ₦100 million: VAT is turned on as the law requires, and the people told are pointed
-- to a plan for the monthly VAT returns.
do $$
declare v_hb uuid; o2 uuid; cu uuid;
begin
  v_hb := tests.remember('habib', tests.user('habib.owner@habib.example.test', 'Habib Owner'));
  o2 := tests.org(v_hb, 'Habib Imports Ltd');
  update orgs set legal_form = 'company', vat_registered = false, vat_opt_in = false where id = o2;
  perform tests.as_user(v_hb);
  cu := public.save_customer(o2, '{"name": "Big Buyer", "email": "buyer@example.test"}');
  perform public.save_sale_doc(o2, jsonb_build_object('customer_id', cu, 'status', 'issue',
    'lines', '[{"description": "Big contract", "qty": 1, "unit_price": 150000000, "vat_treatment": "exempt"}]'::jsonb));
  perform tests.as_postgres();
  update orgs set filing_only = true where id = o2;
  perform private.vat_threshold_tick();
  assert (select vat_registered from orgs where id = o2), 'filing_vat: on';
  assert exists (select 1 from messages where org_id = o2 and template = 'alert' and channel = 'email' and params->>'link' like '%/settings/subscription'
      and params::text like '%Filing-only covers the annual income tax return%'), 'filing_vat: pointed to a plan';
end $$;

-- test: filing_admin
-- TaxStreem sets the bands (rising, ending with one with no upper limit, prices above zero) and sees what was paid.
do $$
declare a jsonb;
begin
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform tests.throws($q$select public.admin_filing_prices_save('{"kind": "vat", "bands": [{"price": 1}]}')$q$, '%Choose companies income tax or personal income tax%');
  perform tests.throws($q$select public.admin_filing_prices_save('{"kind": "cit", "bands": [{"up_to": 10, "price": 1}]}')$q$, '%no upper limit%');
  perform tests.throws($q$select public.admin_filing_prices_save('{"kind": "cit", "bands": [{"up_to": 10, "price": 1}, {"up_to": 5, "price": 2}, {"price": 3}]}')$q$,
    '%higher than the one before%');
  perform tests.throws($q$select public.admin_filing_prices_save('{"kind": "cit", "bands": [{"price": 3}, {"up_to": 5, "price": 2}]}')$q$, '%comes last%');
  perform tests.throws($q$select public.admin_filing_prices_save('{"kind": "cit", "bands": [{"up_to": 5, "price": 0}, {"price": 3}]}')$q$, '%price above zero%');
  a := public.admin_filing();
  assert jsonb_array_length(a->'prices') = 6 and (a->>'businesses')::int >= 3, 'filing_admin: the bands and businesses';
  assert (a->>'collected_total')::numeric = 9000 + 6000 + 800, 'filing_admin: what was collected';
  assert exists (select 1 from jsonb_array_elements(a->'orders') x where x->>'business' = 'Ada Traders Ltd' and x->>'year' = '2025' and x->>'extra_paid' = '6000.00'),
    'filing_admin: the orders';
  perform tests.as_user(tests.id('ada'));
  perform tests.throws('select public.admin_filing()', '42501%');
  perform tests.as_postgres();
end $$;

rollback;
