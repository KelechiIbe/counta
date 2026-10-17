-- Counta · Payables and fixed assets: bills (entered, from stock receipts, from Prism), withholding tax, paying vendors from the
-- wallet or a bank account, the AP sub-ledger, and the fixed asset register with depreciation and disposals.
--
-- Bill approved (AP-02):  Dr expense / asset per line (+ VAT that cannot be recovered)   Dr 1402 input VAT (recoverable)   Cr 2101 vendor (gross)
-- Bill paid (AP-03):      Dr 2101 vendor (gross settled)   Cr bank or wallet (net)   Cr 2202 WHT withheld (vendor)
-- WHT is only recognised when a bill is paid, never from a bank line alone (TAX-03). Input VAT only with a bill (TAX-02).

-- ---------------------------------------------------------------------------
-- 1. Party tags on lines posted before sub-ledgers existed
-- ---------------------------------------------------------------------------
-- Posted amounts never change. The one exception is filling in who a payable or receivable line belongs to when it was posted
-- without one, which is metadata, under app.tag_party.
create or replace function private.guard_journals() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.allow_purge', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'journal_lines' and coalesce(current_setting('app.tag_party', true), '') = 'on'
     and old.party_id is null and new.journal_id = old.journal_id and new.account_code = old.account_code and new.debit = old.debit
     and new.credit = old.credit and new.org_id = old.org_id and new.location_id is not distinct from old.location_id
     and new.item_id is not distinct from old.item_id then
    return new;
  end if;
  raise exception 'Posted journals cannot be changed. Post a reversing entry instead.';
end $$;

-- A stock receipt's payable belongs to its vendor.
create or replace function private.fill_line_party() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare j record;
begin
  if new.party_id is null and new.account_code in ('2101', '2102') then
    select source_type, source_id into j from journals where id = new.journal_id;
    if j.source_type = 'receipt' then
      new.party_type := 'vendor';
      new.party_id := (select vendor_id from receipts where id = j.source_id);
      new.doc_type := coalesce(new.doc_type, 'receipt');
      new.doc_id := coalesce(new.doc_id, j.source_id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists journal_lines_party on public.journal_lines;
create trigger journal_lines_party before insert on public.journal_lines for each row execute function private.fill_line_party();

-- ---------------------------------------------------------------------------
-- 2. Withholding tax rates (Deduction of Tax at Source (Withholding) Regulations 2024, as amended by the Nigeria Tax Act 2025)
-- ---------------------------------------------------------------------------
create table if not exists public.wht_rates (
  code text primary key,
  name text not null,
  rate_company numeric(6,4) not null,
  rate_individual numeric(6,4) not null,
  note text,
  sort int not null default 100
);
insert into public.wht_rates (code, name, rate_company, rate_individual, note, sort) values
  ('none', 'No withholding tax', 0, 0, 'Exempt, or the supplier is not in scope', 1),
  ('goods', 'Supply of goods', 0.02, 0.02, null, 10),
  ('services', 'Other services', 0.02, 0.02, 'All services not listed elsewhere', 11),
  ('professional', 'Professional, consultancy, technical and management services', 0.05, 0.05, null, 12),
  ('commission', 'Commission', 0.05, 0.05, null, 13),
  ('brokerage', 'Brokerage', 0.05, 0.05, null, 14),
  ('rent', 'Rent', 0.10, 0.10, 'Rent and hire of equipment', 15),
  ('construction_roads', 'Construction of roads, bridges, buildings and power plants', 0.02, 0.02, null, 16),
  ('construction_other', 'Other construction', 0.05, 0.05, null, 17),
  ('royalty', 'Royalty', 0.10, 0.05, null, 18),
  ('interest', 'Interest', 0.10, 0.10, null, 19),
  ('dividend', 'Dividend', 0.10, 0.10, null, 20),
  ('directors_fees', 'Directors'' fees', 0.15, 0.15, 'Individuals only', 21),
  ('entertainment', 'Entertainment and sports performers', 0.05, 0.05, null, 22)
on conflict (code) do nothing;
alter table public.wht_rates enable row level security;
drop policy if exists wht_rates_read on public.wht_rates;
create policy wht_rates_read on public.wht_rates for select to authenticated using (true);

-- A small business (turnover up to ₦25 million) does not deduct WHT on a supplier with a TIN when the month's total to them is under ₦2 million.
alter table public.orgs add column if not exists wht_small_company boolean not null default false;

-- Rate to withhold from a vendor for a category: the supplier type sets the column; no TIN doubles it (capped at 20%).
create or replace function private.wht_rate(p_vendor uuid, p_category text) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when r.code is null or r.code = 'none' then 0
              else least(case when coalesce(v.is_individual, false) then r.rate_individual else r.rate_company end
                         * case when nullif(trim(v.tin), '') is null then 2 else 1 end, 0.20) end
  from (select 1) one
  left join public.vendors v on v.id = p_vendor
  left join public.wht_rates r on r.code = coalesce(nullif(p_category, ''), v.wht_category, 'none')
$$;

-- ---------------------------------------------------------------------------
-- 3. Bills
-- ---------------------------------------------------------------------------
create table if not exists public.bills (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  vendor_id uuid not null references public.vendors(id),
  vendor_ref text,
  source text not null default 'manual' check (source in ('manual', 'receipt', 'prism', 'ai', 'import', 'landed_cost')),
  receipt_id uuid references public.receipts(id) on delete set null,
  external_ref text,
  bill_date date not null,
  due_date date not null,
  currency text not null default 'NGN',
  prices_include_vat boolean not null default false,
  vat_charged boolean not null default true,
  status text not null default 'draft' check (status in ('draft', 'approved', 'partially_paid', 'paid', 'void')),
  subtotal numeric(16,2) not null default 0,
  vat_total numeric(16,2) not null default 0,
  total numeric(16,2) not null default 0,
  wht_category text references public.wht_rates(code),
  wht_rate numeric(6,4) not null default 0,
  wht_expected numeric(16,2) not null default 0,
  amount_paid numeric(16,2) not null default 0,
  wht_withheld numeric(16,2) not null default 0,
  journal_id uuid references public.journals(id) on delete set null,
  document_path text,
  notes text,
  ai_confidence numeric(4,3),
  ai_proposal_id uuid references public.ai_proposals(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  voided_by uuid references public.members(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  client_uuid uuid unique,
  created_at timestamptz not null default now(),
  unique (org_id, number)
);
create unique index if not exists bills_receipt on public.bills(receipt_id) where receipt_id is not null;
create unique index if not exists bills_external on public.bills(org_id, source, external_ref) where external_ref is not null;
create index if not exists bills_org on public.bills(org_id, status, due_date);
create index if not exists bills_vendor on public.bills(vendor_id);
create index if not exists bills_journal_fk on public.bills(journal_id);
create index if not exists bills_created_by_fk on public.bills(created_by);
create index if not exists bills_approved_by_fk on public.bills(approved_by);
create index if not exists bills_voided_by_fk on public.bills(voided_by);
create index if not exists bills_proposal_fk on public.bills(ai_proposal_id);
create index if not exists bills_wht_fk on public.bills(wht_category);

create table if not exists public.bill_lines (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  line_no int not null,
  description text not null,
  account_code text not null,
  qty numeric(14,3) not null default 1 check (qty > 0),
  unit_cost numeric(16,2) not null check (unit_cost >= 0),
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard', 'zero', 'exempt', 'none')),
  vat_recoverable boolean not null default true,
  net numeric(16,2) not null,
  vat numeric(16,2) not null default 0,
  gross numeric(16,2) not null,
  asset_life_months int check (asset_life_months is null or asset_life_months between 1 and 1200),
  location_id uuid references public.locations(id) on delete set null,
  ai_confidence numeric(4,3)
);
create index if not exists bill_lines_bill on public.bill_lines(bill_id);
create index if not exists bill_lines_org on public.bill_lines(org_id);
create index if not exists bill_lines_location_fk on public.bill_lines(location_id);

create table if not exists public.bill_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  bill_id uuid not null references public.bills(id) on delete cascade,
  method text not null check (method in ('wallet', 'bank', 'cash', 'offset')),
  status text not null default 'paid' check (status in ('processing', 'paid', 'failed', 'reversed')),
  gross numeric(16,2) not null check (gross > 0),
  wht numeric(16,2) not null default 0 check (wht >= 0),
  net numeric(16,2) not null check (net >= 0),
  bank_account_id uuid references public.bank_accounts(id),
  payout_id uuid references public.payouts(id) on delete set null,
  paid_at timestamptz not null default now(),
  reference text,
  journal_id uuid references public.journals(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  check (gross = net + wht)
);
create index if not exists bill_payments_bill on public.bill_payments(bill_id);
create index if not exists bill_payments_org on public.bill_payments(org_id, paid_at desc);
create index if not exists bill_payments_bank_fk on public.bill_payments(bank_account_id);
create index if not exists bill_payments_payout on public.bill_payments(payout_id);
create index if not exists bill_payments_journal_fk on public.bill_payments(journal_id);
create index if not exists bill_payments_created_by_fk on public.bill_payments(created_by);

-- ---------------------------------------------------------------------------
-- 4. Fixed assets
-- ---------------------------------------------------------------------------
create table if not exists public.asset_classes (
  cost_account text primary key,
  name text not null,
  accum_account text,
  expense_account text not null default '6901',
  default_life_months int,
  depreciates boolean not null default true
);
insert into public.asset_classes (cost_account, name, accum_account, default_life_months, depreciates) values
  ('1501', 'Freehold land', null, null, false),
  ('1502', 'Non-industrial buildings', '1551', 600, true),
  ('1503', 'Industrial buildings', '1552', 480, true),
  ('1504', 'Plant', '1553', 120, true),
  ('1505', 'Ships, boats and yachts', '1554', 180, true),
  ('1506', 'Heavy equipment', '1555', 96, true),
  ('1507', 'Aircraft engines and fuselage', '1556', 180, true),
  ('1508', 'Aircraft and vessel furnishing', '1557', 120, true),
  ('1509', 'Towers and cables', '1558', 240, true),
  ('1510', 'Trains and tracks', '1559', 300, true),
  ('1511', 'Motor vehicles', '1560', 48, true),
  ('1512', 'Buses and trucks', '1561', 60, true),
  ('1513', 'Tools and equipment', '1562', 60, true),
  ('1514', 'Office equipment', '1563', 48, true),
  ('1515', 'Medical equipment', '1564', 84, true),
  ('1516', 'Household equipment', '1565', 60, true),
  ('1517', 'Computer hardware', '1566', 36, true),
  ('1518', 'Office fixtures', '1567', 60, true),
  ('1519', 'Furniture and fittings', '1568', 60, true),
  ('1520', 'Assets under construction', null, null, false),
  ('1521', 'Capital work in progress', null, null, false),
  ('1522', 'Bearer plants', '1569', 240, true),
  ('1523', 'Biological assets', '1570', 60, true),
  ('1524', 'Petroleum development costs', '1571', 120, true),
  ('1525', 'Distribution network', '1572', 240, true),
  ('1526', 'Leasehold improvements', '1573', 120, true),
  ('1527', 'Other property, plant and equipment', '1574', 60, true)
on conflict (cost_account) do nothing;
alter table public.asset_classes enable row level security;
drop policy if exists asset_classes_read on public.asset_classes;
create policy asset_classes_read on public.asset_classes for select to authenticated using (true);

create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  name text not null check (length(trim(name)) > 0),
  class_account text not null references public.asset_classes(cost_account),
  cost numeric(16,2) not null check (cost >= 0),
  residual numeric(16,2) not null default 0 check (residual >= 0),
  life_months int check (life_months is null or life_months between 1 and 1200),
  available_date date,
  status text not null default 'pending_confirmation' check (status in ('pending_confirmation', 'active', 'disposed', 'rejected')),
  location_id uuid references public.locations(id) on delete set null,
  serial_no text,
  bill_id uuid references public.bills(id) on delete set null,
  bill_line_id uuid references public.bill_lines(id) on delete set null,
  journal_id uuid references public.journals(id) on delete set null,
  opening_accumulated numeric(16,2) not null default 0,
  depreciate_from date,
  disposed_at date,
  proceeds numeric(16,2),
  disposal_journal_id uuid references public.journals(id) on delete set null,
  notes text,
  created_by uuid references public.members(id) on delete set null,
  confirmed_by uuid references public.members(id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (org_id, number),
  check (residual <= cost)
);
create index if not exists fixed_assets_org on public.fixed_assets(org_id, status);
create index if not exists fixed_assets_class_fk on public.fixed_assets(class_account);
create index if not exists fixed_assets_location_fk on public.fixed_assets(location_id);
create index if not exists fixed_assets_bill_fk on public.fixed_assets(bill_id);
create index if not exists fixed_assets_bill_line_fk on public.fixed_assets(bill_line_id);
create index if not exists fixed_assets_journal_fk on public.fixed_assets(journal_id);
create index if not exists fixed_assets_disposal_fk on public.fixed_assets(disposal_journal_id);
create index if not exists fixed_assets_created_by_fk on public.fixed_assets(created_by);
create index if not exists fixed_assets_confirmed_by_fk on public.fixed_assets(confirmed_by);

create table if not exists public.depreciation_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  period_end date not null,
  total numeric(16,2) not null default 0,
  lines jsonb not null default '[]'::jsonb,
  journal_id uuid references public.journals(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, period_end)
);
create index if not exists depreciation_runs_journal_fk on public.depreciation_runs(journal_id);
create index if not exists depreciation_runs_created_by_fk on public.depreciation_runs(created_by);

alter table public.bills enable row level security;
alter table public.bill_lines enable row level security;
alter table public.bill_payments enable row level security;
alter table public.fixed_assets enable row level security;
alter table public.depreciation_runs enable row level security;
do $$
declare t text;
begin
  foreach t in array array['bills', 'bill_lines', 'bill_payments', 'fixed_assets', 'depreciation_runs'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select private.can_handle_money(org_id)) or (select private.has_perm(org_id, %L)))',
      t || '_read', t, 'approve_pos');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Writing, approving and voiding bills
-- ---------------------------------------------------------------------------
create or replace function private.vendor_balance(p_org uuid, p_vendor uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(credit - debit), 0) from journal_lines
  where org_id = p_org and party_type = 'vendor' and party_id = p_vendor and account_code in ('2101', '2102')
$$;

create or replace function private.bill_account_ok(p_org uuid, p_code text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.postable(p_org, p_code) and p_code !~ '^(101|1101|1102|1103|1105|1401|1402|2101|2102|22|3|41)' and p_code !~ '^9'
$$;

-- p: {id, vendor_id | vendor:{name, tin, is_individual, wht_category, bank_code, account_number, account_name}, vendor_ref, bill_date, due_date,
--     prices_include_vat, vat_charged, wht_category, notes, document_path, client_uuid, source, external_ref,
--     lines:[{description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, asset_life_months, location_id, ai_confidence}]}
create or replace function private.write_bill(p_org uuid, p jsonb, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; o public.orgs; x jsonb; v_no int := 0; v_qty numeric; v_cost numeric; v_base numeric; v_net numeric; v_vat numeric;
  v_treat text; v_rate numeric; v_id uuid := nullif(p->>'id', '')::uuid; v_vendor uuid := nullif(p->>'vendor_id', '')::uuid; v_day date; v_code text;
  v_wht_cat text; v_recov boolean;
begin
  select * into o from orgs where id = p_org;
  if nullif(p->>'client_uuid', '') is not null and v_id is null then
    select * into b from bills where client_uuid = (p->>'client_uuid')::uuid;
    if found then return b; end if;
  end if;
  if v_vendor is null and coalesce(trim(p->'vendor'->>'name'), '') <> '' then
    select id into v_vendor from vendors where org_id = p_org and (lower(name) = lower(trim(p->'vendor'->>'name'))
      or (nullif(trim(p->'vendor'->>'tin'), '') is not null and tin = trim(p->'vendor'->>'tin'))) limit 1;
    if v_vendor is null then
      insert into vendors (org_id, name, tin, is_individual, wht_category, bank_code, bank_name, account_number, account_name, vat_registered, channel, phone, email)
      values (p_org, left(trim(p->'vendor'->>'name'), 120), nullif(trim(p->'vendor'->>'tin'), ''), coalesce((p->'vendor'->>'is_individual')::boolean, false),
        nullif(p->'vendor'->>'wht_category', ''), nullif(p->'vendor'->>'bank_code', ''), nullif(p->'vendor'->>'bank_name', ''),
        nullif(p->'vendor'->>'account_number', ''), nullif(p->'vendor'->>'account_name', ''), coalesce((p->>'vat_charged')::boolean, true), 'email',
        nullif(p->'vendor'->>'phone', ''), nullif(p->'vendor'->>'email', ''))
      returning id into v_vendor;
    end if;
  end if;
  select * into v from vendors where id = v_vendor and org_id = p_org;
  if not found then raise exception 'Choose the vendor.'; end if;
  v_day := coalesce(nullif(p->>'bill_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A bill cannot be dated in the future.'; end if;
  v_wht_cat := coalesce(nullif(p->>'wht_category', ''), v.wht_category, 'none');
  if not exists (select 1 from wht_rates where code = v_wht_cat) then raise exception 'Unknown withholding tax category.'; end if;
  if v_id is null then
    insert into bills (org_id, number, vendor_id, vendor_ref, source, external_ref, bill_date, due_date, prices_include_vat, vat_charged, wht_category,
      notes, document_path, created_by, client_uuid)
    values (p_org, 'BILL-' || lpad(private.next_no(p_org, 'BILL', 1)::text, 4, '0'), v.id, nullif(trim(p->>'vendor_ref'), ''),
      coalesce(nullif(p->>'source', ''), 'manual'), nullif(p->>'external_ref', ''), v_day,
      coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)), coalesce((p->>'prices_include_vat')::boolean, false),
      coalesce((p->>'vat_charged')::boolean, coalesce(v.vat_registered, true)), v_wht_cat, nullif(trim(p->>'notes'), ''), nullif(p->>'document_path', ''),
      m.id, nullif(p->>'client_uuid', '')::uuid)
    returning * into b;
  else
    select * into b from bills where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status <> 'draft' then raise exception '% is already approved. Void it and enter it again.', b.number; end if;
    update bills set vendor_id = v.id, vendor_ref = case when p ? 'vendor_ref' then nullif(trim(p->>'vendor_ref'), '') else vendor_ref end, bill_date = v_day,
      due_date = coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)),
      prices_include_vat = coalesce((p->>'prices_include_vat')::boolean, prices_include_vat), vat_charged = coalesce((p->>'vat_charged')::boolean, vat_charged),
      wht_category = v_wht_cat, notes = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else notes end,
      document_path = coalesce(nullif(p->>'document_path', ''), document_path)
    where id = b.id returning * into b;
  end if;
  if b.due_date < b.bill_date then raise exception 'The due date is before the bill date.'; end if;
  if p ? 'lines' then
    delete from bill_lines where bill_id = b.id;
    if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line.'; end if;
    for x in select * from jsonb_array_elements(p->'lines') loop
      v_no := v_no + 1;
      v_code := nullif(trim(x->>'account_code'), '');
      if v_code is null or not private.bill_account_ok(p_org, v_code) then
        raise exception 'Line %: choose an expense, stock or asset account.', v_no;
      end if;
      v_qty := coalesce(round(private.num(x->>'qty'), 3), 1);
      v_cost := round(private.num(x->>'unit_cost'), 2);
      if v_qty <= 0 or v_cost is null or v_cost < 0 then raise exception 'Line %: enter the quantity and cost.', v_no; end if;
      v_treat := case when not b.vat_charged then 'none' else coalesce(nullif(x->>'vat_treatment', ''), 'standard') end;
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_rate := case when v_treat = 'standard' then 0.075 else 0 end;
      v_base := round(v_qty * v_cost, 2);
      if b.prices_include_vat then v_net := round(v_base / (1 + v_rate), 2); v_vat := v_base - v_net;
      else v_net := v_base; v_vat := round(v_net * v_rate, 2); end if;
      -- Input VAT is recoverable when the business is VAT-registered (NTA 2025 s.156), unless marked otherwise.
      v_recov := o.vat_registered and coalesce((x->>'vat_recoverable')::boolean, true);
      insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross,
        asset_life_months, location_id, ai_confidence)
      values (b.id, p_org, v_no, left(coalesce(nullif(trim(x->>'description'), ''), 'Line ' || v_no), 300), v_code, v_qty, v_cost, v_treat, v_recov,
        v_net, v_vat, v_net + v_vat, nullif(x->>'asset_life_months', '')::int,
        (select id from locations where id = nullif(x->>'location_id', '')::uuid and org_id = p_org), nullif(x->>'ai_confidence', '')::numeric);
    end loop;
  end if;
  update bills set subtotal = (select coalesce(sum(net), 0) from bill_lines where bill_id = b.id),
    vat_total = (select coalesce(sum(vat), 0) from bill_lines where bill_id = b.id),
    total = (select coalesce(sum(gross), 0) from bill_lines where bill_id = b.id),
    wht_rate = private.wht_rate(b.vendor_id, b.wht_category)
  where id = b.id returning * into b;
  update bills set wht_expected = case
      when o.wht_small_company and nullif(trim(v.tin), '') is not null and b.subtotal < 2000000 then 0
      else round(b.subtotal * b.wht_rate, 2) end
  where id = b.id returning * into b;
  return b;
end $$;

-- Posts an approved bill, and opens a fixed asset record (pending confirmation) for each line coded to an asset class.
create or replace function private.post_bill(p_bill uuid, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; l public.bill_lines; v_jl jsonb := '[]'::jsonb; j public.journals; v_vat numeric := 0; v_vendor text; v_at timestamptz;
begin
  select * into b from bills where id = p_bill for update;
  if b.journal_id is not null then return b; end if;
  select name into v_vendor from vendors where id = b.vendor_id;
  for l in select * from bill_lines where bill_id = b.id order by line_no loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', l.account_code, 'debit', l.net + case when l.vat_recoverable then 0 else l.vat end,
      'location_id', l.location_id, 'memo', l.description, 'doc_type', 'bill', 'doc_id', b.id));
    if l.vat_recoverable then v_vat := v_vat + l.vat; end if;
  end loop;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(b.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT · ' || v_vendor, 'doc_type', 'bill', 'doc_id', b.id),
    jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'credit', b.total, 'party_type', 'vendor', 'party_id', b.vendor_id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', b.number || coalesce(' · ' || b.vendor_ref, '')));
  v_at := private.posting_time(b.org_id, b.bill_date);
  j := private.post_entry(b.org_id, 'Bill ' || b.number || ' · ' || v_vendor || coalesce(' · ' || b.vendor_ref, ''), 'bill', b.id, b.created_by, m.id, v_jl, v_at,
    jsonb_build_object('origin', case when b.source = 'ai' then 'ai' else 'system' end, 'ai_confidence', b.ai_confidence,
      'evidence', jsonb_build_array(jsonb_build_object('type', 'bill', 'id', b.id, 'ref', coalesce(b.vendor_ref, b.number), 'document', b.document_path))));
  update bills set journal_id = j.id, status = 'approved', approved_by = m.id, approved_at = now() where id = b.id returning * into b;
  -- Capital lines become register records waiting for someone to confirm the class, date in use and life (FA-02).
  insert into fixed_assets (org_id, number, name, class_account, cost, life_months, available_date, status, location_id, bill_id, bill_line_id, journal_id, created_by)
  select b.org_id, 'FA-' || lpad(private.next_no(b.org_id, 'FA', 1)::text, 4, '0'), bl.description, bl.account_code,
    bl.net + case when bl.vat_recoverable then 0 else bl.vat end, coalesce(bl.asset_life_months, ac.default_life_months), b.bill_date, 'pending_confirmation',
    bl.location_id, b.id, bl.id, j.id, m.id
  from bill_lines bl join asset_classes ac on ac.cost_account = bl.account_code where bl.bill_id = b.id order by bl.line_no;
  return b;
end $$;

create or replace function private.refresh_bill(p_bill uuid) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v_paid numeric; v_wht numeric;
begin
  select * into b from bills where id = p_bill for update;
  if b.status in ('draft', 'void') then return b; end if;
  select coalesce(sum(gross), 0), coalesce(sum(wht), 0) into v_paid, v_wht from bill_payments where bill_id = b.id and status = 'paid';
  update bills set amount_paid = v_paid, wht_withheld = v_wht,
    status = case when v_paid >= total - 0.004 then 'paid' when v_paid > 0 then 'partially_paid' else 'approved' end
  where id = b.id returning * into b;
  return b;
end $$;

create or replace function private.bill_json(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(b) || jsonb_build_object(
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'bank_code', v.bank_code, 'bank_name', v.bank_name,
        'account_number', v.account_number, 'account_name', v.account_name, 'wht_category', v.wht_category) from vendors v where v.id = b.vendor_id),
    'balance', case when b.status in ('approved', 'partially_paid') then b.total - b.amount_paid else 0 end,
    'in_progress', (select coalesce(sum(gross), 0) from bill_payments where bill_id = b.id and status = 'processing'),
    'overdue_days', case when b.status in ('approved', 'partially_paid') then greatest(private.local_day(b.org_id, now()) - b.due_date, 0) end,
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('account_name', private.account_name(b.org_id, l.account_code)) order by l.line_no), '[]'::jsonb)
              from bill_lines l where l.bill_id = b.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' || jsonb_build_object('payout_number', (select number from payouts where id = p.payout_id),
        'payout_status', (select status from payouts where id = p.payout_id)) order by p.paid_at), '[]'::jsonb) from bill_payments p where p.bill_id = b.id),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'number', a.number, 'name', a.name, 'status', a.status)), '[]'::jsonb) from fixed_assets a where a.bill_id = b.id),
    'journal_ref', (select ref from journals where id = b.journal_id),
    'created_by_name', (select display_name from members where id = b.created_by),
    'approved_by_name', (select display_name from members where id = b.approved_by))
  from bills b where b.id = p_bill
$$;

create or replace function public.save_bill(p_org uuid, p_bill jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bills;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_pos')) then
    raise exception 'Only someone who keeps the books or approves purchases enters bills.' using errcode = '42501';
  end if;
  b := private.write_bill(p_org, p_bill - 'source' - 'external_ref', m);
  if p_bill->>'status' = 'approve' then return public.approve_bill(b.id); end if;
  return private.bill_json(b.id);
end $$;

create or replace function public.approve_bill(p_bill uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if b.status <> 'draft' then raise exception '% is already %.', b.number, b.status; end if;
  if b.total <= 0 then raise exception 'The bill total must be above zero.'; end if;
  perform private.require_open_day(b.org_id, b.bill_date);
  if exists (select 1 from bills where org_id = b.org_id and vendor_id = b.vendor_id and vendor_ref = b.vendor_ref and b.vendor_ref is not null
             and id <> b.id and status <> 'void') then
    raise exception 'Bill % from this vendor is already entered.', b.vendor_ref;
  end if;
  b := private.post_bill(b.id, m);
  if b.ai_proposal_id is not null then
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), journal_id = b.journal_id where id = b.ai_proposal_id and status = 'pending';
  end if;
  return private.bill_json(b.id);
end $$;

create or replace function public.void_bill(p_bill uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason.'; end if;
  if b.status = 'void' then raise exception '% is already void.', b.number; end if;
  if b.source = 'receipt' then raise exception '% came from a stock receipt. Correct the stock instead.', b.number; end if;
  if exists (select 1 from bill_payments where bill_id = b.id and status in ('paid', 'processing')) then
    raise exception '% has payments. Ask the vendor for a credit note instead.', b.number;
  end if;
  if exists (select 1 from fixed_assets where bill_id = b.id and status = 'active') then
    raise exception 'An asset from % is in use. Dispose of it first.', b.number;
  end if;
  if b.journal_id is not null then
    perform private.reverse_entry(b.journal_id, m.id, 'Bill ' || b.number || ' voided: ' || trim(p_reason), null);
    update fixed_assets set status = 'rejected', notes = concat_ws(' · ', notes, 'Bill voided') where bill_id = b.id and status = 'pending_confirmation';
  end if;
  update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = trim(p_reason) where id = b.id;
  return private.bill_json(b.id);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Paying bills: from the wallet (a payout) or recorded as paid from a bank account or cash
-- ---------------------------------------------------------------------------
-- p: {method: 'wallet'|'bank'|'cash', amount (what the bill is settled by, gross), wht (default: the bill's expected WHT in proportion),
--     bank_account_id, paid_at, reference, narration, account_number, bank_code, account_name, client_uuid}
create or replace function public.pay_bill(p_bill uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members; v public.vendors; v_gross numeric; v_wht numeric; v_net numeric; v_due numeric; v_method text := coalesce(nullif(p->>'method', ''), 'wallet');
  ba public.bank_accounts; j public.journals; po public.payouts; bp public.bill_payments; v_at timestamptz; v_withheld_before numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'make_payments');
  if b.status not in ('approved', 'partially_paid') then raise exception '% is %.', b.number, b.status; end if;
  select * into v from vendors where id = b.vendor_id;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  v_gross := round(coalesce(private.num(p->>'amount'), v_due), 2);
  if v_gross <= 0 or v_gross > v_due + 0.004 then raise exception 'Up to % is still owed on %.', to_char(v_due, 'FM999,999,999,990.00'), b.number; end if;
  -- WHT is withheld in proportion to what this payment settles, so part payments add up to the bill's WHT.
  select coalesce(sum(wht), 0) into v_withheld_before from bill_payments where bill_id = b.id and status in ('paid', 'processing');
  v_wht := round(coalesce(private.num(p->>'wht'),
    case when v_gross >= v_due - 0.004 then b.wht_expected - v_withheld_before else b.wht_expected * v_gross / nullif(b.total, 0) end), 2);
  v_wht := greatest(v_wht, 0);
  if v_wht >= v_gross then raise exception 'The withholding tax cannot be the whole payment.'; end if;
  v_net := v_gross - v_wht;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  if v_method = 'wallet' then
    po := private.create_payout(b.org_id, jsonb_build_object('purpose', 'vendor', 'vendor_id', v.id, 'amount', v_net,
      'bank_code', coalesce(nullif(p->>'bank_code', ''), v.bank_code), 'bank_name', coalesce(nullif(p->>'bank_name', ''), v.bank_name),
      'account_number', coalesce(nullif(p->>'account_number', ''), v.account_number), 'account_name', coalesce(nullif(p->>'account_name', ''), v.account_name),
      'narration', left(coalesce(nullif(trim(p->>'narration'), ''), b.number || coalesce(' ' || b.vendor_ref, '')), 80), 'client_uuid', p->>'client_uuid'),
      jsonb_build_array(
        jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', v_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', b.number),
        jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number)), m);
    -- Keep the vendor's account details for next time.
    update vendors set bank_code = coalesce(bank_code, po.bank_code), bank_name = coalesce(bank_name, po.bank_name),
      account_number = coalesce(account_number, po.account_number), account_name = coalesce(account_name, po.account_name) where id = v.id;
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, payout_id, paid_at, reference, created_by)
    values (b.org_id, b.id, 'wallet', 'processing', v_gross, v_wht, v_net, po.id, v_at, po.reference, m.id) returning * into bp;
    return jsonb_build_object('bill', private.bill_json(b.id), 'payout', to_jsonb(po) - 'lines' - 'raw');
  end if;
  if v_method not in ('bank', 'cash') then raise exception 'Pay from the wallet, a bank account or cash.'; end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = b.org_id and active and kind = case when v_method = 'cash' then 'cash' else 'bank' end;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  perform private.require_open_day(b.org_id, private.local_day(b.org_id, v_at));
  j := private.post_entry(b.org_id, 'Paid ' || v.name || ' · ' || b.number, 'bill_payment', b.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', v_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number),
      jsonb_build_object('code', ba.ledger_code, 'credit', v_net, 'memo', b.number || ' · ' || v.name || coalesce(' · ' || nullif(trim(p->>'reference'), ''), '')),
      jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
        'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number)), v_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p->>'reference'), ''), 'by', m.display_name))));
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, bank_account_id, paid_at, reference, journal_id, created_by)
  values (b.org_id, b.id, v_method, 'paid', v_gross, v_wht, v_net, ba.id, v_at, nullif(trim(p->>'reference'), ''), j.id, m.id);
  b := private.refresh_bill(b.id);
  return jsonb_build_object('bill', private.bill_json(b.id));
end $$;

-- A wallet payout for a bill settles it when the rail confirms, and frees it again if the transfer fails.
create or replace function private.on_payout_change() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare bp record;
begin
  for bp in select * from bill_payments where payout_id = new.id loop
    if new.status = 'successful' and new.journal_id is not null then
      update bill_payments set status = 'paid', journal_id = new.journal_id, paid_at = coalesce(new.completed_at, now()) where id = bp.id;
    elsif new.status in ('failed', 'cancelled') then
      update bill_payments set status = 'failed' where id = bp.id;
    elsif new.status = 'reversed' then
      update bill_payments set status = 'reversed' where id = bp.id;
    end if;
    perform private.refresh_bill(bp.bill_id);
  end loop;
  return new;
end $$;
drop trigger if exists payouts_bills on public.payouts;
create trigger payouts_bills after update of status, journal_id on public.payouts for each row execute function private.on_payout_change();

-- ---------------------------------------------------------------------------
-- 7. Stock receipts become bills, so they can be paid with WHT like any other
-- ---------------------------------------------------------------------------
create or replace function private.bill_from_receipt(p_receipt uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; v public.vendors; b public.bills; v_paid numeric;
begin
  select * into r from receipts where id = p_receipt;
  if r.status <> 'posted' or r.vendor_id is null or r.journal_id is null then return null; end if;
  select id into b.id from bills where receipt_id = r.id;
  if b.id is not null then return b.id; end if;
  select * into v from vendors where id = r.vendor_id;
  insert into bills (org_id, number, vendor_id, vendor_ref, source, receipt_id, bill_date, due_date, prices_include_vat, vat_charged, status, subtotal, vat_total,
    total, wht_category, wht_rate, journal_id, document_path, created_by, approved_by, approved_at)
  values (r.org_id, 'BILL-' || lpad(private.next_no(r.org_id, 'BILL', 1)::text, 4, '0'), r.vendor_id, r.invoice_no, 'receipt', r.id,
    coalesce(r.invoice_date, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at))),
    coalesce(r.invoice_date, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at))) + coalesce(nullif(v.credit_days, 0), 30),
    coalesce(r.prices_include_vat, false), coalesce(r.vendor_vat_registered, true), 'approved', coalesce(r.net, 0), coalesce(r.input_vat, 0),
    coalesce(r.gross, coalesce(r.net, 0) + coalesce(r.input_vat, 0)), coalesce(v.wht_category, 'none'), private.wht_rate(v.id, coalesce(v.wht_category, 'none')),
    r.journal_id, r.document_path, coalesce(r.posted_by, r.created_by), r.posted_by, r.posted_at)
  returning * into b;
  insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross)
  values (b.id, b.org_id, 1, 'Stock received · ' || r.ref, private.acct(r.org_id, 'inventory'), 1, b.subtotal, case when b.vat_total > 0 then 'standard' else 'none' end,
    true, b.subtotal, b.vat_total, b.total);
  update bills set wht_expected = round(subtotal * wht_rate, 2) where id = b.id;
  -- Anything already paid against this receipt in the ledger counts.
  select coalesce(sum(debit), 0) into v_paid from journal_lines where org_id = r.org_id and account_code in ('2101', '2102') and doc_type = 'receipt' and doc_id = r.id
    and journal_id <> r.journal_id;
  if v_paid > 0 then
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, paid_at, reference)
    values (b.org_id, b.id, 'bank', 'paid', least(v_paid, b.total), 0, least(v_paid, b.total), now(), 'Paid before bills were kept');
    perform private.refresh_bill(b.id);
  end if;
  return b.id;
end $$;

create or replace function private.on_receipt_posted() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'posted' and old.status is distinct from 'posted' then perform private.bill_from_receipt(new.id); end if;
  return new;
end $$;
drop trigger if exists receipts_bill on public.receipts;
create trigger receipts_bill after update of status on public.receipts for each row execute function private.on_receipt_posted();

-- Receipts posted before today: tag their payable lines with the vendor and give each a bill.
do $$
declare r record;
begin
  perform set_config('app.tag_party', 'on', true);
  update public.journal_lines l set party_type = 'vendor', party_id = rc.vendor_id, doc_type = coalesce(l.doc_type, 'receipt'), doc_id = coalesce(l.doc_id, rc.id)
  from public.journals j join public.receipts rc on rc.id = j.source_id
  where l.journal_id = j.id and j.source_type = 'receipt' and l.account_code in ('2101', '2102') and l.party_id is null and rc.vendor_id is not null;
  perform set_config('app.tag_party', '', true);
  for r in select id from public.receipts where status = 'posted' and vendor_id is not null and journal_id is not null loop
    perform private.bill_from_receipt(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Bills from Prism (TaxStreem). The taxstreem edge function verifies the caller and passes the business.
-- ---------------------------------------------------------------------------
create or replace function public.svc_prism_bill(p_org uuid, p_bill jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members; v_ref text := nullif(trim(p_bill->>'prism_id'), '');
begin
  if v_ref is null then raise exception 'prism_id is required.'; end if;
  select * into b from bills where org_id = p_org and source = 'prism' and external_ref = v_ref;
  if found then return jsonb_build_object('duplicate', true, 'bill', private.bill_json(b.id)); end if;
  select * into m from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
  b := private.write_bill(p_org, (p_bill - 'id' - 'status') || jsonb_build_object('source', 'prism', 'external_ref', v_ref), m);
  update bills set created_by = null where id = b.id;
  perform private.notify_perm(p_org, 'keep_books', 'bill', 'New bill from Prism: ' || (select name from vendors where id = b.vendor_id),
    '₦' || to_char(b.total, 'FM999,999,999,990.00') || coalesce(' · ' || b.vendor_ref, '') || ' · check and approve it', '/purchases/bills/' || b.id, 'bill-' || b.id);
  return jsonb_build_object('duplicate', false, 'bill', private.bill_json(b.id));
end $$;

-- ---------------------------------------------------------------------------
-- 9. Reading payables
-- ---------------------------------------------------------------------------
create or replace function public.get_bills(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_today date;
begin
  m := private.require(p_org, null);
  if not (private.can_handle_money(p_org) or private.perm_of(m, 'approve_pos')) then raise exception 'Your role does not see bills.' using errcode = '42501'; end if;
  v_today := private.local_day(p_org, now());
  return jsonb_build_object(
    'bills', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'vendor_id', b.vendor_id, 'vendor_name', v.name, 'vendor_ref', b.vendor_ref,
        'source', b.source, 'bill_date', b.bill_date, 'due_date', b.due_date, 'status', b.status, 'subtotal', b.subtotal, 'vat_total', b.vat_total, 'total', b.total,
        'wht_expected', b.wht_expected, 'amount_paid', b.amount_paid, 'balance', case when b.status in ('approved', 'partially_paid') then b.total - b.amount_paid else 0 end,
        'in_progress', (select coalesce(sum(gross), 0) from bill_payments where bill_id = b.id and status = 'processing'),
        'overdue_days', case when b.status in ('approved', 'partially_paid') then greatest(v_today - b.due_date, 0) end, 'created_at', b.created_at,
        'ai_confidence', b.ai_confidence) order by b.created_at desc), '[]'::jsonb)
      from bills b join vendors v on v.id = b.vendor_id
      where b.org_id = p_org and (nullif(p_filter->>'status', '') is null or b.status = any(string_to_array(p_filter->>'status', ',')))
        and (nullif(p_filter->>'vendor_id', '') is null or b.vendor_id = (p_filter->>'vendor_id')::uuid)
        and (nullif(p_filter->>'from', '') is null or b.bill_date >= (p_filter->>'from')::date)
        and (nullif(p_filter->>'to', '') is null or b.bill_date <= (p_filter->>'to')::date)),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'wht_category', v.wht_category,
        'bank_code', v.bank_code, 'bank_name', v.bank_name, 'account_number', v.account_number, 'account_name', v.account_name, 'credit_days', v.credit_days,
        'vat_registered', v.vat_registered, 'balance', private.vendor_balance(p_org, v.id), 'phone', v.phone, 'email', v.email, 'address', v.address,
        'default_account', v.default_account) order by v.name), '[]'::jsonb) from vendors v where v.org_id = p_org),
    'wht_rates', (select jsonb_agg(to_jsonb(r) order by r.sort) from wht_rates r),
    'asset_classes', (select jsonb_agg(to_jsonb(a) order by a.cost_account) from asset_classes a),
    'unassigned_payables', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and account_code in ('2101', '2102') and party_id is null));
end $$;

create or replace function public.get_bill(p_bill uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, null);
  if not (private.can_handle_money(b.org_id) or private.perm_of(m, 'approve_pos')) then raise exception 'Your role does not see bills.' using errcode = '42501'; end if;
  return private.bill_json(b.id);
end $$;

create or replace function public.save_vendor_details(p_org uuid, p_vendor uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.vendors;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'approve_pos')) then
    raise exception 'Your role does not change vendor details.' using errcode = '42501';
  end if;
  if p_patch ? 'wht_category' and nullif(p_patch->>'wht_category', '') is not null and not exists (select 1 from wht_rates where code = p_patch->>'wht_category') then
    raise exception 'Unknown withholding tax category.';
  end if;
  if coalesce(p_patch->>'account_number', '') <> '' and p_patch->>'account_number' !~ '^[0-9]{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if nullif(p_patch->>'default_account', '') is not null and not private.bill_account_ok(p_org, p_patch->>'default_account') then
    raise exception 'Choose an expense, stock or asset account.';
  end if;
  update vendors set
    tin = case when p_patch ? 'tin' then nullif(trim(p_patch->>'tin'), '') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    is_individual = coalesce((p_patch->>'is_individual')::boolean, is_individual),
    wht_category = case when p_patch ? 'wht_category' then nullif(p_patch->>'wht_category', '') else wht_category end,
    bank_code = case when p_patch ? 'bank_code' then nullif(p_patch->>'bank_code', '') else bank_code end,
    bank_name = case when p_patch ? 'bank_name' then nullif(p_patch->>'bank_name', '') else bank_name end,
    account_number = case when p_patch ? 'account_number' then nullif(p_patch->>'account_number', '') else account_number end,
    account_name = case when p_patch ? 'account_name' then nullif(trim(p_patch->>'account_name'), '') else account_name end,
    default_account = case when p_patch ? 'default_account' then nullif(p_patch->>'default_account', '') else default_account end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    credit_days = coalesce((p_patch->>'credit_days')::int, credit_days),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered)
  where id = p_vendor and org_id = p_org returning * into v;
  if not found then raise exception 'Vendor not found.'; end if;
  return to_jsonb(v);
end $$;

-- A vendor's statement from the AP sub-ledger.
create or replace function public.vendor_statement(p_vendor uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v public.vendors; m public.members; v_from date; v_to date; v_open numeric;
begin
  select * into v from vendors where id = p_vendor;
  if not found then raise exception 'Vendor not found.'; end if;
  m := private.require(v.org_id, null);
  if not private.can_handle_money(v.org_id) then raise exception 'Your role does not see vendor balances.' using errcode = '42501'; end if;
  v_to := coalesce(p_to, private.local_day(v.org_id, now()));
  v_from := coalesce(p_from, v_to - 89);
  select coalesce(sum(l.credit - l.debit), 0) into v_open from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = v.org_id and l.party_type = 'vendor' and l.party_id = v.id and l.account_code in ('2101', '2102') and j.entry_date < v_from;
  return jsonb_build_object('vendor', to_jsonb(v), 'from', v_from, 'to', v_to, 'opening', v_open,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', x.entry_date, 'ref', x.ref, 'memo', x.memo, 'debit', x.d, 'credit', x.c, 'balance', v_open + x.run)
        order by x.entry_date, x.je_no), '[]'::jsonb)
      from (select y.*, sum(y.c - y.d) over (order by y.entry_date, y.je_no) run from (
        select j.entry_date, j.je_no, j.ref, j.memo, sum(l.debit) d, sum(l.credit) c from journal_lines l join journals j on j.id = l.journal_id
        where l.org_id = v.org_id and l.party_type = 'vendor' and l.party_id = v.id and l.account_code in ('2101', '2102') and j.entry_date between v_from and v_to
        group by j.entry_date, j.je_no, j.ref, j.memo) y) x),
    'closing', private.vendor_balance(v.org_id, v.id),
    'wht_withheld', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = v.org_id and party_type = 'vendor' and party_id = v.id and account_code = '2202'),
    'open_bills', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date, 'due_date', b.due_date,
        'total', b.total, 'balance', b.total - b.amount_paid) order by b.due_date), '[]'::jsonb) from bills b where b.vendor_id = v.id and b.status in ('approved', 'partially_paid')));
end $$;

-- ---------------------------------------------------------------------------
-- 10. Fixed asset register: confirm, add, depreciate, dispose
-- ---------------------------------------------------------------------------
-- Depreciation so far for an asset, straight line from the date it was available for use, by day within each month.
create or replace function private.asset_accumulated(p_asset uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select a.opening_accumulated + coalesce((select sum(l.credit - l.debit) from journal_lines l
     where l.org_id = a.org_id and l.party_type = 'asset' and l.party_id = a.id and l.account_code = ac.accum_account), 0)
  from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account where a.id = p_asset
$$;

create or replace function private.asset_charge(a public.fixed_assets, p_from date, p_to date) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_days numeric; v_monthly numeric; v_charge numeric := 0; d date; v_start date; v_end date; v_month_days numeric;
begin
  if a.status <> 'active' or a.life_months is null or a.available_date is null then return 0; end if;
  if not (select depreciates from asset_classes where cost_account = a.class_account) then return 0; end if;
  v_monthly := (a.cost - a.residual) / a.life_months;
  d := date_trunc('month', greatest(p_from, a.available_date))::date;
  while d <= p_to loop
    v_start := greatest(d, a.available_date, p_from);
    v_end := least((d + interval '1 month' - interval '1 day')::date, p_to, coalesce(a.disposed_at, p_to));
    v_month_days := extract(day from (d + interval '1 month' - interval '1 day'));
    if v_end >= v_start then
      v_days := v_end - v_start + 1;
      v_charge := v_charge + v_monthly * v_days / v_month_days;
    end if;
    d := (d + interval '1 month')::date;
  end loop;
  return round(v_charge, 2);
end $$;

-- What accumulated depreciation should be by a date: what was there when the asset entered the books, plus straight line since.
create or replace function private.asset_expected(a public.fixed_assets, p_to date) returns numeric
language sql stable security definer set search_path = public, private as $$
  select least(a.cost - a.residual, a.opening_accumulated + private.asset_charge(a, coalesce(a.depreciate_from, a.available_date), p_to))
$$;

create or replace function private.asset_json(p_asset uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(a) || jsonb_build_object('class_name', ac.name, 'accum_account', ac.accum_account, 'depreciates', ac.depreciates,
    'accumulated', private.asset_accumulated(a.id), 'carrying_amount', a.cost - private.asset_accumulated(a.id),
    'monthly_charge', case when a.life_months > 0 and ac.depreciates then round((a.cost - a.residual) / a.life_months, 2) end,
    'location_name', (select name from locations where id = a.location_id), 'bill_number', (select number from bills where id = a.bill_id),
    'vendor_name', (select v.name from bills b join vendors v on v.id = b.vendor_id where b.id = a.bill_id))
  from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account where a.id = p_asset
$$;

create or replace function public.get_assets(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see the asset register.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'assets', (select coalesce(jsonb_agg(private.asset_json(a.id) order by a.number), '[]'::jsonb) from fixed_assets a where a.org_id = p_org and a.status <> 'rejected'),
    'classes', (select jsonb_agg(to_jsonb(c) order by c.cost_account) from asset_classes c),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('period_end', r.period_end, 'total', r.total, 'journal_ref', (select ref from journals where id = r.journal_id))
        order by r.period_end desc), '[]'::jsonb) from depreciation_runs r where r.org_id = p_org),
    'threshold', (select capitalisation_threshold from orgs where id = p_org),
    -- FA-01: the register must agree with the ledger, class by class.
    'reconciliation', (select coalesce(jsonb_agg(jsonb_build_object('class', c.cost_account, 'name', c.name,
        'register_cost', (select coalesce(sum(cost), 0) from fixed_assets where org_id = p_org and class_account = c.cost_account and status in ('active', 'pending_confirmation')),
        'ledger_cost', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c.cost_account),
        'register_accumulated', (select coalesce(sum(private.asset_accumulated(id)), 0) from fixed_assets where org_id = p_org and class_account = c.cost_account and status = 'active'),
        'ledger_accumulated', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and account_code = c.accum_account))), '[]'::jsonb)
      from asset_classes c where exists (select 1 from journal_lines where org_id = p_org and account_code in (c.cost_account, c.accum_account))
        or exists (select 1 from fixed_assets where org_id = p_org and class_account = c.cost_account)));
end $$;

-- Confirms an asset's class, date in use, life and residual value; depreciation starts from then. A change of class moves the cost.
create or replace function public.confirm_asset(p_asset uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.fixed_assets; m public.members; v_class text; v_life int;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if a.status not in ('pending_confirmation', 'active') then raise exception '% is %.', a.number, a.status; end if;
  v_class := coalesce(nullif(p->>'class_account', ''), a.class_account);
  if not exists (select 1 from asset_classes where cost_account = v_class) then raise exception 'Unknown asset class.'; end if;
  v_life := coalesce(nullif(p->>'life_months', '')::int, a.life_months, (select default_life_months from asset_classes where cost_account = v_class));
  if (select depreciates from asset_classes where cost_account = v_class) and (v_life is null or v_life < 1) then raise exception 'Enter the useful life in months.'; end if;
  if a.status = 'active' and exists (select 1 from journal_lines where party_type = 'asset' and party_id = a.id) and (v_class <> a.class_account) then
    raise exception 'Depreciation has started on %. Its class can no longer change.', a.number;
  end if;
  if v_class <> a.class_account then
    perform private.post_entry(a.org_id, 'Asset ' || a.number || ' reclassified to ' || (select name from asset_classes where cost_account = v_class), 'asset', a.id, m.id, m.id,
      private.reclass_pair(v_class, a.class_account, a.cost, a.location_id, null), now());
  end if;
  update fixed_assets set class_account = v_class, life_months = v_life, name = coalesce(nullif(trim(p->>'name'), ''), name),
    available_date = coalesce(nullif(p->>'available_date', '')::date, available_date), residual = coalesce(private.num(p->>'residual'), residual),
    depreciate_from = coalesce(nullif(p->>'available_date', '')::date, available_date),
    location_id = coalesce((select id from locations where id = nullif(p->>'location_id', '')::uuid and org_id = a.org_id), location_id),
    serial_no = case when p ? 'serial_no' then nullif(trim(p->>'serial_no'), '') else serial_no end,
    status = 'active', confirmed_by = m.id, confirmed_at = now()
  where id = a.id returning * into a;
  if a.residual > a.cost then raise exception 'The residual value is more than the cost.'; end if;
  return private.asset_json(a.id);
end $$;

-- Not an asset after all: the cost goes to an expense account (FA-02).
create or replace function public.reject_asset(p_asset uuid, p_expense_account text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.fixed_assets; m public.members;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if a.status <> 'pending_confirmation' then raise exception 'Only an asset waiting for confirmation can be expensed.'; end if;
  if coalesce(p_expense_account, '') !~ '^[5-6]' or not private.postable(a.org_id, p_expense_account) then raise exception 'Choose the expense account.'; end if;
  perform private.post_entry(a.org_id, 'Not capitalised: ' || a.name, 'asset', a.id, m.id, m.id,
    private.reclass_pair(p_expense_account, a.class_account, a.cost, a.location_id, null), now());
  update fixed_assets set status = 'rejected', confirmed_by = m.id, confirmed_at = now() where id = a.id;
  return jsonb_build_object('status', 'rejected', 'number', a.number);
end $$;

-- An asset bought before the books started, or paid for outside a bill.
-- p: {name, class_account, cost, accumulated, available_date, life_months, residual, location_id, funding: 'opening'|'bank'|'vendor', bank_account_id, vendor_id, date}
create or replace function public.add_asset(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; a public.fixed_assets; ac public.asset_classes; v_cost numeric := round(private.num(p->>'cost'), 2); v_acc numeric := round(coalesce(private.num(p->>'accumulated'), 0), 2);
  v_credit text; v_party uuid; v_fund text := coalesce(nullif(p->>'funding', ''), 'opening'); v_day date; v_at timestamptz; j public.journals;
begin
  m := private.require(p_org, 'keep_books');
  select * into ac from asset_classes where cost_account = p->>'class_account';
  if not found then raise exception 'Choose the asset class.'; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Name the asset.'; end if;
  if coalesce(v_cost, 0) <= 0 then raise exception 'Enter the cost.'; end if;
  if v_acc < 0 or v_acc > v_cost then raise exception 'Accumulated depreciation must be between zero and the cost.'; end if;
  if v_fund = 'opening' then
    v_credit := private.acct(p_org, 'opening_equity');
    v_day := coalesce((select books_start - 1 from orgs where id = p_org), nullif(p->>'date', '')::date, private.local_day(p_org, now()));
  elsif v_fund = 'bank' then
    select ledger_code into v_credit from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = p_org and active;
    if v_credit is null then raise exception 'Choose the account it was paid from.'; end if;
    if v_acc > 0 then raise exception 'A new purchase has no depreciation yet.'; end if;
  elsif v_fund = 'vendor' then
    v_party := nullif(p->>'vendor_id', '')::uuid;
    if not exists (select 1 from vendors where id = v_party and org_id = p_org) then raise exception 'Choose the vendor.'; end if;
    v_credit := private.acct(p_org, 'payables');
    if v_acc > 0 then raise exception 'A new purchase has no depreciation yet.'; end if;
  else
    raise exception 'Say how the asset was paid for.';
  end if;
  v_day := coalesce(v_day, nullif(p->>'date', '')::date, nullif(p->>'available_date', '')::date, private.local_day(p_org, now()));
  v_at := (v_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos');
  insert into fixed_assets (org_id, number, name, class_account, cost, residual, life_months, available_date, status, location_id, serial_no, opening_accumulated,
    depreciate_from, created_by, confirmed_by, confirmed_at)
  values (p_org, 'FA-' || lpad(private.next_no(p_org, 'FA', 1)::text, 4, '0'), trim(p->>'name'), ac.cost_account, v_cost, coalesce(private.num(p->>'residual'), 0),
    coalesce(nullif(p->>'life_months', '')::int, ac.default_life_months), coalesce(nullif(p->>'available_date', '')::date, v_day), 'active',
    (select id from locations where id = nullif(p->>'location_id', '')::uuid and org_id = p_org), nullif(trim(p->>'serial_no'), ''),
    case when v_fund = 'opening' then v_acc else 0 end,
    case when v_fund = 'opening' then v_day + 1 else coalesce(nullif(p->>'available_date', '')::date, v_day) end, m.id, m.id, now())
  returning * into a;
  j := private.post_entry(p_org, 'Asset ' || a.number || ' · ' || a.name, 'asset', a.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', ac.cost_account, 'debit', v_cost, 'location_id', a.location_id, 'memo', a.name),
      jsonb_build_object('code', v_credit, 'credit', v_cost - case when v_fund = 'opening' then v_acc else 0 end,
        'party_type', case when v_party is not null then 'vendor' end, 'party_id', v_party),
      jsonb_build_object('code', ac.accum_account, 'credit', case when v_fund = 'opening' then v_acc else 0 end, 'memo', 'Depreciation before the books started')),
    v_at, jsonb_build_object('origin', 'manual'));
  update fixed_assets set journal_id = j.id where id = a.id;
  return private.asset_json(a.id);
end $$;

-- Monthly depreciation (FA-03), by code from the register. Runs each month up to p_through that has not been run.
create or replace function private.depreciate(p_org uuid, p_through date, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_last date; v_month date; a record; v_charge numeric; v_lines jsonb; v_jl jsonb; v_total numeric; j public.journals; v_runs jsonb := '[]'::jsonb;
  v_start date;
begin
  select max(period_end) into v_last from depreciation_runs where org_id = p_org;
  -- The first run starts where depreciation first falls due, never inside a closed month; later runs catch up anything missed.
  v_month := (date_trunc('month', coalesce(v_last + 1,
                greatest((select min(coalesce(depreciate_from, available_date)) from fixed_assets where org_id = p_org and status = 'active'),
                         coalesce(private.closed_through(p_org) + 1, '1900-01-01'::date)), p_through))
              + interval '1 month' - interval '1 day')::date;
  while v_month <= p_through loop
    v_start := date_trunc('month', v_month)::date;
    v_lines := '[]'::jsonb; v_jl := '[]'::jsonb; v_total := 0;
    for a in select fa.*, ac.accum_account, ac.expense_account from fixed_assets fa join asset_classes ac on ac.cost_account = fa.class_account
             where fa.org_id = p_org and fa.status = 'active' and ac.depreciates order by fa.number loop
      -- Whatever is due by the month end and not yet charged, so an asset added late catches up.
      v_charge := round(private.asset_expected((select x from fixed_assets x where x.id = a.id), v_month) - private.asset_accumulated(a.id), 2);
      continue when v_charge <= 0;
      v_total := v_total + v_charge;
      v_lines := v_lines || jsonb_build_object('asset_id', a.id, 'number', a.number, 'name', a.name, 'charge', v_charge);
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', a.expense_account, 'debit', v_charge, 'location_id', a.location_id, 'memo', a.number || ' · ' || a.name),
        jsonb_build_object('code', a.accum_account, 'credit', v_charge, 'location_id', a.location_id, 'party_type', 'asset', 'party_id', a.id, 'memo', a.number));
    end loop;
    if v_total > 0 then
      j := private.post_entry(p_org, 'Depreciation · ' || to_char(v_month, 'FMMonth YYYY'), 'depreciation', null, m.id, m.id, v_jl,
        (v_month::timestamp + interval '23 hours') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos'),
        jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'register', 'assets', jsonb_array_length(v_lines)))));
    else
      j := null;
    end if;
    insert into depreciation_runs (org_id, period_end, total, lines, journal_id, created_by) values (p_org, v_month, v_total, v_lines, j.id, m.id);
    v_runs := v_runs || jsonb_build_object('period_end', v_month, 'total', v_total, 'journal_ref', j.ref);
    v_month := (date_trunc('month', v_month) + interval '2 months' - interval '1 day')::date;
  end loop;
  return v_runs;
end $$;

create or replace function public.run_depreciation(p_org uuid, p_through date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_through date;
begin
  m := private.require(p_org, 'keep_books');
  v_through := coalesce(p_through, (date_trunc('month', private.local_day(p_org, now())) - interval '1 day')::date);
  if v_through <> (date_trunc('month', v_through) + interval '1 month' - interval '1 day')::date then raise exception 'Depreciation runs to a month end.'; end if;
  if v_through > private.local_day(p_org, now()) + 31 then raise exception 'Depreciation cannot run that far ahead.'; end if;
  perform private.require_open_day(p_org, v_through);
  return private.depreciate(p_org, v_through, m);
end $$;

-- Disposal (FA-04): depreciate to the date, take out cost and accumulated depreciation, record proceeds, gain or loss.
-- p: {date, proceeds, bank_account_id | customer_id (sold on credit), reason}
create or replace function public.dispose_asset(p_asset uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.fixed_assets; ac public.asset_classes; m public.members; v_day date; v_proceeds numeric := round(coalesce(private.num(p->>'proceeds'), 0), 2);
  v_charge numeric; v_acc numeric; v_carry numeric; v_jl jsonb; j public.journals; v_bank text; v_cust uuid; v_at timestamptz; v_gain numeric;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if a.status <> 'active' then raise exception '% is %.', a.number, replace(a.status, '_', ' '); end if;
  select * into ac from asset_classes where cost_account = a.class_account;
  v_day := coalesce(nullif(p->>'date', '')::date, private.local_day(a.org_id, now()));
  perform private.require_open_day(a.org_id, v_day);
  if v_proceeds < 0 then raise exception 'Proceeds cannot be negative.'; end if;
  if v_proceeds > 0 then
    v_cust := nullif(p->>'customer_id', '')::uuid;
    if v_cust is null then
      select ledger_code into v_bank from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = a.org_id and active;
      if v_bank is null then raise exception 'Choose where the proceeds went, or the customer who owes them.'; end if;
    elsif not exists (select 1 from customers where id = v_cust and org_id = a.org_id) then
      raise exception 'Customer not found.';
    end if;
  end if;
  v_at := (v_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = a.org_id), 'Africa/Lagos');
  -- Depreciation for the part of the month before disposal, if the month has not been run.
  if ac.depreciates then
    v_charge := round(private.asset_expected(a, v_day) - private.asset_accumulated(a.id), 2);
    if v_charge > 0 then
      perform private.post_entry(a.org_id, 'Depreciation to disposal · ' || a.number, 'depreciation', a.id, m.id, m.id, jsonb_build_array(
        jsonb_build_object('code', ac.expense_account, 'debit', v_charge, 'location_id', a.location_id, 'memo', a.number),
        jsonb_build_object('code', ac.accum_account, 'credit', v_charge, 'location_id', a.location_id, 'party_type', 'asset', 'party_id', a.id, 'memo', a.number)), v_at);
    end if;
  end if;
  v_acc := coalesce(private.asset_accumulated(a.id), 0);
  v_carry := a.cost - v_acc;
  v_gain := v_proceeds - v_carry;
  v_jl := jsonb_build_array(
    jsonb_build_object('code', ac.cost_account, 'credit', a.cost, 'location_id', a.location_id, 'memo', 'Cost of ' || a.number),
    jsonb_build_object('code', coalesce(ac.accum_account, ac.cost_account), 'debit', case when ac.accum_account is null then 0 else v_acc - a.opening_accumulated end,
      'party_type', 'asset', 'party_id', a.id, 'memo', 'Depreciation on ' || a.number),
    jsonb_build_object('code', coalesce(ac.accum_account, ac.cost_account), 'debit', case when ac.accum_account is null then 0 else a.opening_accumulated end,
      'memo', 'Opening depreciation on ' || a.number),
    jsonb_build_object('code', coalesce(v_bank, private.acct(a.org_id, 'receivables')), 'debit', v_proceeds,
      'party_type', case when v_cust is not null then 'customer' end, 'party_id', v_cust, 'memo', 'Proceeds from ' || a.number),
    jsonb_build_object('code', '4508', 'credit', greatest(v_gain, 0), 'memo', 'Gain on ' || a.number),
    jsonb_build_object('code', '6804', 'debit', greatest(-v_gain, 0), 'memo', 'Loss on ' || a.number));
  j := private.post_entry(a.org_id, 'Disposal of ' || a.number || ' · ' || a.name || coalesce(' · ' || nullif(trim(p->>'reason'), ''), ''), 'asset_disposal', a.id, m.id, m.id, v_jl, v_at);
  update fixed_assets set status = 'disposed', disposed_at = v_day, proceeds = v_proceeds, disposal_journal_id = j.id,
    notes = concat_ws(' · ', notes, nullif(trim(p->>'reason'), '')) where id = a.id;
  return private.asset_json(a.id) || jsonb_build_object('gain', v_gain);
end $$;

grant execute on function public.save_bill(uuid, jsonb), public.approve_bill(uuid), public.void_bill(uuid, text), public.pay_bill(uuid, jsonb),
  public.get_bills(uuid, jsonb), public.get_bill(uuid), public.save_vendor_details(uuid, uuid, jsonb), public.vendor_statement(uuid, date, date),
  public.get_assets(uuid), public.confirm_asset(uuid, jsonb), public.reject_asset(uuid, text), public.add_asset(uuid, jsonb), public.run_depreciation(uuid, date),
  public.dispose_asset(uuid, jsonb) to authenticated;
revoke execute on function public.save_bill(uuid, jsonb), public.approve_bill(uuid), public.void_bill(uuid, text), public.pay_bill(uuid, jsonb),
  public.get_bills(uuid, jsonb), public.get_bill(uuid), public.save_vendor_details(uuid, uuid, jsonb), public.vendor_statement(uuid, date, date),
  public.get_assets(uuid), public.confirm_asset(uuid, jsonb), public.reject_asset(uuid, text), public.add_asset(uuid, jsonb), public.run_depreciation(uuid, date),
  public.dispose_asset(uuid, jsonb) from public, anon;
revoke execute on function public.svc_prism_bill(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_prism_bill(uuid, jsonb) to service_role;
revoke execute on function private.fill_line_party(), private.wht_rate(uuid, text), private.vendor_balance(uuid, uuid), private.bill_account_ok(uuid, text),
  private.write_bill(uuid, jsonb, public.members), private.post_bill(uuid, public.members), private.refresh_bill(uuid), private.bill_json(uuid),
  private.on_payout_change(), private.bill_from_receipt(uuid), private.on_receipt_posted(), private.asset_accumulated(uuid),
  private.asset_charge(public.fixed_assets, date, date), private.asset_expected(public.fixed_assets, date), private.asset_json(uuid), private.depreciate(uuid, date, public.members) from public, anon, authenticated;
