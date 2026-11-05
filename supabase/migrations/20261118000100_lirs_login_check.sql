-- Counta · the LIRS bot checks each e-Tax login as soon as it is saved (docs/lirs-etax-bot.md)
--
-- Saving a person's e-Tax login now queues a 'check' job: the bot signs in with it, notes whose account it is on e-Tax
-- and the tax station the profile names, and signs out. Nothing on e-Tax is changed. The person's row then shows the
-- login as working (with a warning when e-Tax has another name on the account, or no tax station Counta can place), or
-- as not working with e-Tax's reason. A check belongs to the login, not to a year.
-- A job also carries when the login was last saved, so a report about an older password never marks a newer one.
-- Companies are not touched. Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Data
-- ---------------------------------------------------------------------------
alter table public.lirs_jobs alter column accounting_year drop not null;
alter table public.lirs_jobs drop constraint if exists lirs_jobs_kind_check;
alter table public.lirs_jobs add constraint lirs_jobs_kind_check check (kind in ('file', 'bill', 'pay_account', 'status', 'check'));
alter table public.lirs_jobs drop constraint if exists lirs_jobs_year_check;
alter table public.lirs_jobs add constraint lirs_jobs_year_check check ((kind = 'check') = (accounting_year is null));
-- One check waiting per person (another may be running with the password saved before it).
create unique index if not exists lirs_jobs_one_check on public.lirs_jobs(org_id, person_id) where kind = 'check' and status = 'queued';

-- etax_name: the name e-Tax has on the account, as the last check found it.
alter table public.pit_etax_logins add column if not exists etax_name text check (etax_name is null or length(etax_name) <= 200);

-- ---------------------------------------------------------------------------
-- 2. Saving a login queues its check; the bot's functions know the check
-- ---------------------------------------------------------------------------

-- A person's e-Tax login as the screens show it: never the password.
create or replace function private.pit_etax_login_of(p_org uuid, p_person uuid, p_authority text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('payer_id', l.payer_id, 'status', l.status, 'message', l.message, 'tax_station', l.tax_station,
    'tax_station_name', l.tax_station_name, 'saved_at', l.saved_at, 'checked_at', l.checked_at,
    'saved_by', (select display_name from members where id = l.saved_by), 'etax_name', l.etax_name,
    'checking', exists (select 1 from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check' and j.status in ('queued', 'running')),
    'check_error', case when l.status = 'saved' then (select j.error from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check'
      and j.status = 'failed' and j.finished_at >= l.saved_at order by j.finished_at desc limit 1) end)
  from pit_etax_logins l where l.org_id = p_org and l.person_id = p_person and l.authority = coalesce(p_authority, 'SIRS:LA')
$$;

-- Adds a job (the one open job of its kind for the person, if there is one already).
create or replace function private.lirs_enqueue(p_org uuid, p_year int, p_person uuid, p_kind text, p_request jsonb, p_by uuid, p_after interval default interval '0')
returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs;
begin
  -- A login check has no year, and is added again while one is running: the login may have changed since it started.
  select * into j from lirs_jobs where org_id = p_org and accounting_year is not distinct from p_year and person_id = p_person and kind = p_kind
    and status in ('queued', 'running') and (p_kind <> 'check' or status = 'queued');
  if found then return j; end if;
  insert into lirs_jobs (org_id, accounting_year, person_id, kind, request, created_by, not_before)
  values (p_org, p_year, p_person, p_kind, coalesce(p_request, '{}'::jsonb), p_by, now() + p_after)
  returning * into j;
  return j;
end $$;

-- Saving (service role, from the tax-files function after the check above): the password goes into Supabase Vault.
-- p: {payer_id, password, tax_station?, tax_station_name?, member_id}
-- The bot then checks it (a 'check' job): it signs in, notes whose account it is and the tax station, and signs out.
create or replace function public.svc_pit_etax_login_save(p_org uuid, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.pit_etax_logins; v_pid text := upper(regexp_replace(coalesce(p->>'payer_id', ''), '\s', '', 'g')); v_pw text := p->>'password'; v_sid uuid;
  v_st text := nullif(regexp_replace(coalesce(p->>'tax_station', ''), '\s', '', 'g'), '');
begin
  if not exists (select 1 from pit_people where id = p_person and org_id = p_org) then raise exception 'That person is not in this business.'; end if;
  if v_pid !~ '^[NC]-[0-9]{4,12}$' then raise exception 'A Payer ID is N- (or C-) followed by digits, as e-Tax shows it.'; end if;
  if v_pw is null or length(v_pw) = 0 or length(v_pw) > 200 then raise exception 'Enter the e-Tax password (at most 200 characters).'; end if;
  if v_st is not null and v_st !~ '^[0-9]{3,10}$' then raise exception 'Choose the tax station.'; end if;
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = 'SIRS:LA' for update;
  if l.secret_id is not null and exists (select 1 from vault.secrets where id = l.secret_id) then
    perform vault.update_secret(l.secret_id, v_pw);
    v_sid := l.secret_id;
  else
    v_sid := vault.create_secret(v_pw, 'etax:' || gen_random_uuid()::text, 'LIRS e-Tax password of a person in a Counta business');
  end if;
  insert into pit_etax_logins (org_id, person_id, authority, payer_id, secret_id, tax_station, tax_station_name, status, message, saved_by, saved_at, checked_at, updated_at)
  values (p_org, p_person, 'SIRS:LA', v_pid, v_sid, v_st, left(nullif(trim(coalesce(p->>'tax_station_name', '')), ''), 120), 'saved', null,
    nullif(p->>'member_id', '')::uuid, now(), null, now())
  on conflict (org_id, person_id, authority) do update set payer_id = excluded.payer_id, secret_id = excluded.secret_id,
    tax_station = coalesce(excluded.tax_station, case when pit_etax_logins.payer_id = excluded.payer_id then pit_etax_logins.tax_station end),
    tax_station_name = coalesce(excluded.tax_station_name, case when pit_etax_logins.payer_id = excluded.payer_id then pit_etax_logins.tax_station_name end),
    status = 'saved', message = null, etax_name = case when pit_etax_logins.payer_id = excluded.payer_id then pit_etax_logins.etax_name end,
    saved_by = excluded.saved_by, saved_at = now(), checked_at = null, updated_at = now();
  perform private.lirs_enqueue(p_org, null, p_person, 'check', '{}'::jsonb, nullif(p->>'member_id', '')::uuid);
  return private.pit_etax_login_of(p_org, p_person, 'SIRS:LA');
end $$;

-- What the bot needs for a job. The password is read from Vault here, for the bot only.
create or replace function private.lirs_context(j public.lirs_jobs) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare py public.pit_years; y public.pit_person_years; x jsonb; l public.pit_etax_logins; o public.orgs; v_pw text; v_needs jsonb := private.pit_relief_needs();
  v_reliefs jsonb := '[]'::jsonb; k text; v numeric;
begin
  select * into py from pit_years where org_id = j.org_id and accounting_year = j.accounting_year;
  select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
  x := private.pit_snapshot_person(j.org_id, j.accounting_year, j.person_id);
  if x is null and j.kind = 'check' then
    select jsonb_build_object('person_id', p.id, 'name', p.name, 'tin', p.tin, 'authority', 'SIRS:LA') into x from pit_people p where p.id = j.person_id;
  end if;
  select * into l from pit_etax_logins where org_id = j.org_id and person_id = j.person_id and authority = coalesce(x->>'authority', 'SIRS:LA');
  select * into o from orgs where id = j.org_id;
  if l.secret_id is not null then select decrypted_secret into v_pw from vault.decrypted_secrets where id = l.secret_id; end if;
  -- Each relief Counta counted, with e-Tax's form and the files for each of its fields.
  for k, v in select key, private.num(value #>> '{}') from jsonb_each(coalesce(x->'reliefs_claimed', '{}'::jsonb)) loop
    continue when coalesce(v, 0) <= 0;
    v_reliefs := v_reliefs || jsonb_build_array(jsonb_build_object('relief', k, 'label', v_needs->k->>'label', 'amount', v, 'portal_type', v_needs->k->'portal',
      'details', (select coalesce(jsonb_object_agg(f, coalesce(y.pension_details, '{}'::jsonb)->f), '{}'::jsonb) from jsonb_array_elements_text(coalesce(v_needs->k->'fields', '[]'::jsonb)) f),
      'files', (select coalesce(jsonb_agg(jsonb_build_object('doc', d->>'id', 'label', d->>'label', 'portal_field', d->>'portal_field',
          'paths', (select coalesce(jsonb_agg(e->>'path'), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(y.relief_docs->k) = 'array' then y.relief_docs->k else '[]'::jsonb end) e
                    where e->>'doc' = d->>'id'))), '[]'::jsonb)
        from jsonb_array_elements(coalesce(v_needs->k->'docs', '[]'::jsonb)) d)));
  end loop;
  return jsonb_build_object(
    'login', jsonb_build_object('payer_id', l.payer_id, 'password', v_pw, 'tax_station', l.tax_station, 'tax_station_name', l.tax_station_name),
    'taxpayer', jsonb_build_object('person_id', j.person_id, 'name', x->>'name', 'tin', x->>'tin', 'authority', x->>'authority', 'role', x->>'role', 'share_pct', x->'share_pct'),
    'year', j.accounting_year, 'yoa', j.accounting_year + 1,
    'org', jsonb_build_object('name', o.name, 'address', coalesce(o.registered_office, o.address), 'email', o.email, 'phone', o.phone),
    'portal', coalesce(y.portal, '{}'::jsonb),
    'return', case when j.kind = 'file' then jsonb_build_object(
        'income', x->'income_fields', 'accommodation', coalesce(y.accommodation, x->'accommodation', '{}'::jsonb),
        'household_staff', coalesce(y.household_staff, '[]'::jsonb), 'staff_roles', private.pit_staff_roles(), 'reliefs', v_reliefs,
        'reliefs_on_record', (select coalesce(jsonb_agg(jsonb_build_object('relief', r.key, 'label', v_needs->r.key->>'label', 'amount', r.value)), '[]'::jsonb)
          from jsonb_each(coalesce(x->'reliefs_claimed', '{}'::jsonb)) r where v_needs->r.key->'portal' = 'false'::jsonb),
        'assets', (select coalesce(jsonb_agg(jsonb_build_object('number', a->>'number', 'name', a->>'name', 'category', a->>'category', 'class', a->>'class',
            'cost', a->'qce', 'first_year', a->'first_year', 'acquired_on', a->>'in_use', 'disposed', a->'disposed')), '[]'::jsonb)
          from jsonb_array_elements(coalesce(py.snapshot->'computation'->'business'->'ca'->'assets', '[]'::jsonb)) a where not coalesce((a->>'disposed')::boolean, false)),
        'files', jsonb_build_object('statement_of_accounts', py.soa_path, 'computation', y.computation_path)) end,
    'bill', case when j.kind in ('bill', 'pay_account', 'status') then jsonb_build_object('amount', private.pit_person_payable(j.org_id, j.accounting_year, j.person_id),
        'existing', y.bill, 'revenue_code', '32102', 'start_date', make_date(j.accounting_year, 1, 1), 'end_date', make_date(j.accounting_year, 12, 31),
        'remark', left(coalesce(o.name, '') || ' ' || j.accounting_year || ' personal income tax (direct assessment)', 200)) end,
    'request', j.request);
end $$;

-- The bot takes its next job (service role). A job left running for 20 minutes counts as a failed attempt. One person at a
-- time: e-Tax keeps one session per account.
create or replace function public.svc_lirs_next(p_worker text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; s public.lirs_jobs;
begin
  for s in select * from lirs_jobs where status = 'running' and locked_at < now() - interval '20 minutes' for update skip locked loop
    perform private.lirs_fail(s, 'The bot stopped without reporting back.', true);
  end loop;
  select * into j from lirs_jobs q where q.status = 'queued' and q.not_before <= now()
    and not exists (select 1 from lirs_jobs r where r.status = 'running' and r.org_id = q.org_id and r.person_id = q.person_id)
  order by q.not_before, q.created_at limit 1 for update skip locked;
  if not found then return jsonb_build_object('job', null); end if;
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

-- The bot reporting (service role). p: {step, note} to log a step; {login: verified | failed, login_message}; {tax_station:
-- {code, name}}; {portal: {...}} to keep e-Tax's ids; then {done: true, result} or {failed: true, error, retry}.
-- Results: file {return_id, tax_payer_id, confirmed_at}; bill {bill_id, reference, amount, agency, revenue, payer_id,
-- generated_at, paid}; pay_account {account_number, bank_name, account_name, amount, fee, expires_at} or {paid: true} when
-- the bill is paid already; status {paid, amount_paid, paid_at, reference}; check {payer_id, name, name_matches, tax_station,
-- warning}. What a job says about the login counts only for the login it started with.
create or replace function public.svc_lirs_report(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; y public.pit_person_years; r jsonb := coalesce(p->'result', '{}'::jsonb); v_name text; v_due numeric; v_ref text; v_tr jsonb;
  v_since timestamptz; v_out jsonb;
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
    v_tr := jsonb_strip_nulls(jsonb_build_object('account_number', regexp_replace(r->>'account_number', '\s', '', 'g'), 'bank_name', left(coalesce(nullif(r->>'bank_name', ''), 'Flutterwave MFB'), 120),
      'account_name', left(coalesce(nullif(r->>'account_name', ''), 'LASG Collection'), 160), 'amount', round(private.num(r->>'amount'), 2),
      'fee', round(private.num(r->>'fee'), 2), 'expires_at', nullif(r->>'expires_at', '')::timestamptz, 'fetched_at', now(), 'pay_with', j.request->>'pay_with',
      'channel', coalesce(nullif(r->>'channel', ''), 'Flutterwave')));
    update pit_person_years set bill = coalesce(bill, '{}'::jsonb) || jsonb_build_object('transfer', v_tr)
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', jsonb_build_object('since', now()), j.created_by, interval '15 minutes');
  elsif j.kind = 'status' then
    if coalesce((r->>'paid')::boolean, false) then
      v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
        'paid_at', coalesce(nullif(r->>'paid_at', ''), now()::text), 'reference', coalesce(nullif(r->>'reference', ''), y.bill->>'reference'),
        'amount', coalesce(r->'amount_paid', y.bill->'amount')))));
    else
      v_since := coalesce(nullif(j.request->>'since', '')::timestamptz, (y.bill->'transfer'->>'fetched_at')::timestamptz, j.created_at);
      if v_since > now() - interval '3 days' then
        update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
        perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', jsonb_build_object('since', v_since), j.created_by, interval '15 minutes');
        return jsonb_build_object('job_id', j.id, 'status', j.status, 'next_check', 'in 15 minutes');
      end if;
      perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s ' || j.accounting_year || ' bill is not showing as paid',
        'e-Tax still shows bill ' || coalesce(y.bill->>'reference', '') || ' unpaid three days on. If it was paid, raise it with LIRS with the transfer receipt.',
        '/tax/pit?year=' || j.accounting_year, 'lirs-unpaid-' || j.person_id || '-' || j.accounting_year, null);
    end if;
  elsif j.kind = 'check' then
    -- What the check found: whose account it is on e-Tax, and anything the person should look at (another name on the
    -- account, no tax station Counta can place). The login was marked working when the bot signed in.
    update pit_etax_logins set etax_name = left(nullif(trim(coalesce(r->>'name', '')), ''), 200),
      message = left(nullif(trim(coalesce(r->>'warning', '')), ''), 1000), checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA' and status = 'verified' and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
  end if;
  -- Paid: the checks and transfer accounts still waiting are not needed any more.
  if exists (select 1 from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and paid_at is not null) then
    update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and kind in ('status', 'pay_account') and status = 'queued' and id <> j.id;
  end if;
  update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
  return jsonb_build_object('job_id', j.id, 'status', j.status);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Logins saved before this, and not used yet, are checked now
-- ---------------------------------------------------------------------------
do $$
declare l record;
begin
  for l in select org_id, person_id, saved_by from public.pit_etax_logins where status = 'saved' and checked_at is null loop
    perform private.lirs_enqueue(l.org_id, null, l.person_id, 'check', '{}'::jsonb, l.saved_by);
  end loop;
end $$;
