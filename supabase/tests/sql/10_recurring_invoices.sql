-- Recurring invoices: schedules (monthly on a day from 1 to 28, quarterly, annually) that the hourly tick turns into invoices
-- in the business's own (Lagos) day: created, issued, sent to the customer, rolled forward with one catch-up and no backfill;
-- held for NRS when e-invoicing clears them first, then sent once signed (or left to the person when voided or refused);
-- one-off lines on the first invoice only; each schedule on its own, paused after three failures in a row; issued on the
-- authority of the person who last saved the schedule (under full mandate the business's contact when that place is gone;
-- an ordinary business's schedule fails instead), run now as the person pressing it, each invoice's log entries carrying
-- its own actor; an edit of the timing never bills a period twice; ended at its end date; paused when a full mandate ends;
-- the RPCs need record_sales. Edge-function calls are only recorded in net._requests.
begin;

-- Fixture: an ordinary business (owner Ada, a cashier who may not record sales, two clerks who record sales but cannot
-- override a credit limit), its customers; hooks on.
do $$
declare v_owner uuid; o uuid;
begin
  v_owner := tests.remember('owner', tests.user('owner@retainer.example.test', 'Ada Owner'));
  perform tests.remember('cashier', tests.user('cashier@retainer.example.test', 'Chidi Cashier'));
  perform tests.remember('outsider', tests.user('someone@example.test', 'Some One'));
  o := tests.remember('o', tests.org(v_owner, 'Retainer Books Ltd'));
  perform tests.remember('owner_seat', (select id from members where org_id = o and user_id = v_owner));
  -- A cashier records sales by default; this one may not.
  perform tests.remember('cashier_seat', tests.member(o, tests.id('cashier'), 'cashier'));
  update members set perm_overrides = '{"record_sales": false}' where id = tests.id('cashier_seat');
  perform private.apply_member_perms(tests.id('cashier_seat'));
  perform tests.remember('clerk', tests.user('clerk@retainer.example.test', 'Kemi Clerk'));
  perform tests.remember('clerk_seat', tests.member(o, tests.id('clerk'), 'staff'));
  perform tests.remember('clerk2', tests.user('clerk2@retainer.example.test', 'Femi Clerk'));
  perform tests.remember('clerk2_seat', tests.member(o, tests.id('clerk2'), 'staff'));
  perform tests.as_user(v_owner);
  perform tests.remember('cust_a', public.save_customer(o, '{"name": "Kola Client", "email": "kola@client.example.test"}'));
  perform tests.remember('cust_b', public.save_customer(o, '{"name": "Bola Client", "email": "bola@client.example.test"}'));
  perform tests.remember('cust_c', public.save_customer(o, '{"name": "Gone Client", "email": "gone@client.example.test"}'));
  perform tests.remember('cust_d', public.save_customer(o, '{"name": "Dayo Client", "email": "dayo@client.example.test"}'));
  perform tests.remember('cust_e', public.save_customer(o, '{"name": "Emeka Client", "email": "emeka@client.example.test"}'));
  perform tests.remember('cust_f', public.save_customer(o, '{"name": "Funke Client", "email": "funke@client.example.test"}'));
  perform tests.remember('cust_g', public.save_customer(o, '{"name": "Credit Client", "email": "credit@client.example.test"}'));
  perform tests.as_postgres();
  update customers set credit_limit = 50000 where id = tests.id('cust_g');
  perform tests.hooks_on();
end $$;

-- A schedule as recurring_save takes it: monthly on p_day from p_start, a 100,000 retainer with VAT, plus p_extra.
create function pg_temp.sched(p_customer uuid, p_day int, p_start date, p_extra jsonb default '{}') returns jsonb language sql as $f$
  select jsonb_build_object('customer_id', p_customer, 'frequency', 'monthly', 'day_of_month', p_day, 'start_date', p_start,
    'lines', '[{"description": "Monthly retainer", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"}]'::jsonb) || p_extra
$f$;

-- The invoice a schedule issued for a date.
create function pg_temp.run_sale(p_schedule uuid, p_date date) returns uuid language sql as $f$
  select sale_id from recurring_invoice_runs where schedule_id = p_schedule and run_date = p_date
$f$;

-- test: recurring_dates_and_local_day
-- Day 28 is in every February (leap or not); quarters and years roll over; a schedule started after its day of the month
-- begins the next month; "today" is the business's Lagos day: 22:30 UTC on 27 January is still the 27th in Lagos, 23:30
-- UTC is already the 28th.
do $$
declare o uuid := tests.id('o'); r uuid; v jsonb; p jsonb;
begin
  assert private.recurring_next('monthly', 28, '2027-01-28') = '2027-02-28' and private.recurring_next('monthly', 28, '2028-01-28') = '2028-02-28',
    'recurring_dates_and_local_day: February';
  assert private.recurring_next('monthly', 28, '2028-02-28') = '2028-03-28' and private.recurring_next('monthly', 10, '2026-12-10') = '2027-01-10',
    'recurring_dates_and_local_day: leap February to March, December to January';
  assert private.recurring_next('quarterly', 15, '2026-11-15') = '2027-02-15' and private.recurring_next('annually', 1, '2026-12-01') = '2027-12-01',
    'recurring_dates_and_local_day: quarter, year';
  assert private.recurring_next('annually', 28, '2027-02-28') = '2028-02-28' and private.recurring_next('quarterly', 28, '2027-11-28') = '2028-02-28',
    'recurring_dates_and_local_day: a year and a quarter onto a leap February';
  assert private.recurring_first('monthly', 5, '2026-11-20') = '2026-12-05' and private.recurring_first('monthly', 5, '2026-11-03') = '2026-11-05',
    'recurring_dates_and_local_day: mid-month start';
  assert private.recurring_first('monthly', 5, '2026-11-05') = '2026-11-05' and private.recurring_first('quarterly', 28, '2028-02-01') = '2028-02-28'
     and private.recurring_first('annually', 1, '2026-12-31') = '2027-01-01', 'recurring_dates_and_local_day: start on the day, leap February, year end';
  perform tests.throws($q$select private.recurring_next('weekly', 5, '2026-11-05')$q$, '%monthly, quarterly or annually%');
  perform tests.throws($q$select private.recurring_first('monthly', 29, '2026-11-05')$q$, '%1 to 28%');

  -- A schedule due on 28 January 2026 in a Lagos business, with a one-off expenses deposit.
  p := pg_temp.sched(tests.id('cust_a'), 28, '2026-01-01', jsonb_build_object('lines', '[
    {"description": "Monthly retainer", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"},
    {"description": "Expenses deposit", "qty": 1, "unit_price": 20000, "vat_treatment": "exempt", "once": true}]'::jsonb));
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_save(o, p);
  perform tests.as_postgres();
  r := tests.remember('r', (v->>'id')::uuid);
  assert v->>'next_run' = '2026-01-28' and v->>'status' = 'active' and (v->>'due_days')::int = 14 and (v->>'auto_send')::boolean
     and v->>'send_channel' = 'email' and v->>'customer_name' = 'Kola Client' and v->'runs' = '[]'::jsonb
     and (select created_by from recurring_invoices where id = r) = tests.id('owner_seat'), 'recurring_dates_and_local_day: saved';
  assert (select timezone = 'Africa/Lagos' from orgs where id = o), 'recurring_dates_and_local_day: a Lagos business';

  v := private.recurring_tick('2026-01-27 22:30:00+00');
  assert (select count(*) from recurring_invoice_runs where schedule_id = r) = 0 and v = '{"issued": 0, "sent": 0, "failed": 0}',
    'recurring_dates_and_local_day: 23:30 in Lagos on the 27th is not the 28th';
  v := private.recurring_tick('2026-01-27 23:30:00+00');
  assert (select count(*) from recurring_invoice_runs where schedule_id = r and run_date = '2026-01-28') = 1, 'recurring_dates_and_local_day: Lagos day';
  assert v = '{"issued": 1, "sent": 1, "failed": 0}', format('recurring_dates_and_local_day: the tick''s counts, got %s', v);
end $$;

-- test: recurring_issue_and_send
-- The run made an invoice dated the run day, due 14 days later, issued (posted) in the name of the person who set the
-- schedule up, sent to the customer by email; the schedule moved on to the next month.
do $$
declare r uuid := tests.id('r'); s public.sales;
begin
  select * into s from sales where id = pg_temp.run_sale(r, '2026-01-28');
  assert s.status = 'open' and s.channel = 'recurring' and s.doc_type = 'invoice' and s.issue_date = '2026-01-28' and s.due_date = s.issue_date + 14
     and s.journal_id is not null and s.customer_id = tests.id('cust_a'), 'recurring_issue_and_send: issued';
  assert (select s2.status = 'open' and s2.channel = 'recurring' and s2.due_date = s2.issue_date + 14 from sales s2 join recurring_invoice_runs x on x.sale_id = s2.id where x.schedule_id = r),
    'recurring_issue_and_send: issued (the brief''s form)';
  assert s.created_by = tests.id('owner_seat') and (select posted_by from journals where id = s.journal_id) = tests.id('owner_seat'),
    'recurring_issue_and_send: in the name of the person who set it up';
  assert (select status from recurring_invoice_runs where schedule_id = r) = 'sent'
     and exists (select 1 from messages m join recurring_invoice_runs x on m.sale_id = x.sale_id where x.schedule_id = r), 'recurring_issue_and_send: sent';
  assert (select count(*) from messages where sale_id = s.id and channel = 'email' and to_address = 'kola@client.example.test' and template = 'document') = 1
     and (select sent_at is not null from sales where id = s.id), 'recurring_issue_and_send: one email to the customer';
  assert (select next_run = '2026-02-28' and failures = 0 and last_error is null and last_run_at is not null and status = 'active' from recurring_invoices where id = r),
    'recurring_issue_and_send: rolled forward';
  assert coalesce(current_setting('counta.actor', true), '') = '', 'recurring_issue_and_send: the actor is cleared after the tick';
end $$;

-- test: recurring_no_double_run
-- A second tick the same hour does nothing; a run day already done (the schedule set back to it by hand) is not run again,
-- and the schedule moves on.
do $$
declare r uuid := tests.id('r'); v jsonb;
begin
  v := private.recurring_tick('2026-01-27 23:45:00+00');
  assert (select count(*) from recurring_invoice_runs where schedule_id = r) = 1 and v = '{"issued": 0, "sent": 0, "failed": 0}', 'recurring_no_double_run';
  update recurring_invoices set next_run = '2026-01-28' where id = r;
  v := private.recurring_tick('2026-01-27 23:50:00+00');
  assert (select count(*) from recurring_invoice_runs where schedule_id = r) = 1 and v = '{"issued": 0, "sent": 0, "failed": 0}'
     and (select count(*) from sales where org_id = tests.id('o') and channel = 'recurring') = 1, 'recurring_no_double_run: a run day done is not done again';
  assert (select next_run from recurring_invoices where id = r) = '2026-02-28', 'recurring_no_double_run: the schedule still moves on';
end $$;

-- test: recurring_vat_and_once_lines
-- 100,000 with VAT at 7.5% and a 20,000 VAT-exempt deposit on the first invoice only: 127,500 then 107,500. The prices are
-- before VAT whatever the business's own setting (this one prices with VAT included). VAT treatment 'none' is refused on
-- save, as the invoice lines refuse it; so are other malformed schedules. Once the schedule has issued an invoice, a new
-- line marked once is refused (it would never be billed); the deposit already there stays through other edits.
do $$
declare o uuid := tests.id('o'); r uuid := tests.id('r'); first_sale uuid; second_sale uuid; v jsonb; p jsonb; v_lines jsonb;
begin
  assert (select prices_include_vat and vat_registered from orgs where id = o), 'recurring_vat_and_once_lines: the business prices with VAT included';
  first_sale := pg_temp.run_sale(r, '2026-01-28');
  v := private.recurring_tick('2026-02-27 23:30:00+00');
  second_sale := pg_temp.run_sale(r, '2026-02-28');
  assert (select total from sales where id = first_sale) = 127500 and (select total from sales where id = second_sale) = 107500,
    'recurring_vat_and_once_lines: 7.5% VAT, deposit once';
  assert (select vat_total = 7500 and subtotal = 120000 and not prices_include_vat from sales where id = first_sale)
     and (select count(*) from sale_lines where sale_id = first_sale) = 2
     and (select vat_treatment = 'exempt' and vat = 0 and gross = 20000 from sale_lines where sale_id = first_sale and description = 'Expenses deposit'),
    'recurring_vat_and_once_lines: the first invoice''s lines';
  assert (select array_agg(description) from sale_lines where sale_id = second_sale) = '{"Monthly retainer"}', 'recurring_vat_and_once_lines: the deposit only once';
  assert (select next_run from recurring_invoices where id = r) = '2026-03-28' and v = '{"issued": 1, "sent": 1, "failed": 0}',
    'recurring_vat_and_once_lines: on to March';

  perform tests.as_user(tests.id('owner'));
  p := pg_temp.sched(tests.id('cust_b'), 1, '2026-12-01');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": "Deposit", "qty": 1, "unit_price": 20000, "vat_treatment": "none"}]}'), '%VAT treatment%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"day_of_month": 29}'), '%from 1 to 28%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"day_of_month": "5.5"}'), '%from 1 to 28%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"frequency": "weekly"}'), '%monthly, quarterly or annually%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"lines": []}'), '%at least one line%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || jsonb_build_object('lines',
    (select jsonb_agg(jsonb_build_object('description', 'Line ' || n, 'qty', 1, 'unit_price', 10)) from generate_series(1, 51) n))), '%50 lines%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": "Retainer", "qty": 0, "unit_price": 100}]}'), '%quantity above zero%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": "Retainer", "qty": 1, "unit_price": -1}]}'), '%price%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": " ", "qty": 1, "unit_price": 100}]}'), '%description%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": "Deposit", "qty": 1, "unit_price": 100, "once": true}]}'), '%repeats%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o,
    p || '{"lines": [{"description": "Retainer", "qty": 1, "unit_price": 0}]}'), '%more than zero%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"end_date": "2026-11-30"}'), '%end date%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"start_date": "2026-12-02", "end_date": "2026-12-31"}'), '%No invoice date%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"start_date": "soon"}'), '%start date%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"due_days": 400}'), '%0 to 365%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || '{"send_channel": "sms"}'), '%email or WhatsApp%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || jsonb_build_object('customer_id', gen_random_uuid())), '%Choose the customer%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || jsonb_build_object('id', gen_random_uuid())), '%not found%');

  perform tests.as_postgres();
  v_lines := (select lines from recurring_invoices where id = r);
  perform tests.as_user(tests.id('owner'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, jsonb_build_object('id', r, 'lines',
    v_lines || '[{"description": "Set-up fee", "qty": 1, "unit_price": 5000, "once": true}]'::jsonb)), '%new line marked once would never be billed%');
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, jsonb_build_object('id', r, 'lines',
    jsonb_set(v_lines, '{1,unit_price}', '25000'))), '%new line marked once%');
  v := public.recurring_save(o, jsonb_build_object('id', r, 'notes', 'Retainer for 2026', 'lines', v_lines));
  assert v->>'notes' = 'Retainer for 2026' and v->'lines' = v_lines and v->>'next_run' = '2026-03-28',
    'recurring_vat_and_once_lines: the deposit already there stays through an edit';
  perform tests.as_postgres();
end $$;

-- test: recurring_catch_up_once
-- A schedule three months behind (its start date long past) makes one invoice, dated the day it was due, and moves on past
-- today: no backfill.
do $$
declare o uuid := tests.id('o'); r2 uuid; v jsonb; v_due date; v_today date := private.local_day(tests.id('o'), now());
begin
  update recurring_invoices set status = 'paused' where id = tests.id('r');
  v_due := (date_trunc('month', v_today) - interval '3 months')::date;
  perform tests.as_user(tests.id('owner'));
  r2 := tests.remember('r2', (public.recurring_save(o, pg_temp.sched(tests.id('cust_b'), 1, v_due))->>'id')::uuid);
  perform tests.as_postgres();
  assert (select next_run from recurring_invoices where id = r2) = v_due, 'recurring_catch_up_once: three months behind';
  v := private.recurring_tick();
  assert (select count(*) from recurring_invoice_runs where schedule_id = r2) = 1 and (select next_run > current_date from recurring_invoices where id = r2),
    'recurring_catch_up_once';
  assert (select next_run from recurring_invoices where id = r2) = (date_trunc('month', v_today) + interval '1 month')::date
     and (select issue_date from sales where id = pg_temp.run_sale(r2, v_due)) = v_due
     and (select count(*) from sales where customer_id = tests.id('cust_b') and channel = 'recurring') = 1 and v = '{"issued": 1, "sent": 1, "failed": 0}',
    'recurring_catch_up_once: one invoice, dated the day it was due';
  update recurring_invoices set status = 'paused' where id = r2;
end $$;

-- test: recurring_periods_and_end
-- Through the tick a quarterly schedule moves on three months and an annual one twelve; one that reaches its end date
-- (day 28, ending 28 February 2026) is issued that day and ends, and is not run again. An edit of the timing of a schedule
-- that has made an invoice keeps the period of the next one: billed quarterly on 1 October 2026 and moved to the 15th, the
-- next invoice is 15 January 2027, not a second one for the same quarter (annually the same); with no invoice yet it starts
-- again from the start date.
do $$
declare o uuid := tests.id('o'); q uuid; a uuid; e uuid; q2 uuid; n uuid; v jsonb;
begin
  perform tests.as_user(tests.id('owner'));
  q := (public.recurring_save(o, pg_temp.sched(tests.id('cust_b'), 15, '2026-02-01', '{"frequency": "quarterly"}'))->>'id')::uuid;
  a := (public.recurring_save(o, pg_temp.sched(tests.id('cust_b'), 1, '2026-03-01', '{"frequency": "annually"}'))->>'id')::uuid;
  e := (public.recurring_save(o, pg_temp.sched(tests.id('cust_b'), 28, '2026-02-01', '{"end_date": "2026-02-28"}'))->>'id')::uuid;
  perform tests.as_postgres();

  v := private.recurring_tick('2026-02-15 12:00:00+00');
  assert v = '{"issued": 1, "sent": 1, "failed": 0}' and pg_temp.run_sale(q, '2026-02-15') is not null
     and (select next_run from recurring_invoices where id = q) = '2026-05-15', format('recurring_periods_and_end: quarterly, got %s', v);
  v := private.recurring_tick('2026-02-28 12:00:00+00');
  assert v = '{"issued": 1, "sent": 1, "failed": 0}' and (select status from recurring_invoice_runs where schedule_id = e and run_date = '2026-02-28') = 'sent'
     and (select status = 'ended' and next_run = '2026-03-28' from recurring_invoices where id = e), 'recurring_periods_and_end: the end date reached';
  v := private.recurring_tick('2026-03-01 12:00:00+00');
  assert v = '{"issued": 1, "sent": 1, "failed": 0}' and pg_temp.run_sale(a, '2026-03-01') is not null
     and (select next_run from recurring_invoices where id = a) = '2027-03-01', 'recurring_periods_and_end: annual';
  v := private.recurring_tick('2026-03-28 12:00:00+00');
  assert v = '{"issued": 0, "sent": 0, "failed": 0}' and (select count(*) from recurring_invoice_runs where schedule_id = e) = 1,
    'recurring_periods_and_end: an ended schedule is not run again';

  -- Timing edits.
  update recurring_invoices set status = 'paused' where id = q;
  perform tests.as_user(tests.id('owner'));
  q2 := (public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, '2026-10-01', '{"frequency": "quarterly"}'))->>'id')::uuid;
  perform tests.as_postgres();
  v := private.recurring_tick('2026-10-01 12:00:00+00');
  assert pg_temp.run_sale(q2, '2026-10-01') is not null and (select next_run from recurring_invoices where id = q2) = '2027-01-01',
    'recurring_periods_and_end: quarterly billed on 1 October';
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_save(o, jsonb_build_object('id', q2, 'day_of_month', 15));
  assert v->>'next_run' = '2027-01-15', format('recurring_periods_and_end: a new day keeps the next quarter, got %s', v->>'next_run');
  v := public.recurring_save(o, jsonb_build_object('id', a, 'day_of_month', 20));
  assert v->>'next_run' = '2027-03-20', format('recurring_periods_and_end: a new day keeps the next year, got %s', v->>'next_run');
  v := public.recurring_save(o, jsonb_build_object('id', q2, 'frequency', 'monthly', 'day_of_month', 15));
  assert v->>'next_run' = '2027-01-15', 'recurring_periods_and_end: quarterly to monthly keeps the next period';
  n := (public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, '2026-12-01'))->>'id')::uuid;
  v := public.recurring_save(o, jsonb_build_object('id', n, 'day_of_month', 10));
  assert v->>'next_run' = '2026-12-10', 'recurring_periods_and_end: with no invoice yet, from the start date';
  perform tests.as_postgres();
  update recurring_invoices set status = 'paused' where id in (a, q2, n);
end $$;

-- test: recurring_pause_after_failures
-- A schedule that cannot issue (its customer archived) fails on its own: the healthy schedule in the same tick is issued;
-- the failing one keeps its day, records the error, and is paused after three failures in a row. A failure put right before
-- the third is retried on the same day and the count starts again.
do $$
declare o uuid := tests.id('o'); r3 uuid; r4 uuid; r5 uuid; v jsonb; v_due date := date_trunc('month', private.local_day(tests.id('o'), now()))::date;
begin
  perform tests.as_user(tests.id('owner'));
  r3 := tests.remember('r3', (public.recurring_save(o, pg_temp.sched(tests.id('cust_c'), 1, v_due))->>'id')::uuid);
  r4 := (public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, v_due))->>'id')::uuid;
  r5 := (public.recurring_save(o, pg_temp.sched(tests.id('cust_e'), 1, v_due))->>'id')::uuid;
  perform tests.as_postgres();
  update customers set archived = true where id in (tests.id('cust_c'), tests.id('cust_e'));

  v := private.recurring_tick();
  assert v = '{"issued": 1, "sent": 1, "failed": 2}', format('recurring_pause_after_failures: one tick, got %s', v);
  assert (select status from recurring_invoice_runs where schedule_id = r4) = 'sent', 'recurring_pause_after_failures: the healthy schedule is issued';
  assert (select status = 'active' and failures = 1 and last_error like 'Customer not found%' and next_run = v_due from recurring_invoices where id = r3)
     and (select status = 'failed' and sale_id is null and error like 'Customer not found%' from recurring_invoice_runs where schedule_id = r3 and run_date = v_due),
    'recurring_pause_after_failures: the failure recorded, the day kept';

  -- The second schedule's customer is brought back: retried on the same day, issued, the count back to zero.
  update customers set archived = false where id = tests.id('cust_e');
  v := private.recurring_tick();
  assert (select count(*) from recurring_invoice_runs where schedule_id = r5) = 1
     and (select status = 'sent' and error is null and sale_id is not null from recurring_invoice_runs where schedule_id = r5)
     and (select failures = 0 and last_error is null and next_run > v_due from recurring_invoices where id = r5), 'recurring_pause_after_failures: retried and issued';

  v := private.recurring_tick();
  assert (select status = 'paused' and failures = 3 and last_error is not null from recurring_invoices where id = r3), 'recurring_pause_after_failures';
  v := private.recurring_tick();
  assert (select failures from recurring_invoices where id = r3) = 3 and (select count(*) from recurring_invoice_runs where schedule_id = r3) = 1
     and v = '{"issued": 0, "sent": 0, "failed": 0}', 'recurring_pause_after_failures: a paused schedule is left alone';
  update recurring_invoices set status = 'paused' where id in (r4, r5);
end $$;

-- test: recurring_send_error_kept
-- An invoice that cannot be sent (no WhatsApp number) stays issued with the reason; one not to be sent is just issued.
do $$
declare o uuid := tests.id('o'); r6 uuid; r7 uuid; v jsonb; v_due date := date_trunc('month', private.local_day(tests.id('o'), now()))::date;
begin
  perform tests.as_user(tests.id('owner'));
  r6 := (public.recurring_save(o, pg_temp.sched(tests.id('cust_f'), 1, v_due, '{"send_channel": "whatsapp"}'))->>'id')::uuid;
  r7 := (public.recurring_save(o, pg_temp.sched(tests.id('cust_f'), 1, v_due, '{"auto_send": false}'))->>'id')::uuid;
  perform tests.as_postgres();
  v := private.recurring_tick();
  assert v = '{"issued": 2, "sent": 0, "failed": 0}', format('recurring_send_error_kept: counts, got %s', v);
  assert (select x.status = 'issued' and x.send_error like '%WhatsApp number%' and s.status = 'open' from recurring_invoice_runs x join sales s on s.id = x.sale_id where x.schedule_id = r6)
     and (select failures = 0 and status = 'active' from recurring_invoices where id = r6), 'recurring_send_error_kept: issued, the send error kept';
  assert (select x.status = 'issued' and x.send_error is null and s.status = 'open' and s.sent_at is null from recurring_invoice_runs x join sales s on s.id = x.sale_id where x.schedule_id = r7)
     and not exists (select 1 from messages m join recurring_invoice_runs x on x.sale_id = m.sale_id where x.schedule_id in (r6, r7)),
    'recurring_send_error_kept: issued, not sent';
  update recurring_invoices set status = 'paused' where id in (r6, r7);
end $$;

-- test: recurring_issuing_authority
-- Invoices are issued on the authority of someone who may issue them. Run now issues as the person pressing it: a clerk
-- (records sales, cannot go past a customer's credit limit) cannot run the owner's schedule past the limit; the owner can.
-- Whoever saves a schedule becomes its issuer, so after a clerk's edit the tick issues as the clerk and is refused past the
-- limit. In an ordinary business a schedule whose issuer can no longer record sales, or whose place is gone, fails with the
-- reason and pauses after three, borrowing no one else's authority. (Under full mandate the business's contact issues it
-- instead: recurring_actor_per_item.)
do $$
declare o uuid := tests.id('o'); sg uuid; sd uuid; se uuid; v jsonb; v_today date := private.local_day(tests.id('o'), now()); v_next_month date;
begin
  v_next_month := (date_trunc('month', v_today) + interval '1 month')::date;
  -- 107,500 a month to a customer with a 50,000 limit.
  perform tests.as_user(tests.id('owner'));
  sg := (public.recurring_save(o, pg_temp.sched(tests.id('cust_g'), 1, v_next_month))->>'id')::uuid;
  perform tests.as_user(tests.id('clerk'));
  perform tests.throws(format('select public.recurring_run_now(%L)', sg), '%credit limit%');
  sd := (public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, v_next_month))->>'id')::uuid;
  v := public.recurring_run_now(sd);
  perform tests.as_postgres();
  assert (select created_by from sales where id = (v->>'sale_id')::uuid) = tests.id('clerk_seat') and v->>'status' = 'sent',
    'recurring_issuing_authority: run now as the clerk';
  assert not exists (select 1 from recurring_invoice_runs where schedule_id = sg), 'recurring_issuing_authority: nothing kept of the refused run';
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_run_now(sg);
  perform tests.as_postgres();
  assert (select created_by from sales where id = (v->>'sale_id')::uuid) = tests.id('owner_seat') and v->>'status' = 'sent',
    'recurring_issuing_authority: the owner can';

  -- The clerk edits the owner's schedule: the clerk is now its issuer, and the tick cannot go past the limit.
  perform tests.as_user(tests.id('clerk'));
  v := public.recurring_save(o, jsonb_build_object('id', sg, 'notes', 'Quarterly review included'));
  perform tests.as_postgres();
  assert (select created_by from recurring_invoices where id = sg) = tests.id('clerk_seat') and v->>'created_by_name' = 'Kemi Clerk',
    'recurring_issuing_authority: the editor is the issuer';
  update recurring_invoices set next_run = v_today - 1 where id = sg;
  v := private.recurring_tick();
  assert v = '{"issued": 0, "sent": 0, "failed": 1}' and (select failures = 1 and last_error like '%credit limit%' from recurring_invoices where id = sg),
    format('recurring_issuing_authority: the tick issues as the clerk, got %s', v);
  update recurring_invoices set status = 'paused' where id = sg;

  -- The clerk can no longer record sales; the other clerk's place is gone.
  perform tests.as_user(tests.id('clerk2'));
  se := (public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, date_trunc('month', v_today)::date))->>'id')::uuid;
  perform tests.as_postgres();
  update members set perm_overrides = '{"record_sales": false}' where id = tests.id('clerk_seat');
  perform private.apply_member_perms(tests.id('clerk_seat'));
  update members set status = 'disabled' where id = tests.id('clerk2_seat');
  update recurring_invoices set next_run = v_today - 1 where id = sd;
  v := private.recurring_tick();
  assert v = '{"issued": 0, "sent": 0, "failed": 2}' and (select bool_and(failures = 1 and last_error like '%can no longer issue invoices%')
      from recurring_invoices where id in (sd, se)), format('recurring_issuing_authority: no authority, no invoice, got %s', v);
  perform private.recurring_tick();
  perform private.recurring_tick();
  assert (select bool_and(status = 'paused' and failures = 3) from recurring_invoices where id in (sd, se))
     and not exists (select 1 from recurring_invoice_runs where schedule_id in (sd, se) and status <> 'failed' and run_date <> v_today)
     and not exists (select 1 from recurring_invoice_runs where schedule_id = se and status <> 'failed'),
    'recurring_issuing_authority: paused after three, nothing issued on anyone else''s authority';
  -- The owner saves it: issued in the owner's name from then on.
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_save(o, jsonb_build_object('id', se));
  v := public.recurring_set_status(se, 'active');
  perform tests.as_postgres();
  update recurring_invoices set next_run = v_today - 1 where id = se;
  v := private.recurring_tick();
  assert v = '{"issued": 1, "sent": 1, "failed": 0}' and (select created_by from sales where id = pg_temp.run_sale(se, v_today - 1)) = tests.id('owner_seat'),
    format('recurring_issuing_authority: taken over by the owner, got %s', v);
  update recurring_invoices set status = 'paused' where id = se;
end $$;

-- test: recurring_waiting_nrs
-- With e-invoicing on, an invoice to a business customer waits for NRS: the run waits, nothing is sent; once NRS signs it
-- (and it is issued) the next tick sends it, and a send that fails then counts as failed. A held invoice voided before
-- NRS signs it, credited in full after, refused by NRS, or taken back to change is left to the person: its run is void,
-- with the reason, and is not sent later. (The app voids no draft and NRS's signature rules out voiding, so the void and the
-- full credit are written directly here: whatever route closes the invoice, the run must not wait for ever.)
do $$
declare v_owner uuid; o2 uuid; cu uuid; r8 uuid; r8w uuid; r8v uuid; r8c uuid; r8r uuid; r8t uuid; v jsonb; s uuid; sw uuid; sv uuid; sc uuid; sr uuid; st uuid;
  v_due date;
begin
  v_owner := tests.user('owner@signed.example.test', 'Sade Owner');
  o2 := tests.org(v_owner, 'Signed Books Ltd');
  insert into einvoice_settings (org_id, enabled, enabled_at) values (o2, true, now());
  v_due := date_trunc('month', private.local_day(o2, now()))::date;
  perform tests.as_user(v_owner);
  cu := public.save_customer(o2, '{"name": "Tinned Client Ltd", "email": "accounts@tinned.example.test", "kind": "business", "tin": "1234567800011"}');
  r8 := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due))->>'id')::uuid;
  r8w := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due, '{"send_channel": "whatsapp"}'))->>'id')::uuid;
  r8v := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due))->>'id')::uuid;
  r8c := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due))->>'id')::uuid;
  r8r := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due))->>'id')::uuid;
  r8t := (public.recurring_save(o2, pg_temp.sched(cu, 1, v_due))->>'id')::uuid;
  perform tests.as_postgres();
  v := private.recurring_tick();
  s := pg_temp.run_sale(r8, v_due); sw := pg_temp.run_sale(r8w, v_due); sv := pg_temp.run_sale(r8v, v_due); sc := pg_temp.run_sale(r8c, v_due);
  sr := pg_temp.run_sale(r8r, v_due); st := pg_temp.run_sale(r8t, v_due);
  assert v = '{"issued": 6, "sent": 0, "failed": 0}' and (select bool_and(status = 'waiting_nrs') from recurring_invoice_runs where schedule_id in (r8, r8w, r8v, r8c, r8r, r8t))
     and (select status from sales where id = s) = 'draft' and (select state = 'waiting' and held from einvoice_docs where sale_id = s)
     and not exists (select 1 from messages where sale_id in (s, sw, sv, sc, sr, st)), format('recurring_waiting_nrs: waits for NRS, got %s', v);
  v := private.recurring_tick();
  assert v = '{"issued": 0, "sent": 0, "failed": 0}' and (select status from recurring_invoice_runs where schedule_id = r8) = 'waiting_nrs'
     and not exists (select 1 from messages where sale_id = s), 'recurring_waiting_nrs: still waiting';
  -- One voided before NRS signs it; NRS signs three (one then credited in full) and refuses one; one is taken back.
  update sales set status = 'void', void_reason = 'Raised in error' where id = sv;
  update einvoice_docs set state = 'sending', sending_at = now() where sale_id in (s, sw, sc, sr);
  perform tests.as_service();
  perform public.svc_einvoice_done(s, '{"outcome": "signed"}');
  perform public.svc_einvoice_done(sw, '{"outcome": "signed"}');
  perform public.svc_einvoice_done(sc, '{"outcome": "signed"}');
  perform public.svc_einvoice_done(sr, '{"outcome": "refused", "note": "Bad buyer address."}');
  perform tests.as_user(v_owner);
  perform public.einvoice_take_back(st);
  perform tests.as_postgres();
  update sales set status = 'credited' where id = sc;
  assert (select status from sales where id = s) = 'open' and (select status = 'void' and irn_status = 'stopped' from sales where id = sv)
     and (select status = 'draft' and irn_status = 'refused' from sales where id = sr) and (select state from einvoice_docs where sale_id = st) = 'stopped',
    'recurring_waiting_nrs: signed and issued, voided, refused, taken back';
  v := private.recurring_tick();
  assert v = '{"issued": 0, "sent": 1, "failed": 1}', format('recurring_waiting_nrs: the next tick, got %s', v);
  assert (select status from recurring_invoice_runs where schedule_id = r8) = 'sent'
     and (select count(*) from messages where sale_id = s and to_address = 'accounts@tinned.example.test') = 1, 'recurring_waiting_nrs: sent on the next tick';
  assert (select status = 'issued' and send_error like '%WhatsApp number%' from recurring_invoice_runs where schedule_id = r8w),
    'recurring_waiting_nrs: a send that fails counts, the invoice kept';
  assert (select status = 'void' and error like '%voided%' from recurring_invoice_runs where schedule_id = r8v)
     and (select status = 'void' and error like '%credited in full%' from recurring_invoice_runs where schedule_id = r8c)
     and (select status = 'void' and error like 'NRS refused%' from recurring_invoice_runs where schedule_id = r8r)
     and (select status = 'void' and error like '%taken back%' from recurring_invoice_runs where schedule_id = r8t)
     and not exists (select 1 from messages where sale_id in (sv, sc, sr, st)), 'recurring_waiting_nrs: voided, credited, refused and taken back left to the person';
  -- Issued again by hand and signed: the schedule does not send it.
  perform tests.as_user(v_owner);
  perform public.issue_invoice(sr);
  perform tests.as_postgres();
  update einvoice_docs set state = 'sending', sending_at = now() where sale_id = sr;
  perform tests.as_service();
  perform public.svc_einvoice_done(sr, '{"outcome": "signed"}');
  perform tests.as_postgres();
  v := private.recurring_tick();
  assert (select status from sales where id = sr) = 'open' and v = '{"issued": 0, "sent": 0, "failed": 0}'
     and (select status from recurring_invoice_runs where schedule_id = r8r) = 'void' and not exists (select 1 from messages where sale_id = sr),
    'recurring_waiting_nrs: a void run stays void';
  update recurring_invoices set status = 'paused' where id in (r8, r8w, r8v, r8c, r8r, r8t);
end $$;

-- test: recurring_actor_per_item
-- In a business run under full mandate every write is logged. One tick issues schedules set up by different people: each
-- invoice's log entries carry the person who set its schedule up; a schedule whose creator's place is gone is issued as the
-- business's contact (the engagement partner); a failing schedule after them does not inherit the one before's actor.
do $$
declare v_partner uuid; v_manager uuid; v_kunle uuid; pr uuid; mo uuid; ca uuid; cb uuid; cc uuid; ra uuid; rb uuid; rc uuid; rd uuid; v jsonb;
  sa uuid; sb uuid; sd uuid; v_partner_seat uuid; v_manager_seat uuid; v_kunle_seat uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Bisi Partner'));
  v_manager := tests.remember('manager', tests.user('tola.manager@firm.example.test', 'Tola Manager'));
  v_kunle := tests.user('kunle.partner@firm.example.test', 'Kunle Partner');
  pr := tests.remember('pr', tests.practice(v_partner, 'Ledger Partners', true));
  perform tests.practice_member(pr, v_manager, 'manager');
  perform tests.practice_member(pr, v_kunle, 'partner');
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = pr and user_id <> v_partner;
  mo := tests.remember('mo', tests.managed_org(pr, 'Managed Retainer Ltd'));
  v_partner_seat := (select id from members where org_id = mo and user_id = v_partner);
  v_manager_seat := (select id from members where org_id = mo and user_id = v_manager);
  v_kunle_seat := (select id from members where org_id = mo and user_id = v_kunle);
  assert v_partner_seat is not null and v_manager_seat is not null and v_kunle_seat is not null, 'recurring_actor_per_item: acting seats';
  -- The director who approves what the firm sets up (Release 2): each schedule waits for them once, then runs on its own.
  perform tests.director_approver(mo);

  perform tests.as_user(v_partner);
  ca := public.save_customer(mo, '{"name": "Alpha Client", "email": "alpha@client.example.test"}');
  cb := public.save_customer(mo, '{"name": "Beta Client", "email": "beta@client.example.test"}');
  cc := public.save_customer(mo, '{"name": "Gamma Client", "email": "gamma@client.example.test"}');
  ra := tests.remember('ra', (public.recurring_save(mo, pg_temp.sched(ca, 5, '2026-03-01'))->>'id')::uuid);
  rc := (public.recurring_save(mo, pg_temp.sched(cc, 7, '2026-03-01'))->>'id')::uuid;
  perform tests.as_user(v_manager);
  rb := (public.recurring_save(mo, pg_temp.sched(cb, 6, '2026-03-01'))->>'id')::uuid;
  perform tests.as_user(v_kunle);
  rd := (public.recurring_save(mo, pg_temp.sched(cb, 8, '2026-03-01'))->>'id')::uuid;
  perform tests.as_postgres();
  assert (select count(*) from recurring_invoices where org_id = mo and approval_state = 'pending') = 4, 'recurring_actor_per_item: waiting for the director';
  assert tests.director_approves(mo) = 4, 'recurring_actor_per_item: the director approves the four schedules';
  assert (select count(*) from recurring_invoices where org_id = mo and approval_state = 'approved') = 4, 'recurring_actor_per_item: approved';
  assert (select created_by from recurring_invoices where id = rb) = v_manager_seat and (select created_by from recurring_invoices where id = rd) = v_kunle_seat,
    'recurring_actor_per_item: the creators';
  -- Kunle's place is gone; Gamma Client is archived, so its schedule fails.
  perform set_config('counta.seat_sync', 'on', true);
  update members set status = 'disabled' where id = v_kunle_seat;
  perform set_config('counta.seat_sync', '', true);
  update customers set archived = true where id = cc;

  -- In order: ra (5th, Bisi), rb (6th, Tola), rc (7th, fails), rd (8th, Kunle gone).
  v := private.recurring_tick('2026-03-10 12:00:00+00');
  assert v = '{"issued": 3, "sent": 3, "failed": 1}', format('recurring_actor_per_item: counts, got %s', v);
  sa := pg_temp.run_sale(ra, '2026-03-05'); sb := pg_temp.run_sale(rb, '2026-03-06'); sd := pg_temp.run_sale(rd, '2026-03-08');
  assert (select created_by from sales where id = sa) = v_partner_seat and (select created_by from sales where id = sb) = v_manager_seat
     and (select created_by from sales where id = sd) = v_partner_seat, 'recurring_actor_per_item: issued in the creator''s name, else the contact''s';
  assert (select count(*) from activity_log where org_id = mo and entity = 'sales' and entity_id = sa::text) > 0
     and not exists (select 1 from activity_log where org_id = mo and entity = 'sales' and entity_id = sa::text and actor_user is distinct from v_partner),
    'recurring_actor_per_item: the first invoice logged as Bisi';
  assert (select count(*) from activity_log where org_id = mo and entity = 'sales' and entity_id = sb::text) > 0
     and not exists (select 1 from activity_log where org_id = mo and entity = 'sales' and entity_id = sb::text and actor_user is distinct from v_manager)
     and (select actor_name from activity_log where org_id = mo and entity = 'sales' and entity_id = sb::text and action = 'insert') = 'Tola Manager',
    'recurring_actor_per_item: the second invoice logged as Tola';
  assert (select count(*) from activity_log where org_id = mo and entity = 'sales' and entity_id = sd::text) > 0
     and not exists (select 1 from activity_log where org_id = mo and entity = 'sales' and entity_id = sd::text and actor_user is distinct from v_partner),
    'recurring_actor_per_item: the gone creator''s invoice logged as the engagement partner';
  assert exists (select 1 from activity_log where org_id = mo and entity = 'recurring_invoices' and entity_id = rc::text and 'failures' = any (changed))
     and not exists (select 1 from activity_log where org_id = mo and entity = 'recurring_invoices' and entity_id = rc::text and 'failures' = any (changed)
                     and (actor_user is not null or actor_name <> 'Counta')),
    'recurring_actor_per_item: the failure is Counta''s, not the previous schedule''s actor';
  assert exists (select 1 from activity_log where org_id = mo and entity = 'recurring_invoices' and entity_id = rb::text and 'next_run' = any (changed) and actor_user = v_manager),
    'recurring_actor_per_item: the schedule moving on is logged with its own actor';
  assert coalesce(current_setting('counta.actor', true), '') = '', 'recurring_actor_per_item: the actor is cleared after the tick';
  update recurring_invoices set status = 'paused' where id in (rb, rc, rd);
end $$;

-- test: recurring_outbound_gate
-- A business run under full mandate that the firm set to download only sends nothing: a schedule cannot be saved to send
-- each invoice, and one saved before is issued with the gate's reason as its send error.
do $$
declare mo uuid := tests.id('mo'); ra uuid := tests.id('ra'); v jsonb; v_due date; rx uuid; cu uuid;
begin
  update orgs set send_mode = 'download_only' where id = mo;
  cu := (select customer_id from recurring_invoices where id = ra);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', mo, pg_temp.sched(cu, 9, '2026-04-01')), '%download only%');
  rx := (public.recurring_save(mo, pg_temp.sched(cu, 9, '2026-04-01', '{"auto_send": false}'))->>'id')::uuid;
  perform tests.as_postgres();
  update recurring_invoices set status = 'paused' where id = rx;
  v_due := (select next_run from recurring_invoices where id = ra);
  v := private.recurring_tick((v_due + 1)::timestamp at time zone 'UTC' + interval '12 hours');
  assert v = '{"issued": 1, "sent": 0, "failed": 0}' and (select x.status = 'issued' and x.send_error like '%download only%' and s.status = 'open'
      from recurring_invoice_runs x join sales s on s.id = x.sale_id where x.schedule_id = ra and x.run_date = v_due)
     and not exists (select 1 from messages m join recurring_invoice_runs x on x.sale_id = m.sale_id where x.schedule_id = ra and x.run_date = v_due),
    format('recurring_outbound_gate: issued, not sent, got %s', v);
  update orgs set send_mode = 'send' where id = mo;
end $$;

-- test: recurring_paused_on_end
-- Ending a full mandate pauses the business's schedules (and nobody signed in can restart them: the business is read-only);
-- the tick leaves a read-only business's schedules alone even if one is still active.
do $$
declare mo uuid := tests.id('mo'); ra uuid := tests.id('ra'); c uuid; v jsonb; v_runs bigint;
begin
  c := (select id from practice_clients where org_id = mo and mode = 'full');
  assert (select status from recurring_invoices where id = ra) = 'active', 'recurring_paused_on_end: active before';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_end_mandate(c, '{"reason": "Client moved to another firm"}');
  perform tests.as_postgres();
  assert (select read_only_at is not null from orgs where id = mo) and (select status from recurring_invoices where id = ra) = 'paused',
    'recurring_paused_on_end: paused';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.recurring_set_status(%L, %L)', ra, 'active'), '%read-only%');
  perform tests.as_postgres();
  -- Still active by some other route: the tick skips a read-only business.
  update recurring_invoices set status = 'active' where id = ra;
  v_runs := (select count(*) from recurring_invoice_runs where schedule_id = ra);
  v := private.recurring_tick((select next_run + 1 from recurring_invoices where id = ra)::timestamp at time zone 'UTC' + interval '12 hours');
  assert (select count(*) from recurring_invoice_runs where schedule_id = ra) = v_runs and v = '{"issued": 0, "sent": 0, "failed": 0}',
    'recurring_paused_on_end: a read-only business is skipped';
  update recurring_invoices set status = 'paused' where id = ra;
  -- org_pause_all on its own.
  update recurring_invoices set status = 'active' where id = tests.id('r');
  perform private.org_pause_all(tests.id('o'));
  assert (select status from recurring_invoices where id = tests.id('r')) = 'paused', 'recurring_paused_on_end: org_pause_all';
end $$;

-- test: recurring_rpcs_permission
-- The RPCs need record_sales in the schedule's business. The list shows each schedule with its customer and last 12 runs;
-- pausing and resuming (a past next run moved to today or later, the failures forgotten); run now (today, the next run on
-- one period); an edit recomputes the next run only when the timing changes; a practice client must be one of the firm's.
do $$
declare o uuid := tests.id('o'); r uuid := tests.id('r'); r3 uuid := tests.id('r3'); v jsonb; p jsonb; v_today date := private.local_day(tests.id('o'), now());
  r9 uuid; v_next date; pr uuid := tests.id('pr'); pc uuid;
begin
  p := pg_temp.sched(tests.id('cust_a'), 1, '2026-12-01');
  perform tests.as_user(tests.id('cashier'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p), '%record sales%');
  perform tests.throws(format('select public.recurring_list(%L)', o), '%record sales%');
  perform tests.throws(format('select public.recurring_set_status(%L, %L)', r, 'paused'), '%record sales%');
  perform tests.throws(format('select public.recurring_run_now(%L)', r), '%record sales%');
  perform tests.as_user(tests.id('outsider'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p), '%not a member%');
  perform tests.throws(format('select public.recurring_list(%L)', o), '%not a member%');
  perform tests.throws(format('select public.recurring_run_now(%L)', r), '%not a member%');
  perform tests.as_anon();
  perform tests.throws(format('select public.recurring_list(%L)', o), '%permission denied%');

  -- The list: the business's schedules, each with its customer and runs (newest first, 12 at most).
  perform tests.as_postgres();
  insert into recurring_invoice_runs (schedule_id, run_date, status, error)
  select r, d::date, 'failed', 'old' from generate_series('2024-01-28'::date, '2025-03-28'::date, interval '1 month') d;
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_list(o);
  perform tests.as_postgres();
  assert jsonb_array_length(v) = (select count(*) from recurring_invoices where org_id = o)
     and (select jsonb_array_length(e->'runs') = 12 and e->'runs'->0->>'run_date' = '2026-02-28' and e->'runs'->0->>'number' like 'INV-%'
                 and e->'runs'->0->>'status' = 'sent' and e->'runs'->11->>'run_date' = '2024-06-28'
                 and e->>'customer_name' = 'Kola Client' and e->'lines'->1->>'once' = 'true'
          from jsonb_array_elements(v) e where e->>'id' = r::text), 'recurring_rpcs_permission: the list';

  -- Resume a schedule paused after failures: its past day moves to today or later and the failures are forgotten.
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_set_status(r3, 'active');
  assert v->>'status' = 'active' and (v->>'failures')::int = 0 and v->>'last_error' is null and (v->>'next_run')::date >= v_today
     and (v->>'next_run')::date < v_today + 32, 'recurring_rpcs_permission: resumed';
  v := public.recurring_set_status(r3, 'paused');
  assert v->>'status' = 'paused', 'recurring_rpcs_permission: paused';
  perform tests.throws(format('select public.recurring_set_status(%L, %L)', r3, 'stopped'), '%active, paused or ended%');

  -- Run now: a schedule next due next month is issued today and its next run moves one month on.
  v := public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, (date_trunc('month', v_today) + interval '1 month')::date));
  r9 := (v->>'id')::uuid;
  v_next := (v->>'next_run')::date;
  v := public.recurring_run_now(r9);
  perform tests.as_postgres();
  assert v->>'status' = 'sent' and (select issue_date from sales where id = (v->>'sale_id')::uuid) = v_today
     and (select next_run from recurring_invoices where id = r9) = private.recurring_next('monthly', 1, v_next)
     and (select run_date from recurring_invoice_runs where schedule_id = r9) = v_today and v->'schedule'->>'status' = 'active',
    'recurring_rpcs_permission: run now';
  perform tests.as_user(tests.id('owner'));
  perform tests.throws(format('select public.recurring_run_now(%L)', r9), '%already%');
  -- An edit of the lines keeps the next run; a new day recomputes it.
  v := public.recurring_save(o, pg_temp.sched(tests.id('cust_d'), 1, (date_trunc('month', v_today) + interval '1 month')::date,
    jsonb_build_object('id', r9, 'lines', '[{"description": "Bigger retainer", "qty": 1, "unit_price": 150000}]'::jsonb)));
  perform tests.as_postgres();
  assert (v->>'next_run')::date = private.recurring_next('monthly', 1, v_next) and v->'lines'->0->>'vat_treatment' = 'standard'
     and v->'lines'->0->>'once' = 'false', 'recurring_rpcs_permission: lines edited, next run kept';
  perform tests.as_user(tests.id('owner'));
  -- Run now billed next month's invoice today, so the next is the month after: a new day keeps that period (no second
  -- invoice for next month).
  v := public.recurring_save(o, jsonb_build_object('id', r9, 'day_of_month', 15));
  assert (v->>'next_run')::date = (date_trunc('month', v_today) + interval '2 months')::date + 14 and v->'lines'->0->>'description' = 'Bigger retainer',
    'recurring_rpcs_permission: a new day changes only the day of the next invoice, the rest kept';
  v := public.recurring_set_status(r9, 'ended');
  perform tests.throws(format('select public.recurring_run_now(%L)', r9), '%ended%');

  -- A practice client: only one of a practice whose firm business this is.
  perform tests.as_postgres();
  pc := (select id from practice_clients where practice_id = pr limit 1);
  perform tests.as_user(tests.id('owner'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', o, p || jsonb_build_object('practice_client_id', pc)), '%firm%');
  perform tests.as_postgres();
  update practices set firm_org_id = o where id = pr;
  perform tests.as_user(tests.id('owner'));
  v := public.recurring_save(o, p || jsonb_build_object('practice_client_id', pc));
  assert (v->>'practice_client_id')::uuid = pc, 'recurring_rpcs_permission: a client of the firm';
  perform tests.as_postgres();
end $$;

-- test: recurring_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.issue_invoice_as(uuid, date, public.members)', 'private.send_document_as(uuid, text, text, public.members)',
    'private.recurring_first(text, integer, date)', 'private.recurring_next(text, integer, date)', 'private.recurring_run(uuid, date, public.members)',
    'private.recurring_tick(timestamp with time zone)', 'private.org_pause_all(uuid)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('recurring_helpers_revoked: %s', f);
  end loop;
  foreach f in array array['public.recurring_save(uuid, jsonb)', 'public.recurring_list(uuid)', 'public.recurring_set_status(uuid, text)',
    'public.recurring_run_now(uuid)', 'public.issue_invoice(uuid, date)', 'public.send_document(uuid, text, text)'] loop
    assert has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('recurring_helpers_revoked: %s for signed-in people', f);
  end loop;
  foreach f in array array['public.recurring_invoices', 'public.recurring_invoice_runs'] loop
    assert not has_table_privilege('authenticated', f, 'select') and not has_table_privilege('anon', f, 'select')
       and not has_table_privilege('authenticated', f, 'insert') and (select relrowsecurity from pg_class where oid = f::regclass), format('recurring_helpers_revoked: table %s', f);
  end loop;
  assert exists (select 1 from pg_trigger where tgrelid = 'public.recurring_invoices'::regclass and tgname = 'activity_row'), 'recurring_helpers_revoked: logged';
end $$;

rollback;
