-- What it costs TaxStreem to run Counta for each business (TaxStreem item 5).
--
-- Every service Counta pays for is a cost element with a rate: Gemini tokens and searches, ElevenLabs speech and agent
-- minutes, Twilio call minutes, WhatsApp and email messages, Mono lookups and bank feeds, Flutterwave's fee on plan
-- payments by card, and file storage. The usage comes from Counta's own records (usage_events for the AI, and the
-- calls, messages, lookups, feeds and payments tables). Fees businesses pay themselves (Flutterwave's collection and
-- transfer fees) are shown apart, so the admin sees them without counting them as TaxStreem's cost.
--
-- Rates were filled from the providers' published prices in October 2026 and are marked unchecked until someone at
-- TaxStreem confirms them against the bills. Mono does not publish its prices, so those rates start at zero. Fixed monthly
-- bills (Supabase, Netlify, the relay server and similar) are entered by TaxStreem and shared equally across the month's
-- businesses. Dollar prices are turned into naira at Counta's exchange rate for the month.

create table if not exists public.cost_rates (
  id uuid primary key default gen_random_uuid(),
  service text not null check (service ~ '^[a-z0-9_]{2,30}$'),
  item text not null default '*' check (length(item) between 1 and 80),
  measure text not null check (measure ~ '^[a-z0-9_]{2,40}$'),
  label text not null check (length(label) between 2 and 120),
  unit_qty numeric not null default 1 check (unit_qty > 0),
  unit_label text not null check (length(unit_label) between 1 and 40),
  price numeric(16,6) not null check (price >= 0),
  currency text not null default 'USD' check (currency in ('USD', 'NGN', 'EUR', 'GBP')),
  effective_from date not null default '2026-01-01',
  borne_by text not null default 'taxstreem' check (borne_by in ('taxstreem', 'business')),
  source_url text check (source_url ~ '^https://'),
  note text check (length(note) <= 400),
  checked boolean not null default false,
  checked_by uuid references auth.users(id) on delete set null,
  checked_at timestamptz,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (service, item, measure, effective_from)
);
create index if not exists cost_rates_checked_by on public.cost_rates(checked_by);
create index if not exists cost_rates_updated_by on public.cost_rates(updated_by);
alter table public.cost_rates enable row level security;
revoke all on public.cost_rates from anon, authenticated;

create table if not exists public.cost_fixed (
  id uuid primary key default gen_random_uuid(),
  service text not null check (length(service) between 2 and 40),
  label text not null check (length(label) between 2 and 120),
  currency text not null default 'USD' check (currency in ('USD', 'NGN', 'EUR', 'GBP')),
  monthly_amount numeric(14,2) check (monthly_amount >= 0),
  from_month date not null default '2026-01-01',
  to_month date,
  note text check (length(note) <= 400),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists cost_fixed_updated_by on public.cost_fixed(updated_by);
alter table public.cost_fixed enable row level security;
revoke all on public.cost_fixed from anon, authenticated;

insert into public.cost_rates (service, item, measure, label, unit_qty, unit_label, price, currency, effective_from, borne_by, source_url, note) values
  ('gemini', '*', 'input_tokens', 'Gemini input tokens', 1000000, '1M tokens', 0.75, 'USD', '2026-01-01', 'taxstreem',
    'https://ai.google.dev/gemini-api/docs/pricing', 'gemini-3.8-flash, paid tier, standard. Google''s page sets $1.50 from 1 January 2027.'),
  ('gemini', '*', 'input_tokens', 'Gemini input tokens', 1000000, '1M tokens', 1.50, 'USD', '2027-01-01', 'taxstreem',
    'https://ai.google.dev/gemini-api/docs/pricing', 'gemini-3.8-flash from 1 January 2027.'),
  ('gemini', '*', 'output_tokens', 'Gemini output tokens, thinking included', 1000000, '1M tokens', 3.75, 'USD', '2026-01-01', 'taxstreem',
    'https://ai.google.dev/gemini-api/docs/pricing', 'gemini-3.8-flash. Google''s page sets $7.50 from 1 January 2027.'),
  ('gemini', '*', 'output_tokens', 'Gemini output tokens, thinking included', 1000000, '1M tokens', 7.50, 'USD', '2027-01-01', 'taxstreem',
    'https://ai.google.dev/gemini-api/docs/pricing', 'gemini-3.8-flash from 1 January 2027.'),
  ('gemini', '*', 'searches', 'Gemini grounding with Google Search', 1000, '1,000 searches', 14, 'USD', '2026-01-01', 'taxstreem',
    'https://ai.google.dev/gemini-api/docs/pricing', 'Google gives 5,000 searches a month free across the account; Counta counts them all.'),
  ('elevenlabs', '*', 'tts_chars', 'ElevenLabs speech (Flash v2.5)', 1000, '1,000 characters', 0.05, 'USD', '2026-01-01', 'taxstreem',
    'https://elevenlabs.io/pricing', 'Flash and Turbo models, from a June 2026 summary of ElevenLabs'' API prices. A monthly plan includes credits; enter it under fixed costs.'),
  ('elevenlabs', '*', 'agent_minutes', 'ElevenLabs agent minutes (phone calls)', 1, 'minute', 0.08, 'USD', '2026-01-01', 'taxstreem',
    'https://elevenlabs.io/pricing', 'Agents per minute, from a June 2026 summary of ElevenLabs'' API prices; the agent''s language model can add to it.'),
  ('elevenlabs', '*', 'agent_sessions', 'ElevenLabs agent, in-app voice guide', 1, 'session', 0.24, 'USD', '2026-01-01', 'taxstreem',
    'https://elevenlabs.io/pricing', 'Counta does not record how long a guide session lasts; this assumes three minutes at $0.08.'),
  ('twilio', '*', 'call_minutes', 'Twilio calls to Nigerian mobiles', 1, 'minute', 0.2349, 'USD', '2026-01-01', 'taxstreem',
    'https://www.twilio.com/en-us/voice/pricing/ng', 'Outbound to Nigeria mobile, billed per minute rounded up. The number''s monthly rent goes under fixed costs.'),
  ('whatsapp', '*', 'message_utility', 'WhatsApp utility message, Nigeria', 1, 'message', 0.0101, 'USD', '2026-01-01', 'taxstreem',
    'https://developers.facebook.com/docs/whatsapp/pricing', 'Meta''s rate for Nigeria as reported for October 2026; confirm against Meta''s rate card.'),
  ('resend', '*', 'email', 'Email through Resend', 1000, '1,000 emails', 0.40, 'USD', '2026-01-01', 'taxstreem',
    'https://resend.com/pricing', 'Pro plan: $20 for 50,000 a month, so $0.40 per 1,000; $0.90 per 1,000 beyond it.'),
  ('mono', '*', 'lookup_search', 'Mono CAC search', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'lookup_profile', 'Mono CAC company profile', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'lookup_document', 'Mono CAC document', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'lookup_status_report', 'Mono CAC status report', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'lookup_nin', 'Mono NIN check', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'lookup_tin', 'Mono Tax ID check with the NRS', 1, 'lookup', 0, 'NGN', '2026-01-01', 'taxstreem', 'https://mono.co/pricing',
    'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('mono', '*', 'connect_account_month', 'Mono bank feed, per linked account a month', 1, 'account a month', 0, 'NGN', '2026-01-01', 'taxstreem',
    'https://mono.co/pricing', 'Mono does not publish this price. Enter it from TaxStreem''s Mono agreement.'),
  ('flutterwave', '*', 'subscription_card_amount', 'Flutterwave fee on plan payments by card', 1, 'naira charged', 0.014, 'NGN', '2026-01-01', 'taxstreem',
    'https://flutterwave.com/ng/pricing', 'Local cards 1.4% (a 2026 estimate; confirm in TaxStreem''s Flutterwave agreement). The ₦2,000 cap a charge is not applied here.'),
  ('flutterwave', '*', 'collection_fee', 'Flutterwave fees on sales collected', 1, 'naira', 1, 'NGN', '2026-01-01', 'business',
    'https://flutterwave.com/ng/pricing', 'What Flutterwave kept from payments to businesses, as recorded on each payment.'),
  ('flutterwave', '*', 'transfer_fee', 'Flutterwave transfer fees on payouts', 1, 'naira', 1, 'NGN', '2026-01-01', 'business',
    'https://flutterwave.com/ng/pricing', 'What Flutterwave charged on each payout, paid from the business''s wallet.'),
  ('supabase', '*', 'storage_gb', 'File storage (Supabase)', 1, 'GB a month', 0.021, 'USD', '2026-01-01', 'taxstreem',
    'https://supabase.com/pricing', 'Beyond the 100 GB the Pro plan includes. Counta counts every gigabyte.')
on conflict (service, item, measure, effective_from) do nothing;

insert into public.cost_fixed (service, label, currency, monthly_amount, note)
select * from (values
  ('supabase', 'Supabase Pro plan and compute', 'USD', null::numeric, 'Enter the monthly bill.'),
  ('netlify', 'Netlify', 'USD', null, 'Enter the monthly bill.'),
  ('digitalocean', 'Relay server for Flutterwave transfers', 'USD', null, 'Enter the monthly bill.'),
  ('twilio', 'Twilio phone number', 'USD', null, 'Enter the monthly rent of the number Martina calls from.'),
  ('elevenlabs', 'ElevenLabs plan', 'USD', null, 'Enter the monthly plan, if TaxStreem pays one.')
) v(service, label, currency, monthly_amount, note)
where not exists (select 1 from public.cost_fixed);

-- The business a user's lookups count against: the one they own, else the first they joined.
create or replace function private.user_org(p_user uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from members where user_id = p_user order by (role = 'owner') desc, created_at limit 1
$$;
create or replace function private.subject_org(p_subject text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select case when p_subject ~ '^org:[0-9a-f-]{36}$' then substr(p_subject, 5)::uuid
              when p_subject ~ '^user:[0-9a-f-]{36}$' then private.user_org(substr(p_subject, 6)::uuid) end
$$;

-- Everything used between two moments, by business (null when no business can be named), service and measure.
create or replace function private.cost_usage(p_from timestamptz, p_to timestamptz)
returns table (org_id uuid, service text, item text, measure text, qty numeric)
language plpgsql stable security definer set search_path = public, private as $$
declare d_from date := (p_from at time zone 'Africa/Lagos')::date; d_to date := (p_to at time zone 'Africa/Lagos')::date;
begin
  return query
    select u.org_id, 'gemini'::text, coalesce(u.item, '*'), 'input_tokens'::text, sum(u.qty_in) from usage_events u
    where u.service = 'gemini' and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'output_tokens', sum(u.qty_out) from usage_events u
    where u.service = 'gemini' and u.at >= p_from and u.at < p_to group by u.org_id, u.item
    union all
    select u.org_id, 'gemini', coalesce(u.item, '*'), 'searches', sum(u.searches)::numeric from usage_events u
    where u.service = 'gemini' and u.searches > 0 and u.at >= p_from and u.at < p_to group by u.org_id, u.item
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

-- The rate for a use on a day: the model's own rate first, then the service's general one.
create or replace function private.cost_rate_for(p_service text, p_item text, p_measure text, p_day date) returns public.cost_rates
language sql stable security definer set search_path = public as $$
  select * from cost_rates c where c.service = p_service and c.measure = p_measure and c.item in (coalesce(p_item, '*'), '*') and c.effective_from <= p_day
  order by (c.item = coalesce(p_item, '*')) desc, c.effective_from desc limit 1
$$;

create or replace function private.to_ngn(p_amount numeric, p_currency text, p_day date) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when p_amount is null then null when p_currency = 'NGN' then p_amount
    else round(p_amount * (private.fx_rate(p_currency, p_day)->>'rate')::numeric, 2) end
$$;

-- What each element of a month cost, by business: [{org_id, service, item, measure, qty, rate_id, cost_ngn, borne_by}]
-- Rates are those in force on p_day (the month's first); dollars are turned into naira at the rate on p_fx_day.
create or replace function private.cost_lines(p_from timestamptz, p_to timestamptz, p_day date, p_fx_day date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('org_id', u.org_id, 'service', u.service, 'item', u.item, 'measure', u.measure, 'qty', u.qty,
      'rate_id', r.id, 'label', coalesce(r.label, u.service || ' ' || u.measure), 'borne_by', coalesce(r.borne_by, 'taxstreem'), 'checked', coalesce(r.checked, false),
      'cost_ngn', case when r.id is not null then round(private.to_ngn(u.qty / r.unit_qty * r.price, r.currency, p_fx_day), 2) end)), '[]'::jsonb)
  from private.cost_usage(p_from, p_to) u
  left join lateral (select * from private.cost_rate_for(u.service, u.item, u.measure, p_day)) r on true
  where u.qty > 0
$$;

-- The admin costs page for a month ('YYYY-MM', this month by default).
create or replace function public.admin_costs(p_month text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_day date; v_from timestamptz; v_to timestamptz; v_rate_day date; v_lines jsonb; v_fixed numeric; v_active int; v_usd jsonb; v_share numeric;
begin
  perform private.require_staff(false);
  v_day := coalesce(case when p_month ~ '^\d{4}-\d{2}$' then to_date(p_month || '-01', 'YYYY-MM-DD') end, date_trunc('month', now() at time zone 'Africa/Lagos')::date);
  v_from := v_day::timestamp at time zone 'Africa/Lagos';
  v_to := (v_day + interval '1 month')::timestamp at time zone 'Africa/Lagos';
  v_rate_day := least((v_day + interval '1 month - 1 day')::date, (now() at time zone 'Africa/Lagos')::date);
  v_usd := private.fx_rate('USD', v_rate_day);
  v_lines := private.cost_lines(v_from, v_to, v_day, v_rate_day);
  select coalesce(sum(private.to_ngn(monthly_amount, currency, v_rate_day)), 0) into v_fixed from cost_fixed
  where monthly_amount is not null and from_month <= v_day and (to_month is null or to_month >= v_day);
  select count(*) into v_active from orgs o where not o.is_sample and o.created_at < v_to
    and exists (select 1 from members mb where mb.org_id = o.id and mb.status = 'active');
  v_share := case when v_active > 0 then round(v_fixed / v_active, 2) else 0 end;
  return jsonb_build_object(
    'month', to_char(v_day, 'YYYY-MM'), 'usd_rate', v_usd, 'rate_day', v_rate_day,
    'elements', (select coalesce(jsonb_agg(e order by (e->>'cost_ngn')::numeric desc nulls last), '[]'::jsonb) from (
      select jsonb_build_object('service', x->>'service', 'measure', x->>'measure', 'label', min(x->>'label'), 'borne_by', min(x->>'borne_by'),
        'checked', bool_and((x->>'checked')::boolean), 'rate_id', min(x->>'rate_id'), 'qty', sum((x->>'qty')::numeric),
        'cost_ngn', sum((x->>'cost_ngn')::numeric), 'priced', bool_and(x->>'rate_id' is not null), 'businesses', count(distinct x->>'org_id')) e
      from jsonb_array_elements(v_lines) x group by x->>'service', x->>'measure') z),
    'totals', jsonb_build_object(
      'variable_ngn', (select coalesce(sum((x->>'cost_ngn')::numeric), 0) from jsonb_array_elements(v_lines) x where x->>'borne_by' = 'taxstreem'),
      'passthrough_ngn', (select coalesce(sum((x->>'cost_ngn')::numeric), 0) from jsonb_array_elements(v_lines) x where x->>'borne_by' = 'business'),
      'unattributed_ngn', (select coalesce(sum((x->>'cost_ngn')::numeric), 0) from jsonb_array_elements(v_lines) x where x->>'borne_by' = 'taxstreem' and x->>'org_id' is null),
      'fixed_ngn', v_fixed, 'businesses', v_active, 'fixed_share_ngn', v_share,
      'revenue_ngn', (select coalesce(sum(round(c.amount / (1 + private.vat_rate((c.paid_at at time zone 'Africa/Lagos')::date)), 2)), 0) from subscription_charges c
        where c.status = 'successful' and c.paid_at >= v_from and c.paid_at < v_to)),
    'businesses', (select coalesce(jsonb_agg(b order by (b->>'total_ngn')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('org_id', o.id, 'name', o.name, 'plan', pl.name,
        'variable_ngn', coalesce(sum((x->>'cost_ngn')::numeric) filter (where x->>'borne_by' = 'taxstreem'), 0),
        'passthrough_ngn', coalesce(sum((x->>'cost_ngn')::numeric) filter (where x->>'borne_by' = 'business'), 0),
        'fixed_share_ngn', v_share,
        'total_ngn', coalesce(sum((x->>'cost_ngn')::numeric) filter (where x->>'borne_by' = 'taxstreem'), 0) + v_share,
        'revenue_ngn', (select coalesce(sum(round(c.amount / (1 + private.vat_rate((c.paid_at at time zone 'Africa/Lagos')::date)), 2)), 0) from subscription_charges c
          where c.org_id = o.id and c.status = 'successful' and c.paid_at >= v_from and c.paid_at < v_to),
        'by_service', (select coalesce(jsonb_object_agg(sv, amt), '{}'::jsonb) from (select y->>'service' sv, sum((y->>'cost_ngn')::numeric) amt
          from jsonb_array_elements(v_lines) y where (y->>'org_id')::uuid = o.id and y->>'borne_by' = 'taxstreem' group by 1) q)) b
      from orgs o join plans pl on pl.id = private.org_plan_id(o.id)
      left join jsonb_array_elements(v_lines) x on (x->>'org_id')::uuid = o.id
      where not o.is_sample and o.created_at < v_to
      group by o.id, o.name, pl.name
      order by 1 limit 500) z),
    'plans', (select coalesce(jsonb_agg(jsonb_build_object('plan', pl.name, 'code', pl.code, 'price_month', pl.price_month, 'target_margin', pl.target_margin,
        'businesses', n, 'variable_ngn', var, 'fixed_ngn', n * v_share, 'revenue_ngn', rev,
        'margin', case when rev > 0 then round((rev - var - n * v_share) / rev, 4) end) order by pl.sort), '[]'::jsonb)
      from (select private.org_plan_id(o.id) plan_id, count(*) n,
              coalesce(sum((select sum((x->>'cost_ngn')::numeric) from jsonb_array_elements(v_lines) x where (x->>'org_id')::uuid = o.id and x->>'borne_by' = 'taxstreem')), 0) var,
              coalesce(sum((select sum(round(c.amount / (1 + private.vat_rate((c.paid_at at time zone 'Africa/Lagos')::date)), 2)) from subscription_charges c
                where c.org_id = o.id and c.status = 'successful' and c.paid_at >= v_from and c.paid_at < v_to)), 0) rev
            from orgs o where not o.is_sample and o.created_at < v_to group by 1) s join plans pl on pl.id = s.plan_id),
    'rates', (select coalesce(jsonb_agg(to_jsonb(r) - 'updated_by' - 'checked_by' || jsonb_build_object('checked_by_email', (select email from auth.users u where u.id = r.checked_by))
      order by r.service, r.measure, r.item, r.effective_from), '[]'::jsonb) from cost_rates r),
    'fixed', (select coalesce(jsonb_agg(to_jsonb(f) - 'updated_by' || jsonb_build_object('ngn', private.to_ngn(f.monthly_amount, f.currency, v_rate_day))
      order by f.service, f.label), '[]'::jsonb) from cost_fixed f),
    'to_check', jsonb_build_object('rates', (select count(*) from cost_rates where not checked), 'fixed_missing', (select count(*) from cost_fixed where monthly_amount is null),
      'no_usd_rate', v_usd is null));
end $$;

-- p: {id?, service, item, measure, label, unit_qty, unit_label, price, currency, effective_from, borne_by, source_url, note, checked}
create or replace function public.admin_save_cost_rate(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); v_id uuid := nullif(p->>'id', '')::uuid; v_checked boolean := coalesce((p->>'checked')::boolean, false);
begin
  if v_id is null then
    insert into cost_rates (service, item, measure, label, unit_qty, unit_label, price, currency, effective_from, borne_by, source_url, note, checked, checked_by, checked_at, updated_by)
    values (lower(trim(p->>'service')), coalesce(nullif(trim(p->>'item'), ''), '*'), lower(trim(p->>'measure')), trim(p->>'label'),
      coalesce(nullif(p->>'unit_qty', '')::numeric, 1), coalesce(nullif(trim(p->>'unit_label'), ''), 'unit'), (p->>'price')::numeric,
      coalesce(nullif(p->>'currency', ''), 'USD'), coalesce(nullif(p->>'effective_from', '')::date, '2026-01-01'), coalesce(nullif(p->>'borne_by', ''), 'taxstreem'),
      nullif(trim(p->>'source_url'), ''), nullif(trim(p->>'note'), ''), v_checked, case when v_checked then v_uid end, case when v_checked then now() end, v_uid)
    returning id into v_id;
  else
    update cost_rates set label = coalesce(nullif(trim(p->>'label'), ''), label), unit_qty = coalesce(nullif(p->>'unit_qty', '')::numeric, unit_qty),
      unit_label = coalesce(nullif(trim(p->>'unit_label'), ''), unit_label), price = coalesce(nullif(p->>'price', '')::numeric, price),
      currency = coalesce(nullif(p->>'currency', ''), currency), effective_from = coalesce(nullif(p->>'effective_from', '')::date, effective_from),
      borne_by = coalesce(nullif(p->>'borne_by', ''), borne_by), source_url = case when p ? 'source_url' then nullif(trim(p->>'source_url'), '') else source_url end,
      note = case when p ? 'note' then nullif(trim(p->>'note'), '') else note end,
      checked = v_checked, checked_by = case when v_checked then v_uid end, checked_at = case when v_checked then now() end, updated_by = v_uid, updated_at = now()
    where id = v_id;
    if not found then raise exception 'Rate not found.'; end if;
  end if;
  perform private.audit('save_cost_rate', v_id::text, p);
  return (select to_jsonb(r) - 'updated_by' - 'checked_by' from cost_rates r where r.id = v_id);
end $$;

create or replace function public.admin_remove_cost_rate(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  delete from cost_rates where id = p_id;
  perform private.audit('remove_cost_rate', p_id::text, '{}'::jsonb);
end $$;

-- p: {id?, service, label, currency, monthly_amount, from_month, to_month, note, remove}
create or replace function public.admin_save_fixed_cost(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if coalesce((p->>'remove')::boolean, false) then
    delete from cost_fixed where id = v_id;
    perform private.audit('remove_fixed_cost', v_id::text, '{}'::jsonb);
    return null;
  end if;
  if v_id is null then
    insert into cost_fixed (service, label, currency, monthly_amount, from_month, to_month, note, updated_by)
    values (lower(trim(p->>'service')), trim(p->>'label'), coalesce(nullif(p->>'currency', ''), 'USD'), nullif(p->>'monthly_amount', '')::numeric,
      coalesce(date_trunc('month', nullif(p->>'from_month', '')::date)::date, date_trunc('month', now())::date), date_trunc('month', nullif(p->>'to_month', '')::date)::date,
      nullif(trim(p->>'note'), ''), v_uid)
    returning id into v_id;
  else
    update cost_fixed set service = lower(trim(p->>'service')), label = trim(p->>'label'), currency = coalesce(nullif(p->>'currency', ''), currency),
      monthly_amount = nullif(p->>'monthly_amount', '')::numeric, from_month = coalesce(date_trunc('month', nullif(p->>'from_month', '')::date)::date, from_month),
      to_month = date_trunc('month', nullif(p->>'to_month', '')::date)::date, note = nullif(trim(p->>'note'), ''), updated_by = v_uid, updated_at = now()
    where id = v_id;
    if not found then raise exception 'Fixed cost not found.'; end if;
  end if;
  perform private.audit('save_fixed_cost', v_id::text, p);
  return (select to_jsonb(f) - 'updated_by' from cost_fixed f where f.id = v_id);
end $$;

-- ---------------------------------------------------------------------------
-- Plans: what a unit of each quota costs, and quotas a price and margin allow
-- ---------------------------------------------------------------------------
create or replace function private.gemini_call_cost(p_kinds text[], p_in numeric, p_out numeric) returns numeric
language sql stable security definer set search_path = public, private as $$
  with d as (select (now() at time zone 'Africa/Lagos')::date as day),
  a as (select count(*) n, sum(qty_in) tin, sum(qty_out) tout, sum(searches) srch from usage_events
        where service = 'gemini' and kind = any(p_kinds) and at > now() - interval '30 days'),
  r as (select private.cost_rate_for('gemini', '*', 'input_tokens', d.day) ri, private.cost_rate_for('gemini', '*', 'output_tokens', d.day) ro,
          private.cost_rate_for('gemini', '*', 'searches', d.day) rs, d.day as day from d)
  select private.to_ngn(
    case when a.n > 0 then a.tin / a.n else p_in end / (r.ri).unit_qty * (r.ri).price
    + case when a.n > 0 then a.tout / a.n else p_out end / (r.ro).unit_qty * (r.ro).price
    + case when a.n > 0 then a.srch / a.n else 0 end / (r.rs).unit_qty * (r.rs).price, 'USD', r.day)
  from a, r
$$;

create or replace function private.rate_ngn(p_service text, p_measure text) returns numeric
language sql stable security definer set search_path = public, private as $$
  select private.to_ngn(r.price / r.unit_qty, r.currency, (now() at time zone 'Africa/Lagos')::date)
  from private.cost_rate_for(p_service, '*', p_measure, (now() at time zone 'Africa/Lagos')::date) r
$$;

-- Naira for one unit of a module's meter: what an admin typed, else worked out from the rates and the last 30 days.
create or replace function private.module_unit_cost(p_module text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare md public.plan_modules;
begin
  select * into md from plan_modules where key = p_module;
  if md.unit_cost_ngn is not null then return md.unit_cost_ngn; end if;
  return round(coalesce(case md.meter
    when 'ai_reads' then private.gemini_call_cost(private.ai_read_kinds(), 3000, 800)
    when 'assistant' then private.gemini_call_cost(private.ai_assistant_kinds(), 2500, 500)
    when 'supplier_invoices' then private.gemini_call_cost(array['supplier_invoice'], 4000, 1200) + coalesce(private.rate_ngn('whatsapp', 'message_utility'), 0)
    when 'call_minutes' then coalesce(private.rate_ngn('elevenlabs', 'agent_minutes'), 0) + coalesce(private.rate_ngn('twilio', 'call_minutes'), 0)
    when 'whatsapp' then private.rate_ngn('whatsapp', 'message_utility')
    when 'emails' then private.rate_ngn('resend', 'email')
    when 'tin_checks' then private.rate_ngn('mono', 'lookup_tin')
    when 'bank_feeds' then private.rate_ngn('mono', 'connect_account_month')
    else 0 end, 0), 4);
end $$;

-- How much of a meter the average business used in the last 30 days (now, for counts).
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
    when 'whatsapp' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'whatsapp' and m.status <> 'failed' and m.created_at >= v_from;
    when 'emails' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'email' and m.status <> 'failed' and m.created_at >= v_from;
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

-- The plan calculator. p: {price_month, target_margin, quotas: {module: quota | null}}
-- For each quota module: what a unit costs, what the average business uses, what the quota would cost in full, and a
-- suggested quota that keeps the margin when every costed quota is used up (the budget after VAT and the business's
-- share of fixed costs, split by how the average business's costs are made up).
create or replace function public.admin_plan_calc(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare md public.plan_modules; v_price numeric := coalesce(nullif(p->>'price_month', '')::numeric, 0); v_margin numeric := coalesce(nullif(p->>'target_margin', '')::numeric, 0.6);
  v_net numeric; v_fixed numeric; v_active int; v_share numeric; v_budget numeric; v_rows jsonb := '[]'::jsonb; v_unit numeric; v_avg numeric;
  v_mix numeric := 0; v_costed int := 0; v_full numeric := 0; v_avg_cost numeric := 0; v_day date := (now() at time zone 'Africa/Lagos')::date; v_unlim jsonb;
begin
  perform private.require_staff(false);
  v_net := round(v_price / (1 + private.vat_rate(v_day)), 2);
  select coalesce(sum(private.to_ngn(monthly_amount, currency, v_day)), 0) into v_fixed from cost_fixed
  where monthly_amount is not null and from_month <= v_day and (to_month is null or to_month >= v_day);
  select count(*) into v_active from orgs o where not o.is_sample and exists (select 1 from members mb where mb.org_id = o.id and mb.status = 'active');
  v_share := case when v_active > 0 then round(v_fixed / v_active, 2) else v_fixed end;
  v_budget := greatest(round(v_net * (1 - v_margin) - v_share, 2), 0);
  for md in select * from plan_modules where active and kind = 'quota' order by sort loop
    v_unit := private.module_unit_cost(md.key);
    v_avg := private.meter_average(md.meter);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('module', md.key, 'name', md.name, 'unit', md.unit, 'unit_cost_ngn', v_unit, 'average', v_avg,
      'quota', case when p->'quotas' ? md.key then nullif(p->'quotas'->>md.key, '')::numeric end));
    if v_unit > 0 then v_costed := v_costed + 1; v_mix := v_mix + v_avg * v_unit; end if;
  end loop;
  select coalesce(jsonb_agg(x || jsonb_build_object(
      'cost_at_quota', case when (x->>'quota') is not null then round((x->>'quota')::numeric * (x->>'unit_cost_ngn')::numeric, 2) end,
      'cost_at_average', round((x->>'average')::numeric * (x->>'unit_cost_ngn')::numeric, 2),
      'suggested', case when (x->>'unit_cost_ngn')::numeric > 0 then
        floor(v_budget * case when v_mix > 0 then (x->>'average')::numeric * (x->>'unit_cost_ngn')::numeric / v_mix else 1.0 / v_costed end / (x->>'unit_cost_ngn')::numeric) end)), '[]'::jsonb)
  into v_rows from jsonb_array_elements(v_rows) x;
  select coalesce(sum((x->>'cost_at_quota')::numeric), 0), coalesce(sum((x->>'cost_at_average')::numeric), 0) into v_full, v_avg_cost from jsonb_array_elements(v_rows) x;
  -- A module that costs money with each use and has no limit leaves the cost at full use unknown, so no margin is given for it.
  select coalesce(jsonb_agg(x->>'name'), '[]'::jsonb) into v_unlim from jsonb_array_elements(v_rows) x where (x->>'quota') is null and (x->>'unit_cost_ngn')::numeric > 0;
  return jsonb_build_object('price_month', v_price, 'price_net', v_net, 'target_margin', v_margin, 'fixed_share_ngn', v_share, 'budget_ngn', v_budget,
    'modules', v_rows, 'unlimited_costed', v_unlim,
    'cost_full_ngn', case when jsonb_array_length(v_unlim) = 0 then v_full + v_share end,
    'margin_full', case when v_net > 0 and jsonb_array_length(v_unlim) = 0 then round((v_net - v_full - v_share) / v_net, 4) end,
    'cost_average_ngn', v_avg_cost + v_share, 'margin_average', case when v_net > 0 then round((v_net - v_avg_cost - v_share) / v_net, 4) end);
end $$;

revoke all on function private.user_org(uuid), private.subject_org(text), private.cost_usage(timestamptz, timestamptz), private.cost_rate_for(text, text, text, date),
  private.to_ngn(numeric, text, date), private.cost_lines(timestamptz, timestamptz, date, date), private.gemini_call_cost(text[], numeric, numeric),
  private.rate_ngn(text, text), private.module_unit_cost(text), private.meter_average(text) from public, anon, authenticated;
revoke all on function public.admin_costs(text), public.admin_save_cost_rate(jsonb), public.admin_remove_cost_rate(uuid), public.admin_save_fixed_cost(jsonb),
  public.admin_plan_calc(jsonb) from public, anon;
grant execute on function public.admin_costs(text), public.admin_save_cost_rate(jsonb), public.admin_remove_cost_rate(uuid), public.admin_save_fixed_cost(jsonb),
  public.admin_plan_calc(jsonb) to authenticated;
