-- WHT credits (20261201000100_wht_credits.sql): the credits customers deducted (account 1401) are set against companies
-- income tax and personal income tax once, and an approved PIT return moves the credit it uses out of 1401. Only fake
-- people (example.test addresses).
begin;

-- Fixture. Companies: Wale Logistics Ltd (two years filed together, then 2024 paid late with Rev360 applying less credit),
-- Femi Motors Ltd (2024 paid on time), Gbenga Foods Ltd (2024 paid with no credit applied). Business names: Tobi Stores (sole
-- trader), Kola Stores (sole trader whose 1401 was corrected after the year end). Partnership: Ade and Bisi Ventures, 60/40.
do $$
declare o uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('wale', tests.user('wale.owner@logistics.example.test', 'Wale Owner'));
  perform tests.remember('femi', tests.user('femi.owner@motors.example.test', 'Femi Owner'));
  perform tests.remember('gbenga', tests.user('gbenga.owner@foods.example.test', 'Gbenga Owner'));
  perform tests.remember('tobi', tests.user('tobi.owner@stores.example.test', 'Tobi Owner'));
  perform tests.remember('kola', tests.user('kola.owner@stores.example.test', 'Kola Owner'));
  perform tests.remember('ade', tests.user('ade.partner@ventures.example.test', 'Ade Partner'));
  foreach o in array array[tests.remember('w', tests.org(tests.id('wale'), 'Wale Logistics Ltd')), tests.remember('f', tests.org(tests.id('femi'), 'Femi Motors Ltd')),
                           tests.remember('g', tests.org(tests.id('gbenga'), 'Gbenga Foods Ltd'))] loop
    update orgs set legal_form = 'company', category_id = 'logistics', offering = 'services', incorporation_date = '2015-01-01', books_start = '2024-01-01' where id = o;
  end loop;
  foreach o in array array[tests.remember('t', tests.org(tests.id('tobi'), 'Tobi Stores')), tests.remember('k', tests.org(tests.id('kola'), 'Kola Stores'))] loop
    update orgs set legal_form = 'enterprise', commenced_on = '2023-06-01', books_start = '2024-01-01' where id = o;
  end loop;
  o := tests.remember('p', tests.org(tests.id('ade'), 'Ade and Bisi Ventures'));
  update orgs set legal_form = 'partnership', commenced_on = '2023-06-01', books_start = '2024-01-01' where id = o;
  update locations set state = 'Lagos' where org_id in (tests.id('t'), tests.id('k'), tests.id('p'));
  insert into pit_people (org_id, name, source) values (tests.id('t'), 'Tobi Owner', 'added'), (tests.id('k'), 'Kola Owner', 'added'),
    (tests.id('p'), 'Ade Partner', 'added'), (tests.id('p'), 'Bisi Partner', 'added');
  -- What a return needs before approval: where each person lived, the mixed-use review and the statement of accounts.
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, accommodation)
  select pp.org_id, y, pp.id, case when pp.name like 'Ade%' then 60 when pp.name like 'Bisi%' then 40 else 100 end, case when pp.org_id = tests.id('p') then 'active' else 'proprietor' end,
    '{"address": "1 Test Street, Ikeja", "type": "flat", "occupancy": "owner", "started_on": "2020-01-01"}'::jsonb
  from pit_people pp cross join (values (2024), (2025)) v(y) where pp.org_id in (tests.id('t'), tests.id('k'), tests.id('p'));
  insert into pit_years (org_id, accounting_year, soa_path, settings) values (tests.id('t'), 2024, 'pit/soa-2024.pdf', '{"mixed_use_reviewed": true}'),
    (tests.id('t'), 2025, 'pit/soa-2025.pdf', '{"mixed_use_reviewed": true}'), (tests.id('k'), 2024, 'pit/soa-2024.pdf', '{"mixed_use_reviewed": true}'),
    (tests.id('p'), 2024, 'pit/soa-2024.pdf', '{"mixed_use_reviewed": true}');
  perform tests.as_postgres();
end $$;

-- A year's trade: sales (part of it kept back by customers as WHT) and rent.
create function pg_temp.trade(p_org uuid, p_year int, p_sales numeric, p_wht numeric, p_rent numeric) returns void language plpgsql as $f$
begin
  perform private.post_entry(p_org, 'Sales ' || p_year, 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1011', 'debit', p_sales - p_wht), jsonb_build_object('code', '4101', 'credit', p_sales))
    || case when p_wht > 0 then jsonb_build_array(jsonb_build_object('code', '1401', 'debit', p_wht)) else '[]'::jsonb end,
    make_timestamptz(p_year, 5, 1, 12, 0, 0, 'Africa/Lagos'));
  perform private.post_entry(p_org, 'Rent ' || p_year, 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '6201', 'debit', p_rent), jsonb_build_object('code', '1011', 'credit', p_rent)), make_timestamptz(p_year, 6, 1, 12, 0, 0, 'Africa/Lagos'));
end $f$;
-- A CIT payment through Rev360, recorded as the payments function records it.
create function pg_temp.pay_cit(p_org uuid, p_owner uuid, p_year int, p_amount numeric, p_credit numeric, p_at timestamptz) returns public.journals language sql as $f$
  select private.post_tax_paid(p_org, 'cit', null, null, p_year, p_amount, null, '1011', 0, 'CIT-' || p_year, (select id from members where org_id = p_org and user_id = p_owner),
    gen_random_uuid(), null, p_at, 'Companies income tax ' || p_year, 'NRS',
    jsonb_build_object('penalty', 0, 'interest', 0, 'late_filing_penalty', 0, 'charges', 0, 'credit_applied', p_credit))
$f$;
create function pg_temp.ledger(p_org uuid, p_code text) returns numeric language sql as $f$
  select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = p_code
$f$;
create function pg_temp.fig(p_comp jsonb, p_key text) returns numeric language sql as $f$
  select coalesce((p_comp->'figures'->>p_key)::numeric, 0)
$f$;

-- test: pit_2024_saves
-- A 2024 return can be saved (Release 5 opened it; its tables took years from 2025 only).
do $$
declare r jsonb;
begin
  perform tests.as_user(tests.id('tobi'));
  r := public.save_pit_year(tests.id('t'), 2024, '{"notes": "First return on Counta"}'::jsonb);
  perform tests.as_postgres();
  assert (select settings->>'notes' from pit_years where org_id = tests.id('t') and accounting_year = 2024) = 'First return on Counta', 'pit_2024_saves: saved';
  perform tests.throws(format('insert into pit_years (org_id, accounting_year) values (%L, 2023)', tests.id('k')), '%pit_years_accounting_year_check%');
end $$;

-- test: wht_cit_filed_together
-- Wale kept back ₦5m of WHT in 2024 and none in 2025. Both years are computed before any tax is paid: 2024 uses the ₦5m,
-- and 2025, whose year end still holds it in 1401, does not use it again. The years list agrees.
do $$
declare w uuid := tests.id('w'); r24 jsonb; r25 jsonb; c jsonb;
begin
  perform pg_temp.trade(w, 2024, 200000000, 5000000, 100000000);
  perform pg_temp.trade(w, 2025, 200000000, 0, 100000000);
  r24 := private.cit_run(w, 2024); r25 := private.cit_run(w, 2025);
  assert pg_temp.fig(r24, 'wht_held') = 5000000 and pg_temp.fig(r24, 'wht_pending') = 0 and pg_temp.fig(r24, 'wht_credit') = 5000000, 'wht_cit_filed_together: 2024 uses it';
  assert pg_temp.fig(r25, 'wht_held') = 5000000 and pg_temp.fig(r25, 'wht_pending') = 5000000 and pg_temp.fig(r25, 'wht_credit') = 0
    and pg_temp.fig(r25, 'payable') = pg_temp.fig(r25, 'total_tax'), 'wht_cit_filed_together: 2025 does not use it again';
  assert (select x->>'basis' from jsonb_array_elements(r25->'rows') x where x->>'id' = 'W') like '%held, of which %5,000,000% is already set against earlier years'' tax; set against companies income tax only',
    'wht_cit_filed_together: the computation says why';
  c := (select x from jsonb_array_elements(private.cit_chain(w, 2025)) x where (x->>'year')::int = 2025);
  assert pg_temp.fig(c, 'wht_credit') = 0 and pg_temp.fig(c, 'wht_pending') = 5000000, 'wht_cit_filed_together: the years list agrees';
  -- New WHT in 2025 is used in 2025.
  perform private.post_entry(w, 'WHT 2025', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1401', 'debit', 2000000), jsonb_build_object('code', '1011', 'credit', 2000000)), '2025-08-01 12:00+01');
  r25 := private.cit_run(w, 2025);
  assert pg_temp.fig(r25, 'wht_held') = 7000000 and pg_temp.fig(r25, 'wht_pending') = 5000000 and pg_temp.fig(r25, 'wht_credit') = 2000000,
    'wht_cit_filed_together: only the new credit';
end $$;

-- test: wht_cit_paid_late
-- Wale pays 2024 in November 2026 and Rev360 applies ₦4m of the ₦5m. The payment clears ₦4m from 1401, tagged with its year.
-- 2025 still holds the ₦4m at its year end and does not use it; the ₦1m Rev360 left is used, with the ₦2m deducted in 2025.
-- 2026: 2024's credit has left the books, 2025's ₦3m is still held for its unpaid tax, and 2026's own ₦1m is used.
do $$
declare w uuid := tests.id('w'); j public.journals; r25 jsonb; r26 jsonb;
begin
  j := pg_temp.pay_cit(w, tests.id('wale'), 2024, 23000000, 4000000, '2026-11-14 12:00+01');
  assert (select count(*) from journal_lines where journal_id = j.id and split_part(account_code, '-', 1) = '1401' and credit = 4000000 and doc_type = 'cit_wht:2024') = 1,
    'wht_cit_paid_late: the cleared credit names its year';
  assert pg_temp.ledger(w, '1401') = 3000000, 'wht_cit_paid_late: 1401 after the payment';
  r25 := private.cit_run(w, 2025);
  assert pg_temp.fig(r25, 'wht_held') = 7000000 and pg_temp.fig(r25, 'wht_pending') = 4000000 and pg_temp.fig(r25, 'wht_credit') = 3000000,
    'wht_cit_paid_late: 2025 uses what Rev360 left and its own';
  perform pg_temp.trade(w, 2026, 200000000, 1000000, 100000000);
  r26 := private.cit_run(w, 2026);
  assert pg_temp.fig(r26, 'wht_held') = 4000000 and pg_temp.fig(r26, 'wht_pending') = 3000000 and pg_temp.fig(r26, 'wht_credit') = 1000000,
    'wht_cit_paid_late: 2026';
  -- A chain of one year (the year opens the chain) sees nothing pending, as before.
  assert pg_temp.fig(private.cit_compute(w, 2025), 'wht_pending') = 0, 'wht_cit_paid_late: no chain, nothing pending';
end $$;

-- test: wht_cit_paid_on_time
-- Femi pays 2024 in June 2025 with the whole ₦5m applied: by 2025's year end it has left 1401, and 2025 uses only its own ₦1m.
-- Gbenga pays 2024 with no credit applied: the ₦3m stayed in 1401 unused, so 2025 may use it.
do $$
declare f uuid := tests.id('f'); g uuid := tests.id('g'); r jsonb;
begin
  insert into cit_years (org_id, accounting_year, period_from, period_to) values (f, 2024, '2024-01-01', '2024-12-31'), (g, 2024, '2024-01-01', '2024-12-31');
  perform pg_temp.trade(f, 2024, 200000000, 5000000, 100000000);
  perform pg_temp.trade(f, 2025, 200000000, 1000000, 100000000);
  perform pg_temp.pay_cit(f, tests.id('femi'), 2024, 23000000, 5000000, '2025-06-30 12:00+01');
  assert (select tax_paid_at is not null from cit_years where org_id = f and accounting_year = 2024), 'wht_cit_paid_on_time: recorded as paid';
  r := private.cit_run(f, 2025);
  assert pg_temp.fig(r, 'wht_held') = 1000000 and pg_temp.fig(r, 'wht_pending') = 0 and pg_temp.fig(r, 'wht_credit') = 1000000, 'wht_cit_paid_on_time: 2025 uses its own';
  assert (select x->>'basis' from jsonb_array_elements(r->'rows') x where x->>'id' = 'W') not like '%earlier years%', 'wht_cit_paid_on_time: nothing to explain';
  perform pg_temp.trade(g, 2024, 200000000, 3000000, 100000000);
  perform pg_temp.trade(g, 2025, 200000000, 0, 100000000);
  perform pg_temp.pay_cit(g, tests.id('gbenga'), 2024, 30000000, 0, '2026-11-14 12:00+01');
  r := private.cit_run(g, 2025);
  assert pg_temp.fig(r, 'wht_held') = 3000000 and pg_temp.fig(r, 'wht_pending') = 0 and pg_temp.fig(r, 'wht_credit') = 3000000,
    'wht_cit_paid_on_time: credit Rev360 did not apply stays available';
end $$;

-- test: wht_cit_bf
-- What the chain hands a year: last year's carry-forward with the credits, or (after a year without figures) the credits
-- alone, which open the year like a first year. Credits for the year itself or later are ignored, and so are odd keys.
do $$
declare w uuid := tests.id('w'); r jsonb; r0 jsonb;
begin
  assert private.cit_bf(null, '{}'::jsonb) is null and private.cit_bf('{"losses": 1}'::jsonb, null) = '{"losses": 1}'::jsonb
    and private.cit_bf(null, '{"2024": 5}'::jsonb) = '{"wht_years": {"2024": 5}}'::jsonb
    and private.cit_bf('{"losses": 1, "ca": 2}'::jsonb, '{"2024": 5}'::jsonb) = '{"losses": 1, "ca": 2, "wht_years": {"2024": 5}}'::jsonb, 'wht_cit_bf: cit_bf';
  assert private.cit_wht_note('{}'::jsonb, '{"year": 2024, "figures": {"wht_credit": 5000000}}'::jsonb) = '{"2024": 5000000}'::jsonb
    and private.cit_wht_note('{"2023": 1}'::jsonb, '{"year": 2024, "figures": {"wht_credit": 0}}'::jsonb) = '{"2023": 1}'::jsonb, 'wht_cit_bf: cit_wht_note';
  r0 := private.cit_compute(w, 2025, null);
  r := private.cit_compute(w, 2025, '{"wht_years": {"2024": 1000000, "2025": 9, "2031": 9, "x": 9}}'::jsonb);
  assert r->'bf' = r0->'bf' and pg_temp.fig(r, 'assessable') = pg_temp.fig(r0, 'assessable'), 'wht_cit_bf: credits alone open the year like a first year';
  -- 2024 has a recorded payment, so it counts as what the payment cleared (₦4m), which 1401 still held at 2025's year end.
  assert pg_temp.fig(r, 'wht_pending') = 4000000, 'wht_cit_bf: a recorded payment counts what it cleared';
  assert private.cit_wht_pending(w, 2025, '2025-12-31', '{"2025": 1, "2026": 1}'::jsonb) = 0
    and private.cit_wht_pending(w, 2025, '2025-12-31', '"x"'::jsonb) = 0 and private.cit_wht_pending(w, 2025, '2025-12-31', null) = 0, 'wht_cit_bf: nothing else counts';
end $$;

-- test: wht_cit_imported
-- A year prepared from imported statements keeps the WHT figure in those statements.
do $$
declare f uuid := tests.id('f'); r jsonb;
begin
  insert into cit_years (org_id, accounting_year, period_from, period_to, source, imported)
  values (f, 2023, '2023-01-01', '2023-12-31', 'imported', '{"STATEMENT_OF_FINANCIAL_POSITION!D51": {"amount": 750000}, "INCOME_STATEMENT!D9": {"amount": 10000000}}'::jsonb);
  r := private.cit_compute(f, 2023, '{"wht_years": {"2022": 5000000}}'::jsonb);
  assert r->>'source' = 'imported' and pg_temp.fig(r, 'wht_held') = 750000 and pg_temp.fig(r, 'wht_pending') = 0, 'wht_cit_imported: the statements'' figure';
end $$;

-- test: wht_pit_sole
-- Tobi's 2024 return uses the ₦1m kept back in 2024: approving it moves the ₦1m to retained earnings (the owner's drawings)
-- with no name in the ledger. 2025, whose year end still holds that ₦1m, uses only its own ₦500,000, and approving 2025
-- clears that too. Reopening 2025 puts it back; approving again moves it again. Approvals post today, so the year they
-- reach is the running year: every year up to it has trade, and only the running year keeps back more WHT (₦200,000).
do $$
declare t uuid := tests.id('t'); v jsonb; j public.journals; r jsonb; v_now int := extract(year from now())::int; y int;
begin
  perform pg_temp.trade(t, 2024, 30000000, 1000000, 10000000);
  perform pg_temp.trade(t, 2025, 30000000, 500000, 10000000);
  v := private.pit_run(t, 2024);
  assert pg_temp.fig(v, 'wht_credit_used') = 1000000 and pg_temp.fig(v, 'wht_pending') = 0, 'wht_pit_sole: 2024 uses ₦1m';
  perform tests.as_user(tests.id('tobi'));
  r := public.approve_pit_year(t, 2024, '{"attest": true}'::jsonb);
  perform tests.as_postgres();
  select * into j from journals where id = (select (settings->>'wht_journal_id')::uuid from pit_years where org_id = t and accounting_year = 2024);
  assert j.source_type = 'pit_year' and j.memo = 'WHT credit notes used against the 2024 income tax', 'wht_pit_sole: the journal';
  assert (select count(*) from journal_lines where journal_id = j.id) = 2
    and (select debit from journal_lines where journal_id = j.id and account_code = '3005') = 1000000
    and (select memo from journal_lines where journal_id = j.id and account_code = '3005') = 'WHT credit set against the owner''s 2024 income tax'
    and (select credit from journal_lines where journal_id = j.id and split_part(account_code, '-', 1) = '1401' and doc_type = 'pit_wht:2024') = 1000000,
    'wht_pit_sole: Dr retained earnings, Cr 1401';
  assert not exists (select 1 from journal_lines where journal_id = j.id and memo like '%Tobi%'), 'wht_pit_sole: no name in the ledger';
  assert pg_temp.ledger(t, '1401') = 500000, 'wht_pit_sole: 1401 after approving 2024';
  v := private.pit_run(t, 2025);
  assert pg_temp.fig(v, 'wht_held') = 1500000 and pg_temp.fig(v, 'wht_pending') = 1000000 and pg_temp.fig(v, 'wht_available') = 500000
    and pg_temp.fig(v, 'wht_credit_used') = 500000, 'wht_pit_sole: 2025 uses its own';
  perform tests.as_user(tests.id('tobi'));
  r := public.approve_pit_year(t, 2025, '{"attest": true}'::jsonb);
  perform tests.as_postgres();
  assert pg_temp.ledger(t, '1401') = 0 and pg_temp.ledger(t, '3005') = 1500000, 'wht_pit_sole: both years cleared';
  -- The running year: both credits have left the books; only its own ₦200,000 is there.
  for y in 2026 .. v_now loop perform pg_temp.trade(t, y, 30000000, case when y = v_now then 200000 else 0 end, 10000000); end loop;
  v := private.pit_run(t, v_now);
  assert pg_temp.fig(v, 'wht_held') = 200000 and pg_temp.fig(v, 'wht_pending') = 0 and pg_temp.fig(v, 'wht_available') = 200000, 'wht_pit_sole: the running year';
  -- Reopening 2025 reverses its journal; the computations come out the same.
  perform tests.as_user(tests.id('tobi'));
  r := public.reopen_pit_year(t, 2025, 'Wrong rent figure');
  perform tests.as_postgres();
  assert (select not (settings ? 'wht_journal_id') and settings->'reopened'->>'reason' = 'Wrong rent figure' from pit_years where org_id = t and accounting_year = 2025),
    'wht_pit_sole: the journal is forgotten';
  assert exists (select 1 from journals where reversal_of = (select id from journals where org_id = t and memo = 'WHT credit notes used against the 2025 income tax'))
    and pg_temp.ledger(t, '1401') = 700000, 'wht_pit_sole: reversed';
  v := private.pit_run(t, 2025);
  assert pg_temp.fig(v, 'wht_pending') = 1000000 and pg_temp.fig(v, 'wht_credit_used') = 500000, 'wht_pit_sole: 2025 again';
  v := private.pit_run(t, v_now);
  assert pg_temp.fig(v, 'wht_held') = 700000 and pg_temp.fig(v, 'wht_pending') = 500000 and pg_temp.fig(v, 'wht_available') = 200000, 'wht_pit_sole: the running year again';
  perform tests.as_user(tests.id('tobi'));
  r := public.approve_pit_year(t, 2025, '{"attest": true}'::jsonb);
  perform tests.as_postgres();
  assert pg_temp.ledger(t, '1401') = 200000 and (select settings ? 'wht_journal_id' from pit_years where org_id = t and accounting_year = 2025), 'wht_pit_sole: approved again';
end $$;

-- test: wht_pit_partners
-- Ade and Bisi share 60/40: the ₦2m credit is split the same way, one line for each share, with no names.
do $$
declare p uuid := tests.id('p'); v jsonb; r jsonb; j uuid;
begin
  perform pg_temp.trade(p, 2024, 50000000, 2000000, 10000000);
  v := private.pit_run(p, 2024);
  assert v->>'kind' = 'partnership' and pg_temp.fig(v, 'wht_credit_used') = 2000000, 'wht_pit_partners: ₦2m used';
  perform tests.as_user(tests.id('ade'));
  r := public.approve_pit_year(p, 2024, '{"attest": true}'::jsonb);
  perform tests.as_postgres();
  j := (select (settings->>'wht_journal_id')::uuid from pit_years where org_id = p and accounting_year = 2024);
  assert (select array_agg(debit order by debit desc) from journal_lines where journal_id = j and account_code = '3005') = array[1200000.00, 800000.00]::numeric[]
    and (select array_agg(memo order by debit desc) from journal_lines where journal_id = j and account_code = '3005')
      = array['WHT credit set against a partner''s 2024 income tax (60% share)', 'WHT credit set against a partner''s 2024 income tax (40% share)'],
    'wht_pit_partners: one line for each share';
  assert pg_temp.ledger(p, '1401') = 0 and not exists (select 1 from journal_lines where journal_id = j and (memo like '%Ade%' or memo like '%Bisi%')),
    'wht_pit_partners: cleared, no names';
end $$;

-- test: wht_pit_capped
-- Kola's ₦1m of 2024 WHT was partly corrected out of 1401 after the year end (₦600,000): approving moves only the ₦400,000 left.
-- Figures from imported statements post nothing.
do $$
declare k uuid := tests.id('k'); r jsonb; j uuid; m public.members;
begin
  perform pg_temp.trade(k, 2024, 30000000, 1000000, 10000000);
  perform private.post_entry(k, 'WHT corrected', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1011', 'debit', 600000), jsonb_build_object('code', '1401', 'credit', 600000)), '2025-03-01 12:00+01');
  assert pg_temp.fig(private.pit_run(k, 2024), 'wht_credit_used') = 1000000, 'wht_pit_capped: 2024 uses its year-end ₦1m';
  perform tests.as_user(tests.id('kola'));
  r := public.approve_pit_year(k, 2024, '{"attest": true}'::jsonb);
  perform tests.as_postgres();
  j := (select (settings->>'wht_journal_id')::uuid from pit_years where org_id = k and accounting_year = 2024);
  assert (select credit from journal_lines where journal_id = j and split_part(account_code, '-', 1) = '1401') = 400000
    and (select sum(debit) from journal_lines where journal_id = j and account_code = '3005') = 400000 and pg_temp.ledger(k, '1401') = 0, 'wht_pit_capped: no more than 1401 holds';
  select * into m from members where org_id = k and user_id = tests.id('kola');
  assert private.pit_wht_post(k, 2024, '{"kind": "sole", "business": {"source": "imported"}, "figures": {"wht_credit_used": 100}}'::jsonb, m) is null
    and private.pit_wht_post(k, 2024, '{"kind": "sole", "business": {"source": "books"}, "figures": {"wht_credit_used": 0}}'::jsonb, m) is null
    and private.pit_wht_post(k, 2024, '{"kind": "sole", "business": {"source": "books"}, "figures": {"wht_credit_used": 100}}'::jsonb, m) is null,
    'wht_pit_capped: nothing to move';
end $$;

-- test: wht_grants
do $$
begin
  perform tests.as_user(tests.id('wale'));
  perform tests.throws(format('select private.wht_cleared(%L, %L, 2025, %L)', tests.id('w'), 'cit', '2025-12-31'), '%permission denied%');
  perform tests.throws(format('select private.cit_wht_pending(%L, 2025, %L, null)', tests.id('w'), '2025-12-31'), '%permission denied%');
  perform tests.throws('select private.cit_bf(null, null)', '%permission denied%');
  perform tests.as_postgres();
end $$;

rollback;
