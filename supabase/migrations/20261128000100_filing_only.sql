-- Release 4 of the identity and compliance work: filing-only. A business that wants only its annual income tax return
-- (companies income tax for a company, personal income tax for a business name or partnership) pays a one-time fee for
-- each year instead of a monthly plan.
--
-- 1. The package. A filing-only business (orgs.filing_only) is on the Annual filing plan (plans.kind = 'filing'), made of
--    modules like any plan and edited in the admin portal. Four modules are added for the app's areas (Selling, Purchases,
--    Inventory, VAT and WHT returns); every existing plan leaves them on, so nothing changes for anyone else. The package
--    switches them off with payments, bank feeds, Martina, calls and the supplier portal, and keeps AI reading, the books,
--    financial statements and the income tax return. Email and WhatsApp stay on: with Selling off nothing goes to customers,
--    and Counta's own alerts to the business (VAT turned on, a payment received) still reach it. Choosing any plan in
--    Subscription ends filing-only.
-- 2. The fee. TaxStreem sets price bands by the year's bank transactions in the admin portal (filing_prices), separately for
--    CIT and PIT. Counta counts the statement lines dated in the year (no AI: statements are read by their columns in the
--    browser), adds 35 lines a page for scanned statements held until payment (filing_scans), and quotes the band. One fee
--    for each year (filing_orders). Paid by card through the plan payments (subscription_charges.kind = 'filing'), by the
--    business, or by its accounting firm with the firm's card.
-- 3. Nothing before payment. Until a year is paid, no AI reads anything for a filing-only business (private.feature_on turns
--    AI reading off), the bookkeeper leaves its lines alone, and the books, the return and the financial statements are not
--    shown. After payment the year's lines are read; lines of years not paid for wait. Statements added later are read at no
--    extra charge. Scans are read after payment, and when their real count falls in a higher band the difference is owed
--    before the year's return can be approved.
-- 4. A filing-only business above the VAT line still files its return: VAT is turned on as the law requires and the people
--    told are pointed to a plan for the monthly VAT returns.
-- Run once, in the SQL Editor of the counta project, as one script.

-- ---------------------------------------------------------------------------
-- 1. Columns, the package and its modules
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists filing_only boolean not null default false;
alter table public.plans add column if not exists kind text not null default 'subscription';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'plans_kind_check') then
    alter table public.plans add constraint plans_kind_check check (kind in ('subscription', 'filing'));
  end if;
  -- A filing package is never offered as a subscription nor the default.
  if not exists (select 1 from pg_constraint where conname = 'plans_filing_hidden') then
    alter table public.plans add constraint plans_filing_hidden check (kind <> 'filing' or (not is_default and not public));
  end if;
end $$;

alter table public.plan_modules drop constraint if exists plan_modules_feature_check;
alter table public.plan_modules add constraint plan_modules_feature_check check (feature = any (array['payments', 'bulk_payments', 'martina', 'phone_calls',
  'payment_voice', 'ai_reading', 'email', 'whatsapp', 'bank_feeds', 'supplier_portal', 'selling', 'purchases', 'inventory', 'vat_wht']));

create or replace function private.feature_keys() returns text[]
language sql immutable as $$
  select array['new_businesses', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'payments', 'bulk_payments', 'bank_feeds',
    'supplier_portal', 'selling', 'purchases', 'inventory', 'vat_wht']
$$;

insert into public.plan_modules (key, name, kind, feature, what, sort) values
  ('selling', 'Selling', 'feature', 'selling', 'Sales, invoices, the till, customers, recurring invoices, price lists and the online shop', 2),
  ('purchases', 'Purchases', 'feature', 'purchases', 'Bills and vendors', 3),
  ('inventory', 'Inventory', 'feature', 'inventory', 'Items, stock, counts, production and stock reports', 4),
  ('vat_wht', 'VAT and WHT returns', 'feature', 'vat_wht', 'Monthly VAT returns and withholding tax schedules', 5)
on conflict (key) do nothing;

-- The Annual filing package: what a filing-only business has. TaxStreem changes it in the admin portal like any plan.
insert into public.plans (code, name, description, price_month, kind, public, is_default, active, sort)
values ('annual-filing', 'Annual filing', 'The annual income tax return, paid year by year: statements, AI bookkeeping, financial statements and the return.',
  0, 'filing', false, false, true, 900)
on conflict (code) do nothing;
insert into public.plan_entitlements (plan_id, module_key, included, quota, enforce)
select p.id, x.k, x.inc, null, 'block' from public.plans p,
  (values ('selling', false), ('purchases', false), ('inventory', false), ('vat_wht', false), ('payments', false), ('bulk_payments', false),
    ('bank_feeds_on', false), ('martina', false), ('phone_calls', false), ('payment_voice', false), ('whatsapp_channel', true), ('email_channel', true),
    ('supplier_portal', false), ('ai_reading', true), ('payouts', false), ('bank_feeds', false), ('assistant', false), ('call_minutes', false),
    ('supplier_invoices', false)) x(k, inc)
where p.code = 'annual-filing' and exists (select 1 from public.plan_modules md where md.key = x.k)
on conflict (plan_id, module_key) do nothing;

create or replace function private.filing_plan_id() returns uuid
language sql stable security definer set search_path = public, private as $$
  select id from plans where kind = 'filing' and active order by created_at limit 1
$$;

-- A filing-only business is on the Annual filing package whatever else it has; any other business as before.
create or replace function private.org_plan_id(p_org uuid) returns uuid
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select private.filing_plan_id() from orgs o where o.id = p_org and o.filing_only),
    (select s.plan_id from subscriptions s join plans p on p.id = s.plan_id where s.org_id = p_org),
    private.default_plan_id())
$$;

-- Choosing a plan (or a firm paying for one) ends filing-only. Years already paid stay paid. Annual filing itself is never a
-- subscription: a business is put on it by switching to filing-only.
create or replace function private.subscription_ends_filing() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.plan_id = private.filing_plan_id() then
    raise exception 'Annual filing is not set as a plan. Switch the business to filing-only instead.';
  end if;
  if new.plan_id is distinct from private.filing_plan_id() then
    update orgs set filing_only = false where id = new.org_id and filing_only;
  end if;
  return new;
end $$;
drop trigger if exists subscriptions_end_filing on public.subscriptions;
create trigger subscriptions_end_filing after insert or update of plan_id on public.subscriptions
  for each row execute function private.subscription_ends_filing();

-- ---------------------------------------------------------------------------
-- 2. Prices, orders and scans
-- ---------------------------------------------------------------------------
-- Price bands by the year's transactions: each band covers counts up to up_to; the band with no up_to covers the rest.
create table if not exists public.filing_prices (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('cit', 'pit')),
  up_to integer check (up_to is null or up_to between 1 and 10000000),
  price numeric(14,2) not null check (price > 0 and price <= 100000000),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create unique index if not exists filing_prices_band on public.filing_prices (kind, coalesce(up_to, 2147483647));
create index if not exists filing_prices_updated_by on public.filing_prices (updated_by) where updated_by is not null;
insert into public.filing_prices (kind, up_to, price)
select k, u, pr from (values ('cit', 5000, 70000), ('cit', 10000, 120000), ('cit', null::int, 200000),
  ('pit', 5000, 70000), ('pit', 10000, 120000), ('pit', null::int, 200000)) x(k, u, pr)
where not exists (select 1 from public.filing_prices);

-- One order for each year a filing-only business files (the year as the income tax returns name it: the calendar year
-- its accounting year ends in). What was counted and charged is kept as it was at payment.
create table if not exists public.filing_orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  year integer not null check (year between 2000 and 2100),
  kind text not null check (kind in ('cit', 'pit')),
  status text not null default 'open' check (status in ('open', 'paid')),
  lines integer check (lines >= 0),
  scan_pages integer check (scan_pages >= 0),
  estimate integer check (estimate >= 0),
  counted integer check (counted >= 0),
  band_up_to integer,
  amount numeric(14,2) check (amount >= 0),
  paid_at timestamptz,
  payer text check (payer in ('business', 'practice')),
  practice_id uuid references public.practices(id) on delete set null,
  charge_id uuid references public.subscription_charges(id) on delete set null,
  true_count integer check (true_count >= 0),
  extra_due numeric(14,2) not null default 0 check (extra_due >= 0),
  extra_paid numeric(14,2) not null default 0 check (extra_paid >= 0),
  extra_paid_at timestamptz,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, year),
  check (status = 'open' or (paid_at is not null and amount is not null))
);
create index if not exists filing_orders_practice on public.filing_orders (practice_id) where practice_id is not null;
create index if not exists filing_orders_charge on public.filing_orders (charge_id) where charge_id is not null;
create index if not exists filing_orders_created_by on public.filing_orders (created_by) where created_by is not null;

-- A scanned statement held unread until its year is paid for, priced by its pages.
create table if not exists public.filing_scans (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  order_id uuid not null references public.filing_orders(id) on delete cascade,
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  path text not null,
  file_name text check (length(file_name) <= 200),
  pages integer not null check (pages between 1 and 500),
  bytes bigint check (bytes > 0),
  status text not null default 'held' check (status in ('held', 'read')),
  import_id uuid references public.bank_imports(id) on delete set null,
  lines_found integer check (lines_found >= 0),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (path)
);
create index if not exists filing_scans_order on public.filing_scans (order_id);
create index if not exists filing_scans_org on public.filing_scans (org_id);
create index if not exists filing_scans_account on public.filing_scans (bank_account_id) where bank_account_id is not null;
create index if not exists filing_scans_import on public.filing_scans (import_id) where import_id is not null;
create index if not exists filing_scans_created_by on public.filing_scans (created_by) where created_by is not null;

alter table public.filing_prices enable row level security;
alter table public.filing_orders enable row level security;
alter table public.filing_scans enable row level security;
revoke all on public.filing_prices, public.filing_orders, public.filing_scans from anon, authenticated;

-- The plan payments carry the filing fee too: the order paid for and what was quoted when the payment started.
alter table public.subscription_charges drop constraint if exists subscription_charges_kind_check;
alter table public.subscription_charges add constraint subscription_charges_kind_check check (kind in ('start', 'renewal', 'filing'));
alter table public.subscription_charges add column if not exists filing_order_id uuid references public.filing_orders(id) on delete set null;
alter table public.subscription_charges add column if not exists filing_quote jsonb;
create index if not exists subscription_charges_filing_order on public.subscription_charges (filing_order_id) where filing_order_id is not null;

-- ---------------------------------------------------------------------------
-- 3. Counting, quoting and the Filing page
-- ---------------------------------------------------------------------------
-- The return a year's filing is for: CIT for a company, PIT for a business name or partnership, none for an exempt body.
create or replace function private.filing_kind(p_org uuid, p_year integer) returns text
language sql stable security definer set search_path = public, private as $$
  select case private.income_tax_kind(p_org, p_year) when 'company' then 'cit' when 'sole' then 'pit' when 'partnership' then 'pit' end
$$;

-- A filing-only business that has paid for no year yet: no AI reads anything for it and nothing it uploaded is shown.
create or replace function private.filing_hold(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select o.filing_only from orgs o where o.id = p_org), false)
    and not exists (select 1 from filing_orders f where f.org_id = p_org and f.status = 'paid')
$$;

-- Whether AI may read a day's bank lines: any business but a filing-only one, or a year it has paid for.
create or replace function private.filing_day_open(p_org uuid, p_day date) returns boolean
language sql stable security definer set search_path = public, private as $$
  select not coalesce((select o.filing_only from orgs o where o.id = p_org), false)
    or exists (select 1 from filing_orders f where f.org_id = p_org and f.status = 'paid' and f.year = private.cit_year_of(p_org, p_day))
$$;

-- Whether a year's return and books stay hidden: a filing-only business that has not paid for it.
create or replace function private.filing_unpaid(p_org uuid, p_year integer) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select o.filing_only from orgs o where o.id = p_org), false)
    and not exists (select 1 from filing_orders f where f.org_id = p_org and f.status = 'paid' and (p_year is null or f.year = p_year))
$$;

-- What a hidden return or statement answers instead (to a member of the business only).
create or replace function private.filing_unpaid_json(p_org uuid, p_year integer) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, null);
  return jsonb_build_object('locked', true, 'filing_only', true, 'year', p_year,
    'message', case when p_year is null then 'Pay the filing fee on the Filing page to see the books and the return.'
                    else format('Pay the filing fee for %s on the Filing page to see its books and return.', p_year) end);
end $$;

-- The year's transactions as the fee counts them: the statement lines dated in the year (read without AI), and 35 lines
-- for each page of a scanned statement held until payment.
create or replace function private.filing_count(p_org uuid, p_year integer) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare p record; v_lines int; v_pages int;
begin
  select * into p from private.cit_period(p_org, p_year);
  select count(*) into v_lines from bank_lines where org_id = p_org and line_date between p.pfrom and p.pto;
  select coalesce(sum(s.pages), 0) into v_pages from filing_scans s join filing_orders f on f.id = s.order_id
  where f.org_id = p_org and f.year = p_year and s.status = 'held';
  return jsonb_build_object('lines', v_lines, 'scan_pages', v_pages, 'estimate', v_pages * 35, 'counted', v_lines + v_pages * 35,
    'from', p.pfrom, 'to', p.pto);
end $$;

-- The price band a count falls in: the smallest band that covers it, else the band with no upper end. Null when TaxStreem
-- has set no prices for that return.
create or replace function private.filing_band(p_kind text, p_count integer) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('up_to', up_to, 'price', price) from filing_prices
  where kind = p_kind and (up_to is null or up_to >= greatest(p_count, 0))
  order by coalesce(up_to, 2147483647) limit 1
$$;

create or replace function private.filing_quote(p_org uuid, p_year integer) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_kind text := private.filing_kind(p_org, p_year); c jsonb := private.filing_count(p_org, p_year); b jsonb;
begin
  b := case when v_kind is not null then private.filing_band(v_kind, (c->>'counted')::int) end;
  return c || jsonb_build_object('kind', v_kind, 'band_up_to', b->'up_to', 'price', b->'price', 'year', p_year);
end $$;

-- The years a filing-only business can file: up to four accounting years that have ended, none before the first year
-- Counta prepares (2023 for CIT, 2025 for PIT) or before the business began; and any year it has an order for.
create or replace function private.filing_years(p_org uuid) returns integer[]
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_today date := private.local_day(p_org, now()); v_last int; v_first int; v_kind text; v_out int[];
begin
  select * into o from orgs where id = p_org;
  v_last := private.cit_year_of(p_org, v_today);
  if (select pto from private.cit_period(p_org, v_last)) >= v_today then v_last := v_last - 1; end if;
  v_kind := private.filing_kind(p_org, v_last);
  v_first := greatest(v_last - 3, case v_kind when 'pit' then 2025 else 2023 end,
    coalesce(private.cit_year_of(p_org, coalesce(o.incorporation_date, o.commenced_on)), 0));
  select array_agg(y order by y desc) into v_out from (
    select generate_series(v_first, v_last) y union select year from filing_orders where org_id = p_org) x;
  return coalesce(v_out, '{}');
end $$;

-- Who pays for a filing-only business's year: its owner or admin by card (not while a firm runs it under full mandate), or
-- a partner or manager of a firm it works with, with the firm's card.
create or replace function private.filing_practice(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', pr.id, 'name', pr.name, 'client_id', pc.id,
    'card', (select jsonb_build_object('last4', k.last4, 'brand', k.brand) from subscription_cards k where k.practice_id = pr.id and k.active
             order by k.created_at desc limit 1))
  from practice_clients pc join practices pr on pr.id = pc.practice_id
  join practice_members pm on pm.practice_id = pc.practice_id and pm.user_id = auth.uid() and pm.status = 'active' and pm.role in ('partner', 'manager')
  where pc.org_id = p_org and pc.status = 'active'
  order by pc.started_at desc nulls last limit 1
$$;

create or replace function public.filing_state(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_years int[]; y int; v_out jsonb := '[]'::jsonb; q jsonb; f public.filing_orders; v_kind text; r jsonb;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_years := private.filing_years(p_org);
  foreach y in array v_years loop
    q := private.filing_quote(p_org, y);
    select * into f from filing_orders where org_id = p_org and year = y;
    v_kind := coalesce(f.kind, q->>'kind');
    r := case v_kind
      when 'cit' then (select jsonb_build_object('status', c.status, 'approved_at', c.approved_at, 'filed_at', c.filed_at, 'flux_status', c.flux_status) from cit_years c
                       where c.org_id = p_org and c.accounting_year = y)
      when 'pit' then (select jsonb_build_object('status', p.status, 'approved_at', p.approved_at,
                         'filed_at', (select max(pp.filed_at) from pit_person_years pp where pp.org_id = p_org and pp.accounting_year = y and pp.included))
                       from pit_years p where p.org_id = p_org and p.accounting_year = y) end;
    v_out := v_out || jsonb_build_array(q || jsonb_build_object(
      'kind', v_kind,
      'due', case v_kind when 'pit' then make_date(y + 1, 3, 31) else ((q->>'to')::date + interval '6 months')::date end,
      'order', case when f.id is not null then jsonb_build_object('id', f.id, 'status', f.status, 'amount', f.amount, 'counted', f.counted,
        'lines', f.lines, 'estimate', f.estimate, 'band_up_to', f.band_up_to, 'paid_at', f.paid_at, 'payer', f.payer,
        'practice', (select name from practices where id = f.practice_id), 'true_count', f.true_count, 'extra_due', f.extra_due,
        'extra_paid', f.extra_paid) end,
      'scans', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'file_name', s.file_name, 'pages', s.pages, 'status', s.status, 'path', s.path,
          'bank_account_id', s.bank_account_id, 'account', (select name from bank_accounts where id = s.bank_account_id), 'lines_found', s.lines_found,
          'created_at', s.created_at) order by s.created_at), '[]'::jsonb) from filing_scans s where s.order_id = f.id),
      'statements', (select coalesce(jsonb_agg(jsonb_build_object('file_name', i.file_name, 'account', b.name, 'from', coalesce(i.period_from, i.from_date),
          'to', coalesce(i.period_to, i.to_date), 'lines', i.lines_added, 'at', i.created_at) order by i.created_at), '[]'::jsonb)
        from bank_imports i join bank_accounts b on b.id = i.bank_account_id
        where i.org_id = p_org and coalesce(i.period_from, i.from_date) <= (q->>'to')::date and coalesce(i.period_to, i.to_date) >= (q->>'from')::date),
      'return', r,
      'pending', (select jsonb_build_object('tx_ref', c.tx_ref, 'amount', c.amount, 'payer', case when c.practice_id is not null then 'practice' else 'business' end,
          'status', c.status, 'at', c.created_at) from subscription_charges c
        where c.filing_order_id = f.id and c.status in ('pending', 'sent') and c.created_at > now() - interval '2 days' order by c.created_at desc limit 1)));
  end loop;
  return jsonb_build_object(
    'filing_only', o.filing_only, 'hold', private.filing_hold(p_org), 'is_sample', o.is_sample, 'managed', o.managed_by is not null,
    'kind', private.filing_kind(p_org, v_years[1]), 'legal_form', o.legal_form, 'vat_registered', o.vat_registered,
    'years', v_out,
    'prices', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'up_to', up_to, 'price', price) order by kind, coalesce(up_to, 2147483647)), '[]'::jsonb)
               from filing_prices),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'bank_name', b.bank_name,
        'last4', right(regexp_replace(coalesce(b.account_number, ''), '\D', '', 'g'), 4)) order by b.created_at), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active and b.kind in ('bank', 'cash')),
    'can_upload', private.perm_of(m, 'keep_books'),
    'can_pay', o.managed_by is null and not o.is_sample and (m.role in ('owner', 'admin') or m.acts_as_owner),
    'card', (select jsonb_build_object('last4', k.last4, 'brand', k.brand) from subscription_cards k where k.org_id = p_org and k.active
             order by k.created_at desc limit 1),
    'practice', private.filing_practice(p_org));
end $$;

-- A year's order, opened when the business starts on it.
create or replace function public.filing_open(p_org uuid, p_year integer) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_kind text;
begin
  m := private.require(p_org, 'keep_books');
  if not coalesce((select filing_only from orgs where id = p_org), false) then raise exception 'This business is not on filing-only.'; end if;
  if not (p_year = any (private.filing_years(p_org))) then raise exception 'Choose one of the years on the Filing page.'; end if;
  v_kind := private.filing_kind(p_org, p_year);
  if v_kind is null then raise exception 'This business is exempt from income tax, so it has no return to file.'; end if;
  insert into filing_orders (org_id, year, kind, created_by) values (p_org, p_year, v_kind, m.id) on conflict (org_id, year) do nothing;
  return public.filing_state(p_org);
end $$;

-- A scanned statement (a PDF with no text, or one whose columns could not be read) kept unread until the year is paid for,
-- and priced by its pages. The browser uploads it to <org>/filing/<year>/ first.
create or replace function public.filing_scan_hold(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; f public.filing_orders; v_year int := case when p->>'year' ~ '^\d{4}$' then (p->>'year')::int end; v_path text := p->>'path';
  v_pages int := case when p->>'pages' ~ '^\d{1,4}$' then (p->>'pages')::int end;
  v_acct uuid := private.uuid_of(p->>'bank_account_id'); v_obj record;
begin
  m := private.require(p_org, 'keep_books');
  select * into f from filing_orders where org_id = p_org and year = v_year;
  if not found then raise exception 'Choose the year on the Filing page first.'; end if;
  if f.status = 'paid' then raise exception '% is paid for: upload the statement again and it is read now.', v_year; end if;
  if v_pages is null or v_pages not between 1 and 500 then raise exception 'A scanned statement has 1 to 500 pages.'; end if;
  if v_path is null or v_path !~ ('^' || p_org::text || '/filing/' || v_year || '/[A-Za-z0-9_-][A-Za-z0-9._-]{0,150}\.pdf$') then
    raise exception 'The statement was not uploaded where expected. Upload it again.';
  end if;
  if v_acct is null or not exists (select 1 from bank_accounts where id = v_acct and org_id = p_org and active) then
    raise exception 'Choose the bank account this statement is for.';
  end if;
  select (metadata->>'size')::bigint size, metadata->>'mimetype' mime into v_obj from storage.objects where bucket_id = 'documents' and name = v_path;
  if not found then raise exception 'The statement was not found. Upload it again.'; end if;
  if v_obj.size is null or v_obj.size > 25 * 1048576 then raise exception 'A statement can be up to 25 MB.'; end if;
  if v_obj.mime is distinct from 'application/pdf' then raise exception 'A scanned statement must be a PDF.'; end if;
  insert into filing_scans (org_id, order_id, bank_account_id, path, file_name, pages, bytes, created_by)
  values (p_org, f.id, v_acct, v_path, left(nullif(trim(p->>'file_name'), ''), 200), v_pages, v_obj.size, m.id)
  on conflict (path) do nothing;
  return public.filing_state(p_org);
end $$;

-- A held scan taken off before payment (it no longer counts).
create or replace function public.filing_scan_remove(p_org uuid, p_scan uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.filing_scans;
begin
  m := private.require(p_org, 'keep_books');
  select * into s from filing_scans where id = p_scan and org_id = p_org for update;
  if not found then raise exception 'Statement not found.'; end if;
  if s.status <> 'held' or (select status from filing_orders where id = s.order_id) = 'paid' then
    raise exception 'This statement is part of a year already paid for.';
  end if;
  delete from filing_scans where id = s.id;
  return public.filing_state(p_org);
end $$;

-- A held scan read after payment: its lines are in the books (import_bank_lines gave p_import). When the real count of the
-- year (what was counted at payment, with the scans' own lines in place of their estimate) falls in a dearer band, the
-- difference is owed before the year's return can be approved.
create or replace function public.filing_scan_done(p_org uuid, p_scan uuid, p_import uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.filing_scans; f public.filing_orders; p record; v_found int; v_true int; b jsonb; v_owed numeric;
begin
  m := private.require(p_org, 'keep_books');
  select * into s from filing_scans where id = p_scan and org_id = p_org for update;
  if not found then raise exception 'Statement not found.'; end if;
  select * into f from filing_orders where id = s.order_id for update;
  if f.status <> 'paid' then raise exception 'Pay for % first: the statement is read after payment.', f.year; end if;
  if s.status = 'read' then return public.filing_state(p_org); end if;
  if not exists (select 1 from bank_imports where id = p_import and org_id = p_org and created_at >= s.created_at) then
    raise exception 'The statement''s lines were not found. Read it again.';
  end if;
  select * into p from private.cit_period(p_org, f.year);
  select count(*) into v_found from bank_lines where import_id = p_import and line_date between p.pfrom and p.pto;
  update filing_scans set status = 'read', import_id = p_import, lines_found = v_found, read_at = now() where id = s.id;
  select coalesce(f.lines, 0) + coalesce(sum(lines_found), 0) into v_true from filing_scans where order_id = f.id and status = 'read';
  b := private.filing_band(f.kind, v_true);
  v_owed := greatest(coalesce((b->>'price')::numeric, 0) - coalesce(f.amount, 0) - f.extra_paid, 0);
  update filing_orders set true_count = v_true, extra_due = v_owed, updated_at = now() where id = f.id;
  if v_owed > 0 then
    perform private.notify_perm(p_org, 'manage_settings', 'plan', format('Filing %s: ₦%s to pay', f.year, to_char(v_owed, 'FM999,999,999,990.00')),
      format('The scanned statements came to %s transactions for %s, more than the %s estimated. Pay the difference on the Filing page before the return is approved.',
        to_char(v_true, 'FM999,999,990'), f.year, to_char(f.counted, 'FM999,999,990')), '/filing', 'filing-extra-' || f.id);
  end if;
  return public.filing_state(p_org);
end $$;

-- A business on the free default plan (or no plan) that wants only its annual return: the owner or an admin switches to
-- filing-only. One paying for a plan lets the plan end first.
create or replace function public.filing_start(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.subscriptions; pl public.plans;
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business stays on its plan.'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  if found then
    select * into pl from plans where id = s.plan_id;
    if s.paid_by is not null or s.comp or (private.plan_price(pl, coalesce(s.billing, 'month')) > 0 and s.status in ('active', 'trialing', 'past_due')) then
      raise exception 'The business is on the % plan. Stop renewing it in Subscription and switch to filing-only when it ends.', pl.name;
    end if;
    delete from subscriptions where org_id = p_org;
  end if;
  update orgs set filing_only = true where id = p_org;
  update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and kind = 'start' and status = 'pending';
  perform private.activity_event(p_org, 'filing_only', 'Switched to filing-only by ' || m.display_name, '{}'::jsonb);
  return public.filing_state(p_org);
end $$;

-- A business a firm runs under full mandate is switched to filing-only by a partner or manager of that firm, in the
-- accountant portal; again only while no plan is being paid for (the firm stops paying for one first).
create or replace function public.practice_filing_start(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; pm public.practice_members; o public.orgs; s public.subscriptions; pl public.plans;
begin
  select * into c from practice_clients where id = p_client and status = 'active';
  if not found then raise exception 'Client not found.'; end if;
  pm := private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id for update;
  if o.managed_by is distinct from c.practice_id then
    raise exception 'The business''s owner switches it to filing-only in Settings, Subscription.' using errcode = '42501';
  end if;
  if o.read_only_at is not null then raise exception 'This business is read-only.'; end if;
  if o.filing_only then return jsonb_build_object('ok', true, 'filing_only', true); end if;
  select * into s from subscriptions where org_id = o.id for update;
  if found then
    select * into pl from plans where id = s.plan_id;
    if s.paid_by is not null or s.comp or (private.plan_price(pl, coalesce(s.billing, 'month')) > 0 and s.status in ('active', 'trialing', 'past_due')) then
      raise exception 'The business is on the % plan. Stop paying for it under Counta plans and switch to filing-only when it ends.', pl.name;
    end if;
    delete from subscriptions where org_id = o.id;
  end if;
  update orgs set filing_only = true where id = o.id;
  update subscription_charges set status = 'cancelled', updated_at = now() where org_id = o.id and kind = 'start' and status = 'pending';
  perform private.activity_event(o.id, 'filing_only', 'Switched to filing-only by ' || pm.display_name, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'filing_only', true);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Paying
-- ---------------------------------------------------------------------------
-- The amount to pay for a year now: the fee for its count while it is open, or the difference owed after its scans were
-- read. With what is charged and why (kept on the charge).
create or replace function private.filing_due(p_org uuid, p_year integer) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare f public.filing_orders; q jsonb;
begin
  select * into f from filing_orders where org_id = p_org and year = p_year;
  if not found then raise exception 'Choose the year on the Filing page first.'; end if;
  if f.status = 'paid' then
    if f.extra_due <= 0 then raise exception '% is paid for.', p_year; end if;
    return jsonb_build_object('order_id', f.id, 'amount', f.extra_due, 'extra', true, 'true_count', f.true_count, 'kind', f.kind, 'year', p_year);
  end if;
  q := private.filing_quote(p_org, p_year);
  if q->>'kind' is null then raise exception 'This business is exempt from income tax for %, so there is nothing to pay.', p_year; end if;
  -- The business's legal form changed since the year was opened (a business name registered as a company, say).
  if q->>'kind' is distinct from f.kind then
    update filing_orders set kind = q->>'kind', updated_at = now() where id = f.id;
  end if;
  if (q->>'counted')::int = 0 then
    raise exception 'Add the year''s bank statements first: the fee follows the number of transactions in them.';
  end if;
  if q->>'price' is null then raise exception 'TaxStreem has not set the filing prices yet. Try again later.'; end if;
  return jsonb_build_object('order_id', f.id, 'amount', (q->>'price')::numeric, 'extra', false, 'quote', q, 'kind', q->>'kind', 'year', p_year);
end $$;

-- A charge for the filing fee: one waiting from the last half hour for the same amount and payer, else a new one (any
-- other waiting for that year is cancelled).
create or replace function private.filing_charge(p_org uuid, d jsonb, p_practice uuid, p_card uuid, p_by uuid) returns public.subscription_charges
language plpgsql security definer set search_path = public, private as $$
declare c public.subscription_charges; v_order uuid := (d->>'order_id')::uuid; v_amount numeric := (d->>'amount')::numeric;
begin
  select * into c from subscription_charges where filing_order_id = v_order and kind = 'filing' and status = 'pending' and amount = v_amount
    and practice_id is not distinct from p_practice and created_at > now() - interval '30 minutes' order by created_at desc limit 1;
  if found then
    if p_card is not null and c.card_id is null then update subscription_charges set card_id = p_card where id = c.id returning * into c; end if;
    return c;
  end if;
  update subscription_charges set status = 'cancelled', updated_at = now() where filing_order_id = v_order and kind = 'filing' and status = 'pending';
  insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, requested_by, practice_id, filing_order_id, filing_quote)
  values (p_org, private.filing_plan_id(), 'year', v_amount, 'card', 'filing', p_card, 'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    p_by, p_practice, v_order, d)
  returning * into c;
  return c;
end $$;

-- The business pays for a year by card (Flutterwave's page the first time, then the saved card).
create or replace function public.filing_pay_start(p_org uuid, p_year integer, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; d jsonb; c public.subscription_charges; v_card uuid;
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business pays for the filing.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business does not pay for filing.'; end if;
  if not coalesce((select filing_only from orgs where id = p_org), false) then raise exception 'This business is not on filing-only.'; end if;
  if private.filing_plan_id() is null then raise exception 'Filing-only is not available just now.'; end if;
  d := private.filing_due(p_org, p_year);
  if coalesce((p->>'use_saved')::boolean, true) then
    select id into v_card from subscription_cards where org_id = p_org and active order by created_at desc limit 1;
  end if;
  c := private.filing_charge(p_org, d, null, v_card, m.id);
  return jsonb_build_object('action', case when c.card_id is not null then 'charge_card' else 'checkout' end, 'charge_id', c.id, 'tx_ref', c.tx_ref,
    'amount', c.amount);
end $$;

-- A partner or manager of a firm the business works with pays for a year with the firm's card.
create or replace function public.practice_filing_pay_start(p_org uuid, p_year integer, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr jsonb := private.filing_practice(p_org); d jsonb; c public.subscription_charges; v_card uuid; v_seat uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if pr is null then raise exception 'Only a partner or manager of a firm working for this business pays from the firm''s card.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business does not pay for filing.'; end if;
  if not coalesce((select filing_only from orgs where id = p_org), false) then raise exception 'This business is not on filing-only.'; end if;
  if private.filing_plan_id() is null then raise exception 'Filing-only is not available just now.'; end if;
  d := private.filing_due(p_org, p_year);
  if coalesce((p->>'use_saved')::boolean, true) then
    select id into v_card from subscription_cards where practice_id = (pr->>'id')::uuid and active order by created_at desc limit 1;
  end if;
  select id into v_seat from members where org_id = p_org and user_id = auth.uid();
  c := private.filing_charge(p_org, d, (pr->>'id')::uuid, v_card, v_seat);
  return jsonb_build_object('action', case when c.card_id is not null then 'charge_card' else 'checkout' end, 'charge_id', c.id, 'tx_ref', c.tx_ref,
    'amount', c.amount);
end $$;

-- What the payments function needs to take a charge: for the filing fee, its own words on Flutterwave's page and the Filing
-- page to come back to.
create or replace function public.svc_subscription_charge(p_charge uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('charge', to_jsonb(c) - 'journal_id' - 'filing_quote', 'plan', jsonb_build_object('name', pl.name, 'code', pl.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'phone', o.phone,
      'email', coalesce((select coalesce(mb.email, u.email) from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = o.id and (mb.role = 'owner' or mb.id = (private.org_contact(o.id)).id)
        order by mb.created_at limit 1), o.email)),
    'card', (select jsonb_build_object('token', k.token, 'email', k.email, 'last4', k.last4) from subscription_cards k
             where k.active and (case when c.practice_id is not null then k.practice_id = c.practice_id else k.org_id = c.org_id end)
               and (c.card_id is null or k.id = c.card_id) order by (k.id = c.card_id) desc, k.created_at desc limit 1),
    'payer', case when c.practice_id is not null then (select jsonb_build_object('kind', 'practice', 'id', pr.id, 'name', pr.name,
        'email', coalesce(nullif(pr.email, ''), (select u.email from auth.users u where u.id = pr.created_by)), 'phone', pr.phone) from practices pr where pr.id = c.practice_id) end,
    'return_path', case when c.kind = 'filing' then '/filing' when c.practice_id is not null then '/practice/billing' else '/settings/subscription' end,
    'description', case when c.kind = 'filing' then (select format('%s for %s, %s accounts%s', case f.kind when 'pit' then 'Personal income tax return'
        else 'Companies income tax return' end, left(o.name, 40), f.year, case when coalesce((c.filing_quote->>'extra')::boolean, false) then ' (the balance)' else '' end)
      from filing_orders f where f.id = c.filing_order_id) end,
    'narration', case when c.kind = 'filing' then (select format('Counta annual filing %s', f.year) from filing_orders f where f.id = c.filing_order_id) end,
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'rail', w.rail) from wallets w
               where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1))
  from subscription_charges c join orgs o on o.id = c.org_id join plans pl on pl.id = c.plan_id where c.id = p_charge
$$;

create or replace function public.svc_subscription_expire(p_tx_ref text) returns void
language sql security definer set search_path = public as $$
  update subscription_charges set status = 'cancelled', error = 'The checkout was not finished.', updated_at = now()
  where tx_ref = p_tx_ref and status = 'pending' and method = 'card' and kind in ('start', 'filing')
$$;

-- A filing fee paid: the year's order records what was counted and charged, and the people who keep the books are told
-- the books and the return are being prepared.
create or replace function private.filing_paid(c public.subscription_charges) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare f public.filing_orders; q jsonb := coalesce(c.filing_quote, '{}'::jsonb);
begin
  select * into f from filing_orders where id = c.filing_order_id for update;
  if not found then return jsonb_build_object('status', 'successful', 'order', null); end if;
  if coalesce((q->>'extra')::boolean, false) then
    update filing_orders set extra_paid = extra_paid + c.amount, extra_due = greatest(extra_due - c.amount, 0), extra_paid_at = now(), updated_at = now()
    where id = f.id;
  elsif f.status = 'open' then
    update filing_orders set status = 'paid', kind = coalesce(q->'quote'->>'kind', kind), lines = (q->'quote'->>'lines')::int,
      scan_pages = (q->'quote'->>'scan_pages')::int, estimate = (q->'quote'->>'estimate')::int, counted = (q->'quote'->>'counted')::int,
      band_up_to = (q->'quote'->>'band_up_to')::int, amount = c.amount, paid_at = now(),
      payer = case when c.practice_id is not null then 'practice' else 'business' end, practice_id = c.practice_id, charge_id = c.id,
      true_count = (q->'quote'->>'counted')::int, updated_at = now()
    where id = f.id;
    perform private.notify_perm(c.org_id, 'keep_books', 'books', format('Filing %s paid: the books are being prepared', f.year),
      'Counta is reading the statements and building the books. Questions about lines it cannot explain come to the books inbox; the return follows.',
      '/filing', 'filing-paid-' || f.id);
  else
    -- Paid twice (two payment pages finished): the money is recorded on the charge; TaxStreem refunds the second.
    perform private.activity_event(c.org_id, 'filing_paid_twice', format('A second filing fee for %s was paid (%s)', f.year, c.tx_ref),
      jsonb_build_object('charge_id', c.id, 'order_id', f.id));
  end if;
  if c.practice_id is not null then
    perform private.practice_notify(c.practice_id, format('Filing %s paid for %s', f.year, coalesce((select name from orgs where id = c.org_id), 'a client')),
      format('₦%s on the firm''s card.', to_char(c.amount, 'FM999,999,999,990.00')), '/practice');
  end if;
  return jsonb_build_object('status', 'successful', 'order', f.id, 'year', f.year);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Existing functions, each changed in one place
-- ---------------------------------------------------------------------------
-- public.cit_year: a filing-only business sees a year once it is paid for.
CREATE OR REPLACE FUNCTION public.cit_year(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; comp jsonb; p record;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.cit_run(p_org, p_year);
  return jsonb_build_object('computation', comp,
    'row', jsonb_build_object('status', coalesce(cy.status, 'draft'), 'source', comp->>'source', 'settings', coalesce(cy.settings, '{}'::jsonb),
      'adjustments', coalesce(cy.adjustments, '{}'::jsonb), 'overrides', coalesce(cy.overrides, '{}'::jsonb), 'imported', coalesce(cy.imported, '{}'::jsonb),
      'imported_from', cy.imported_from, 'afs_path', cy.afs_path, 'template_path', cy.template_path, 'approved_at', cy.approved_at,
      'approved_by', (select display_name from members where id = cy.approved_by), 'flux_status', cy.flux_status, 'flux_ref', cy.flux_ref,
      'flux_message', cy.flux_message, 'flux_sent_at', cy.flux_sent_at, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'rev360_computation', cy.rev360_computation, 'updated_at', cy.updated_at),
    'lines', (select jsonb_agg(jsonb_build_object('cell', l.cell, 'sheet', l.sheet, 'addr', l.addr, 'section', l.section, 'label', l.label, 'note', l.note,
        'codes', l.codes, 'positive_only', l.positive_only, 'config_id', l.config_id,
        'amount', coalesce((comp->'cells'->>l.cell)::numeric, (comp->'adjustments'->>l.cell)::numeric, 0),
        'detail', comp->'detail'->l.cell, 'items', comp->'items'->l.cell,
        'source', case when l.sheet = 'PROFIT_ADJUSTMENT' then 'adjustment' when cy.overrides ? l.cell then 'override'
                       when comp->>'source' = 'imported' then coalesce(cy.imported->l.cell->>'source', 'imported') else 'books' end,
        'imported', cy.imported->l.cell, 'override', cy.overrides->l.cell) order by l.sort) from cit_template_lines l),
    'declaration', private.cit_declaration(p_org, comp),
    'tax_assets', (select coalesce(jsonb_agg(to_jsonb(t) order by t.in_use_from, t.name), '[]'::jsonb) from tax_assets t where t.org_id = p_org),
    'can_edit', private.perm_of(m, 'keep_books') and coalesce(cy.status, 'draft') in ('draft', 'rejected'),
    'can_approve', private.perm_of(m, 'keep_books') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_adjustments')),
    'period', jsonb_build_object('from', p.pfrom, 'to', p.pto));
end $function$;

-- public.pit_year: a filing-only business sees a year once it is paid for.
CREATE OR REPLACE FUNCTION public.pit_year(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; py public.pit_years; comp jsonb; v_cit jsonb; v_draft boolean; v_all boolean; v_books boolean; p record;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  acc := private.pit_access(p_org);
  if p_year < 2025 or p_year > 2100 then raise exception 'Counta prepares personal income tax from 2025 accounts.'; end if;
  v_all := (acc->>'all')::boolean;
  v_books := (acc->>'books')::boolean or v_all;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  v_draft := coalesce(py.status, 'draft') = 'draft';
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.pit_live(p_org, p_year, private.pit_run(p_org, p_year));
  if private.can_handle_money(p_org) then
    v_cit := public.cit_year(p_org, p_year);
    v_cit := v_cit || jsonb_build_object('can_edit', coalesce((v_cit->>'can_edit')::boolean, false) and v_draft);
  end if;
  return jsonb_build_object('kind', private.income_tax_kind(p_org, p_year), 'computation', private.pit_mask(comp, acc), 'state', private.pit_state(p_org, p_year),
    'row', jsonb_build_object('status', coalesce(py.status, 'draft'), 'settings', coalesce(py.settings, '{}'::jsonb), 'soa_path', py.soa_path,
      'approved_at', py.approved_at, 'approved_by', (select display_name from members where id = py.approved_by), 'attested', py.snapshot->'attested',
      'updated_at', py.updated_at),
    'cit', v_cit,
    'people_all', (select coalesce(jsonb_agg(jsonb_build_object('id', pp.id, 'name', pp.name, 'tin', pp.tin, 'member_id', pp.member_id, 'active', pp.active,
        'source', pp.source) order by pp.sort, pp.created_at), '[]'::jsonb) from pit_people pp where pp.org_id = p_org),
    'members', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('id', mm.id, 'name', mm.display_name, 'role', mm.role) order by mm.display_name), '[]'::jsonb)
        from members mm where mm.org_id = p_org and mm.status = 'active' and mm.practice_id is null) end,
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'authority', private.state_code(l.state), 'is_main', l.is_main)
        order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name) order by a.sort) from tax_authorities a),
    'needs_setup', not exists (select 1 from pit_people where org_id = p_org),
    'suggested', case when not exists (select 1 from pit_people where org_id = p_org) then
        coalesce((select jsonb_agg(d->>'name') from orgs o, jsonb_array_elements(case when jsonb_typeof(o.directors) = 'array' then o.directors else '[]'::jsonb end) d
                  where o.id = p_org and coalesce(d->>'name', '') <> ''), '[]'::jsonb) end,
    'can', jsonb_build_object('see_all', v_all, 'edit_business', v_books and v_draft, 'edit_people', v_all and v_draft,
      'edit_self', acc->>'me' is not null and v_draft, 'approve', v_all, 'owner', (acc->>'owner')::boolean),
    'me', acc->'me', 'period', jsonb_build_object('from', p.pfrom, 'to', p.pto), 'relief_needs', private.pit_relief_needs(), 'staff_roles', private.pit_staff_roles(),
    'bot_authorities', to_jsonb(private.pit_bot_authorities()),
    'logins', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'status', l.status, 'tax_office', l.tax_office,
        'username_hint', l.username_hint)), '[]'::jsonb) from portal_logins l where l.org_id = p_org) end);
end $function$;

-- public.cit_pack: a filing-only business sees a year once it is paid for.
CREATE OR REPLACE FUNCTION public.cit_pack(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; comp jsonb; o public.orgs; v_draft boolean; v_org jsonb; v_tin text;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select * into o from orgs where id = p_org;
  v_draft := cy.accounting_year is null or cy.status = 'draft' or cy.snapshot is null;
  if v_draft then
    comp := private.cit_run(p_org, p_year, null);
    v_org := jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'address', o.address, 'taxstreem_org_id', o.taxstreem_org_id);
  else
    comp := cy.snapshot->'computation';
    v_org := cy.snapshot->'org';
  end if;
  v_tin := nullif(regexp_replace(coalesce(v_org->>'tin', ''), '[^0-9A-Za-z-]', '', 'g'), '');
  return jsonb_build_object(
    'org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'regime', comp->>'regime', 'from', comp->>'from', 'to', comp->>'to',
    'status', coalesce(cy.status, 'draft'), 'draft', v_draft, 'org', v_org,
    'cell_map', case when v_draft then private.cit_cell_map(comp) else cy.snapshot->'cell_map' end,
    'declaration', case when v_draft then private.cit_declaration(p_org, comp) else cy.snapshot->'declaration' end,
    'figures', comp->'figures', 'rows', comp->'rows', 'checks', comp->'checks', 'due', comp->>'due',
    'file_name', p_year || '_' || coalesce(v_tin, 'NO-TIN') || '_CIT' || case when v_draft then '_DRAFT' else '' end || '.xlsx',
    'afs_path', cy.afs_path, 'template_path', case when v_draft then null else cy.template_path end,
    'approved_by', cy.snapshot->>'approved_by', 'approved_at', cy.snapshot->>'approved_at',
    'flux', jsonb_build_object('status', cy.flux_status, 'ref', cy.flux_ref, 'message', cy.flux_message, 'sent_at', cy.flux_sent_at,
      'updated_at', cy.flux_updated_at, 'acknowledgement_ref', cy.acknowledgement_ref, 'filed_at', cy.filed_at),
    'can_send', not v_draft and cy.status in ('approved', 'rejected') and cy.afs_path is not null
      and private.perm_of(m, 'keep_books') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_adjustments')));
end $function$;

-- public.pit_pack: a filing-only business sees a year once it is paid for.
CREATE OR REPLACE FUNCTION public.pit_pack(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; py public.pit_years; comp jsonb;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' or py.snapshot is null then raise exception 'Approve the % return before sending it.', p_year; end if;
  comp := py.snapshot->'computation';
  return jsonb_build_object('org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'from', comp->>'from', 'to', comp->>'to', 'regime', comp->>'regime',
    'kind', comp->>'kind', 'due', comp->>'due', 'org', py.snapshot->'org', 'attested', py.snapshot->'attested', 'approved_by', py.snapshot->>'approved_by',
    'approved_at', py.snapshot->>'approved_at', 'soa_path', py.soa_path, 'business', comp->'business'->'rows', 'business_figures', comp->'business'->'figures',
    'flux_authorities', comp->'flux_authorities', 'rulebook', comp->'rulebook',
    'bot_authorities', to_jsonb(private.pit_bot_authorities()), 'staff', coalesce(comp->'staff', '[]'::jsonb), 'staff_review', comp->'staff_review', 'portal_ready', comp ? 'staff_review', 'relief_needs', private.pit_relief_needs(),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('number', a->>'number', 'name', a->>'name', 'category', a->>'category', 'cost', a->'qce', 'in_use', a->>'in_use',
        'first_year', a->'first_year', 'use_pct', a->'use_pct', 'tax_value_bf', a->'twdv_bf', 'allowance', a->'allowance', 'tax_value_cf', a->'twdv_cf',
        'disposed', a->'disposed', 'proceeds', a->'proceeds', 'qualifies', a->'qualifies')), '[]'::jsonb)
      from jsonb_array_elements(coalesce(comp->'business'->'ca'->'assets', '[]'::jsonb)) a),
    'logins', (select coalesce(jsonb_object_agg(l.authority, jsonb_build_object('flux_ref', l.flux_ref, 'tax_office', l.tax_office, 'status', l.status)), '{}'::jsonb)
      from portal_logins l where l.org_id = p_org),
    'people', (select coalesce(jsonb_agg(x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'computation_path', y.computation_path, 'household_staff', y.household_staff, 'portal', y.portal,
        'etax_login', private.pit_etax_login_of(p_org, y.person_id, x->>'authority'), 'income_fields', coalesce(x->'income_fields', private.pit_portal_income(x->'computation')))), '[]'::jsonb)
      from jsonb_array_elements(comp->'people') x
      left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (x->>'person_id')::uuid));
end $function$;

-- public.financial_statements_pack: a filing-only business sees its statements once a year is paid for.
CREATE OR REPLACE FUNCTION public.financial_statements_pack(p_org uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; pr jsonb; v jsonb; w jsonb := '[]'::jsonb; k text; n jsonb; v_susp numeric; tc jsonb; x jsonb;
begin
  if private.filing_unpaid(p_org, null) then return private.filing_unpaid_json(p_org, null); end if;
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Financial reports need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  pr := private.fs_periods(p_org, p_from, p_to);
  n := coalesce(o.fs_narrative, '{}'::jsonb);
  v := jsonb_build_object('org', private.corporate_json(p_org), 'periods', pr, 'signing_directors', private.signing_directors(p_org), 'generated_at', now());
  foreach k in array array['corporate', 'directors_report', 'responsibilities', 'value_added', 'five_year'] loop
    v := v || jsonb_build_object(k, public.statement_extra(p_org, k, (pr->>'from')::date, (pr->>'to')::date));
  end loop;
  foreach k in array array['sofp', 'sopl', 'soce', 'cash_flow', 'notes'] loop
    v := v || jsonb_build_object(k, public.accounting_report(p_org, k, (pr->>'from')::date, (pr->>'to')::date, '{}'::jsonb));
  end loop;
  tc := private.tax_computation(p_org, (pr->>'from')::date, (pr->>'to')::date);
  v := v || jsonb_build_object('tax_computation', jsonb_build_object('rows', tc->'rows', 'extra', jsonb_build_object('figures', tc->'figures', 'flags', tc->'flags',
      'settings', tc->'settings')),
    'capital_allowances', jsonb_build_object('rows', tc->'ca'->'rows', 'extra', jsonb_build_object('assets', tc->'ca'->'assets', 'months', tc->'ca'->'months',
      'retention', tc->'ca'->'retention', 'totals', tc->'ca'->'totals')));
  -- What to settle before signing.
  if jsonb_array_length(o.directors) = 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Add the directors who sign the statements.')); end if;
  if jsonb_array_length(private.signing_directors(p_org)) = 1 then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Only one director is recorded; the statement of financial position is normally signed by two.')); end if;
  if not ((v->'sofp'->'extra'->>'casts')::boolean) then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'The statement of financial position does not cast.')); end if;
  if coalesce((v->'cash_flow'->'extra'->>'casts')::boolean, true) is false then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'The statement of cash flows does not end on the cash in the books.')); end if;
  if coalesce((v->'sofp'->'extra'->>'unreconciled')::numeric, 0) <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Unreconciled bank balances of ' || private.naira((v->'sofp'->'extra'->>'unreconciled')::numeric) || ' remain. Clear them in Banking.')); end if;
  if coalesce((v->'sofp'->'extra'->>'opening_to_confirm')::numeric, 0) <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Opening balances of ' || private.naira((v->'sofp'->'extra'->>'opening_to_confirm')::numeric) || ' still sit in 3999 and need to be reclassified.')); end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_susp from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and split_part(l.account_code, '-', 1) = '9001' and j.entry_date <= (pr->>'to')::date;
  if v_susp <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Transactions of ' || private.naira(v_susp) || ' wait in suspense (9001). Answer the books inbox first.')); end if;
  if coalesce(private.closed_through(p_org), date '1900-01-01') < (pr->>'to')::date then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text',
    case when private.closed_through(p_org) is null then 'No period has been closed yet' else 'The books are open after ' || private.fdate(private.closed_through(p_org)) end
    || '. Close the period so the figures cannot change after signing.')); end if;
  if nullif(n->>'approved_on', '') is null then w := w || jsonb_build_array(jsonb_build_object('level', 'info', 'text', 'No approval date yet: the statements print a blank line for it.')); end if;
  foreach k in array array['going_concern', 'contingencies', 'commitments', 'events_after', 'dividend'] loop
    if nullif(n->>k, '') is null then
      w := w || jsonb_build_array(jsonb_build_object('level', 'info', 'key', k, 'text', 'Standard wording used for ' || replace(k, '_', ' ') || '. Confirm it or write your own.'));
    end if;
  end loop;
  if nullif(o.rc_number, '') is null or nullif(o.tin, '') is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the RC number and Tax ID under Settings, Branding.')); end if;
  if o.company_secretary is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the company secretary for the directors'' report.')); end if;
  -- The tax computation's own checks, and whether the accounts carry the charge it computes.
  for x in select * from jsonb_array_elements(coalesce(tc->'flags', '[]'::jsonb)) loop
    w := w || jsonb_build_array(x || jsonb_build_object('text', 'Tax computation: ' || (x->>'text')));
  end loop;
  if coalesce(o.legal_form, 'company') = 'company'
     and abs(((tc->'figures'->>'cit')::numeric + (tc->'figures'->>'levy')::numeric + (tc->'figures'->>'topup')::numeric) - (tc->'figures'->>'tax_in_accounts')::numeric) >= 1 then
    w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'key', 'tax_charge', 'text', 'The tax computation gives a charge of ' || private.naira((tc->'figures'->>'cit')::numeric
      + (tc->'figures'->>'levy')::numeric + (tc->'figures'->>'topup')::numeric) || ', but the accounts carry ' || private.naira((tc->'figures'->>'tax_in_accounts')::numeric)
      || case when tc->'settings'->>'posted_journal_id' is not null then '. The figures changed after the charge was posted: post it again from the Tax tab.' else '. Post the tax charge from the Tax tab.' end));
  end if;
  return v || jsonb_build_object('warnings', w);
end $function$;

-- private.feature_on: no AI reading for a filing-only business until it has paid for a year.
CREATE OR REPLACE FUNCTION private.feature_on(p_org uuid, p_feature text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v boolean;
begin
  if p_feature = 'ai_reading' and private.filing_hold(p_org) then return false; end if;
  select enabled into v from org_switches where org_id = p_org and feature = p_feature;
  if found then return v; end if;
  if not coalesce((private.setting('switches')->>p_feature)::boolean, true) then return false; end if;
  return private.plan_allows(p_org, p_feature);
end $function$;

-- public.svc_lines_for_ai: a filing-only business's lines are read for the years it paid for.
CREATE OR REPLACE FUNCTION public.svc_lines_for_ai(p_org uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object(
    'org', (select jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'vat_registered', o.vat_registered,
       'cash_sales_without_invoices', o.cash_sales_without_invoices, 'threshold', greatest(o.auto_post_threshold, 0.8)) from orgs o where o.id = p_org),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', bl.id, 'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description,
        'reference', bl.reference, 'counterparty', bl.counterparty, 'account', b.name, 'account_kind', b.kind,
        'history', (select jsonb_agg(h) from (select l.account_code code, count(*) n from bank_lines x join journal_lines l on l.journal_id = x.journal_id
            and l.account_code <> b.ledger_code where x.org_id = p_org and x.party_key = bl.party_key and x.status in ('posted', 'matched') and x.id <> bl.id
            group by 1 order by 2 desc limit 3) h)) order by bl.line_date), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org and status = 'unmatched' and ai_attempts < 3 and private.filing_day_open(p_org, line_date) order by line_date limit greatest(p_limit, 1)) bl
      join bank_accounts b on b.id = bl.bank_account_id),
    'accounts', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category, 'ifrs_line', a.ifrs_line) order by a.code)
      from private.accounts_of(p_org) a
      where a.active and not a.is_group and private.postable(p_org, a.code) and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from customers where org_id = p_org and not is_walk_in and not archived),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from vendors where org_id = p_org),
    'directors', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from members where org_id = p_org and role = 'owner'))
$function$;

-- public.svc_suspend_rest: lines of years a filing-only business has not paid for wait, unasked.
CREATE OR REPLACE FUNCTION public.svc_suspend_rest(p_org uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare bl record; n int := 0;
begin
  for bl in select id, amount from bank_lines where org_id = p_org and status = 'unmatched' and (ai_attempts >= 3 or created_at < now() - interval '1 hour')
    and private.filing_day_open(p_org, line_date) loop
    perform private.suspend_line(bl.id, 'Unexplained ' || case when bl.amount > 0 then 'money in' else 'payment' end,
      case when bl.amount > 0 then 'What was this money for?' else 'What was this payment for?' end, '{}'::jsonb, 0, 'Nothing in the books or the rules explains it',
      'suspense');
    n := n + 1;
  end loop;
  return n;
end $function$;

-- public.svc_subscription_charge_update: a filing fee paid records the year as paid, not a plan.
CREATE OR REPLACE FUNCTION public.svc_subscription_charge_update(p_tx_ref text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
      select id into v_card from subscription_cards where token = p->'card'->>'token' and active
        and (case when c.practice_id is not null then practice_id = c.practice_id else org_id = c.org_id end);
      if v_card is null then
        insert into subscription_cards (org_id, practice_id, token, email, last4, brand, expiry, added_by)
        values (case when c.practice_id is null then c.org_id end, c.practice_id, p->'card'->>'token', coalesce(nullif(p->'card'->>'email', ''), 'unknown@counta.ng'),
          left(p->'card'->>'last4', 4), left(p->'card'->>'brand', 30), left(p->'card'->>'expiry', 7), c.requested_by)
        returning id into v_card;
      end if;
    end if;
    if c.kind = 'filing' then
      update subscription_charges set status = 'successful', paid_at = now(), provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref),
        card_id = coalesce(v_card, card_id), error = null, updated_at = now() where id = c.id returning * into c;
      return private.filing_paid(c);
    end if;
    select * into s from subscriptions where org_id = c.org_id for update;
    v_start := case when c.kind = 'renewal' and s.current_period_end is not null and s.current_period_end > now() - interval '7 days'
                    then s.current_period_end else now() end;
    v_end := v_start + case when c.billing = 'year' then interval '1 year' else interval '1 month' end;
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_used, paid_by)
    values (c.org_id, c.plan_id, 'active', c.billing, c.method, coalesce(v_card, c.card_id), v_start, v_end, false, c.practice_id)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = case when excluded.paid_by is distinct from subscriptions.paid_by then excluded.card_id else coalesce(excluded.card_id, subscriptions.card_id) end,
      current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end, trial_ends_at = null, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, paid_by = excluded.paid_by, updated_at = now();
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
      format('₦%s %s. It runs to %s.', to_char(c.amount, 'FM999,999,999,990.00'),
        case when c.practice_id is not null then 'by ' || coalesce((select name from practices where id = c.practice_id), 'your accountant')
             when c.method = 'wallet' then 'from the wallet' else 'by card' end,
        to_char(v_end at time zone 'Africa/Lagos', 'DD Mon YYYY')), '/settings/subscription', 'sub-' || c.id);
    return jsonb_build_object('status', 'successful', 'period_end', v_end);
  end if;
  -- Failed.
  update subscription_charges set status = 'failed', error = left(coalesce(nullif(p->>'error', ''), 'The payment did not go through.'), 300),
    provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now() where id = c.id;
  if c.kind = 'renewal' then
    update subscriptions set status = 'past_due', past_due_since = coalesce(past_due_since, now()), attempts = attempts + 1, retry_at = now() + interval '1 day',
      updated_at = now() where org_id = c.org_id;
    if c.practice_id is not null then perform private.practice_notify(c.practice_id, 'Counta plan payment failed for ' || coalesce((select name from orgs where id = c.org_id), 'a client'),
      'Counta tries the card again tomorrow. Check the card under Billing.', '/practice/billing'); end if;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Counta plan payment failed',
      format('%s. Counta tries again tomorrow; after three days the business moves to the %s plan. Check the card or fund the wallet in Settings, Subscription.',
        left(coalesce(nullif(p->>'error', ''), 'The payment did not go through'), 200), (select name from plans where id = private.default_plan_id())),
      '/settings/subscription', 'sub-fail-' || c.org_id);
  end if;
  return jsonb_build_object('status', 'failed');
end $function$;

-- public.subscription_start: Annual filing is not a plan to choose.
CREATE OR REPLACE FUNCTION public.subscription_start(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; pl public.plans; cur public.plans; s public.subscriptions; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_method text := nullif(p->>'method', ''); v_price numeric; v_cur_price numeric; c public.subscription_charges; v_card uuid; v_bal numeric;
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business stays on its plan.'; end if;
  if v_billing not in ('month', 'year') then raise exception 'Pay monthly or yearly.'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  select * into cur from plans where id = private.org_plan_id(p_org);
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active and (public or id = cur.id);
  if not found then raise exception 'Choose a plan.'; end if;
  if pl.kind = 'filing' then raise exception 'Annual filing is paid year by year on the Filing page.'; end if;
  v_price := private.plan_price(pl, v_billing);
  if pl.id = cur.id and coalesce(s.billing, 'month') = v_billing and coalesce(s.status, 'active') <> 'past_due' and not coalesce(s.cancel_at_period_end, false)
     and s.next_plan_id is null and (v_price = 0 or s.pay_method is not null) and s.paid_by is null then
    raise exception 'The business is on % already.', pl.name;
  end if;

  -- A free plan starts at once.
  if v_price = 0 then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, current_period_start, current_period_end)
    values (p_org, pl.id, 'active', v_billing, null, now(), now() + case when v_billing = 'year' then interval '1 year' else interval '1 month' end)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = null, card_id = null,
      current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end, trial_ends_at = null,
      cancel_at_period_end = false, next_plan_id = null, next_billing = null, past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and status = 'pending';
    return jsonb_build_object('action', 'done', 'state', public.subscription_state(p_org));
  end if;

  if coalesce(v_method, '') not in ('card', 'wallet') then raise exception 'Pay by card or from the wallet.'; end if;
  select id into v_card from subscription_cards where org_id = p_org and active order by (id = s.card_id) desc, created_at desc limit 1;
  -- The business paying for itself again: the accountant's card is not used for it.
  if s.paid_by is not null then v_card := null; s.card_id := null; end if;

  -- A first trial of a plan with one: no charge until it ends.
  if pl.trial_days > 0 and not coalesce(s.trial_used, false) and not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful') then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_ends_at, trial_used)
    values (p_org, pl.id, 'trialing', v_billing, v_method, case when v_method = 'card' then v_card end, now(), now() + make_interval(days => pl.trial_days),
      now() + make_interval(days => pl.trial_days), true)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'trialing', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = excluded.card_id, current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
      trial_ends_at = excluded.trial_ends_at, trial_used = true, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    return jsonb_build_object('action', 'done', 'trial', true, 'state', public.subscription_state(p_org));
  end if;

  -- A cheaper plan while a paid period runs: it starts when the period ends.
  v_cur_price := private.plan_price(cur, coalesce(s.billing, 'month'));
  if s.status = 'active' and s.current_period_end > now() and v_cur_price > 0 and not coalesce(s.comp, false)
     and v_price < private.plan_price(cur, v_billing) then
    update subscriptions set next_plan_id = pl.id, next_billing = v_billing, pay_method = v_method, card_id = coalesce(v_card, card_id),
      cancel_at_period_end = false, paid_by = null, updated_at = now() where org_id = p_org;
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
end $function$;

-- public.kyc_submit: a business set up for filing only.
CREATE OR REPLACE FUNCTION public.kyc_submit(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false; v_for uuid; v_to jsonb; v_rc text; mc public.practice_clients; v_intake_rc text;
  v_dup jsonb; v_practice uuid; mo public.orgs; v_reg text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  v_for := private.uuid_of(p->>'org_id');
  if nullif(trim(coalesce(p->>'org_id', '')), '') is not null and v_for is null then raise exception 'Choose the business.'; end if;
  if v_for is not null and not private.is_owner(v_for) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  v_to := case when v_for is not null then jsonb_build_object('org_id', v_for) else '{}'::jsonb end;
  if p ? 'answers' then
    perform public.kyc_answer(case when jsonb_typeof(p->'answers') = 'object' then (p->'answers') || v_to else p->'answers' end);
  end if;
  if p ? 'charges_vat' then perform public.kyc_answer(jsonb_build_object('charges_vat', p->'charges_vat') || v_to); end if;
  k := private.kyc_row(v_uid, v_for);
  if v_for is not null and k.org_id is distinct from v_for then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  end if;
  if k.org_id is not null and not private.is_owner(k.org_id) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  if k.source is null then raise exception 'Find the business on CAC first, or tell us it is not registered.'; end if;
  if array_length(private.kyc_missing(k.answers), 1) > 0 then
    raise exception 'A few questions are still open: %.', array_to_string(private.kyc_missing(k.answers), ', ');
  end if;
  c := k.cac->'profile';
  select * into v_cat from business_categories where id = k.answers->>'category';
  v_cls := upper(coalesce(c->>'classification', ''));
  v_form := case when v_cls like 'COMPANY%' then 'company' when v_cls = 'BUSINESS_NAME' then 'enterprise' when v_cls = 'IT' then 'ngo'
                 when v_cls = 'LP' then 'partnership' when k.source = 'manual' then 'individual' else null end;
  v_name := coalesce(nullif(left(trim(p->>'trading_name'), 120), ''), initcap(lower(c->>'approved_name')), k.manual->>'name');
  v_addr := coalesce(nullif(left(trim(p->>'address'), 300), ''), nullif(trim(c->>'business_address'), ''), nullif(trim(c->>'address'), ''), k.manual->>'address');
  v_vat := coalesce((k.answers->>'charges_vat')::boolean, k.answers->>'revenue_band' = 'over_100m' or k.answers->'filing'->>'vat' in ('always', 'sometimes'));
  v_tin := coalesce(nullif(regexp_replace(coalesce(k.tin->>'nrs_tin', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(c->>'tax_id', ''), '\D', '', 'g'), ''));
  if v_tin !~ '^[0-9]{13}$' then v_tin := null; end if;
  v_dir := (select jsonb_agg(jsonb_build_object('name', private.person(d), 'appointed', left(d->>'date_of_appointment', 10)))
            from jsonb_array_elements(coalesce(c->'directors', '[]'::jsonb)) d where private.person(d) is not null);
  v_shares := (select sum(case when s->>'num_shares_alloted' ~ '^[0-9]+$' then (s->>'num_shares_alloted')::numeric else 0 end)
               from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s);
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_display, v_email from auth.users where id = v_uid;
  v_branch := coalesce(nullif(left(trim(p->>'branch_name'), 60), ''), 'Head office');

  -- The company: its turn on its numbers, and for a business a practice runs, the one the firm took on and nobody else's.
  v_rc := coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''));
  perform private.company_lock(v_rc, v_tin);
  -- The number with its registry, from the CAC classification when the number does not say (RC for a company, BN for a
  -- business name, IT for incorporated trustees), to compare it.
  v_reg := case when private.reg_kind(v_rc) is null and private.norm_id(v_rc) is not null and v_form in ('company', 'enterprise', 'ngo')
    then case v_form when 'company' then 'RC ' when 'enterprise' then 'BN ' else 'IT ' end || v_rc else v_rc end;
  if k.org_id is not null and private.is_managed(k.org_id) then
    select managed_by into v_practice from orgs where id = k.org_id;
    mc := private.mandate(k.org_id);
    select x.rc_number into v_intake_rc from practice_intakes x where x.id = mc.intake_id;
    if private.norm_id(v_rc) is not null and private.norm_id(v_intake_rc) is not null and not private.same_reg(v_reg, v_intake_rc) then
      raise exception 'This CAC record is for RC %, but the firm took this business on as RC %. Choose the right company.',
        private.norm_id(v_rc), private.norm_id(v_intake_rc);
    end if;
    v_dup := private.company_taken(v_reg, v_tin, v_practice, k.org_id);
    if v_dup is not null then
      insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
      select v_practice, mc.intake_id, mc.id, 'duplicate_company', v_dup || jsonb_build_object('source', 'cac', 'business_org_id', k.org_id)
      where not exists (select 1 from practice_mandate_flags f where f.practice_id = v_practice and f.kind = 'duplicate_company' and f.resolved_at is null
                        and f.detail->>'business_org_id' = k.org_id::text);
      return jsonb_build_object('ok', false, 'reason', 'duplicate');
    end if;
  elsif private.norm_id(v_rc) is not null or v_tin is not null then
    -- A company already on Counta is not set up a second time. The person is told whose account holds it (masked), and a
    -- director recovers it (recovery_start). A firm that runs it under full mandate is also told, as before.
    mo := private.reg_holder(v_reg, v_tin, k.org_id);
    if mo.id is not null then
      if mo.managed_by is not null then
        mc := private.mandate(mo.id);
        insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
        select mo.managed_by, mc.intake_id, mc.id, 'duplicate_company',
          jsonb_build_object('source', 'owner', 'matched_on', case when private.same_reg(mo.rc_number, v_reg) then 'rc_number' else 'tax_id' end,
            'business_org_id', mo.id, 'user_id', v_uid, 'email', v_email, 'name', v_name, 'org_id', k.org_id)
        where not exists (select 1 from practice_mandate_flags f where f.kind = 'duplicate_company' and f.resolved_at is null
                          and f.detail->>'source' = 'owner' and f.detail->>'business_org_id' = mo.id::text and f.detail->>'user_id' = v_uid::text);
      end if;
      return jsonb_build_object('ok', false, 'reason', 'exists', 'business', mo.name, 'masked_email', private.holder_masked(mo.id),
        'yours', private.acts_as_owner(mo.id, v_uid));
    end if;
  end if;

  v_org := k.org_id;
  if v_org is null then
    v_org := public.create_org(v_name, coalesce(nullif(trim(p->>'email'), ''), v_email), nullif(trim(p->>'phone'), ''), v_display,
      jsonb_build_array(jsonb_build_object('name', v_branch, 'address', v_addr)), v_vat, false);
    v_new := true;
  elsif not private.is_owner(v_org) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  else
    update orgs set name = v_name, vat_registered = v_vat, phone = coalesce(nullif(trim(p->>'phone'), ''), phone) where id = v_org;
  end if;
  update orgs set
    rc_number = coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''), rc_number),
    tin = coalesce(v_tin, tin),
    legal_form = coalesce(v_form, legal_form),
    address = coalesce(v_addr, address),
    registered_office = coalesce(nullif(trim(c->>'address'), ''), nullif(trim(c->>'head_office_address'), ''), registered_office),
    incorporation_date = coalesce(nullif(left(c->>'registration_date', 10), '')::date, incorporation_date),
    commenced_on = coalesce(nullif(left(c->>'business_commencement_date', 10), '')::date, commenced_on),
    principal_activity = coalesce(nullif(left(trim(c->>'objectives'), 500), ''), v_cat.label, principal_activity),
    directors = coalesce(v_dir, directors),
    industry = coalesce(v_cat.industry, industry),
    offering = coalesce(nullif(k.answers->>'offering', ''), v_cat.kind, offering),
    category_id = coalesce(v_cat.id, category_id),
    identity_status = case when v_new then 'pending' else identity_status end,
    website = coalesce(website, nullif(left(k.web->>'website', 200), '')),
    -- The shares CAC has on record, when the statements have none yet.
    share_info = case when share_info = '{}'::jsonb and v_shares > 0 then jsonb_build_object('issued_shares', v_shares) else share_info end,
    company_secretary = coalesce(nullif(company_secretary, ''), (select coalesce(private.person(s), nullif(trim(s->>'corporation_name'), ''))
      from jsonb_array_elements(coalesce(k.cac->'secretary', '[]'::jsonb)) s limit 1))
  where id = v_org;
  -- The head office's state (and local government area, when CAC names one the NRS list knows) from the CAC record or the address.
  v_state := coalesce(private.ng_state(nullif(c->>'state', '')), private.ng_state(k.manual->>'state'), private.ng_state_of_address(v_addr));
  if v_state is not null then
    v_lga := private.ng_lga(v_state, nullif(trim(regexp_replace(coalesce(nullif(c->>'lga', ''), c->>'city', ''), '\s*L\.?G\.?A\.?$', '', 'i')), ''));
    update locations set state = v_state, lga = coalesce(v_lga, lga) where org_id = v_org and is_main and state is null;
  end if;
  if v_new and coalesce(p->'filing_only' = 'true'::jsonb, false) then update orgs set filing_only = true where id = v_org; end if;
  update kyc_profiles set status = 'submitted', submitted_at = now(), org_id = v_org, updated_at = now() where id = k.id;
  insert into guide_progress (user_id, org_id) values (v_uid, v_org) on conflict (user_id) do update set org_id = excluded.org_id, last_seen_at = now();
  return jsonb_build_object('org_id', v_org, 'name', v_name, 'compliance', public.compliance_score(v_org));
end $function$;

-- public.practice_create_business: a firm can set a business up under full mandate for filing only.
CREATE OR REPLACE FUNCTION public.practice_create_business(p_intake uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.practice_intakes; m public.practice_members; pr public.practices; g jsonb; v_missing text;
  v_email text; v_phone text; v_vat boolean; v_bank text; v_alert text; v_ep uuid; v_years int; v_dup jsonb; v_org uuid; v_client uuid;
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to set up.'; end if;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if i.status <> 'draft' or i.client_id is not null then raise exception 'This intake has a client already. Start a new intake for another business.'; end if;
  g := private.mandate_gate(i.id);
  select string_agg(k, ', ' order by n) into v_missing
  from unnest(array['partner_verified', 'practice_can_full', 'risk_rated', 'rc_or_tax_id', 'conflicts_cleared', 'letter_completed',
    'authority_declared']) with ordinality u(k, n)
  where not coalesce((g->>k)::boolean, false);
  if v_missing is not null then raise exception 'Full mandate needs: %', v_missing; end if;

  v_email := lower(trim(coalesce(p->>'email', '')));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'Enter the email address the business will use (the firm chooses it).';
  end if;
  v_phone := nullif(trim(coalesce(p->>'phone', '')), '');
  if length(v_phone) > 40 then raise exception 'That phone number is too long.'; end if;
  if jsonb_typeof(p->'vat_registered') not in ('boolean', 'null') and coalesce(p->>'vat_registered', '') not in ('true', 'false') then
    raise exception 'Say yes or no to whether the business is registered for VAT.';
  end if;
  v_vat := coalesce((p->>'vat_registered')::boolean, true);
  v_bank := nullif(trim(coalesce(p->>'bank_details', '')), '');
  if length(v_bank) > 500 then raise exception 'Keep the bank details under 500 characters.'; end if;
  v_alert := nullif(lower(trim(coalesce(p->>'alert_email', ''))), '');
  if v_alert is not null and (v_alert !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or private.firm_email(i.practice_id, v_alert) is null) then
    raise exception 'Use an address of the firm.';
  end if;
  v_ep := coalesce(private.uuid_of(nullif(p->>'engagement_partner_id', '')), m.id);
  if (nullif(p->>'engagement_partner_id', '') is not null and private.uuid_of(p->>'engagement_partner_id') is null)
     or not exists (select 1 from practice_members where id = v_ep and practice_id = i.practice_id and role in ('partner', 'manager') and status = 'active') then
    raise exception 'The engagement partner must be one of the firm''s active partners or managers.';
  end if;

  -- The same company already on Counta: owned by someone who signed in, or run by another practice. (Its numbers stay
  -- this transaction's until it ends, so another practice setting it up at the same moment sees this one.)
  v_dup := private.company_taken(i.rc_number, i.tax_id, i.practice_id, null);
  if v_dup is not null then
    insert into practice_mandate_flags (practice_id, intake_id, kind, detail)
    select i.practice_id, i.id, 'duplicate_company', v_dup || jsonb_build_object('by', m.id)
    where not exists (select 1 from practice_mandate_flags f where f.intake_id = i.id and f.kind = 'duplicate_company' and f.resolved_at is null);
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  select * into pr from practices where id = i.practice_id;
  v_org := private.create_org_core(i.legal_name, v_email, v_phone, jsonb_build_array(jsonb_build_object('name', 'Head office', 'address', i.address)),
    v_vat, false);
  update orgs set managed_by = i.practice_id, identity_status = 'pending', invoice_note = v_bank, rc_number = nullif(trim(i.rc_number), ''),
    tin = nullif(trim(i.tax_id), ''), address = i.address, filing_only = coalesce(p->'filing_only' = 'true'::jsonb, false)
  where id = v_org;
  v_years := (private.mandate_letter(i)).retention_years;
  -- (The intake is engaged on the link by practice_clients_intake.)
  insert into practice_clients (practice_id, org_id, status, initiated_by, business_name, billing, mode, intake_id, engagement_partner_id,
    alert_email, retention_years, started_at, created_by)
  values (i.practice_id, v_org, 'active', 'practice', left(i.legal_name, 120), 'practice', 'full', i.id, v_ep, v_alert, v_years, now(), auth.uid())
  returning id into v_client;
  perform private.practice_sync_seats(v_client);
  perform private.activity_event(v_org, 'mandate_started', 'Full mandate started by ' || pr.name,
    jsonb_build_object('practice_id', i.practice_id, 'client_id', v_client, 'intake_id', i.id));
  return jsonb_build_object('ok', true, 'org_id', v_org, 'client_id', v_client);
end $function$;

-- public.admin_save_plan: Annual filing stays hidden and is never the default.
CREATE OR REPLACE FUNCTION public.admin_save_plan(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
  if v_id is not null and pl.kind = 'filing' and (coalesce((p->>'public')::boolean, true) or v_default) then
    raise exception 'Annual filing is not offered as a plan and cannot be the default: leave Public and Default off.';
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
end $function$;

-- private.plan_json: whether a plan is the filing package.
CREATE OR REPLACE FUNCTION private.plan_json(p_plan uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'kind', p.kind, 'description', p.description, 'price_month', p.price_month,
    'price_year', coalesce(p.price_year, p.price_month * 12), 'trial_days', p.trial_days, 'is_default', p.is_default, 'public', p.public, 'active', p.active,
    'entitlements', (select coalesce(jsonb_agg(jsonb_build_object('module', md.key, 'name', md.name, 'kind', md.kind, 'unit', md.unit,
        'included', coalesce(pe.included, true), 'quota', case when md.kind = 'quota' then pe.quota end, 'enforce', coalesce(pe.enforce, 'warn')) order by md.sort), '[]'::jsonb)
      from plan_modules md left join plan_entitlements pe on pe.plan_id = p.id and pe.module_key = md.key where md.active))
  from plans p where p.id = p_plan
$function$;

-- public.admin_plans: the new area switches.
CREATE OR REPLACE FUNCTION public.admin_plans()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'modules', (select coalesce(jsonb_agg(to_jsonb(md) - 'updated_by' order by md.sort, md.key), '[]'::jsonb) from plan_modules md),
    'plans', (select coalesce(jsonb_agg(private.plan_json(p.id) || jsonb_build_object('target_margin', p.target_margin, 'sort', p.sort, 'updated_at', p.updated_at,
        'businesses', (select count(*) from orgs o where not o.is_sample and private.org_plan_id(o.id) = p.id),
        'mrr', (select coalesce(sum(case when s.billing = 'year' then private.plan_price(p, 'year') / 12 else p.price_month end), 0)
                from subscriptions s where s.plan_id = p.id and s.status in ('active', 'past_due') and not s.comp)) order by p.sort, p.price_month), '[]'::jsonb)
      from plans p),
    'features', to_jsonb(array['payments', 'bulk_payments', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'bank_feeds', 'supplier_portal',
      'selling', 'purchases', 'inventory', 'vat_wht']),
    'meters', to_jsonb(array['sales', 'ai_reads', 'assistant', 'call_minutes', 'whatsapp', 'emails', 'tin_checks', 'supplier_invoices', 'payouts', 'users', 'locations', 'bank_feeds']));
end $function$;

-- public.practice_billing: which clients are filing-only, and which the firm runs.
CREATE OR REPLACE FUNCTION public.practice_billing(p_practice uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  perform private.practice_require(p_practice, true);
  return jsonb_build_object(
    'clients', (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'business_name', o.name, 'billing', c.billing,
        'filing_only', o.filing_only, 'managed', coalesce(o.managed_by = p_practice, false),
        'plan', (select jsonb_build_object('id', pl.id, 'name', pl.name) from plans pl where pl.id = private.org_plan_id(c.org_id)),
        'subscription', (select jsonb_build_object('status', s.status, 'billing', s.billing, 'period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
            'paid_by_us', s.paid_by = p_practice, 'paid_by_other', s.paid_by is not null and s.paid_by <> p_practice) from subscriptions s where s.org_id = c.org_id)) order by o.name), '[]'::jsonb)
      from practice_clients c join orgs o on o.id = c.org_id where c.practice_id = p_practice and c.status = 'active'),
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'last4', k.last4, 'brand', k.brand, 'expiry', k.expiry, 'created_at', k.created_at) order by k.created_at desc), '[]'::jsonb)
      from subscription_cards k where k.practice_id = p_practice and k.active),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('id', ch.id, 'tx_ref', ch.tx_ref, 'business_name', o.name, 'plan', pl.name, 'billing', ch.billing, 'amount', ch.amount,
        'kind', ch.kind, 'status', ch.status, 'error', ch.error, 'paid_at', ch.paid_at, 'created_at', ch.created_at) order by ch.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where practice_id = p_practice order by created_at desc limit 60) ch join orgs o on o.id = ch.org_id join plans pl on pl.id = ch.plan_id),
    'plans', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.name, 'price_month', pl.price_month, 'price_year', pl.price_year,
        'description', pl.description) order by pl.sort, pl.price_month), '[]'::jsonb)
      from plans pl where pl.active and pl.public and pl.price_month > 0));
end $function$;

-- public.cit_years: a filing-only business's years show no figures until each is paid for.
CREATE OR REPLACE FUNCTION public.cit_years(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_now int := private.cit_year_of(p_org, private.local_day(p_org, now())); ch jsonb;
begin
  m := private.cit_can_see(p_org);
  ch := private.cit_chain(p_org, v_now);
  return jsonb_build_object('years', (select coalesce(jsonb_agg(jsonb_build_object(
      'year', (c->>'year')::int, 'yoa', (c->>'yoa')::int, 'from', c->>'from', 'to', c->>'to', 'regime', c->>'regime', 'rulebook', c->'rulebook',
      'source', c->>'source', 'has_data', coalesce((c->>'has_data')::boolean, false) and not private.filing_unpaid(p_org, (c->>'year')::int), 'locked', private.filing_unpaid(p_org, (c->>'year')::int), 'ended', (c->>'ended')::boolean, 'class', c->>'class',
      'status', coalesce(cy.status, 'draft'), 'flux_status', cy.flux_status, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'total_tax', case when not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'total_tax')::numeric end, 'payable', case when not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'payable')::numeric end,
      'profit_before_tax', case when not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'profit_before_tax')::numeric end,
      'due', c->>'due', 'blocks', case when private.filing_unpaid(p_org, (c->>'year')::int) then 0 else (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'block') end,
      'warnings', (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'warn'))
      order by (c->>'year')::int desc), '[]'::jsonb)
    from jsonb_array_elements(ch) c left join cit_years cy on cy.org_id = p_org and cy.accounting_year = (c->>'year')::int),
    'first_year', private.cit_first_year(p_org), 'current_year', v_now, 'books_start', (select books_start from orgs where id = p_org),
    'profile', (select jsonb_build_object('legal_form', legal_form, 'industry', industry, 'professional_services', professional_services, 'commenced_on', commenced_on,
       'incorporation_date', incorporation_date, 'tin', tin, 'rc_number', rc_number, 'cit_profile', cit_profile, 'fiscal_year_start', fiscal_year_start) from orgs where id = p_org));
end $function$;

-- public.pit_years: a filing-only business's years show no figures until each is paid for.
CREATE OR REPLACE FUNCTION public.pit_years(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; v_now int := private.cit_year_of(p_org, private.local_day(p_org, now())); v_kind text; ch jsonb; v_all boolean;
begin
  acc := private.pit_access(p_org);
  v_all := (acc->>'all')::boolean;
  v_kind := private.income_tax_kind(p_org, v_now);
  if v_kind not in ('sole', 'partnership') or v_now < 2025 then
    return jsonb_build_object('kind', v_kind, 'years', '[]'::jsonb, 'current_year', v_now, 'first_year', private.pit_first_year(p_org));
  end if;
  ch := private.pit_chain(p_org, v_now);
  return jsonb_build_object('kind', v_kind, 'current_year', v_now, 'first_year', private.pit_first_year(p_org),
    'years', (select coalesce(jsonb_agg(jsonb_build_object('year', (c->>'year')::int, 'yoa', (c->>'yoa')::int, 'from', c->>'from', 'to', c->>'to',
        'regime', c->>'regime', 'kind', c->>'kind', 'has_data', coalesce((c->>'has_data')::boolean, false) and not private.filing_unpaid(p_org, (c->>'year')::int), 'locked', private.filing_unpaid(p_org, (c->>'year')::int), 'ended', (c->>'ended')::boolean,
        'state', private.pit_state(p_org, (c->>'year')::int), 'due', c->>'due', 'people', (c->'figures'->>'people')::int,
        'tax', case when v_all and not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'tax')::numeric end, 'payable', case when v_all and not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'payable')::numeric end,
        'assessable', case when not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'assessable')::numeric end,
        'blocks', case when private.filing_unpaid(p_org, (c->>'year')::int) then 0 else (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'block') end)
      order by (c->>'year')::int desc), '[]'::jsonb) from jsonb_array_elements(ch) c where c ? 'people' or not coalesce((c->>'has_data')::boolean, true)));
end $function$;

-- ---------------------------------------------------------------------------
-- 6. The bookkeeper, approvals, VAT and Subscription
-- ---------------------------------------------------------------------------
-- The bookkeeper's queue leaves out filing-only businesses that have paid for nothing yet.
create or replace function public.svc_orgs_with_lines() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(x.org_id), '[]'::jsonb)
  from (select distinct org_id from bank_lines where status = 'unmatched' and ai_attempts < 3) x
  where not private.filing_hold(x.org_id)
$$;

-- A filing-only business approves a year's return once the year is paid for, with any difference for scans settled.
create or replace function private.filing_approve_check() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare f public.filing_orders;
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and coalesce((select filing_only from orgs where id = new.org_id), false) then
    select * into f from filing_orders where org_id = new.org_id and year = new.accounting_year;
    if f.id is null or f.status <> 'paid' then
      raise exception 'Pay the filing fee for % on the Filing page before approving its return.', new.accounting_year;
    end if;
    if f.extra_due > 0 then
      raise exception 'The scanned statements for % came to more transactions than estimated. Pay the difference of ₦% on the Filing page, then approve.',
        new.accounting_year, to_char(f.extra_due, 'FM999,999,999,990.00');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists cit_years_filing on public.cit_years;
create trigger cit_years_filing before update of status on public.cit_years for each row execute function private.filing_approve_check();
drop trigger if exists pit_years_filing on public.pit_years;
create trigger pit_years_filing before update of status on public.pit_years for each row execute function private.filing_approve_check();

-- Counta turns VAT on for a filing-only business too (the law requires it). Its people are told that the monthly VAT
-- returns need a plan.
CREATE OR REPLACE FUNCTION private.vat_threshold_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o record; st jsonb; v_reason text; c public.vat_changes; w jsonb;
begin
  for o in select id, filing_only from orgs where not vat_registered and not is_sample and read_only_at is null loop
    begin
      st := private.vat_small_status(o.id);
      v_reason := private.vat_must_reason(st);
      continue when v_reason is null;
      update orgs set vat_registered = true, vat_opt_in = false where id = o.id and not vat_registered;
      continue when not found;
      insert into vat_changes (org_id, charge, by_member, by_name, reason, status) values (o.id, true, null, 'Counta', v_reason, st) returning * into c;
      w := private.vat_on_words(v_reason, st, private.local_day(o.id, now()));
      if o.filing_only then
        w := jsonb_set(w, '{lines}', (w->'lines') || to_jsonb('Filing-only covers the annual income tax return, not the monthly VAT returns. Choose a plan in Settings, Subscription to file them with Counta.'::text));
      end if;
      perform private.alert_send(o.id, 'vat_on', c.id::text, array['push', 'email', 'whatsapp'],
        jsonb_build_object('title', w->>'title', 'body', w->'lines'->>0, 'lines', w->'lines',
          'url', case when o.filing_only then '/settings/subscription' else '/tax/vat' end, 'perm', 'keep_books',
          'button', case when o.filing_only then 'Choose a plan' else 'Open VAT' end));
    exception when others then
      raise warning 'vat_threshold_tick: % could not be switched: %', o.id, sqlerrm;
    end;
  end loop;
end $function$;

-- Subscription: Annual filing is shown as the business's package, never offered as a plan to choose.
CREATE OR REPLACE FUNCTION public.subscription_state(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_plan uuid; k text; v_ents jsonb := '[]'::jsonb; w record; v_org public.orgs;
begin
  m := private.require(p_org, 'manage_settings');
  select * into v_org from orgs where id = p_org;
  v_plan := private.org_plan_id(p_org);
  for k in select key from plan_modules where active order by sort loop
    v_ents := v_ents || jsonb_build_array(private.entitlement(p_org, k, true));
  end loop;
  select wl.id, private.wallet_balance(wl.id) bal into w from wallets wl join orgs o on o.id = wl.org_id
  where wl.org_id = p_org and wl.rail = o.payment_rail and wl.status = 'active' limit 1;
  return jsonb_build_object(
    'plan', private.plan_json(v_plan), 'subscription', private.sub_json(p_org), 'entitlements', v_ents,
    'plans', (select coalesce(jsonb_agg(private.plan_json(p.id) order by p.sort, p.price_month), '[]'::jsonb) from plans p
              where p.active and p.kind = 'subscription' and (p.public or p.id = v_plan)),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'plan', pl.name, 'billing', c.billing, 'amount', c.amount,
        'method', c.method, 'kind', c.kind, 'status', c.status, 'error', c.error, 'paid_at', c.paid_at, 'tx_ref', c.tx_ref,
        'year', (select f.year from filing_orders f where f.id = c.filing_order_id)) order by c.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where org_id = p_org order by created_at desc limit 24) c join plans pl on pl.id = c.plan_id),
    'wallet', case when w.id is not null then jsonb_build_object('available', w.bal) end,
    'can_change', (m.role in ('owner', 'admin') or m.acts_as_owner), 'is_sample', v_org.is_sample,
    'filing_only', v_org.filing_only,
    -- Whether the owner may switch to filing-only now: no plan being paid for.
    'can_file_only', not v_org.filing_only and not v_org.is_sample and v_org.managed_by is null and not exists (
      select 1 from subscriptions s join plans pl on pl.id = s.plan_id where s.org_id = p_org
        and (s.paid_by is not null or s.comp or (private.plan_price(pl, coalesce(s.billing, 'month')) > 0 and s.status in ('active', 'trialing', 'past_due')))));
end $function$;

-- ---------------------------------------------------------------------------
-- 7. The admin portal: prices and what was paid
-- ---------------------------------------------------------------------------
create or replace function public.admin_filing() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'prices', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'up_to', up_to, 'price', price, 'updated_at', updated_at)
        order by kind, coalesce(up_to, 2147483647)), '[]'::jsonb) from filing_prices),
    'businesses', (select count(*) from orgs where filing_only and not is_sample),
    'orders', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
      select jsonb_build_object('id', f.id, 'org_id', f.org_id, 'business', o.name, 'year', f.year, 'kind', f.kind, 'status', f.status, 'counted', f.counted,
        'band_up_to', f.band_up_to, 'amount', f.amount, 'extra_due', f.extra_due, 'extra_paid', f.extra_paid, 'payer', f.payer,
        'practice', (select name from practices where id = f.practice_id), 'paid_at', f.paid_at, 'at', coalesce(f.paid_at, f.created_at),
        'filed', coalesce((select c.status = 'filed' from cit_years c where c.org_id = f.org_id and c.accounting_year = f.year and f.kind = 'cit'),
                          (select p.status = 'filed_outside' or exists (select 1 from pit_person_years pp where pp.org_id = f.org_id
                             and pp.accounting_year = f.year and pp.included and pp.filed_at is not null)
                           from pit_years p where p.org_id = f.org_id and p.accounting_year = f.year and f.kind = 'pit'), false)) x
      from filing_orders f join orgs o on o.id = f.org_id where not o.is_sample order by coalesce(f.paid_at, f.created_at) desc limit 300) y),
    'collected_month', (select coalesce(sum(amount), 0) from subscription_charges where kind = 'filing' and status = 'successful'
      and paid_at >= date_trunc('month', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos'),
    'collected_total', (select coalesce(sum(amount), 0) from subscription_charges where kind = 'filing' and status = 'successful'));
end $$;

-- The bands for one return, replaced as a whole: counts up to each band's top in rising order, then one band with no top.
create or replace function public.admin_filing_prices_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); v_kind text := p->>'kind'; x jsonb; v_prev int := 0; v_top int; v_price numeric; v_n int := 0; v_open int := 0;
begin
  if v_kind not in ('cit', 'pit') then raise exception 'Choose companies income tax or personal income tax.'; end if;
  if jsonb_typeof(p->'bands') <> 'array' or jsonb_array_length(p->'bands') not between 1 and 10 then raise exception 'Set 1 to 10 price bands.'; end if;
  for x in select value from jsonb_array_elements(p->'bands') loop
    v_n := v_n + 1;
    if v_open > 0 then raise exception 'The band with no upper limit comes last.'; end if;
    v_top := case when nullif(x->>'up_to', '') is null then null when x->>'up_to' ~ '^\d{1,8}$' then (x->>'up_to')::int else -1 end;
    if v_top = -1 then raise exception 'Band %: the number of transactions must be a whole number.', v_n; end if;
    v_price := case when x->>'price' ~ '^\d{1,9}(\.\d{1,2})?$' then (x->>'price')::numeric end;
    if v_price is null or v_price <= 0 then raise exception 'Band %: give a price above zero.', v_n; end if;
    if v_top is null then v_open := 1;
    elsif v_top <= v_prev then raise exception 'Band %: each band must go higher than the one before.', v_n;
    else v_prev := v_top; end if;
  end loop;
  if v_open = 0 then raise exception 'Add a last band with no upper limit, for everything above.'; end if;
  delete from filing_prices where kind = v_kind;
  insert into filing_prices (kind, up_to, price, updated_by)
  select v_kind, case when nullif(value->>'up_to', '') is null then null else (value->>'up_to')::int end, (value->>'price')::numeric, v_uid
  from jsonb_array_elements(p->'bands');
  perform private.audit('save_filing_prices', v_kind, p);
  return public.admin_filing();
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
select private.activity_attach('public.filing_orders');
select private.activity_attach('public.filing_scans');

revoke all on function private.filing_plan_id(), private.subscription_ends_filing(), private.filing_kind(uuid, integer), private.filing_hold(uuid),
  private.filing_day_open(uuid, date), private.filing_unpaid(uuid, integer), private.filing_unpaid_json(uuid, integer), private.filing_count(uuid, integer),
  private.filing_band(text, integer), private.filing_quote(uuid, integer), private.filing_years(uuid), private.filing_practice(uuid),
  private.filing_due(uuid, integer), private.filing_charge(uuid, jsonb, uuid, uuid, uuid), private.filing_paid(public.subscription_charges),
  private.filing_approve_check() from public, anon, authenticated;

revoke all on function public.filing_state(uuid), public.filing_open(uuid, integer), public.filing_scan_hold(uuid, jsonb), public.filing_scan_remove(uuid, uuid),
  public.filing_scan_done(uuid, uuid, uuid), public.filing_start(uuid), public.filing_pay_start(uuid, integer, jsonb),
  public.practice_filing_pay_start(uuid, integer, jsonb), public.practice_filing_start(uuid), public.admin_filing(),
  public.admin_filing_prices_save(jsonb) from public, anon;
grant execute on function public.filing_state(uuid), public.filing_open(uuid, integer), public.filing_scan_hold(uuid, jsonb), public.filing_scan_remove(uuid, uuid),
  public.filing_scan_done(uuid, uuid, uuid), public.filing_start(uuid), public.filing_pay_start(uuid, integer, jsonb),
  public.practice_filing_pay_start(uuid, integer, jsonb), public.practice_filing_start(uuid), public.admin_filing(),
  public.admin_filing_prices_save(jsonb) to authenticated;
revoke all on function public.svc_subscription_charge(uuid), public.svc_subscription_expire(text), public.svc_orgs_with_lines() from public, anon, authenticated;
grant execute on function public.svc_subscription_charge(uuid), public.svc_subscription_expire(text), public.svc_orgs_with_lines() to service_role;
