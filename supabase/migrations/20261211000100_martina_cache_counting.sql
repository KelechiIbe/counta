-- Martina's cache and how plans count her messages.
--
-- 1. Gemini tokens taken from a cache are billed at a tenth of the input price. The chat function now sends how many tokens
--    each call took from a cache (usage_events.qty_cached), what making Martina's cache cost (kind context_cache, no
--    business) and the token-hours it was kept (service gemini_cache), and the costs page prices each at its own rate.
-- 2. The "Questions to Martina" quota counted every Gemini call, so one WhatsApp question used two to four of it. It now
--    counts one per message Martina answers: the first call of a turn keeps the counted kind (chat, customer_chat) and the
--    calls after it in the same turn are *_step, for the costs page only. A picture someone on the team sends her counts
--    once (whatsapp_media), and so does each reply she sends a customer (customer_chat). The quota is renamed to say so.
-- 3. The platform averages on the plan calculator leave out team alerts, as each business's own count already did.

-- ---------------------------------------------------------------------------
-- 1. Cached tokens and the cache's storage
-- ---------------------------------------------------------------------------
alter table public.usage_events add column if not exists qty_cached numeric not null default 0 check (qty_cached >= 0);

-- p: {org_id, service, kind, item, qty_in, qty_out, qty_cached, searches | grounded}
create or replace function public.svc_usage(p jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_in numeric;
begin
  begin v_org := nullif(p->>'org_id', '')::uuid; exception when others then v_org := null; end;
  if v_org is not null and not exists (select 1 from orgs where id = v_org) then v_org := null; end if;
  v_in := least(greatest(coalesce((p->>'qty_in')::numeric, 0), 0), 100000000);
  insert into usage_events (org_id, service, kind, item, qty_in, qty_out, qty_cached, searches)
  values (v_org, left(lower(coalesce(nullif(p->>'service', ''), 'other')), 30), left(coalesce(nullif(p->>'kind', ''), 'other'), 40), left(nullif(p->>'item', ''), 80),
    v_in, least(greatest(coalesce((p->>'qty_out')::numeric, 0), 0), 100000000),
    least(greatest(coalesce((p->>'qty_cached')::numeric, 0), 0), v_in),
    least(greatest(coalesce((p->>'searches')::int, case when (p->>'grounded')::boolean then 1 else 0 end), 0), 1000));
end $$;
revoke all on function public.svc_usage(jsonb) from public, anon, authenticated;
grant execute on function public.svc_usage(jsonb) to service_role;

do $$
begin
  insert into public.cost_rates (service, item, measure, label, unit_qty, unit_label, price, currency, effective_from, borne_by, source_url, note, checked, checked_at)
  values
    ('gemini', '*', 'cached_input_tokens', 'Gemini input tokens from a cache', 1000000, '1M tokens', 0.075, 'USD', '2026-01-01', 'taxstreem',
      'https://cloud.google.com/vertex-ai/generative-ai/pricing', 'gemini-3.8-flash on Vertex AI: a tenth of the input price. $0.15 from 1 January 2027.', true, now()),
    ('gemini', '*', 'cached_input_tokens', 'Gemini input tokens from a cache', 1000000, '1M tokens', 0.15, 'USD', '2027-01-01', 'taxstreem',
      'https://cloud.google.com/vertex-ai/generative-ai/pricing', 'gemini-3.8-flash from 1 January 2027.', true, now()),
    ('gemini', '*', 'cache_storage', 'Gemini cache storage', 1000000, '1M token-hours', 1.00, 'USD', '2026-01-01', 'taxstreem',
      'https://cloud.google.com/vertex-ai/generative-ai/pricing', 'Context cache storage, $0.000001 per token-hour. Martina''s cache is kept only while messages come.', true, now())
  on conflict (service, item, measure, effective_from) do nothing;
end $$;

-- Latest definition (20261030000500_service_costs.sql), with input tokens split between those Gemini took from a cache and
-- the rest, and the cache's storage.
create or replace function private.cost_usage(p_from timestamptz, p_to timestamptz)
returns table (org_id uuid, service text, item text, measure text, qty numeric)
language plpgsql stable security definer set search_path = public, private as $$
declare d_from date := (p_from at time zone 'Africa/Lagos')::date; d_to date := (p_to at time zone 'Africa/Lagos')::date;
begin
  return query
    select u.org_id, 'gemini'::text, coalesce(u.item, '*'), 'input_tokens'::text, sum(u.qty_in - u.qty_cached) from usage_events u
    where u.service = 'gemini' and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'cached_input_tokens', sum(u.qty_cached) from usage_events u
    where u.service = 'gemini' and u.qty_cached > 0 and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'output_tokens', sum(u.qty_out) from usage_events u
    where u.service = 'gemini' and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'searches', sum(u.searches)::numeric from usage_events u
    where u.service = 'gemini' and u.searches > 0 and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'cache_storage', sum(u.qty_in) from usage_events u
    where u.service = 'gemini_cache' and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select private.subject_org(t.subject), 'elevenlabs', '*', 'tts_chars', sum(t.chars)::numeric from tts_usage t
    where t.day >= d_from and t.day < d_to group by 1
    union all
    select v.org_id, 'elevenlabs', '*', 'agent_minutes', sum(coalesce(v.duration_secs, 0)) / 60.0 from voice_calls v
    where v.created_at >= p_from and v.created_at < p_to and coalesce(v.duration_secs, 0) > 0 group by v.org_id
    union all
    select v.org_id, 'twilio', '*', 'call_minutes', sum(ceil(v.duration_secs / 60.0)) from voice_calls v
    where v.created_at >= p_from and v.created_at < p_to and v.to_number is not null and coalesce(v.duration_secs, 0) > 0 group by v.org_id
    union all
    select private.user_org(g.user_id), 'elevenlabs', '*', 'agent_sessions', count(*)::numeric from guide_sessions g
    where g.started_at >= p_from and g.started_at < p_to group by 1
    union all
    select m.org_id, 'whatsapp', '*', 'message_utility', count(*)::numeric from messages m
    where m.channel = 'whatsapp' and m.status in ('sent', 'delivered', 'read') and m.created_at >= p_from and m.created_at < p_to group by m.org_id
    union all
    select m.org_id, 'resend', '*', 'email', count(*)::numeric from messages m
    where m.channel = 'email' and m.status in ('sent', 'delivered', 'read') and m.created_at >= p_from and m.created_at < p_to group by m.org_id
    union all
    select private.user_org(k.user_id), 'mono', '*', 'lookup_' || k.kind, count(*)::numeric from kyc_lookups k
    where k.kind in ('search', 'profile', 'document', 'status_report', 'nin', 'tin') and k.at >= p_from and k.at < p_to group by 1, k.kind
    union all
    select t.org_id, 'mono', '*', 'lookup_tin', count(*)::numeric from tin_checks t
    where t.outcome <> 'asked' and t.at >= p_from and t.at < p_to group by t.org_id
    union all
    select b.org_id, 'mono', '*', 'connect_account_month', count(*)::numeric from bank_accounts b
    where b.provider = 'mono' and b.active and b.created_at < p_to group by b.org_id
    union all
    select r.org_id, 'flutterwave', '*', 'collection_fee', sum(r.fee) from payment_requests r
    where r.status = 'paid' and r.paid_at >= p_from and r.paid_at < p_to and r.fee > 0 group by r.org_id
    union all
    select po.org_id, 'flutterwave', '*', 'transfer_fee', sum(po.fee) from payouts po
    where po.status = 'successful' and po.completed_at >= p_from and po.completed_at < p_to and po.fee > 0 group by po.org_id
    union all
    select c.org_id, 'flutterwave', '*', 'subscription_card_amount', sum(c.amount) from subscription_charges c
    where c.status = 'successful' and c.method = 'card' and c.paid_at >= p_from and c.paid_at < p_to group by c.org_id;
  -- Stored files, by the business folder they sit in (the hosted database keeps their sizes; a bare one has no sizes).
  if exists (select 1 from information_schema.columns where table_schema = 'storage' and table_name = 'objects' and column_name = 'metadata') then
    return query execute $q$
      select split_part(o.name, '/', 1)::uuid, 'supabase'::text, '*'::text, 'storage_gb'::text, round(sum(coalesce((o.metadata->>'size')::numeric, 0)) / 1e9, 4)
      from storage.objects o where split_part(o.name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and exists (select 1 from public.orgs g where g.id::text = split_part(o.name, '/', 1))
      group by 1 $q$;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. One count per message Martina answers
-- ---------------------------------------------------------------------------
create or replace function private.ai_assistant_kinds() returns text[]
language sql immutable set search_path = public, private as $$
  select array['ask', 'chat', 'check', 'business_insights', 'whatsapp_media', 'customer_chat']
$$;
-- The calls within a counted message that are not counted themselves: further steps of a turn, a voice note written down, a
-- picture a customer sent described. Their tokens belong to the message's cost.
create or replace function private.ai_assistant_extra_kinds() returns text[]
language sql immutable set search_path = public, private as $$
  select array['chat_step', 'customer_chat_step', 'transcribe', 'customer_media']
$$;

-- Naira for one counted use: the tokens of the counted calls and of the calls that belong to them (p_extra), over the last
-- 30 days, divided by the counted calls; cached tokens at their own rate. p_in and p_out stand in when nothing was used.
create or replace function private.gemini_unit_cost(p_kinds text[], p_extra text[], p_in numeric, p_out numeric) returns numeric
language sql stable security definer set search_path = public, private as $$
  with d as (select (now() at time zone 'Africa/Lagos')::date as day),
  a as (select count(*) filter (where kind = any(p_kinds)) n, sum(qty_in - qty_cached) tin, sum(qty_cached) tc, sum(qty_out) tout, sum(searches) srch
        from usage_events where service = 'gemini' and (kind = any(p_kinds) or kind = any(p_extra)) and at > now() - interval '30 days'),
  r as (select private.cost_rate_for('gemini', '*', 'input_tokens', d.day) ri, private.cost_rate_for('gemini', '*', 'cached_input_tokens', d.day) rc,
          private.cost_rate_for('gemini', '*', 'output_tokens', d.day) ro, private.cost_rate_for('gemini', '*', 'searches', d.day) rs, d.day as day from d)
  select private.to_ngn(
    case when a.n > 0 then a.tin / a.n else p_in end / (r.ri).unit_qty * (r.ri).price
    + case when a.n > 0 then a.tc / a.n else 0 end * coalesce((r.rc).price / (r.rc).unit_qty, (r.ri).price / (r.ri).unit_qty)
    + case when a.n > 0 then a.tout / a.n else p_out end / (r.ro).unit_qty * (r.ro).price
    + case when a.n > 0 then a.srch / a.n else 0 end / (r.rs).unit_qty * (r.rs).price, 'USD', r.day)
  from a, r
$$;

-- Latest definition (20261030000500_service_costs.sql), now through gemini_unit_cost.
create or replace function private.gemini_call_cost(p_kinds text[], p_in numeric, p_out numeric) returns numeric
language sql stable security definer set search_path = public, private as $$
  select private.gemini_unit_cost(p_kinds, '{}'::text[], p_in, p_out)
$$;

-- Latest definition (20261030000500_service_costs.sql); a message to Martina carries the cost of every call in it.
create or replace function private.module_unit_cost(p_module text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare md public.plan_modules;
begin
  select * into md from plan_modules where key = p_module;
  if md.unit_cost_ngn is not null then return md.unit_cost_ngn; end if;
  return round(coalesce(case md.meter
    when 'ai_reads' then private.gemini_call_cost(private.ai_read_kinds(), 3000, 800)
    when 'assistant' then private.gemini_unit_cost(private.ai_assistant_kinds(), private.ai_assistant_extra_kinds(), 8000, 450)
    when 'supplier_invoices' then private.gemini_call_cost(array['supplier_invoice'], 4000, 1200) + coalesce(private.rate_ngn('whatsapp', 'message_utility'), 0)
    when 'call_minutes' then coalesce(private.rate_ngn('elevenlabs', 'agent_minutes'), 0) + coalesce(private.rate_ngn('twilio', 'call_minutes'), 0)
    when 'whatsapp' then private.rate_ngn('whatsapp', 'message_utility')
    when 'emails' then private.rate_ngn('resend', 'email')
    when 'tin_checks' then private.rate_ngn('mono', 'lookup_tin')
    when 'bank_feeds' then private.rate_ngn('mono', 'connect_account_month')
    else 0 end, 0), 4);
end $$;

update public.plan_modules set name = 'Messages to Martina a month', unit = 'messages a month',
  what = 'Messages Martina answers in Counta, on WhatsApp and on Siri, and her replies to customers on WhatsApp.', updated_at = now()
where key = 'assistant' and updated_by is null and name = 'Questions to Martina a month';

-- ---------------------------------------------------------------------------
-- 3. Platform averages without team alerts
-- ---------------------------------------------------------------------------
-- Latest definition (20261124001300_fixes_and_rules.sql); WhatsApp messages and emails to the team (alerts) are left out, as
-- meter_usage leaves them out of each business's count.
create or replace function private.meter_average(p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := now() - interval '30 days'; v_n int; v numeric;
begin
  select count(*) into v_n from orgs o where not o.is_sample and exists (select 1 from members mb where mb.org_id = o.id and mb.status = 'active');
  if v_n = 0 then return 0; end if;
  case p_meter
    when 'sales' then select count(*) into v from sales s join orgs o on o.id = s.org_id where not o.is_sample and s.created_at >= v_from and s.doc_type in ('receipt', 'invoice') and s.status not in ('draft', 'void', 'cancelled');
    when 'ai_reads' then select count(*) into v from usage_events u join orgs o on o.id = u.org_id where not o.is_sample and u.service = 'gemini' and u.kind = any(private.ai_read_kinds()) and u.at >= v_from;
    when 'assistant' then select count(*) into v from usage_events u join orgs o on o.id = u.org_id where not o.is_sample and u.service = 'gemini' and u.kind = any(private.ai_assistant_kinds()) and u.at >= v_from;
    when 'call_minutes' then select coalesce(sum(ceil(coalesce(v.duration_secs, 0) / 60.0)), 0) into v from voice_calls v join orgs o on o.id = v.org_id where not o.is_sample and v.created_at >= v_from;
    when 'whatsapp' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'whatsapp' and m.template <> 'alert' and m.status not in ('failed', 'suppressed') and m.created_at >= v_from;
    when 'emails' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'email' and m.template <> 'alert' and m.status not in ('failed', 'suppressed') and m.created_at >= v_from;
    when 'tin_checks' then select count(*) into v from tin_checks t join orgs o on o.id = t.org_id where not o.is_sample and t.at >= v_from;
    when 'supplier_invoices' then select count(*) into v from supplier_invoices t join orgs o on o.id = t.org_id where not o.is_sample and t.created_at >= v_from;
    when 'payouts' then select count(*) into v from payouts t join orgs o on o.id = t.org_id where not o.is_sample and t.created_at >= v_from and t.status <> 'cancelled';
    when 'users' then select count(*) into v from members t join orgs o on o.id = t.org_id where not o.is_sample and t.status in ('active', 'invited');
    when 'locations' then select count(*) into v from locations t join orgs o on o.id = t.org_id where not o.is_sample;
    when 'bank_feeds' then select count(*) into v from bank_accounts t join orgs o on o.id = t.org_id where not o.is_sample and t.provider = 'mono' and t.active;
    else v := 0;
  end case;
  return round(coalesce(v, 0)::numeric / v_n, 2);
end $$;

revoke all on function private.ai_assistant_kinds(), private.ai_assistant_extra_kinds(), private.gemini_unit_cost(text[], text[], numeric, numeric),
  private.gemini_call_cost(text[], numeric, numeric), private.module_unit_cost(text), private.meter_average(text), private.cost_usage(timestamptz, timestamptz)
  from public, anon, authenticated;
