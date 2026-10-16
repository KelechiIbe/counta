-- Counta (TaxStreem Inventory) — core schema
-- Inventory is a sub-ledger of Atlas: every stock movement carries a journal.
-- Movements are append-only. All postings go through security-definer RPCs.

create schema if not exists private;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Chart of accounts used by the inventory sub-ledger
-- ---------------------------------------------------------------------------
create table public.accounts (
  code text primary key,
  name text not null,
  kind text not null check (kind in ('asset','liability','equity','expense','income'))
);
insert into public.accounts (code, name, kind) values
  ('1310', 'Inventory – stock on hand', 'asset'),
  ('1315', 'Goods in transit', 'asset'),
  ('1420', 'Input VAT receivable', 'asset'),
  ('2010', 'Accounts payable', 'liability'),
  ('3100', 'Opening balance equity', 'equity'),
  ('5100', 'Cost of sales', 'expense'),
  ('5200', 'Inventory shrinkage', 'expense');

-- ---------------------------------------------------------------------------
-- Businesses, branches, people
-- ---------------------------------------------------------------------------
create table public.orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  email text,
  phone text,
  timezone text not null default 'Africa/Lagos',
  vat_registered boolean not null default true,
  margin_threshold numeric(5,2) not null default 8 check (margin_threshold >= 0 and margin_threshold < 100),
  safety_days int not null default 3 check (safety_days >= 0),
  cover_days int not null default 10 check (cover_days >= 1),
  cash_available numeric(16,2),
  voice_trust_threshold int not null default 20,
  is_sample boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  code text not null,
  address text,
  is_main boolean not null default false,
  created_at timestamptz not null default now(),
  unique (org_id, code)
);
create index locations_org on public.locations(org_id);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text,
  display_name text not null,
  phone text,
  role text not null default 'staff' check (role in ('owner','manager','staff','cashier')),
  title text,
  location_id uuid references public.locations(id) on delete set null,
  status text not null default 'active' check (status in ('active','invited','disabled')),
  p_record_sales boolean not null default false,
  p_receive_stock boolean not null default false,
  p_count_stock boolean not null default false,
  p_approve_adjustments boolean not null default false,
  p_edit_prices boolean not null default false,
  p_approve_pos boolean not null default false,
  p_transfer_stock boolean not null default false,
  p_see_margins boolean not null default false,
  voice_confirmed int not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, user_id),
  -- Hard rule: whoever records sales can never edit quantities, costs or prices.
  constraint sales_cannot_edit check (
    role = 'owner' or not (p_record_sales and (p_edit_prices or p_approve_adjustments))
  )
);
create unique index members_org_email on public.members(org_id, lower(email)) where email is not null;
create index members_user on public.members(user_id);

create table public.org_counters (
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null,
  next_val int not null,
  primary key (org_id, kind)
);

-- ---------------------------------------------------------------------------
-- Vendors and the item master
-- ---------------------------------------------------------------------------
create table public.vendors (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  location text,
  channel text not null default 'whatsapp' check (channel in ('whatsapp','email','phone')),
  phone text,
  email text,
  vat_registered boolean not null default false,
  lead_time_days int not null default 2 check (lead_time_days >= 0),
  credit_days int not null default 0 check (credit_days >= 0),
  fill_rate numeric(5,2),
  price_stability text check (price_stability in ('High','Medium','Low')),
  notes text,
  created_at timestamptz not null default now()
);
create index vendors_org on public.vendors(org_id);

create table public.items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  photo_path text,
  barcode text,
  sku text,
  qr_code text not null default ('CT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  category text not null default 'General',
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard','zero','exempt')),
  nafdac_no text,
  purchase_unit text not null default 'Carton',
  pack_size int not null default 1 check (pack_size >= 1),
  selling_unit text not null default 'piece',
  informal_unit boolean not null default false,
  track_batches boolean not null default false,
  reorder_floor numeric(14,3) not null default 0 check (reorder_floor >= 0),
  preferred_vendor_id uuid references public.vendors(id) on delete set null,
  alt_vendor_id uuid references public.vendors(id) on delete set null,
  price numeric(14,2) not null check (price > 0),
  import_priced boolean not null default false,
  notes jsonb not null default '{}'::jsonb,
  needs_review boolean not null default false,
  archived boolean not null default false,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index items_org on public.items(org_id);
create unique index items_org_barcode on public.items(org_id, barcode) where barcode is not null and barcode <> '';
create unique index items_qr on public.items(qr_code);

-- Cost fields live apart so people without "See margins" never receive them.
create table public.item_costs (
  item_id uuid primary key references public.items(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  wac numeric(14,4) not null default 0 check (wac >= 0),
  last_cost numeric(14,4),
  replacement_cost numeric(14,4),
  replacement_source text,
  updated_at timestamptz not null default now()
);
create index item_costs_org on public.item_costs(org_id);

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------
create table public.journals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  je_no int not null,
  ref text generated always as ('JE-' || je_no::text) stored,
  entry_date date not null,
  memo text not null,
  source_type text not null,
  source_id uuid,
  posted_by uuid references public.members(id) on delete set null,
  approved_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, je_no)
);
create index journals_org on public.journals(org_id, created_at desc);

create table public.journal_lines (
  id bigint generated always as identity primary key,
  journal_id uuid not null references public.journals(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  account_code text not null references public.accounts(code),
  debit numeric(16,2) not null default 0 check (debit >= 0),
  credit numeric(16,2) not null default 0 check (credit >= 0),
  location_id uuid references public.locations(id) on delete set null,
  item_id uuid references public.items(id) on delete set null,
  memo text
);
create index journal_lines_journal on public.journal_lines(journal_id);
create index journal_lines_org on public.journal_lines(org_id, account_code);

-- ---------------------------------------------------------------------------
-- Batches, documents, receipts
-- ---------------------------------------------------------------------------
create table public.batches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  batch_no text not null,
  expiry_date date,
  qty_received numeric(14,3) not null default 0,
  qty_remaining numeric(14,3) not null default 0,
  quarantined boolean not null default false,
  quarantined_at timestamptz,
  quarantined_by uuid references public.members(id) on delete set null,
  receipt_id uuid,
  created_at timestamptz not null default now()
);
create index batches_item on public.batches(item_id, location_id, expiry_date);
create index batches_org on public.batches(org_id);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  ref text not null,
  vendor_id uuid references public.vendors(id) on delete set null,
  vendor_name text,
  location_id uuid references public.locations(id) on delete set null,
  source text not null check (source in ('pdf','photo_typed','photo_handwritten','manual')),
  document_path text,
  document_mime text,
  invoice_no text,
  invoice_date date,
  vendor_vat_registered boolean not null default false,
  prices_include_vat boolean not null default false,
  status text not null default 'needs_review' check (status in ('reading','needs_review','posted','discarded')),
  net numeric(16,2) not null default 0,
  input_vat numeric(16,2) not null default 0,
  gross numeric(16,2) not null default 0,
  journal_id uuid references public.journals(id) on delete set null,
  po_id uuid,
  ai_model text,
  ai_error text,
  device_id text,
  offline boolean not null default false,
  client_uuid uuid unique,
  created_by uuid references public.members(id) on delete set null,
  posted_by uuid references public.members(id) on delete set null,
  posted_at timestamptz,
  created_at timestamptz not null default now()
);
create index receipts_org on public.receipts(org_id, created_at desc);

create table public.receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.receipts(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  line_no int not null default 1,
  raw_text text,
  item_id uuid references public.items(id) on delete set null,
  new_item jsonb,
  qty numeric(14,3) not null default 0,
  unit_kind text not null default 'purchase' check (unit_kind in ('purchase','selling')),
  unit_label text,
  unit_cost numeric(14,4) not null default 0,
  confidence int not null default 100 check (confidence between 0 and 100),
  alt_reading jsonb,
  bbox int[],
  confirmed boolean not null default true,
  model_reading jsonb,
  batch_no text,
  expiry_date date,
  created_at timestamptz not null default now()
);
create index receipt_lines_receipt on public.receipt_lines(receipt_id, line_no);

create table public.ocr_corrections (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  receipt_id uuid references public.receipts(id) on delete cascade,
  line_id uuid,
  raw_text text,
  model_reading jsonb,
  user_reading jsonb,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index ocr_corrections_org on public.ocr_corrections(org_id);

-- ---------------------------------------------------------------------------
-- Movements (append-only) and derived balances
-- ---------------------------------------------------------------------------
create table public.movements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  type text not null check (type in ('opening','receipt','sale','voice_sale','transfer_out','transfer_in','adjustment','write_off','quarantine')),
  item_id uuid not null references public.items(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  qty numeric(14,3) not null,
  unit_cost numeric(14,4) not null default 0,
  unit_price numeric(14,2),
  value numeric(16,2) generated always as (round(qty * unit_cost, 2)) stored,
  journal_id uuid references public.journals(id) on delete set null,
  receipt_id uuid references public.receipts(id) on delete set null,
  transfer_id uuid,
  count_session_id uuid,
  batch_id uuid references public.batches(id) on delete set null,
  reason text,
  note text,
  channel text not null default 'App',
  author_id uuid references public.members(id) on delete set null,
  approver_id uuid references public.members(id) on delete set null,
  device_id text,
  offline boolean not null default false,
  client_uuid uuid unique,
  review_status text check (review_status in ('pending','reviewed')),
  recorded_at timestamptz not null default now(),
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index movements_org_time on public.movements(org_id, recorded_at desc);
create index movements_item on public.movements(item_id, location_id, recorded_at desc);
create index movements_type on public.movements(org_id, type, recorded_at desc);
create index movements_journal on public.movements(journal_id);

create table public.stock_levels (
  item_id uuid not null references public.items(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  qty numeric(14,3) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (item_id, location_id)
);
create index stock_levels_org on public.stock_levels(org_id);

create or replace function private.apply_movement() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.stock_levels (item_id, location_id, org_id, qty, updated_at)
  values (new.item_id, new.location_id, new.org_id, new.qty, now())
  on conflict (item_id, location_id)
  do update set qty = public.stock_levels.qty + excluded.qty, updated_at = now();
  return new;
end $$;
create trigger movements_apply after insert on public.movements
  for each row execute function private.apply_movement();

-- Append-only guard. Only review_status may change; deletes only during a purge.
create or replace function private.guard_movements() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.allow_purge', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE' then
    raise exception 'Movements are append-only. Post a correcting movement instead.';
  end if;
  if (new.type, new.item_id, new.location_id, new.qty, new.unit_cost, new.unit_price, new.journal_id, new.author_id, new.recorded_at)
     is distinct from
     (old.type, old.item_id, old.location_id, old.qty, old.unit_cost, old.unit_price, old.journal_id, old.author_id, old.recorded_at) then
    raise exception 'Movements are append-only. Post a correcting movement instead.';
  end if;
  return new;
end $$;
create trigger movements_guard before update or delete on public.movements
  for each row execute function private.guard_movements();

create or replace function private.guard_journals() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.allow_purge', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'Posted journals cannot be changed. Post a reversing entry instead.';
end $$;
create trigger journals_guard before update or delete on public.journals
  for each row execute function private.guard_journals();
create trigger journal_lines_guard before update or delete on public.journal_lines
  for each row execute function private.guard_journals();

-- ---------------------------------------------------------------------------
-- Stock counts
-- ---------------------------------------------------------------------------
create table public.count_sessions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  ref text not null,
  location_id uuid not null references public.locations(id) on delete cascade,
  area text not null default 'Whole store',
  assignee_id uuid references public.members(id) on delete set null,
  status text not null default 'open' check (status in ('open','awaiting_reasons','awaiting_approval','approved')),
  created_by uuid references public.members(id) on delete set null,
  submitted_at timestamptz,
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  device_id text,
  offline boolean not null default false,
  client_uuid uuid unique,
  rejected_count int not null default 0,
  created_at timestamptz not null default now()
);
create index count_sessions_org on public.count_sessions(org_id, created_at desc);

create table public.count_lines (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.count_sessions(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  expected numeric(14,3),
  counted numeric(14,3),
  reason text check (reason in ('Breakage','Expired','Theft suspected','Miscount','Unrecorded sale','Other')),
  note text,
  unique (session_id, item_id)
);

-- ---------------------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------------------
create table public.price_proposals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  kind text not null check (kind in ('cost_increase','below_replacement','margin_compressed')),
  old_cost numeric(14,4) not null,
  new_cost numeric(14,4) not null,
  old_price numeric(14,2) not null,
  suggested_price numeric(14,2) not null,
  target_margin numeric(6,2),
  source_ref text,
  status text not null default 'open' check (status in ('open','applied','dismissed')),
  decided_by uuid references public.members(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index price_proposals_org on public.price_proposals(org_id, status);
create unique index price_proposals_one_open on public.price_proposals(item_id) where status = 'open';

create table public.price_changes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  old_price numeric(14,2) not null,
  new_price numeric(14,2) not null,
  reason text not null,
  proposal_id uuid references public.price_proposals(id) on delete set null,
  changed_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index price_changes_item on public.price_changes(item_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Purchasing
-- ---------------------------------------------------------------------------
create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  ref text not null,
  vendor_id uuid references public.vendors(id) on delete set null,
  location_id uuid references public.locations(id) on delete set null,
  status text not null default 'draft' check (status in ('draft','sent','received','cancelled')),
  sent_via text,
  total numeric(16,2) not null default 0,
  fx_note text,
  note text,
  created_by uuid references public.members(id) on delete set null,
  approved_by uuid references public.members(id) on delete set null,
  sent_at timestamptz,
  received_at timestamptz,
  created_at timestamptz not null default now()
);
create index purchase_orders_org on public.purchase_orders(org_id, created_at desc);

create table public.po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,4) not null default 0,
  total numeric(16,2) generated always as (round(qty * unit_cost, 2)) stored
);
create index po_lines_po on public.po_lines(po_id);

create table public.reorder_snoozes (
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  until date not null,
  snoozed_by uuid references public.members(id) on delete set null,
  primary key (org_id, item_id)
);

-- ---------------------------------------------------------------------------
-- Transfers
-- ---------------------------------------------------------------------------
create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  ref text not null,
  item_id uuid not null references public.items(id) on delete cascade,
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,4) not null default 0,
  from_location_id uuid not null references public.locations(id) on delete cascade,
  to_location_id uuid not null references public.locations(id) on delete cascade,
  status text not null default 'in_transit' check (status in ('in_transit','received')),
  batch_alloc jsonb not null default '[]'::jsonb,
  created_by uuid references public.members(id) on delete set null,
  received_by uuid references public.members(id) on delete set null,
  client_uuid uuid unique,
  created_at timestamptz not null default now(),
  received_at timestamptz,
  check (from_location_id <> to_location_id)
);
create index transfers_org on public.transfers(org_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Cash vs stock inputs, FX, AI log
-- ---------------------------------------------------------------------------
create table public.cash_takings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  cash numeric(16,2) not null default 0,
  pos numeric(16,2) not null default 0,
  transfers numeric(16,2) not null default 0,
  source text not null default 'manual',
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, location_id, day)
);

create table public.fx_rates (
  day date primary key,
  usd_ngn numeric(12,4) not null,
  source text not null default 'open.er-api.com',
  fetched_at timestamptz not null default now()
);

create table public.ai_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.orgs(id) on delete cascade,
  member_id uuid references public.members(id) on delete set null,
  kind text not null,
  model text,
  input jsonb,
  output jsonb,
  ok boolean not null default true,
  created_at timestamptz not null default now()
);
create index ai_logs_org on public.ai_logs(org_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helper functions (private schema, used by policies and RPCs)
-- ---------------------------------------------------------------------------
create or replace function private.me(p_org uuid) returns public.members
language sql stable security definer set search_path = public as $$
  select m.* from public.members m
  where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
  limit 1
$$;

create or replace function private.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m
    where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active')
$$;

create or replace function private.is_member_text(p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m
    where m.org_id::text = p_org and m.user_id = auth.uid() and m.status = 'active')
$$;

create or replace function private.perm_of(m public.members, p_perm text) returns boolean
language sql immutable as $$
  select case
    when m.id is null then false
    when m.role = 'owner' then true
    else case p_perm
      when 'record_sales' then m.p_record_sales
      when 'receive_stock' then m.p_receive_stock
      when 'count_stock' then m.p_count_stock
      when 'approve_adjustments' then m.p_approve_adjustments
      when 'edit_prices' then m.p_edit_prices
      when 'approve_pos' then m.p_approve_pos
      when 'transfer_stock' then m.p_transfer_stock
      when 'see_margins' then m.p_see_margins
      when 'owner' then false
      else false end
  end
$$;

create or replace function private.has_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(private.perm_of(private.me(p_org), p_perm), false)
$$;

create or replace function private.is_owner(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m
    where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role = 'owner')
$$;

create or replace function private.can_see_costs(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.has_perm(p_org, 'see_margins') or private.has_perm(p_org, 'edit_prices')
$$;

grant execute on all functions in schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.accounts enable row level security;
alter table public.orgs enable row level security;
alter table public.locations enable row level security;
alter table public.members enable row level security;
alter table public.org_counters enable row level security;
alter table public.vendors enable row level security;
alter table public.items enable row level security;
alter table public.item_costs enable row level security;
alter table public.journals enable row level security;
alter table public.journal_lines enable row level security;
alter table public.batches enable row level security;
alter table public.receipts enable row level security;
alter table public.receipt_lines enable row level security;
alter table public.ocr_corrections enable row level security;
alter table public.movements enable row level security;
alter table public.stock_levels enable row level security;
alter table public.count_sessions enable row level security;
alter table public.count_lines enable row level security;
alter table public.price_proposals enable row level security;
alter table public.price_changes enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.po_lines enable row level security;
alter table public.reorder_snoozes enable row level security;
alter table public.transfers enable row level security;
alter table public.cash_takings enable row level security;
alter table public.fx_rates enable row level security;
alter table public.ai_logs enable row level security;

create policy accounts_read on public.accounts for select to authenticated using (true);
create policy fx_read on public.fx_rates for select to authenticated using (true);

create policy orgs_read on public.orgs for select to authenticated using ((select private.is_member(id)));
create policy orgs_update on public.orgs for update to authenticated
  using ((select private.is_owner(id))) with check ((select private.is_owner(id)));

create policy locations_read on public.locations for select to authenticated using ((select private.is_member(org_id)));
create policy locations_insert on public.locations for insert to authenticated with check ((select private.is_owner(org_id)));
create policy locations_update on public.locations for update to authenticated
  using ((select private.is_owner(org_id))) with check ((select private.is_owner(org_id)));

create policy members_read on public.members for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_member(org_id)));

create policy vendors_read on public.vendors for select to authenticated using ((select private.is_member(org_id)));
create policy vendors_insert on public.vendors for insert to authenticated
  with check ((select private.has_perm(org_id, 'receive_stock')) or (select private.has_perm(org_id, 'approve_pos')));
create policy vendors_update on public.vendors for update to authenticated
  using ((select private.has_perm(org_id, 'approve_pos')) or (select private.has_perm(org_id, 'receive_stock')))
  with check ((select private.has_perm(org_id, 'approve_pos')) or (select private.has_perm(org_id, 'receive_stock')));

create policy items_read on public.items for select to authenticated using ((select private.is_member(org_id)));
create policy item_costs_read on public.item_costs for select to authenticated using ((select private.can_see_costs(org_id)));

create policy journals_read on public.journals for select to authenticated using ((select private.can_see_costs(org_id)));
create policy journal_lines_read on public.journal_lines for select to authenticated using ((select private.can_see_costs(org_id)));

create policy batches_read on public.batches for select to authenticated using ((select private.is_member(org_id)));
create policy stock_levels_read on public.stock_levels for select to authenticated using ((select private.is_member(org_id)));
create policy movements_read on public.movements for select to authenticated using ((select private.can_see_costs(org_id)));

create policy receipts_read on public.receipts for select to authenticated
  using ((select private.has_perm(org_id, 'receive_stock')) or (select private.can_see_costs(org_id)));
create policy receipts_insert on public.receipts for insert to authenticated
  with check ((select private.has_perm(org_id, 'receive_stock')) and status in ('reading','needs_review'));
create policy receipts_update on public.receipts for update to authenticated
  using ((select private.has_perm(org_id, 'receive_stock')) and status in ('reading','needs_review'))
  with check ((select private.has_perm(org_id, 'receive_stock')) and status in ('reading','needs_review','discarded'));

create policy receipt_lines_read on public.receipt_lines for select to authenticated
  using ((select private.has_perm(org_id, 'receive_stock')) or (select private.can_see_costs(org_id)));
create policy receipt_lines_write on public.receipt_lines for insert to authenticated
  with check ((select private.has_perm(org_id, 'receive_stock'))
    and exists (select 1 from public.receipts r where r.id = receipt_id and r.org_id = receipt_lines.org_id and r.status in ('reading','needs_review')));
create policy receipt_lines_update on public.receipt_lines for update to authenticated
  using ((select private.has_perm(org_id, 'receive_stock'))
    and exists (select 1 from public.receipts r where r.id = receipt_id and r.status in ('reading','needs_review')))
  with check ((select private.has_perm(org_id, 'receive_stock')));
create policy receipt_lines_delete on public.receipt_lines for delete to authenticated
  using ((select private.has_perm(org_id, 'receive_stock'))
    and exists (select 1 from public.receipts r where r.id = receipt_id and r.status in ('reading','needs_review')));

create policy ocr_corrections_insert on public.ocr_corrections for insert to authenticated
  with check ((select private.has_perm(org_id, 'receive_stock')));
create policy ocr_corrections_read on public.ocr_corrections for select to authenticated
  using ((select private.is_owner(org_id)));

create policy count_sessions_read on public.count_sessions for select to authenticated using ((select private.is_member(org_id)));
create policy count_lines_read on public.count_lines for select to authenticated
  using ((select private.has_perm(org_id, 'approve_adjustments')));

create policy price_proposals_read on public.price_proposals for select to authenticated using ((select private.can_see_costs(org_id)));
create policy price_changes_read on public.price_changes for select to authenticated using ((select private.can_see_costs(org_id)));

create policy purchase_orders_read on public.purchase_orders for select to authenticated
  using ((select private.has_perm(org_id, 'approve_pos')) or (select private.can_see_costs(org_id)));
create policy po_lines_read on public.po_lines for select to authenticated
  using ((select private.has_perm(org_id, 'approve_pos')) or (select private.can_see_costs(org_id)));

create policy reorder_snoozes_read on public.reorder_snoozes for select to authenticated using ((select private.is_member(org_id)));
create policy transfers_read on public.transfers for select to authenticated using ((select private.is_member(org_id)));
create policy cash_takings_read on public.cash_takings for select to authenticated using ((select private.can_see_costs(org_id)));
create policy ai_logs_read on public.ai_logs for select to authenticated using ((select private.is_owner(org_id)));
