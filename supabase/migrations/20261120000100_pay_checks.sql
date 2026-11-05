-- Counta · the bot checks a tax payment only once money has gone out (docs/lirs-etax-bot.md)
--
-- Until now every transfer account the bot fetched set off a check of the Lagos State payments page every 15 minutes for
-- three days, paid or not. Now the checks start only when Counta sees money go out for the bill: a payout from the Counta
-- wallet to the one-time account, a bank line in the books for the exact amount, or someone tapping "I've paid". From that
-- moment the bot checks at about 5 and 20 minutes, 1, 4 and 12 hours, 1 day and 46 hours, and never more than ten times in
-- any two days for a bill (a check tried again because the page was down counts). After the last one, whoever files tax is
-- told to take it up with LIRS.
-- The one-time account works for 15 minutes. Fetching one goes to the front of the bot's queue, the person who asked is told
-- when it is ready, no new one is fetched while the one on screen still works, and at most three are fetched for a bill in a
-- day. If no money has gone out 30 minutes after an account was given, the person who asked for it and the owner get an
-- email to log in and pay.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Data: each bill's round of checks
-- ---------------------------------------------------------------------------
-- pay_round_at: when Counta saw the money go out (the round's start); pay_round_source: tapped (I've paid), bank (a bank
-- line), wallet (a payout from the Counta wallet); pay_round_ref: the bank line or payout; pay_round_ended_at: when the
-- checks stopped with the bill still unpaid; pay_checks: when the bot looked at the payments page for it, kept three days.
alter table public.pit_person_years add column if not exists pay_round_at timestamptz;
alter table public.pit_person_years add column if not exists pay_round_source text check (pay_round_source is null or pay_round_source in ('tapped', 'bank', 'wallet'));
alter table public.pit_person_years add column if not exists pay_round_by uuid references public.members(id) on delete set null;
alter table public.pit_person_years add column if not exists pay_round_ref text check (pay_round_ref is null or length(pay_round_ref) <= 120);
alter table public.pit_person_years add column if not exists pay_round_ended_at timestamptz;
alter table public.pit_person_years add column if not exists pay_checks timestamptz[] not null default '{}';
create index if not exists pit_person_years_pay_round_by_fk on public.pit_person_years(pay_round_by);
-- One open job of a kind for a person and year, as before, except payment checks: one waiting, while a check from an
-- earlier round may still be running.
drop index if exists public.lirs_jobs_one_open;
create unique index if not exists lirs_jobs_one_open on public.lirs_jobs(org_id, accounting_year, person_id, kind)
  where status in ('queued', 'running') and kind <> 'status';
create unique index if not exists lirs_jobs_one_status on public.lirs_jobs(org_id, accounting_year, person_id) where kind = 'status' and status = 'queued';

-- ---------------------------------------------------------------------------
-- 2. The checks after money goes out
-- ---------------------------------------------------------------------------
-- In minutes from the moment the money went out.
create or replace function private.pit_check_ladder() returns int[]
language sql immutable set search_path = '' as $$
  select array[5, 20, 60, 240, 720, 1440, 2760]
$$;

-- The earliest time at or after p_at when one more check keeps a bill at ten or fewer in any two days.
create or replace function private.pit_check_slot(p_checks timestamptz[], p_at timestamptz) returns timestamptz
language sql stable set search_path = '' as $$
  select case when count(*) < 10 then p_at
    else greatest(p_at, (array_agg(c order by c desc))[10] + interval '48 hours' + interval '1 second') end
  from unnest(coalesce(p_checks, '{}'::timestamptz[])) c where c > p_at - interval '48 hours'
$$;

-- A time in a bill as Counta keeps it ("2026-03-31T10:00:00Z", or e-Tax's own wording), or null when it is not one.
create or replace function private.pit_ts(p text) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  return nullif(trim(coalesce(p, '')), '')::timestamptz;
exception when others then
  return null;
end $$;

-- When the account on screen stops working: Flutterwave's time, or 15 minutes after it was fetched.
create or replace function private.pit_transfer_expiry(p_transfer jsonb) returns timestamptz
language sql stable set search_path = public, private as $$
  select coalesce(private.pit_ts(p_transfer->>'expires_at'), private.pit_ts(p_transfer->>'fetched_at') + interval '15 minutes')
$$;

-- Adds a job (the one open job of its kind for the person, if there is one already). A login check, and a payment check, is
-- added again while one is running: the login may have changed since, and a new round of checks may have begun.
create or replace function private.lirs_enqueue(p_org uuid, p_year int, p_person uuid, p_kind text, p_request jsonb, p_by uuid, p_after interval default interval '0')
returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs;
begin
  select * into j from lirs_jobs where org_id = p_org and accounting_year is not distinct from p_year and person_id = p_person and kind = p_kind
    and status in ('queued', 'running') and (p_kind not in ('check', 'status') or status = 'queued');
  if found then return j; end if;
  insert into lirs_jobs (org_id, accounting_year, person_id, kind, request, created_by, not_before)
  values (p_org, p_year, p_person, p_kind, coalesce(p_request, '{}'::jsonb), p_by, now() + p_after)
  returning * into j;
  return j;
end $$;

-- Queues check number p_step of the round that began at p_round, at its time on the ladder: a little uneven (up to a tenth of
-- the gap before it earlier, a twentieth later), never in the past, never an eleventh in two days, and after the first,
-- never past the two days (a first check that has to wait for its turn, after rounds that ended unpaid, still runs).
-- Answers when it will run, or null when the round has no check left.
create or replace function private.pit_schedule_check(p_org uuid, p_year int, p_person uuid, p_round timestamptz, p_step int, p_by uuid)
returns timestamptz
language plpgsql security definer set search_path = public, private as $$
declare l int[] := private.pit_check_ladder(); v_gap numeric; v_at timestamptz; v_checks timestamptz[];
begin
  if p_round is null or p_step is null or p_step < 1 or p_step > array_length(l, 1) then return null; end if;
  v_gap := l[p_step] - case when p_step = 1 then 0 else l[p_step - 1] end;
  v_at := p_round + make_interval(secs => ((l[p_step] + (random() * 0.15 - 0.10) * v_gap) * 60)::float8);
  v_at := greatest(v_at, now() + interval '1 minute');
  select pay_checks into v_checks from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person;
  v_at := private.pit_check_slot(v_checks, v_at);
  if p_step > 1 and v_at > p_round + interval '48 hours' then return null; end if;
  perform private.lirs_enqueue(p_org, p_year, p_person, 'status', jsonb_build_object('round_at', p_round, 'step', p_step), p_by, v_at - now());
  return v_at;
end $$;

-- The checks stopped with the bill still unpaid: whoever files tax is told what Counta did and what to do next.
create or replace function private.pit_round_end(p_org uuid, p_year int, p_person uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare y public.pit_person_years; v_name text; v_n int; v_how text;
begin
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  if not found or y.paid_at is not null or y.pay_round_at is null or y.pay_round_ended_at is not null then return; end if;
  update pit_person_years set pay_round_ended_at = now() where org_id = p_org and accounting_year = p_year and person_id = p_person;
  update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'status' and status = 'queued';
  select name into v_name from pit_people where id = p_person;
  select count(*) into v_n from unnest(y.pay_checks) c where c >= y.pay_round_at;
  v_how := case y.pay_round_source when 'wallet' then 'the payment left the Counta wallet' when 'bank' then 'the payment showed in the bank feed'
    else coalesce((select display_name from members where id = y.pay_round_by), 'someone') || ' tapped I''ve paid' end;
  perform private.notify_perm(p_org, 'file_tax', 'books', v_name || '''s ' || p_year || ' bill is not showing as paid',
    'Counta checked the Lagos State payments page ' || v_n || case when v_n = 1 then ' time' else ' times' end || ' in the two days after ' || v_how
      || ', and bill ' || coalesce(y.bill->>'reference', '') || ' still shows unpaid. If it was paid, raise it with LIRS with the transfer receipt.',
    '/tax/pit?year=' || p_year, 'lirs-unpaid-' || p_person || '-' || p_year, null);
end $$;

-- What follows a check that found the bill unpaid, or could not read the page: the next check on the ladder, or, after the
-- last, the end of the round. A check from an earlier round, or for a bill paid since, has nothing after it.
create or replace function private.pit_check_next(j public.lirs_jobs) returns timestamptz
language plpgsql security definer set search_path = public, private as $$
declare y public.pit_person_years; v_round timestamptz := private.pit_ts(j.request->>'round_at'); v_at timestamptz;
begin
  select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
  if not found or y.paid_at is not null or v_round is null or y.pay_round_at is distinct from v_round or y.pay_round_ended_at is not null then return null; end if;
  v_at := private.pit_schedule_check(j.org_id, j.accounting_year, j.person_id, v_round, coalesce((j.request->>'step')::int, 0) + 1, j.created_by);
  if v_at is null then perform private.pit_round_end(j.org_id, j.accounting_year, j.person_id); end if;
  return v_at;
end $$;

-- Money has gone out for a person's bill (from the Counta wallet, a bank line in the books, or someone tapping "I've paid"):
-- the checks start, unless they are running already for this bill. Answers started, already, paid, no_bill or not_lirs.
create or replace function private.pit_pay_signal(p_org uuid, p_year int, p_person uuid, p_source text, p_ref text, p_by uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare y public.pit_person_years; v_by uuid; v_at timestamptz;
begin
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  if not found or y.bill is null or coalesce(y.bill->>'reference', '') = '' then return 'no_bill'; end if;
  if y.paid_at is not null then return 'paid'; end if;
  if not coalesce(private.pit_snapshot_person(p_org, p_year, p_person)->>'authority' = any(private.pit_bot_authorities()), false) then return 'not_lirs'; end if;
  if y.pay_round_at is not null and y.pay_round_ended_at is null then return 'already'; end if;
  update pit_person_years set pay_round_at = now(), pay_round_source = p_source, pay_round_ref = left(p_ref, 120), pay_round_by = p_by, pay_round_ended_at = null
  where org_id = p_org and accounting_year = p_year and person_id = p_person;
  update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'status' and status = 'queued';
  v_by := coalesce(p_by, (select created_by from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'pay_account'
    order by created_at desc limit 1));
  v_at := private.pit_schedule_check(p_org, p_year, p_person, now(), 1, v_by);
  if v_at is null then perform private.pit_round_end(p_org, p_year, p_person); end if;
  return 'started';
end $$;

-- The round of checks as the screens show it: when and how it began, how many checks so far and when the next one is.
create or replace function private.pit_pay_checks_of(p_org uuid, p_year int, p_person uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when y.pay_round_at is null then null else jsonb_build_object('round_at', y.pay_round_at, 'source', y.pay_round_source,
    'by', (select display_name from members where id = y.pay_round_by), 'ended_at', y.pay_round_ended_at,
    'active', y.pay_round_ended_at is null and y.paid_at is null,
    'checks', (select count(*) from unnest(y.pay_checks) c where c >= y.pay_round_at),
    'last_at', (select max(c) from unnest(y.pay_checks) c where c >= y.pay_round_at),
    'next_at', (select min(j.not_before) from lirs_jobs j where j.org_id = y.org_id and j.accounting_year = y.accounting_year and j.person_id = y.person_id
      and j.kind = 'status' and j.status = 'queued')) end
  from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.person_id = p_person
$$;

-- The latest job of each kind for a person, and the round of payment checks, as the screens show them.
create or replace function private.pit_jobs_of(p_org uuid, p_year int, p_person uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce((select jsonb_object_agg(j.kind, jsonb_build_object('id', j.id, 'status', j.status, 'error', j.error, 'attempts', j.attempts,
      'request', j.request - 'secret', 'created_at', j.created_at, 'updated_at', j.updated_at, 'finished_at', j.finished_at,
      'step', j.log->-1->>'step', 'note', j.log->-1->>'note'))
    from (select distinct on (kind) * from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person
          order by kind, created_at desc) j), '{}'::jsonb)
    || coalesce((select jsonb_build_object('pay_checks', c) from private.pit_pay_checks_of(p_org, p_year, p_person) c where c is not null), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------
-- 3. "I've paid", bank lines and wallet payouts start the checks
-- ---------------------------------------------------------------------------
-- Someone paid the bill from outside Counta (their own bank app, the payments page by card): whoever files tax or makes
-- payments taps "I've paid".
create or replace function public.pit_pay_tapped(p_org uuid, p_year int, p_person uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; y public.pit_person_years; x jsonb; v_out text;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'file_tax') or private.can_handle_money(p_org)) then
    raise exception 'Your role does not allow this (file tax, or make payments).' using errcode = '42501';
  end if;
  x := private.pit_snapshot_person(p_org, p_year, p_person);
  if x is null then raise exception 'That person is not in the % return.', p_year; end if;
  if not ((x->>'authority') = any(private.pit_bot_authorities())) then raise exception 'Counta checks payments on LIRS e-Tax only.'; end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person;
  if not found or y.bill is null or coalesce(y.bill->>'reference', '') = '' then raise exception 'There is no bill to pay yet.'; end if;
  if y.paid_at is not null then raise exception 'This bill is paid.'; end if;
  v_out := private.pit_pay_signal(p_org, p_year, p_person, 'tapped', null, m.id);
  return jsonb_build_object('result', v_out, 'pay_checks', private.pit_pay_checks_of(p_org, p_year, p_person));
end $$;

-- A debit in the books (a bank feed, a statement, the wallet's own feed) for the exact amount of an unpaid bill: the transfer
-- amount within two days of the account being given, or the bill's own amount any time after it was raised. A match that
-- is someone else's payment only starts a few checks; it never marks a bill paid. A bank line is never refused over this.
create or replace function private.pit_pay_from_bank_line() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare y record; v_amt numeric := round(-new.amount, 2);
begin
  begin
    for y in
      select py.accounting_year, py.person_id from pit_person_years py
      where py.org_id = new.org_id and py.paid_at is null and coalesce(py.bill->>'reference', '') <> ''
        and ((py.bill ? 'transfer' and round(coalesce(private.num(py.bill->'transfer'->>'amount'), 0), 2) = v_amt
              and new.line_date between (private.pit_ts(py.bill->'transfer'->>'fetched_at') at time zone 'Africa/Lagos')::date
                                    and (private.pit_ts(py.bill->'transfer'->>'fetched_at') at time zone 'Africa/Lagos')::date + 2)
          or (round(coalesce(private.num(py.bill->>'amount'), 0), 2) = v_amt
              and new.line_date >= coalesce((private.pit_ts(py.bill->>'generated_at') at time zone 'Africa/Lagos')::date, new.line_date)))
    loop
      perform private.pit_pay_signal(new.org_id, y.accounting_year, y.person_id, 'bank', new.id::text, null);
    end loop;
  exception when others then
    null;
  end;
  return new;
end $$;
drop trigger if exists bank_lines_pit_pay on public.bank_lines;
create trigger bank_lines_pit_pay after insert on public.bank_lines
  for each row when (new.amount < 0) execute function private.pit_pay_from_bank_line();

-- A payout from the Counta wallet to the one-time account of an unpaid bill, once Flutterwave has it.
create or replace function private.pit_pay_from_payout() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare y record;
begin
  if new.status not in ('processing', 'successful') or (tg_op = 'UPDATE' and old.status is not distinct from new.status) then return new; end if;
  begin
    for y in
      select py.accounting_year, py.person_id from pit_person_years py
      where py.org_id = new.org_id and py.paid_at is null and py.bill->'transfer'->>'account_number' = new.account_number
        and new.created_at >= private.pit_ts(py.bill->'transfer'->>'fetched_at') - interval '1 hour'
    loop
      perform private.pit_pay_signal(new.org_id, y.accounting_year, y.person_id, 'wallet', new.id::text, coalesce(new.approved_by, new.requested_by));
    end loop;
  exception when others then
    null;
  end;
  return new;
end $$;
drop trigger if exists payouts_pit_pay on public.payouts;
create trigger payouts_pit_pay after insert or update of status on public.payouts
  for each row execute function private.pit_pay_from_payout();

-- ---------------------------------------------------------------------------
-- 4. Asking for the account
-- ---------------------------------------------------------------------------
-- Asked by the tax-files function as the person. p_kind: file (whoever files tax; the app has made the computation), bill
-- (again, after a bill failed), pay_account (whoever files tax or handles money). p_request for pay_account:
-- {pay_with: transfer} (the tax wallet and the business account follow). A new account is not fetched while the one on
-- screen still works for three minutes or more, nor a fourth in a day.
create or replace function public.pit_lirs_queue(p_org uuid, p_year int, p_person uuid, p_kind text, p_request jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; y public.pit_person_years; x jsonb; j public.lirs_jobs; l public.pit_etax_logins; v_with text;
  v_exp timestamptz; v_open boolean; v_next timestamptz; v_tz text;
begin
  m := private.require(p_org, null);
  if p_kind not in ('file', 'bill', 'pay_account') then raise exception 'Unknown job.'; end if;
  if p_kind in ('file', 'bill') and not private.perm_of(m, 'file_tax') then raise exception 'Your role does not allow this (file tax).' using errcode = '42501'; end if;
  if p_kind = 'pay_account' and not (private.perm_of(m, 'file_tax') or private.can_handle_money(p_org)) then
    raise exception 'Your role does not allow this (file tax, or make payments).' using errcode = '42501';
  end if;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' then raise exception 'Approve the % return first.', p_year; end if;
  x := private.pit_snapshot_person(p_org, p_year, p_person);
  if x is null then raise exception 'That person is not in the % return.', p_year; end if;
  if not ((x->>'authority') = any(private.pit_bot_authorities())) then raise exception 'Counta files on LIRS e-Tax only: % files with %.', x->>'name', coalesce(x->>'authority_name', 'another state'); end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = x->>'authority';
  if l.id is null then raise exception 'Save %''s e-Tax login (Payer ID and password) under People first.', x->>'name'; end if;
  if l.status = 'failed' then raise exception '%''s e-Tax login did not work: %. Save it again under People.', x->>'name', coalesce(l.message, 'e-Tax refused it'); end if;

  if p_kind = 'file' then
    if y.status = 'filed' then raise exception '%''s % return is already filed.', x->>'name', p_year; end if;
    if y.status = 'sent' and exists (select 1 from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'file' and status in ('queued', 'running')) then
      return jsonb_build_object('job', (select to_jsonb(z) - 'log' - 'request' from lirs_jobs z where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'file' and status in ('queued', 'running')), 'already', true);
    end if;
    if py.soa_path is null then raise exception 'Attach the statement of accounts first.'; end if;
    if y.computation_path is null then raise exception 'The computation for % is not ready yet. Send again from the app, which makes it.', x->>'name'; end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'file', '{}'::jsonb, m.id);
    update pit_person_years set status = 'sent', flux_status = 'queued', flux_message = 'Waiting for Counta''s bot to file it on LIRS e-Tax.', flux_sent_at = now(),
      flux_updated_at = now(), updated_by = m.id, updated_at = now()
    where org_id = p_org and accounting_year = p_year and person_id = p_person;
  elsif p_kind = 'bill' then
    if y.status <> 'filed' then raise exception 'File the return first: the bill follows the filing.'; end if;
    if y.paid_at is not null then raise exception 'The % income tax of % is paid.', p_year, x->>'name'; end if;
    if private.pit_person_payable(p_org, p_year, p_person) <= 0 then raise exception 'There is no tax to pay for % in %.', x->>'name', p_year; end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'bill', '{}'::jsonb, m.id);
  else
    v_with := coalesce(nullif(p_request->>'pay_with', ''), 'transfer');
    if v_with in ('tax_wallet', 'business') then raise exception 'Paying from the tax wallet or the business account comes next. Pay this bill by transfer for now.'; end if;
    if v_with <> 'transfer' then raise exception 'Choose how to pay.'; end if;
    if y.status <> 'filed' or y.bill is null or coalesce(y.bill->>'reference', '') = '' then raise exception 'There is no bill to pay yet.'; end if;
    if y.paid_at is not null then raise exception 'This bill is paid.'; end if;
    select coalesce(nullif(timezone, ''), 'Africa/Lagos') into v_tz from orgs where id = p_org;
    v_open := exists (select 1 from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'pay_account' and status in ('queued', 'running'));
    -- The account on screen still works: pay into it rather than fetch another.
    v_exp := private.pit_transfer_expiry(y.bill->'transfer');
    if not v_open and y.bill ? 'transfer' and v_exp > now() + interval '3 minutes' then
      raise exception 'The account on screen works until %. Pay into it, or ask for a new one after then.', to_char(v_exp at time zone v_tz, 'HH24:MI');
    end if;
    -- Three accounts a day at most for a bill: each one is a visit to the Lagos State payments page.
    if not v_open and (select count(*) from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'pay_account'
        and status = 'done' and created_at > now() - interval '24 hours') >= 3 then
      select min(z.created_at) + interval '24 hours' into v_next from (select created_at from lirs_jobs where org_id = p_org and accounting_year = p_year
        and person_id = p_person and kind = 'pay_account' and status = 'done' and created_at > now() - interval '24 hours' order by created_at desc limit 3) z;
      raise exception 'Counta has fetched three accounts for this bill today. Ask again after %, or pay on the Lagos State payments page and tap I''ve paid.',
        to_char(v_next at time zone v_tz, 'HH24:MI');
    end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'pay_account', jsonb_build_object('pay_with', v_with), m.id);
  end if;
  return jsonb_build_object('job', to_jsonb(j) - 'log' - 'request', 'already', false);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The bot's queue
-- ---------------------------------------------------------------------------
-- The bot takes its next job (service role). A job left running for 20 minutes counts as a failed attempt. One job at a
-- time for a person (e-Tax keeps one session per account); fetching an account goes first, as someone is waiting to pay
-- into it within 15 minutes. A payment check that would be the eleventh in two days for a bill waits for its turn; one for
-- a bill paid meanwhile is dropped.
create or replace function public.svc_lirs_next(p_worker text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; s public.lirs_jobs; y public.pit_person_years; v_slot timestamptz; i int; v_ok boolean := false;
begin
  for s in select * from lirs_jobs where status = 'running' and locked_at < now() - interval '20 minutes' for update skip locked loop
    perform private.lirs_fail(s, 'The bot stopped without reporting back.', true);
  end loop;
  for i in 1..20 loop
    select * into j from lirs_jobs q where q.status = 'queued' and q.not_before <= now()
      and not exists (select 1 from lirs_jobs r where r.status = 'running' and r.org_id = q.org_id and r.person_id = q.person_id)
    order by (q.kind = 'pay_account') desc, q.not_before, q.created_at limit 1 for update skip locked;
    if not found then return jsonb_build_object('job', null); end if;
    if j.kind <> 'status' then v_ok := true; exit; end if;
    select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id for update;
    if not found or y.paid_at is not null then
      update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now() where id = j.id;
      continue;
    end if;
    v_slot := private.pit_check_slot(y.pay_checks, now());
    if v_slot <= now() then
      update pit_person_years set pay_checks = array(select c from unnest(pay_checks) c where c > now() - interval '3 days' order by c) || now()
      where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
      v_ok := true;
      exit;
    end if;
    update lirs_jobs set not_before = v_slot, updated_at = now() where id = j.id;
  end loop;
  if not v_ok then return jsonb_build_object('job', null); end if;
  -- When the login was last saved goes with the job, so a report about an older password does not mark a newer one.
  update lirs_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), worker = left(coalesce(p_worker, 'bot'), 120), error = null, updated_at = now(),
    request = (request - 'login_saved_at') || coalesce((select jsonb_build_object('login_saved_at', l.saved_at) from pit_etax_logins l
      where l.org_id = j.org_id and l.person_id = j.person_id and l.authority = 'SIRS:LA'), '{}'::jsonb)
  where id = j.id returning * into j;
  if j.kind = 'file' then
    update pit_person_years set flux_status = 'processing', flux_message = 'Counta''s bot is filing it on LIRS e-Tax.', flux_updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and status = 'sent';
  end if;
  return jsonb_build_object('job', jsonb_build_object('id', j.id, 'kind', j.kind, 'attempt', j.attempts, 'max_attempts', j.max_attempts, 'org_id', j.org_id,
    'year', j.accounting_year, 'person_id', j.person_id), 'context', private.lirs_context(j));
end $$;

-- A job that did not work: tried again later (p_retry), or given up, with what that means for the return. A payment check
-- is tried again only while the bill has had fewer than ten checks in two days; given up, the next check on the ladder
-- still goes ahead. A login check or a payment check that has another of its kind waiting (a login saved again, a new
-- round of checks) is not tried again: the one waiting takes its place.
create or replace function private.lirs_fail(j public.lirs_jobs, p_error text, p_retry boolean) returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_again boolean := p_retry and j.attempts < j.max_attempts;
begin
  if v_again and exists (select 1 from lirs_jobs o where o.id <> j.id and o.status = 'queued' and o.kind = j.kind and o.org_id = j.org_id
      and o.person_id = j.person_id and o.accounting_year is not distinct from j.accounting_year) then
    v_again := false;
  end if;
  if v_again and j.kind = 'status' then
    v_again := (select private.pit_check_slot(pay_checks, now()) <= now() from pit_person_years
      where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id);
    v_again := coalesce(v_again, false);
  end if;
  select name into v_name from pit_people where id = j.person_id;
  update lirs_jobs set status = case when v_again then 'queued' else 'failed' end, error = left(coalesce(p_error, 'Something went wrong on e-Tax.'), 2000),
    not_before = case when v_again then now() + make_interval(mins => 2 * power(2, greatest(j.attempts - 1, 0))::int) else not_before end,
    locked_at = null, updated_at = now(), finished_at = case when v_again then null else now() end
  where id = j.id returning * into j;
  if v_again then return j; end if;
  if j.kind = 'file' then
    update pit_person_years set status = 'approved', flux_status = 'send_failed', flux_message = left(j.error, 1000), flux_updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and status = 'sent';
    perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s ' || j.accounting_year || ' return was not filed', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'bill' then
    perform private.notify_perm(j.org_id, 'file_tax', 'books', 'Counta could not raise ' || v_name || '''s ' || j.accounting_year || ' bill', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'status' then
    perform private.pit_check_next(j);
  elsif j.kind = 'check' and not p_retry
    -- Only a check that never signed in: a sign-in that worked was reported as such, whatever failed after it.
    and not exists (select 1 from jsonb_array_elements(coalesce(j.log, '[]'::jsonb)) x where x->>'step' in ('signed_in', 'signed_in_again')) then
    update pit_etax_logins set status = 'failed', message = left(j.error, 1000), checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA' and status = 'saved'
      and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
  end if;
  return j;
end $$;

-- The bot reporting (service role). p: {step, note} to log a step; {login: verified | failed, login_message}; {tax_station:
-- {code, name}}; {portal: {...}} to keep e-Tax's ids; then {done: true, result} or {failed: true, error, retry}.
-- Results: file {return_id, tax_payer_id, confirmed_at}; bill {bill_id, reference, amount, agency, revenue, payer_id,
-- generated_at, paid}; pay_account {account_number, bank_name, account_name, amount, fee, expires_at} or {paid: true} when
-- the bill is paid already; status {paid, amount_paid, paid_at, reference}; check {payer_id, name, name_matches, tax_station,
-- warning}. What a job says about the login counts only for the login it started with. A transfer account no longer starts
-- any checks: those start when money goes out (private.pit_pay_signal).
create or replace function public.svc_lirs_report(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; y public.pit_person_years; r jsonb := coalesce(p->'result', '{}'::jsonb); v_name text; v_due numeric; v_ref text; v_tr jsonb;
  v_out jsonb; v_exp timestamptz; v_next timestamptz; v_tz text; v_user uuid;
begin
  select * into j from lirs_jobs where id = p_job for update;
  if not found then raise exception 'No such job.'; end if;
  if j.status <> 'running' then return jsonb_build_object('job_id', j.id, 'status', j.status, 'ignored', true); end if;
  select name into v_name from pit_people where id = j.person_id;
  if nullif(p->>'step', '') is not null then
    update lirs_jobs set log = (case when jsonb_array_length(log) >= 200 then log - 0 else log end)
        || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('at', now(), 'step', left(p->>'step', 80), 'note', left(nullif(p->>'note', ''), 500)))),
      locked_at = now(), updated_at = now()
    where id = j.id returning * into j;
  end if;
  if p->>'login' in ('verified', 'failed') then
    update pit_etax_logins set status = p->>'login', message = case when p->>'login' = 'failed' then left(coalesce(nullif(p->>'login_message', ''), 'e-Tax did not accept the Payer ID and password.'), 1000) end,
      checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA'
      and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
    if found and p->>'login' = 'failed' then
      perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s e-Tax login did not work',
        coalesce(nullif(p->>'login_message', ''), 'e-Tax did not accept the Payer ID and password.') || ' Save it again under People.',
        '/tax/pit' || coalesce('?year=' || j.accounting_year, ''), 'lirs-login-' || j.person_id || '-' || to_char(now(), 'YYYYMMDDHH24MI'), null);
    end if;
  end if;
  if jsonb_typeof(p->'tax_station') = 'object' and coalesce(p->'tax_station'->>'code', '') ~ '^[0-9]{3,10}$' then
    update pit_etax_logins set tax_station = p->'tax_station'->>'code', tax_station_name = left(nullif(p->'tax_station'->>'name', ''), 120), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA' and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
  end if;
  if jsonb_typeof(p->'portal') = 'object' then
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || ((p->'portal') - 'steps')
        || case when jsonb_typeof(p->'portal'->'steps') = 'object' then jsonb_build_object('steps', coalesce(portal->'steps', '{}'::jsonb) || (p->'portal'->'steps')) else '{}'::jsonb end
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
  end if;

  if coalesce((p->>'failed')::boolean, false) then
    j := private.lirs_fail(j, p->>'error', coalesce((p->>'retry')::boolean, true));
    return jsonb_build_object('job_id', j.id, 'status', j.status, 'not_before', j.not_before);
  end if;
  if not coalesce((p->>'done')::boolean, false) then return jsonb_build_object('job_id', j.id, 'status', j.status); end if;

  select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id for update;
  if j.kind = 'file' then
    if coalesce(r->>'return_id', '') !~ '^[0-9]{1,15}$' then raise exception 'result.return_id is e-Tax''s return reference.'; end if;
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('return_id', r->>'return_id',
      'tax_payer_id', r->>'tax_payer_id', 'confirmed_at', coalesce(nullif(r->>'confirmed_at', ''), now()::text)))
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('status', 'filed', 'ref', 'ETAX-' || (r->>'return_id'),
      'acknowledgement_ref', r->>'return_id', 'filed_at', coalesce(nullif(r->>'confirmed_at', ''), now()::text),
      'message', 'Filed and confirmed on LIRS e-Tax by Counta''s bot (return ' || (r->>'return_id') || ').'));
    if private.pit_person_payable(j.org_id, j.accounting_year, j.person_id) > 0 then
      perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'bill', '{}'::jsonb, j.created_by);
    end if;
  elsif j.kind = 'bill' then
    v_ref := nullif(trim(coalesce(r->>'reference', '')), '');
    if v_ref is null or v_ref !~ '^[0-9A-Za-z][0-9A-Za-z-]{5,60}$' then raise exception 'result.reference is the bill reference.'; end if;
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('bill', jsonb_build_object('amount', r->'amount', 'reference', v_ref,
      'agency', r->>'agency', 'revenue', coalesce(nullif(r->>'revenue', ''), 'Direct Assessment'), 'payer_id', r->>'payer_id',
      'payment_url', 'https://payments.lasg-public.com/tax-confirm?bill_type=' || v_ref, 'generated_at', coalesce(nullif(r->>'generated_at', ''), now()::text))));
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('bill_id', r->>'bill_id'))
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    -- A bill e-Tax already shows as paid (raised and paid before Counta's bot reported back).
    if coalesce((r->>'paid')::boolean, false) then
      v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
        'paid_at', now()::text, 'reference', v_ref, 'amount', r->'amount'))));
    end if;
  elsif j.kind = 'pay_account' and coalesce((r->>'paid')::boolean, false) then
    -- The payments page shows the bill paid already: nothing to pay.
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
      'paid_at', coalesce(nullif(r->>'paid_at', ''), now()::text), 'reference', coalesce(nullif(r->>'reference', ''), y.bill->>'reference'), 'amount', y.bill->'amount'))));
  elsif j.kind = 'pay_account' then
    if coalesce(regexp_replace(r->>'account_number', '\s', '', 'g'), '') !~ '^[0-9]{10}$' then raise exception 'result.account_number is the 10-digit account number.'; end if;
    if coalesce(private.num(r->>'amount'), 0) <= 0 then raise exception 'result.amount is the exact amount to transfer.'; end if;
    -- The account works for 15 minutes: Flutterwave's own time when it gives an earlier one (and one that has not already
    -- passed, which would be a misread), else 15 minutes from now.
    v_exp := private.pit_ts(r->>'expires_at');
    v_exp := case when v_exp is null or v_exp < now() + interval '2 minutes' then now() + interval '15 minutes' else least(v_exp, now() + interval '15 minutes') end;
    v_tr := jsonb_strip_nulls(jsonb_build_object('account_number', regexp_replace(r->>'account_number', '\s', '', 'g'), 'bank_name', left(coalesce(nullif(r->>'bank_name', ''), 'Flutterwave MFB'), 120),
      'account_name', left(coalesce(nullif(r->>'account_name', ''), 'LASG Collection'), 160), 'amount', round(private.num(r->>'amount'), 2),
      'fee', round(private.num(r->>'fee'), 2), 'expires_at', v_exp, 'fetched_at', now(), 'pay_with', j.request->>'pay_with',
      'channel', coalesce(nullif(r->>'channel', ''), 'Flutterwave'), 'asked_by', j.created_by));
    update pit_person_years set bill = coalesce(bill, '{}'::jsonb) || jsonb_build_object('transfer', v_tr)
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    -- Whoever asked is told it is ready, in case they stepped away while the bot was getting it.
    select coalesce(nullif(timezone, ''), 'Africa/Lagos') into v_tz from orgs where id = j.org_id;
    select user_id into v_user from members where id = j.created_by;
    perform private.notify(j.org_id, v_user, 'books', 'The account to pay ' || v_name || '''s tax is ready',
      'Transfer ₦' || to_char(round(private.num(r->>'amount'), 2), 'FM999,999,999,990.00') || ' by ' || to_char(v_exp at time zone v_tz, 'HH24:MI')
        || '. The account works for 15 minutes. Open Counta for the account number.',
      '/tax/pit?year=' || j.accounting_year, 'lirs-acct-' || j.id);
  elsif j.kind = 'status' then
    if coalesce((r->>'paid')::boolean, false) then
      v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
        'paid_at', coalesce(nullif(r->>'paid_at', ''), now()::text), 'reference', coalesce(nullif(r->>'reference', ''), y.bill->>'reference'),
        'amount', coalesce(r->'amount_paid', y.bill->'amount')))));
    else
      update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
      v_next := private.pit_check_next(j);
      return jsonb_build_object('job_id', j.id, 'status', j.status, 'next_check', v_next);
    end if;
  elsif j.kind = 'check' then
    -- What the check found: whose account it is on e-Tax, and anything the person should look at (another name on the
    -- account, no tax station Counta can place). The login was marked working when the bot signed in.
    update pit_etax_logins set etax_name = left(nullif(trim(coalesce(r->>'name', '')), ''), 200),
      message = left(nullif(trim(coalesce(r->>'warning', '')), ''), 1000), checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA' and status = 'verified' and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
  end if;
  -- Paid: the checks and transfer accounts still waiting are not needed any more, and the round of checks is over.
  if exists (select 1 from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and paid_at is not null) then
    update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and kind in ('status', 'pay_account') and status = 'queued' and id <> j.id;
    update pit_person_years set pay_round_ended_at = coalesce(pay_round_ended_at, now())
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and pay_round_at is not null;
  end if;
  update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
  return jsonb_build_object('job_id', j.id, 'status', j.status);
end $$;

-- ---------------------------------------------------------------------------
-- 6. The email 30 minutes after an account was given, when no money has gone out
-- ---------------------------------------------------------------------------
-- To whoever asked for the account and to the owner (once each, one email per account), with the same on the bell. Nothing
-- goes when money went out around that account, for the sample business, or while TaxStreem has email paused.
create or replace function private.pit_pay_remind() returns int
language plpgsql security definer set search_path = public, private as $$
declare y record; o public.orgs; v_tr jsonb; v_asker uuid; v_asker_name text; v_at text; v_amt text; v_link text; v_n int := 0; r record; v_lines jsonb;
  v_seen text[];
begin
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  for y in
    select py.org_id, py.accounting_year, py.person_id, py.bill, p.name person_name from pit_person_years py join pit_people p on p.id = py.person_id
    where py.paid_at is null and py.bill ? 'transfer' and py.bill->'transfer'->>'reminded_at' is null
      and private.pit_ts(py.bill->'transfer'->>'fetched_at') between now() - interval '1 day' and now() - interval '30 minutes'
      and not (py.pay_round_at is not null and (py.pay_round_ended_at is null or py.pay_round_at >= private.pit_ts(py.bill->'transfer'->>'fetched_at') - interval '1 hour'))
    for update of py skip locked
  loop
    update pit_person_years set bill = jsonb_set(bill, '{transfer,reminded_at}', to_jsonb(now()))
    where org_id = y.org_id and accounting_year = y.accounting_year and person_id = y.person_id;
    select * into o from orgs where id = y.org_id;
    continue when o.is_sample or not private.feature_on(o.id, 'email');
    v_tr := y.bill->'transfer';
    v_asker := coalesce(nullif(v_tr->>'asked_by', '')::uuid, (select created_by from lirs_jobs where org_id = y.org_id and accounting_year = y.accounting_year
      and person_id = y.person_id and kind = 'pay_account' and status = 'done' order by finished_at desc nulls last limit 1));
    select display_name into v_asker_name from members where id = v_asker;
    v_at := to_char(private.pit_ts(v_tr->>'fetched_at') at time zone coalesce(nullif(o.timezone, ''), 'Africa/Lagos'), 'HH24:MI');
    v_amt := '₦' || to_char(round(coalesce(private.num(v_tr->>'amount'), private.num(y.bill->>'amount'), 0), 2), 'FM999,999,999,990.00');
    v_seen := '{}';
    for r in
      select mb.id, mb.user_id, mb.display_name, lower(trim(coalesce(nullif(trim(coalesce(mb.email, '')), ''), u.email))) email, mb.id = v_asker is_asker
      from members mb left join auth.users u on u.id = mb.user_id
      where mb.org_id = y.org_id and mb.status = 'active' and (mb.id = v_asker or mb.role = 'owner')
      order by mb.id = v_asker desc, mb.created_at
    loop
      continue when r.email is null or r.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or r.email = any(v_seen);
      v_seen := v_seen || r.email;
      v_lines := jsonb_build_array(
        case when r.is_asker then 'You asked for an account at ' || v_at else coalesce(v_asker_name, 'Someone in ' || o.name) || ' asked for an account at ' || v_at end
          || ' to pay ' || y.person_name || '''s ' || y.accounting_year || ' Lagos State income tax of ' || v_amt
          || '. Counta has not seen the money go out, and that account has now expired.',
        'Log in to Counta, open Tax, then Personal income tax, and press Pay for a fresh account. Have your bank app ready first: each account works for 15 minutes.',
        'If the money has already gone, open the bill and tap I''ve paid, and Counta will confirm the payment with LIRS.');
      begin
        perform private.queue_message(y.org_id, 'email', r.email, 'alert', y.person_name || '''s ' || y.accounting_year || ' income tax is not paid yet',
          jsonb_build_object('kind', 'pit_pay_remind', 'person_name', r.display_name, 'business', o.name, 'heading', 'Pay ' || y.person_name || '''s ' || y.accounting_year || ' income tax',
            'lines', v_lines, 'button', 'Log in and pay', 'link', v_link || '/tax/pit?year=' || y.accounting_year, 'automatic', true,
            'footer', 'Counta sends this when a tax payment it set up for ' || o.name || ' has not gone through.'),
          null, null, v_asker);
        v_n := v_n + 1;
      exception when others then
        null;
      end;
      perform private.notify(y.org_id, r.user_id, 'books', y.person_name || '''s ' || y.accounting_year || ' income tax is not paid yet',
        'The account for it has expired. Press Pay for a fresh one, or tap I''ve paid if the money has gone.', '/tax/pit?year=' || y.accounting_year,
        'lirs-remind-' || y.person_id || '-' || y.accounting_year);
    end loop;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- 7. What was waiting
-- ---------------------------------------------------------------------------
-- The 15-minute checks still queued stop; accounts already given get their expiry and count as reminded, so nobody gets an
-- email about an account fetched before this.
update public.lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now(), error = 'Checks now start when money goes out.'
where kind = 'status' and status = 'queued' and not (request ? 'round_at');
update public.pit_person_years set bill = jsonb_set(bill, '{transfer}', (bill->'transfer') || jsonb_build_object('reminded_at', now(),
    'expires_at', coalesce(private.pit_ts(bill->'transfer'->>'expires_at'), private.pit_ts(bill->'transfer'->>'fetched_at') + interval '15 minutes')))
where bill ? 'transfer' and jsonb_typeof(bill->'transfer') = 'object' and bill->'transfer'->>'reminded_at' is null;

-- ---------------------------------------------------------------------------
-- 8. Who may call what, and the reminder's round
-- ---------------------------------------------------------------------------
revoke execute on function public.pit_pay_tapped(uuid, int, uuid), public.pit_lirs_queue(uuid, int, uuid, text, jsonb) from public, anon;
grant execute on function public.pit_pay_tapped(uuid, int, uuid), public.pit_lirs_queue(uuid, int, uuid, text, jsonb) to authenticated;
revoke execute on function public.svc_lirs_next(text), public.svc_lirs_report(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_lirs_next(text), public.svc_lirs_report(uuid, jsonb) to service_role;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and (p.proname like 'pit\_%' or p.proname like 'lirs\_%') and p.proname <> 'pit_doc_path_ok' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-pit-pay-remind';
    perform cron.schedule('counta-pit-pay-remind', '*/5 * * * *', $c$select private.pit_pay_remind() where exists (select 1 from public.pit_person_years
      where paid_at is null and bill ? 'transfer' and bill->'transfer'->>'reminded_at' is null)$c$);
  end if;
end $$;
