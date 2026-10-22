-- Counta · the Counta Partner programme for accountants
--
-- An accountant's practice earns a share of what the businesses it brings to Counta pay for their plans.
--
-- Who counts. A business connected to the practice before it ever paid for a Counta plan: through the practice's own
-- link (/r/<code>), its email invitation, the business inviting it, or the business asking from the partner directory.
-- One practice per business, the first that connected. A business owned by someone in the practice earns nothing, and a
-- business that leaves the practice before its first payment stops counting.
--
-- What it earns. From the business's first paid plan, for the tier's number of months (6 at first), each payment earns the
-- tier's rate (15% at first) while the business stays connected. A yearly payment counts for the months of it that fall
-- in that window, so a first payment for a year earns on half of it. The practice's tier rises with the number of its
-- referred businesses that have paid: Bronze, Silver, Gold, each with its own rate and months. Milestone bonuses are paid
-- once each, at 5, 10 and 25 paying businesses. A business that joins through an accountant gets a welcome discount on
-- its first payment. TaxStreem sets every number in the admin portal (platform_settings 'partners').
--
-- Getting paid. Each amount waits (30 days) after the payment it came from, so a payment that is reversed is not paid on.
-- On the payout day (the 5th) Counta lists what each practice has waiting, in one payout per practice, once it reaches the
-- minimum (₦5,000) and the practice has a verified ICAN, ANAN or CITN licence and a bank account the bank confirmed.
-- TaxStreem approves each payout in the admin portal; the payments function sends it by bank transfer from TaxStreem's
-- Flutterwave balance. Withholding tax is deducted at the rate the admin portal sets, and the practice gets a WHT note.
--
-- The directory. Practices with a verified licence can list themselves with a short description; businesses see them
-- under Settings, Your accountant, with their tier, and ask one to be their accountant.

-- ---------------------------------------------------------------------------
-- 1. The programme's settings
-- ---------------------------------------------------------------------------
alter table public.platform_settings drop constraint if exists platform_settings_key_check;
alter table public.platform_settings add constraint platform_settings_key_check check (key in ('martina', 'limits', 'switches', 'alerts', 'partners'));

create or replace function private.partner_defaults() returns jsonb
language sql immutable as $$
  select '{
    "enabled": true,
    "tiers": [
      {"code": "bronze", "name": "Bronze", "clients": 0, "rate": 0.15, "months": 6},
      {"code": "silver", "name": "Silver", "clients": 10, "rate": 0.175, "months": 6},
      {"code": "gold", "name": "Gold", "clients": 25, "rate": 0.2, "months": 9}],
    "milestones": [{"clients": 5, "bonus": 25000}, {"clients": 10, "bonus": 75000}, {"clients": 25, "bonus": 200000}],
    "welcome": {"on": true, "percent": 20, "payments": 1},
    "hold_days": 30, "min_payout": 5000, "payout_day": 5, "wht_rate": 0.05,
    "directory": {"on": true, "min_clients": 0},
    "payer": {"name": "TaxStreem Technologies Limited", "tin": null, "address": null}
  }'::jsonb
$$;

create or replace function private.partner_settings() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.partner_defaults() || coalesce((select value from platform_settings where key = 'partners'), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
-- Each practice's own link code, its directory listing and the bank account it is paid into.
alter table public.practices add column if not exists referral_code text;
alter table public.practices add column if not exists listed boolean not null default false;
alter table public.practices add column if not exists blurb text check (blurb is null or length(blurb) <= 300);
create unique index if not exists practices_referral_code on public.practices(referral_code) where referral_code is not null;

-- How a connection came about, when it was not an email invitation: the practice's link or the partner directory.
alter table public.practice_clients add column if not exists via text check (via in ('link', 'directory'));

-- A plan payment's welcome discount.
alter table public.subscription_charges add column if not exists discount numeric(14,2) not null default 0 check (discount >= 0);
alter table public.subscription_charges add column if not exists discount_note text;

create table if not exists public.practice_payout_accounts (
  practice_id uuid primary key references public.practices(id) on delete cascade,
  bank_code text not null check (bank_code ~ '^[0-9A-Za-z]{2,12}$'),
  bank_name text not null check (length(bank_name) between 2 and 120),
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null check (length(account_name) between 2 and 120),
  name_match boolean not null default false,
  set_by uuid references auth.users(id) on delete set null,
  set_at timestamptz not null default now()
);
create index if not exists practice_payout_accounts_set_by on public.practice_payout_accounts(set_by);
alter table public.practice_payout_accounts enable row level security;
revoke all on public.practice_payout_accounts from anon, authenticated;

create table if not exists public.partner_referrals (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  client_id uuid references public.practice_clients(id) on delete set null,
  source text not null check (source in ('link', 'invite', 'request', 'directory')),
  status text not null default 'waiting' check (status in ('waiting', 'earning', 'completed', 'void')),
  void_reason text check (void_reason in ('self', 'ended')),
  connected_at timestamptz not null default now(),
  first_paid_at timestamptz,
  months int check (months between 1 and 36),
  window_ends timestamptz,
  created_at timestamptz not null default now(),
  check (status in ('waiting', 'void') or (first_paid_at is not null and window_ends is not null))
);
-- One practice per business: the first that connected before the business paid.
create unique index if not exists partner_referrals_org on public.partner_referrals(org_id) where status <> 'void';
create index if not exists partner_referrals_practice on public.partner_referrals(practice_id, status);
create index if not exists partner_referrals_client on public.partner_referrals(client_id);
alter table public.partner_referrals enable row level security;
revoke all on public.partner_referrals from anon, authenticated;

create table if not exists public.partner_payouts (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  period date not null,
  gross numeric(14,2) not null check (gross > 0),
  wht_rate numeric(6,4) not null default 0 check (wht_rate >= 0 and wht_rate < 1),
  wht numeric(14,2) not null default 0 check (wht >= 0),
  net numeric(14,2) not null check (net > 0),
  status text not null default 'draft' check (status in ('draft', 'approved', 'sending', 'paid', 'failed', 'cancelled')),
  bank_code text, bank_name text, account_number text, account_name text, name_match boolean,
  reference text not null unique,
  old_references text[] not null default '{}',
  attempts int not null default 0,
  provider_ref text,
  fee numeric(14,2),
  error text,
  note text,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  sent_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  check (net = gross - wht)
);
create index if not exists partner_payouts_practice on public.partner_payouts(practice_id, created_at desc);
create index if not exists partner_payouts_open on public.partner_payouts(status) where status in ('draft', 'approved', 'sending', 'failed');
create index if not exists partner_payouts_approved_by on public.partner_payouts(approved_by);
alter table public.partner_payouts enable row level security;
revoke all on public.partner_payouts from anon, authenticated;

create table if not exists public.partner_commissions (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  referral_id uuid references public.partner_referrals(id) on delete set null,
  org_id uuid references public.orgs(id) on delete set null,
  charge_id uuid unique references public.subscription_charges(id) on delete set null,
  kind text not null check (kind in ('commission', 'bonus')),
  milestone int check (milestone > 0),
  base numeric(14,2),
  rate numeric(6,4),
  amount numeric(14,2) not null check (amount > 0),
  note text,
  status text not null default 'pending' check (status in ('pending', 'in_payout', 'paid', 'void')),
  available_at timestamptz not null,
  payout_id uuid references public.partner_payouts(id) on delete set null,
  created_at timestamptz not null default now(),
  check (kind = 'commission' or milestone is not null),
  check ((status in ('in_payout', 'paid')) = (payout_id is not null))
);
create unique index if not exists partner_commissions_bonus on public.partner_commissions(practice_id, milestone) where kind = 'bonus';
create index if not exists partner_commissions_practice on public.partner_commissions(practice_id, status, available_at);
create index if not exists partner_commissions_referral on public.partner_commissions(referral_id);
create index if not exists partner_commissions_org on public.partner_commissions(org_id);
create index if not exists partner_commissions_payout on public.partner_commissions(payout_id);
alter table public.partner_commissions enable row level security;
revoke all on public.partner_commissions from anon, authenticated;

-- The monthly listing of payouts, once per month (an admin can list again by hand).
create table if not exists public.partner_payout_runs (
  period date primary key,
  ran_at timestamptz not null default now(),
  created int not null default 0
);
alter table public.partner_payout_runs enable row level security;
revoke all on public.partner_payout_runs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Link codes, tiers and who is verified
-- ---------------------------------------------------------------------------
-- A code people can read out: up to four letters of the practice's name and four characters that are never confused
-- (no 0, O, 1, I or L), such as LEDG-7K3Q.
create or replace function private.referral_code_new(p_name text) returns text
language plpgsql volatile set search_path = public, private as $$
declare v_head text := rpad(left(upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z]', '', 'g')), 4), 4, 'X'); v_code text; a text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
begin
  loop
    v_code := v_head || '-' || (select string_agg(substr(a, 1 + floor(random() * length(a))::int, 1), '') from generate_series(1, 4));
    exit when not exists (select 1 from practices where referral_code = v_code);
  end loop;
  return v_code;
end $$;

create or replace function private.practice_code_default() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.referral_code is null then new.referral_code := private.referral_code_new(new.name); end if;
  return new;
end $$;
drop trigger if exists practices_code on public.practices;
create trigger practices_code before insert on public.practices for each row execute function private.practice_code_default();
update public.practices set referral_code = private.referral_code_new(name) where referral_code is null;

-- A practice is paid once one of its partners has a licence number TaxStreem verified.
create or replace function private.partner_verified(p_practice uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from practice_members where practice_id = p_practice and role = 'partner' and status = 'active' and licence_status = 'verified')
$$;

-- Referred businesses that have paid at least once.
create or replace function private.partner_paying(p_practice uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select count(*)::int from partner_referrals where practice_id = p_practice and status <> 'void' and first_paid_at is not null
$$;

-- The tier for a number of paying businesses, with the next one up.
create or replace function private.partner_tier_for(p_paying int) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with t as (select x, (x->>'clients')::int c from jsonb_array_elements(private.partner_settings()->'tiers') x)
  select coalesce((select x from t where c <= p_paying order by c desc limit 1), (select x from t order by c limit 1))
    || jsonb_build_object('paying', p_paying, 'next', (select x from t where c > p_paying order by c limit 1))
$$;

create or replace function private.partner_tier(p_practice uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.partner_tier_for(private.partner_paying(p_practice))
$$;

-- What anyone may see of a partner: on its link page and in the directory.
create or replace function private.partner_public(p_practice uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'state', p.state, 'blurb', p.blurb, 'code', p.referral_code,
    'tier', jsonb_build_object('code', t->>'code', 'name', t->>'name'), 'verified', private.partner_verified(p.id),
    'licences', (select coalesce(jsonb_agg(distinct m.licence_body), '[]'::jsonb) from practice_members m
      where m.practice_id = p.id and m.status = 'active' and m.licence_status = 'verified'))
  from practices p, lateral (select private.partner_tier(p.id) t) x where p.id = p_practice
$$;

-- The welcome discount still open to a business: the percent and how many payments it covers.
create or replace function private.partner_offer(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s jsonb := private.partner_settings(); r public.partner_referrals; v_used int;
begin
  if not (s->>'enabled')::boolean or not (s->'welcome'->>'on')::boolean or (s->'welcome'->>'percent')::numeric <= 0 then return null; end if;
  select * into r from partner_referrals where org_id = p_org and status in ('waiting', 'earning');
  if not found then return null; end if;
  select count(*) into v_used from subscription_charges where org_id = p_org and status = 'successful' and discount > 0;
  if v_used >= (s->'welcome'->>'payments')::int then return null; end if;
  return jsonb_build_object('percent', (s->'welcome'->>'percent')::numeric, 'payments', (s->'welcome'->>'payments')::int - v_used,
    'practice', (select name from practices where id = r.practice_id));
end $$;

-- ---------------------------------------------------------------------------
-- 4. A business connects: the referral starts
-- ---------------------------------------------------------------------------
-- The referral for a business that is now an active client of a practice, if it counts. The trigger below and the backfill
-- for clients connected before the programme both start referrals here.
create or replace function private.partner_referral_start(c public.practice_clients) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_self boolean; v_source text;
begin
  if c.org_id is null or c.practice_id is null or c.status <> 'active' then return; end if;
  if not (private.partner_settings()->>'enabled')::boolean then return; end if;
  if (select is_sample from orgs where id = c.org_id) then return; end if;
  if exists (select 1 from partner_referrals where org_id = c.org_id and status <> 'void') then return; end if;
  if exists (select 1 from subscription_charges where org_id = c.org_id and status = 'successful') then return; end if;
  v_self := exists (select 1 from members m join practice_members pm on pm.user_id = m.user_id
    where m.org_id = c.org_id and m.role = 'owner' and m.user_id is not null and pm.practice_id = c.practice_id and pm.status = 'active');
  v_source := case when c.via is not null then c.via when c.initiated_by = 'practice' then 'invite' else 'request' end;
  insert into partner_referrals (practice_id, org_id, client_id, source, status, void_reason)
  values (c.practice_id, c.org_id, c.id, v_source, case when v_self then 'void' else 'waiting' end, case when v_self then 'self' end);
end $$;

create or replace function private.partner_on_connect() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.org_id is null or new.practice_id is null then return new; end if;
  -- Leaving before the first payment: the business no longer counts for this practice.
  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active' then
    update partner_referrals set status = 'void', void_reason = 'ended' where practice_id = new.practice_id and org_id = new.org_id and status = 'waiting';
    return new;
  end if;
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then return new; end if;
  perform private.partner_referral_start(new);
  return new;
end $$;
drop trigger if exists practice_clients_partner on public.practice_clients;
create trigger practice_clients_partner after insert or update of status on public.practice_clients
  for each row execute function private.partner_on_connect();

-- Clients already connected when the programme starts count too, if they have never paid: the earliest connection first.
do $$
declare c public.practice_clients;
begin
  for c in select * from public.practice_clients pc where pc.status = 'active'
      and not exists (select 1 from public.partner_referrals r where r.client_id = pc.id)
    order by coalesce(pc.started_at, pc.created_at), pc.id loop
    perform private.partner_referral_start(c);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The welcome discount on a referred business's first payment
-- ---------------------------------------------------------------------------
create or replace function private.partner_discount() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare o jsonb := private.partner_offer(new.org_id); pl public.plans; v_pct numeric; v_d numeric;
begin
  if o is null or new.amount <= 0 or new.status <> 'pending' then return new; end if;
  v_pct := least((o->>'percent')::numeric, 90) / 100;
  if new.billing = 'year' then
    -- A yearly payment: the discount on the months it still covers, at the monthly price.
    select * into pl from plans where id = new.plan_id;
    v_d := round(least(new.amount, private.plan_price(pl, 'month') * (o->>'payments')::int) * v_pct, 2);
  else
    v_d := round(new.amount * v_pct, 2);
  end if;
  if v_d <= 0 or v_d >= new.amount then return new; end if;
  new.discount := v_d;
  new.amount := new.amount - v_d;
  new.discount_note := left(format('%s%% welcome offer from %s', trim(to_char((o->>'percent')::numeric, 'FM990.##')), o->>'practice'), 200);
  return new;
end $$;
drop trigger if exists subscription_charges_partner_discount on public.subscription_charges;
create trigger subscription_charges_partner_discount before insert on public.subscription_charges
  for each row execute function private.partner_discount();

-- ---------------------------------------------------------------------------
-- 6. A referred business pays: the commission, the tier and the milestones
-- ---------------------------------------------------------------------------
create or replace function private.partner_on_payment() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare s jsonb := private.partner_settings(); r public.partner_referrals; t jsonb; t_before jsonb; v_at timestamptz := coalesce(new.paid_at, now());
  v_first boolean := false; v_age interval; v_months numeric; v_base numeric; v_amt numeric; v_paying int; m jsonb; v_id uuid; v_org text;
begin
  if not (s->>'enabled')::boolean then return new; end if;
  select * into r from partner_referrals where org_id = new.org_id and status in ('waiting', 'earning') for update;
  if not found then return new; end if;
  -- Only while the business is still the practice's client.
  if not exists (select 1 from practice_clients where practice_id = r.practice_id and org_id = r.org_id and status = 'active') then return new; end if;
  select name into v_org from orgs where id = r.org_id;
  if r.status = 'waiting' then
    t_before := private.partner_tier(r.practice_id);
    t := private.partner_tier_for((t_before->>'paying')::int + 1);
    update partner_referrals set status = 'earning', first_paid_at = v_at, months = (t->>'months')::int,
      window_ends = v_at + make_interval(months => (t->>'months')::int) where id = r.id returning * into r;
    v_first := true;
  end if;
  if v_at >= r.window_ends then
    update partner_referrals set status = 'completed' where id = r.id;
    return new;
  end if;
  if new.billing = 'year' then
    -- The months of the year paid for that fall inside the window.
    v_age := age(least(v_at + interval '1 year', r.window_ends), v_at);
    v_months := least(12, extract(year from v_age) * 12 + extract(month from v_age) + extract(day from v_age) / 30.0 + extract(hour from v_age) / 720.0);
    v_base := round(new.amount * v_months / 12, 2);
  else
    v_base := new.amount;
  end if;
  t := private.partner_tier(r.practice_id);
  v_amt := round(v_base * (t->>'rate')::numeric, 2);
  if v_amt > 0 then
    insert into partner_commissions (practice_id, referral_id, org_id, charge_id, kind, base, rate, amount, note, available_at)
    values (r.practice_id, r.id, r.org_id, new.id, 'commission', v_base, (t->>'rate')::numeric, v_amt,
      left(format('%s · %s plan, %s', v_org, (select name from plans where id = new.plan_id), case when new.billing = 'year' then 'a year' else 'a month' end), 200),
      v_at + make_interval(days => (s->>'hold_days')::int))
    on conflict (charge_id) do nothing;
    perform private.practice_notify(r.practice_id, format('You earned ₦%s from %s', to_char(v_amt, 'FM999,999,990.00'), v_org),
      format('%s%% of their Counta plan payment. It is paid to you from %s.', trim(to_char((t->>'rate')::numeric * 100, 'FM990.##')),
        to_char((v_at + make_interval(days => (s->>'hold_days')::int)) at time zone 'Africa/Lagos', 'DD Mon YYYY')), '/practice/earnings');
  end if;
  if v_first then
    v_paying := private.partner_paying(r.practice_id);
    for m in select x from jsonb_array_elements(s->'milestones') x where (x->>'clients')::int <= v_paying and (x->>'bonus')::numeric > 0 loop
      v_id := null;
      insert into partner_commissions (practice_id, kind, milestone, amount, note, available_at)
      values (r.practice_id, 'bonus', (m->>'clients')::int, (m->>'bonus')::numeric,
        format('Milestone bonus: %s paying businesses', m->>'clients'), now() + make_interval(days => (s->>'hold_days')::int))
      on conflict (practice_id, milestone) where kind = 'bonus' do nothing returning id into v_id;
      if v_id is not null then
        perform private.practice_notify(r.practice_id, format('Milestone bonus: ₦%s', to_char((m->>'bonus')::numeric, 'FM999,999,990')),
          format('%s businesses you brought to Counta have paid for a plan.', m->>'clients'), '/practice/earnings');
      end if;
    end loop;
    if (t->>'code') is distinct from (t_before->>'code') then
      perform private.practice_notify(r.practice_id, format('You are now a %s Counta Partner', t->>'name'),
        format('From now on you earn %s%% of each payment, for %s months, on businesses you bring.', trim(to_char((t->>'rate')::numeric * 100, 'FM990.##')), t->>'months'),
        '/practice/earnings');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists subscription_charges_partner on public.subscription_charges;
create trigger subscription_charges_partner after update of status on public.subscription_charges
  for each row when (new.status = 'successful' and old.status is distinct from 'successful') execute function private.partner_on_payment();

-- ---------------------------------------------------------------------------
-- 7. The link, the directory and the business's side
-- ---------------------------------------------------------------------------
-- The link page, before anyone signs in.
create or replace function public.referral_preview(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_id uuid; s jsonb := private.partner_settings();
begin
  if coalesce(p_code, '') !~ '^[A-Za-z]{4}-[A-Za-z0-9]{4}$' or not (s->>'enabled')::boolean then return null; end if;
  select id into v_id from practices where referral_code = upper(p_code);
  if v_id is null then return null; end if;
  return private.partner_public(v_id) || jsonb_build_object('offer', case when (s->'welcome'->>'on')::boolean and (s->'welcome'->>'percent')::numeric > 0
    then jsonb_build_object('percent', (s->'welcome'->>'percent')::numeric, 'payments', (s->'welcome'->>'payments')::int) end);
end $$;

-- What the business owner sees after following a practice's link: whether to connect it, and the offer that comes with it.
create or replace function public.referral_offer(p_org uuid, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_id uuid; v_new boolean; s jsonb := private.partner_settings();
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' or (select is_sample from orgs where id = p_org) or not (s->>'enabled')::boolean then return null; end if;
  if coalesce(p_code, '') !~ '^[A-Za-z]{4}-[A-Za-z0-9]{4}$' then return null; end if;
  select id into v_id from practices where referral_code = upper(p_code);
  if v_id is null then return null; end if;
  if exists (select 1 from practice_clients where practice_id = v_id and org_id = p_org and status = 'active') then
    return jsonb_build_object('connected', true, 'practice', private.partner_public(v_id));
  end if;
  if exists (select 1 from practice_members where practice_id = v_id and user_id = auth.uid() and status = 'active') then return null; end if;
  v_new := not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful')
    and not exists (select 1 from partner_referrals where org_id = p_org and status <> 'void');
  return jsonb_build_object('connected', false, 'practice', private.partner_public(v_id),
    'offer', case when v_new and (s->'welcome'->>'on')::boolean and (s->'welcome'->>'percent')::numeric > 0
      then jsonb_build_object('percent', (s->'welcome'->>'percent')::numeric, 'payments', (s->'welcome'->>'payments')::int) end);
end $$;

-- The owner connects the practice whose link they followed.
create or replace function public.referral_connect(p_org uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pr public.practices; c public.practice_clients;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner of the business connects it to an accountant.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot be connected. Choose your own business.'; end if;
  select * into pr from practices where referral_code = upper(coalesce(p_code, ''));
  if not found then raise exception 'That link is not complete. Ask your accountant for it again.'; end if;
  if exists (select 1 from practice_clients where practice_id = pr.id and org_id = p_org and status = 'active') then
    raise exception '% is already your accountant.', pr.name;
  end if;
  insert into practice_clients (practice_id, org_id, status, initiated_by, via, business_name, created_by, accepted_by, started_at)
  values (pr.id, p_org, 'active', 'practice', 'link', (select name from orgs where id = p_org), auth.uid(), auth.uid(), now())
  returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.practice_notify(pr.id, c.business_name || ' joined through your link', 'It is now one of your clients.', '/practice/clients/' || c.id);
  perform private.notify_perm(p_org, 'manage_team', 'practice', pr.name || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('client_id', c.id, 'practice', private.partner_public(pr.id), 'offer', private.partner_offer(p_org));
end $$;

-- The business's partners and its welcome offer, for Settings and the plan page.
create or replace function public.org_partner(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return jsonb_build_object('offer', private.partner_offer(p_org),
    'partners', (select coalesce(jsonb_agg(private.partner_public(c.practice_id)), '[]'::jsonb) from practice_clients c where c.org_id = p_org and c.status = 'active'),
    'directory', (private.partner_settings()->'directory'->>'on')::boolean and (private.partner_settings()->>'enabled')::boolean);
end $$;

-- The partner directory, for a business choosing an accountant.
create or replace function public.partner_directory(p_org uuid, p_state text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; s jsonb := private.partner_settings();
begin
  m := private.require(p_org, 'manage_team');
  if not (s->>'enabled')::boolean or not (s->'directory'->>'on')::boolean then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(x.j || jsonb_build_object(
      'connected', exists (select 1 from practice_clients c where c.practice_id = x.id and c.org_id = p_org and c.status = 'active'),
      'requested', exists (select 1 from practice_clients c where c.practice_id = x.id and c.org_id = p_org and c.status = 'requested'))
      order by x.paying desc, x.j->>'name'), '[]'::jsonb)
    from (select p.id, private.partner_public(p.id) j, private.partner_paying(p.id) paying from practices p
          where p.listed and private.partner_verified(p.id) and private.partner_paying(p.id) >= (s->'directory'->>'min_clients')::int
            and (nullif(trim(coalesce(p_state, '')), '') is null or lower(p.state) = lower(trim(p_state)))) x);
end $$;

-- A business asks a listed partner to be its accountant; the practice says yes or no in its portal.
create or replace function public.directory_request(p_org uuid, p_practice uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pr public.practices; v_id uuid; v_services text[]; s jsonb := private.partner_settings();
begin
  m := private.require(p_org, 'manage_team');
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot connect an accountant. Use your own business.'; end if;
  select * into pr from practices where id = p_practice and listed;
  if not found or not private.partner_verified(p_practice) or not (s->'directory'->>'on')::boolean then raise exception 'That accountant is not in the directory.'; end if;
  if exists (select 1 from practice_clients where practice_id = p_practice and org_id = p_org and status = 'active') then raise exception '% is already your accountant.', pr.name; end if;
  if exists (select 1 from practice_clients where practice_id = p_practice and org_id = p_org and status = 'requested') then raise exception 'You have asked % already. They will answer in their portal.', pr.name; end if;
  if (select count(*) from practice_clients where org_id = p_org and created_at > now() - interval '1 day') >= 10 then raise exception 'That is enough requests for today.'; end if;
  select coalesce(array_agg(distinct x) filter (where x in ('bookkeeping', 'vat', 'wht', 'cit', 'statements', 'payroll', 'advisory')), '{bookkeeping,vat,wht,cit,statements}')
    into v_services from jsonb_array_elements_text(coalesce(p->'services', '[]'::jsonb)) x;
  insert into practice_clients (practice_id, org_id, status, initiated_by, via, invite_email, business_name, services, billing, note, created_by)
  values (p_practice, p_org, 'requested', 'business', 'directory',
    (select email from practice_members where practice_id = p_practice and role = 'partner' and status = 'active' order by created_at limit 1),
    (select name from orgs where id = p_org), v_services, case when p->>'billing' = 'practice' then 'practice' else 'business' end,
    nullif(left(trim(coalesce(p->>'note', '')), 500), ''), auth.uid())
  returning id into v_id;
  perform private.practice_notify(p_practice, (select name from orgs where id = p_org) || ' asked you to be their accountant',
    'They found you in the Counta Partner directory. Answer under Clients.', '/practice');
  return jsonb_build_object('client_id', v_id);
end $$;

-- ---------------------------------------------------------------------------
-- 8. The practice's side: earnings, its listing, its bank account and requests from the directory
-- ---------------------------------------------------------------------------
create or replace function public.practice_partner(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare me public.practice_members; s jsonb := private.partner_settings(); t jsonb; pr public.practices; b public.practice_payout_accounts;
begin
  me := private.practice_require(p_practice, true);
  select * into pr from practices where id = p_practice;
  select * into b from practice_payout_accounts where practice_id = p_practice;
  t := private.partner_tier(p_practice);
  return jsonb_build_object(
    'enabled', (s->>'enabled')::boolean,
    'me', jsonb_build_object('role', me.role),
    'code', pr.referral_code,
    'listing', jsonb_build_object('listed', pr.listed, 'blurb', pr.blurb, 'state', pr.state, 'directory', (s->'directory'->>'on')::boolean,
      'min_clients', (s->'directory'->>'min_clients')::int),
    'verified', private.partner_verified(p_practice),
    'tier', t,
    'tiers', s->'tiers',
    'milestones', (select coalesce(jsonb_agg(x || jsonb_build_object('reached', (x->>'clients')::int <= (t->>'paying')::int,
        'paid', exists (select 1 from partner_commissions c where c.practice_id = p_practice and c.kind = 'bonus' and c.milestone = (x->>'clients')::int and c.status = 'paid')) order by (x->>'clients')::int), '[]'::jsonb)
      from jsonb_array_elements(s->'milestones') x),
    'terms', jsonb_build_object('hold_days', (s->>'hold_days')::int, 'min_payout', (s->>'min_payout')::numeric, 'payout_day', (s->>'payout_day')::int,
      'wht_rate', (s->>'wht_rate')::numeric, 'welcome', s->'welcome'),
    'totals', (select jsonb_build_object(
        'earned', coalesce(sum(amount) filter (where status <> 'void'), 0),
        'waiting', coalesce(sum(amount) filter (where status = 'pending' and available_at > now()), 0),
        'ready', coalesce(sum(amount) filter (where status = 'pending' and available_at <= now()), 0),
        'in_payout', coalesce(sum(amount) filter (where status = 'in_payout'), 0),
        'paid', coalesce(sum(amount) filter (where status = 'paid'), 0))
      from partner_commissions where practice_id = p_practice),
    'bank', case when b.practice_id is null then null else jsonb_build_object('bank_name', b.bank_name, 'bank_code', b.bank_code,
      'last4', right(b.account_number, 4), 'account_name', b.account_name, 'name_match', b.name_match, 'set_at', b.set_at,
      'set_by', (select display_name from practice_members where practice_id = p_practice and user_id = b.set_by limit 1)) end,
    'referrals', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'business', o.name, 'source', r.source,
        'status', case when r.status = 'earning' and r.window_ends <= now() then 'completed' else r.status end, 'void_reason', r.void_reason,
        'connected_at', r.connected_at, 'first_paid_at', r.first_paid_at, 'window_ends', r.window_ends, 'months', r.months,
        'earned', (select coalesce(sum(amount), 0) from partner_commissions c where c.referral_id = r.id and c.status <> 'void'),
        'client_id', r.client_id) order by r.connected_at desc), '[]'::jsonb)
      from partner_referrals r join orgs o on o.id = r.org_id where r.practice_id = p_practice),
    'commissions', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'note', c.note, 'base', c.base, 'rate', c.rate,
        'amount', c.amount, 'status', case when c.status = 'pending' and c.available_at > now() then 'waiting' when c.status = 'pending' then 'ready' else c.status end,
        'available_at', c.available_at, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
      from (select * from partner_commissions where practice_id = p_practice order by created_at desc limit 100) c),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'period', x.period, 'gross', x.gross, 'wht_rate', x.wht_rate, 'wht', x.wht, 'net', x.net,
        'status', case when x.status in ('draft', 'approved', 'sending', 'failed') then 'processing' else x.status end,
        'bank_name', x.bank_name, 'last4', right(x.account_number, 4), 'paid_at', x.paid_at, 'created_at', x.created_at) order by x.created_at desc), '[]'::jsonb)
      from partner_payouts x where x.practice_id = p_practice and x.status <> 'cancelled'),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'business', c.business_name, 'note', c.note, 'services', c.services,
        'billing', c.billing, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
      from practice_clients c where c.practice_id = p_practice and c.status = 'requested'));
end $$;

create or replace function public.practice_listing_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare me public.practice_members;
begin
  me := private.practice_require(p_practice, true);
  if me.role <> 'partner' then raise exception 'Only a partner changes the practice''s listing.' using errcode = '42501'; end if;
  if coalesce((p->>'listed')::boolean, false) and not private.partner_verified(p_practice) then
    raise exception 'The directory lists practices with a licence TaxStreem has verified. Add your ICAN, ANAN or CITN number under Practice first.';
  end if;
  if length(trim(coalesce(p->>'blurb', ''))) > 300 then raise exception 'Keep the description to 300 characters.'; end if;
  update practices set listed = case when p ? 'listed' then coalesce((p->>'listed')::boolean, false) else listed end,
    blurb = case when p ? 'blurb' then nullif(trim(p->>'blurb'), '') else blurb end, updated_at = now()
  where id = p_practice;
  return public.practice_partner(p_practice);
end $$;

-- Before the payments function saves a bank account: the caller is a partner, and the names the account may be held in.
create or replace function public.practice_bank_check(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare me public.practice_members;
begin
  me := private.practice_require(p_practice, true);
  if me.role <> 'partner' then raise exception 'Only a partner sets the bank account the practice is paid into.' using errcode = '42501'; end if;
  return jsonb_build_object('practice', (select name from practices where id = p_practice),
    'partners', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from practice_members where practice_id = p_practice and role = 'partner' and status = 'active'));
end $$;

-- p: {bank_code, bank_name, account_number, account_name (as the bank gave it), name_match}
create or replace function public.svc_practice_bank_save(p_practice uuid, p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pm public.practice_members; v_old public.practice_payout_accounts; u uuid;
begin
  select * into pm from practice_members where practice_id = p_practice and user_id = p_user and role = 'partner' and status = 'active';
  if not found then raise exception 'Only a partner sets the bank account the practice is paid into.' using errcode = '42501'; end if;
  if coalesce(p->>'account_number', '') !~ '^[0-9]{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if length(trim(coalesce(p->>'account_name', ''))) < 2 then raise exception 'The bank did not give a name for that account. Check the number and the bank.'; end if;
  select * into v_old from practice_payout_accounts where practice_id = p_practice;
  insert into practice_payout_accounts (practice_id, bank_code, bank_name, account_number, account_name, name_match, set_by, set_at)
  values (p_practice, p->>'bank_code', left(trim(p->>'bank_name'), 120), p->>'account_number', left(trim(p->>'account_name'), 120),
    coalesce((p->>'name_match')::boolean, false), p_user, now())
  on conflict (practice_id) do update set bank_code = excluded.bank_code, bank_name = excluded.bank_name, account_number = excluded.account_number,
    account_name = excluded.account_name, name_match = excluded.name_match, set_by = excluded.set_by, set_at = excluded.set_at;
  -- Every other partner hears of a change, in case it was not theirs to make.
  if v_old.practice_id is not null and (v_old.account_number, v_old.bank_code) is distinct from (p->>'account_number', p->>'bank_code') then
    for u in select user_id from practice_members where practice_id = p_practice and role = 'partner' and status = 'active' and user_id is not null and user_id <> p_user loop
      perform private.notify(null, u, 'practice', 'The payout bank account changed',
        format('%s set it to %s ••••%s (%s).', pm.display_name, left(trim(p->>'bank_name'), 60), right(p->>'account_number', 4), left(trim(p->>'account_name'), 60)),
        '/practice/earnings', null);
    end loop;
  end if;
  return jsonb_build_object('bank_name', p->>'bank_name', 'last4', right(p->>'account_number', 4), 'account_name', p->>'account_name');
end $$;

-- The practice answers a business that asked through the directory.
create or replace function public.practice_directory_answer(p_client uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; pr text;
begin
  select * into c from practice_clients where id = p_client and status = 'requested' and practice_id is not null for update;
  if not found then raise exception 'That request was withdrawn or answered.'; end if;
  perform private.practice_require(c.practice_id, true);
  select name into pr from practices where id = c.practice_id;
  if not coalesce(p_accept, false) then
    update practice_clients set status = 'declined', ended_at = now(), ended_by = auth.uid() where id = c.id;
    perform private.notify_perm(c.org_id, 'manage_team', 'practice', pr || ' cannot take you on', 'Choose another accountant from the directory.', '/settings#accountant', null);
    return jsonb_build_object('declined', true);
  end if;
  if exists (select 1 from practice_clients where practice_id = c.practice_id and org_id = c.org_id and status = 'active') then
    raise exception 'That business is already one of your clients.';
  end if;
  update practice_clients set status = 'active', started_at = now(), accepted_by = auth.uid() where id = c.id returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.notify_perm(c.org_id, 'manage_team', 'practice', pr || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('client_id', c.id, 'org_id', c.org_id);
end $$;

-- A WHT note for one payout.
create or replace function public.practice_payout_note(p_payout uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare x public.partner_payouts; pr public.practices; s jsonb := private.partner_settings();
begin
  select * into x from partner_payouts where id = p_payout and status = 'paid';
  if not found then raise exception 'That payout has not been paid yet.'; end if;
  perform private.practice_require(x.practice_id, true);
  select * into pr from practices where id = x.practice_id;
  return jsonb_build_object('payer', s->'payer', 'payee', jsonb_build_object('name', pr.name, 'address', pr.address, 'firm_reg', pr.firm_reg, 'state', pr.state),
    'payout', jsonb_build_object('reference', x.reference, 'period', x.period, 'paid_at', x.paid_at, 'gross', x.gross, 'wht_rate', x.wht_rate, 'wht', x.wht, 'net', x.net,
      'bank_name', x.bank_name, 'last4', right(x.account_number, 4)),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('note', c.note, 'kind', c.kind, 'amount', c.amount) order by c.created_at), '[]'::jsonb)
      from partner_commissions c where c.payout_id = x.id));
end $$;

-- ---------------------------------------------------------------------------
-- 9. Payouts: listed monthly, approved by TaxStreem, sent by the payments function
-- ---------------------------------------------------------------------------
create or replace function private.partner_new_ref() returns text
language sql volatile as $$ select 'CNTR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)) $$;

-- Lists what each practice has waiting, as one payout each. The poll calls it every five minutes; it works once a month,
-- from the payout day. p_force (an admin's "List payouts now") lists again at any time.
create or replace function public.svc_partner_payout_run(p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s jsonb := private.partner_settings(); v_today date := (now() at time zone 'Africa/Lagos')::date; v_period date; g record; b public.practice_payout_accounts;
  v_id uuid; v_n int := 0; v_skipped jsonb := '[]'::jsonb; v_wht numeric; a uuid;
begin
  v_period := date_trunc('month', v_today)::date;
  if not coalesce(p_force, false) then
    if extract(day from v_today) < (s->>'payout_day')::int then return jsonb_build_object('ran', false, 'reason', 'not_yet'); end if;
    if exists (select 1 from partner_payout_runs where period = v_period) then return jsonb_build_object('ran', false, 'reason', 'done'); end if;
  end if;
  update partner_referrals set status = 'completed' where status = 'earning' and window_ends <= now();
  for g in select c.practice_id, sum(c.amount) gross from partner_commissions c where c.status = 'pending' and c.available_at <= now() group by c.practice_id loop
    if exists (select 1 from partner_payouts where practice_id = g.practice_id and status in ('draft', 'approved', 'sending', 'failed')) then
      v_skipped := v_skipped || jsonb_build_object('practice_id', g.practice_id, 'reason', 'open_payout'); continue;
    end if;
    if g.gross < (s->>'min_payout')::numeric then v_skipped := v_skipped || jsonb_build_object('practice_id', g.practice_id, 'reason', 'below_minimum'); continue; end if;
    if not private.partner_verified(g.practice_id) then v_skipped := v_skipped || jsonb_build_object('practice_id', g.practice_id, 'reason', 'licence'); continue; end if;
    select * into b from practice_payout_accounts where practice_id = g.practice_id;
    if not found then v_skipped := v_skipped || jsonb_build_object('practice_id', g.practice_id, 'reason', 'bank'); continue; end if;
    v_wht := round(g.gross * (s->>'wht_rate')::numeric, 2);
    insert into partner_payouts (practice_id, period, gross, wht_rate, wht, net, bank_code, bank_name, account_number, account_name, name_match, reference)
    values (g.practice_id, v_period, g.gross, (s->>'wht_rate')::numeric, v_wht, g.gross - v_wht, b.bank_code, b.bank_name, b.account_number, b.account_name,
      b.name_match, private.partner_new_ref())
    returning id into v_id;
    update partner_commissions set status = 'in_payout', payout_id = v_id where practice_id = g.practice_id and status = 'pending' and available_at <= now();
    v_n := v_n + 1;
  end loop;
  insert into partner_payout_runs (period, ran_at, created) values (v_period, now(), v_n)
  on conflict (period) do update set ran_at = now(), created = partner_payout_runs.created + excluded.created;
  if v_n > 0 then
    for a in select user_id from platform_admins loop
      perform private.notify(null, a, 'admin', format('%s partner payout%s to approve', v_n, case when v_n = 1 then '' else 's' end),
        'Check each in the admin portal, Partners, and approve it.', '/admin/partners', 'partner-payouts-' || v_period);
    end loop;
  end if;
  return jsonb_build_object('ran', true, 'created', v_n, 'skipped', v_skipped);
end $$;

-- approve: a listed payout goes out on the next send. hold: back to waiting, for next month. retry: a failed payout again.
create or replace function public.admin_partner_payout_decide(p_payout uuid, p_action text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.partner_payouts; b public.practice_payout_accounts;
begin
  perform private.require_staff(true);
  select * into x from partner_payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  if p_action = 'approve' then
    if x.status <> 'draft' then raise exception 'Only a listed payout can be approved.'; end if;
    if not private.partner_verified(x.practice_id) then raise exception 'The practice no longer has a verified licence.'; end if;
    select * into b from practice_payout_accounts where practice_id = x.practice_id;
    if not found then raise exception 'The practice has no bank account to pay into.'; end if;
    update partner_payouts set status = 'approved', approved_by = auth.uid(), approved_at = now(), note = nullif(left(trim(coalesce(p_note, '')), 300), ''),
      bank_code = b.bank_code, bank_name = b.bank_name, account_number = b.account_number, account_name = b.account_name, name_match = b.name_match
    where id = x.id returning * into x;
  elsif p_action = 'hold' then
    if x.status not in ('draft', 'failed') then raise exception 'Only a listed or failed payout can be held.'; end if;
    update partner_commissions set status = 'pending', payout_id = null where payout_id = x.id and status = 'in_payout';
    update partner_payouts set status = 'cancelled', note = nullif(left(trim(coalesce(p_note, '')), 300), '') where id = x.id returning * into x;
  elsif p_action = 'retry' then
    if x.status <> 'failed' then raise exception 'Only a failed payout is sent again.'; end if;
    update partner_payouts set status = 'approved', old_references = old_references || reference, reference = private.partner_new_ref(), error = null,
      approved_by = auth.uid(), approved_at = now() where id = x.id returning * into x;
  else
    raise exception 'Approve, hold or retry.';
  end if;
  perform private.audit('partner_payout_' || p_action, x.id::text, jsonb_build_object('practice_id', x.practice_id, 'net', x.net, 'reference', x.reference, 'note', p_note));
  return to_jsonb(x) - 'account_number' || jsonb_build_object('last4', right(x.account_number, 4));
end $$;

create or replace function public.admin_partner_payout_run() returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_staff(true);
  perform private.audit('partner_payout_run', 'partners', '{}'::jsonb);
  return public.svc_partner_payout_run(true);
end $$;

-- The approved payouts, each moved to "sending" as it is handed out, so two senders never send one twice.
create or replace function public.svc_partner_payouts_claim() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v jsonb;
begin
  with c as (
    update partner_payouts x set status = 'sending', attempts = attempts + 1, sent_at = now()
    where x.id in (select id from partner_payouts where status = 'approved' order by approved_at limit 20 for update skip locked)
    returning x.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'reference', c.reference, 'net', c.net, 'bank_code', c.bank_code, 'account_number', c.account_number,
    'account_name', c.account_name, 'period', c.period, 'practice', (select name from practices where id = c.practice_id))), '[]'::jsonb) into v from c;
  return v;
end $$;

-- Payouts sent and not yet settled, for the poll to ask about.
create or replace function public.svc_partner_payouts_open() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('reference', reference, 'provider_ref', provider_ref)), '[]'::jsonb)
  from partner_payouts where status = 'sending' and provider_ref is not null
$$;

-- What the rail said: p {status: processing|successful|failed, provider_ref, fee, error}. A reference from an earlier
-- attempt that turns out to have gone counts too.
create or replace function public.svc_partner_payout_update(p_reference text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.partner_payouts; v_status text := p->>'status';
begin
  select * into x from partner_payouts where reference = p_reference or p_reference = any(old_references) for update;
  if not found then raise exception 'Payout not found.'; end if;
  if x.status in ('paid', 'cancelled') then return jsonb_build_object('status', x.status, 'unchanged', true); end if;
  if v_status = 'successful' then
    update partner_payouts set status = 'paid', paid_at = now(), provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref),
      fee = coalesce((p->>'fee')::numeric, fee), error = null where id = x.id returning * into x;
    update partner_commissions set status = 'paid' where payout_id = x.id;
    perform private.practice_notify(x.practice_id, format('Counta paid you ₦%s', to_char(x.net, 'FM999,999,990.00')),
      format('To %s ••••%s%s. Your WHT note is under Earnings.', x.bank_name, right(x.account_number, 4),
        case when x.wht > 0 then format(', after ₦%s withholding tax', to_char(x.wht, 'FM999,999,990.00')) else '' end), '/practice/earnings');
  elsif v_status = 'failed' then
    if x.reference <> p_reference then return jsonb_build_object('status', x.status, 'unchanged', true); end if;
    update partner_payouts set status = 'failed', error = left(coalesce(nullif(p->>'error', ''), 'The transfer did not go through.'), 300),
      provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref) where id = x.id returning * into x;
  elsif x.reference = p_reference then
    update partner_payouts set provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), fee = coalesce((p->>'fee')::numeric, fee)
    where id = x.id returning * into x;
  end if;
  return jsonb_build_object('status', x.status);
end $$;

-- ---------------------------------------------------------------------------
-- 10. The admin portal
-- ---------------------------------------------------------------------------
create or replace function public.admin_partners() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(true);
  return jsonb_build_object(
    'settings', private.partner_settings(),
    'practices', (select coalesce(jsonb_agg(x order by (x->>'earned')::numeric desc, x->>'name'), '[]'::jsonb) from (
      select jsonb_build_object('id', p.id, 'name', p.name, 'code', p.referral_code, 'listed', p.listed, 'verified', private.partner_verified(p.id),
        'tier', private.partner_tier(p.id)->>'name', 'paying', private.partner_paying(p.id),
        'referrals', (select count(*) from partner_referrals r where r.practice_id = p.id and r.status <> 'void'),
        'void', (select count(*) from partner_referrals r where r.practice_id = p.id and r.status = 'void'),
        'earned', (select coalesce(sum(amount), 0) from partner_commissions c where c.practice_id = p.id and c.status <> 'void'),
        'paid', (select coalesce(sum(amount), 0) from partner_commissions c where c.practice_id = p.id and c.status = 'paid'),
        'waiting', (select coalesce(sum(amount), 0) from partner_commissions c where c.practice_id = p.id and c.status in ('pending', 'in_payout')),
        'bank', (select jsonb_build_object('bank_name', b.bank_name, 'last4', right(b.account_number, 4), 'account_name', b.account_name, 'name_match', b.name_match,
          'set_at', b.set_at) from practice_payout_accounts b where b.practice_id = p.id)) x
      from practices p where exists (select 1 from partner_referrals r where r.practice_id = p.id) or exists (select 1 from practice_payout_accounts b where b.practice_id = p.id)) y(x)),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'practice', p.name, 'practice_id', p.id, 'period', x.period, 'gross', x.gross, 'wht_rate', x.wht_rate,
        'wht', x.wht, 'net', x.net, 'status', x.status, 'bank_name', x.bank_name, 'last4', right(x.account_number, 4), 'account_name', x.account_name,
        'name_match', x.name_match, 'reference', x.reference, 'attempts', x.attempts, 'error', x.error, 'note', x.note, 'approved_at', x.approved_at,
        'paid_at', x.paid_at, 'created_at', x.created_at, 'verified', private.partner_verified(p.id),
        'bank_changed', exists (select 1 from practice_payout_accounts b where b.practice_id = p.id and (b.account_number, b.bank_code) is distinct from (x.account_number, x.bank_code)),
        'lines', (select count(*) from partner_commissions c where c.payout_id = x.id))
        order by x.status in ('draft', 'failed', 'approved', 'sending') desc, x.created_at desc), '[]'::jsonb)
      from (select * from partner_payouts where status in ('draft', 'approved', 'sending', 'failed') or created_at > now() - interval '180 days' order by created_at desc limit 300) x
      join practices p on p.id = x.practice_id),
    'wht', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'wht', w, 'gross', g, 'payouts', n) order by m desc), '[]'::jsonb)
      from (select date_trunc('month', paid_at at time zone 'Africa/Lagos')::date m, sum(wht) w, sum(gross) g, count(*) n from partner_payouts where status = 'paid' group by 1) z),
    'last_run', (select to_jsonb(r) from partner_payout_runs r order by period desc limit 1));
end $$;

-- The whole programme's settings, checked and saved as one.
create or replace function public.admin_partner_settings_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v jsonb := private.partner_settings(); x jsonb; k text; n int; v_prev int := -1; v_tiers jsonb := '[]'::jsonb; v_ms jsonb := '[]'::jsonb; v_old jsonb;
  num numeric; v_name text;
begin
  perform private.require_staff(true);
  if jsonb_typeof(coalesce(p, 'null'::jsonb)) <> 'object' then raise exception 'Nothing to save.'; end if;
  for k in select key from jsonb_each(p) loop
    if not (private.partner_defaults() ? k) then raise exception 'Unknown setting: %.', k; end if;
  end loop;
  if p ? 'enabled' then
    if jsonb_typeof(p->'enabled') <> 'boolean' then raise exception 'The programme is on or off.'; end if;
    v := v || jsonb_build_object('enabled', p->'enabled');
  end if;
  if p ? 'tiers' then
    if jsonb_typeof(p->'tiers') <> 'array' or jsonb_array_length(p->'tiers') not between 1 and 5 then raise exception 'Set one to five tiers.'; end if;
    for x in select e from jsonb_array_elements(p->'tiers') e loop
      v_name := trim(coalesce(x->>'name', ''));
      if length(v_name) not between 2 and 20 then raise exception 'Each tier needs a name of 2 to 20 characters.'; end if;
      begin n := (x->>'clients')::int; num := (x->>'rate')::numeric; exception when others then raise exception 'Tier %: paying businesses and the rate are numbers.', v_name; end;
      if n is null or n < 0 or n > 10000 then raise exception 'Tier %: paying businesses from 0 to 10,000.', v_name; end if;
      if v_prev = -1 and n <> 0 then raise exception 'The first tier starts at 0 paying businesses.'; end if;
      if n <= v_prev then raise exception 'Each tier needs more paying businesses than the one before.'; end if;
      if num is null or num < 0 or num > 0.5 then raise exception 'Tier %: the rate is from 0%% to 50%%.', v_name; end if;
      begin n := (x->>'months')::int; exception when others then raise exception 'Tier %: months is a whole number.', v_name; end;
      if n is null or n not between 1 and 36 then raise exception 'Tier %: from 1 to 36 months.', v_name; end if;
      v_prev := (x->>'clients')::int;
      v_tiers := v_tiers || jsonb_build_object('code', coalesce(nullif(lower(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g')), ''), 'tier' || jsonb_array_length(v_tiers)),
        'name', v_name, 'clients', v_prev, 'rate', trim_scale(round(num, 4)), 'months', n);
    end loop;
    v := v || jsonb_build_object('tiers', v_tiers);
  end if;
  if p ? 'milestones' then
    if jsonb_typeof(p->'milestones') <> 'array' or jsonb_array_length(p->'milestones') > 10 then raise exception 'Set up to ten milestones.'; end if;
    v_prev := 0;
    for x in select e from jsonb_array_elements(p->'milestones') e loop
      begin n := (x->>'clients')::int; num := (x->>'bonus')::numeric; exception when others then raise exception 'Milestones are numbers.'; end;
      if n is null or n < 1 or n > 10000 or n <= v_prev then raise exception 'Each milestone needs more paying businesses than the one before, from 1.'; end if;
      if num is null or num < 0 or num > 10000000 then raise exception 'A bonus is from ₦0 to ₦10,000,000.'; end if;
      v_prev := n;
      v_ms := v_ms || jsonb_build_object('clients', n, 'bonus', trim_scale(round(num, 2)));
    end loop;
    v := v || jsonb_build_object('milestones', v_ms);
  end if;
  if p ? 'welcome' then
    x := p->'welcome';
    if jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'on') <> 'boolean' then raise exception 'The welcome offer is on or off.'; end if;
    begin num := (x->>'percent')::numeric; n := (x->>'payments')::int; exception when others then raise exception 'The welcome offer''s percent and payments are numbers.'; end;
    if num is null or num < 0 or num > 90 then raise exception 'The welcome discount is from 0%% to 90%%.'; end if;
    if n is null or n not between 1 and 12 then raise exception 'The welcome discount covers 1 to 12 payments.'; end if;
    v := v || jsonb_build_object('welcome', jsonb_build_object('on', x->'on', 'percent', trim_scale(round(num, 2)), 'payments', n));
  end if;
  foreach k in array array['hold_days', 'min_payout', 'payout_day', 'wht_rate'] loop
    if p ? k then
      begin num := (p->>k)::numeric; exception when others then num := null; end;
      if num is null
         or (k = 'hold_days' and (num <> trunc(num) or num not between 0 and 120))
         or (k = 'min_payout' and num not between 0 and 1000000)
         or (k = 'payout_day' and (num <> trunc(num) or num not between 1 and 28))
         or (k = 'wht_rate' and num not between 0 and 0.25) then
        raise exception '%', case k when 'hold_days' then 'Hold payments for 0 to 120 days.' when 'min_payout' then 'The minimum payout is ₦0 to ₦1,000,000.'
          when 'payout_day' then 'The payout day is from the 1st to the 28th.' else 'The WHT rate is from 0% to 25%.' end;
      end if;
      v := v || jsonb_build_object(k, case when k in ('hold_days', 'payout_day') then to_jsonb(num::int) else to_jsonb(trim_scale(round(num, 4))) end);
    end if;
  end loop;
  if p ? 'directory' then
    x := p->'directory';
    if jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'on') <> 'boolean' then raise exception 'The directory is on or off.'; end if;
    begin n := (x->>'min_clients')::int; exception when others then raise exception 'The directory''s minimum is a whole number.'; end;
    if n is null or n not between 0 and 1000 then raise exception 'The directory''s minimum is 0 to 1,000 paying businesses.'; end if;
    v := v || jsonb_build_object('directory', jsonb_build_object('on', x->'on', 'min_clients', n));
  end if;
  if p ? 'payer' then
    x := p->'payer';
    if jsonb_typeof(x) <> 'object' or length(trim(coalesce(x->>'name', ''))) not between 2 and 120 then raise exception 'Give the name on the WHT notes.'; end if;
    if nullif(trim(coalesce(x->>'tin', '')), '') is not null and trim(x->>'tin') !~ '^[0-9-]{8,20}$' then raise exception 'The Tax ID is 8 to 20 digits.'; end if;
    if length(coalesce(x->>'address', '')) > 300 then raise exception 'Keep the address to 300 characters.'; end if;
    v := v || jsonb_build_object('payer', jsonb_build_object('name', trim(x->>'name'), 'tin', nullif(trim(coalesce(x->>'tin', '')), ''),
      'address', nullif(trim(coalesce(x->>'address', '')), '')));
  end if;
  select value into v_old from platform_settings where key = 'partners';
  insert into platform_settings (key, value, updated_by, updated_at) values ('partners', v, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform private.audit('save_partners', 'partners', jsonb_build_object('from', coalesce(v_old, private.partner_defaults()), 'to', v));
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.referral_preview(text) from public;
grant execute on function public.referral_preview(text) to anon, authenticated;
revoke all on function public.referral_offer(uuid, text), public.referral_connect(uuid, text), public.org_partner(uuid), public.partner_directory(uuid, text),
  public.directory_request(uuid, uuid, jsonb), public.practice_partner(uuid), public.practice_listing_save(uuid, jsonb), public.practice_bank_check(uuid),
  public.practice_directory_answer(uuid, boolean), public.practice_payout_note(uuid), public.admin_partners(), public.admin_partner_settings_save(jsonb),
  public.admin_partner_payout_decide(uuid, text, text), public.admin_partner_payout_run() from public, anon;
grant execute on function public.referral_offer(uuid, text), public.referral_connect(uuid, text), public.org_partner(uuid), public.partner_directory(uuid, text),
  public.directory_request(uuid, uuid, jsonb), public.practice_partner(uuid), public.practice_listing_save(uuid, jsonb), public.practice_bank_check(uuid),
  public.practice_directory_answer(uuid, boolean), public.practice_payout_note(uuid), public.admin_partners(), public.admin_partner_settings_save(jsonb),
  public.admin_partner_payout_decide(uuid, text, text), public.admin_partner_payout_run() to authenticated;
revoke all on function public.svc_practice_bank_save(uuid, uuid, jsonb), public.svc_partner_payout_run(boolean), public.svc_partner_payouts_claim(),
  public.svc_partner_payouts_open(), public.svc_partner_payout_update(text, jsonb) from public, anon, authenticated;
grant execute on function public.svc_practice_bank_save(uuid, uuid, jsonb), public.svc_partner_payout_run(boolean), public.svc_partner_payouts_claim(),
  public.svc_partner_payouts_open(), public.svc_partner_payout_update(text, jsonb) to service_role;
revoke all on function private.partner_defaults(), private.partner_settings(), private.referral_code_new(text), private.practice_code_default(),
  private.partner_verified(uuid), private.partner_paying(uuid), private.partner_tier_for(int), private.partner_tier(uuid), private.partner_public(uuid),
  private.partner_offer(uuid), private.partner_referral_start(public.practice_clients), private.partner_on_connect(), private.partner_discount(), private.partner_on_payment(), private.partner_new_ref()
  from public, anon, authenticated;
