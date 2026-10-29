-- 9 November 2026 (asked 29 October): Mono lookups that fail are kept with Mono's reply, a Tax ID check that could not run
-- stays "not checked" instead of reading as "not on the NRS record", and the sample business is made once per person.

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. Lookups that failed or found no record, with what Mono answered
-- ---------------------------------------------------------------------------------------------------------------------
-- One row for each CAC search, CAC record, CAC status report, Tax ID or NIN lookup that did not go through, or that came
-- back with no record. Mono's message is kept with every run of five or more digits cut to its last four, and email
-- addresses removed, so an NIN or a Tax ID Mono echoes back is never stored whole. TaxStreem's admin portal shows these
-- under Activity, "What failed". Rows go after 120 days.
create table if not exists public.lookup_failures (
  id bigserial primary key,
  at timestamptz not null default now(),
  service text not null default 'mono',
  kind text not null check (kind in ('cac_search', 'cac_record', 'cac_status_report', 'tin', 'nin')),
  outcome text not null default 'failed' check (outcome in ('failed', 'no_record')),
  org_id uuid references public.orgs(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  http_status int,
  seconds numeric(6,1),
  message text
);
create index if not exists lookup_failures_at on public.lookup_failures(at desc);
create index if not exists lookup_failures_org_at on public.lookup_failures(org_id, at desc) where org_id is not null;
alter table public.lookup_failures enable row level security;
revoke all on public.lookup_failures from public, anon, authenticated;
revoke all on sequence public.lookup_failures_id_seq from public, anon, authenticated;

-- Long numbers cut to their last four digits; email addresses removed.
create or replace function private.lookup_mask(p text) returns text
language sql immutable set search_path = public as $$
  select left(regexp_replace(regexp_replace(coalesce(p, ''), '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+', '[email]', 'g'),
                              '[0-9]+([0-9]{4})', '•••\1', 'g'), 300)
$$;

-- Written by the mono function. A Tax ID check that did not go through is marked "failed" on its row in tin_checks, so it
-- is never read as an answer.
create or replace function public.svc_lookup_failure(p jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_kind text := p->>'kind'; v_outcome text := coalesce(nullif(p->>'outcome', ''), 'failed'); v_org uuid; v_user uuid; v_check uuid;
begin
  if v_kind is null or v_kind not in ('cac_search', 'cac_record', 'cac_status_report', 'tin', 'nin') then raise exception 'Unknown lookup.'; end if;
  if v_outcome not in ('failed', 'no_record') then raise exception 'Unknown outcome.'; end if;
  v_org := case when coalesce(p->>'org_id', '') ~* '^[0-9a-f-]{36}$' then (p->>'org_id')::uuid end;
  v_user := case when coalesce(p->>'user_id', '') ~* '^[0-9a-f-]{36}$' then (p->>'user_id')::uuid end;
  v_check := case when coalesce(p->>'check_id', '') ~* '^[0-9a-f-]{36}$' then (p->>'check_id')::uuid end;
  if v_org is not null and not exists (select 1 from orgs where id = v_org) then v_org := null; end if;
  if v_user is not null and not exists (select 1 from auth.users where id = v_user) then v_user := null; end if;
  insert into lookup_failures (service, kind, outcome, org_id, user_id, http_status, seconds, message)
  values (left(coalesce(nullif(p->>'service', ''), 'mono'), 20), v_kind, v_outcome, v_org, v_user,
          case when coalesce(p->>'http_status', '') ~ '^[0-9]{3}$' then (p->>'http_status')::int end,
          case when coalesce(p->>'seconds', '') ~ '^[0-9]+(\.[0-9]+)?$' then least((p->>'seconds')::numeric, 99999)::numeric(6,1) end,
          nullif(private.lookup_mask(p->>'message'), ''));
  if v_outcome = 'failed' and v_check is not null then
    update tin_checks set outcome = 'failed' where id = v_check and outcome = 'asked';
  end if;
  delete from lookup_failures where at < now() - interval '120 days';
end $$;
revoke all on function public.svc_lookup_failure(jsonb) from public, anon, authenticated;
grant execute on function public.svc_lookup_failure(jsonb) to service_role;
revoke all on function private.lookup_mask(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. The admin portal: failed lookups under "What failed", and Tax ID checks counted by outcome
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function private.platform_failures(p_since timestamptz, p_org uuid default null, p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(f order by (f->>'at') desc), '[]'::jsonb) from (
    select f from (
      select jsonb_build_object('at', m.updated_at, 'kind', 'message', 'what', initcap(m.channel) || ' ' || m.template, 'org_id', m.org_id, 'business', o.name,
               'error', left(coalesce(m.error, 'Failed'), 300)) f
      from messages m join orgs o on o.id = m.org_id where m.status = 'failed' and m.updated_at >= p_since and (p_org is null or m.org_id = p_org)
      union all
      select jsonb_build_object('at', coalesce(c.ended_at, c.created_at), 'kind', 'call', 'what', replace(c.kind, '_', ' ') || ' call', 'org_id', c.org_id, 'business', o.name,
               'error', left(coalesce(c.error, 'The call failed'), 300))
      from voice_calls c left join orgs o on o.id = c.org_id where c.status = 'failed' and c.created_at >= p_since and (p_org is null or c.org_id = p_org)
      union all
      select jsonb_build_object('at', p.created_at, 'kind', 'payout', 'what', 'Payout of ₦' || to_char(p.amount, 'FM999,999,999,990.00'), 'org_id', p.org_id, 'business', o.name,
               'error', left(coalesce(p.error, 'The payout failed'), 300))
      from payouts p join orgs o on o.id = p.org_id where p.status in ('failed', 'reversed') and p.created_at >= p_since and (p_org is null or p.org_id = p_org)
      union all
      select jsonb_build_object('at', r.created_at, 'kind', 'payment', 'what', 'Payment request of ₦' || to_char(r.amount, 'FM999,999,999,990.00'), 'org_id', r.org_id, 'business', o.name,
               'error', left(coalesce(r.error, 'Could not be created'), 300))
      from payment_requests r join orgs o on o.id = r.org_id where r.status = 'failed' and r.created_at >= p_since and (p_org is null or r.org_id = p_org)
      union all
      select jsonb_build_object('at', w.created_at, 'kind', 'wallet', 'what', 'Wallet on ' || w.rail, 'org_id', w.org_id, 'business', o.name,
               'error', left(coalesce(w.error, 'Could not be opened'), 300))
      from wallets w join orgs o on o.id = w.org_id where w.status = 'failed' and w.created_at >= p_since and (p_org is null or w.org_id = p_org)
      union all
      select jsonb_build_object('at', e.received_at, 'kind', 'webhook', 'what', e.rail || ' ' || coalesce(e.event, 'event'), 'org_id', e.org_id, 'business', o.name,
               'error', left(e.error, 300))
      from payment_events e left join orgs o on o.id = e.org_id where e.error is not null and e.received_at >= p_since and (p_org is null or e.org_id = p_org)
      union all
      select jsonb_build_object('at', r.created_at, 'kind', 'ai', 'what', 'Reading invoice ' || r.ref, 'org_id', r.org_id, 'business', o.name,
               'error', left(r.ai_error, 300))
      from receipts r join orgs o on o.id = r.org_id where r.ai_error is not null and r.created_at >= p_since and (p_org is null or r.org_id = p_org)
      union all
      select jsonb_build_object('at', a.started_at, 'kind', 'books', 'what', a.agent || ' ' || a.action, 'org_id', a.org_id, 'business', o.name,
               'error', left(a.error, 300))
      from agent_runs a left join orgs o on o.id = a.org_id where a.error is not null and a.started_at >= p_since and (p_org is null or a.org_id = p_org)
      union all
      select jsonb_build_object('at', l.at, 'kind', 'lookup',
               'what', case l.kind when 'cac_search' then 'CAC search' when 'cac_record' then 'CAC record' when 'cac_status_report' then 'CAC status report'
                                   when 'tin' then 'Tax ID check' when 'nin' then 'NIN check' else l.kind end
                       || case when l.outcome = 'no_record' then ': no record' else ' did not go through' end,
               'org_id', l.org_id, 'business', o.name,
               'error', left(concat_ws(' · ', initcap(l.service) || coalesce(' answered ' || l.http_status, ' did not answer'),
                                      case when l.seconds is not null then l.seconds || ' s' end, l.message), 300))
      from lookup_failures l left join orgs o on o.id = l.org_id where l.at >= p_since and (p_org is null or l.org_id = p_org)
    ) x order by (f->>'at') desc limit greatest(1, least(p_limit, 500))
  ) y
$$;


create or replace function public.admin_activity(p_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
begin
  perform private.require_staff();
  return jsonb_build_object('since', v_since,
    'messages', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select channel || ':' || status k, count(*) n from messages where created_at >= v_since group by 1) x),
    'calls', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select kind || ':' || status k, count(*) n from voice_calls where created_at >= v_since group by 1) x),
    'ai', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
        select k, sum(n) n from (select kind k, count(*) n from ai_logs where created_at >= v_since group by 1
                                 union all select kind, count(*) from kyc_lookups where at >= v_since group by 1) y group by k) x),
    'martina', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select kind k, count(*) n from guide_sessions where started_at >= v_since group by 1) x),
    'payouts', (select coalesce(jsonb_object_agg(k, jsonb_build_object('count', n, 'amount', a)), '{}'::jsonb)
                from (select status k, count(*) n, sum(amount) a from payouts where created_at >= v_since group by 1) x),
    'payments', (select coalesce(jsonb_object_agg(k, jsonb_build_object('count', n, 'amount', a)), '{}'::jsonb)
                from (select status k, count(*) n, sum(coalesce(paid_amount, amount)) a from payment_requests where created_at >= v_since group by 1) x),
    'tin_checks', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select outcome k, count(*) n from tin_checks where at >= v_since group by 1) x),
    'signups', (select count(*) from auth.users where created_at >= v_since),
    'businesses', (select count(*) from orgs where created_at >= v_since and not is_sample),
    'failures', private.platform_failures(v_since, null, 200));
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- 3. The sample business, once per person
-- ---------------------------------------------------------------------------------------------------------------------
-- create_sample_business looked for the person's sample before making one, but a second tap that arrived while the first
-- was still writing found nothing and made another (three in three seconds on 29 October). The function that builds the
-- sample moves, unchanged, to private.create_sample_business_build; create_sample_business now takes a lock for the person
-- first, so a second call waits for the first and gets the same sample business.
-- A later migration that changes how the sample is built replaces private.create_sample_business_build, not this one.
do $$
begin
  if to_regprocedure('private.create_sample_business_build()') is null then
    alter function public.create_sample_business() rename to create_sample_business_build;
    alter function public.create_sample_business_build() set schema private;
  end if;
end $$;
revoke all on function private.create_sample_business_build() from public, anon, authenticated;

create or replace function public.create_sample_business() returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); v_org uuid;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  perform pg_advisory_xact_lock(hashtext('sample-business:' || v_uid::text));
  select o.id into v_org from orgs o join members m on m.org_id = o.id
  where o.is_sample and m.user_id = v_uid and m.status = 'active' order by o.created_at limit 1;
  if v_org is not null then return v_org; end if;
  return private.create_sample_business_build();
end $$;
revoke all on function public.create_sample_business() from public, anon;
grant execute on function public.create_sample_business() to authenticated, service_role;
