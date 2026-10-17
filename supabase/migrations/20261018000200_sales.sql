-- Counta · Sales: till, receipts, invoices, quotes, online orders, credit notes, customer credit, price lists,
-- cashier shifts, deliveries, vans and the online shop.
--
-- Every issued sale posts one journal:
--   Dr 1101 trade receivables (gross, party = the customer; till sales use the walk-in customer)
--   Cr 41xx revenue (net of VAT, after discounts; delivery to its own income account)   Cr 2201 output VAT (standard-rated lines)
--   Dr 5400 / Cr 1203 at weighted average cost for the stock that left (one stock movement per line).
-- Money received posts separately as a collection: Dr till cash / bank / wallet (+ Dr 6701 fees) / Cr 1101, and
-- anything beyond what is owed Cr 2107 customer advances. Cash confirms itself. Transfers, card, cheques and other
-- channels stay pending until a manager or accountant confirms them; the payment provider's webhook confirms its own.
-- Until then the customer still owes the money.

-- ---------------------------------------------------------------------------
-- 1. Settings, locations, movement links
-- ---------------------------------------------------------------------------
alter table public.locations add column if not exists kind text not null default 'store';
alter table public.locations drop constraint if exists locations_kind_check;
alter table public.locations add constraint locations_kind_check check (kind in ('store', 'warehouse', 'van'));
alter table public.locations add column if not exists cash_account_id uuid references public.bank_accounts(id) on delete set null;
create index if not exists locations_cash_account_fk on public.locations(cash_account_id);

alter table public.orgs add column if not exists max_cashier_discount_pct numeric(5,2) not null default 0;
alter table public.orgs drop constraint if exists orgs_max_cashier_discount_check;
alter table public.orgs add constraint orgs_max_cashier_discount_check check (max_cashier_discount_pct between 0 and 100);
alter table public.orgs add column if not exists receipt_footer text;
alter table public.orgs add column if not exists shop_slug text;
alter table public.orgs add column if not exists shop_enabled boolean not null default false;
alter table public.orgs add column if not exists shop_title text;
alter table public.orgs add column if not exists shop_note text;
alter table public.orgs add column if not exists shop_whatsapp text;
alter table public.orgs add column if not exists shop_location_id uuid references public.locations(id) on delete set null;
alter table public.orgs add column if not exists shop_delivery_fee numeric(14,2) not null default 0;
alter table public.orgs add column if not exists shop_pickup boolean not null default true;
alter table public.orgs add column if not exists shop_delivery boolean not null default true;
alter table public.orgs add column if not exists shop_show_stock boolean not null default false;
alter table public.orgs add column if not exists shop_categories text[];
alter table public.orgs drop constraint if exists orgs_shop_slug_check;
alter table public.orgs add constraint orgs_shop_slug_check check (shop_slug is null or shop_slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$');
create unique index if not exists orgs_shop_slug on public.orgs(shop_slug) where shop_slug is not null;
create index if not exists orgs_shop_location_fk on public.orgs(shop_location_id);

alter table public.movements drop constraint if exists movements_type_check;
alter table public.movements add constraint movements_type_check check (type in (
  'opening', 'receipt', 'sale', 'voice_sale', 'transfer_out', 'transfer_in', 'adjustment', 'write_off', 'quarantine',
  'issue', 'issue_return', 'production_in', 'sale_return'));
alter table public.movements add column if not exists sale_id uuid;
create index if not exists movements_sale on public.movements(sale_id) where sale_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Price lists
-- ---------------------------------------------------------------------------
create table if not exists public.price_lists (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  kind text not null default 'wholesale' check (kind in ('wholesale', 'distributor', 'custom', 'staff')),
  rule text not null default 'fixed' check (rule in ('fixed', 'discount_on_retail', 'markup_on_cost')),
  pct numeric(6,2) not null default 0 check (pct >= 0 and pct < 1000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, name)
);
create table if not exists public.price_list_items (
  price_list_id uuid not null references public.price_lists(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  min_qty numeric(14,3) not null default 1 check (min_qty > 0),
  price numeric(14,2) not null check (price > 0),
  primary key (price_list_id, item_id, min_qty)
);
create index if not exists price_list_items_item_fk on public.price_list_items(item_id);
create index if not exists price_list_items_org on public.price_list_items(org_id);
alter table public.customers drop constraint if exists customers_price_list_fk;
alter table public.customers add constraint customers_price_list_fk foreign key (price_list_id) references public.price_lists(id) on delete set null;
create index if not exists customers_price_list_fk_idx on public.customers(price_list_id);
alter table public.price_lists enable row level security;
alter table public.price_list_items enable row level security;
drop policy if exists price_lists_read on public.price_lists;
create policy price_lists_read on public.price_lists for select to authenticated using ((select private.is_member(org_id)));
drop policy if exists price_list_items_read on public.price_list_items;
create policy price_list_items_read on public.price_list_items for select to authenticated using ((select private.is_member(org_id)));

-- Price of one selling unit for this list and quantity. Prices carry the business's VAT setting (inclusive by default).
create or replace function private.list_price(p_org uuid, p_item uuid, p_list uuid, p_qty numeric) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare it public.items; pl public.price_lists; v numeric; v_wac numeric;
begin
  select * into it from items where id = p_item and org_id = p_org;
  if not found then return null; end if;
  if p_list is null then return it.price; end if;
  select * into pl from price_lists where id = p_list and org_id = p_org and active;
  if not found then return it.price; end if;
  select price into v from price_list_items where price_list_id = pl.id and item_id = p_item and min_qty <= greatest(coalesce(p_qty, 1), 0)
    order by min_qty desc limit 1;
  if v is not null then return v; end if;
  if pl.rule = 'discount_on_retail' then return round(it.price * (1 - pl.pct / 100.0), 2); end if;
  if pl.rule = 'markup_on_cost' then
    select wac into v_wac from item_costs where item_id = p_item;
    if coalesce(v_wac, 0) > 0 then return round(v_wac * (1 + pl.pct / 100.0), 2); end if;
  end if;
  return it.price;
end $$;

create or replace function public.save_price_list(p_org uuid, p_list jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_id uuid := nullif(p_list->>'id', '')::uuid; x jsonb; v_kind text := coalesce(nullif(p_list->>'kind', ''), 'wholesale');
  v_rule text := coalesce(nullif(p_list->>'rule', ''), 'fixed');
begin
  m := private.require(p_org, 'edit_prices');
  if coalesce(trim(p_list->>'name'), '') = '' then raise exception 'Name the price list, for example Wholesale.'; end if;
  if exists (select 1 from price_lists where org_id = p_org and lower(name) = lower(trim(p_list->>'name')) and id is distinct from v_id) then
    raise exception 'There is already a price list called %.', trim(p_list->>'name');
  end if;
  if v_id is null then
    insert into price_lists (org_id, name, kind, rule, pct) values (p_org, trim(p_list->>'name'), v_kind, v_rule, coalesce(private.num(p_list->>'pct'), 0))
    returning id into v_id;
  else
    update price_lists set name = trim(p_list->>'name'), kind = v_kind, rule = v_rule,
      pct = coalesce(private.num(p_list->>'pct'), pct), active = coalesce((p_list->>'active')::boolean, active)
    where id = v_id and org_id = p_org;
    if not found then raise exception 'Price list not found.'; end if;
  end if;
  if p_list ? 'items' then
    delete from price_list_items where price_list_id = v_id;
    for x in select * from jsonb_array_elements(p_list->'items') loop
      if coalesce(private.num(x->>'price'), 0) > 0 then
        insert into price_list_items (price_list_id, org_id, item_id, min_qty, price)
        select v_id, p_org, i.id, greatest(coalesce(private.num(x->>'min_qty'), 1), 0.001), round(private.num(x->>'price'), 2)
        from items i where i.id = nullif(x->>'item_id', '')::uuid and i.org_id = p_org
        on conflict (price_list_id, item_id, min_qty) do update set price = excluded.price;
      end if;
    end loop;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Customers
-- ---------------------------------------------------------------------------
create or replace function private.walk_in(p_org uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v uuid;
begin
  select id into v from customers where org_id = p_org and is_walk_in;
  if v is null then
    insert into customers (org_id, name, kind, is_walk_in, whatsapp_opt_in) values (p_org, 'Walk-in customer', 'individual', true, false)
    on conflict do nothing returning id into v;
    if v is null then select id into v from customers where org_id = p_org and is_walk_in; end if;
  end if;
  return v;
end $$;

-- Nigerian numbers become +234…; anything else keeps its digits with a plus.
create or replace function private.clean_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when p is null or regexp_replace(p, '[^0-9]', '', 'g') = '' then null
    when regexp_replace(p, '[^0-9]', '', 'g') ~ '^0[789][01][0-9]{8}$' then '+234' || substr(regexp_replace(p, '[^0-9]', '', 'g'), 2)
    when regexp_replace(p, '[^0-9]', '', 'g') ~ '^234[789][01][0-9]{8}$' then '+' || regexp_replace(p, '[^0-9]', '', 'g')
    when regexp_replace(p, '[^0-9]', '', 'g') ~ '^[789][01][0-9]{8}$' then '+234' || regexp_replace(p, '[^0-9]', '', 'g')
    else '+' || regexp_replace(p, '[^0-9]', '', 'g') end
$$;

create or replace function private.upsert_customer(p_org uuid, p_customer jsonb, m public.members) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid := nullif(p_customer->>'id', '')::uuid; v_phone text := private.clean_phone(p_customer->>'phone');
  v_limit numeric := private.num(p_customer->>'credit_limit'); c public.customers; v_can_credit boolean;
begin
  if coalesce(trim(p_customer->>'name'), '') = '' then raise exception 'Enter the customer''s name.'; end if;
  if length(trim(p_customer->>'name')) > 120 then raise exception 'The customer''s name is too long.'; end if;
  v_can_credit := private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books');
  if v_id is not null then
    select * into c from customers where id = v_id and org_id = p_org;
    if not found then raise exception 'Customer not found.'; end if;
    if c.is_walk_in then raise exception 'The walk-in customer cannot be edited.'; end if;
  end if;
  if v_limit is not null and v_limit < 0 then raise exception 'A credit limit cannot be negative.'; end if;
  if v_limit is not null and v_limit is distinct from coalesce(c.credit_limit, 0) and not v_can_credit then
    raise exception 'Only a manager, an accountant or the owner can set a credit limit.';
  end if;
  if (p_customer ? 'terms_days') and coalesce((p_customer->>'terms_days')::int, 0) is distinct from coalesce(c.terms_days, 0) and not v_can_credit then
    raise exception 'Only a manager, an accountant or the owner can set payment terms.';
  end if;
  if v_phone is not null and exists (select 1 from customers where org_id = p_org and phone = v_phone and not archived and id is distinct from v_id) then
    raise exception 'A customer with phone % already exists.', v_phone;
  end if;
  if nullif(p_customer->>'price_list_id', '') is not null and not exists (select 1 from price_lists where id = (p_customer->>'price_list_id')::uuid and org_id = p_org) then
    raise exception 'Price list not found.';
  end if;
  if v_id is null then
    insert into customers (org_id, name, kind, phone, email, tin, address, price_list_id, credit_limit, terms_days, whatsapp_opt_in, notes, tags, created_by)
    values (p_org, trim(p_customer->>'name'), coalesce(nullif(p_customer->>'kind', ''), 'individual'), v_phone, nullif(lower(trim(p_customer->>'email')), ''),
      nullif(trim(p_customer->>'tin'), ''), nullif(trim(p_customer->>'address'), ''), nullif(p_customer->>'price_list_id', '')::uuid,
      coalesce(v_limit, 0), least(greatest(coalesce((p_customer->>'terms_days')::int, 0), 0), 365), coalesce((p_customer->>'whatsapp_opt_in')::boolean, true),
      nullif(trim(p_customer->>'notes'), ''),
      coalesce((select array_agg(value) from jsonb_array_elements_text(case when jsonb_typeof(p_customer->'tags') = 'array' then p_customer->'tags' else '[]'::jsonb end)), '{}'),
      m.id)
    returning id into v_id;
  else
    update customers set name = trim(p_customer->>'name'), kind = coalesce(nullif(p_customer->>'kind', ''), kind),
      phone = case when p_customer ? 'phone' then v_phone else phone end,
      email = case when p_customer ? 'email' then nullif(lower(trim(p_customer->>'email')), '') else email end,
      tin = case when p_customer ? 'tin' then nullif(trim(p_customer->>'tin'), '') else tin end,
      address = case when p_customer ? 'address' then nullif(trim(p_customer->>'address'), '') else address end,
      price_list_id = case when p_customer ? 'price_list_id' then nullif(p_customer->>'price_list_id', '')::uuid else price_list_id end,
      credit_limit = coalesce(v_limit, credit_limit),
      terms_days = case when p_customer ? 'terms_days' then least(greatest(coalesce((p_customer->>'terms_days')::int, 0), 0), 365) else terms_days end,
      whatsapp_opt_in = coalesce((p_customer->>'whatsapp_opt_in')::boolean, whatsapp_opt_in),
      notes = case when p_customer ? 'notes' then nullif(trim(p_customer->>'notes'), '') else notes end,
      tags = case when jsonb_typeof(p_customer->'tags') = 'array' then coalesce((select array_agg(value) from jsonb_array_elements_text(p_customer->'tags')), '{}') else tags end,
      archived = coalesce((p_customer->>'archived')::boolean, archived)
    where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.save_customer(p_org uuid, p_customer jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'record_sales');
  return private.upsert_customer(p_org, p_customer, m);
end $$;

-- What a customer owes (positive) or holds as credit (negative), straight from the ledger.
create or replace function private.customer_balance(p_org uuid, p_customer uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(debit - credit), 0)
  from journal_lines where org_id = p_org and party_type = 'customer' and party_id = p_customer and account_code in ('1101', '1102', '2107')
$$;

create or replace function private.customer_advance(p_org uuid, p_customer uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(credit - debit), 0) from journal_lines
  where org_id = p_org and party_type = 'customer' and party_id = p_customer and account_code = '2107'
$$;

-- ---------------------------------------------------------------------------
-- 4. Sales documents
-- ---------------------------------------------------------------------------
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  doc_type text not null check (doc_type in ('receipt', 'invoice', 'quote', 'order', 'credit_note')),
  number text not null,
  status text not null default 'open' check (status in ('draft', 'pending', 'open', 'partially_paid', 'paid', 'void', 'converted', 'cancelled', 'expired', 'credited')),
  customer_id uuid not null references public.customers(id),
  customer_name text not null,
  customer_phone text,
  customer_email text,
  customer_tin text,
  customer_address text,
  location_id uuid not null references public.locations(id),
  shift_id uuid,
  price_list_id uuid references public.price_lists(id) on delete set null,
  channel text not null default 'till' check (channel in ('till', 'invoice', 'online', 'whatsapp', 'van', 'phone', 'voice', 'api', 'import')),
  issue_date date not null,
  due_date date,
  prices_include_vat boolean not null default true,
  vat_registered boolean not null default true,
  currency text not null default 'NGN',
  subtotal numeric(16,2) not null default 0,
  discount_total numeric(16,2) not null default 0,
  vat_total numeric(16,2) not null default 0,
  delivery_fee numeric(16,2) not null default 0,
  total numeric(16,2) not null default 0,
  amount_paid numeric(16,2) not null default 0,
  credited numeric(16,2) not null default 0,
  original_sale_id uuid references public.sales(id),
  converted_to uuid references public.sales(id),
  reference text,
  notes text,
  terms text,
  delivery_method text check (delivery_method in ('pickup', 'delivery', 'none')),
  delivery_address text,
  journal_id uuid references public.journals(id) on delete set null,
  public_token text not null default replace(gen_random_uuid()::text, '-', ''),
  irn text,
  irn_status text,
  client_uuid uuid unique,
  device_id text,
  offline boolean not null default false,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  issued_at timestamptz,
  voided_by uuid references public.members(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  sent_at timestamptz,
  viewed_at timestamptz,
  reminded_at timestamptz,
  unique (org_id, number)
);
create unique index if not exists sales_token on public.sales(public_token);
create index if not exists sales_org on public.sales(org_id, doc_type, issue_date desc);
create index if not exists sales_customer on public.sales(customer_id, issue_date desc);
create index if not exists sales_location_fk on public.sales(location_id);
create index if not exists sales_shift on public.sales(shift_id) where shift_id is not null;
create index if not exists sales_price_list_fk on public.sales(price_list_id);
create index if not exists sales_original_fk on public.sales(original_sale_id);
create index if not exists sales_converted_fk on public.sales(converted_to);
create index if not exists sales_journal_fk on public.sales(journal_id);
create index if not exists sales_created_by_fk on public.sales(created_by);
create index if not exists sales_voided_by_fk on public.sales(voided_by);
create index if not exists sales_open on public.sales(org_id, status) where status in ('open', 'partially_paid', 'pending');

create table if not exists public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  line_no int not null,
  kind text not null default 'goods' check (kind in ('goods', 'service', 'delivery')),
  item_id uuid references public.items(id) on delete set null,
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_label text not null default 'unit',
  unit_factor numeric(14,3) not null default 1 check (unit_factor > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  list_price numeric(14,2),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard', 'zero', 'exempt')),
  vat_rate numeric(6,4) not null default 0,
  net numeric(16,2) not null,
  vat numeric(16,2) not null,
  gross numeric(16,2) not null,
  cost numeric(16,2),
  revenue_account text,
  original_line_id uuid references public.sale_lines(id),
  returned_qty numeric(14,3) not null default 0
);
create index if not exists sale_lines_sale on public.sale_lines(sale_id);
create index if not exists sale_lines_item on public.sale_lines(item_id);
create index if not exists sale_lines_org on public.sale_lines(org_id);
create index if not exists sale_lines_original_fk on public.sale_lines(original_line_id);

-- ---------------------------------------------------------------------------
-- 5. Shifts and cash drawers
-- ---------------------------------------------------------------------------
create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  location_id uuid not null references public.locations(id),
  cash_account_id uuid not null references public.bank_accounts(id),
  register text not null default 'Till 1',
  status text not null default 'open' check (status in ('open', 'closed')),
  opened_by uuid references public.members(id) on delete set null,
  opened_at timestamptz not null default now(),
  opening_expected numeric(16,2) not null default 0,
  opening_count numeric(16,2) not null default 0,
  closed_by uuid references public.members(id) on delete set null,
  closed_at timestamptz,
  expected_cash numeric(16,2),
  counted_cash numeric(16,2),
  difference numeric(16,2),
  notes text,
  journal_id uuid references public.journals(id) on delete set null,
  unique (org_id, number)
);
create index if not exists shifts_org on public.shifts(org_id, opened_at desc);
create index if not exists shifts_location_fk on public.shifts(location_id);
create index if not exists shifts_cash_fk on public.shifts(cash_account_id);
create index if not exists shifts_opened_by_fk on public.shifts(opened_by);
create index if not exists shifts_closed_by_fk on public.shifts(closed_by);
create index if not exists shifts_journal_fk on public.shifts(journal_id);
create unique index if not exists shifts_one_open on public.shifts(cash_account_id) where status = 'open';
alter table public.sales drop constraint if exists sales_shift_fk;
alter table public.sales add constraint sales_shift_fk foreign key (shift_id) references public.shifts(id) on delete set null;

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  shift_id uuid not null references public.shifts(id) on delete cascade,
  kind text not null check (kind in ('pay_in', 'pay_out', 'drop')),
  amount numeric(16,2) not null check (amount > 0),
  reason text not null,
  account_code text,
  bank_account_id uuid references public.bank_accounts(id),
  by_member uuid references public.members(id) on delete set null,
  at timestamptz not null default now(),
  journal_id uuid references public.journals(id) on delete set null
);
create index if not exists cash_movements_shift on public.cash_movements(shift_id);
create index if not exists cash_movements_org on public.cash_movements(org_id);
create index if not exists cash_movements_bank_fk on public.cash_movements(bank_account_id);
create index if not exists cash_movements_member_fk on public.cash_movements(by_member);
create index if not exists cash_movements_journal_fk on public.cash_movements(journal_id);

-- ---------------------------------------------------------------------------
-- 6. Money: payment requests, collections, their allocation to sales, credit notes applied
-- ---------------------------------------------------------------------------
create table if not exists public.payment_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  sale_id uuid references public.sales(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  purpose text not null default 'sale' check (purpose in ('sale', 'customer_balance', 'top_up', 'order')),
  method text not null check (method in ('account', 'link', 'qr')),
  rail text not null default 'flutterwave',
  amount numeric(16,2) not null check (amount > 0),
  currency text not null default 'NGN',
  tx_ref text not null unique,
  provider_ref text,
  account_number text,
  bank_name text,
  account_name text,
  link_url text,
  qr_image text,
  expires_at timestamptz,
  status text not null default 'creating' check (status in ('creating', 'pending', 'paid', 'expired', 'cancelled', 'failed')),
  paid_amount numeric(16,2),
  fee numeric(16,2),
  paid_at timestamptz,
  payer jsonb,
  error text,
  shift_id uuid references public.shifts(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists payment_requests_org on public.payment_requests(org_id, created_at desc);
create index if not exists payment_requests_sale on public.payment_requests(sale_id);
create index if not exists payment_requests_customer_fk on public.payment_requests(customer_id);
create index if not exists payment_requests_shift_fk on public.payment_requests(shift_id);
create index if not exists payment_requests_created_by_fk on public.payment_requests(created_by);
create index if not exists payment_requests_pending on public.payment_requests(status, expires_at) where status in ('creating', 'pending');

create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  direction text not null default 'in' check (direction in ('in', 'out')),
  customer_id uuid not null references public.customers(id),
  sale_id uuid references public.sales(id) on delete set null,
  amount numeric(16,2) not null check (amount > 0),
  fee numeric(16,2) not null default 0 check (fee >= 0),
  advance_part numeric(16,2) not null default 0 check (advance_part >= 0),
  method text not null check (method in ('cash', 'transfer', 'card', 'pos', 'flutterwave', 'rail', 'cheque', 'wht_credit', 'advance', 'other')),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected', 'reversed')),
  bank_account_id uuid references public.bank_accounts(id),
  shift_id uuid references public.shifts(id) on delete set null,
  payment_request_id uuid references public.payment_requests(id) on delete set null,
  reference text,
  provider_ref text,
  received_at timestamptz not null default now(),
  confirmed_by uuid references public.members(id) on delete set null,
  confirmed_at timestamptz,
  journal_id uuid references public.journals(id) on delete set null,
  note text,
  wht_rate numeric(6,4),
  client_uuid uuid unique,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, number),
  check (fee <= amount and advance_part <= amount)
);
create index if not exists collections_org on public.collections(org_id, received_at desc);
create index if not exists collections_customer on public.collections(customer_id);
create index if not exists collections_sale on public.collections(sale_id);
create index if not exists collections_bank_fk on public.collections(bank_account_id);
create index if not exists collections_shift on public.collections(shift_id);
create index if not exists collections_request on public.collections(payment_request_id);
create index if not exists collections_confirmed_by_fk on public.collections(confirmed_by);
create index if not exists collections_created_by_fk on public.collections(created_by);
create index if not exists collections_journal_fk on public.collections(journal_id);
create index if not exists collections_pending on public.collections(org_id) where status = 'pending';
create unique index if not exists collections_provider_ref on public.collections(org_id, method, provider_ref) where provider_ref is not null;

-- posted_as: 'receivable' when the money cleared 1101; 'advance' when it was paid against an order not yet confirmed,
-- so it sits in 2107 until the order is confirmed and moves across (reclass_journal_id).
create table if not exists public.collection_allocations (
  collection_id uuid not null references public.collections(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  amount numeric(16,2) not null check (amount > 0),
  posted_as text not null default 'receivable' check (posted_as in ('receivable', 'advance')),
  reclass_journal_id uuid references public.journals(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (collection_id, sale_id)
);
create index if not exists collection_allocations_sale on public.collection_allocations(sale_id);
create index if not exists collection_allocations_org on public.collection_allocations(org_id);
create index if not exists collection_allocations_reclass_fk on public.collection_allocations(reclass_journal_id);

-- A credit note used against a sale (both sit in 1101 for the same customer, so no journal is needed),
-- or against itself when it is paid out as a refund.
create table if not exists public.credit_allocations (
  credit_note_id uuid not null references public.sales(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  amount numeric(16,2) not null check (amount > 0),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (credit_note_id, sale_id)
);
create index if not exists credit_allocations_sale on public.credit_allocations(sale_id);
create index if not exists credit_allocations_org on public.credit_allocations(org_id);
create index if not exists credit_allocations_created_by_fk on public.credit_allocations(created_by);

-- ---------------------------------------------------------------------------
-- 7. Deliveries and the shop's request log
-- ---------------------------------------------------------------------------
create table if not exists public.deliveries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  sale_id uuid not null references public.sales(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'dispatched', 'delivered', 'failed', 'cancelled')),
  driver_id uuid references public.members(id) on delete set null,
  vehicle_location_id uuid references public.locations(id) on delete set null,
  address text,
  contact_phone text,
  scheduled_for date,
  dispatched_at timestamptz,
  delivered_at timestamptz,
  received_by text,
  proof_path text,
  notes text,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, number)
);
create index if not exists deliveries_org on public.deliveries(org_id, status, created_at desc);
create index if not exists deliveries_sale on public.deliveries(sale_id);
create index if not exists deliveries_driver_fk on public.deliveries(driver_id);
create index if not exists deliveries_vehicle_fk on public.deliveries(vehicle_location_id);
create index if not exists deliveries_created_by_fk on public.deliveries(created_by);

-- Orders placed through the public shop, kept a day to slow down floods. Read only by the functions below.
create table if not exists public.shop_hits (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs(id) on delete cascade,
  phone text,
  at timestamptz not null default now()
);
create index if not exists shop_hits_org on public.shop_hits(org_id, at desc);

alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.shifts enable row level security;
alter table public.cash_movements enable row level security;
alter table public.payment_requests enable row level security;
alter table public.collections enable row level security;
alter table public.collection_allocations enable row level security;
alter table public.credit_allocations enable row level security;
alter table public.deliveries enable row level security;
alter table public.shop_hits enable row level security;
do $$
declare t text;
begin
  foreach t in array array['sales', 'shifts', 'cash_movements', 'payment_requests', 'collections', 'collection_allocations', 'credit_allocations', 'deliveries'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select private.is_member(org_id)))', t || '_read', t);
  end loop;
end $$;
-- Lines carry cost. Members without See margins read them through get_sale, which leaves cost out.
drop policy if exists sale_lines_read on public.sale_lines;
create policy sale_lines_read on public.sale_lines for select to authenticated using ((select private.can_see_costs(org_id)));

-- ---------------------------------------------------------------------------
-- 8. Building and posting a sale
-- ---------------------------------------------------------------------------
create or replace function private.doc_prefix(p_type text) returns text
language sql immutable set search_path = '' as $$
  select case p_type when 'receipt' then 'RCT' when 'invoice' then 'INV' when 'quote' then 'QTE' when 'order' then 'ORD' when 'credit_note' then 'CRN' else 'DOC' end
$$;

create or replace function private.doc_number(p_org uuid, p_type text) returns text
language sql security definer set search_path = public, private as $$
  select private.doc_prefix(p_type) || '-' || lpad(private.next_no(p_org, private.doc_prefix(p_type), 1)::text, case when p_type = 'receipt' then 6 else 4 end, '0')
$$;

create or replace function private.pay_no(p_org uuid) returns text
language sql security definer set search_path = public, private as $$
  select 'PAY-' || lpad(private.next_no(p_org, 'PAY', 1)::text, 5, '0')
$$;

-- The books are closed up to a date: documents dated on or before it cannot be issued.
create or replace function private.require_open_day(p_org uuid, p_day date) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare v_closed date := private.closed_through(p_org);
begin
  if v_closed is not null and p_day <= v_closed then
    raise exception 'The books are closed up to %. Date it after that.', to_char(v_closed, 'DD Mon YYYY');
  end if;
end $$;

-- When a document dated p_day posts: now if it is today, otherwise midday on that day in the business's time zone.
create or replace function private.posting_time(p_org uuid, p_day date, p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, private as $$
  select case when p_day = private.local_day(p_org, p_now) then p_now
              else (p_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos') end
$$;

-- Writes the lines and totals of a sale.
-- p_lines: [{item_id, qty, unit: 'selling'|'purchase', unit_price, discount}] for stock, or
--          [{description, qty, unit_label, unit_price, discount, vat_treatment, revenue_account}] for services.
-- A cart discount is spread over the lines by value. Delivery becomes its own standard-rated line.
create or replace function private.write_lines(s public.sales, p_lines jsonb, p_cart_discount numeric, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; it public.items; v_no int := 0; v_factor numeric; v_qty numeric; v_price numeric; v_list numeric; v_disc numeric;
  v_rate numeric; v_gross numeric; v_net numeric; v_vat numeric; v_base numeric;
  v_lines jsonb := '[]'::jsonb; v_sum_before numeric := 0; v_line_disc numeric := 0; v_cart numeric := round(greatest(coalesce(p_cart_discount, 0), 0), 2);
  v_share numeric; v_alloc numeric := 0; v_i int := 0; v_n int; o public.orgs; v_can_price boolean; v_rev text; v_acct text; v_treat text;
begin
  select * into o from orgs where id = s.org_id;
  v_can_price := coalesce(private.perm_of(m, 'edit_prices') or private.perm_of(m, 'approve_adjustments'), false);
  v_rev := private.acct(s.org_id, 'sales_revenue');
  delete from sale_lines where sale_id = s.id;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item.'; end if;
  if jsonb_array_length(p_lines) > 300 then raise exception 'A sale can have up to 300 lines.'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(private.num(x->>'qty'), 3);
    if coalesce(v_qty, 0) <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    if nullif(x->>'item_id', '') is not null then
      select * into it from items where id = (x->>'item_id')::uuid and org_id = s.org_id and not archived;
      if not found then raise exception 'An item on this sale no longer exists.'; end if;
      v_factor := case when x->>'unit' = 'purchase' then it.pack_size else 1 end;
      v_list := round(private.list_price(s.org_id, it.id, s.price_list_id, v_qty * v_factor) * v_factor, 2);
      v_price := coalesce(round(private.num(x->>'unit_price'), 2), v_list);
      if v_price < 0 then raise exception 'A price cannot be negative.'; end if;
      if abs(v_price - v_list) > 0.004 and not v_can_price then
        raise exception 'Only someone who can edit prices can change the price of %. Give a discount instead.', it.name;
      end if;
      v_lines := v_lines || jsonb_build_object('kind', 'goods', 'item_id', it.id, 'desc', it.name, 'qty', v_qty, 'factor', v_factor, 'price', v_price,
        'list', v_list, 'treat', it.vat_treatment, 'label', case when v_factor > 1 then it.purchase_unit else it.selling_unit end, 'acct', v_rev);
    else
      if coalesce(trim(x->>'description'), '') = '' then raise exception 'A line without an item needs a description.'; end if;
      v_price := round(private.num(x->>'unit_price'), 2);
      if v_price is null or v_price < 0 then raise exception 'Enter a price for "%".', trim(x->>'description'); end if;
      if not v_can_price and s.doc_type in ('receipt', 'order') then
        raise exception 'Only someone who can edit prices can sell "%" without an item.', trim(x->>'description');
      end if;
      v_treat := coalesce(nullif(x->>'vat_treatment', ''), 'standard');
      if v_treat not in ('standard', 'zero', 'exempt') then raise exception 'Unknown VAT treatment %.', v_treat; end if;
      v_acct := coalesce(nullif(x->>'revenue_account', ''), v_rev);
      if v_acct !~ '^4' or not private.postable(s.org_id, v_acct) then raise exception 'Choose an income account for "%".', trim(x->>'description'); end if;
      v_lines := v_lines || jsonb_build_object('kind', 'service', 'item_id', null, 'desc', left(trim(x->>'description'), 300), 'qty', v_qty, 'factor', 1,
        'price', v_price, 'list', null, 'treat', v_treat, 'label', coalesce(nullif(trim(x->>'unit_label'), ''), 'unit'), 'acct', v_acct);
    end if;
    v_disc := round(greatest(coalesce(private.num(x->>'discount'), 0), 0), 2);
    if v_disc > round(v_qty * v_price, 2) then raise exception 'The discount on a line is more than the line.'; end if;
    v_lines := jsonb_set(v_lines, array[(jsonb_array_length(v_lines) - 1)::text, 'disc'], to_jsonb(v_disc));
    v_sum_before := v_sum_before + round(v_qty * v_price, 2) - v_disc;
    v_line_disc := v_line_disc + v_disc;
  end loop;
  if v_cart > v_sum_before then raise exception 'The discount is more than the sale.'; end if;
  -- Discounts beyond the cashier allowance need someone who can edit prices or approve adjustments.
  if not v_can_price and v_line_disc + v_cart > 0
     and (v_line_disc + v_cart) * 100 > o.max_cashier_discount_pct * (v_sum_before + v_line_disc) + 0.001 then
    raise exception 'Discounts above % percent need a manager or the owner.', trim(to_char(o.max_cashier_discount_pct, 'FM990.##'));
  end if;
  v_n := jsonb_array_length(v_lines);
  for x in select * from jsonb_array_elements(v_lines) loop
    v_i := v_i + 1;
    v_base := round((x->>'qty')::numeric * (x->>'price')::numeric, 2) - (x->>'disc')::numeric;
    v_share := case when v_cart = 0 or v_sum_before = 0 then 0 when v_i = v_n then v_cart - v_alloc else round(v_cart * v_base / v_sum_before, 2) end;
    v_share := least(v_share, v_base);
    v_alloc := v_alloc + v_share;
    v_rate := case when not s.vat_registered then 0 when x->>'treat' = 'standard' then 0.075 else 0 end;
    if s.prices_include_vat then
      v_gross := v_base - v_share;
      v_net := round(v_gross / (1 + v_rate), 2);
      v_vat := v_gross - v_net;
    else
      v_net := v_base - v_share;
      v_vat := round(v_net * v_rate, 2);
      v_gross := v_net + v_vat;
    end if;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount,
      vat_treatment, vat_rate, net, vat, gross, revenue_account)
    values (s.id, s.org_id, v_no, x->>'kind', nullif(x->>'item_id', '')::uuid, x->>'desc', (x->>'qty')::numeric, x->>'label', (x->>'factor')::numeric,
      (x->>'price')::numeric, nullif(x->>'list', '')::numeric, (x->>'disc')::numeric + v_share, x->>'treat', v_rate, v_net, v_vat, v_gross, x->>'acct');
  end loop;
  -- Delivery is a service and carries VAT like any other.
  if s.delivery_fee > 0 then
    v_rate := case when s.vat_registered then 0.075 else 0 end;
    if s.prices_include_vat then v_gross := s.delivery_fee; v_net := round(v_gross / (1 + v_rate), 2); v_vat := v_gross - v_net;
    else v_net := s.delivery_fee; v_vat := round(v_net * v_rate, 2); v_gross := v_net + v_vat; end if;
    insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account)
    values (s.id, s.org_id, v_no + 1, 'delivery', 'Delivery', 1, 'trip', s.delivery_fee, 'standard', v_rate, v_net, v_vat, v_gross,
      private.acct(s.org_id, 'delivery_income'));
  end if;
  update sales set
    subtotal = (select coalesce(sum(net), 0) from sale_lines where sale_id = s.id),
    discount_total = (select coalesce(sum(discount), 0) from sale_lines where sale_id = s.id),
    vat_total = (select coalesce(sum(vat), 0) from sale_lines where sale_id = s.id),
    total = (select coalesce(sum(gross), 0) from sale_lines where sale_id = s.id)
  where id = s.id returning * into s;
  return s;
end $$;

-- Posts a sale: revenue, VAT, receivable and cost of sales, and moves the stock out, first expiry first.
-- Money already received against it as an advance (an order paid online before it was confirmed) moves from 2107 to 1101.
create or replace function private.post_sale(p_sale uuid, m public.members, p_at timestamptz) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; l record; v_jl jsonb := '[]'::jsonb; j public.journals; r public.journals; v_wac numeric; v_cost numeric;
  v_rev jsonb := '{}'::jsonb; k text; v numeric; v_vat numeric := 0; v_type text; v_adv numeric;
begin
  select * into s from sales where id = p_sale for update;
  if s.journal_id is not null then return s; end if;
  for l in select sl.* from sale_lines sl where sl.sale_id = s.id order by sl.line_no loop
    v_rev := jsonb_set(v_rev, array[l.revenue_account], to_jsonb(coalesce((v_rev->>l.revenue_account)::numeric, 0) + l.net));
    v_vat := v_vat + l.vat;
    if l.item_id is not null then
      select wac into v_wac from item_costs where item_id = l.item_id;
      v_cost := round(l.qty * l.unit_factor * coalesce(v_wac, 0), 2);
      update sale_lines set cost = v_cost where id = l.id;
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', private.acct(s.org_id, 'inventory_movement'), 'debit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id,
          'memo', l.description, 'doc_type', 'sale', 'doc_id', s.id),
        jsonb_build_object('code', private.inv_acct(l.item_id), 'credit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id,
          'memo', l.description, 'doc_type', 'sale', 'doc_id', s.id));
    end if;
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'debit', s.total, 'location_id', s.location_id,
    'party_type', 'customer', 'party_id', s.customer_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || s.customer_name));
  for k, v in select key, value::numeric from jsonb_each_text(v_rev) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', k, 'credit', v, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'credit', v_vat, 'location_id', s.location_id,
    'doc_type', 'sale', 'doc_id', s.id, 'memo', 'Output VAT ' || s.number));
  j := private.post_entry(s.org_id, case s.doc_type when 'receipt' then 'Sale ' when 'order' then 'Order ' else 'Invoice ' end || s.number || ' · ' || s.customer_name,
    'sale', s.id, m.id, null, v_jl, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  v_type := case when s.channel = 'voice' then 'voice_sale' else 'sale' end;
  for l in select * from sale_lines where sale_id = s.id and item_id is not null order by line_no loop
    perform private.sale_internal(s.org_id, l.item_id, s.location_id, l.qty * l.unit_factor, round(l.gross / (l.qty * l.unit_factor), 2), m.id,
      case s.channel when 'till' then 'Till' when 'online' then 'Online shop' when 'whatsapp' then 'WhatsApp' when 'van' then 'Van'
        when 'phone' then 'Phone app' when 'voice' then 'Voice' when 'api' then 'API' else 'Invoice' end,
      v_type, p_at, jsonb_build_object('note', s.number, 'device_id', s.device_id, 'offline', s.offline), j.id);
  end loop;
  update movements set sale_id = s.id where journal_id = j.id and sale_id is null;
  -- Money paid before the order was confirmed moves from advances to the receivable.
  select coalesce(sum(a.amount), 0) into v_adv from collection_allocations a join collections c on c.id = a.collection_id
  where a.sale_id = s.id and a.posted_as = 'advance' and c.status = 'confirmed' and c.journal_id is not null;
  if v_adv > 0 then
    r := private.post_entry(s.org_id, 'Advance applied to ' || s.number || ' · ' || s.customer_name, 'sale', s.id, m.id, null, jsonb_build_array(
      jsonb_build_object('code', private.acct(s.org_id, 'customer_advances'), 'debit', v_adv, 'party_type', 'customer', 'party_id', s.customer_id,
        'doc_type', 'sale', 'doc_id', s.id, 'memo', 'Paid before confirmation'),
      jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'credit', v_adv, 'party_type', 'customer', 'party_id', s.customer_id,
        'doc_type', 'sale', 'doc_id', s.id, 'memo', 'Paid before confirmation')), p_at);
    update collection_allocations a set posted_as = 'receivable', reclass_journal_id = r.id
    from collections c where c.id = a.collection_id and a.sale_id = s.id and a.posted_as = 'advance' and c.status = 'confirmed' and c.journal_id is not null;
  end if;
  update sales set journal_id = j.id, issued_at = coalesce(issued_at, p_at) where id = s.id returning * into s;
  return s;
end $$;

-- What is still owed on a sale, and its status.
create or replace function private.refresh_sale(p_sale uuid) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v_paid numeric; v_cred numeric; v_status text;
begin
  select * into s from sales where id = p_sale for update;
  if s.doc_type in ('quote', 'credit_note') or s.status in ('void', 'converted', 'cancelled', 'expired', 'draft') then return s; end if;
  select coalesce(sum(a.amount), 0) into v_paid from collection_allocations a join collections c on c.id = a.collection_id
    where a.sale_id = s.id and c.status = 'confirmed';
  select coalesce(sum(amount), 0) into v_cred from credit_allocations where sale_id = s.id;
  v_status := case when v_paid + v_cred >= s.total - 0.004 then case when v_cred >= s.total - 0.004 and v_paid = 0 then 'credited' else 'paid' end
                   when v_paid + v_cred > 0 then 'partially_paid'
                   when s.journal_id is null and s.doc_type in ('order', 'receipt') then 'pending'
                   else 'open' end;
  update sales set amount_paid = v_paid, credited = v_cred, status = v_status where id = s.id returning * into s;
  return s;
end $$;

-- Posts a confirmed collection.
--   In:  Dr the account the money reached (bank, wallet, drawer), or 1401 for WHT credit, or 2107 when customer credit is used;
--        Dr 6701 for the provider's fee; Cr 1101 for each sale it pays (2107 while an order is unconfirmed); Cr 2107 for any excess.
--   Out: Dr 1101 / 2107 for the customer credit paid back; Cr the account it left from.
create or replace function private.post_collection(p_collection uuid, m public.members) returns public.collections
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; b public.bank_accounts; v_alloc numeric := 0; v_jl jsonb; j public.journals; v_target text; a record; v_due numeric;
  v_cust text; v_party_target boolean;
begin
  select * into c from collections where id = p_collection for update;
  if c.journal_id is not null then return c; end if;
  if c.status <> 'confirmed' then raise exception 'Only confirmed payments post.'; end if;
  select name into v_cust from customers where id = c.customer_id;
  if c.method not in ('wht_credit', 'advance') then
    select * into b from bank_accounts where id = c.bank_account_id;
    if not found then raise exception 'Choose the account the money went into.'; end if;
  end if;
  if c.direction = 'out' then
    v_jl := jsonb_build_array(
      jsonb_build_object('code', private.acct(c.org_id, 'receivables'), 'debit', c.amount - c.advance_part, 'party_type', 'customer', 'party_id', c.customer_id,
        'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number),
      jsonb_build_object('code', private.acct(c.org_id, 'customer_advances'), 'debit', c.advance_part, 'party_type', 'customer', 'party_id', c.customer_id,
        'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number),
      jsonb_build_object('code', b.ledger_code, 'credit', c.amount, 'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number || ' · ' || v_cust));
  else
    -- A payment confirmed after the sale was settled another way keeps only what is still owed; the rest becomes customer credit.
    for a in select ca.sale_id, ca.amount from collection_allocations ca where ca.collection_id = c.id for update loop
      select s.total - s.credited - coalesce((select sum(x.amount) from collection_allocations x join collections cc on cc.id = x.collection_id
          where x.sale_id = s.id and cc.status = 'confirmed' and cc.id <> c.id), 0)
        into v_due from sales s where s.id = a.sale_id and s.status not in ('void', 'cancelled');
      if coalesce(v_due, 0) <= 0.004 then
        delete from collection_allocations where collection_id = c.id and sale_id = a.sale_id;
      elsif a.amount > v_due then
        update collection_allocations set amount = v_due where collection_id = c.id and sale_id = a.sale_id;
      end if;
    end loop;
    v_party_target := c.method in ('wht_credit', 'advance');
    v_target := case c.method when 'wht_credit' then private.acct(c.org_id, 'wht_receivable') when 'advance' then private.acct(c.org_id, 'customer_advances')
                else b.ledger_code end;
    v_jl := jsonb_build_array(jsonb_build_object('code', v_target, 'debit', c.amount - c.fee, 'doc_type', 'collection', 'doc_id', c.id,
      'party_type', case when v_party_target then 'customer' end, 'party_id', case when v_party_target then c.customer_id end,
      'memo', c.number || ' · ' || v_cust || coalesce(' · ' || c.reference, '')));
    if c.fee > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(c.org_id, 'payment_fees'), 'debit', c.fee, 'doc_type', 'collection',
        'doc_id', c.id, 'memo', 'Payment fee ' || c.number));
    end if;
    for a in select ca.*, s.number, s.journal_id sale_journal from collection_allocations ca join sales s on s.id = ca.sale_id where ca.collection_id = c.id loop
      v_alloc := v_alloc + a.amount;
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code',
          case when a.sale_journal is null then private.acct(c.org_id, 'customer_advances') else private.acct(c.org_id, 'receivables') end,
        'credit', a.amount, 'party_type', 'customer', 'party_id', c.customer_id, 'doc_type', 'sale', 'doc_id', a.sale_id, 'memo', c.number || ' for ' || a.number));
      update collection_allocations set posted_as = case when a.sale_journal is null then 'advance' else 'receivable' end
      where collection_id = c.id and sale_id = a.sale_id;
    end loop;
    if c.amount - v_alloc > 0.004 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(c.org_id, 'customer_advances'), 'credit', c.amount - v_alloc,
        'party_type', 'customer', 'party_id', c.customer_id, 'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Customer credit ' || c.number));
    end if;
  end if;
  j := private.post_entry(c.org_id,
    case when c.direction = 'out' then 'Refund ' when c.method = 'advance' then 'Customer credit used ' when c.method = 'wht_credit' then 'WHT deducted by customer '
      else 'Payment received ' end || c.number || ' · ' || v_cust,
    'collection', c.id, coalesce(m.id, c.confirmed_by, c.created_by), c.confirmed_by, v_jl, c.received_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', case when c.provider_ref is not null then 'provider' else 'confirmation' end,
      'ref', coalesce(c.provider_ref, c.reference), 'method', c.method, 'confirmed_by', c.confirmed_by))));
  update collections set journal_id = j.id where id = c.id returning * into c;
  for a in select sale_id from collection_allocations where collection_id = c.id loop
    perform private.refresh_sale(a.sale_id);
  end loop;
  return c;
end $$;

-- Records money from a customer and spreads it over the sales named first, then (when spreading) the oldest open ones.
create or replace function private.add_collection(p_org uuid, p_customer uuid, p_amount numeric, p_method text, p_meta jsonb, m public.members,
  p_status text, p_sales uuid[] default null) returns public.collections
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; v_left numeric := round(p_amount, 2); s record; v_take numeric; v_bank uuid := nullif(p_meta->>'bank_account_id', '')::uuid;
  v_spread boolean := coalesce((p_meta->>'spread')::boolean, p_sales is null);
begin
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter an amount above zero.'; end if;
  if v_bank is not null and not exists (select 1 from bank_accounts where id = v_bank and org_id = p_org and active) then
    raise exception 'That account is not available.';
  end if;
  insert into collections (org_id, number, customer_id, sale_id, amount, fee, method, status, bank_account_id, shift_id, payment_request_id, reference,
    provider_ref, received_at, confirmed_by, confirmed_at, note, wht_rate, client_uuid, created_by)
  values (p_org, private.pay_no(p_org), p_customer, (p_sales)[1], round(p_amount, 2),
    round(coalesce(private.num(p_meta->>'fee'), 0), 2), p_method, p_status, v_bank, nullif(p_meta->>'shift_id', '')::uuid,
    nullif(p_meta->>'payment_request_id', '')::uuid, nullif(trim(p_meta->>'reference'), ''), nullif(p_meta->>'provider_ref', ''),
    least(coalesce(nullif(p_meta->>'received_at', '')::timestamptz, now()), now()),
    case when p_status = 'confirmed' then m.id end, case when p_status = 'confirmed' then now() end, nullif(trim(p_meta->>'note'), ''),
    nullif(p_meta->>'wht_rate', '')::numeric, nullif(p_meta->>'client_uuid', '')::uuid, m.id)
  returning * into c;
  for s in
    select x.id, x.total - x.amount_paid - x.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = x.id and cc.status = 'pending'), 0) due
    from sales x
    where x.org_id = p_org and x.customer_id = p_customer and x.status in ('open', 'partially_paid', 'pending')
      and x.doc_type in ('receipt', 'invoice', 'order') and (x.id = any(coalesce(p_sales, '{}')) or v_spread)
    order by array_position(p_sales, x.id) nulls last, coalesce(x.due_date, x.issue_date), x.created_at
    for update of x
  loop
    exit when v_left <= 0.004;
    v_take := least(v_left, greatest(s.due, 0));
    if v_take > 0 then
      insert into collection_allocations (collection_id, sale_id, org_id, amount) values (c.id, s.id, p_org, v_take);
      v_left := v_left - v_take;
    end if;
  end loop;
  if p_status = 'confirmed' then
    c := private.post_collection(c.id, m);
  elsif p_method in ('transfer', 'card', 'pos', 'cheque', 'other') then
    -- Someone who can confirm money is told there is a payment to check against the bank.
    perform private.notify_perm(p_org, 'approve_adjustments', 'payment', 'Confirm a ' || p_method || ' of ₦' || to_char(c.amount, 'FM999,999,999,990.00'),
      coalesce((select name from customers where id = p_customer), '') || coalesce(' · ' || c.reference, '') || ' · recorded by ' || coalesce(m.display_name, 'the shop'),
      '/sell/payments', 'confirm-payments', m.id);
    perform private.notify_perm(p_org, 'keep_books', 'payment', 'Confirm a ' || p_method || ' of ₦' || to_char(c.amount, 'FM999,999,999,990.00'),
      coalesce((select name from customers where id = p_customer), '') || coalesce(' · ' || c.reference, '') || ' · recorded by ' || coalesce(m.display_name, 'the shop'),
      '/sell/payments', 'confirm-payments', m.id);
  end if;
  return c;
end $$;

-- Uses a customer's credit against a sale: open credit notes first, then money held as an advance.
create or replace function private.use_customer_credit(p_sale uuid, p_amount numeric, m public.members) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; cn record; v_left numeric := round(coalesce(p_amount, 0), 2); v_take numeric; v_adv numeric; v_due numeric;
begin
  s := private.refresh_sale(p_sale);
  v_due := s.total - s.amount_paid - s.credited;
  if v_left > v_due + 0.004 then raise exception 'Only % is owed on %.', to_char(v_due, 'FM999,999,999,990.00'), s.number; end if;
  for cn in select id, total - credited remaining from sales where org_id = s.org_id and customer_id = s.customer_id and doc_type = 'credit_note'
      and status = 'open' and total - credited > 0 order by created_at for update loop
    exit when v_left <= 0.004;
    v_take := least(v_left, cn.remaining);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, s.id, s.org_id, v_take, m.id)
    on conflict (credit_note_id, sale_id) do update set amount = credit_allocations.amount + excluded.amount;
    update sales set credited = credited + v_take, status = case when credited + v_take >= total - 0.004 then 'paid' else status end where id = cn.id;
    v_left := v_left - v_take;
  end loop;
  if v_left > 0.004 then
    v_adv := private.customer_advance(s.org_id, s.customer_id);
    if v_adv < v_left - 0.004 then
      raise exception '% has only % of credit.', s.customer_name, to_char(round(coalesce(p_amount, 0), 2) - v_left + greatest(v_adv, 0), 'FM999,999,999,990.00');
    end if;
    perform private.add_collection(s.org_id, s.customer_id, v_left, 'advance', jsonb_build_object('reference', 'Customer credit', 'spread', false), m,
      'confirmed', array[s.id]);
  end if;
  perform private.refresh_sale(s.id);
  return round(coalesce(p_amount, 0), 2);
end $$;

-- The cash drawer of a branch, opened on first use as a sub-account of 1011.
create or replace function private.cash_drawer(p_org uuid, p_loc uuid, m public.members) returns public.bank_accounts
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; v_name text;
begin
  select ba.* into b from bank_accounts ba join locations l on l.cash_account_id = ba.id where l.id = p_loc and l.org_id = p_org and ba.active;
  if found then return b; end if;
  select * into b from bank_accounts where org_id = p_org and kind = 'cash' and location_id = p_loc and active order by created_at limit 1;
  if not found then
    select name into v_name from locations where id = p_loc and org_id = p_org;
    if v_name is null then raise exception 'Unknown branch.'; end if;
    b := private.open_bank_account(p_org, 'cash', 'Cash drawer · ' || v_name, jsonb_build_object('location_id', p_loc), m.id);
  end if;
  update locations set cash_account_id = b.id where id = p_loc and cash_account_id is null;
  return b;
end $$;

-- The heart of the till, the phone app, the invoice editor and the shop.
-- p: {client_uuid, doc_type, location_id, shift_id, customer_id | customer:{name, phone, email}, price_list_id, retail_only, lines[], cart_discount,
--     delivery_fee, delivery_method, delivery_address, due_date, issue_date, reference, notes, terms, channel, recorded_at, device, offline,
--     prices_include_vat (invoices and quotes), tenders:[{method, amount, reference, bank_account_id}], pay_in_full: method,
--     status: 'draft' | 'issue'}
create or replace function private.create_sale(p_org uuid, p jsonb, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; o public.orgs; c public.customers; v_type text := coalesce(nullif(p->>'doc_type', ''), 'receipt');
  v_at timestamptz := coalesce(nullif(p->>'recorded_at', '')::timestamptz, now()); v_loc uuid; v_shift public.shifts; t jsonb; v_credit numeric := 0;
  v_cust uuid; v_owed numeric; v_paid numeric; v_tendered numeric := 0; v_issue boolean; v_bank uuid; v_method text; v_change numeric := 0;
  v_tenders jsonb; v_day date; v_today date; v_manager boolean; v_amt numeric; v_instant numeric := 0;
begin
  if nullif(p->>'client_uuid', '') is not null then
    select * into s from sales where client_uuid = (p->>'client_uuid')::uuid;
    if found then return s; end if;
  end if;
  if v_type not in ('receipt', 'invoice', 'quote', 'order') then raise exception 'Unknown document type.'; end if;
  if v_at > now() + interval '5 minutes' then v_at := now(); end if;
  select * into o from orgs where id = p_org;
  v_manager := coalesce(private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books'), false);
  v_loc := coalesce(nullif(p->>'location_id', '')::uuid, m.location_id, (select id from locations where org_id = p_org order by is_main desc, created_at limit 1));
  if not exists (select 1 from locations where id = v_loc and org_id = p_org) then raise exception 'Choose the branch selling.'; end if;
  if nullif(p->>'shift_id', '') is not null then
    select * into v_shift from shifts where id = (p->>'shift_id')::uuid and org_id = p_org;
    if not found or v_shift.status <> 'open' then raise exception 'This till shift is closed. Open a new shift.'; end if;
  end if;
  v_today := private.local_day(p_org, now());
  v_day := coalesce(nullif(p->>'issue_date', '')::date, private.local_day(p_org, v_at));
  if v_day > v_today then raise exception 'A sale cannot be dated in the future.'; end if;
  -- Customer: chosen, matched by phone, created on the spot, or the walk-in customer.
  v_cust := nullif(p->>'customer_id', '')::uuid;
  if v_cust is null and coalesce(trim(p->'customer'->>'name'), '') <> '' then
    select id into v_cust from customers where org_id = p_org and phone = private.clean_phone(p->'customer'->>'phone') and not archived;
    if v_cust is null then v_cust := private.upsert_customer(p_org, (p->'customer') - 'id' - 'credit_limit' - 'terms_days', m); end if;
  end if;
  if v_cust is null then
    if v_type in ('invoice', 'quote') then raise exception 'Choose the customer.'; end if;
    v_cust := private.walk_in(p_org);
  end if;
  select * into c from customers where id = v_cust and org_id = p_org and not archived;
  if not found then raise exception 'Customer not found.'; end if;
  v_issue := coalesce(p->>'status', 'issue') = 'issue' and v_type in ('receipt', 'invoice');
  if v_issue then perform private.require_open_day(p_org, v_day); end if;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, shift_id, price_list_id, channel, issue_date, due_date, prices_include_vat, vat_registered, delivery_fee, reference, notes, terms,
    delivery_method, delivery_address, client_uuid, device_id, offline, created_by, created_at)
  values (p_org, v_type, private.doc_number(p_org, v_type),
    case when v_type = 'quote' then 'open' when v_type = 'order' then 'pending' when v_issue then 'open' else 'draft' end,
    c.id, c.name, c.phone, c.email, c.tin, c.address, v_loc, v_shift.id,
    case when coalesce((p->>'retail_only')::boolean, false) then null
         when nullif(p->>'price_list_id', '') is not null and exists (select 1 from price_lists where id = (p->>'price_list_id')::uuid and org_id = p_org)
         then (p->>'price_list_id')::uuid else c.price_list_id end,
    coalesce(nullif(p->>'channel', ''), case v_type when 'invoice' then 'invoice' when 'quote' then 'invoice' when 'order' then 'online' else 'till' end),
    v_day,
    case when v_type = 'quote' then coalesce(nullif(p->>'due_date', '')::date, v_day + 14)
         else coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(c.terms_days, 0), case when v_type = 'receipt' then 0 else o.invoice_terms_days end, 0)) end,
    case when v_type in ('invoice', 'quote') then coalesce((p->>'prices_include_vat')::boolean, o.prices_include_vat) else o.prices_include_vat end,
    o.vat_registered, round(greatest(coalesce(private.num(p->>'delivery_fee'), 0), 0), 2), nullif(trim(p->>'reference'), ''),
    nullif(trim(p->>'notes'), ''), coalesce(nullif(trim(p->>'terms'), ''), case when v_type = 'invoice' then o.invoice_note end),
    nullif(p->>'delivery_method', ''), nullif(trim(p->>'delivery_address'), ''), nullif(p->>'client_uuid', '')::uuid,
    nullif(p->>'device', ''), coalesce((p->>'offline')::boolean, false), m.id, v_at)
  returning * into s;
  s := private.write_lines(s, p->'lines', private.num(p->>'cart_discount'), m);
  if s.total <= 0 and v_type <> 'quote' then raise exception 'The total must be above zero.'; end if;
  if not v_issue then return s; end if;
  -- What the customer paid now. Anything not covered is credit.
  v_tenders := case when nullif(p->>'pay_in_full', '') is not null then jsonb_build_array(jsonb_build_object('method', p->>'pay_in_full', 'amount', s.total))
                    else coalesce(p->'tenders', '[]'::jsonb) end;
  if jsonb_typeof(v_tenders) <> 'array' then raise exception 'Payments must be a list.'; end if;
  for t in select * from jsonb_array_elements(v_tenders) loop
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    if v_amt < 0 then raise exception 'A payment cannot be negative.'; end if;
    if coalesce(t->>'method', '') not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other', 'credit', 'account', 'link', 'qr') then
      raise exception 'Unknown way of paying: %.', coalesce(t->>'method', '(none)');
    end if;
    if t->>'method' in ('account', 'link', 'qr') then
      if v_type <> 'receipt' then raise exception 'Send a payment link from the invoice instead.'; end if;
      v_instant := v_instant + v_amt;
    end if;
    v_tendered := v_tendered + v_amt;
  end loop;
  if v_tendered > s.total + 0.004 then
    -- Cash handed over above the total is change, not income.
    v_change := v_tendered - s.total;
    if (select coalesce(sum(round(private.num(e->>'amount'), 2)), 0) from jsonb_array_elements(v_tenders) e where e->>'method' = 'cash') < v_change - 0.004 then
      raise exception 'The payments are more than the total. Only cash can be more than the total, as change.';
    end if;
  end if;
  v_credit := greatest(s.total - v_tendered, 0);
  if v_credit > 0.004 and v_type = 'receipt' then
    if c.is_walk_in then raise exception 'A walk-in customer cannot buy on credit. Choose or add the customer.'; end if;
    if c.credit_limit = 0 and not v_manager then
      raise exception '% has no credit limit. Set one on the customer, or ask a manager.', c.name;
    end if;
  end if;
  if v_credit > 0.004 then
    v_owed := private.customer_balance(p_org, c.id) + v_credit;
    if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not v_manager then
      raise exception '% would owe % against a credit limit of %. A manager can approve it.', c.name,
        to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
    end if;
  end if;
  -- Paying by instant transfer, link or QR: the sale waits, unposted, until the rail confirms the money. Then it posts and takes the stock.
  if v_instant > 0 then
    update sales set status = 'pending' where id = s.id returning * into s;
  else
    s := private.post_sale(s.id, m, private.posting_time(p_org, v_day, v_at));
  end if;
  for t in select * from jsonb_array_elements(v_tenders) loop
    v_method := t->>'method';
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    v_paid := v_amt;
    if v_method = 'cash' and v_change > 0 then
      v_paid := v_amt - least(v_change, v_amt);
      v_change := v_change - least(v_change, v_amt);
    end if;
    continue when v_paid <= 0;
    if v_method = 'credit' then
      perform private.use_customer_credit(s.id, v_paid, m);
      continue;
    end if;
    if v_method in ('account', 'link', 'qr') then
      perform private.open_request(p_org, s.id, null, v_method, v_paid, m, false, v_shift.id);
      continue;
    end if;
    if v_method = 'cash' then
      v_bank := coalesce(v_shift.cash_account_id, (private.cash_drawer(p_org, v_loc, m)).id);
    else
      v_bank := nullif(t->>'bank_account_id', '')::uuid;
    end if;
    perform private.add_collection(p_org, c.id, v_paid, v_method,
      jsonb_build_object('bank_account_id', v_bank, 'shift_id', v_shift.id, 'reference', t->>'reference', 'received_at', v_at, 'spread', false,
        'note', case when v_method <> 'cash' then 'Recorded at the till by ' || coalesce(m.display_name, 'staff') end),
      m, case when v_method = 'cash' then 'confirmed' else 'pending' end, array[s.id]);
  end loop;
  return private.refresh_sale(s.id);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Till, invoices, quotes, payments, voids, returns
-- ---------------------------------------------------------------------------
create or replace function private.sale_json(p_sale uuid, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(s) || jsonb_build_object(
    'cost_total', case when p_cost then (select sum(cost) from sale_lines where sale_id = s.id) end,
    'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                    when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
    'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
    'confirmed', s.journal_id is not null,
    'location_name', (select name from locations where id = s.location_id),
    'created_by_name', (select display_name from members where id = s.created_by),
    'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(private.local_day(s.org_id, now()) - s.due_date, 0) end,
    'org', (select jsonb_build_object('name', o.name, 'address', o.address, 'phone', o.phone, 'email', o.email, 'tin', o.tin, 'rc_number', o.rc_number,
        'logo_path', o.logo_path, 'receipt_footer', o.receipt_footer, 'vat_registered', o.vat_registered, 'timezone', o.timezone) from orgs o where o.id = s.org_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'cost' - 'org_id' || jsonb_build_object('cost', case when p_cost then l.cost end) order by l.line_no), '[]'::jsonb)
              from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'status', c.status, 'direction', c.direction,
        'amount', a.amount, 'collection_amount', c.amount, 'fee', c.fee, 'received_at', c.received_at, 'reference', c.reference, 'bank_account_id', c.bank_account_id,
        'confirmed_by_name', (select display_name from members where id = c.confirmed_by)) order by c.received_at), '[]'::jsonb)
      from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id),
    'refunds', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'received_at', c.received_at)), '[]'::jsonb)
      from collections c where c.sale_id = s.id and c.direction = 'out'),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('credit_note_id', ca.credit_note_id, 'number', cn.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales cn on cn.id = ca.credit_note_id where ca.sale_id = s.id and ca.credit_note_id <> s.id),
    'applied_to', (select coalesce(jsonb_agg(jsonb_build_object('sale_id', ca.sale_id, 'number', x.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales x on x.id = ca.sale_id where ca.credit_note_id = s.id and ca.sale_id <> s.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', cn.id, 'number', cn.number, 'total', cn.total, 'status', cn.status)), '[]'::jsonb)
      from sales cn where cn.original_sale_id = s.id and cn.doc_type = 'credit_note'),
    'original_number', (select number from sales where id = s.original_sale_id),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'method', r.method, 'status', r.status, 'amount', r.amount, 'account_number', r.account_number,
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end)
  from sales s where s.id = p_sale
$$;

create or replace function public.till_checkout(p_org uuid, p_sale jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.sales;
begin
  m := private.require(p_org, 'record_sales');
  s := private.create_sale(p_org, (p_sale - 'issue_date' - 'prices_include_vat' - 'retail_only') || jsonb_build_object('doc_type', 'receipt', 'status', 'issue'), m);
  return private.sale_json(s.id, private.can_see_costs(p_org));
end $$;

-- Create or edit an invoice or quote. Drafts can be edited; issuing posts the invoice.
create or replace function public.save_sale_doc(p_org uuid, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.sales; v_id uuid := nullif(p_doc->>'id', '')::uuid; v_type text := coalesce(nullif(p_doc->>'doc_type', ''), 'invoice');
  c public.customers; o public.orgs;
begin
  m := private.require(p_org, 'record_sales');
  if v_type not in ('invoice', 'quote') then raise exception 'Only invoices and quotes are edited here.'; end if;
  if v_id is null then
    s := private.create_sale(p_org, (p_doc - 'tenders' - 'pay_in_full' - 'retail_only') || jsonb_build_object('doc_type', v_type,
      'status', case when v_type = 'invoice' and p_doc->>'status' = 'issue' then 'issue' else 'draft' end), m);
  else
    select * into s from sales where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Document not found.'; end if;
    if not (s.status = 'draft' or (s.doc_type = 'quote' and s.status = 'open')) then
      raise exception '% is already issued. Void it or raise a credit note instead.', s.number;
    end if;
    select * into o from orgs where id = p_org;
    if nullif(p_doc->>'customer_id', '') is not null and (p_doc->>'customer_id')::uuid <> s.customer_id then
      select * into c from customers where id = (p_doc->>'customer_id')::uuid and org_id = p_org and not archived;
      if not found then raise exception 'Customer not found.'; end if;
      update sales set customer_id = c.id, customer_name = c.name, customer_phone = c.phone, customer_email = c.email, customer_tin = c.tin,
        customer_address = c.address, price_list_id = c.price_list_id where id = s.id;
    end if;
    update sales set issue_date = coalesce(nullif(p_doc->>'issue_date', '')::date, issue_date),
      due_date = coalesce(nullif(p_doc->>'due_date', '')::date, due_date),
      price_list_id = case when p_doc ? 'price_list_id' then (select id from price_lists where id = nullif(p_doc->>'price_list_id', '')::uuid and org_id = p_org)
                           else price_list_id end,
      reference = case when p_doc ? 'reference' then nullif(trim(p_doc->>'reference'), '') else reference end,
      notes = case when p_doc ? 'notes' then nullif(trim(p_doc->>'notes'), '') else notes end,
      terms = case when p_doc ? 'terms' then nullif(trim(p_doc->>'terms'), '') else terms end,
      delivery_fee = case when p_doc ? 'delivery_fee' then round(greatest(coalesce(private.num(p_doc->>'delivery_fee'), 0), 0), 2) else delivery_fee end,
      delivery_address = case when p_doc ? 'delivery_address' then nullif(trim(p_doc->>'delivery_address'), '') else delivery_address end,
      location_id = coalesce((select id from locations where id = nullif(p_doc->>'location_id', '')::uuid and org_id = p_org), location_id),
      prices_include_vat = coalesce((p_doc->>'prices_include_vat')::boolean, prices_include_vat), vat_registered = o.vat_registered
    where id = s.id returning * into s;
    if s.issue_date > private.local_day(p_org, now()) then raise exception 'A document cannot be dated in the future.'; end if;
    if s.due_date < s.issue_date then raise exception 'The due date is before the issue date.'; end if;
    s := private.write_lines(s, coalesce(p_doc->'lines', (select jsonb_agg(case when l.item_id is not null then
        jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end, 'unit_price', l.unit_price,
          'discount', l.discount)
      else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
          'vat_treatment', l.vat_treatment, 'revenue_account', l.revenue_account) end order by l.line_no)
      from sale_lines l where l.sale_id = s.id and l.kind <> 'delivery')), private.num(p_doc->>'cart_discount'), m);
    if p_doc->>'status' = 'issue' and s.doc_type = 'invoice' then
      return public.issue_invoice(s.id, null);
    end if;
  end if;
  return private.sale_json(s.id, private.can_see_costs(p_org));
end $$;

create or replace function public.issue_invoice(p_sale uuid, p_issue_date date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; c public.customers; v_owed numeric; v_day date; v_today date;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.doc_type <> 'invoice' or s.status <> 'draft' then raise exception '% is not a draft invoice.', s.number; end if;
  if s.total <= 0 then raise exception 'The invoice total must be above zero.'; end if;
  v_today := private.local_day(s.org_id, now());
  -- A draft left with the day it was started takes the day it is issued.
  v_day := coalesce(p_issue_date, case when s.issue_date = private.local_day(s.org_id, s.created_at) then v_today else s.issue_date end);
  if v_day > v_today then raise exception 'An invoice cannot be dated in the future.'; end if;
  perform private.require_open_day(s.org_id, v_day);
  select * into c from customers where id = s.customer_id;
  v_owed := private.customer_balance(s.org_id, c.id) + s.total;
  if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception '% would owe % against a credit limit of %. A manager can issue it.', c.name, to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
  end if;
  update sales set status = 'open', due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day where id = s.id;
  s := private.post_sale(s.id, m, private.posting_time(s.org_id, v_day));
  s := private.refresh_sale(s.id);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

create or replace function public.convert_quote(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare q public.sales; m public.members; v_lines jsonb; s public.sales;
begin
  select * into q from sales where id = p_sale for update;
  if not found or q.doc_type <> 'quote' then raise exception 'Quote not found.'; end if;
  m := private.require(q.org_id, 'record_sales');
  if q.status <> 'open' then raise exception '% is %.', q.number, q.status; end if;
  select jsonb_agg(case when l.item_id is not null then jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end,
      'unit_price', l.unit_price, 'discount', l.discount)
    else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
      'vat_treatment', l.vat_treatment, 'revenue_account', l.revenue_account) end order by l.line_no)
  into v_lines from sale_lines l where l.sale_id = q.id and l.kind <> 'delivery';
  -- The quoted prices are what the customer agreed, so the invoice keeps them whoever converts it.
  s := private.create_sale(q.org_id, jsonb_build_object('doc_type', 'invoice', 'status', 'draft', 'customer_id', q.customer_id,
    'location_id', q.location_id, 'price_list_id', q.price_list_id, 'delivery_fee', q.delivery_fee, 'notes', q.notes, 'terms', q.terms,
    'reference', q.number, 'prices_include_vat', q.prices_include_vat, 'delivery_address', q.delivery_address, 'lines', v_lines),
    jsonb_populate_record(m, '{"p_edit_prices": true}'::jsonb));
  update sales set status = 'converted', converted_to = s.id where id = q.id;
  return private.sale_json(s.id, private.can_see_costs(q.org_id));
end $$;

-- Money received against a customer or a sale. Cash is confirmed at once. Transfers, card and cheques wait for a manager or
-- accountant to confirm them, unless the person recording can confirm and says the money is in the account.
create or replace function public.record_payment(p_org uuid, p_payment jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.collections; v_cust uuid := nullif(p_payment->>'customer_id', '')::uuid; v_sale uuid := nullif(p_payment->>'sale_id', '')::uuid;
  v_method text := coalesce(nullif(p_payment->>'method', ''), 'transfer'); v_status text; v_wht numeric; s public.sales; v_amt numeric := round(private.num(p_payment->>'amount'), 2);
  v_confirmer boolean; v_bank uuid := nullif(p_payment->>'bank_account_id', '')::uuid;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_payment->>'client_uuid', '') is not null then
    select * into c from collections where client_uuid = (p_payment->>'client_uuid')::uuid;
    if found then return jsonb_build_object('collection', to_jsonb(c), 'duplicate', true); end if;
  end if;
  if v_sale is not null then
    select * into s from sales where id = v_sale and org_id = p_org;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
    if s.status in ('void', 'cancelled', 'draft') then raise exception '% is %.', s.number, s.status; end if;
    v_cust := s.customer_id;
  end if;
  if v_cust is null or not exists (select 1 from customers where id = v_cust and org_id = p_org) then raise exception 'Choose the customer who paid.'; end if;
  if v_method not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other') then raise exception 'Unknown payment method.'; end if;
  v_confirmer := private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments');
  v_status := case when v_method = 'cash' then 'confirmed'
                   when coalesce((p_payment->>'confirmed')::boolean, false) and v_confirmer then 'confirmed'
                   else 'pending' end;
  if v_method = 'cash' and v_bank is null then
    v_bank := (private.cash_drawer(p_org, coalesce(s.location_id, m.location_id, (select id from locations where org_id = p_org order by is_main desc, created_at limit 1)), m)).id;
  end if;
  if v_status = 'confirmed' and v_bank is null then raise exception 'Choose the account the money went into.'; end if;
  -- WHT the customer deducted is a credit against tax, not money (AR-03): Dr 1401 / Cr 1101.
  v_wht := round(private.num(p_payment->>'wht_amount'), 2);
  if coalesce(v_wht, 0) > 0 then
    perform private.add_collection(p_org, v_cust, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', nullif(p_payment->>'wht_rate', ''),
      'note', 'Collect the withholding tax credit note from the customer', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  if coalesce(v_amt, 0) > 0 then
    c := private.add_collection(p_org, v_cust, v_amt, v_method, (p_payment - 'wht_amount' - 'confirmed' - 'fee') || jsonb_build_object('bank_account_id', v_bank),
      m, v_status, case when v_sale is not null then array[v_sale] end);
  elsif coalesce(v_wht, 0) = 0 then
    raise exception 'Enter the amount paid.';
  end if;
  return jsonb_build_object('collection', to_jsonb(c), 'sale', case when v_sale is not null then private.sale_json(v_sale, private.can_see_costs(p_org)) end);
end $$;

create or replace function public.confirm_payment(p_collection uuid, p_bank_account uuid, p_confirm boolean default true, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; m public.members; a record;
begin
  select * into c from collections where id = p_collection for update;
  if not found then raise exception 'Payment not found.'; end if;
  m := private.require(c.org_id, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments')) then
    raise exception 'Only a manager, an accountant or the owner confirms payments.' using errcode = '42501';
  end if;
  if c.status <> 'pending' then raise exception '% is already %.', c.number, c.status; end if;
  if not coalesce(p_confirm, true) then
    update collections set status = 'rejected', note = concat_ws(' · ', note, nullif(trim(p_note), '')), confirmed_by = m.id, confirmed_at = now() where id = c.id;
    for a in select sale_id from collection_allocations where collection_id = c.id loop perform private.refresh_sale(a.sale_id); end loop;
    return jsonb_build_object('status', 'rejected', 'number', c.number);
  end if;
  if p_bank_account is null or not exists (select 1 from bank_accounts where id = p_bank_account and org_id = c.org_id and active) then
    raise exception 'Choose the account the money arrived in.';
  end if;
  update collections set status = 'confirmed', bank_account_id = p_bank_account, confirmed_by = m.id, confirmed_at = now(),
    note = concat_ws(' · ', note, nullif(trim(p_note), '')) where id = c.id;
  c := private.post_collection(c.id, m);
  return jsonb_build_object('status', 'confirmed', 'journal_id', c.journal_id, 'number', c.number);
end $$;

-- Use a customer's credit (open credit notes, then money held in advance) against a sale.
create or replace function public.apply_customer_credit(p_sale uuid, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale;
  if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.status not in ('open', 'partially_paid', 'pending') then raise exception '% has nothing owed.', s.number; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the amount to apply.'; end if;
  perform private.use_customer_credit(s.id, p_amount, m);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- Pay a customer's credit back (from a credit note or an advance).
create or replace function public.refund_customer(p_org uuid, p_customer uuid, p_amount numeric, p_method text, p_bank_account uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.customers; v_bal numeric; v_ar numeric; v_adv numeric; v_amt numeric := round(coalesce(p_amount, 0), 2);
  col public.collections; cn record; v_left numeric; v_take numeric; v_bank uuid := p_bank_account;
begin
  m := private.require(p_org, 'approve_adjustments');
  select * into c from customers where id = p_customer and org_id = p_org;
  if not found then raise exception 'Customer not found.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the refund.'; end if;
  if coalesce(p_method, 'cash') not in ('cash', 'transfer', 'cheque', 'other') then raise exception 'Unknown refund method.'; end if;
  v_bal := private.customer_balance(p_org, c.id);
  if v_amt <= 0 or v_amt > -v_bal + 0.004 then
    raise exception '% has % of credit to refund.', c.name, to_char(greatest(-v_bal, 0), 'FM999,999,999,990.00');
  end if;
  if v_bank is null and coalesce(p_method, 'cash') = 'cash' then v_bank := (private.cash_drawer(p_org, coalesce(m.location_id,
      (select id from locations where org_id = p_org order by is_main desc, created_at limit 1)), m)).id; end if;
  if v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = p_org and active) then
    raise exception 'Choose the account the refund is paid from.';
  end if;
  -- Credit held in receivables (credit notes) goes first, then advances.
  select coalesce(sum(debit - credit), 0) into v_ar from journal_lines where org_id = p_org and party_type = 'customer' and party_id = c.id and account_code in ('1101', '1102');
  v_adv := greatest(v_amt - greatest(-v_ar, 0), 0);
  insert into collections (org_id, number, direction, customer_id, amount, advance_part, method, status, bank_account_id, shift_id, reference, received_at,
    confirmed_by, confirmed_at, note, created_by)
  values (p_org, private.pay_no(p_org), 'out', c.id, v_amt, v_adv, coalesce(p_method, 'cash'), 'confirmed', v_bank,
    (select id from shifts where cash_account_id = v_bank and status = 'open'), 'Refund', now(), m.id, now(), trim(p_reason), m.id)
  returning * into col;
  col := private.post_collection(col.id, m);
  v_left := v_amt - v_adv;
  for cn in select id, total - credited remaining from sales where org_id = p_org and customer_id = c.id and doc_type = 'credit_note' and status = 'open'
      and total - credited > 0 order by created_at for update loop
    exit when v_left <= 0.004;
    v_take := least(v_left, cn.remaining);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, p_org, v_take, m.id)
    on conflict (credit_note_id, sale_id) do update set amount = credit_allocations.amount + excluded.amount;
    update sales set credited = credited + v_take, status = case when credited + v_take >= total - 0.004 then 'paid' else status end where id = cn.id;
    v_left := v_left - v_take;
  end loop;
  return jsonb_build_object('collection', to_jsonb(col), 'balance', private.customer_balance(p_org, c.id));
end $$;

-- Void a sale: the cashier on the same day, otherwise a manager. Reverses revenue, VAT, cost and stock.
-- Cash taken for this sale alone goes back out of the drawer; customer credit used goes back to the customer; any other
-- payment stays with the business as the customer's credit, to use or refund.
create or replace function public.void_sale(p_sale uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; r public.journals; mv record; a record; v_cash numeric := 0; v_credit numeric := 0;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for voiding.'; end if;
  if s.doc_type in ('credit_note', 'quote') then raise exception 'A % cannot be voided.', replace(s.doc_type, '_', ' '); end if;
  if s.status in ('void', 'converted', 'cancelled', 'expired', 'draft') then raise exception '% is %.', s.number, s.status; end if;
  if s.journal_id is null then raise exception '% is not confirmed yet. Cancel it instead.', s.number; end if;
  if not (private.perm_of(m, 'approve_adjustments') or (s.created_by = m.id and private.local_day(s.org_id, s.created_at) = private.local_day(s.org_id, now()))) then
    raise exception 'Only a manager can void another person''s sale, or one from an earlier day.';
  end if;
  if exists (select 1 from credit_allocations where sale_id = s.id) or exists (select 1 from sales where original_sale_id = s.id and doc_type = 'credit_note') then
    raise exception '% has a credit note against it.', s.number;
  end if;
  -- A walk-in customer cannot hold credit, so money that is not cash in the drawer has to go back as a refund.
  if (select is_walk_in from customers where id = s.customer_id) and exists (
       select 1 from collection_allocations ca join collections col on col.id = ca.collection_id
       where ca.sale_id = s.id and col.status = 'confirmed' and not (col.method = 'cash' and col.amount = ca.amount
         and not exists (select 1 from collection_allocations x where x.collection_id = col.id and x.sale_id <> s.id))) then
    raise exception '% was paid by transfer or card. Take the goods back as a return and refund the customer instead.', s.number;
  end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  for a in select ca.amount, ca.reclass_journal_id, col.id cid, col.method, col.amount col_amount, col.journal_id cj,
      (select count(*) from collection_allocations x where x.collection_id = col.id) n
    from collection_allocations ca join collections col on col.id = ca.collection_id
    where ca.sale_id = s.id and col.status = 'confirmed' and col.journal_id is not null loop
    if a.method in ('cash', 'advance') and a.n = 1 and a.col_amount = a.amount then
      perform private.reverse_entry(a.cj, m.id, 'Sale ' || s.number || ' voided', null);
      update collections set status = 'reversed' where id = a.cid;
      if a.method = 'cash' then v_cash := v_cash + a.amount; else v_credit := v_credit + a.amount; end if;
    elsif a.reclass_journal_id is not null then
      perform private.reverse_entry(a.reclass_journal_id, m.id, 'Sale ' || s.number || ' voided', null);
      v_credit := v_credit + a.amount;
    else
      perform private.post_entry(s.org_id, 'Payment for voided ' || s.number || ' kept as customer credit', 'sale', s.id, m.id, null, jsonb_build_array(
        jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'debit', a.amount, 'party_type', 'customer', 'party_id', s.customer_id,
          'doc_type', 'sale', 'doc_id', s.id),
        jsonb_build_object('code', private.acct(s.org_id, 'customer_advances'), 'credit', a.amount, 'party_type', 'customer', 'party_id', s.customer_id,
          'doc_type', 'collection', 'doc_id', a.cid)), now());
      v_credit := v_credit + a.amount;
    end if;
  end loop;
  r := private.reverse_entry(s.journal_id, m.id, 'Voided: ' || trim(p_reason), null);
  for mv in select * from movements where journal_id = s.journal_id and sale_id = s.id loop
    perform private.update_wac(mv.item_id, -mv.qty, -mv.qty * mv.unit_cost);
    if mv.batch_id is not null then update batches set qty_remaining = qty_remaining - mv.qty where id = mv.batch_id; end if;
    perform private.add_movement(s.org_id, 'sale_return', mv.item_id, mv.location_id, -mv.qty, mv.unit_cost, mv.unit_price, r.id, m.id, 'Void', now(),
      jsonb_build_object('note', 'Void ' || s.number || ' · ' || trim(p_reason), 'batch_id', mv.batch_id));
  end loop;
  update movements set sale_id = s.id where journal_id = r.id;
  -- Pending transfers stay pending; if confirmed later they become the customer's credit.
  delete from collection_allocations where sale_id = s.id;
  update payment_requests set status = 'cancelled' where sale_id = s.id and status in ('creating', 'pending');
  update deliveries set status = 'cancelled' where sale_id = s.id and status in ('pending', 'dispatched');
  update sales set status = 'void', voided_by = m.id, voided_at = now(), void_reason = trim(p_reason) where id = s.id;
  return jsonb_build_object('status', 'void', 'number', s.number, 'cash_back', v_cash, 'customer_credit', v_credit);
end $$;

-- Returns and credit notes. p_lines: [{sale_line_id, qty}]. p_refund: {method, amount, bank_account_id}; leave out to keep it as credit.
create or replace function public.return_sale(p_sale uuid, p_lines jsonb, p_refund jsonb, p_reason text, p_restock boolean default true) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; cn public.sales; x jsonb; l public.sale_lines; v_qty numeric; v_jl jsonb := '[]'::jsonb; j public.journals;
  v_net numeric := 0; v_vat numeric := 0; v_gross numeric; v_lnet numeric; v_cost numeric; v_ratio numeric; v_refund numeric; v_due numeric; v_apply numeric;
  v_wac numeric; v_total numeric; v_bank uuid; col public.collections; v_no int := 0; v_whole boolean;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'approve_adjustments');
  if s.doc_type not in ('receipt', 'invoice', 'order') or s.journal_id is null or s.status in ('void', 'cancelled') then raise exception '% cannot take a return.', s.number; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the return.'; end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, prices_include_vat, vat_registered, original_sale_id, notes, created_by, issued_at)
  values (s.org_id, 'credit_note', private.doc_number(s.org_id, 'credit_note'), 'open', s.customer_id, s.customer_name, s.customer_phone, s.customer_email,
    s.customer_tin, s.customer_address, s.location_id, s.channel, private.local_day(s.org_id, now()), s.prices_include_vat, s.vat_registered, s.id,
    trim(p_reason), m.id, now())
  returning * into cn;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into l from sale_lines where id = nullif(x->>'sale_line_id', '')::uuid and sale_id = s.id for update;
    if not found then raise exception 'A returned line is not on %.', s.number; end if;
    v_qty := round(private.num(x->>'qty'), 3);
    continue when coalesce(v_qty, 0) <= 0;
    if v_qty > l.qty - l.returned_qty + 0.0005 then raise exception 'Only % of % can still be returned.', private.fmt_qty(l.qty - l.returned_qty), l.description; end if;
    v_ratio := v_qty / l.qty;
    -- The last of a line takes whatever is left, so rounding never leaves a kobo behind.
    v_whole := v_qty >= l.qty - l.returned_qty - 0.0005;
    v_gross := case when v_whole then l.gross - coalesce((select sum(gross) from sale_lines where original_line_id = l.id), 0) else round(l.gross * v_ratio, 2) end;
    v_lnet := case when v_whole then l.net - coalesce((select sum(net) from sale_lines where original_line_id = l.id), 0) else round(l.net * v_ratio, 2) end;
    v_cost := case when not (p_restock and l.item_id is not null) then 0
                   when v_whole then coalesce(l.cost, 0) - coalesce((select sum(cost) from sale_lines where original_line_id = l.id), 0)
                   else round(coalesce(l.cost, 0) * v_ratio, 2) end;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount, vat_treatment,
      vat_rate, net, vat, gross, cost, revenue_account, original_line_id)
    values (cn.id, s.org_id, v_no, l.kind, l.item_id, l.description, v_qty, l.unit_label, l.unit_factor, l.unit_price, l.list_price, round(l.discount * v_ratio, 2),
      l.vat_treatment, l.vat_rate, v_lnet, v_gross - v_lnet, v_gross, v_cost, l.revenue_account, l.id);
    update sale_lines set returned_qty = returned_qty + v_qty where id = l.id;
    v_net := v_net + v_lnet; v_vat := v_vat + (v_gross - v_lnet);
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.kind = 'goods' then private.acct(s.org_id, 'sales_returns') else l.revenue_account end,
      'debit', v_lnet, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', l.description));
    if v_cost <> 0 then
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', private.inv_acct(l.item_id), 'debit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id),
        jsonb_build_object('code', private.acct(s.org_id, 'inventory_movement'), 'credit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id));
    end if;
  end loop;
  v_total := v_net + v_vat;
  if v_total <= 0 then raise exception 'Choose what is being returned.'; end if;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'debit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', 'VAT on ' || cn.number),
    jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'credit', v_total, 'location_id', s.location_id, 'party_type', 'customer',
      'party_id', s.customer_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', cn.number || ' for ' || s.number));
  update sales set subtotal = v_net, vat_total = v_vat, total = v_total where id = cn.id;
  j := private.post_entry(s.org_id, 'Credit note ' || cn.number || ' for ' || s.number || ' · ' || trim(p_reason), 'sale', cn.id, m.id, m.id, v_jl, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = cn.id;
  if p_restock then
    for l in select * from sale_lines where sale_id = cn.id and item_id is not null order by line_no loop
      v_wac := coalesce(l.cost, 0) / (l.qty * l.unit_factor);
      perform private.update_wac(l.item_id, l.qty * l.unit_factor, coalesce(l.cost, 0));
      perform private.add_movement(s.org_id, 'sale_return', l.item_id, s.location_id, l.qty * l.unit_factor, round(v_wac, 4), round(l.gross / (l.qty * l.unit_factor), 2),
        j.id, m.id, 'Return', now(), jsonb_build_object('note', cn.number || ' · ' || trim(p_reason)));
    end loop;
    update movements set sale_id = cn.id where journal_id = j.id;
  end if;
  -- The credit first settles what is still owed on the original sale.
  s := private.refresh_sale(s.id);
  v_due := s.total - s.amount_paid - s.credited;
  v_apply := least(greatest(v_due, 0), v_total);
  if v_apply > 0 then
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, s.id, s.org_id, v_apply, m.id);
    s := private.refresh_sale(s.id);
  end if;
  -- Then a refund in money, if asked; what is left stays with the customer as credit.
  v_refund := least(round(coalesce(private.num(p_refund->>'amount'), 0), 2), v_total - v_apply);
  if v_refund > 0 then
    v_bank := nullif(p_refund->>'bank_account_id', '')::uuid;
    if v_bank is null and coalesce(nullif(p_refund->>'method', ''), 'cash') = 'cash' then v_bank := (private.cash_drawer(s.org_id, s.location_id, m)).id; end if;
    if v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = s.org_id and active) then
      raise exception 'Choose the account the refund is paid from.';
    end if;
    if coalesce(nullif(p_refund->>'method', ''), 'cash') not in ('cash', 'transfer', 'cheque', 'other') then raise exception 'Unknown refund method.'; end if;
    insert into collections (org_id, number, direction, customer_id, sale_id, amount, method, status, bank_account_id, shift_id, reference, received_at,
      confirmed_by, confirmed_at, note, created_by)
    values (s.org_id, private.pay_no(s.org_id), 'out', s.customer_id, cn.id, v_refund, coalesce(nullif(p_refund->>'method', ''), 'cash'), 'confirmed', v_bank,
      (select id from shifts where cash_account_id = v_bank and status = 'open'), cn.number, now(), m.id, now(), 'Refund for ' || s.number, m.id)
    returning * into col;
    perform private.post_collection(col.id, m);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, s.org_id, v_refund, m.id);
  end if;
  update sales set credited = v_apply + v_refund, status = case when v_apply + v_refund >= v_total - 0.004 then 'paid' else 'open' end where id = cn.id;
  return jsonb_build_object('credit_note', private.sale_json(cn.id, private.can_see_costs(s.org_id)), 'refunded', v_refund, 'applied', v_apply,
    'store_credit', v_total - v_apply - v_refund);
end $$;

-- ---------------------------------------------------------------------------
-- 10. Shifts: float in, cash in and out, count at close
-- ---------------------------------------------------------------------------
create or replace function private.shift_json(p_shift uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(sh) || jsonb_build_object(
    'location_name', (select name from locations where id = sh.location_id),
    'cash_account_name', (select name from bank_accounts where id = sh.cash_account_id),
    'opened_by_name', (select display_name from members where id = sh.opened_by),
    'closed_by_name', (select display_name from members where id = sh.closed_by),
    'cash_balance', (select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join bank_accounts b on b.ledger_code = l.account_code and b.org_id = l.org_id
       where b.id = sh.cash_account_id),
    'sales_count', (select count(*) from sales s where s.shift_id = sh.id and s.status <> 'void' and s.doc_type = 'receipt'),
    'sales_total', (select coalesce(sum(s.total), 0) from sales s where s.shift_id = sh.id and s.status <> 'void' and s.doc_type = 'receipt'),
    'voids', (select count(*) from sales s where s.shift_id = sh.id and s.status = 'void'),
    'by_method', (select coalesce(jsonb_object_agg(k, amt), '{}'::jsonb) from (
        select c.method || case when c.status = 'pending' then '_pending' else '' end k, sum(case when c.direction = 'in' then c.amount else -c.amount end) amt
        from collections c where c.shift_id = sh.id and c.status in ('confirmed', 'pending') group by 1) x),
    'credit_sales', (select coalesce(sum(s.total - s.amount_paid - s.credited), 0) from sales s where s.shift_id = sh.id and s.status in ('open', 'partially_paid')),
    'movements', (select coalesce(jsonb_agg(to_jsonb(cm) || jsonb_build_object('by_name', (select display_name from members where id = cm.by_member)) order by cm.at), '[]'::jsonb)
      from cash_movements cm where cm.shift_id = sh.id))
  from shifts sh where sh.id = p_shift
$$;

-- The float counted at opening. When it is more than the drawer's books show, p_float_from names the account the cash came from;
-- a drawer's very first float with no source goes to opening balances to confirm (3999). Any other difference is over or short.
create or replace function public.open_shift(p_org uuid, p_location uuid, p_opening_count numeric, p_register text default null, p_cash_account uuid default null,
  p_float_from uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bank_accounts; fb public.bank_accounts; sh public.shifts; v_bal numeric; v_diff numeric; v_new boolean;
begin
  m := private.require(p_org, 'record_sales');
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Choose the branch.'; end if;
  if p_opening_count is null or p_opening_count < 0 then raise exception 'Count the float in the drawer.'; end if;
  if p_cash_account is not null then
    select * into b from bank_accounts where id = p_cash_account and org_id = p_org and kind = 'cash' and active;
    if not found then raise exception 'Choose a cash drawer.'; end if;
  else
    b := private.cash_drawer(p_org, p_location, m);
  end if;
  select * into sh from shifts where cash_account_id = b.id and status = 'open';
  if found then
    return private.shift_json(sh.id) || jsonb_build_object('already_open', true);
  end if;
  select coalesce(sum(debit - credit), 0), count(*) = 0 into v_bal, v_new from journal_lines where org_id = p_org and account_code = b.ledger_code;
  if p_float_from is not null then
    select * into fb from bank_accounts where id = p_float_from and org_id = p_org and active and id <> b.id;
    if not found then raise exception 'Choose the account the float came from.'; end if;
  end if;
  insert into shifts (org_id, number, location_id, cash_account_id, register, opened_by, opening_expected, opening_count)
  values (p_org, 'SHF-' || lpad(private.next_no(p_org, 'SHF', 1)::text, 5, '0'), p_location, b.id, coalesce(nullif(trim(p_register), ''), b.name), m.id,
    v_bal, round(p_opening_count, 2))
  returning * into sh;
  -- A float that differs from what the books say the drawer holds is posted now, so the shift starts from the count.
  v_diff := sh.opening_count - v_bal;
  if v_diff >= 0.01 and fb.id is not null then
    perform private.post_entry(p_org, 'Float for ' || sh.number || ' from ' || fb.name, 'shift', sh.id, m.id, null,
      private.reclass_pair(b.ledger_code, fb.ledger_code, v_diff, p_location, null), now(),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'count', 'counted', sh.opening_count, 'expected', v_bal, 'by', m.display_name))));
  elsif v_diff >= 0.01 and v_new then
    perform private.post_entry(p_org, 'Opening float in ' || b.name || ' · source to confirm', 'shift', sh.id, m.id, null,
      private.reclass_pair(b.ledger_code, private.acct(p_org, 'opening_equity'), v_diff, p_location, null), now(),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'count', 'counted', sh.opening_count, 'expected', v_bal, 'by', m.display_name))));
  elsif abs(v_diff) >= 0.01 then
    perform private.post_entry(p_org, case when v_diff < 0 then 'Drawer short at opening ' else 'Drawer over at opening ' end || sh.number, 'shift', sh.id, m.id, null,
      private.reclass_pair(b.ledger_code, private.acct(p_org, 'cash_over_short'), v_diff, p_location, null), now(),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'count', 'counted', sh.opening_count, 'expected', v_bal, 'by', m.display_name))));
  end if;
  return private.shift_json(sh.id);
end $$;

create or replace function public.cash_movement(p_shift uuid, p_kind text, p_amount numeric, p_reason text, p_account text default null, p_bank uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare sh public.shifts; m public.members; b public.bank_accounts; cm public.cash_movements; j public.journals; v_other text; v_amt numeric := round(p_amount, 2);
begin
  select * into sh from shifts where id = p_shift for update;
  if not found or sh.status <> 'open' then raise exception 'The shift is not open.'; end if;
  m := private.require(sh.org_id, 'record_sales');
  if p_kind not in ('pay_in', 'pay_out', 'drop') then raise exception 'Unknown cash movement.'; end if;
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter an amount.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say what the cash was for.'; end if;
  select * into b from bank_accounts where id = sh.cash_account_id;
  if p_kind = 'drop' then
    -- Cash taken from the drawer to the bank or the safe.
    select ledger_code into v_other from bank_accounts where id = p_bank and org_id = sh.org_id and active and id <> b.id;
    if v_other is null then raise exception 'Choose where the cash is going.'; end if;
  elsif p_kind = 'pay_out' then
    v_other := coalesce(nullif(p_account, ''), private.acct(sh.org_id, 'expenses_default'));
    if v_other !~ '^[56]' or not private.postable(sh.org_id, v_other) then raise exception 'Choose an expense account for the cash paid out.'; end if;
  else
    v_other := coalesce(nullif(p_account, ''), private.acct(sh.org_id, 'other_income'));
    if not private.postable(sh.org_id, v_other) or v_other ~ '^(1101|1102|2201|120)' then raise exception 'Choose where the cash came from.'; end if;
  end if;
  if p_kind <> 'pay_in' and v_amt > (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = sh.org_id and account_code = b.ledger_code) + 0.004 then
    raise exception 'The drawer does not hold that much cash.';
  end if;
  j := private.post_entry(sh.org_id, case p_kind when 'pay_in' then 'Cash in · ' when 'pay_out' then 'Cash paid out · ' else 'Cash taken from drawer · ' end || trim(p_reason),
    'shift', sh.id, m.id, null,
    case when p_kind = 'pay_in' then private.reclass_pair(b.ledger_code, v_other, v_amt, sh.location_id, null)
         else private.reclass_pair(v_other, b.ledger_code, v_amt, sh.location_id, null) end, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'till', 'shift', sh.number, 'by', m.display_name))));
  insert into cash_movements (org_id, shift_id, kind, amount, reason, account_code, bank_account_id, by_member, journal_id)
  values (sh.org_id, sh.id, p_kind, v_amt, trim(p_reason), case when p_kind <> 'drop' then v_other end, case when p_kind = 'drop' then p_bank end, m.id, j.id)
  returning * into cm;
  return to_jsonb(cm);
end $$;

create or replace function public.close_shift(p_shift uuid, p_counted numeric, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare sh public.shifts; m public.members; b public.bank_accounts; v_exp numeric; v_diff numeric; j public.journals;
begin
  select * into sh from shifts where id = p_shift for update;
  if not found or sh.status <> 'open' then raise exception 'The shift is not open.'; end if;
  m := private.require(sh.org_id, 'record_sales');
  if sh.opened_by <> m.id and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only the cashier who opened the shift or a manager can close it.';
  end if;
  if p_counted is null or p_counted < 0 then raise exception 'Count the cash in the drawer.'; end if;
  select * into b from bank_accounts where id = sh.cash_account_id;
  -- Expected cash is what the drawer's account holds: the float, cash sales net of change, refunds and cash in or out.
  select coalesce(sum(debit - credit), 0) into v_exp from journal_lines where org_id = sh.org_id and account_code = b.ledger_code;
  v_diff := round(p_counted, 2) - v_exp;
  if abs(v_diff) >= 0.01 then
    j := private.post_entry(sh.org_id, case when v_diff < 0 then 'Till short at close ' else 'Till over at close ' end || sh.number, 'shift', sh.id, m.id, null,
      private.reclass_pair(b.ledger_code, private.acct(sh.org_id, 'cash_over_short'), v_diff, sh.location_id, null), now(),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'count', 'counted', round(p_counted, 2), 'expected', v_exp, 'by', m.display_name))));
  end if;
  update shifts set status = 'closed', closed_by = m.id, closed_at = now(), expected_cash = v_exp, counted_cash = round(p_counted, 2), difference = v_diff,
    notes = nullif(trim(p_notes), ''), journal_id = j.id
  where id = sh.id returning * into sh;
  -- The day's takings feed the cash-against-stock check, unless someone already entered them by hand.
  insert into cash_takings (org_id, location_id, day, cash, pos, transfers, source, created_by)
  select sh.org_id, sh.location_id, private.local_day(sh.org_id, sh.opened_at),
    coalesce(sum(c.amount) filter (where c.method = 'cash'), 0),
    coalesce(sum(c.amount) filter (where c.method in ('card', 'pos')), 0),
    coalesce(sum(c.amount) filter (where c.method not in ('cash', 'card', 'pos', 'advance', 'wht_credit')), 0), 'till', m.id
  from collections c where c.shift_id = sh.id and c.direction = 'in' and c.status in ('confirmed', 'pending')
  on conflict (org_id, location_id, day) do update set cash = cash_takings.cash + excluded.cash, pos = cash_takings.pos + excluded.pos,
    transfers = cash_takings.transfers + excluded.transfers
  where cash_takings.source = 'till';
  return private.shift_json(sh.id);
end $$;

-- ---------------------------------------------------------------------------
-- 11. Orders (online shop, WhatsApp) and deliveries
-- ---------------------------------------------------------------------------
-- Confirming an order posts it like any sale and takes the stock. Money paid before then moves from advances.
create or replace function public.confirm_order(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale for update;
  if not found or s.doc_type <> 'order' then raise exception 'Order not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.journal_id is not null then raise exception '% is already confirmed.', s.number; end if;
  if s.status in ('cancelled', 'void') then raise exception '% was cancelled.', s.number; end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  update sales set issue_date = private.local_day(s.org_id, now()) where id = s.id;
  s := private.post_sale(s.id, m, now());
  s := private.refresh_sale(s.id);
  if s.delivery_method = 'delivery' and not exists (select 1 from deliveries where sale_id = s.id) then
    insert into deliveries (org_id, number, sale_id, address, contact_phone, created_by)
    values (s.org_id, 'DN-' || lpad(private.next_no(s.org_id, 'DN', 1)::text, 5, '0'), s.id, s.delivery_address, s.customer_phone, m.id);
  end if;
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- Cancels an order, a quote, or a till sale still waiting for its transfer. Cash taken at the till for it alone goes back
-- out of the drawer; any other money already paid stays with the customer as credit, to use or refund.
create or replace function public.cancel_order(p_sale uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; v_held numeric := 0; v_cash numeric := 0; a record;
begin
  select * into s from sales where id = p_sale for update;
  if not found or s.doc_type not in ('order', 'quote', 'receipt') then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.journal_id is not null then raise exception '% is confirmed. Void it instead.', s.number; end if;
  if s.status in ('cancelled', 'converted', 'void', 'expired', 'draft') then raise exception '% is %.', s.number, s.status; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason.'; end if;
  for a in select ca.amount, col.id cid, col.method, col.amount col_amount, col.journal_id cj,
      (select count(*) from collection_allocations x where x.collection_id = col.id) n
    from collection_allocations ca join collections col on col.id = ca.collection_id
    where ca.sale_id = s.id and col.status = 'confirmed' and col.journal_id is not null loop
    if a.method in ('cash', 'advance') and a.n = 1 and a.col_amount = a.amount then
      perform private.reverse_entry(a.cj, m.id, s.number || ' cancelled', null);
      update collections set status = 'reversed' where id = a.cid;
      if a.method = 'cash' then v_cash := v_cash + a.amount; end if;
    else
      v_held := v_held + a.amount;
    end if;
  end loop;
  delete from collection_allocations where sale_id = s.id;
  update payment_requests set status = 'cancelled' where sale_id = s.id and status in ('creating', 'pending');
  update sales set status = 'cancelled', void_reason = trim(p_reason), voided_by = m.id, voided_at = now() where id = s.id;
  return jsonb_build_object('status', 'cancelled', 'number', s.number, 'customer_credit', v_held, 'cash_back', v_cash);
end $$;

create or replace function public.save_delivery(p_org uuid, p_delivery jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; d public.deliveries; v_id uuid := nullif(p_delivery->>'id', '')::uuid; s public.sales; v_status text := nullif(p_delivery->>'status', '');
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_delivery->>'driver_id', '') is not null and not exists (select 1 from members where id = (p_delivery->>'driver_id')::uuid and org_id = p_org) then
    raise exception 'Choose a driver from the team.';
  end if;
  if nullif(p_delivery->>'vehicle_location_id', '') is not null
     and not exists (select 1 from locations where id = (p_delivery->>'vehicle_location_id')::uuid and org_id = p_org and kind = 'van') then
    raise exception 'Choose one of the business''s vans.';
  end if;
  if v_id is null then
    select * into s from sales where id = nullif(p_delivery->>'sale_id', '')::uuid and org_id = p_org;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') or s.status in ('void', 'cancelled', 'draft') then raise exception 'Choose the sale being delivered.'; end if;
    insert into deliveries (org_id, number, sale_id, driver_id, vehicle_location_id, address, contact_phone, scheduled_for, notes, created_by)
    values (p_org, 'DN-' || lpad(private.next_no(p_org, 'DN', 1)::text, 5, '0'), s.id, nullif(p_delivery->>'driver_id', '')::uuid,
      nullif(p_delivery->>'vehicle_location_id', '')::uuid, coalesce(nullif(trim(p_delivery->>'address'), ''), s.delivery_address, s.customer_address),
      coalesce(private.clean_phone(p_delivery->>'contact_phone'), s.customer_phone), nullif(p_delivery->>'scheduled_for', '')::date,
      nullif(trim(p_delivery->>'notes'), ''), m.id)
    returning * into d;
  else
    select * into d from deliveries where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Delivery not found.'; end if;
    if v_status is not null and v_status not in ('pending', 'dispatched', 'delivered', 'failed', 'cancelled') then raise exception 'Unknown delivery status.'; end if;
    if d.status in ('delivered', 'cancelled') and v_status is not null and v_status <> d.status then raise exception '% is already %.', d.number, d.status; end if;
    if v_status = 'delivered' and coalesce(nullif(trim(p_delivery->>'received_by'), ''), d.received_by, '') = '' then
      raise exception 'Enter the name of the person who received the goods.';
    end if;
    update deliveries set status = coalesce(v_status, status),
      driver_id = case when p_delivery ? 'driver_id' then nullif(p_delivery->>'driver_id', '')::uuid else driver_id end,
      vehicle_location_id = case when p_delivery ? 'vehicle_location_id' then nullif(p_delivery->>'vehicle_location_id', '')::uuid else vehicle_location_id end,
      address = coalesce(nullif(trim(p_delivery->>'address'), ''), address),
      contact_phone = coalesce(private.clean_phone(p_delivery->>'contact_phone'), contact_phone),
      scheduled_for = case when p_delivery ? 'scheduled_for' then nullif(p_delivery->>'scheduled_for', '')::date else scheduled_for end,
      dispatched_at = case when v_status in ('dispatched', 'delivered') and dispatched_at is null then now() else dispatched_at end,
      delivered_at = case when v_status = 'delivered' then now() else delivered_at end,
      received_by = coalesce(nullif(trim(p_delivery->>'received_by'), ''), received_by),
      proof_path = coalesce(nullif(p_delivery->>'proof_path', ''), proof_path),
      notes = case when p_delivery ? 'notes' then nullif(trim(p_delivery->>'notes'), '') else notes end
    where id = d.id returning * into d;
  end if;
  return to_jsonb(d);
end $$;

-- ---------------------------------------------------------------------------
-- 12. The online shop (no sign-in) and public documents
-- ---------------------------------------------------------------------------
create or replace function public.shop_catalog(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  return jsonb_build_object(
    'shop', jsonb_build_object('slug', o.shop_slug, 'name', o.name, 'title', coalesce(o.shop_title, o.name), 'note', o.shop_note, 'whatsapp', o.shop_whatsapp,
      'phone', o.phone, 'address', o.address, 'logo_path', o.logo_path, 'delivery_fee', o.shop_delivery_fee, 'pickup', o.shop_pickup, 'delivery', o.shop_delivery,
      'vat_registered', o.vat_registered, 'prices_include_vat', o.prices_include_vat),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'category', i.category, 'brand', i.brand, 'description', i.description,
        'price', i.price, 'unit', i.selling_unit, 'photo_path', i.photo_path,
        'available', coalesce(st.qty, 0) > 0,
        'stock', case when o.shop_show_stock then greatest(floor(coalesce(st.qty, 0)), 0) end) order by i.category nulls last, i.name), '[]'::jsonb)
      from items i
      left join (select item_id, sum(qty) qty from stock_levels where org_id = o.id and (o.shop_location_id is null or location_id = o.shop_location_id) group by item_id) st
        on st.item_id = i.id
      where i.org_id = o.id and not i.archived and i.price > 0 and i.item_type in ('merchandise', 'finished_good')
        and (o.shop_categories is null or i.category = any(o.shop_categories))));
end $$;

-- p_order: {customer:{name, phone, email}, lines:[{item_id, qty}], delivery_method: 'pickup'|'delivery', address, note, client_uuid}
create or replace function public.shop_place_order(p_slug text, p_order jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_phone text := private.clean_phone(p_order->'customer'->>'phone'); v_cust uuid; s public.sales; x jsonb; v_lines jsonb := '[]'::jsonb;
  v_loc uuid; v_method text := coalesce(nullif(p_order->>'delivery_method', ''), 'pickup'); m public.members; v_avail numeric; it public.items;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  if nullif(p_order->>'client_uuid', '') is not null then
    select * into s from sales where client_uuid = (p_order->>'client_uuid')::uuid and org_id = o.id;
    if found then return jsonb_build_object('number', s.number, 'token', s.public_token, 'total', s.total, 'duplicate', true); end if;
  end if;
  if coalesce(trim(p_order->'customer'->>'name'), '') = '' then raise exception 'Enter your name.'; end if;
  if v_phone is null or length(v_phone) < 11 then raise exception 'Enter a phone number we can reach you on.'; end if;
  if v_method not in ('pickup', 'delivery') or (v_method = 'pickup' and not o.shop_pickup) or (v_method = 'delivery' and not o.shop_delivery) then
    raise exception 'Choose pickup or delivery.';
  end if;
  if v_method = 'delivery' and coalesce(trim(p_order->>'address'), '') = '' then raise exception 'Enter the delivery address.'; end if;
  -- Slow down floods: five orders an hour from one phone, sixty every ten minutes for the shop.
  if (select count(*) from shop_hits where org_id = o.id and phone = v_phone and at > now() - interval '1 hour') >= 5
     or (select count(*) from shop_hits where org_id = o.id and at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many orders just now. Please try again in a little while, or message the shop.';
  end if;
  if jsonb_typeof(p_order->'lines') <> 'array' or jsonb_array_length(p_order->'lines') = 0 then raise exception 'Your cart is empty.'; end if;
  if jsonb_array_length(p_order->'lines') > 50 then raise exception 'Up to 50 different items per order.'; end if;
  insert into shop_hits (org_id, phone) values (o.id, v_phone);
  v_loc := coalesce(o.shop_location_id, (select id from locations where org_id = o.id order by is_main desc, created_at limit 1));
  for x in select * from jsonb_array_elements(p_order->'lines') loop
    select * into it from items where id = nullif(x->>'item_id', '')::uuid and org_id = o.id and not archived and price > 0 and item_type in ('merchandise', 'finished_good');
    if not found then raise exception 'An item in your cart is no longer for sale.'; end if;
    if coalesce(private.num(x->>'qty'), 0) <= 0 or private.num(x->>'qty') > 10000 then raise exception 'Check the quantity of %.', it.name; end if;
    select coalesce(sum(qty), 0) into v_avail from stock_levels where item_id = it.id and (o.shop_location_id is null or location_id = o.shop_location_id);
    if v_avail < private.num(x->>'qty') then
      raise exception 'Only % of % left.', private.fmt_qty(greatest(v_avail, 0)), it.name;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'qty', round(private.num(x->>'qty'), 3)));
  end loop;
  select id into v_cust from customers where org_id = o.id and phone = v_phone and not archived;
  if v_cust is null then
    insert into customers (org_id, name, kind, phone, email, address, whatsapp_opt_in, notes)
    values (o.id, left(trim(p_order->'customer'->>'name'), 120), 'individual', v_phone, nullif(lower(trim(p_order->'customer'->>'email')), ''),
      nullif(trim(p_order->>'address'), ''), true, 'Added by an online order')
    returning id into v_cust;
  end if;
  -- The shop writes the order, not a staff member: it carries no permissions and no author until someone confirms it.
  s := private.create_sale(o.id, jsonb_build_object('doc_type', 'order', 'status', 'draft', 'customer_id', v_cust, 'location_id', v_loc, 'channel', 'online',
    'retail_only', true, 'lines', v_lines, 'delivery_fee', case when v_method = 'delivery' then o.shop_delivery_fee else 0 end, 'delivery_method', v_method,
    'delivery_address', nullif(trim(p_order->>'address'), ''), 'notes', left(nullif(trim(p_order->>'note'), ''), 500),
    'client_uuid', nullif(p_order->>'client_uuid', '')), m);
  perform private.notify_perm(o.id, 'record_sales', 'order', 'New online order ' || s.number,
    s.customer_name || ' · ₦' || to_char(s.total, 'FM999,999,999,990.00') || case when v_method = 'delivery' then ' · delivery' else ' · pickup' end,
    '/sell/orders', 'order-' || s.id, null, v_loc);
  return jsonb_build_object('number', s.number, 'token', s.public_token, 'total', s.total, 'vat', s.vat_total, 'status', s.status);
end $$;

-- A shared receipt, invoice, quote, order or credit note, opened by its link. No costs and no staff details.
create or replace function public.public_document(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v jsonb;
begin
  if p_token is null or length(p_token) < 24 then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if s.viewed_at is null then update sales set viewed_at = now() where id = s.id; end if;
  v := private.sale_json(s.id, false);
  return (v - 'created_by' - 'voided_by' - 'shift_id' - 'device_id' - 'client_uuid' - 'journal_id' - 'journal_ref' - 'org_id' - 'cost_total' - 'location_id'
    - 'price_list_id' - 'created_by_name' - 'deliveries' - 'refunds' - 'void_reason' - 'offline' - 'customer_credit')
    || jsonb_build_object(
      'lines', (select coalesce(jsonb_agg(l - 'cost' - 'item_id' - 'revenue_account' - 'list_price' - 'original_line_id' - 'returned_qty' - 'sale_id' - 'id'
          order by (l->>'line_no')::int), '[]'::jsonb) from jsonb_array_elements(v->'lines') l),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p->>'method', 'amount', p->'amount', 'status', p->>'status', 'received_at', p->'received_at')), '[]'::jsonb)
        from jsonb_array_elements(v->'payments') p where p->>'status' in ('confirmed', 'pending')),
      'requests', (select coalesce(jsonb_agg(r - 'id'), '[]'::jsonb) from jsonb_array_elements(v->'requests') r where r->>'status' = 'pending'),
      'shop_slug', (select shop_slug from orgs where id = s.org_id and shop_enabled));
end $$;

-- Shop and till settings.
create or replace function public.update_sales_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_slug text;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes these settings.' using errcode = '42501'; end if;
  if p_patch ? 'shop_slug' then
    v_slug := nullif(lower(trim(p_patch->>'shop_slug')), '');
    if v_slug is not null and v_slug !~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$' then
      raise exception 'Use 3 to 40 letters, numbers or dashes for the shop link.';
    end if;
    if v_slug is not null and exists (select 1 from orgs where shop_slug = v_slug and id <> p_org) then raise exception 'That shop link is taken.'; end if;
  end if;
  if nullif(p_patch->>'shop_location_id', '') is not null and not exists (select 1 from locations where id = (p_patch->>'shop_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose the branch the shop sells from.';
  end if;
  if private.num(p_patch->>'max_cashier_discount_pct') not between 0 and 100 then raise exception 'The cashier discount allowance is a percentage from 0 to 100.'; end if;
  update orgs set
    max_cashier_discount_pct = coalesce(private.num(p_patch->>'max_cashier_discount_pct'), max_cashier_discount_pct),
    receipt_footer = case when p_patch ? 'receipt_footer' then left(nullif(trim(p_patch->>'receipt_footer'), ''), 300) else receipt_footer end,
    shop_slug = case when p_patch ? 'shop_slug' then v_slug else shop_slug end,
    shop_enabled = coalesce((p_patch->>'shop_enabled')::boolean, shop_enabled),
    shop_title = case when p_patch ? 'shop_title' then left(nullif(trim(p_patch->>'shop_title'), ''), 80) else shop_title end,
    shop_note = case when p_patch ? 'shop_note' then left(nullif(trim(p_patch->>'shop_note'), ''), 500) else shop_note end,
    shop_whatsapp = case when p_patch ? 'shop_whatsapp' then private.clean_phone(p_patch->>'shop_whatsapp') else shop_whatsapp end,
    shop_location_id = case when p_patch ? 'shop_location_id' then nullif(p_patch->>'shop_location_id', '')::uuid else shop_location_id end,
    shop_delivery_fee = case when p_patch ? 'shop_delivery_fee' then round(greatest(coalesce(private.num(p_patch->>'shop_delivery_fee'), 0), 0), 2) else shop_delivery_fee end,
    shop_pickup = coalesce((p_patch->>'shop_pickup')::boolean, shop_pickup),
    shop_delivery = coalesce((p_patch->>'shop_delivery')::boolean, shop_delivery),
    shop_show_stock = coalesce((p_patch->>'shop_show_stock')::boolean, shop_show_stock),
    shop_categories = case when p_patch ? 'shop_categories' then
      (select nullif(array_agg(value), '{}') from jsonb_array_elements_text(case when jsonb_typeof(p_patch->'shop_categories') = 'array' then p_patch->'shop_categories' else '[]'::jsonb end))
      else shop_categories end
  where id = p_org returning * into o;
  if o.shop_enabled and o.shop_slug is null then raise exception 'Choose a link for the shop before opening it.'; end if;
  if o.shop_enabled and not o.shop_pickup and not o.shop_delivery then raise exception 'Offer pickup, delivery or both.'; end if;
  return jsonb_build_object('max_cashier_discount_pct', o.max_cashier_discount_pct, 'receipt_footer', o.receipt_footer, 'shop_slug', o.shop_slug,
    'shop_enabled', o.shop_enabled, 'shop_title', o.shop_title, 'shop_note', o.shop_note, 'shop_whatsapp', o.shop_whatsapp, 'shop_location_id', o.shop_location_id,
    'shop_delivery_fee', o.shop_delivery_fee, 'shop_pickup', o.shop_pickup, 'shop_delivery', o.shop_delivery, 'shop_show_stock', o.shop_show_stock,
    'shop_categories', o.shop_categories);
end $$;

-- ---------------------------------------------------------------------------
-- 13. Reading
-- ---------------------------------------------------------------------------
create or replace function public.get_sale(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  perform private.require(s.org_id, null);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- p_filter: {doc_type (comma list), status (comma list), customer_id, from, to, location_id, shift_id, q, limit}
create or replace function public.get_sales(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_from date := nullif(p_filter->>'from', '')::date; v_to date := nullif(p_filter->>'to', '')::date;
  v_q text := nullif(lower(trim(p_filter->>'q')), ''); v_lim int := least(greatest(coalesce((p_filter->>'limit')::int, 300), 1), 2000); v_today date;
begin
  m := private.require(p_org, null);
  v_cost := private.can_see_costs(p_org);
  v_today := private.local_day(p_org, now());
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(r order by (r->>'created_at')::timestamptz desc), '[]'::jsonb) from (
      select jsonb_build_object('id', s.id, 'doc_type', s.doc_type, 'number', s.number, 'status', s.status, 'customer_id', s.customer_id,
        'customer_name', s.customer_name, 'customer_phone', s.customer_phone, 'customer_email', s.customer_email, 'location_id', s.location_id, 'channel', s.channel,
        'issue_date', s.issue_date, 'due_date', s.due_date, 'total', s.total, 'subtotal', s.subtotal, 'vat_total', s.vat_total, 'discount_total', s.discount_total,
        'amount_paid', s.amount_paid, 'credited', s.credited, 'confirmed', s.journal_id is not null, 'delivery_method', s.delivery_method,
        'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                        when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
        'cost_total', case when v_cost then (select sum(cost) from sale_lines where sale_id = s.id) end, 'created_at', s.created_at,
        'created_by_name', (select display_name from members where id = s.created_by),
        'shift_id', s.shift_id, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at, 'public_token', s.public_token, 'reference', s.reference,
        'original_sale_id', s.original_sale_id,
        'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
        'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(v_today - s.due_date, 0) end) r
      from sales s
      where s.org_id = p_org
        and (nullif(p_filter->>'doc_type', '') is null or s.doc_type = any(string_to_array(p_filter->>'doc_type', ',')))
        and (nullif(p_filter->>'status', '') is null or s.status = any(string_to_array(p_filter->>'status', ',')))
        and (nullif(p_filter->>'customer_id', '') is null or s.customer_id = (p_filter->>'customer_id')::uuid)
        and (nullif(p_filter->>'location_id', '') is null or s.location_id = (p_filter->>'location_id')::uuid)
        and (nullif(p_filter->>'shift_id', '') is null or s.shift_id = (p_filter->>'shift_id')::uuid)
        and (v_from is null or s.issue_date >= v_from) and (v_to is null or s.issue_date <= v_to)
        and (v_q is null or lower(s.number) like '%' || v_q || '%' or lower(s.customer_name) like '%' || v_q || '%' or coalesce(s.customer_phone, '') like '%' || v_q || '%'
             or lower(coalesce(s.reference, '')) like '%' || v_q || '%')
      order by s.created_at desc limit v_lim) x),
    'pending_payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'reference', c.reference,
        'customer_id', c.customer_id, 'customer_name', cu.name, 'received_at', c.received_at, 'note', c.note, 'bank_account_id', c.bank_account_id,
        'created_by_name', (select display_name from members where id = c.created_by),
        'sales', (select jsonb_agg(jsonb_build_object('id', s2.id, 'number', s2.number, 'amount', a.amount)) from collection_allocations a join sales s2 on s2.id = a.sale_id
                  where a.collection_id = c.id)) order by c.received_at), '[]'::jsonb)
      from collections c join customers cu on cu.id = c.customer_id where c.org_id = p_org and c.status = 'pending'),
    'orders_waiting', (select count(*) from sales where org_id = p_org and doc_type = 'order' and journal_id is null and status not in ('cancelled', 'void')));
end $$;

create or replace function public.get_customers(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_today date;
begin
  m := private.require(p_org, null);
  v_today := private.local_day(p_org, now());
  return jsonb_build_object(
    'customers', (select coalesce(jsonb_agg(to_jsonb(c) - 'org_id' || jsonb_build_object(
        'balance', coalesce(b.bal, 0), 'receivable', coalesce(b.ar, 0), 'advance', coalesce(b.adv, 0),
        'credit_notes', coalesce(cn.open_credit, 0),
        'open_count', coalesce(o.n, 0), 'overdue', coalesce(o.overdue, 0), 'oldest_due', o.oldest,
        'last_sale', o.last_sale, 'sales_12m', coalesce(o.sales_12m, 0),
        'price_list_name', (select name from price_lists where id = c.price_list_id)
      ) order by c.is_walk_in desc, c.name), '[]'::jsonb)
      from customers c
      left join (select party_id, sum(case when account_code in ('1101', '1102') then debit - credit else 0 end) ar,
          sum(case when account_code = '2107' then credit - debit else 0 end) adv, sum(debit - credit) bal
        from journal_lines where org_id = p_org and party_type = 'customer' and account_code in ('1101', '1102', '2107') group by party_id) b on b.party_id = c.id
      left join (select customer_id,
          count(*) filter (where status in ('open', 'partially_paid')) n,
          sum(total - amount_paid - credited) filter (where status in ('open', 'partially_paid') and due_date < v_today) overdue,
          min(due_date) filter (where status in ('open', 'partially_paid')) oldest,
          max(issue_date) filter (where status not in ('void', 'draft', 'cancelled', 'converted')) last_sale,
          sum(total) filter (where status not in ('void', 'draft', 'converted', 'cancelled', 'pending') and issue_date > v_today - 365) sales_12m
        from sales where org_id = p_org and doc_type in ('receipt', 'invoice', 'order') group by customer_id) o on o.customer_id = c.id
      left join (select customer_id, sum(total - credited) open_credit from sales where org_id = p_org and doc_type = 'credit_note' and status = 'open' group by customer_id) cn
        on cn.customer_id = c.id
      where c.org_id = p_org and not c.archived),
    'price_lists', (select coalesce(jsonb_agg(to_jsonb(pl) - 'org_id' || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(pli) - 'org_id' - 'price_list_id'), '[]'::jsonb)
        from price_list_items pli where pli.price_list_id = pl.id)) order by pl.name), '[]'::jsonb) from price_lists pl where pl.org_id = p_org));
end $$;

-- A customer's statement: every sale, payment and credit with a running balance, and what is still open.
create or replace function public.customer_statement(p_customer uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.customers; m public.members; v_from date; v_to date; v_open numeric;
begin
  select * into c from customers where id = p_customer;
  if not found then raise exception 'Customer not found.'; end if;
  m := private.require(c.org_id, null);
  v_to := coalesce(p_to, private.local_day(c.org_id, now()));
  v_from := coalesce(p_from, v_to - 89);
  select coalesce(sum(l.debit - l.credit), 0) into v_open
  from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = c.org_id and l.party_type = 'customer' and l.party_id = c.id and l.account_code in ('1101', '1102', '2107') and j.entry_date < v_from;
  return jsonb_build_object('customer', to_jsonb(c) - 'org_id', 'from', v_from, 'to', v_to, 'opening', v_open,
    'org', (select jsonb_build_object('name', name, 'address', address, 'phone', phone, 'email', email, 'tin', tin, 'logo_path', logo_path) from orgs where id = c.org_id),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', x.entry_date, 'ref', x.ref, 'memo', x.memo, 'debit', x.d, 'credit', x.c,
        'balance', v_open + x.run) order by x.entry_date, x.je_no), '[]'::jsonb)
      from (select y.*, sum(y.d - y.c) over (order by y.entry_date, y.je_no) run from (
              select j.entry_date, j.je_no, j.ref, j.memo, sum(l.debit) d, sum(l.credit) c
              from journal_lines l join journals j on j.id = l.journal_id
              where l.org_id = c.org_id and l.party_type = 'customer' and l.party_id = c.id and l.account_code in ('1101', '1102', '2107')
                and j.entry_date between v_from and v_to
              group by j.entry_date, j.je_no, j.ref, j.memo having sum(l.debit) <> sum(l.credit)) y) x),
    'closing', (select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join journals j on j.id = l.journal_id
      where l.org_id = c.org_id and l.party_type = 'customer' and l.party_id = c.id and l.account_code in ('1101', '1102', '2107') and j.entry_date <= v_to),
    'open_items', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'number', s.number, 'issue_date', s.issue_date, 'due_date', s.due_date, 'total', s.total,
        'balance', s.total - s.amount_paid - s.credited, 'days_overdue', greatest(v_to - coalesce(s.due_date, s.issue_date), 0), 'token', s.public_token) order by s.due_date), '[]'::jsonb)
      from sales s where s.customer_id = c.id and s.status in ('open', 'partially_paid')));
end $$;

create or replace function public.get_shifts(p_org uuid, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return (select coalesce(jsonb_agg(private.shift_json(sh.id) order by sh.opened_at desc), '[]'::jsonb) from shifts sh
          where sh.org_id = p_org and (sh.status = 'open' or sh.opened_at > now() - make_interval(days => greatest(coalesce(p_days, 14), 1))));
end $$;

create or replace function public.get_deliveries(p_org uuid, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return (select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('sale_number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
      'balance', s.total - s.amount_paid - s.credited, 'sale_status', s.status, 'public_token', s.public_token,
      'driver_name', (select display_name from members where id = d.driver_id), 'vehicle_name', (select name from locations where id = d.vehicle_location_id),
      'lines', (select jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label) order by l.line_no)
                from sale_lines l where l.sale_id = s.id and l.kind <> 'delivery'))
    order by d.created_at desc), '[]'::jsonb)
    from deliveries d join sales s on s.id = d.sale_id
    where d.org_id = p_org and (d.status in ('pending', 'dispatched') or d.created_at > now() - make_interval(days => greatest(coalesce(p_days, 30), 1))));
end $$;

-- What the till needs on opening: the open shift at this branch, accounts money can go into, price lists and settings.
create or replace function public.get_till(p_org uuid, p_location uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, 'record_sales');
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'shift', (select private.shift_json(sh.id) from shifts sh where sh.org_id = p_org and sh.location_id = p_location and sh.status = 'open'
              order by (sh.opened_by = m.id) desc, sh.opened_at desc limit 1),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'bank_name', b.bank_name, 'account_number', b.account_number,
        'account_name', b.account_name, 'provider', b.provider, 'location_id', b.location_id) order by b.kind, b.name), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active),
    'price_lists', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.name, 'kind', pl.kind, 'rule', pl.rule, 'pct', pl.pct,
        'items', (select coalesce(jsonb_agg(jsonb_build_object('item_id', pli.item_id, 'min_qty', pli.min_qty, 'price', pli.price)), '[]'::jsonb)
                  from price_list_items pli where pli.price_list_id = pl.id)) order by pl.name), '[]'::jsonb)
      from price_lists pl where pl.org_id = p_org and pl.active),
    'settings', jsonb_build_object('max_cashier_discount_pct', o.max_cashier_discount_pct, 'receipt_footer', o.receipt_footer, 'vat_registered', o.vat_registered,
      'prices_include_vat', o.prices_include_vat, 'name', o.name, 'address', o.address, 'phone', o.phone, 'tin', o.tin, 'logo_path', o.logo_path,
      'can_edit_prices', private.perm_of(m, 'edit_prices') or private.perm_of(m, 'approve_adjustments'),
      'can_confirm', private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments'),
      'can_give_credit', private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments'),
      'shop_slug', o.shop_slug, 'shop_enabled', o.shop_enabled));
end $$;

-- ---------------------------------------------------------------------------
-- 14. The phone app's quick sale now makes a till receipt
-- ---------------------------------------------------------------------------
-- record_sale (phone, voice and queued offline sales) keeps its signature and answer. It now writes a receipt, so revenue and
-- output VAT post with the stock. It is paid in cash into the branch drawer, unless the note says the customer paid by transfer,
-- in which case the transfer waits for confirmation. A price typed by someone who cannot edit prices is noted and not used.
create or replace function public.record_sale(
  p_org uuid, p_item uuid, p_location uuid, p_qty numeric, p_unit_price numeric default null,
  p_channel text default 'Phone app', p_voice boolean default false, p_note text default null,
  p_voice_clean boolean default true, p_client_uuid uuid default null, p_device text default null,
  p_offline boolean default false, p_recorded_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; s public.sales; v_review text; mv public.movements; v_list numeric; v_can_price boolean; v_note text;
begin
  m := private.require(p_org, 'record_sales');
  if p_client_uuid is not null then
    select * into s from sales where client_uuid = p_client_uuid;
    if found then
      select * into mv from movements where sale_id = s.id order by created_at limit 1;
      return jsonb_build_object('duplicate', true, 'movement_id', mv.id, 'sale_id', s.id, 'number', s.number);
    end if;
    select * into mv from movements where client_uuid = p_client_uuid;
    if found then return jsonb_build_object('duplicate', true, 'movement_id', mv.id); end if;
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a quantity above zero.'; end if;
  select * into o from orgs where id = p_org;
  select price into v_list from items where id = p_item and org_id = p_org;
  if v_list is null then raise exception 'Item not found.'; end if;
  v_can_price := private.perm_of(m, 'edit_prices') or private.perm_of(m, 'approve_adjustments');
  v_note := nullif(trim(coalesce(p_note, '')), '');
  if p_unit_price is not null and abs(p_unit_price - v_list) > 0.004 and not v_can_price then
    v_note := concat_ws(' · ', v_note, 'Price ' || to_char(p_unit_price, 'FM999,999,990.00') || ' entered; list price used');
  end if;
  if p_voice then
    v_review := case when m.voice_confirmed >= o.voice_trust_threshold then 'reviewed' else 'pending' end;
    if p_voice_clean then update members set voice_confirmed = voice_confirmed + 1 where id = m.id; end if;
  end if;
  s := private.create_sale(p_org, jsonb_build_object('doc_type', 'receipt', 'status', 'issue', 'location_id', p_location, 'client_uuid', p_client_uuid,
    'channel', case when p_voice then 'voice' else 'phone' end, 'recorded_at', p_recorded_at, 'device', p_device, 'offline', p_offline, 'notes', v_note,
    'pay_in_full', case when lower(coalesce(p_note, '')) ~ '(transfer|trf|bank|paid to account)' then 'transfer' else 'cash' end,
    'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', p_item, 'qty', p_qty, 'unit', 'selling',
      'unit_price', case when p_unit_price is not null and abs(p_unit_price - v_list) > 0.004 and v_can_price then p_unit_price end)))), m);
  select * into mv from movements where sale_id = s.id order by created_at limit 1;
  if v_review is not null then update movements set review_status = v_review where sale_id = s.id; end if;
  if p_client_uuid is not null and mv.id is not null then
    update movements set client_uuid = p_client_uuid where id = mv.id and client_uuid is null;
  end if;
  return jsonb_build_object('movement_id', mv.id, 'sale_id', s.id, 'number', s.number, 'journal_ref', (select ref from journals where id = s.journal_id),
    'review_status', v_review, 'voice_confirmed', m.voice_confirmed + case when p_voice and p_voice_clean then 1 else 0 end,
    'voice_threshold', o.voice_trust_threshold, 'total', s.total, 'vat', s.vat_total, 'status', s.status);
end $$;

-- Overnight: quotes past their valid-until date expire, and the shop's flood log is trimmed.
create or replace function private.sales_nightly() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  update public.sales s set status = 'expired'
  where s.doc_type = 'quote' and s.status = 'open' and s.due_date < private.local_day(s.org_id, now());
  delete from public.shop_hits where at < now() - interval '1 day';
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-sales-nightly';
    perform cron.schedule('counta-sales-nightly', '15 0 * * *', 'select private.sales_nightly()');
  end if;
end $$;

grant execute on function public.save_price_list(uuid, jsonb), public.save_customer(uuid, jsonb), public.till_checkout(uuid, jsonb),
  public.save_sale_doc(uuid, jsonb), public.issue_invoice(uuid, date), public.convert_quote(uuid), public.record_payment(uuid, jsonb),
  public.confirm_payment(uuid, uuid, boolean, text), public.apply_customer_credit(uuid, numeric), public.refund_customer(uuid, uuid, numeric, text, uuid, text),
  public.void_sale(uuid, text), public.return_sale(uuid, jsonb, jsonb, text, boolean), public.open_shift(uuid, uuid, numeric, text, uuid, uuid),
  public.cash_movement(uuid, text, numeric, text, text, uuid), public.close_shift(uuid, numeric, text), public.confirm_order(uuid), public.cancel_order(uuid, text),
  public.save_delivery(uuid, jsonb), public.update_sales_settings(uuid, jsonb), public.get_sale(uuid), public.get_sales(uuid, jsonb), public.get_customers(uuid),
  public.customer_statement(uuid, date, date), public.get_shifts(uuid, int), public.get_deliveries(uuid, int), public.get_till(uuid, uuid) to authenticated;
revoke execute on function public.save_price_list(uuid, jsonb), public.save_customer(uuid, jsonb), public.till_checkout(uuid, jsonb),
  public.save_sale_doc(uuid, jsonb), public.issue_invoice(uuid, date), public.convert_quote(uuid), public.record_payment(uuid, jsonb),
  public.confirm_payment(uuid, uuid, boolean, text), public.apply_customer_credit(uuid, numeric), public.refund_customer(uuid, uuid, numeric, text, uuid, text),
  public.void_sale(uuid, text), public.return_sale(uuid, jsonb, jsonb, text, boolean), public.open_shift(uuid, uuid, numeric, text, uuid, uuid),
  public.cash_movement(uuid, text, numeric, text, text, uuid), public.close_shift(uuid, numeric, text), public.confirm_order(uuid), public.cancel_order(uuid, text),
  public.save_delivery(uuid, jsonb), public.update_sales_settings(uuid, jsonb), public.get_sale(uuid), public.get_sales(uuid, jsonb), public.get_customers(uuid),
  public.customer_statement(uuid, date, date), public.get_shifts(uuid, int), public.get_deliveries(uuid, int), public.get_till(uuid, uuid) from public, anon;
grant execute on function public.shop_catalog(text), public.shop_place_order(text, jsonb), public.public_document(text) to anon, authenticated;
revoke execute on function private.list_price(uuid, uuid, uuid, numeric), private.walk_in(uuid), private.clean_phone(text),
  private.upsert_customer(uuid, jsonb, public.members), private.customer_balance(uuid, uuid), private.customer_advance(uuid, uuid), private.doc_prefix(text),
  private.doc_number(uuid, text), private.pay_no(uuid), private.require_open_day(uuid, date), private.posting_time(uuid, date, timestamptz),
  private.write_lines(public.sales, jsonb, numeric, public.members), private.post_sale(uuid, public.members, timestamptz), private.refresh_sale(uuid),
  private.post_collection(uuid, public.members), private.add_collection(uuid, uuid, numeric, text, jsonb, public.members, text, uuid[]),
  private.use_customer_credit(uuid, numeric, public.members), private.cash_drawer(uuid, uuid, public.members),
  private.create_sale(uuid, jsonb, public.members), private.sale_json(uuid, boolean), private.shift_json(uuid), private.sales_nightly()
  from public, anon, authenticated;
