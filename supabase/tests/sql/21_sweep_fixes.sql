-- Sweep fixes (20261202000100_sweep_fixes.sql): a practice outlives the deletion of its own business, empty books balance,
-- WHT credits used by returns filed or paid outside Counta leave 1401, an audit fee's webhook asks the audits function, and
-- the advisors' search paths and indexes. Only fake people (example.test addresses).
begin;

-- Fixture. Okoro & Co: an accountant practice billing from its own business, Okoro & Co (the firm business). Ngozi Bakery:
-- a business the practice referred, with a commission on it. Tunde Stores (sole trader) and Ife and Uche Ventures (60/40
-- partnership) for PIT; Sade Haulage Ltd for CIT. Empty Shelf Ltd has no entries at all.
do $$
declare o uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('okoro', tests.user('okoro.partner@okoroco.example.test', 'Okoro Partner'));
  perform tests.remember('ngozi', tests.user('ngozi.owner@bakery.example.test', 'Ngozi Owner'));
  perform tests.remember('tunde', tests.user('tunde.owner@stores.example.test', 'Tunde Owner'));
  perform tests.remember('ife', tests.user('ife.partner@ventures.example.test', 'Ife Partner'));
  perform tests.remember('sade', tests.user('sade.owner@haulage.example.test', 'Sade Owner'));
  perform tests.remember('empty', tests.user('empty.owner@shelf.example.test', 'Empty Owner'));
  perform tests.remember('admin', tests.admin_user('sweep.admin@example.test'));
  perform tests.remember('pr', tests.practice(tests.id('okoro'), 'Okoro & Co Chartered Accountants'));
  perform tests.remember('firm', tests.org(tests.id('okoro'), 'Okoro & Co'));
  update practices set firm_org_id = tests.id('firm') where id = tests.id('pr');
  perform tests.remember('bakery', tests.org(tests.id('ngozi'), 'Ngozi Bakery'));
  insert into partner_commissions (practice_id, org_id, kind, base, rate, amount, status, available_at)
  values (tests.id('pr'), tests.id('bakery'), 'commission', 100000, 0.2, 20000, 'pending', now() + interval '20 days');
  o := tests.remember('t', tests.org(tests.id('tunde'), 'Tunde Stores'));
  update orgs set legal_form = 'enterprise', commenced_on = '2023-06-01', books_start = '2024-01-01' where id = o;
  o := tests.remember('p', tests.org(tests.id('ife'), 'Ife and Uche Ventures'));
  update orgs set legal_form = 'partnership', commenced_on = '2023-06-01', books_start = '2024-01-01' where id = o;
  update locations set state = 'Lagos' where org_id in (tests.id('t'), tests.id('p'));
  insert into pit_people (org_id, name, source) values (tests.id('t'), 'Tunde Owner', 'added'), (tests.id('p'), 'Ife Partner', 'added'), (tests.id('p'), 'Uche Partner', 'added');
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, accommodation)
  select pp.org_id, y, pp.id, case when pp.name like 'Ife%' then 60 when pp.name like 'Uche%' then 40 else 100 end,
    case when pp.org_id = tests.id('p') then 'active' else 'proprietor' end,
    '{"address": "1 Test Street, Ikeja", "type": "flat", "occupancy": "owner", "started_on": "2020-01-01"}'::jsonb
  from pit_people pp cross join (values (2024), (2025)) v(y) where pp.org_id in (tests.id('t'), tests.id('p'));
  o := tests.remember('s', tests.org(tests.id('sade'), 'Sade Haulage Ltd'));
  update orgs set legal_form = 'company', category_id = 'logistics', offering = 'services', incorporation_date = '2015-01-01', books_start = '2024-01-01' where id = o;
  perform tests.remember('e', tests.org(tests.id('empty'), 'Empty Shelf Ltd'));
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
create function pg_temp.ledger(p_org uuid, p_code text) returns numeric language sql as $f$
  select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = p_code
$f$;
create function pg_temp.fig(p_comp jsonb, p_key text) returns numeric language sql as $f$
  select coalesce((p_comp->'figures'->>p_key)::numeric, 0)
$f$;
create function pg_temp.cleared(p_org uuid, p_tag text) returns numeric language sql as $f$
  select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401' and doc_type = p_tag
$f$;

-- test: delete_keeps_firm_practice
-- Deleting Okoro & Co (the firm business) keeps the practice, unlinked, and the partner's login; the preview names the
-- practice. Deleting Ngozi Bakery keeps the commission the practice earned on it, unlinked.
do $$
declare v jsonb;
begin
  perform tests.as_user(tests.id('admin'), 'aal2');
  v := public.admin_business_delete_preview(tests.id('firm'));
  perform tests.as_postgres();
  assert v->'practices' = jsonb_build_array(jsonb_build_object('id', tests.id('pr'), 'name', 'Okoro & Co Chartered Accountants')), 'delete_keeps_firm_practice: preview';
  assert (select p->>'login' from jsonb_array_elements(v->'people') p where p->>'user_id' = tests.id('okoro')::text) = 'kept', 'delete_keeps_firm_practice: login kept';
  perform tests.as_user(tests.id('admin'), 'aal2');
  perform public.admin_business_delete(tests.id('firm'), 'Okoro & Co');
  perform public.admin_business_delete(tests.id('bakery'), 'Ngozi Bakery');
  perform tests.as_postgres();
  assert not exists (select 1 from orgs where id in (tests.id('firm'), tests.id('bakery'))), 'delete_keeps_firm_practice: both businesses gone';
  assert (select firm_org_id is null and name = 'Okoro & Co Chartered Accountants' from practices where id = tests.id('pr')), 'delete_keeps_firm_practice: practice stays, unlinked';
  assert exists (select 1 from practice_members where practice_id = tests.id('pr') and user_id = tests.id('okoro') and status = 'active'), 'delete_keeps_firm_practice: partner stays';
  assert (select org_id is null and amount = 20000 and status = 'pending' from partner_commissions where practice_id = tests.id('pr')), 'delete_keeps_firm_practice: commission stays';
  -- Rows of the business's own still go (usage and support history).
  assert not exists (select 1 from usage_events where org_id in (tests.id('firm'), tests.id('bakery'))), 'delete_keeps_firm_practice: own rows gone';
end $$;

-- test: trial_balance_empty
-- Books with no entries: the trial balance totals 0 and balances.
do $$
declare v jsonb;
begin
  perform tests.as_user(tests.id('empty'));
  v := public.accounting_report(tests.id('e'), 'trial_balance', '2026-01-01', '2026-06-30');
  perform tests.as_postgres();
  assert (v->'extra'->>'total_dr')::numeric = 0 and (v->'extra'->>'total_cr')::numeric = 0 and (v->'extra'->>'balances')::boolean, 'trial_balance_empty: balances';
  assert jsonb_array_length(coalesce(v->'rows', '[]'::jsonb)) = 0, 'trial_balance_empty: no rows';
end $$;

-- test: pit_outside_default
-- Tunde marks 2024 as filed outside Counta without giving a credit: Counta's ₦1m moves out of 1401 on the date filed, tagged
-- with the year, one line for the owner. 2025 counts it as used. Undoing the mark reverses it.
do $$
declare t uuid := tests.id('t'); v jsonb; j public.journals;
begin
  perform pg_temp.trade(t, 2024, 30000000, 1000000, 10000000);
  perform pg_temp.trade(t, 2025, 30000000, 500000, 10000000);
  assert pg_temp.fig(private.pit_run(t, 2024), 'wht_credit_used') = 1000000, 'pit_outside_default: Counta''s figure';
  perform tests.as_user(tests.id('tunde'));
  v := public.mark_pit_filed(t, 2024, '{"outside": true, "note": "Filed with LIRS by our accountant", "filed_on": "2025-06-30"}'::jsonb);
  perform tests.as_postgres();
  select * into j from journals where id = (select (settings->>'wht_journal_id')::uuid from pit_years where org_id = t and accounting_year = 2024);
  assert j.entry_date = '2025-06-30' and j.memo = 'WHT credit notes used against the 2024 income tax (filed outside Counta)', 'pit_outside_default: the journal';
  assert (select debit from journal_lines where journal_id = j.id and account_code = '3005') = 1000000
    and (select memo from journal_lines where journal_id = j.id and account_code = '3005') = 'WHT credit set against the owner''s 2024 income tax'
    and pg_temp.cleared(t, 'pit_wht:2024') = 1000000 and pg_temp.ledger(t, '1401') = 500000, 'pit_outside_default: Dr retained earnings, Cr 1401';
  assert (select status = 'filed_outside' and (settings->'filed_outside'->>'wht_credit')::numeric = 1000000 and (settings->'filed_outside'->>'computed')::numeric = 1000000
    and settings->'filed_outside'->>'note' = 'Filed with LIRS by our accountant' from pit_years where org_id = t and accounting_year = 2024), 'pit_outside_default: recorded';
  v := private.pit_run(t, 2025);
  assert pg_temp.fig(v, 'wht_held') = 500000 and pg_temp.fig(v, 'wht_pending') = 0 and pg_temp.fig(v, 'wht_credit_used') = 500000, 'pit_outside_default: 2025 uses its own';
  perform tests.as_user(tests.id('tunde'));
  v := public.mark_pit_filed(t, 2024, '{"outside": false}'::jsonb);
  perform tests.as_postgres();
  assert exists (select 1 from journals where reversal_of = j.id) and pg_temp.ledger(t, '1401') = 1500000 and pg_temp.cleared(t, 'pit_wht:2024') = 0, 'pit_outside_default: undone';
  assert (select status = 'draft' and not (settings ? 'filed_outside') and not (settings ? 'wht_journal_id') from pit_years where org_id = t and accounting_year = 2024),
    'pit_outside_default: back to draft';
end $$;

-- test: pit_outside_given
-- Tunde's return claimed only ₦400,000. That much leaves 1401 (dated today), and 2025 counts ₦400,000 as used, so the other
-- ₦600,000 of 2024's credit stays available to it. A credit given as 0 moves nothing and leaves the whole credit available.
-- More than 1401 holds, or something that is not an amount, is refused.
do $$
declare t uuid := tests.id('t'); v jsonb;
begin
  perform tests.as_user(tests.id('tunde'));
  perform tests.throws(format($q$select public.mark_pit_filed(%L, 2024, '{"outside": true, "wht_credit": "5000000"}'::jsonb)$q$, t),
    '%Account 1401 holds NGN 1,500,000.00 of WHT credit notes. Enter at most that.');
  perform tests.throws(format($q$select public.mark_pit_filed(%L, 2024, '{"outside": true, "wht_credit": "about half"}'::jsonb)$q$, t), '%Enter the WHT credit as an amount, or 0.');
  perform tests.throws(format($q$select public.mark_pit_filed(%L, 2024, '{"outside": true, "wht_credit": "-5"}'::jsonb)$q$, t), '%Enter the WHT credit as an amount, or 0.');
  v := public.mark_pit_filed(t, 2024, '{"outside": true, "wht_credit": "400,000"}'::jsonb);
  perform tests.as_postgres();
  assert pg_temp.cleared(t, 'pit_wht:2024') = 400000 and pg_temp.ledger(t, '1401') = 1100000, 'pit_outside_given: ₦400,000 moved';
  v := private.pit_run(t, 2025);
  assert pg_temp.fig(v, 'wht_held') = 1500000 and pg_temp.fig(v, 'wht_pending') = 400000 and pg_temp.fig(v, 'wht_available') = 1100000,
    'pit_outside_given: 2025 sees ₦600,000 of 2024''s credit still free';
  perform tests.as_user(tests.id('tunde'));
  v := public.mark_pit_filed(t, 2024, '{"outside": false}'::jsonb);
  v := public.mark_pit_filed(t, 2024, '{"outside": true, "wht_credit": 0}'::jsonb);
  perform tests.as_postgres();
  assert pg_temp.cleared(t, 'pit_wht:2024') = 0 and pg_temp.ledger(t, '1401') = 1500000
    and (select not (settings ? 'wht_journal_id') and (settings->'filed_outside'->>'wht_credit')::numeric = 0 from pit_years where org_id = t and accounting_year = 2024),
    'pit_outside_given: nothing moved for 0';
  v := private.pit_run(t, 2025);
  assert pg_temp.fig(v, 'wht_pending') = 0 and pg_temp.fig(v, 'wht_available') = 1500000, 'pit_outside_given: all of it free for 2025';
end $$;

-- test: pit_outside_partners
-- Ife and Uche (60/40) filed 2024 outside Counta claiming ₦1m of the ₦2m Counta worked out: one line for each share.
do $$
declare p uuid := tests.id('p'); v jsonb; j uuid;
begin
  perform pg_temp.trade(p, 2024, 50000000, 2000000, 10000000);
  perform tests.as_user(tests.id('ife'));
  v := public.mark_pit_filed(p, 2024, '{"outside": true, "wht_credit": 1000000}'::jsonb);
  perform tests.as_postgres();
  j := (select (settings->>'wht_journal_id')::uuid from pit_years where org_id = p and accounting_year = 2024);
  assert (select array_agg(debit order by debit desc) from journal_lines where journal_id = j and account_code = '3005') = array[600000.00, 400000.00]::numeric[]
    and (select array_agg(memo order by debit desc) from journal_lines where journal_id = j and account_code = '3005')
      = array['WHT credit set against a partner''s 2024 income tax (60% share)', 'WHT credit set against a partner''s 2024 income tax (40% share)'],
    'pit_outside_partners: one line for each share';
  assert pg_temp.ledger(p, '1401') = 1000000 and not exists (select 1 from journal_lines where journal_id = j and (memo like '%Ife%' or memo like '%Uche%')),
    'pit_outside_partners: ₦1m moved, no names';
end $$;

-- test: cit_outside
-- Sade Haulage kept back ₦5m of WHT in 2024 and provided ₦3m of CIT in the books. Recorded as paid outside Counta with
-- Counta's figure: Dr 2208 ₦3m, Dr 7501 ₦2m for what the books did not provide, Cr 1401 ₦5m tagged with the year, on the
-- date paid. The year shows it; 2025 does not count the credit again. Undo reverses it; recording again with 0 moves nothing
-- and leaves the credit free for 2025. Paying through Counta after a record of ₦3m clears only the other ₦2m, and then the
-- record cannot be undone.
do $$
declare s uuid := tests.id('s'); v jsonb; j public.journals; r jsonb; v_today date := current_date;
begin
  perform pg_temp.trade(s, 2024, 200000000, 5000000, 100000000);
  perform pg_temp.trade(s, 2025, 200000000, 0, 100000000);
  perform private.post_entry(s, 'CIT provision 2024', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '7501', 'debit', 3000000), jsonb_build_object('code', '2208', 'credit', 3000000)), '2024-12-31 12:00+01');
  r := private.cit_run(s, 2024);
  assert pg_temp.fig(r, 'wht_credit') = 5000000, 'cit_outside: Counta''s figure';
  perform tests.as_user(tests.id('sade'));
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, %s, '{}'::jsonb)$q$, s, extract(year from v_today)::int), '%accounts year has not ended yet.');
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, '{"paid_on": "2024-12-01"}'::jsonb)$q$, s), '%is paid after the year ends. Check the date.');
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, %L::jsonb)$q$, s, jsonb_build_object('paid_on', v_today + 3)), '%A payment cannot be in the future.');
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, '{"wht_credit": 9000000}'::jsonb)$q$, s),
    '%Account 1401 holds NGN 5,000,000.00 of WHT credit notes. Enter at most that.');
  v := public.record_cit_paid_outside(s, 2024, '{"paid_on": "2025-06-30", "note": "Paid at the bank"}'::jsonb);
  perform tests.as_postgres();
  assert (v->'row'->'paid_outside'->>'wht_credit')::numeric = 5000000 and v->'row'->'paid_outside'->>'note' = 'Paid at the bank'
    and v->'row'->>'tax_paid_at' is null, 'cit_outside: the year shows it';
  select * into j from journals where id = (v->'row'->'paid_outside'->>'journal_id')::uuid;
  assert j.entry_date = '2025-06-30' and j.source_type = 'cit_year', 'cit_outside: dated when paid';
  assert (select debit from journal_lines where journal_id = j.id and account_code = '2208') = 3000000
    and (select debit from journal_lines where journal_id = j.id and account_code = '7501') = 2000000
    and pg_temp.cleared(s, 'cit_wht:2024') = 5000000 and pg_temp.ledger(s, '1401') = 0 and pg_temp.ledger(s, '2208') = 0, 'cit_outside: the entry';
  r := private.cit_run(s, 2025);
  assert pg_temp.fig(r, 'wht_held') = 0 and pg_temp.fig(r, 'wht_pending') = 0 and pg_temp.fig(r, 'wht_credit') = 0, 'cit_outside: 2025 has nothing to use';
  perform tests.as_user(tests.id('sade'));
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, '{}'::jsonb)$q$, s), '%already recorded as paid outside Counta. Undo that first to change it.');
  v := public.record_cit_paid_outside(s, 2024, '{"undo": true}'::jsonb);
  perform tests.as_postgres();
  assert v->'row'->'paid_outside' = 'null'::jsonb and exists (select 1 from journals where reversal_of = j.id) and pg_temp.ledger(s, '1401') = 5000000
    and pg_temp.ledger(s, '2208') = -3000000, 'cit_outside: undone';
  -- With 0: nothing moves, and 2025 may use 2024's credit (it is not counted as used).
  perform tests.as_user(tests.id('sade'));
  v := public.record_cit_paid_outside(s, 2024, '{"wht_credit": "0", "paid_on": "2025-06-30"}'::jsonb);
  perform tests.as_postgres();
  assert v->'row'->'paid_outside'->>'journal_id' is null and pg_temp.ledger(s, '1401') = 5000000, 'cit_outside: nothing moved for 0';
  r := private.cit_run(s, 2025);
  assert pg_temp.fig(r, 'wht_held') = 5000000 and pg_temp.fig(r, 'wht_pending') = 0 and pg_temp.fig(r, 'wht_credit') > 0, 'cit_outside: 2025 may use it';
  -- Recorded with ₦3m, then paid through Counta with Rev360 applying ₦5m: the payment clears only the other ₦2m.
  perform tests.as_user(tests.id('sade'));
  v := public.record_cit_paid_outside(s, 2024, '{"undo": true}'::jsonb);
  v := public.record_cit_paid_outside(s, 2024, '{"wht_credit": 3000000, "paid_on": "2025-06-30"}'::jsonb);
  perform tests.as_postgres();
  assert pg_temp.cleared(s, 'cit_wht:2024') = 3000000, 'cit_outside: ₦3m recorded';
  perform private.post_tax_paid(s, 'cit', null, null, 2024, 20000000, null, '1011', 0, 'CIT-2024', (select id from members where org_id = s and user_id = tests.id('sade')),
    gen_random_uuid(), null, '2025-07-15 12:00+01', 'Companies income tax 2024', 'NRS',
    jsonb_build_object('penalty', 0, 'interest', 0, 'late_filing_penalty', 0, 'charges', 0, 'credit_applied', 5000000));
  assert pg_temp.cleared(s, 'cit_wht:2024') = 5000000 and pg_temp.ledger(s, '1401') = 0, 'cit_outside: the payment cleared only the other ₦2m';
  perform tests.as_user(tests.id('sade'));
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, '{"undo": true}'::jsonb)$q$, s), '%is now recorded in Counta, so this cannot be undone.');
  perform tests.as_postgres();
end $$;

-- test: cit_outside_paid_first
-- A year whose payment is recorded through Counta cannot also be recorded as paid outside it.
do $$
begin
  perform tests.as_user(tests.id('sade'));
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2024, '{}'::jsonb)$q$, tests.id('s')), '%The 2024 tax payment is recorded in Counta already.');
  perform tests.as_postgres();
end $$;

-- test: outside_permissions
-- Only people who file tax may mark or record; nobody signed out may.
do $$
declare v_staff uuid := tests.user('staff.member@haulage.example.test', 'Staff Member');
begin
  perform tests.member(tests.id('s'), v_staff, 'staff');
  perform tests.as_user(v_staff);
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2023, '{}'::jsonb)$q$, tests.id('s')), '%Your role does not allow this (file tax).');
  perform tests.as_anon();
  perform tests.throws(format($q$select public.record_cit_paid_outside(%L, 2023, '{}'::jsonb)$q$, tests.id('s')), '%permission denied%');
  perform tests.throws(format($q$select public.mark_pit_filed(%L, 2024, '{"outside": true}'::jsonb)$q$, tests.id('t')), '%permission denied%');
  perform tests.as_postgres();
end $$;

-- test: audit_webhook_poll
-- The payments function's call for an audit fee's webhook: one request to the audits function, as its cron makes. Only the
-- service role may call it.
do $$
declare n0 bigint := (select count(*) from net._requests); r net._requests;
begin
  perform tests.as_service();
  assert public.svc_audit_poll_now(), 'audit_webhook_poll: the call left';
  perform tests.as_postgres();
  select * into r from net._requests order by id desc limit 1;
  assert (select count(*) from net._requests) = n0 + 1 and r.url = 'http://functions.test/audits' and r.body = '{"action": "poll"}'::jsonb
    and r.headers->>'x-counta-hook' = 'test-hook', 'audit_webhook_poll: the request';
  perform tests.as_user(tests.id('sade'));
  perform tests.throws('select public.svc_audit_poll_now()', '%permission denied%');
  perform tests.as_postgres();
end $$;

-- test: advisors
-- The sixteen helpers have a fixed search_path, and the five foreign keys an index.
do $$
declare f text;
begin
  foreach f in array array['private.kyc_missing(jsonb)', 'private.partner_defaults()', 'private.partner_new_ref()', 'private.plan_price(plans,text)',
    'private.secret_catalog()', 'private.words_and(text[])', 'private.hs_code(text)', 'private.nrs_irn(text,text,date)', 'private.feature_keys()',
    'private.plan_fmt(numeric)', 'private.ai_read_kinds()', 'private.ai_assistant_kinds()', 'private.month_start()', 'private.audit_defaults()',
    'private.audit_naira(numeric)', 'private.audit_can_act(members)'] loop
    assert exists (select 1 from pg_proc where oid = f::regprocedure and proconfig @> array['search_path=public, private']), 'advisors: search_path of ' || f;
  end loop;
  assert (select count(*) from pg_indexes where schemaname = 'public' and indexname in ('einvoice_docs_issued_by', 'lookup_failures_user', 'portal_logins_authority',
    'portal_logins_saved_by', 'recurring_invoices_created_by')) = 5, 'advisors: the five indexes';
  -- Helpers stay private.
  perform tests.as_user(tests.id('sade'));
  perform tests.throws(format('select private.wht_held_now(%L)', tests.id('s')), '%permission denied%');
  perform tests.as_postgres();
end $$;

rollback;
