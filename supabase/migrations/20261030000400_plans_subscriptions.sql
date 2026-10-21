-- Plans, modules, entitlements and subscriptions (TaxStreem item 6).
--
-- TaxStreem's admins define modules (a feature a business has or not, or a monthly quota) and plans that say, for each
-- module, whether it is included, the quota and whether going past it is blocked or only warned about. Every business
-- is on a plan: the one it subscribed to, or the plan an admin marked as the default. A business pays for a plan from
-- a linked card (Flutterwave tokenised charges) or from its Counta wallet; renewals run from the payments function.
--
-- The plan the migration adds is the default one, with every module included and no limits, so nothing a business does
-- today stops until an admin sets plans up. Sample businesses are never limited.
--
-- usage_events: what each AI call (and later other metered services) used, written by the edge functions (svc_usage).
-- The AI quotas count it, and the admin portal's costs page prices it (20261030000500).

-- ---------------------------------------------------------------------------
-- 1. Usage written by the edge functions
-- ---------------------------------------------------------------------------
create table if not exists public.usage_events (
  id bigint generated always as identity primary key,
  org_id uuid references public.orgs(id) on delete set null,
  at timestamptz not null default now(),
  service text not null check (service ~ '^[a-z0-9_]{2,30}$'),
  kind text not null check (length(kind) between 1 and 40),
  item text check (length(item) <= 80),
  qty_in numeric not null default 0 check (qty_in >= 0),
  qty_out numeric not null default 0 check (qty_out >= 0),
  searches int not null default 0 check (searches >= 0)
);
create index if not exists usage_events_at on public.usage_events(at);
create index if not exists usage_events_org on public.usage_events(org_id, service, kind, at) where org_id is not null;
alter table public.usage_events enable row level security;
revoke all on public.usage_events from anon, authenticated;

-- p: {org_id, service, kind, item, qty_in, qty_out, searches | grounded}
create or replace function public.svc_usage(p jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid;
begin
  begin v_org := nullif(p->>'org_id', '')::uuid; exception when others then v_org := null; end;
  if v_org is not null and not exists (select 1 from orgs where id = v_org) then v_org := null; end if;
  insert into usage_events (org_id, service, kind, item, qty_in, qty_out, searches)
  values (v_org, left(lower(coalesce(nullif(p->>'service', ''), 'other')), 30), left(coalesce(nullif(p->>'kind', ''), 'other'), 40), left(nullif(p->>'item', ''), 80),
    least(greatest(coalesce((p->>'qty_in')::numeric, 0), 0), 100000000), least(greatest(coalesce((p->>'qty_out')::numeric, 0), 0), 100000000),
    least(greatest(coalesce((p->>'searches')::int, case when (p->>'grounded')::boolean then 1 else 0 end), 0), 1000));
end $$;

-- What the AI quotas count: documents read, and questions answered.
create or replace function private.ai_read_kinds() returns text[]
language sql immutable as $$
  select array['read_invoice', 'read_statement', 'read_purchase_invoice', 'read_cac_document', 'read_nin_slip', 'read_product', 'supplier_invoice', 'extract_rows']
$$;
create or replace function private.ai_assistant_kinds() returns text[]
language sql immutable as $$
  select array['ask', 'chat', 'check', 'business_insights']
$$;

-- ---------------------------------------------------------------------------
-- 2. Modules, plans and entitlements
-- ---------------------------------------------------------------------------
create table if not exists public.plan_modules (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null check (length(name) between 2 and 60),
  kind text not null check (kind in ('feature', 'quota')),
  meter text check (meter in ('sales', 'ai_reads', 'assistant', 'call_minutes', 'whatsapp', 'emails', 'tin_checks', 'supplier_invoices', 'payouts',
    'users', 'locations', 'bank_feeds')),
  feature text check (feature in ('payments', 'bulk_payments', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'bank_feeds',
    'supplier_portal')),
  unit text,
  what text,
  unit_cost_ngn numeric(14,4) check (unit_cost_ngn >= 0),
  sort int not null default 100,
  active boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  check ((kind = 'quota' and meter is not null and feature is null) or (kind = 'feature' and feature is not null and meter is null))
);
alter table public.plan_modules enable row level security;
drop policy if exists plan_modules_read on public.plan_modules;
create policy plan_modules_read on public.plan_modules for select to authenticated using (true);
revoke insert, update, delete on public.plan_modules from anon, authenticated;
create index if not exists plan_modules_updated_by on public.plan_modules(updated_by);

create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z][a-z0-9_-]{1,29}$'),
  name text not null check (length(name) between 2 and 40),
  description text check (length(description) <= 400),
  price_month numeric(14,2) not null default 0 check (price_month >= 0),
  price_year numeric(14,2) check (price_year >= 0),
  trial_days int not null default 0 check (trial_days between 0 and 90),
  target_margin numeric(5,4) not null default 0.6 check (target_margin >= 0 and target_margin < 1),
  is_default boolean not null default false,
  public boolean not null default true,
  active boolean not null default true,
  sort int not null default 100,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (not is_default or active)
);
create unique index if not exists plans_one_default on public.plans(is_default) where is_default;
create index if not exists plans_updated_by on public.plans(updated_by);
alter table public.plans enable row level security;
drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select to authenticated using (active);
revoke insert, update, delete on public.plans from anon, authenticated;

create table if not exists public.plan_entitlements (
  plan_id uuid not null references public.plans(id) on delete cascade,
  module_key text not null references public.plan_modules(key) on delete cascade,
  included boolean not null default true,
  quota numeric(14,2) check (quota >= 0),
  enforce text not null default 'warn' check (enforce in ('block', 'warn')),
  primary key (plan_id, module_key)
);
create index if not exists plan_entitlements_module on public.plan_entitlements(module_key);
alter table public.plan_entitlements enable row level security;
drop policy if exists plan_entitlements_read on public.plan_entitlements;
create policy plan_entitlements_read on public.plan_entitlements for select to authenticated using (true);
revoke insert, update, delete on public.plan_entitlements from anon, authenticated;

-- What an admin set for one business, replacing the plan's entitlement for that module until the day given.
create table if not exists public.org_entitlement_overrides (
  org_id uuid not null references public.orgs(id) on delete cascade,
  module_key text not null references public.plan_modules(key) on delete cascade,
  included boolean not null default true,
  quota numeric(14,2) check (quota >= 0),
  enforce text not null default 'warn' check (enforce in ('block', 'warn')),
  until date,
  note text,
  set_by uuid references auth.users(id) on delete set null,
  set_at timestamptz not null default now(),
  primary key (org_id, module_key)
);
create index if not exists org_entitlement_overrides_module on public.org_entitlement_overrides(module_key);
create index if not exists org_entitlement_overrides_set_by on public.org_entitlement_overrides(set_by);
alter table public.org_entitlement_overrides enable row level security;
revoke all on public.org_entitlement_overrides from anon, authenticated;

-- Warnings already sent this month, so each goes once.
create table if not exists public.entitlement_notices (
  org_id uuid not null references public.orgs(id) on delete cascade,
  module_key text not null,
  month date not null,
  level text not null check (level in ('near', 'over')),
  at timestamptz not null default now(),
  primary key (org_id, module_key, month, level)
);
alter table public.entitlement_notices enable row level security;
revoke all on public.entitlement_notices from anon, authenticated;

insert into public.plan_modules (key, name, kind, meter, feature, unit, what, sort) values
  ('payments', 'Payments', 'feature', null, 'payments', null, 'Business account numbers, pay by transfer, payment links, QR codes and payouts.', 10),
  ('bulk_payments', 'Bulk payments', 'feature', null, 'bulk_payments', null, 'Paying many people at once from a spreadsheet, contractors included.', 11),
  ('martina', 'Martina', 'feature', null, 'martina', null, 'The guide and assistant, by voice and typing.', 12),
  ('phone_calls', 'Phone calls', 'feature', null, 'phone_calls', null, 'Martina phoning suppliers, staff and customers.', 13),
  ('payment_voice', 'Spoken announcements', 'feature', null, 'payment_voice', null, '"Payment received" and sales read back aloud.', 14),
  ('ai_reading', 'AI reading', 'feature', null, 'ai_reading', null, 'Invoices, statements, product photos and documents read by AI.', 15),
  ('whatsapp_channel', 'WhatsApp to customers', 'feature', null, 'whatsapp', null, 'Invoices, receipts and reminders by WhatsApp.', 16),
  ('email_channel', 'Email to customers', 'feature', null, 'email', null, 'Invoices, receipts and reminders by email.', 17),
  ('bank_feeds_on', 'Bank feeds', 'feature', null, 'bank_feeds', null, 'Bank accounts linked through Mono, read into the books.', 18),
  ('supplier_portal', 'Supplier invoice portal', 'feature', null, 'supplier_portal', null, 'A link suppliers use to upload their invoices.', 19),
  ('users', 'Team members', 'quota', 'users', null, 'people', 'People in the business, invited ones included.', 30),
  ('locations', 'Branches', 'quota', 'locations', null, 'branches', 'Shops, warehouses and other locations.', 31),
  ('sales', 'Sales a month', 'quota', 'sales', null, 'sales a month', 'Receipts and invoices recorded each month.', 32),
  ('ai_reads', 'AI reads a month', 'quota', 'ai_reads', null, 'documents a month', 'Invoices, statements, photos and documents read by AI.', 33),
  ('assistant', 'Questions to Martina a month', 'quota', 'assistant', null, 'questions a month', 'Typed questions and checks answered by Martina.', 34),
  ('call_minutes', 'Phone call minutes a month', 'quota', 'call_minutes', null, 'minutes a month', 'Minutes of Martina''s phone calls.', 35),
  ('whatsapp', 'WhatsApp messages a month', 'quota', 'whatsapp', null, 'messages a month', 'Messages to customers and suppliers by WhatsApp.', 36),
  ('emails', 'Emails a month', 'quota', 'emails', null, 'emails a month', 'Messages to customers and suppliers by email.', 37),
  ('tin_checks', 'Tax ID checks a month', 'quota', 'tin_checks', null, 'checks a month', 'Tax IDs checked with the NRS.', 38),
  ('supplier_invoices', 'Supplier invoices a month', 'quota', 'supplier_invoices', null, 'invoices a month', 'Supplier invoices uploaded and checked.', 39),
  ('payouts', 'Payouts a month', 'quota', 'payouts', null, 'payouts a month', 'Transfers from the wallet, bulk payments included.', 40),
  ('bank_feeds', 'Linked bank accounts', 'quota', 'bank_feeds', null, 'accounts', 'Bank accounts linked through Mono.', 41)
on conflict (key) do nothing;

insert into public.plans (code, name, description, price_month, price_year, is_default, public, sort)
select 'standard', 'Standard', 'Everything Counta does, with no limits. TaxStreem sets the plans businesses can choose.', 0, 0, true, true, 10
where not exists (select 1 from public.plans where is_default);

-- ---------------------------------------------------------------------------
-- 3. Subscriptions, cards and charges
-- ---------------------------------------------------------------------------
create table if not exists public.subscription_cards (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  token text not null,
  email text not null,
  last4 text,
  brand text,
  expiry text,
  active boolean not null default true,
  added_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists subscription_cards_org on public.subscription_cards(org_id) where active;
create index if not exists subscription_cards_added_by on public.subscription_cards(added_by);
alter table public.subscription_cards enable row level security;
revoke all on public.subscription_cards from anon, authenticated;

create table if not exists public.subscriptions (
  org_id uuid primary key references public.orgs(id) on delete cascade,
  plan_id uuid not null references public.plans(id),
  status text not null default 'active' check (status in ('trialing', 'active', 'past_due')),
  billing text not null default 'month' check (billing in ('month', 'year')),
  pay_method text check (pay_method in ('card', 'wallet')),
  card_id uuid references public.subscription_cards(id) on delete set null,
  current_period_start timestamptz,
  current_period_end timestamptz,
  trial_ends_at timestamptz,
  trial_used boolean not null default false,
  cancel_at_period_end boolean not null default false,
  next_plan_id uuid references public.plans(id),
  next_billing text check (next_billing in ('month', 'year')),
  past_due_since timestamptz,
  retry_at timestamptz,
  attempts int not null default 0,
  comp boolean not null default false,
  note text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists subscriptions_plan on public.subscriptions(plan_id);
create index if not exists subscriptions_next_plan on public.subscriptions(next_plan_id);
create index if not exists subscriptions_card on public.subscriptions(card_id);
create index if not exists subscriptions_due on public.subscriptions(current_period_end);
alter table public.subscriptions enable row level security;
revoke all on public.subscriptions from anon, authenticated;

create table if not exists public.subscription_charges (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  plan_id uuid not null references public.plans(id),
  billing text not null check (billing in ('month', 'year')),
  amount numeric(14,2) not null check (amount > 0),
  currency text not null default 'NGN',
  method text not null check (method in ('card', 'wallet')),
  kind text not null check (kind in ('start', 'renewal')),
  card_id uuid references public.subscription_cards(id) on delete set null,
  tx_ref text not null unique,
  provider_ref text,
  status text not null default 'pending' check (status in ('pending', 'sent', 'successful', 'failed', 'cancelled')),
  error text,
  journal_id uuid references public.journals(id) on delete set null,
  requested_by uuid references public.members(id) on delete set null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists subscription_charges_org on public.subscription_charges(org_id, created_at desc);
create index if not exists subscription_charges_open on public.subscription_charges(status, created_at) where status in ('pending', 'sent');
create index if not exists subscription_charges_plan on public.subscription_charges(plan_id);
create index if not exists subscription_charges_card on public.subscription_charges(card_id);
create index if not exists subscription_charges_journal on public.subscription_charges(journal_id);
create index if not exists subscription_charges_requested_by on public.subscription_charges(requested_by);
alter table public.subscription_charges enable row level security;
revoke all on public.subscription_charges from anon, authenticated;

create index if not exists sales_org_created on public.sales(org_id, created_at);

-- ---------------------------------------------------------------------------
-- 4. Which plan, what it allows, what has been used
-- ---------------------------------------------------------------------------
create or replace function private.default_plan_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from plans where is_default limit 1
$$;

create or replace function private.org_plan_id(p_org uuid) returns uuid
language sql stable security definer set search_path = public, private as $$
  select coalesce((select s.plan_id from subscriptions s join plans p on p.id = s.plan_id where s.org_id = p_org), private.default_plan_id())
$$;

-- The start of this month in Lagos.
create or replace function private.month_start() returns timestamptz
language sql stable as $$
  select date_trunc('month', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos'
$$;

create or replace function private.meter_usage(p_org uuid, p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := private.month_start(); v numeric;
begin
  case p_meter
    when 'sales' then
      select count(*) into v from sales where org_id = p_org and created_at >= v_from and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled');
    when 'ai_reads' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_read_kinds()) and at >= v_from;
    when 'assistant' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_assistant_kinds()) and at >= v_from;
    when 'call_minutes' then
      select coalesce(sum(ceil(coalesce(duration_secs, 0) / 60.0)), 0) into v from voice_calls where org_id = p_org and created_at >= v_from;
    when 'whatsapp' then
      select count(*) into v from messages where org_id = p_org and channel = 'whatsapp' and status <> 'failed' and created_at >= v_from;
    when 'emails' then
      select count(*) into v from messages where org_id = p_org and channel = 'email' and status <> 'failed' and created_at >= v_from;
    when 'tin_checks' then
      select count(*) into v from tin_checks where org_id = p_org and at >= v_from;
    when 'supplier_invoices' then
      select count(*) into v from supplier_invoices where org_id = p_org and created_at >= v_from;
    when 'payouts' then
      select count(*) into v from payouts where org_id = p_org and created_at >= v_from and status <> 'cancelled';
    when 'users' then
      select count(*) into v from members where org_id = p_org and status in ('active', 'invited');
    when 'locations' then
      select count(*) into v from locations where org_id = p_org;
    when 'bank_feeds' then
      select count(*) into v from bank_accounts where org_id = p_org and provider = 'mono' and active;
    else v := 0;
  end case;
  return coalesce(v, 0);
end $$;

-- One module for one business: the plan's entitlement, or an admin's override while it lasts, and (for a quota with a
-- limit, or when asked) what has been used.
create or replace function private.entitlement(p_org uuid, p_module text, p_usage boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare md public.plan_modules; pe public.plan_entitlements; ov public.org_entitlement_overrides; v_plan uuid := private.org_plan_id(p_org);
  v_inc boolean; v_quota numeric; v_enf text; v_used numeric; v_src text := 'plan';
begin
  select * into md from plan_modules where key = p_module;
  if not found then return null; end if;
  select * into pe from plan_entitlements where plan_id = v_plan and module_key = p_module;
  -- A module the plan does not list is included with no limit: a new module takes nothing away until a plan says so.
  v_inc := coalesce(pe.included, true); v_quota := pe.quota; v_enf := coalesce(pe.enforce, 'warn');
  select * into ov from org_entitlement_overrides where org_id = p_org and module_key = p_module
    and (until is null or until >= (now() at time zone 'Africa/Lagos')::date);
  if found then v_inc := ov.included; v_quota := ov.quota; v_enf := ov.enforce; v_src := 'override'; end if;
  if md.kind = 'quota' and (p_usage or (v_inc and v_quota is not null)) then v_used := private.meter_usage(p_org, md.meter); end if;
  return jsonb_build_object('module', md.key, 'name', md.name, 'kind', md.kind, 'meter', md.meter, 'feature', md.feature, 'unit', md.unit, 'what', md.what,
    'included', v_inc, 'quota', case when md.kind = 'quota' then v_quota end, 'enforce', v_enf, 'used', v_used,
    'left', case when md.kind = 'quota' and v_quota is not null then greatest(v_quota - coalesce(v_used, 0), 0) end, 'source', v_src,
    'until', case when v_src = 'override' then ov.until end);
end $$;

-- The switches admins set, for everyone or one business: three more with plans.
create or replace function private.feature_keys() returns text[]
language sql immutable as $$
  select array['new_businesses', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'payments', 'bulk_payments', 'bank_feeds',
    'supplier_portal']
$$;

-- Whether the business's plan lets it use a feature. Sample businesses always may.
create or replace function private.plan_allows(p_org uuid, p_feature text) returns boolean
language plpgsql stable security definer set search_path = public, private as $$
declare k text; e jsonb;
begin
  if p_org is null or coalesce((select is_sample from orgs where id = p_org), false) then return true; end if;
  for k in select key from plan_modules where active and kind = 'feature' and feature = p_feature loop
    e := private.entitlement(p_org, k);
    if not (e->>'included')::boolean and e->>'enforce' = 'block' then return false; end if;
  end loop;
  return true;
end $$;

-- A switch set for one business wins either way; then the platform switch; then the business's plan.
create or replace function private.feature_on(p_org uuid, p_feature text) returns boolean
language plpgsql stable security definer set search_path = public, private as $$
declare v boolean;
begin
  select enabled into v from org_switches where org_id = p_org and feature = p_feature;
  if found then return v; end if;
  if not coalesce((private.setting('switches')->>p_feature)::boolean, true) then return false; end if;
  return private.plan_allows(p_org, p_feature);
end $$;

-- What a member's screens need to know: features that are off for the business, and (under _plan) the ones its plan leaves out,
-- so the screen can say which.
create or replace function public.org_features(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare k text; v_out jsonb := '{}'::jsonb; v_plan jsonb := '{}'::jsonb;
begin
  perform private.require(p_org, null);
  foreach k in array private.feature_keys() loop
    if k <> 'new_businesses' then
      v_out := v_out || jsonb_build_object(k, private.feature_on(p_org, k));
      if not exists (select 1 from org_switches where org_id = p_org and feature = k) and not private.plan_allows(p_org, k) then
        v_plan := v_plan || jsonb_build_object(k, true);
      end if;
    end if;
  end loop;
  return v_out || jsonb_build_object('_plan', v_plan);
end $$;

create or replace function private.plan_fmt(n numeric) returns text
language sql immutable as $$
  select case when n is null then 'no limit' when n = trunc(n) then to_char(n, 'FM999,999,999,990') else to_char(n, 'FM999,999,999,990.##') end
$$;

-- A warning to the people who manage the business, once a month for each module and level.
create or replace function private.entitlement_notice(p_org uuid, p_module text, p_level text, p_title text, p_body text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_n int;
begin
  insert into entitlement_notices (org_id, module_key, month, level) values (p_org, p_module, private.month_start()::date, p_level)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform private.notify_perm(p_org, 'manage_settings', 'plan', p_title, p_body, '/settings/subscription', 'plan-' || p_module || '-' || p_level);
  end if;
end $$;

-- Checks every active quota module that counts p_meter before p_add more is used. A module whose limit blocks stops it with
-- a plain reason; one that warns lets it through and tells the managers at 80% and when it goes over.
create or replace function private.check_quota(p_org uuid, p_meter text, p_add numeric default 1) returns void
language plpgsql security definer set search_path = public, private as $$
declare md public.plan_modules; e jsonb; v_q numeric; v_used numeric; pl public.plans;
begin
  if p_org is null or coalesce((select is_sample from orgs where id = p_org), true) then return; end if;
  for md in select * from plan_modules where active and kind = 'quota' and meter = p_meter order by sort loop
    e := private.entitlement(p_org, md.key);
    if pl.id is null then select * into pl from plans where id = private.org_plan_id(p_org); end if;
    if not (e->>'included')::boolean then
      if e->>'enforce' = 'block' then
        raise exception '% is not in your plan (%). The owner can change the plan in Settings, Subscription.', md.name, pl.name using errcode = 'P0001';
      end if;
      continue;
    end if;
    v_q := (e->>'quota')::numeric;
    if v_q is null then continue; end if;
    v_used := coalesce((e->>'used')::numeric, 0);
    if v_used + p_add > v_q then
      if e->>'enforce' = 'block' then
        raise exception '%', case when md.meter in ('users', 'locations', 'bank_feeds')
          then format('Your plan (%s) includes %s %s. The owner can move to a bigger plan in Settings, Subscription.', pl.name, private.plan_fmt(v_q), md.unit)
          else format('Your plan (%s) includes %s %s, and this month''s are used up. The owner can move to a bigger plan in Settings, Subscription.',
            pl.name, private.plan_fmt(v_q), md.unit) end using errcode = 'P0001';
      end if;
      perform private.entitlement_notice(p_org, md.key, 'over', md.name || ': past your plan''s limit',
        format('%s of %s used this month on the %s plan. It still works; the owner can move to a bigger plan in Settings, Subscription.',
          private.plan_fmt(v_used + p_add), private.plan_fmt(v_q), pl.name));
    elsif v_q >= 10 and v_used + p_add >= 0.8 * v_q then
      perform private.entitlement_notice(p_org, md.key, 'near', md.name || ': 80% used',
        format('%s of %s used this month on the %s plan.', private.plan_fmt(v_used + p_add), private.plan_fmt(v_q), pl.name));
    end if;
  end loop;
end $$;

-- The checks, where the things counted are made.
create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') then perform private.check_quota(new.org_id, 'sales'); end if;
  elsif tg_table_name = 'members' then
    if new.role <> 'owner' and new.status in ('active', 'invited') then perform private.check_quota(new.org_id, 'users'); end if;
  elsif tg_table_name = 'locations' then
    perform private.check_quota(new.org_id, 'locations');
  elsif tg_table_name = 'payouts' then
    if new.batch_id is not null and not private.feature_on(new.org_id, 'bulk_payments') then
      raise exception 'Bulk payments are not in your plan. The owner can change the plan in Settings, Subscription.';
    end if;
    perform private.check_quota(new.org_id, 'payouts');
  elsif tg_table_name = 'supplier_invoices' then
    if new.source = 'portal' and not private.feature_on(new.org_id, 'supplier_portal') then
      raise exception 'This business is not taking invoices on its portal right now.';
    end if;
    perform private.check_quota(new.org_id, 'supplier_invoices');
  elsif tg_table_name = 'tin_checks' then
    perform private.check_quota(new.org_id, 'tin_checks');
  elsif tg_table_name = 'bank_accounts' then
    if new.provider = 'mono' and (tg_op = 'INSERT' or old.provider is distinct from 'mono') then
      if not private.feature_on(new.org_id, 'bank_feeds') then
        raise exception 'Bank feeds are not in your plan. The owner can change the plan in Settings, Subscription.';
      end if;
      perform private.check_quota(new.org_id, 'bank_feeds');
    end if;
  elsif tg_table_name = 'voice_calls' then
    perform private.check_quota(new.org_id, 'call_minutes');
  elsif tg_table_name = 'messages' then
    -- A message over a blocking limit is kept, marked failed with the reason, so whatever queued it carries on.
    begin
      perform private.check_quota(new.org_id, case when new.channel = 'whatsapp' then 'whatsapp' else 'emails' end);
    exception when sqlstate 'P0001' then
      new.status := 'failed'; new.error := left(sqlerrm, 300);
    end;
  end if;
  return new;
end $$;

drop trigger if exists sales_plan on public.sales;
create trigger sales_plan before insert on public.sales for each row execute function private.enforce_plan();
drop trigger if exists members_plan on public.members;
create trigger members_plan before insert on public.members for each row execute function private.enforce_plan();
drop trigger if exists locations_plan on public.locations;
create trigger locations_plan before insert on public.locations for each row execute function private.enforce_plan();
drop trigger if exists payouts_plan on public.payouts;
create trigger payouts_plan before insert on public.payouts for each row execute function private.enforce_plan();
drop trigger if exists supplier_invoices_plan on public.supplier_invoices;
create trigger supplier_invoices_plan before insert on public.supplier_invoices for each row execute function private.enforce_plan();
drop trigger if exists tin_checks_plan on public.tin_checks;
create trigger tin_checks_plan before insert on public.tin_checks for each row execute function private.enforce_plan();
drop trigger if exists bank_accounts_plan on public.bank_accounts;
create trigger bank_accounts_plan before insert or update of provider on public.bank_accounts for each row execute function private.enforce_plan();
drop trigger if exists voice_calls_plan on public.voice_calls;
create trigger voice_calls_plan before insert on public.voice_calls for each row execute function private.enforce_plan();
drop trigger if exists messages_plan on public.messages;
create trigger messages_plan before insert on public.messages for each row execute function private.enforce_plan();

-- For the edge functions: may this business use p_meter now (the AI quotas). {ok, message}
create or replace function public.svc_entitle(p_org uuid, p_meter text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.check_quota(p_org, p_meter);
  return jsonb_build_object('ok', true);
exception when sqlstate 'P0001' then
  return jsonb_build_object('ok', false, 'message', sqlerrm);
end $$;

-- ---------------------------------------------------------------------------
-- 5. What a business sees and chooses
-- ---------------------------------------------------------------------------
create or replace function private.plan_json(p_plan uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'description', p.description, 'price_month', p.price_month,
    'price_year', coalesce(p.price_year, p.price_month * 12), 'trial_days', p.trial_days, 'is_default', p.is_default, 'public', p.public, 'active', p.active,
    'entitlements', (select coalesce(jsonb_agg(jsonb_build_object('module', md.key, 'name', md.name, 'kind', md.kind, 'unit', md.unit,
        'included', coalesce(pe.included, true), 'quota', case when md.kind = 'quota' then pe.quota end, 'enforce', coalesce(pe.enforce, 'warn')) order by md.sort), '[]'::jsonb)
      from plan_modules md left join plan_entitlements pe on pe.plan_id = p.id and pe.module_key = md.key where md.active))
  from plans p where p.id = p_plan
$$;

create or replace function private.plan_price(p public.plans, p_billing text) returns numeric
language sql immutable as $$
  select case when p_billing = 'year' then coalesce(p.price_year, p.price_month * 12) else p.price_month end
$$;

create or replace function private.sub_json(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('status', coalesce(s.status, 'active'), 'billing', coalesce(s.billing, 'month'), 'pay_method', s.pay_method,
    'current_period_start', s.current_period_start, 'current_period_end', s.current_period_end, 'trial_ends_at', s.trial_ends_at,
    'trial_used', coalesce(s.trial_used, false), 'cancel_at_period_end', coalesce(s.cancel_at_period_end, false), 'past_due_since', s.past_due_since,
    'retry_at', s.retry_at, 'comp', coalesce(s.comp, false),
    'next_plan', case when s.next_plan_id is not null then jsonb_build_object('id', np.id, 'name', np.name, 'billing', s.next_billing) end,
    'card', (select jsonb_build_object('id', c.id, 'last4', c.last4, 'brand', c.brand, 'expiry', c.expiry) from subscription_cards c
             where c.org_id = p_org and c.active order by (c.id = s.card_id) desc, c.created_at desc limit 1))
  from (select 1) one left join subscriptions s on s.org_id = p_org left join plans np on np.id = s.next_plan_id
$$;

create or replace function public.subscription_state(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_plan uuid; k text; v_ents jsonb := '[]'::jsonb; w record;
begin
  m := private.require(p_org, 'manage_settings');
  v_plan := private.org_plan_id(p_org);
  for k in select key from plan_modules where active order by sort loop
    v_ents := v_ents || jsonb_build_array(private.entitlement(p_org, k, true));
  end loop;
  select wl.id, private.wallet_balance(wl.id) bal into w from wallets wl join orgs o on o.id = wl.org_id
  where wl.org_id = p_org and wl.rail = o.payment_rail and wl.status = 'active' limit 1;
  return jsonb_build_object(
    'plan', private.plan_json(v_plan), 'subscription', private.sub_json(p_org), 'entitlements', v_ents,
    'plans', (select coalesce(jsonb_agg(private.plan_json(p.id) order by p.sort, p.price_month), '[]'::jsonb) from plans p
              where p.active and (p.public or p.id = v_plan)),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'plan', pl.name, 'billing', c.billing, 'amount', c.amount,
        'method', c.method, 'kind', c.kind, 'status', c.status, 'error', c.error, 'paid_at', c.paid_at, 'tx_ref', c.tx_ref) order by c.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where org_id = p_org order by created_at desc limit 24) c join plans pl on pl.id = c.plan_id),
    'wallet', case when w.id is not null then jsonb_build_object('available', w.bal) end,
    'can_change', m.role in ('owner', 'admin'), 'is_sample', (select is_sample from orgs where id = p_org));
end $$;

-- What the owner chose. p: {plan_id, billing month|year, method card|wallet, use_saved}
-- Returns {action: done | scheduled | charge_card | checkout | wallet, charge_id, tx_ref, amount}; the payments function
-- carries out a charge, and the plan changes when it succeeds.
create or replace function public.subscription_start(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pl public.plans; cur public.plans; s public.subscriptions; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_method text := nullif(p->>'method', ''); v_price numeric; v_cur_price numeric; c public.subscription_charges; v_card uuid; v_bal numeric;
begin
  m := private.require(p_org, 'manage_settings');
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business stays on its plan.'; end if;
  if v_billing not in ('month', 'year') then raise exception 'Pay monthly or yearly.'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  select * into cur from plans where id = private.org_plan_id(p_org);
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active and (public or id = cur.id);
  if not found then raise exception 'Choose a plan.'; end if;
  v_price := private.plan_price(pl, v_billing);
  if pl.id = cur.id and coalesce(s.billing, 'month') = v_billing and coalesce(s.status, 'active') <> 'past_due' and not coalesce(s.cancel_at_period_end, false)
     and s.next_plan_id is null and (v_price = 0 or s.pay_method is not null) then
    raise exception 'The business is on % already.', pl.name;
  end if;

  -- A free plan starts at once.
  if v_price = 0 then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, current_period_start, current_period_end)
    values (p_org, pl.id, 'active', v_billing, null, now(), now() + case when v_billing = 'year' then interval '1 year' else interval '1 month' end)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = null, card_id = null,
      current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end, trial_ends_at = null,
      cancel_at_period_end = false, next_plan_id = null, next_billing = null, past_due_since = null, retry_at = null, attempts = 0, updated_at = now();
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and status = 'pending';
    return jsonb_build_object('action', 'done', 'state', public.subscription_state(p_org));
  end if;

  if coalesce(v_method, '') not in ('card', 'wallet') then raise exception 'Pay by card or from the wallet.'; end if;
  select id into v_card from subscription_cards where org_id = p_org and active order by (id = s.card_id) desc, created_at desc limit 1;

  -- A first trial of a plan with one: no charge until it ends.
  if pl.trial_days > 0 and not coalesce(s.trial_used, false) and not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful') then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_ends_at, trial_used)
    values (p_org, pl.id, 'trialing', v_billing, v_method, case when v_method = 'card' then v_card end, now(), now() + make_interval(days => pl.trial_days),
      now() + make_interval(days => pl.trial_days), true)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'trialing', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = excluded.card_id, current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
      trial_ends_at = excluded.trial_ends_at, trial_used = true, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, updated_at = now();
    return jsonb_build_object('action', 'done', 'trial', true, 'state', public.subscription_state(p_org));
  end if;

  -- A cheaper plan while a paid period runs: it starts when the period ends.
  v_cur_price := private.plan_price(cur, coalesce(s.billing, 'month'));
  if s.status = 'active' and s.current_period_end > now() and v_cur_price > 0 and not coalesce(s.comp, false)
     and v_price < private.plan_price(cur, v_billing) then
    update subscriptions set next_plan_id = pl.id, next_billing = v_billing, pay_method = v_method, card_id = coalesce(v_card, card_id),
      cancel_at_period_end = false, updated_at = now() where org_id = p_org;
    return jsonb_build_object('action', 'scheduled', 'at', s.current_period_end, 'state', public.subscription_state(p_org));
  end if;

  if v_method = 'wallet' then
    select private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval')), 0)
      into v_bal from wallets w join orgs o on o.id = w.org_id where w.org_id = p_org and w.rail = o.payment_rail and w.status = 'active';
    if v_bal is null then raise exception 'Open the business wallet in Payments first, or pay by card.'; end if;
    if v_bal < v_price then
      raise exception 'The wallet has ₦% available and the plan costs ₦%. Fund the wallet or pay by card.', to_char(v_bal, 'FM999,999,999,990.00'),
        to_char(v_price, 'FM999,999,999,990.00');
    end if;
  end if;
  -- The same choice made again within half an hour uses the charge already waiting.
  select * into c from subscription_charges where org_id = p_org and kind = 'start' and status = 'pending' and plan_id = pl.id and billing = v_billing
    and method = v_method and created_at > now() - interval '30 minutes' order by created_at desc limit 1;
  if not found then
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and kind = 'start' and status = 'pending';
    insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, requested_by)
    values (p_org, pl.id, v_billing, v_price, v_method, 'start', case when v_method = 'card' and coalesce((p->>'use_saved')::boolean, true) then v_card end,
      'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), m.id)
    returning * into c;
  end if;
  return jsonb_build_object('action', case when v_method = 'wallet' then 'wallet' when c.card_id is not null then 'charge_card' else 'checkout' end,
    'charge_id', c.id, 'tx_ref', c.tx_ref, 'amount', c.amount);
end $$;

-- Stop renewing: the plan runs to the end of the period, then the business moves to the default plan. p_on false undoes it.
create or replace function public.subscription_cancel(p_org uuid, p_on boolean default true) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.subscriptions;
begin
  m := private.require(p_org, 'manage_settings');
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  if not found or s.plan_id = private.default_plan_id() then raise exception 'The business is on the standard plan; there is nothing to cancel.'; end if;
  update subscriptions set cancel_at_period_end = p_on, next_plan_id = case when p_on then null else next_plan_id end, updated_at = now() where org_id = p_org;
  return public.subscription_state(p_org);
end $$;

-- How renewals are paid. p: {method card|wallet, remove_card_id}
create or replace function public.subscription_method(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_card uuid;
begin
  m := private.require(p_org, 'manage_settings');
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if nullif(p->>'remove_card_id', '') is not null then
    update subscription_cards set active = false where id = (p->>'remove_card_id')::uuid and org_id = p_org;
    update subscriptions set card_id = null, pay_method = case when pay_method = 'card' then null else pay_method end, updated_at = now()
    where org_id = p_org and card_id = (p->>'remove_card_id')::uuid;
  end if;
  if p->>'method' in ('card', 'wallet') then
    select id into v_card from subscription_cards where org_id = p_org and active order by created_at desc limit 1;
    if p->>'method' = 'card' and v_card is null then raise exception 'Add a card first: pay for the plan by card once, and Counta keeps it for renewals.'; end if;
    update subscriptions set pay_method = p->>'method', card_id = case when p->>'method' = 'card' then v_card else card_id end, updated_at = now() where org_id = p_org;
  end if;
  return public.subscription_state(p_org);
end $$;

-- ---------------------------------------------------------------------------
-- 6. For the payments function
-- ---------------------------------------------------------------------------
create or replace function public.svc_subscription_charge(p_charge uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('charge', to_jsonb(c) - 'journal_id', 'plan', jsonb_build_object('name', pl.name, 'code', pl.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'phone', o.phone,
      'email', coalesce((select coalesce(mb.email, u.email) from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = o.id and mb.role = 'owner'
        order by mb.created_at limit 1), o.email)),
    'card', (select jsonb_build_object('token', k.token, 'email', k.email, 'last4', k.last4) from subscription_cards k
             where k.org_id = c.org_id and k.active and (c.card_id is null or k.id = c.card_id) order by (k.id = c.card_id) desc, k.created_at desc limit 1),
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'rail', w.rail) from wallets w
               where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1))
  from subscription_charges c join orgs o on o.id = c.org_id join plans pl on pl.id = c.plan_id where c.id = p_charge
$$;

create or replace function public.svc_subscription_by_ref(p_tx_ref text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from subscription_charges where tx_ref = p_tx_ref
$$;

-- What the rail said about a charge. p: {status sent|successful|failed, provider_ref, amount, currency, error,
-- card {token, last4, brand, expiry, email}}
create or replace function public.svc_subscription_charge_update(p_tx_ref text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.subscription_charges; s public.subscriptions; pl public.plans; v_card uuid; v_start timestamptz; v_end timestamptz; o public.orgs;
  v_net numeric; v_vat numeric; v_ledger text; j public.journals; v_status text := p->>'status';
begin
  select * into c from subscription_charges where tx_ref = p_tx_ref for update;
  if not found then raise exception 'Charge not found.'; end if;
  if c.status in ('successful', 'cancelled') or (c.status = 'failed' and v_status <> 'successful') then
    return jsonb_build_object('status', c.status, 'unchanged', true);
  end if;
  select * into o from orgs where id = c.org_id;
  select * into pl from plans where id = c.plan_id;
  if v_status = 'sent' then
    update subscription_charges set status = 'sent', provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now() where id = c.id;
    return jsonb_build_object('status', 'sent');
  end if;
  if v_status = 'successful' and (coalesce((p->>'amount')::numeric, 0) < c.amount - 0.01 or coalesce(nullif(p->>'currency', ''), 'NGN') <> 'NGN') then
    v_status := 'failed'; p := p || jsonb_build_object('error', format('The rail reports %s %s, not ₦%s.', coalesce(p->>'currency', 'NGN'), coalesce(p->>'amount', '0'), c.amount));
  end if;
  if v_status = 'successful' then
    if nullif(p->'card'->>'token', '') is not null then
      select id into v_card from subscription_cards where org_id = c.org_id and token = p->'card'->>'token' and active;
      if v_card is null then
        insert into subscription_cards (org_id, token, email, last4, brand, expiry, added_by)
        values (c.org_id, p->'card'->>'token', coalesce(nullif(p->'card'->>'email', ''), 'unknown@counta.ng'), left(p->'card'->>'last4', 4),
          left(p->'card'->>'brand', 30), left(p->'card'->>'expiry', 7), c.requested_by)
        returning id into v_card;
      end if;
    end if;
    select * into s from subscriptions where org_id = c.org_id for update;
    v_start := case when c.kind = 'renewal' and s.current_period_end is not null and s.current_period_end > now() - interval '7 days'
                    then s.current_period_end else now() end;
    v_end := v_start + case when c.billing = 'year' then interval '1 year' else interval '1 month' end;
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_used)
    values (c.org_id, c.plan_id, 'active', c.billing, c.method, coalesce(v_card, c.card_id), v_start, v_end, false)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = coalesce(excluded.card_id, subscriptions.card_id), current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end, trial_ends_at = null, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, updated_at = now();
    -- Paid from the wallet: the books show the money leaving it, as a software subscription (VAT included in the price).
    if c.method = 'wallet' then
      select b.ledger_code into v_ledger from wallets w join bank_accounts b on b.id = w.bank_account_id
      where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1;
      if v_ledger is not null then
        v_net := case when o.vat_registered then round(c.amount / (1 + private.vat_rate(private.local_day(c.org_id, now()))), 2) else c.amount end;
        v_vat := c.amount - v_net;
        j := private.post_entry(c.org_id, 'Counta ' || pl.name || ' plan · ' || c.tx_ref, 'subscription', c.id, null, null, jsonb_build_array(
          jsonb_build_object('code', coalesce((select code from accounts where code = '6303'), private.acct(c.org_id, 'expenses_default')), 'debit', v_net,
            'memo', 'Counta ' || pl.name || ' plan, ' || case when c.billing = 'year' then 'a year' else 'a month' end),
          jsonb_build_object('code', private.acct(c.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'VAT on the Counta plan'),
          jsonb_build_object('code', v_ledger, 'credit', c.amount, 'memo', 'Counta plan · ' || c.tx_ref)),
          now(), jsonb_build_object('origin', 'system', 'evidence', jsonb_build_array(jsonb_build_object('type', 'subscription', 'ref', c.tx_ref))));
      end if;
    end if;
    update subscription_charges set status = 'successful', paid_at = now(), provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref),
      card_id = coalesce(v_card, card_id), journal_id = j.id, error = null, updated_at = now() where id = c.id;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Counta plan paid: ' || pl.name,
      format('₦%s %s. It runs to %s.', to_char(c.amount, 'FM999,999,999,990.00'), case when c.method = 'wallet' then 'from the wallet' else 'by card' end,
        to_char(v_end at time zone 'Africa/Lagos', 'DD Mon YYYY')), '/settings/subscription', 'sub-' || c.id);
    return jsonb_build_object('status', 'successful', 'period_end', v_end);
  end if;
  -- Failed.
  update subscription_charges set status = 'failed', error = left(coalesce(nullif(p->>'error', ''), 'The payment did not go through.'), 300),
    provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now() where id = c.id;
  if c.kind = 'renewal' then
    update subscriptions set status = 'past_due', past_due_since = coalesce(past_due_since, now()), attempts = attempts + 1, retry_at = now() + interval '1 day',
      updated_at = now() where org_id = c.org_id;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Counta plan payment failed',
      format('%s. Counta tries again tomorrow; after three days the business moves to the %s plan. Check the card or fund the wallet in Settings, Subscription.',
        left(coalesce(nullif(p->>'error', ''), 'The payment did not go through'), 200), (select name from plans where id = private.default_plan_id())),
      '/settings/subscription', 'sub-fail-' || c.org_id);
  end if;
  return jsonb_build_object('status', 'failed');
end $$;

create or replace function private.to_default_plan(p_org uuid, p_why text) returns void
language plpgsql security definer set search_path = public, private as $$
declare d public.plans;
begin
  select * into d from plans where id = private.default_plan_id();
  update subscriptions set plan_id = d.id, status = 'active', billing = 'month', pay_method = null, current_period_start = now(),
    current_period_end = now() + interval '1 month', trial_ends_at = null, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
    past_due_since = null, retry_at = null, attempts = 0, updated_at = now(), note = left(p_why, 200)
  where org_id = p_org;
  perform private.notify_perm(p_org, 'manage_settings', 'plan', 'Now on the ' || d.name || ' plan', p_why, '/settings/subscription', 'sub-down-' || p_org);
end $$;

create or replace function private.renewal_charge(s public.subscriptions, p_plan uuid, p_billing text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare pl public.plans; v_id uuid; v_card uuid;
begin
  select * into pl from plans where id = p_plan;
  select id into v_card from subscription_cards where org_id = s.org_id and active order by (id = s.card_id) desc, created_at desc limit 1;
  insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref)
  values (s.org_id, pl.id, p_billing, private.plan_price(pl, p_billing), s.pay_method, 'renewal', case when s.pay_method = 'card' then v_card end,
    'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)))
  returning id into v_id;
  return v_id;
end $$;

-- The day's subscription work, done in the database: trials and periods that ended, cancellations, cheaper plans chosen,
-- payments three days overdue. Returns the charges the payments function must now make: [{charge_id, method}].
create or replace function public.svc_subscription_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.subscriptions; pl public.plans; v_out jsonb := '[]'::jsonb; v_id uuid; v_has_card boolean; v_np public.plans; v_default uuid := private.default_plan_id();
begin
  for s in select * from subscriptions where current_period_end <= now() or status = 'past_due' for update skip locked loop
    select * into pl from plans where id = s.plan_id;
    v_has_card := exists (select 1 from subscription_cards where org_id = s.org_id and active);
    if exists (select 1 from subscription_charges where org_id = s.org_id and kind = 'renewal' and status in ('pending', 'sent') and created_at > now() - interval '6 hours') then
      continue;
    end if;
    if s.plan_id = v_default or s.comp or private.plan_price(pl, s.billing) = 0 then
      -- Free and complimentary plans roll on.
      if s.current_period_end <= now() then
        update subscriptions set current_period_start = current_period_end,
          current_period_end = current_period_end + case when billing = 'year' then interval '1 year' else interval '1 month' end,
          status = 'active', past_due_since = null, retry_at = null, attempts = 0, updated_at = now() where org_id = s.org_id;
      end if;
      continue;
    end if;
    if s.cancel_at_period_end and s.current_period_end <= now() then
      perform private.to_default_plan(s.org_id, format('The %s plan was cancelled and has ended.', pl.name));
      continue;
    end if;
    if s.status = 'past_due' and s.past_due_since < now() - interval '3 days' then
      perform private.to_default_plan(s.org_id, format('The %s plan was not paid for three days.', pl.name));
      continue;
    end if;
    if s.status = 'past_due' and s.retry_at > now() then continue; end if;
    if s.current_period_end > now() and s.status <> 'past_due' then continue; end if;
    if s.next_plan_id is not null then
      select * into v_np from plans where id = s.next_plan_id;
      if private.plan_price(v_np, coalesce(s.next_billing, s.billing)) = 0 then
        update subscriptions set plan_id = v_np.id, billing = coalesce(next_billing, billing), pay_method = null, next_plan_id = null, next_billing = null,
          current_period_start = now(), current_period_end = now() + interval '1 month', status = 'active', updated_at = now() where org_id = s.org_id;
        continue;
      end if;
    end if;
    if s.pay_method is null or (s.pay_method = 'card' and not v_has_card) then
      if s.status = 'trialing' then
        perform private.to_default_plan(s.org_id, format('The %s trial ended with no way to pay chosen.', pl.name));
      elsif s.status <> 'past_due' then
        update subscriptions set status = 'past_due', past_due_since = now(), retry_at = now() + interval '1 day', updated_at = now() where org_id = s.org_id;
        perform private.notify_perm(s.org_id, 'manage_settings', 'plan', 'Choose how to pay for Counta',
          format('The %s plan is due and no card or wallet is set to pay it. After three days the business moves to the standard plan.', pl.name),
          '/settings/subscription', 'sub-nomethod-' || s.org_id);
      end if;
      continue;
    end if;
    v_id := private.renewal_charge(s, coalesce(s.next_plan_id, s.plan_id), coalesce(s.next_billing, s.billing));
    v_out := v_out || jsonb_build_array(jsonb_build_object('charge_id', v_id, 'method', s.pay_method));
  end loop;
  return v_out;
end $$;

-- Charges waiting on the rail: checkouts never finished (asked again for two days), card charges and wallet moves sent.
create or replace function public.svc_subscription_open() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tx_ref', tx_ref, 'method', method, 'status', status, 'provider_ref', provider_ref, 'kind', kind,
    'age_minutes', round(extract(epoch from now() - created_at) / 60))), '[]'::jsonb)
  from subscription_charges where status in ('pending', 'sent') and created_at > now() - interval '2 days' and created_at < now() - interval '2 minutes'
$$;
create or replace function public.svc_subscription_expire(p_tx_ref text) returns void
language sql security definer set search_path = public as $$
  update subscription_charges set status = 'cancelled', error = 'The checkout was not finished.', updated_at = now()
  where tx_ref = p_tx_ref and status = 'pending' and method = 'card' and kind = 'start'
$$;

-- ---------------------------------------------------------------------------
-- 7. The admin portal
-- ---------------------------------------------------------------------------
-- The keys and settings the portal lists: TaxStreem's Flutterwave merchant ID joins them, for plans paid from wallets.
create or replace function private.secret_catalog() returns table (name text, grp text, label text, secret boolean, hint text, sort int)
language sql immutable as $$
  values
    ('GOOGLE_APPLICATION_CREDENTIALS_JSON', 'gemini', 'Service account key (JSON)', true, 'A Google Cloud service account with the Vertex AI User role. Paste the whole key file.', 101),
    ('GOOGLE_CLOUD_PROJECT', 'gemini', 'Google Cloud project', false, 'Leave empty to use the key''s own project.', 102),
    ('GOOGLE_CLOUD_LOCATION', 'gemini', 'Vertex AI region', false, 'us-central1 unless the project uses another region.', 103),
    ('GEMINI_MODEL', 'gemini', 'Gemini model', false, 'Leave empty for gemini-3.8-flash.', 104),
    ('GEMINI_API_KEY', 'gemini', 'Gemini API key (fallback)', true, 'Only used when there is no service account key.', 105),
    ('ELEVENLABS_API_KEY', 'elevenlabs', 'API key', true, 'Needs access to text to speech, voices, agents and phone numbers.', 201),
    ('ELEVENLABS_PHONE_NUMBER_ID', 'elevenlabs', 'Phone number for calls', false, 'Only needed when ElevenLabs has more than one number. The id from Phone Numbers in ElevenLabs.', 202),
    ('ELEVENLABS_TTS_MODEL', 'elevenlabs', 'Voice model for announcements', false, 'Leave empty for eleven_flash_v2_5.', 203),
    ('FLW_SECRET_KEY', 'flutterwave', 'Secret key', true, 'From Flutterwave, Settings, API keys. Live keys start FLWSECK-.', 301),
    ('FLW_PUBLIC_KEY', 'flutterwave', 'Public key', false, 'From the same page. Starts FLWPUBK-.', 302),
    ('FLW_WEBHOOK_HASH', 'flutterwave', 'Webhook secret hash', true, 'The same value as Secret hash in Flutterwave''s webhook settings.', 303),
    ('FLW_RELAY_URL', 'flutterwave', 'Transfer relay address', false, 'The https address of TaxStreem''s transfer relay (the server with the fixed IP address whitelisted on Flutterwave).', 304),
    ('FLW_RELAY_SECRET', 'flutterwave', 'Transfer relay secret', true, 'The 64 characters after RELAY_SECRET= in /etc/counta-relay.env on the relay server. Signs every request Counta sends through it.', 305),
    ('FLW_MERCHANT_ID', 'flutterwave', 'TaxStreem merchant ID', false, 'TaxStreem''s own Flutterwave merchant ID (Flutterwave, Settings, Business preferences). Counta plans paid from a business''s wallet go to this account.', 306),
    ('MONO_SECRET_KEY', 'mono', 'Secret key', true, 'From the Mono dashboard, for bank feeds.', 401),
    ('MONO_PUBLIC_KEY', 'mono', 'Public key', false, 'From the same app in the Mono dashboard.', 402),
    ('MONO_WEBHOOK_SECRET', 'mono', 'Webhook secret', true, 'The same value as the webhook secret in the Mono dashboard.', 403),
    ('MONO_LOOKUP_SECRET_KEY', 'mono', 'Lookup key (optional)', true, 'A separate key for CAC, Tax ID and NIN lookups. Without it the secret key is used.', 404),
    ('RESEND_API_KEY', 'email', 'Resend API key', true, 'From Resend, API keys, with sending access.', 501),
    ('RESEND_FROM', 'email', 'Sending address', false, 'An address on the domain verified in Resend, such as billing@taxstreem.com. Customers see "Business name via Counta".', 502),
    ('WHATSAPP_TOKEN', 'whatsapp', 'Access token', true, 'A permanent system user token from Meta Business, with WhatsApp messaging access.', 601),
    ('WHATSAPP_PHONE_NUMBER_ID', 'whatsapp', 'Phone number id', false, 'From WhatsApp, API setup, in the Meta app.', 602),
    ('WHATSAPP_BUSINESS_ACCOUNT_ID', 'whatsapp', 'Business account id', false, 'From the same page.', 603),
    ('WHATSAPP_APP_SECRET', 'whatsapp', 'App secret', true, 'From the Meta app''s basic settings. Checks that webhooks come from Meta.', 604),
    ('WHATSAPP_VERIFY_TOKEN', 'whatsapp', 'Webhook verify token', true, 'Any long random text, entered in the same place in the Meta app.', 605),
    ('WHATSAPP_TEMPLATE_LANG', 'whatsapp', 'Template language', false, 'en unless the message templates were approved in another language.', 606),
    ('NUMENS_API_URL', 'numens', 'Numens address', false, 'The https address of TaxStreem''s tax model.', 701),
    ('NUMENS_API_KEY', 'numens', 'Numens key', true, null, 702),
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903)
$$;

create or replace function public.admin_plans() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'modules', (select coalesce(jsonb_agg(to_jsonb(md) - 'updated_by' order by md.sort, md.key), '[]'::jsonb) from plan_modules md),
    'plans', (select coalesce(jsonb_agg(private.plan_json(p.id) || jsonb_build_object('target_margin', p.target_margin, 'sort', p.sort, 'updated_at', p.updated_at,
        'businesses', (select count(*) from orgs o where not o.is_sample and private.org_plan_id(o.id) = p.id),
        'mrr', (select coalesce(sum(case when s.billing = 'year' then private.plan_price(p, 'year') / 12 else p.price_month end), 0)
                from subscriptions s where s.plan_id = p.id and s.status in ('active', 'past_due') and not s.comp)) order by p.sort, p.price_month), '[]'::jsonb)
      from plans p),
    'features', to_jsonb(array['payments', 'bulk_payments', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'bank_feeds', 'supplier_portal']),
    'meters', to_jsonb(array['sales', 'ai_reads', 'assistant', 'call_minutes', 'whatsapp', 'emails', 'tin_checks', 'supplier_invoices', 'payouts', 'users', 'locations', 'bank_feeds']));
end $$;

-- p: {key, name, kind, meter, feature, unit, what, unit_cost_ngn, sort, active}
create or replace function public.admin_save_module(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff();
begin
  insert into plan_modules (key, name, kind, meter, feature, unit, what, unit_cost_ngn, sort, active, updated_by, updated_at)
  values (lower(trim(p->>'key')), trim(p->>'name'), p->>'kind', nullif(p->>'meter', ''), nullif(p->>'feature', ''), nullif(trim(p->>'unit'), ''),
    nullif(trim(p->>'what'), ''), nullif(p->>'unit_cost_ngn', '')::numeric, coalesce(nullif(p->>'sort', '')::int, 100), coalesce((p->>'active')::boolean, true), v_uid, now())
  on conflict (key) do update set name = excluded.name, kind = excluded.kind, meter = excluded.meter, feature = excluded.feature, unit = excluded.unit,
    what = excluded.what, unit_cost_ngn = excluded.unit_cost_ngn, sort = excluded.sort, active = excluded.active, updated_by = v_uid, updated_at = now();
  perform private.audit('save_module', lower(trim(p->>'key')), p);
  return public.admin_plans();
end $$;

-- p: {id?, code, name, description, price_month, price_year, trial_days, target_margin, public, active, sort, is_default,
--     entitlements: [{module, included, quota, enforce}]}
create or replace function public.admin_save_plan(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); v_id uuid := nullif(p->>'id', '')::uuid; pl public.plans; x jsonb; v_default boolean := coalesce((p->>'is_default')::boolean, false);
begin
  if v_id is not null then
    select * into pl from plans where id = v_id for update;
    if not found then raise exception 'Plan not found.'; end if;
    if pl.is_default and not v_default then raise exception 'Mark another plan as the default first: every business needs one to fall back on.'; end if;
    if pl.is_default and not coalesce((p->>'active')::boolean, true) then raise exception 'The default plan cannot be switched off.'; end if;
    if not coalesce((p->>'active')::boolean, true) and exists (select 1 from subscriptions where plan_id = v_id) then
      raise exception '% is in use. Move its businesses to another plan before switching it off.', pl.name;
    end if;
  end if;
  if coalesce(nullif(p->>'price_month', '')::numeric, 0) < 0 then raise exception 'Prices cannot be below zero.'; end if;
  if v_default then update plans set is_default = false where is_default and id is distinct from v_id; end if;
  if v_id is null then
    insert into plans (code, name, description, price_month, price_year, trial_days, target_margin, public, active, sort, is_default, updated_by)
    values (lower(trim(p->>'code')), trim(p->>'name'), nullif(trim(p->>'description'), ''), coalesce(nullif(p->>'price_month', '')::numeric, 0),
      nullif(p->>'price_year', '')::numeric, coalesce(nullif(p->>'trial_days', '')::int, 0), coalesce(nullif(p->>'target_margin', '')::numeric, 0.6),
      coalesce((p->>'public')::boolean, true), coalesce((p->>'active')::boolean, true), coalesce(nullif(p->>'sort', '')::int, 100), v_default, v_uid)
    returning * into pl;
  else
    update plans set code = lower(trim(p->>'code')), name = trim(p->>'name'), description = nullif(trim(p->>'description'), ''),
      price_month = coalesce(nullif(p->>'price_month', '')::numeric, 0), price_year = nullif(p->>'price_year', '')::numeric,
      trial_days = coalesce(nullif(p->>'trial_days', '')::int, 0), target_margin = coalesce(nullif(p->>'target_margin', '')::numeric, 0.6),
      public = coalesce((p->>'public')::boolean, true), active = coalesce((p->>'active')::boolean, true), sort = coalesce(nullif(p->>'sort', '')::int, 100),
      is_default = v_default, updated_by = v_uid, updated_at = now()
    where id = v_id returning * into pl;
  end if;
  if not exists (select 1 from plans where is_default) then raise exception 'One plan must be the default.'; end if;
  if jsonb_typeof(p->'entitlements') = 'array' then
    for x in select * from jsonb_array_elements(p->'entitlements') loop
      if not exists (select 1 from plan_modules where key = x->>'module') then raise exception 'Unknown module %.', x->>'module'; end if;
      insert into plan_entitlements (plan_id, module_key, included, quota, enforce)
      values (pl.id, x->>'module', coalesce((x->>'included')::boolean, true), nullif(x->>'quota', '')::numeric, coalesce(nullif(x->>'enforce', ''), 'warn'))
      on conflict (plan_id, module_key) do update set included = excluded.included, quota = excluded.quota, enforce = excluded.enforce;
    end loop;
  end if;
  perform private.audit('save_plan', pl.code, p - 'entitlements' || jsonb_build_object('entitlements', jsonb_array_length(coalesce(p->'entitlements', '[]'::jsonb))));
  return public.admin_plans();
end $$;

-- A business's plan, as an admin sees and sets it.
create or replace function public.admin_org_plan(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare k text; v_ents jsonb := '[]'::jsonb;
begin
  perform private.require_staff(false);
  for k in select key from plan_modules where active order by sort loop
    v_ents := v_ents || jsonb_build_array(private.entitlement(p_org, k, true));
  end loop;
  return jsonb_build_object('plan', private.plan_json(private.org_plan_id(p_org)), 'subscription', private.sub_json(p_org), 'entitlements', v_ents,
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('at', c.created_at, 'amount', c.amount, 'method', c.method, 'kind', c.kind, 'status', c.status,
        'error', c.error, 'plan', pl.name) order by c.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where org_id = p_org order by created_at desc limit 12) c join plans pl on pl.id = c.plan_id));
end $$;

-- p: {plan_id, comp, months, note}: put a business on a plan without a charge (complimentary when comp), for months (default 1).
create or replace function public.admin_set_org_plan(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); pl public.plans; v_months int := least(greatest(coalesce(nullif(p->>'months', '')::int, 1), 1), 36);
begin
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active;
  if not found then raise exception 'Choose a plan.'; end if;
  insert into subscriptions (org_id, plan_id, status, billing, current_period_start, current_period_end, comp, note)
  values (p_org, pl.id, 'active', 'month', now(), now() + make_interval(months => v_months), coalesce((p->>'comp')::boolean, false), left(nullif(trim(p->>'note'), ''), 200))
  on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end, comp = excluded.comp, note = excluded.note, trial_ends_at = null, cancel_at_period_end = false,
    next_plan_id = null, next_billing = null, past_due_since = null, retry_at = null, attempts = 0, updated_at = now();
  perform private.audit('set_org_plan', p_org::text, p);
  return public.admin_org_plan(p_org);
end $$;

-- p: {module, included, quota, enforce, until, note, remove}
create or replace function public.admin_set_override(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff();
begin
  if not exists (select 1 from plan_modules where key = p->>'module') then raise exception 'Unknown module.'; end if;
  if coalesce((p->>'remove')::boolean, false) then
    delete from org_entitlement_overrides where org_id = p_org and module_key = p->>'module';
  else
    insert into org_entitlement_overrides (org_id, module_key, included, quota, enforce, until, note, set_by)
    values (p_org, p->>'module', coalesce((p->>'included')::boolean, true), nullif(p->>'quota', '')::numeric, coalesce(nullif(p->>'enforce', ''), 'warn'),
      nullif(p->>'until', '')::date, left(nullif(trim(p->>'note'), ''), 200), v_uid)
    on conflict (org_id, module_key) do update set included = excluded.included, quota = excluded.quota, enforce = excluded.enforce, until = excluded.until,
      note = excluded.note, set_by = v_uid, set_at = now();
  end if;
  perform private.audit('set_override', p_org::text, p);
  return public.admin_org_plan(p_org);
end $$;

-- The subscriptions dashboard. p: {search, status, limit}
create or replace function public.admin_subscriptions(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := private.month_start(); v_q text := nullif(trim(p->>'search'), ''); v_status text := nullif(p->>'status', '');
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'mrr', (select coalesce(sum(case when s.billing = 'year' then private.plan_price(pl, 'year') / 12 else pl.price_month end), 0)
            from subscriptions s join plans pl on pl.id = s.plan_id where s.status in ('active', 'past_due') and not s.comp),
    'paying', (select count(*) from subscriptions s join plans pl on pl.id = s.plan_id where s.status in ('active', 'past_due') and not s.comp
               and private.plan_price(pl, s.billing) > 0),
    'trialing', (select count(*) from subscriptions where status = 'trialing'),
    'past_due', (select count(*) from subscriptions where status = 'past_due'),
    'comp', (select count(*) from subscriptions where comp),
    'cancelling', (select count(*) from subscriptions where cancel_at_period_end),
    'collected_month', (select coalesce(sum(amount), 0) from subscription_charges where status = 'successful' and paid_at >= v_from),
    'failed_month', (select count(*) from subscription_charges where status = 'failed' and created_at >= v_from),
    'by_plan', (select coalesce(jsonb_agg(jsonb_build_object('plan', pl.name, 'code', pl.code, 'businesses', n) order by pl.sort), '[]'::jsonb)
      from (select private.org_plan_id(o.id) plan_id, count(*) n from orgs o where not o.is_sample group by 1) x join plans pl on pl.id = x.plan_id),
    'rows', (select coalesce(jsonb_agg(r order by r->>'name'), '[]'::jsonb) from (
      select jsonb_build_object('org_id', o.id, 'name', o.name, 'plan', pl.name, 'status', coalesce(s.status, 'active'), 'billing', coalesce(s.billing, 'month'),
        'pay_method', s.pay_method, 'period_end', s.current_period_end, 'comp', coalesce(s.comp, false), 'cancelling', coalesce(s.cancel_at_period_end, false),
        'price', private.plan_price(pl, coalesce(s.billing, 'month')),
        'last_charge', (select jsonb_build_object('status', c.status, 'at', c.created_at, 'error', c.error) from subscription_charges c where c.org_id = o.id
                        order by c.created_at desc limit 1)) r
      from orgs o left join subscriptions s on s.org_id = o.id join plans pl on pl.id = coalesce(s.plan_id, private.default_plan_id())
      where not o.is_sample and (v_q is null or o.name ilike '%' || v_q || '%')
        and (v_status is null or coalesce(s.status, 'active') = v_status or (v_status = 'paying' and s.pay_method is not null))
      order by o.name limit least(coalesce(nullif(p->>'limit', '')::int, 200), 500)) z));
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.ai_read_kinds(), private.ai_assistant_kinds(), private.default_plan_id(), private.org_plan_id(uuid), private.month_start(),
  private.meter_usage(uuid, text), private.entitlement(uuid, text, boolean), private.plan_allows(uuid, text), private.plan_fmt(numeric),
  private.entitlement_notice(uuid, text, text, text, text), private.check_quota(uuid, text, numeric), private.enforce_plan(), private.plan_json(uuid),
  private.plan_price(public.plans, text), private.sub_json(uuid), private.to_default_plan(uuid, text), private.renewal_charge(public.subscriptions, uuid, text)
  from public, anon, authenticated;
revoke all on function public.svc_usage(jsonb), public.svc_entitle(uuid, text), public.svc_subscription_charge(uuid), public.svc_subscription_by_ref(text),
  public.svc_subscription_charge_update(text, jsonb), public.svc_subscription_tick(), public.svc_subscription_open(), public.svc_subscription_expire(text)
  from public, anon, authenticated;
grant execute on function public.svc_usage(jsonb), public.svc_entitle(uuid, text), public.svc_subscription_charge(uuid), public.svc_subscription_by_ref(text),
  public.svc_subscription_charge_update(text, jsonb), public.svc_subscription_tick(), public.svc_subscription_open(), public.svc_subscription_expire(text)
  to service_role;
revoke all on function public.subscription_state(uuid), public.subscription_start(uuid, jsonb), public.subscription_cancel(uuid, boolean),
  public.subscription_method(uuid, jsonb), public.admin_plans(), public.admin_save_module(jsonb), public.admin_save_plan(jsonb), public.admin_org_plan(uuid),
  public.admin_set_org_plan(uuid, jsonb), public.admin_set_override(uuid, jsonb), public.admin_subscriptions(jsonb) from public, anon;
grant execute on function public.subscription_state(uuid), public.subscription_start(uuid, jsonb), public.subscription_cancel(uuid, boolean),
  public.subscription_method(uuid, jsonb), public.admin_plans(), public.admin_save_module(jsonb), public.admin_save_plan(jsonb), public.admin_org_plan(uuid),
  public.admin_set_org_plan(uuid, jsonb), public.admin_set_override(uuid, jsonb), public.admin_subscriptions(jsonb) to authenticated;
