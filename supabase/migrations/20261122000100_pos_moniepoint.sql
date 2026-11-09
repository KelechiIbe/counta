-- Counta · POS terminals (Moniepoint first)
--
-- A business connects the Moniepoint account its POS terminals pay into. The owner creates an API key in the Moniepoint
-- Business app (POS Terminal Configuration, ERP Integration) and pastes it into Counta; the pos edge function checks it,
-- subscribes Counta to the account's terminal payments and keeps the key and the webhook secret in Supabase Vault.
--
-- At the till, a sale paid by POS or by transfer can be sent to a terminal: the sale waits, unposted, until Moniepoint
-- confirms the payment, then posts and takes its stock (as Pay by transfer does). Payments keyed on a terminal by hand,
-- with no sale sent to it, are matched to a sale waiting for that amount, or to a POS payment a cashier recorded; a shop
-- that sells without invoices records the rest as till sales, every other shop holds them in suspense for a person.
--
-- Booking: POS money goes to 9002 (payments being confirmed) until the account shows it; the matching credit on the
-- account's feed or statement clears 9002, and any shortfall is the provider's charge (6701). Money nobody has matched yet
-- sits in suspense (9001) until someone says what it was.
--
-- Safe to run twice.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.pos_connections (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  provider text not null check (provider in ('moniepoint')),
  label text not null check (length(label) between 1 and 80),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  business_ref text check (business_ref is null or length(business_ref) <= 64),
  business_name text check (business_name is null or length(business_name) <= 200),
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  status text not null default 'live' check (status in ('live', 'error', 'removed')),
  -- How the provider counts money in its API: kobo unless the setup test showed otherwise.
  amount_unit text not null default 'kobo' check (amount_unit in ('kobo', 'naira')),
  unit_checked boolean not null default false,
  scopes text[] not null default '{}',
  key_secret_id uuid,
  key_hint text check (key_hint is null or length(key_hint) <= 12),
  hook_token_hash text,
  hook_secret_id uuid,
  hook_password_secret_id uuid,
  subscription_ref text check (subscription_ref is null or length(subscription_ref) <= 64),
  last_event_at timestamptz,
  last_pull_at timestamptz,
  last_error text check (last_error is null or length(last_error) <= 300),
  last_error_at timestamptz,
  connected_by uuid references public.members(id) on delete set null,
  connected_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists pos_connections_live on public.pos_connections(org_id, provider, coalesce(business_ref, '')) where status <> 'removed';
create unique index if not exists pos_connections_hook on public.pos_connections(hook_token_hash) where hook_token_hash is not null;
create index if not exists pos_connections_org on public.pos_connections(org_id);
create index if not exists pos_connections_bank on public.pos_connections(bank_account_id);
create index if not exists pos_connections_by on public.pos_connections(connected_by);

create table if not exists public.pos_terminals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  serial text not null check (serial ~ '^[A-Z0-9-]{4,40}$'),
  label text check (label is null or length(label) <= 60),
  location_id uuid references public.locations(id) on delete set null,
  active boolean not null default true,
  first_seen_at timestamptz,
  last_seen_at timestamptz,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (connection_id, serial)
);
create index if not exists pos_terminals_org on public.pos_terminals(org_id);
create index if not exists pos_terminals_location on public.pos_terminals(location_id);
create index if not exists pos_terminals_by on public.pos_terminals(created_by);

-- One amount sent to a terminal. A sale can have several (sent again after a decline, or to another terminal).
create table if not exists public.pos_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  terminal_id uuid not null references public.pos_terminals(id) on delete cascade,
  sale_id uuid references public.sales(id) on delete set null,
  purpose text not null default 'sale' check (purpose in ('sale', 'test')),
  amount numeric(16,2) not null check (amount > 0),
  pay_method text not null default 'any' check (pay_method in ('any', 'card', 'transfer')),
  reference text not null unique check (reference ~ '^CNP[A-Z0-9]{16}$'),
  status text not null default 'creating' check (status in ('creating', 'sent', 'paid', 'declined', 'cancelled', 'expired', 'failed')),
  provider_ref text,
  paid_amount numeric(16,2),
  paid_how text check (paid_how is null or paid_how in ('card', 'transfer', 'other')),
  response_code text check (response_code is null or length(response_code) <= 10),
  response_message text check (response_message is null or length(response_message) <= 200),
  error text check (error is null or length(error) <= 300),
  transaction_id uuid,
  collection_id uuid references public.collections(id) on delete set null,
  shift_id uuid references public.shifts(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  checked_at timestamptz,
  paid_at timestamptz
);
create index if not exists pos_requests_org on public.pos_requests(org_id, created_at desc);
create index if not exists pos_requests_sale on public.pos_requests(sale_id);
create index if not exists pos_requests_open on public.pos_requests(connection_id, amount) where status in ('creating', 'sent', 'declined', 'cancelled', 'expired', 'failed') and transaction_id is null;
create index if not exists pos_requests_terminal on public.pos_requests(terminal_id);
create index if not exists pos_requests_collection on public.pos_requests(collection_id);
create index if not exists pos_requests_shift on public.pos_requests(shift_id);
create index if not exists pos_requests_by on public.pos_requests(created_by);

-- One payment as the provider reported it, whatever started it.
create table if not exists public.pos_transactions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  transaction_ref text not null check (length(transaction_ref) between 1 and 120),
  event_ids text[] not null default '{}',
  event_type text check (event_type is null or length(event_type) <= 60),
  kind text not null default 'other' check (kind in ('card', 'transfer', 'other')),
  terminal_serial text,
  terminal_id uuid references public.pos_terminals(id) on delete set null,
  merchant_reference text check (merchant_reference is null or length(merchant_reference) <= 120),
  amount numeric(16,2) not null check (amount > 0),
  fee numeric(16,2) not null default 0 check (fee >= 0),
  status text not null check (status in ('approved', 'pending', 'declined')),
  response_code text check (response_code is null or length(response_code) <= 10),
  response_message text check (response_message is null or length(response_message) <= 200),
  occurred_at timestamptz not null,
  payer jsonb not null default '{}'::jsonb,
  raw jsonb,
  verified text not null default 'signature' check (verified in ('signature', 'event_api', 'status_api', 'pull')),
  outcome text not null default 'new' check (outcome in ('new', 'request', 'collection', 'sale', 'unassigned', 'assigned', 'ignored')),
  request_id uuid references public.pos_requests(id) on delete set null,
  sale_id uuid references public.sales(id) on delete set null,
  collection_id uuid references public.collections(id) on delete set null,
  journal_id uuid references public.journals(id) on delete set null,
  assign_journal_id uuid references public.journals(id) on delete set null,
  cleared_line_id uuid references public.bank_lines(id) on delete set null,
  cleared_at timestamptz,
  note text check (note is null or length(note) <= 300),
  assigned_by uuid references public.members(id) on delete set null,
  assigned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (connection_id, transaction_ref)
);
create index if not exists pos_transactions_org on public.pos_transactions(org_id, occurred_at desc);
create index if not exists pos_transactions_unassigned on public.pos_transactions(org_id) where outcome = 'unassigned';
create index if not exists pos_transactions_uncleared on public.pos_transactions(connection_id, occurred_at) where journal_id is not null and cleared_line_id is null;
create index if not exists pos_transactions_terminal on public.pos_transactions(terminal_id);
create index if not exists pos_transactions_request on public.pos_transactions(request_id);
create index if not exists pos_transactions_sale on public.pos_transactions(sale_id);
create index if not exists pos_transactions_collection on public.pos_transactions(collection_id);
create index if not exists pos_transactions_journal on public.pos_transactions(journal_id);
create index if not exists pos_transactions_assign_journal on public.pos_transactions(assign_journal_id);
create index if not exists pos_transactions_line on public.pos_transactions(cleared_line_id);
create index if not exists pos_transactions_by on public.pos_transactions(assigned_by);

alter table public.pos_requests drop constraint if exists pos_requests_transaction_fk;
alter table public.pos_requests add constraint pos_requests_transaction_fk foreign key (transaction_id) references public.pos_transactions(id) on delete set null;
create index if not exists pos_requests_transaction on public.pos_requests(transaction_id);

alter table public.pos_connections enable row level security;
alter table public.pos_terminals enable row level security;
alter table public.pos_requests enable row level security;
alter table public.pos_transactions enable row level security;
revoke all on public.pos_connections, public.pos_terminals, public.pos_requests, public.pos_transactions from anon, authenticated;

-- A collection that posts somewhere other than its account's own ledger: 9002 while a POS payment waits for the account to
-- show it, or suspense when a person matches a POS payment Counta had held there.
alter table public.collections add column if not exists via_account text;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
create or replace function private.pos_provider_name(p text) returns text
language sql immutable set search_path = '' as $$
  select case p when 'moniepoint' then 'Moniepoint' else initcap(coalesce(p, '')) end
$$;

create or replace function private.pos_terminal_name(t public.pos_terminals) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce(nullif(t.label, ''), 'Terminal ' || right(t.serial, 4))
$$;

create or replace function private.pos_conn_json(c public.pos_connections) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', c.id, 'provider', c.provider, 'provider_name', private.pos_provider_name(c.provider), 'label', c.label,
    'environment', c.environment, 'business_ref', c.business_ref, 'business_name', c.business_name, 'status', c.status,
    'amount_unit', c.amount_unit, 'unit_checked', c.unit_checked, 'scopes', to_jsonb(c.scopes), 'key_hint', c.key_hint,
    'bank_account_id', c.bank_account_id, 'bank_account_name', (select name from bank_accounts where id = c.bank_account_id),
    'last_event_at', c.last_event_at, 'last_pull_at', c.last_pull_at, 'last_error', c.last_error, 'last_error_at', c.last_error_at,
    'connected_at', c.connected_at, 'connected_by', (select display_name from members where id = c.connected_by),
    'terminals', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'serial', t.serial, 'label', t.label, 'name', private.pos_terminal_name(t),
        'location_id', t.location_id, 'location_name', (select name from locations where id = t.location_id), 'active', t.active,
        'last_seen_at', t.last_seen_at) order by t.active desc, coalesce(t.label, t.serial)) from pos_terminals t where t.connection_id = c.id), '[]'::jsonb),
    'in_clearing', (select coalesce(sum(x.amount - x.fee), 0) from pos_transactions x where x.connection_id = c.id and x.journal_id is not null
        and x.cleared_line_id is null and x.status = 'approved'),
    'in_clearing_count', (select count(*) from pos_transactions x where x.connection_id = c.id and x.journal_id is not null
        and x.cleared_line_id is null and x.status = 'approved'))
$$;

create or replace function private.pos_request_json(r public.pos_requests) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', r.id, 'reference', r.reference, 'purpose', r.purpose, 'amount', r.amount, 'pay_method', r.pay_method, 'status', r.status,
    'paid_amount', r.paid_amount, 'paid_how', r.paid_how, 'paid_at', r.paid_at, 'response_code', r.response_code, 'response_message', r.response_message,
    'error', r.error, 'sent_at', r.sent_at, 'created_at', r.created_at, 'sale_id', r.sale_id,
    'sale_number', (select number from sales where id = r.sale_id), 'sale_status', (select status from sales where id = r.sale_id),
    'terminal_id', r.terminal_id, 'terminal_name', (select private.pos_terminal_name(t) from pos_terminals t where t.id = r.terminal_id),
    'terminal_serial', (select serial from pos_terminals where id = r.terminal_id),
    'provider', (select provider from pos_connections where id = r.connection_id),
    'provider_name', (select private.pos_provider_name(provider) from pos_connections where id = r.connection_id))
$$;

create or replace function private.pos_txn_json(t public.pos_transactions) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', t.id, 'transaction_ref', t.transaction_ref, 'kind', t.kind, 'amount', t.amount, 'fee', t.fee, 'status', t.status,
    'occurred_at', t.occurred_at, 'outcome', t.outcome, 'note', t.note, 'payer', t.payer->>'name', 'response_message', t.response_message,
    'terminal_serial', t.terminal_serial, 'terminal_name', (select private.pos_terminal_name(x) from pos_terminals x where x.id = t.terminal_id),
    'location_id', (select location_id from pos_terminals where id = t.terminal_id),
    'sale_id', t.sale_id, 'sale_number', (select number from sales where id = t.sale_id),
    'request_reference', (select reference from pos_requests where id = t.request_id),
    'cleared', t.cleared_line_id is not null, 'assigned_by', (select display_name from members where id = t.assigned_by), 'assigned_at', t.assigned_at,
    'provider_name', (select private.pos_provider_name(provider) from pos_connections where id = t.connection_id))
$$;

-- The owner, or a refusal in plain words.
create or replace function private.pos_require_owner(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner connects a POS provider or changes its key.' using errcode = '42501'; end if;
  return m;
end $$;

-- Someone who may name terminals and say which branch they sit in: the owner or a settings manager.
create or replace function private.pos_require_manager(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or coalesce(private.perm_of(m, 'manage_settings'), false)) then
    raise exception 'Only the owner or someone who manages settings looks after POS terminals.' using errcode = '42501';
  end if;
  return m;
end $$;

-- Someone who says what a POS payment was: a manager or the bookkeeper.
create or replace function private.pos_require_books(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (coalesce(private.perm_of(m, 'keep_books'), false) or coalesce(private.perm_of(m, 'approve_adjustments'), false)) then
    raise exception 'Only a manager, an accountant or the owner matches POS payments.' using errcode = '42501';
  end if;
  return m;
end $$;

create or replace function private.pos_owner_member(p_org uuid) returns public.members
language sql stable security definer set search_path = public, private as $$
  select * from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1
$$;

create or replace function private.pos_new_reference() returns text
language sql volatile set search_path = public, private as $$
  select 'CNP' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16))
$$;

-- ---------------------------------------------------------------------------
-- 3. Booking helpers
-- ---------------------------------------------------------------------------
-- Keeps a value in Vault: replaces the one already there, or makes a new secret. An empty value changes nothing.
create or replace function private.pos_vault_put(p_id uuid, p_value text, p_desc text) returns uuid
language plpgsql security definer set search_path = public, private, vault as $$
begin
  if coalesce(p_value, '') = '' then return p_id; end if;
  if p_id is not null and exists (select 1 from vault.secrets where id = p_id) then
    perform vault.update_secret(p_id, p_value);
    return p_id;
  end if;
  return vault.create_secret(p_value, 'pos:' || gen_random_uuid()::text, p_desc);
end $$;

-- A payment nobody has matched yet: in the books at once, against suspense, until a person says what it was.
create or replace function private.pos_hold(t public.pos_transactions, c public.pos_connections, p_note text) returns void
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; v_term text;
begin
  select private.pos_terminal_name(x) into v_term from pos_terminals x where x.id = t.terminal_id;
  j := private.post_entry(c.org_id, 'POS payment to match · ' || private.naira(t.amount) || ' · ' || coalesce(v_term, private.pos_provider_name(c.provider)),
    'pos', t.id, null, null,
    jsonb_build_array(
      jsonb_build_object('code', private.acct(c.org_id, 'bank_clearing'), 'debit', t.amount - t.fee, 'memo', private.pos_provider_name(c.provider) || ' ' || t.transaction_ref),
      jsonb_build_object('code', private.acct(c.org_id, 'payment_fees'), 'debit', t.fee, 'memo', private.pos_provider_name(c.provider) || ' charge ' || t.transaction_ref),
      jsonb_build_object('code', private.acct(c.org_id, 'suspense'), 'credit', t.amount, 'memo', 'POS payment waiting to be matched · ' || t.transaction_ref)),
    t.occurred_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'provider', 'ref', c.provider || ':' || t.transaction_ref,
      'terminal', t.terminal_serial, 'verified', t.verified))));
  update pos_transactions set outcome = 'unassigned', journal_id = j.id, note = coalesce(p_note, note), updated_at = now() where id = t.id;
  perform private.notify_perm(c.org_id, 'keep_books', 'payment', 'POS payment to match: ' || private.naira(t.amount),
    coalesce(p_note, 'No sale was waiting for this amount') || ' · ' || coalesce(v_term, 'terminal'), '/sell/sales?tab=confirm', 'pos-unassigned', null, null);
  perform private.notify_perm(c.org_id, 'approve_adjustments', 'payment', 'POS payment to match: ' || private.naira(t.amount),
    coalesce(p_note, 'No sale was waiting for this amount') || ' · ' || coalesce(v_term, 'terminal'), '/sell/sales?tab=confirm', 'pos-unassigned', null, null);
end $$;

-- A payment taken on a terminal as a till sale with no items, as the business answered for money with no sale behind it.
-- Debits p_debit (9002 for a payment Counta has just heard of, suspense for one a person is now matching) and books any
-- charge the provider stated.
create or replace function private.pos_txn_sale(t public.pos_transactions, c public.pos_connections, m public.members, p_debit text, p_fee numeric)
returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s public.sales; j public.journals; v_amt numeric := t.amount; v_rate numeric; v_net numeric; v_vat numeric; v_absorbed numeric;
  v_cust uuid; v_name text; v_treat text; v_incl boolean; v_def jsonb; v_term public.pos_terminals; v_loc uuid; v_day date; v_rev text;
begin
  select * into o from orgs where id = c.org_id;
  select * into v_term from pos_terminals where id = t.terminal_id;
  v_loc := coalesce(v_term.location_id, private.main_location(c.org_id));
  v_day := private.local_day(c.org_id, t.occurred_at);
  v_def := private.receipt_vat_default(c.org_id, 'POS');
  v_treat := v_def->>'treatment';
  v_incl := coalesce(o.vat_on_receipts, 'inclusive') = 'inclusive';
  v_rate := case when o.vat_registered and v_treat = 'standard' then private.vat_rate(v_day) else 0 end;
  if v_incl then v_net := round(v_amt / (1 + v_rate), 2); v_vat := v_amt - v_net; v_absorbed := 0;
  else v_net := v_amt; v_vat := round(v_amt * v_rate, 2); v_absorbed := v_vat; end if;
  v_cust := private.walk_in(c.org_id);
  select name into v_name from customers where id = v_cust;
  v_rev := private.acct(c.org_id, 'sales_revenue');
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, location_id, channel, issue_date, prices_include_vat, vat_registered,
    subtotal, vat_total, total, amount_paid, reference, notes, created_by, issued_at, vat_source, vat_check, vat_reason)
  values (c.org_id, 'receipt', private.doc_number(c.org_id, 'receipt'), 'paid', v_cust, v_name, v_loc, 'till', v_day, v_incl, o.vat_registered,
    v_net, v_vat, v_net + v_vat, v_net + v_vat, left(t.transaction_ref, 60),
    left('Paid by ' || case t.kind when 'card' then 'card' when 'transfer' then 'transfer' else 'POS' end || ' on '
      || coalesce(private.pos_terminal_name(v_term), 'a ' || private.pos_provider_name(c.provider) || ' terminal') || ' with no sale rung up in Counta. No stock was taken off.', 300),
    m.id, now(), v_def->>'source', coalesce((v_def->>'check')::boolean, false), left(v_def->>'reason', 300))
  returning * into s;
  insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account, nrs_vat_label)
  values (s.id, c.org_id, 1, 'goods', 'Sale paid on a POS terminal', 1, 'sale', v_net, v_treat, v_rate, v_net, v_vat, v_net + v_vat, v_rev,
    case when v_treat <> 'standard' then private.nrs_label_guess(v_treat, 'POS') end);
  j := private.post_entry(c.org_id, 'Sale ' || s.number || ' · paid on ' || coalesce(private.pos_terminal_name(v_term), 'a POS terminal') || ' with no sale in Counta',
    'sale', s.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', p_debit, 'debit', v_amt - coalesce(p_fee, 0), 'memo', private.pos_provider_name(c.provider) || ' ' || t.transaction_ref),
      jsonb_build_object('code', private.acct(c.org_id, 'payment_fees'), 'debit', coalesce(p_fee, 0), 'memo', private.pos_provider_name(c.provider) || ' charge ' || s.number),
      jsonb_build_object('code', '6512', 'debit', v_absorbed, 'memo', 'VAT on ' || s.number || ' not charged to the customer'),
      jsonb_build_object('code', v_rev, 'credit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || v_name),
      jsonb_build_object('code', private.acct(c.org_id, 'output_vat'), 'credit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id,
        'memo', 'Output VAT ' || s.number)),
    t.occurred_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'provider', 'ref', c.provider || ':' || t.transaction_ref, 'terminal', t.terminal_serial),
      jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = s.id returning * into s;
  return s;
end $$;

-- A request's sale is paid: the sale posts (if it was waiting), the payment is recorded against it through 9002.
create or replace function private.pos_pay_request(r public.pos_requests, t public.pos_transactions, c public.pos_connections, p_note text) returns void
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; col public.collections; v_term text;
begin
  select * into s from sales where id = r.sale_id for update;
  select * into m from members where id = r.created_by and status = 'active';
  if m.id is null then m := private.pos_owner_member(c.org_id); end if;
  -- A till sale waiting for the terminal posts now, and takes its stock.
  if s.doc_type = 'receipt' and s.journal_id is null and s.status not in ('cancelled', 'void', 'draft') then
    perform private.post_sale(s.id, m, t.occurred_at);
  end if;
  select private.pos_terminal_name(x) into v_term from pos_terminals x where x.id = coalesce(t.terminal_id, r.terminal_id);
  col := private.add_collection(c.org_id, s.customer_id, t.amount, 'pos',
    jsonb_build_object('bank_account_id', c.bank_account_id, 'via_account', private.acct(c.org_id, 'bank_clearing'), 'fee', t.fee,
      'provider_ref', c.provider || ':' || t.transaction_ref, 'reference', r.reference, 'received_at', t.occurred_at, 'shift_id', r.shift_id, 'spread', false,
      'note', 'Paid by ' || case t.kind when 'card' then 'card' when 'transfer' then 'transfer' else 'POS' end || ' on ' || coalesce(v_term, 'the terminal')
        || coalesce(' · ' || p_note, '')),
    null::public.members, 'confirmed', case when s.id is not null then array[s.id] end);
  -- The provider confirmed it, not a person; the cashier who sent it stays on record as who asked for it.
  update collections set created_by = r.created_by where id = col.id;
  update pos_requests set status = 'paid', paid_amount = t.amount, paid_at = t.occurred_at, paid_how = t.kind, transaction_id = t.id, collection_id = col.id,
    provider_ref = t.transaction_ref, response_code = coalesce(t.response_code, response_code), response_message = coalesce(t.response_message, response_message),
    error = null where id = r.id;
  update pos_transactions set outcome = 'request', request_id = r.id, sale_id = s.id, collection_id = col.id, journal_id = col.journal_id,
    note = coalesce(p_note, note), updated_at = now() where id = t.id;
  if m.user_id is not null then
    perform private.notify(c.org_id, m.user_id, 'payment', 'Paid ' || private.naira(t.amount) || coalesce(' for ' || s.number, ''),
      case t.kind when 'card' then 'Card' when 'transfer' then 'Transfer' else 'POS' end || ' on ' || coalesce(v_term, 'the terminal'),
      case when s.id is not null then '/sell/sales?open=' || s.id else '/payments?tab=pos' end, 'pos-paid-' || r.id);
  end if;
end $$;

-- A payment no request names: a sale sent to a terminal for that amount (keyed by hand instead), then a POS payment a
-- cashier recorded, then (for a shop that sells without invoices) a till sale; anything else waits for a person.
create or replace function private.pos_walk_up(t public.pos_transactions, c public.pos_connections) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.pos_requests; col public.collections; v_n int; tm public.pos_terminals; o public.orgs; m public.members; s public.sales; v_here boolean;
begin
  select * into tm from pos_terminals where id = t.terminal_id;
  select * into o from orgs where id = c.org_id;
  -- 1 A sale sent to a terminal for exactly this amount and not paid: the cashier keyed it by hand, or it was paid after the till gave up.
  select count(distinct x.sale_id) into v_n from pos_requests x join sales xs on xs.id = x.sale_id
  where x.connection_id = c.id and x.purpose = 'sale' and x.amount = t.amount and x.transaction_id is null
    and x.status in ('creating', 'sent', 'declined', 'cancelled', 'expired', 'failed')
    and x.created_at between t.occurred_at - interval '4 days' and t.occurred_at + interval '10 minutes'
    and xs.status not in ('cancelled', 'void', 'paid', 'draft')
    and not exists (select 1 from pos_requests y where y.sale_id = x.sale_id and y.status = 'paid');
  if v_n > 0 then
    select x.* into r from pos_requests x join sales xs on xs.id = x.sale_id
    where x.connection_id = c.id and x.purpose = 'sale' and x.amount = t.amount and x.transaction_id is null
      and x.status in ('creating', 'sent', 'declined', 'cancelled', 'expired', 'failed')
      and x.created_at between t.occurred_at - interval '4 days' and t.occurred_at + interval '10 minutes'
      and xs.status not in ('cancelled', 'void', 'paid', 'draft')
      and not exists (select 1 from pos_requests y where y.sale_id = x.sale_id and y.status = 'paid')
    order by (x.terminal_id is not distinct from t.terminal_id) desc, (x.status = 'sent') desc, abs(extract(epoch from (x.created_at - t.occurred_at))), x.created_at
    limit 1;
    select * into r from pos_requests where id = r.id for update;
    perform private.pos_pay_request(r, t, c, case when v_n > 1 then v_n || ' sales were waiting for this amount; Counta gave it to the nearest in time. Check with the cashier.' end);
    return jsonb_build_object('ok', true, 'outcome', 'request', 'request', private.pos_request_json((select x from pos_requests x where x.id = r.id)));
  end if;
  -- 2 A POS, card or transfer payment a cashier recorded (at the phone till, say), waiting to be confirmed.
  select count(*) into v_n from collections x
  where x.org_id = c.org_id and x.status = 'pending' and x.direction = 'in' and x.amount = t.amount
    and (x.method in ('pos', 'card') or (x.method = 'transfer' and t.kind = 'transfer' and (x.bank_account_id is null or x.bank_account_id = c.bank_account_id)))
    and x.received_at between t.occurred_at - interval '2 days' and t.occurred_at + interval '10 minutes';
  if v_n > 0 then
    select x.* into col from collections x left join shifts sh on sh.id = x.shift_id
    where x.org_id = c.org_id and x.status = 'pending' and x.direction = 'in' and x.amount = t.amount
      and (x.method in ('pos', 'card') or (x.method = 'transfer' and t.kind = 'transfer' and (x.bank_account_id is null or x.bank_account_id = c.bank_account_id)))
      and x.received_at between t.occurred_at - interval '2 days' and t.occurred_at + interval '10 minutes'
    order by (tm.location_id is not null and sh.location_id is not distinct from tm.location_id) desc, abs(extract(epoch from (x.received_at - t.occurred_at))), x.received_at
    limit 1;
    v_here := tm.location_id is not null and exists (select 1 from shifts sh where sh.id = col.shift_id and sh.location_id = tm.location_id);
    if v_n = 1 or v_here then
      select * into col from collections where id = col.id for update;
      m := private.pos_owner_member(c.org_id);
      update collections set status = 'confirmed', bank_account_id = c.bank_account_id, via_account = private.acct(c.org_id, 'bank_clearing'),
        fee = case when fee = 0 then least(t.fee, amount) else fee end,
        provider_ref = coalesce(provider_ref, c.provider || ':' || t.transaction_ref), confirmed_at = now(),
        note = concat_ws(' · ', note, 'Confirmed by ' || private.pos_provider_name(c.provider))
      where id = col.id;
      col := private.post_collection(col.id, m);
      update pos_transactions set outcome = 'collection', collection_id = col.id, journal_id = col.journal_id,
        sale_id = (select a.sale_id from collection_allocations a where a.collection_id = col.id order by a.amount desc limit 1),
        note = case when v_n > 1 then v_n || ' recorded payments matched this amount; Counta took the one at this terminal''s branch, nearest in time.' end,
        updated_at = now()
      where id = t.id;
      return jsonb_build_object('ok', true, 'outcome', 'collection', 'collection', col.number);
    end if;
  end if;
  -- 3 A shop that sells without invoices: a till sale.
  if coalesce(o.cash_sales_without_invoices, false) and t.kind in ('card', 'transfer') then
    m := private.pos_owner_member(c.org_id);
    s := private.pos_txn_sale(t, c, m, private.acct(c.org_id, 'bank_clearing'), t.fee);
    update pos_transactions set outcome = 'sale', sale_id = s.id, journal_id = s.journal_id, updated_at = now() where id = t.id;
    return jsonb_build_object('ok', true, 'outcome', 'sale', 'sale', s.number);
  end if;
  -- 4 A person says what it was.
  perform private.pos_hold(t, c, null);
  return jsonb_build_object('ok', true, 'outcome', 'unassigned');
end $$;

-- Opens a request to send an amount to a terminal (the pos function sends it). p_how: any, card or transfer.
create or replace function private.open_pos_request(p_org uuid, p_sale uuid, p_terminal uuid, p_amount numeric, p_how text, m public.members, p_shift uuid,
  p_purpose text default 'sale') returns public.pos_requests
language plpgsql security definer set search_path = public, private as $$
declare tm public.pos_terminals; c public.pos_connections; r public.pos_requests; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  select * into tm from pos_terminals where id = p_terminal and org_id = p_org;
  if not found or not tm.active then raise exception 'That terminal is not connected. Choose another, or record the POS payment without sending it.'; end if;
  select * into c from pos_connections where id = tm.connection_id;
  if c.status = 'removed' then raise exception 'That terminal is not connected any more.'; end if;
  if c.status = 'error' then raise exception '% has stopped answering Counta. Record the POS payment without sending it, and tell the owner.', private.pos_provider_name(c.provider); end if;
  if not c.unit_checked and p_purpose <> 'test' then
    raise exception 'Finish the terminal test in Payments, POS terminals, before sending sales to %.', private.pos_terminal_name(tm);
  end if;
  if v_amt <= 0 then raise exception 'Enter an amount above zero.'; end if;
  if coalesce(p_how, 'any') not in ('any', 'card', 'transfer') then raise exception 'Choose card, transfer or either.'; end if;
  -- Earlier requests for the same sale on the same terminal that never reached it are withdrawn.
  if p_sale is not null then
    update pos_requests set status = 'cancelled' where sale_id = p_sale and terminal_id = tm.id and status = 'creating';
  end if;
  insert into pos_requests (org_id, connection_id, terminal_id, sale_id, purpose, amount, pay_method, reference, status, shift_id, created_by)
  values (p_org, c.id, tm.id, p_sale, coalesce(p_purpose, 'sale'), v_amt, coalesce(p_how, 'any'), private.pos_new_reference(), 'creating', p_shift, m.id)
  returning * into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 4. For the screens
-- ---------------------------------------------------------------------------
-- Payments, POS terminals: the connections, their terminals, and the payments waiting for a person.
create or replace function public.pos_overview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_owner boolean; v_manage boolean; v_books boolean;
begin
  m := private.require(p_org, null);
  v_owner := m.role = 'owner';
  v_manage := v_owner or coalesce(private.perm_of(m, 'manage_settings'), false);
  v_books := coalesce(private.perm_of(m, 'keep_books'), false) or coalesce(private.perm_of(m, 'approve_adjustments'), false);
  return jsonb_build_object(
    'can', jsonb_build_object('connect', v_owner, 'manage', v_manage, 'assign', v_books),
    'sample', coalesce((select is_sample from orgs where id = p_org), false),
    'connections', coalesce((select jsonb_agg(private.pos_conn_json(c) order by c.connected_at) from pos_connections c where c.org_id = p_org and c.status <> 'removed'), '[]'::jsonb),
    'accounts', case when v_owner then coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'bank_name', b.bank_name,
        'account_number', b.account_number) order by b.name) from bank_accounts b where b.org_id = p_org and b.active and b.kind = 'bank'), '[]'::jsonb) else '[]'::jsonb end,
    'locations', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.is_main desc, l.name) from locations l where l.org_id = p_org), '[]'::jsonb),
    'unassigned', case when v_books or v_manage then coalesce((select jsonb_agg(private.pos_txn_json(t) order by t.occurred_at desc)
        from pos_transactions t where t.org_id = p_org and t.outcome = 'unassigned'), '[]'::jsonb) else '[]'::jsonb end,
    'recent', case when v_books or v_manage then coalesce((select jsonb_agg(x.j order by x.at desc) from (select private.pos_txn_json(t) j, t.occurred_at at
        from pos_transactions t where t.org_id = p_org and t.status = 'approved' order by t.occurred_at desc limit 40) x), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- Before the pos function talks to a provider for a business: the owner, and not the sample business.
create or replace function public.pos_connect_check(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.pos_require_owner(p_org);
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot connect a POS provider. Use your own business.'; end if;
  return jsonb_build_object('member_id', m.id, 'org_id', p_org, 'org_name', (select name from orgs where id = p_org),
    'connections', coalesce((select jsonb_agg(private.pos_conn_json(c)) from pos_connections c where c.org_id = p_org and c.status <> 'removed'), '[]'::jsonb));
end $$;

-- A connection, for the pos function acting for its owner (test the key, replace it, disconnect).
create or replace function public.pos_connection_manage(p_connection uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.pos_connections; m public.members;
begin
  select * into c from pos_connections where id = p_connection and status <> 'removed';
  if not found then raise exception 'Connection not found.'; end if;
  m := private.pos_require_owner(c.org_id);
  return private.pos_conn_json(c) || jsonb_build_object('org_id', c.org_id, 'member_id', m.id);
end $$;

-- p: {label, bank_account_id}
create or replace function public.pos_connection_update(p_connection uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; m public.members; v_bank uuid := nullif(p->>'bank_account_id', '')::uuid;
begin
  select * into c from pos_connections where id = p_connection and status <> 'removed' for update;
  if not found then raise exception 'Connection not found.'; end if;
  m := private.pos_require_owner(c.org_id);
  if p ? 'bank_account_id' and (v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = c.org_id and active and kind = 'bank')) then
    raise exception 'Choose the bank account the terminals pay into.';
  end if;
  update pos_connections set label = coalesce(nullif(left(trim(p->>'label'), 80), ''), label),
    bank_account_id = case when p ? 'bank_account_id' then v_bank else bank_account_id end
  where id = c.id returning * into c;
  return private.pos_conn_json(c);
end $$;

-- p: {id?, serial, label, location_id, active}
create or replace function public.pos_terminal_save(p_connection uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; m public.members; t public.pos_terminals; v_serial text := upper(regexp_replace(coalesce(p->>'serial', ''), '\s', '', 'g'));
  v_loc uuid := nullif(p->>'location_id', '')::uuid;
begin
  select * into c from pos_connections where id = p_connection and status <> 'removed';
  if not found then raise exception 'Connection not found.'; end if;
  m := private.pos_require_manager(c.org_id);
  if v_loc is not null and not exists (select 1 from locations where id = v_loc and org_id = c.org_id) then raise exception 'Choose one of your branches.'; end if;
  if nullif(p->>'id', '') is not null then
    select * into t from pos_terminals where id = (p->>'id')::uuid and connection_id = c.id for update;
    if not found then raise exception 'Terminal not found.'; end if;
    update pos_terminals set label = case when p ? 'label' then nullif(left(trim(p->>'label'), 60), '') else label end,
      location_id = case when p ? 'location_id' then v_loc else location_id end,
      active = coalesce((p->>'active')::boolean, active)
    where id = t.id;
  else
    if v_serial !~ '^[A-Z0-9-]{4,40}$' then
      raise exception 'Enter the terminal''s serial number, as printed on its back or shown in the Moniepoint Business app.';
    end if;
    insert into pos_terminals (org_id, connection_id, serial, label, location_id, created_by)
    values (c.org_id, c.id, v_serial, nullif(left(trim(p->>'label'), 60), ''), v_loc, m.id)
    on conflict (connection_id, serial) do update set label = coalesce(excluded.label, pos_terminals.label),
      location_id = coalesce(excluded.location_id, pos_terminals.location_id), active = true;
  end if;
  return private.pos_conn_json((select x from pos_connections x where x.id = c.id));
end $$;

-- The terminals a till can send sales to: those at its branch first.
create or replace function public.pos_till_terminals(p_org uuid, p_location uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'record_sales');
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', private.pos_terminal_name(t), 'serial', t.serial, 'location_id', t.location_id,
      'here', t.location_id = p_location, 'provider', c.provider, 'provider_name', private.pos_provider_name(c.provider), 'ready', c.unit_checked and c.status = 'live')
      order by (t.location_id = p_location) desc nulls last, private.pos_terminal_name(t))
    from pos_terminals t join pos_connections c on c.id = t.connection_id
    where t.org_id = p_org and t.active and c.status in ('live', 'error')), '[]'::jsonb);
end $$;

create or replace function public.get_pos_request(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r public.pos_requests;
begin
  select * into r from pos_requests where id = p_request;
  if not found then raise exception 'Request not found.'; end if;
  perform private.require(r.org_id, null);
  return private.pos_request_json(r);
end $$;

-- A sale's requests, newest first (the till opens the one it has just made).
create or replace function public.pos_sale_requests(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  perform private.require(s.org_id, null);
  return coalesce((select jsonb_agg(private.pos_request_json(r) order by r.created_at desc) from pos_requests r where r.sale_id = s.id), '[]'::jsonb);
end $$;

-- Sales at this branch still waiting for a terminal (the till offers to pick them up again).
create or replace function public.pos_waiting(p_org uuid, p_location uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'record_sales');
  return coalesce((select jsonb_agg(private.pos_request_json(r) order by r.created_at desc)
    from pos_requests r join sales s on s.id = r.sale_id
    where r.org_id = p_org and r.purpose = 'sale' and r.status in ('creating', 'sent') and s.journal_id is null and s.status not in ('cancelled', 'void', 'draft')
      and s.location_id is not distinct from p_location and r.created_at > now() - interval '12 hours'), '[]'::jsonb);
end $$;

-- Send it again: to the same terminal or another, after a decline, a timeout or a cancel.
create or replace function public.pos_retry(p_request uuid, p_terminal uuid default null, p_how text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.pos_requests; s public.sales; m public.members; n public.pos_requests;
begin
  select * into r from pos_requests where id = p_request for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.purpose = 'test' then m := private.pos_require_manager(r.org_id); else m := private.require(r.org_id, 'record_sales'); end if;
  if r.status = 'paid' then raise exception 'This was paid already.'; end if;
  if r.sale_id is not null then
    select * into s from sales where id = r.sale_id;
    if s.status in ('cancelled', 'void') then raise exception '% was cancelled.', s.number; end if;
    if s.status = 'paid' or exists (select 1 from pos_requests x where x.sale_id = s.id and x.status = 'paid') then raise exception '% is paid already.', s.number; end if;
  end if;
  if r.status in ('creating', 'sent') then update pos_requests set status = 'cancelled' where id = r.id; end if;
  n := private.open_pos_request(r.org_id, r.sale_id, coalesce(p_terminal, r.terminal_id), r.amount, coalesce(p_how, r.pay_method), m, r.shift_id, r.purpose);
  return private.pos_request_json(n);
end $$;

create or replace function public.pos_cancel(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.pos_requests;
begin
  select * into r from pos_requests where id = p_request for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.purpose = 'test' then perform private.pos_require_manager(r.org_id); else perform private.require(r.org_id, 'record_sales'); end if;
  if r.status in ('creating', 'sent') then update pos_requests set status = 'cancelled' where id = r.id returning * into r; end if;
  return private.pos_request_json(r);
end $$;

-- The setup test: ₦100 sent to a terminal, so the owner sees the amount arrive as Counta meant it.
create or replace function public.pos_test_request(p_connection uuid, p_terminal uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; m public.members; r public.pos_requests;
begin
  select * into c from pos_connections where id = p_connection and status <> 'removed';
  if not found then raise exception 'Connection not found.'; end if;
  m := private.pos_require_manager(c.org_id);
  if not exists (select 1 from pos_terminals where id = p_terminal and connection_id = c.id and active) then raise exception 'Choose one of this account''s terminals.'; end if;
  update pos_requests set status = 'cancelled' where connection_id = c.id and purpose = 'test' and status in ('creating', 'sent');
  r := private.open_pos_request(c.org_id, null, p_terminal, 100, 'any', m, null, 'test');
  return private.pos_request_json(r);
end $$;

-- What the terminal showed for the ₦100 test: right, ₦10,000.00 (the provider counts in naira) or ₦1.00 (in kobo).
create or replace function public.pos_test_answer(p_connection uuid, p_answer text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections;
begin
  select * into c from pos_connections where id = p_connection and status <> 'removed' for update;
  if not found then raise exception 'Connection not found.'; end if;
  perform private.pos_require_manager(c.org_id);
  if p_answer = 'right' then
    update pos_connections set unit_checked = true where id = c.id returning * into c;
  elsif p_answer = 'too_big' then
    -- Counta sent kobo and the terminal read naira: the provider counts in naira. Test again.
    update pos_connections set amount_unit = case when amount_unit = 'kobo' then 'naira' else amount_unit end, unit_checked = false where id = c.id returning * into c;
  elsif p_answer = 'too_small' then
    update pos_connections set amount_unit = case when amount_unit = 'naira' then 'kobo' else amount_unit end, unit_checked = false where id = c.id returning * into c;
  else
    raise exception 'Say what the terminal showed.';
  end if;
  update pos_requests set status = 'cancelled' where connection_id = c.id and purpose = 'test' and status in ('creating', 'sent');
  return private.pos_conn_json(c);
end $$;

-- POS payments waiting for a person, with the sales and invoices each could be.
create or replace function public.pos_unassigned(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.pos_require_books(p_org);
  return coalesce((select jsonb_agg(private.pos_txn_json(t) || jsonb_build_object('candidates', coalesce((
      select jsonb_agg(x.j) from (
        select jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'customer', s.customer_name, 'issue_date', s.issue_date,
          'due', s.total - s.amount_paid - s.credited) j
        from sales s
        where s.org_id = p_org and s.doc_type in ('receipt', 'invoice', 'order') and s.status in ('pending', 'open', 'partially_paid')
          and abs((s.total - s.amount_paid - s.credited) - t.amount) < 0.005 and s.issue_date between private.local_day(p_org, t.occurred_at) - 30 and private.local_day(p_org, t.occurred_at) + 1
        order by abs(s.issue_date - private.local_day(p_org, t.occurred_at)), s.created_at desc limit 5) x), '[]'::jsonb))
      order by t.occurred_at desc)
    from pos_transactions t where t.org_id = p_org and t.outcome = 'unassigned'), '[]'::jsonb);
end $$;

-- Says what a POS payment held in suspense was. p: {sale_id} | {customer_id} | {as: 'till_sale'} | {account: '<code>'}, note?
create or replace function public.pos_assign(p_txn uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.pos_transactions; c public.pos_connections; m public.members; s public.sales; col public.collections; j public.journals; v_acct text;
  v_susp text; v_cust uuid; v_note text := nullif(left(trim(coalesce(p->>'note', '')), 200), ''); v_term text;
begin
  select * into t from pos_transactions where id = p_txn for update;
  if not found then raise exception 'Payment not found.'; end if;
  m := private.pos_require_books(t.org_id);
  if t.outcome <> 'unassigned' then raise exception 'This payment was matched already.'; end if;
  select * into c from pos_connections where id = t.connection_id;
  v_susp := private.acct(t.org_id, 'suspense');
  select private.pos_terminal_name(x) into v_term from pos_terminals x where x.id = t.terminal_id;
  if nullif(p->>'sale_id', '') is not null then
    select * into s from sales where id = (p->>'sale_id')::uuid and org_id = t.org_id for update;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
    if s.status in ('cancelled', 'void', 'draft', 'converted', 'credited') then raise exception '% is %.', s.number, s.status; end if;
    -- A till sale still waiting for its payment posts now, and takes its stock.
    if s.doc_type = 'receipt' and s.journal_id is null then
      perform private.post_sale(s.id, m, t.occurred_at);
      update pos_requests set status = 'cancelled' where sale_id = s.id and status in ('creating', 'sent');
      update payment_requests set status = 'cancelled' where sale_id = s.id and status in ('creating', 'pending');
    end if;
    col := private.add_collection(t.org_id, s.customer_id, t.amount, 'pos',
      jsonb_build_object('bank_account_id', c.bank_account_id, 'via_account', v_susp, 'provider_ref', c.provider || ':' || t.transaction_ref,
        'reference', left(t.transaction_ref, 60), 'received_at', t.occurred_at, 'spread', false,
        'note', 'Paid on ' || coalesce(v_term, 'a POS terminal') || ', matched by ' || coalesce(m.display_name, 'staff') || coalesce(' · ' || v_note, '')),
      m, 'confirmed', array[s.id]);
    update pos_transactions set outcome = 'assigned', sale_id = s.id, collection_id = col.id, assign_journal_id = col.journal_id where id = t.id;
  elsif nullif(p->>'customer_id', '') is not null then
    select id into v_cust from customers where id = (p->>'customer_id')::uuid and org_id = t.org_id and not archived;
    if v_cust is null then raise exception 'Customer not found.'; end if;
    col := private.add_collection(t.org_id, v_cust, t.amount, 'pos',
      jsonb_build_object('bank_account_id', c.bank_account_id, 'via_account', v_susp, 'provider_ref', c.provider || ':' || t.transaction_ref,
        'reference', left(t.transaction_ref, 60), 'received_at', t.occurred_at, 'spread', true,
        'note', 'Paid on ' || coalesce(v_term, 'a POS terminal') || ', matched by ' || coalesce(m.display_name, 'staff') || coalesce(' · ' || v_note, '')),
      m, 'confirmed', null);
    update pos_transactions set outcome = 'assigned', collection_id = col.id, assign_journal_id = col.journal_id,
      sale_id = (select a.sale_id from collection_allocations a where a.collection_id = col.id order by a.amount desc limit 1) where id = t.id;
  elsif p->>'as' = 'till_sale' then
    s := private.pos_txn_sale(t, c, m, v_susp, 0);
    update pos_transactions set outcome = 'assigned', sale_id = s.id, assign_journal_id = s.journal_id where id = t.id;
  elsif nullif(p->>'account', '') is not null then
    v_acct := p->>'account';
    if not private.postable(t.org_id, v_acct) or v_acct ~ '^(10|12|9)'
       or v_acct in (private.acct(t.org_id, 'receivables'), private.acct(t.org_id, 'payables'), private.acct(t.org_id, 'customer_advances'))
       or exists (select 1 from bank_accounts where org_id = t.org_id and ledger_code = v_acct) then
      raise exception 'Choose an account for what the money was: the owner''s account, a loan, other income and the like.';
    end if;
    j := private.post_entry(t.org_id, 'POS payment ' || private.naira(t.amount) || ' · ' || coalesce(v_note, private.account_name(t.org_id, v_acct)), 'pos', t.id, m.id, m.id,
      private.reclass_pair(v_susp, v_acct, t.amount, null, null), t.occurred_at,
      jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'provider', 'ref', c.provider || ':' || t.transaction_ref),
        jsonb_build_object('type', 'confirmation', 'by', m.display_name))));
    update pos_transactions set outcome = 'assigned', assign_journal_id = j.id where id = t.id;
  else
    raise exception 'Say what this payment was: a sale, a customer''s payment, a till sale or another account.';
  end if;
  update pos_transactions set assigned_by = m.id, assigned_at = now(), note = coalesce(v_note, note), updated_at = now() where id = t.id returning * into t;
  return private.pos_txn_json(t);
end $$;

-- ---------------------------------------------------------------------------
-- 5. For the pos function only
-- ---------------------------------------------------------------------------
-- p: {org_id, member_id, provider, label, environment, business_ref, business_name, scopes[], key, key_hint, hook_token (plain; kept as a
--     hash), hook_secret, hook_password, subscription_ref, bank_account_id | new_account_name, account_number}
create or replace function public.svc_pos_connection_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; m public.members; v_org uuid := (p->>'org_id')::uuid; v_prov text := p->>'provider'; v_bank uuid; b public.bank_accounts;
  v_key uuid; v_hs uuid; v_hp uuid; v_scopes text[];
begin
  select * into m from members where id = (p->>'member_id')::uuid and org_id = v_org and status = 'active';
  if not found or m.role <> 'owner' then raise exception 'Only the owner connects a POS provider.'; end if;
  if (select is_sample from orgs where id = v_org) then raise exception 'The sample business cannot connect a POS provider. Use your own business.'; end if;
  if coalesce(v_prov, '') not in ('moniepoint') then raise exception 'Unknown POS provider.'; end if;
  select coalesce(array_agg(x), '{}') into v_scopes from jsonb_array_elements_text(coalesce(p->'scopes', '[]'::jsonb)) x;
  select * into c from pos_connections where org_id = v_org and provider = v_prov and coalesce(business_ref, '') = coalesce(p->>'business_ref', '')
    and status <> 'removed' for update;
  v_bank := nullif(p->>'bank_account_id', '')::uuid;
  if v_bank is not null and not exists (select 1 from bank_accounts where id = v_bank and org_id = v_org and active and kind = 'bank') then
    raise exception 'Choose one of your bank accounts, or let Counta open one for the terminals.';
  end if;
  v_bank := coalesce(v_bank, c.bank_account_id);
  if v_bank is null then
    b := private.open_bank_account(v_org, 'bank', coalesce(nullif(left(trim(p->>'new_account_name'), 80), ''), private.pos_provider_name(v_prov)),
      jsonb_build_object('bank_name', case v_prov when 'moniepoint' then 'Moniepoint MFB' end, 'account_number', nullif(p->>'account_number', '')), m.id);
    v_bank := b.id;
  end if;
  v_key := private.pos_vault_put(c.key_secret_id, p->>'key', 'A ' || private.pos_provider_name(v_prov) || ' POS key for ' || v_org::text);
  v_hs := private.pos_vault_put(c.hook_secret_id, p->>'hook_secret', 'A ' || private.pos_provider_name(v_prov) || ' webhook secret for ' || v_org::text);
  -- An empty password means the webhook has none (Moniepoint would not set one): the old one must not stay, or every event would be refused.
  if p ? 'hook_password' and coalesce(p->>'hook_password', '') = '' then
    if c.hook_password_secret_id is not null then perform vault.update_secret(c.hook_password_secret_id, ''); end if;
    v_hp := null;
  else
    v_hp := private.pos_vault_put(c.hook_password_secret_id, p->>'hook_password', 'A ' || private.pos_provider_name(v_prov) || ' webhook password for ' || v_org::text);
  end if;
  if c.id is null then
    insert into pos_connections (org_id, provider, label, environment, business_ref, business_name, bank_account_id, status, scopes, key_secret_id, key_hint,
      hook_token_hash, hook_secret_id, hook_password_secret_id, subscription_ref, connected_by)
    values (v_org, v_prov, coalesce(nullif(left(trim(p->>'label'), 80), ''), private.pos_provider_name(v_prov)),
      coalesce(nullif(p->>'environment', ''), 'production'), nullif(left(p->>'business_ref', 64), ''), nullif(left(p->>'business_name', 200), ''), v_bank, 'live',
      v_scopes, v_key, nullif(left(p->>'key_hint', 12), ''),
      case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') end, v_hs, v_hp,
      nullif(left(p->>'subscription_ref', 64), ''), m.id)
    returning * into c;
  else
    update pos_connections set label = coalesce(nullif(left(trim(p->>'label'), 80), ''), label), environment = coalesce(nullif(p->>'environment', ''), environment),
      business_name = coalesce(nullif(left(p->>'business_name', 200), ''), business_name), bank_account_id = v_bank, status = 'live',
      scopes = case when cardinality(v_scopes) > 0 then v_scopes else scopes end, key_secret_id = v_key, key_hint = coalesce(nullif(left(p->>'key_hint', 12), ''), key_hint),
      hook_token_hash = case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') else hook_token_hash end,
      hook_secret_id = v_hs, hook_password_secret_id = v_hp, subscription_ref = coalesce(nullif(left(p->>'subscription_ref', 64), ''), subscription_ref),
      connected_by = m.id, connected_at = now(), last_error = null, last_error_at = null
    where id = c.id returning * into c;
  end if;
  return private.pos_conn_json(c) || jsonb_build_object('org_id', c.org_id);
end $$;

-- A connection with its keys, for the function as it talks to the provider.
create or replace function public.svc_pos_connection(p_connection uuid) returns jsonb
language sql stable security definer set search_path = public, private, vault as $$
  select private.pos_conn_json(c) || jsonb_build_object('org_id', c.org_id, 'subscription_ref', c.subscription_ref,
    'key', (select decrypted_secret from vault.decrypted_secrets where id = c.key_secret_id),
    'hook_secret', (select decrypted_secret from vault.decrypted_secrets where id = c.hook_secret_id),
    'hook_password', (select decrypted_secret from vault.decrypted_secrets where id = c.hook_password_secret_id))
  from pos_connections c where c.id = p_connection and c.status <> 'removed'
$$;

-- A webhook address's connection, by the token in it.
create or replace function public.svc_pos_by_token(p_provider text, p_token text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select id from pos_connections where provider = p_provider and status in ('live', 'error')
    and hook_token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- p: {event: true} a verified event arrived · {pulled: true} the history was read · {error (text, or null to clear), hard: true when the
-- provider refused the key}. A refused key needs the owner at once; anything else only once it has kept failing for half an hour.
create or replace function public.svc_pos_note(p_connection uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; v_was text; v_err text := nullif(left(p->>'error', 300), ''); v_since timestamptz;
begin
  select * into c from pos_connections where id = p_connection for update;
  if not found or c.status = 'removed' then return null; end if;
  v_was := c.status;
  v_since := case when v_err is not null then coalesce(c.last_error_at, now()) end;
  update pos_connections set
    last_event_at = case when coalesce((p->>'event')::boolean, false) then now() else last_event_at end,
    last_pull_at = case when coalesce((p->>'pulled')::boolean, false) then now() else last_pull_at end,
    last_error = case when p ? 'error' then v_err else last_error end,
    last_error_at = case when p ? 'error' then v_since else last_error_at end,
    status = case when v_err is not null and (coalesce((p->>'hard')::boolean, false) or v_since <= now() - interval '30 minutes') then 'error'
      when p ? 'error' and v_err is null then 'live' else status end
  where id = c.id returning * into c;
  if c.status = 'error' and v_was <> 'error' then
    perform private.notify_perm(c.org_id, 'owner', 'payments', private.pos_provider_name(c.provider) || ' stopped answering Counta', left(c.last_error, 200),
      '/payments?tab=pos', 'pos-error-' || c.id, null, null);
  end if;
  return private.pos_conn_json(c);
end $$;

-- Disconnected: the keys are wiped from Vault, the terminals stop taking sales, open requests are withdrawn.
create or replace function public.svc_pos_remove(p_connection uuid) returns jsonb
language plpgsql security definer set search_path = public, private, vault as $$
declare c public.pos_connections;
begin
  select * into c from pos_connections where id = p_connection for update;
  if not found then return null; end if;
  if c.key_secret_id is not null then perform vault.update_secret(c.key_secret_id, ''); end if;
  if c.hook_secret_id is not null then perform vault.update_secret(c.hook_secret_id, ''); end if;
  if c.hook_password_secret_id is not null then perform vault.update_secret(c.hook_password_secret_id, ''); end if;
  update pos_connections set status = 'removed', key_secret_id = null, hook_secret_id = null, hook_password_secret_id = null, hook_token_hash = null,
    key_hint = null where id = c.id;
  update pos_terminals set active = false where connection_id = c.id;
  update pos_requests set status = 'cancelled' where connection_id = c.id and status in ('creating', 'sent');
  return jsonb_build_object('removed', true, 'provider', c.provider);
end $$;

-- What the function needs to send a request to its terminal, or to ask how it went.
create or replace function public.svc_pos_request_context(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.pos_request_json(r) || jsonb_build_object('connection_id', r.connection_id, 'org_id', r.org_id, 'terminal_serial', t.serial,
    'connection_status', c.status, 'amount_unit', c.amount_unit, 'unit_checked', c.unit_checked, 'provider', c.provider)
  from pos_requests r join pos_terminals t on t.id = r.terminal_id join pos_connections c on c.id = r.connection_id
  where r.id = p_request
$$;

-- d: {status: sent | failed | declined | expired, error, response_code, response_message, checked: true}. A paid request is never touched.
create or replace function public.svc_pos_request_update(p_request uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.pos_requests; v_to text := nullif(d->>'status', '');
begin
  select * into r from pos_requests where id = p_request for update;
  if not found then return null; end if;
  if v_to is not null and v_to not in ('sent', 'failed', 'declined', 'expired') then raise exception 'Unknown status %.', v_to; end if;
  if r.status not in ('paid') and (v_to is null
      or (r.status = 'creating' and v_to in ('sent', 'failed'))
      or (r.status = 'sent' and v_to in ('declined', 'failed', 'expired'))) then
    update pos_requests set status = coalesce(v_to, status),
      sent_at = case when v_to = 'sent' then now() else sent_at end,
      checked_at = case when coalesce((d->>'checked')::boolean, false) then now() else checked_at end,
      error = case when d ? 'error' then nullif(left(d->>'error', 300), '') else error end,
      response_code = coalesce(nullif(left(d->>'response_code', 10), ''), response_code),
      response_message = coalesce(nullif(left(d->>'response_message', 200), ''), response_message)
    where id = r.id returning * into r;
  elsif coalesce((d->>'checked')::boolean, false) then
    update pos_requests set checked_at = now() where id = r.id returning * into r;
  end if;
  return private.pos_request_json(r);
end $$;

-- A payment the provider reported (a webhook, its status answer, or its history). Recorded once per provider reference; what it
-- pays is decided once, when it is first seen approved.
-- d: {transaction_ref, event_id, event_type, kind: card | transfer | other, terminal_serial, merchant_reference, amount (naira), fee,
--     status: approved | pending | declined, response_code, response_message, occurred_at, payer {name, account, bank}, raw,
--     verified: signature | event_api | status_api | pull}
create or replace function public.svc_pos_transaction(p_connection uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.pos_connections; t public.pos_transactions; tm public.pos_terminals; r public.pos_requests; s public.sales;
  v_ref text := left(trim(coalesce(d->>'transaction_ref', '')), 120); v_amt numeric := round(private.num(d->>'amount'), 2); v_status text := d->>'status';
  v_serial text := upper(nullif(regexp_replace(coalesce(d->>'terminal_serial', ''), '\s', '', 'g'), '')); v_mref text := nullif(trim(coalesce(d->>'merchant_reference', '')), '');
  v_rank jsonb := '{"signature": 1, "pull": 2, "event_api": 3, "status_api": 4}'::jsonb; v_note text; v_ver text := coalesce(nullif(d->>'verified', ''), 'signature');
begin
  select * into c from pos_connections where id = p_connection;
  if not found or c.status = 'removed' then return jsonb_build_object('ok', false, 'reason', 'unknown_connection'); end if;
  if v_ref = '' or coalesce(v_amt, 0) <= 0 or coalesce(v_status, '') not in ('approved', 'pending', 'declined') then
    return jsonb_build_object('ok', false, 'reason', 'incomplete');
  end if;
  if v_ver not in ('signature', 'event_api', 'status_api', 'pull') then v_ver := 'signature'; end if;
  -- The terminal: known, or added the first time it pays (the POS screen then asks which branch it is in).
  if v_serial ~ '^[A-Z0-9-]{4,40}$' then
    insert into pos_terminals (org_id, connection_id, serial, first_seen_at, last_seen_at) values (c.org_id, c.id, v_serial, now(), now())
    on conflict (connection_id, serial) do update set last_seen_at = now(), first_seen_at = coalesce(pos_terminals.first_seen_at, now())
    returning * into tm;
  end if;
  insert into pos_transactions (org_id, connection_id, transaction_ref, event_ids, event_type, kind, terminal_serial, terminal_id, merchant_reference,
    amount, fee, status, response_code, response_message, occurred_at, payer, raw, verified)
  values (c.org_id, c.id, v_ref, case when nullif(d->>'event_id', '') is not null then array[left(d->>'event_id', 80)] else '{}'::text[] end,
    nullif(left(d->>'event_type', 60), ''), case when d->>'kind' in ('card', 'transfer') then d->>'kind' else 'other' end, v_serial, tm.id, left(v_mref, 120),
    v_amt, round(greatest(coalesce(private.num(d->>'fee'), 0), 0), 2), v_status, nullif(left(d->>'response_code', 10), ''), nullif(left(d->>'response_message', 200), ''),
    least(coalesce(nullif(d->>'occurred_at', '')::timestamptz, now()), now()), coalesce(d->'payer', '{}'::jsonb), d->'raw', v_ver)
  on conflict (connection_id, transaction_ref) do update set
    event_ids = case when excluded.event_ids = '{}'::text[] or excluded.event_ids[1] = any(pos_transactions.event_ids) then pos_transactions.event_ids
                     else pos_transactions.event_ids || excluded.event_ids end,
    -- An approved payment stays approved, and its amount stands once anything was booked.
    status = case when pos_transactions.status = 'approved' then 'approved' else excluded.status end,
    amount = case when pos_transactions.outcome = 'new' then excluded.amount else pos_transactions.amount end,
    fee = case when pos_transactions.outcome = 'new' then excluded.fee else pos_transactions.fee end,
    kind = case when excluded.kind <> 'other' then excluded.kind else pos_transactions.kind end,
    terminal_serial = coalesce(pos_transactions.terminal_serial, excluded.terminal_serial),
    terminal_id = coalesce(pos_transactions.terminal_id, excluded.terminal_id),
    merchant_reference = coalesce(pos_transactions.merchant_reference, excluded.merchant_reference),
    response_code = coalesce(excluded.response_code, pos_transactions.response_code),
    response_message = coalesce(excluded.response_message, pos_transactions.response_message),
    occurred_at = case when pos_transactions.outcome = 'new' then excluded.occurred_at else pos_transactions.occurred_at end,
    payer = pos_transactions.payer || excluded.payer,
    raw = coalesce(excluded.raw, pos_transactions.raw),
    verified = case when (v_rank->>excluded.verified)::int > (v_rank->>pos_transactions.verified)::int then excluded.verified else pos_transactions.verified end,
    updated_at = now()
  returning * into t;
  select * into t from pos_transactions where id = t.id for update;
  -- Reported as not approved after it was approved and booked (a reversal, most likely): a person checks before anything is given back.
  if v_status = 'declined' and t.status = 'approved' and t.outcome <> 'new' and coalesce(t.note, '') not like '%later reported%' then
    update pos_transactions set note = left(private.pos_provider_name(c.provider) || ' later reported this payment as '
      || coalesce(nullif(d->>'response_message', ''), 'not approved') || '. Check the account before anything is given back.', 300), updated_at = now()
    where id = t.id returning * into t;
    perform private.notify_perm(c.org_id, 'keep_books', 'payment', 'Check a POS payment of ' || private.naira(t.amount), t.note, '/payments?tab=pos', 'pos-reversed-' || t.id, null, null);
  end if;
  if t.merchant_reference is not null then
    select * into r from pos_requests where reference = t.merchant_reference and connection_id = c.id for update;
  end if;
  if t.status <> 'approved' then
    if r.id is not null and r.status in ('creating', 'sent') and t.status = 'declined' then
      update pos_requests set status = 'declined', response_code = t.response_code, response_message = t.response_message, checked_at = now() where id = r.id;
    end if;
    return jsonb_build_object('ok', true, 'status', t.status, 'outcome', t.outcome,
      'request', case when r.id is not null then private.pos_request_json((select x from pos_requests x where x.id = r.id)) end);
  end if;
  if t.outcome <> 'new' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'status', t.status, 'outcome', t.outcome,
      'request', case when r.id is not null then private.pos_request_json((select x from pos_requests x where x.id = r.id)) end);
  end if;
  -- Counta sent it: the request's sale.
  if r.id is not null then
    if r.purpose = 'test' then
      update pos_requests set status = 'paid', paid_amount = t.amount, paid_at = t.occurred_at, paid_how = t.kind, transaction_id = t.id where id = r.id;
      update pos_transactions set request_id = r.id where id = t.id returning * into t;
      perform private.pos_hold(t, c, 'Paid during the terminal test. Say what it was (the owner''s own money, most likely).');
    else
      select * into s from sales where id = r.sale_id;
      if s.id is null or s.status in ('cancelled', 'void') then
        v_note := 'Paid on the terminal after ' || coalesce(s.number, 'its sale') || ' was cancelled.';
      elsif s.status = 'paid' or exists (select 1 from pos_requests x where x.sale_id = s.id and x.status = 'paid' and x.id <> r.id) then
        v_note := s.number || ' was paid already. The customer may need a refund.';
      end if;
      if v_note is not null then
        update pos_requests set status = 'paid', paid_amount = t.amount, paid_at = t.occurred_at, paid_how = t.kind, transaction_id = t.id where id = r.id;
        update pos_transactions set request_id = r.id where id = t.id returning * into t;
        perform private.pos_hold(t, c, v_note);
      else
        perform private.pos_pay_request(r, t, c, case when abs(t.amount - r.amount) >= 0.005 then 'Paid ' || private.naira(t.amount) || ' of ' || private.naira(r.amount) end);
      end if;
    end if;
    return jsonb_build_object('ok', true, 'status', 'approved', 'outcome', (select outcome from pos_transactions where id = t.id),
      'request', private.pos_request_json((select x from pos_requests x where x.id = r.id)));
  end if;
  return private.pos_walk_up(t, c) || jsonb_build_object('status', 'approved');
end $$;

-- The schedule's work list: requests to ask about, and connections whose history to read. Requests that never reached a terminal,
-- or were never answered, are closed here (money that arrives later still finds its sale).
create or replace function public.svc_pos_due() returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  update pos_requests set status = 'expired', error = 'Not sent to the terminal.' where status = 'creating' and created_at < now() - interval '10 minutes';
  update pos_requests set status = 'expired' where status = 'sent' and coalesce(sent_at, created_at) < now() - interval '30 minutes';
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(x.id) from (select r.id from pos_requests r join pos_connections c on c.id = r.connection_id
        where r.status = 'sent' and c.status in ('live', 'error') and r.sent_at < now() - interval '15 seconds'
          and (r.checked_at is null or r.checked_at < now() - interval '50 seconds') order by r.checked_at nulls first limit 40) x), '[]'::jsonb),
    'pulls', coalesce((select jsonb_agg(x.id) from (select c.id from pos_connections c where c.status in ('live', 'error') and c.subscription_ref is not null
        and (c.last_pull_at is null or c.last_pull_at < now() - interval '6 hours') order by c.last_pull_at nulls first limit 10) x), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Settlement: the credit on the account clears 9002
-- ---------------------------------------------------------------------------
-- Money a POS provider paid into the account for payments Counta holds in 9002: one payment (exactly, or less a charge of up to 2%),
-- or a day's payments settled together. Answers the stage, or null when nothing fits.
create or replace function private.pos_settle_line(bl public.bank_lines, b public.bank_accounts, m public.members) returns text
language plpgsql security definer set search_path = public, private as $$
declare v_amt numeric := abs(bl.amount); v_ids uuid[]; v_total numeric; v_day date; v_one record; j public.journals; v_n int;
begin
  if bl.amount <= 0 or not exists (select 1 from pos_connections pc where pc.bank_account_id = b.id) then return null; end if;
  select pt.id, pt.amount - pt.fee due into v_one from pos_transactions pt join pos_connections pc on pc.id = pt.connection_id
  where pc.bank_account_id = b.id and pt.journal_id is not null and pt.cleared_line_id is null and pt.status = 'approved'
    and pt.amount - pt.fee >= v_amt and (pt.amount - pt.fee) - v_amt <= round((pt.amount - pt.fee) * 0.02, 2)
    and private.local_day(bl.org_id, pt.occurred_at) between bl.line_date - 3 and bl.line_date + 1
  order by (pt.amount - pt.fee = v_amt) desc, abs(private.local_day(bl.org_id, pt.occurred_at) - bl.line_date), pt.occurred_at
  limit 1;
  if v_one.id is not null then
    v_ids := array[v_one.id]; v_total := v_one.due;
  else
    foreach v_day in array array[bl.line_date, bl.line_date - 1] loop
      select array_agg(pt.id), sum(pt.amount - pt.fee) into v_ids, v_total from pos_transactions pt join pos_connections pc on pc.id = pt.connection_id
      where pc.bank_account_id = b.id and pt.journal_id is not null and pt.cleared_line_id is null and pt.status = 'approved'
        and private.local_day(bl.org_id, pt.occurred_at) = v_day;
      exit when cardinality(v_ids) > 1 and v_total >= v_amt and v_total - v_amt <= round(v_total * 0.02, 2);
      v_ids := null;
    end loop;
  end if;
  if v_ids is null then return null; end if;
  v_n := cardinality(v_ids);
  j := private.post_entry(bl.org_id, 'POS payments settled into ' || b.name || case when v_n > 1 then ' · ' || v_n || ' payments' else '' end, 'bank', bl.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', private.acct(bl.org_id, 'payment_fees'), 'debit', v_total - v_amt, 'memo', 'POS charges · ' || b.name),
      jsonb_build_object('code', private.acct(bl.org_id, 'bank_clearing'), 'credit', v_total, 'memo', 'POS payments settled')),
    private.line_time(bl.org_id, bl.line_date),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source, 'date', bl.line_date,
      'amount', bl.amount, 'narration', bl.description, 'stage', 'pos_settlement'), jsonb_build_object('type', 'pos_settlement', 'payments', v_n, 'total', v_total))));
  update bank_lines set status = 'matched', journal_id = j.id, stage = 'pos_settlement', matched_by = 'system', confidence = 1 where id = bl.id;
  update pos_transactions set cleared_line_id = bl.id, cleared_at = now(), updated_at = now() where id = any(v_ids);
  return 'pos_settlement';
end $$;

-- ---------------------------------------------------------------------------
-- 7. Changes to existing functions (each as it stood, with the POS parts added)
-- ---------------------------------------------------------------------------
-- add_collection: p_meta.via_account, the account the payment posts to instead of its bank account's own (9002, or suspense).
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
    provider_ref, received_at, confirmed_by, confirmed_at, note, wht_rate, client_uuid, created_by, via_account)
  values (p_org, private.pay_no(p_org), p_customer, (p_sales)[1], round(p_amount, 2),
    round(coalesce(private.num(p_meta->>'fee'), 0), 2), p_method, p_status, v_bank, nullif(p_meta->>'shift_id', '')::uuid,
    nullif(p_meta->>'payment_request_id', '')::uuid, nullif(trim(p_meta->>'reference'), ''), nullif(p_meta->>'provider_ref', ''),
    least(coalesce(nullif(p_meta->>'received_at', '')::timestamptz, now()), now()),
    case when p_status = 'confirmed' then m.id end, case when p_status = 'confirmed' then now() end, nullif(trim(p_meta->>'note'), ''),
    nullif(p_meta->>'wht_rate', '')::numeric, nullif(p_meta->>'client_uuid', '')::uuid, m.id, nullif(p_meta->>'via_account', ''))
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
      '/sell/sales?tab=confirm', 'confirm-payments', m.id);
    perform private.notify_perm(p_org, 'keep_books', 'payment', 'Confirm a ' || p_method || ' of ₦' || to_char(c.amount, 'FM999,999,999,990.00'),
      coalesce((select name from customers where id = p_customer), '') || coalesce(' · ' || c.reference, '') || ' · recorded by ' || coalesce(m.display_name, 'the shop'),
      '/sell/sales?tab=confirm', 'confirm-payments', m.id);
  end if;
  return c;
end $$;

-- post_collection: a collection with via_account posts there (POS payments to 9002 until the account shows them).
create or replace function private.post_collection(p_collection uuid, m members)
 RETURNS collections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.collections; b public.bank_accounts; v_alloc numeric := 0; v_jl jsonb; j public.journals; v_target text; a record; v_due numeric;
  v_cust text; v_party_target boolean;
begin
  select * into c from collections where id = p_collection for update;
  if c.journal_id is not null then return c; end if;
  if c.status <> 'confirmed' then raise exception 'Only confirmed payments post.'; end if;
  select name into v_cust from customers where id = c.customer_id;
  if c.method not in ('wht_credit', 'wvat_credit', 'ncd_levy', 'advance') then
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
    v_party_target := c.method in ('wht_credit', 'wvat_credit', 'advance');
    v_target := case c.method when 'wht_credit' then private.acct(c.org_id, 'wht_receivable') when 'wvat_credit' then private.acct(c.org_id, 'vat_withheld_by_customers')
                when 'advance' then private.acct(c.org_id, 'customer_advances') when 'ncd_levy' then private.acct(c.org_id, 'ncd_levy') else coalesce(c.via_account, b.ledger_code) end;
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
      when c.method = 'wvat_credit' then 'VAT withheld by customer ' when c.method = 'ncd_levy' then 'NCD levy deducted by customer ' else 'Payment received ' end || c.number || ' · ' || v_cust,
    'collection', c.id, coalesce(m.id, c.confirmed_by, c.created_by), c.confirmed_by, v_jl, c.received_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', case when c.provider_ref is not null then 'provider' else 'confirmation' end,
      'ref', coalesce(c.provider_ref, c.reference), 'method', c.method, 'confirmed_by', c.confirmed_by))));
  update collections set journal_id = j.id where id = c.id returning * into c;
  for a in select sale_id from collection_allocations where collection_id = c.id loop
    perform private.refresh_sale(a.sale_id);
  end loop;
  return c;
end $function$;

-- create_sale: a POS payment with a terminal_id (and pay_method any, card or transfer) is sent to that terminal.
create or replace function private.create_sale(p_org uuid, p jsonb, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; o public.orgs; c public.customers; v_type text := coalesce(nullif(p->>'doc_type', ''), 'receipt');
  v_at timestamptz := coalesce(nullif(p->>'recorded_at', '')::timestamptz, now()); v_loc uuid; v_shift public.shifts; t jsonb; v_credit numeric := 0;
  v_cust uuid; v_owed numeric; v_paid numeric; v_tendered numeric := 0; v_issue boolean; v_bank uuid; v_method text; v_change numeric := 0;
  v_tenders jsonb; v_day date; v_today date; v_manager boolean; v_amt numeric; v_instant numeric := 0; v_later boolean := false;
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
    if coalesce(t->>'method', '') not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other', 'credit', 'account', 'link', 'qr', 'later') then
      raise exception 'Unknown way of paying: %.', coalesce(t->>'method', '(none)');
    end if;
    -- Paid, but how is decided later on the platform (a sale logged by voice or by scanning): no money is recorded yet.
    if t->>'method' = 'later' then
      if v_type <> 'receipt' then raise exception 'Only a receipt can leave the way it was paid for later.'; end if;
      v_later := true;
      continue;
    end if;
    -- Sent to a connected POS terminal (POS, or pay by transfer on the terminal): the sale waits for the terminal, as for pay by transfer.
    if t->>'method' in ('account', 'link', 'qr') or (t->>'method' = 'pos' and nullif(t->>'terminal_id', '') is not null) then
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
  if v_credit > 0.004 and v_type = 'receipt' and not v_later then
    if c.is_walk_in then raise exception 'A walk-in customer cannot buy on credit. Choose or add the customer.'; end if;
    if c.credit_limit = 0 and not v_manager then
      raise exception '% has no credit limit. Set one on the customer, or ask a manager.', c.name;
    end if;
  end if;
  if v_credit > 0.004 and not v_later then
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
    continue when v_method = 'later';
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
    if v_method = 'pos' and nullif(t->>'terminal_id', '') is not null then
      perform private.open_pos_request(p_org, s.id, (t->>'terminal_id')::uuid, v_paid, coalesce(nullif(t->>'pay_method', ''), 'any'), m, v_shift.id);
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
  if v_later then update sales set settle_later = true where id = s.id; end if;
  return private.refresh_sale(s.id);
end $$;

-- cancel_order: requests sent to a POS terminal are withdrawn with the sale.
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
  update pos_requests set status = 'cancelled' where sale_id = s.id and status in ('creating', 'sent');
  update sales set status = 'cancelled', void_reason = trim(p_reason), voided_by = m.id, voided_at = now() where id = s.id;
  return jsonb_build_object('status', 'cancelled', 'number', s.number, 'customer_credit', v_held, 'cash_back', v_cash);
end $$;

-- match_bank_line: step 1b, a POS provider's settlement clears 9002.
create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb; v_pos text;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  select * into m from members where org_id = bl.org_id and role = 'owner' and status = 'active' order by created_at limit 1;

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;
  -- 1b A POS provider settling payments Counta already holds in 9002 (see pos_settle_line).
  if v_in then
    v_pos := private.pos_settle_line(bl, b, m);
    if v_pos is not null then return v_pos; end if;
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- The invoice's own number and exactly what is owed (or that less WHT, and VAT for a customer who withholds VAT): settled.
      -- Any other amount is put to a person below.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if abs(v_due - v_amt) < 0.005 or v_split is not null then
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'invoice_ref';
      end if;
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration: their open invoices that fit are put to a person to confirm (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'customer');
        return 'customer';
      end if;
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Paying with nothing owed: held as an advance, flagged (AR rule).
      if v_due <= 0.004 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'No invoice open: held as customer credit', 'spread', true), m, 'confirmed', null);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_advance', matched_by = 'system', confidence = 0.8 where id = bl.id;
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
        return 'customer_advance';
      end if;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'vendor_bill');
        return 'vendor_bill';
      end if;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  -- 6b Money sent to Bujeti from this account (or taken back from it): a transfer to or from the Bujeti balance.
  if upper(v_text) ~ '\yBUJETI\y' then
    select xa.* into ob from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active and xa.provider = 'integration'
      and xa.provider_ref = bl.org_id::text || ':bujeti';
    if ob.id is not null then
      perform private.post_bank_line(bl.id, ob.ledger_code, null, null, case when v_in then 'Money back from Bujeti · ' else 'Money sent to Bujeti · ' end || bl.description,
        'transfer', jsonb_build_object('matched_by', 'system'));
      return 'transfer';
    end if;
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    perform private.post_bank_line(bl.id, v_rule.account_code,
      case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
      null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named: the open invoices (or bills) the amount fits, as it stands, less WHT or less bank charges, are put to a
  --   person to confirm in one tap.
  v_cands := private.match_candidates(bl.id);
  if jsonb_array_length(v_cands) > 0 then
    perform private.propose_match(bl.id, v_cands, case when v_in then 'invoice_amount' else 'bill_amount' end);
    return case when v_in then 'invoice_amount' else 'bill_amount' end;
  end if;
  return null;
end $$;

-- voice_say: "Payment received" for a sale paid on a POS terminal too.
create or replace function public.voice_say(p_org uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; r public.payment_requests; pr public.pos_requests; i public.items; v_qty numeric; v_amount numeric; v_vars jsonb;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  case p_kind
    when 'payment_received' then
      select * into r from payment_requests where id = nullif(p->>'request_id', '')::uuid and org_id = p_org;
      -- Or a sale paid on a POS terminal: the amount, and no payer's name (card payments carry none).
      if r.id is null then
        select * into pr from pos_requests where id = nullif(p->>'request_id', '')::uuid and org_id = p_org;
        if pr.id is null then raise exception 'Payment not found.'; end if;
        if pr.status <> 'paid' then raise exception 'That payment has not arrived yet.'; end if;
        v_vars := jsonb_build_object('amount', coalesce(pr.paid_amount, pr.amount), 'payer', '');
      else
      if r.status <> 'paid' then raise exception 'That payment has not arrived yet.'; end if;
      v_vars := jsonb_build_object('amount', coalesce(r.paid_amount, r.amount),
        'payer', left(coalesce(nullif(trim(r.payer->>'name'), ''), ''), 60));
      end if;
    when 'sale_recorded' then
      select * into i from items where id = nullif(p->>'item_id', '')::uuid and org_id = p_org;
      if i.id is null then raise exception 'Item not found.'; end if;
      begin
        v_qty := (p->>'qty')::numeric; v_amount := coalesce((p->>'amount')::numeric, 0);
      exception when others then raise exception 'Quantity and amount must be numbers.';
      end;
      if v_qty is null or v_qty <= 0 or v_qty > 1000000 or v_amount < 0 or v_amount > 10000000000 then
        raise exception 'Quantity and amount are out of range.';
      end if;
      v_vars := jsonb_build_object('item', left(i.name, 80), 'unit', i.selling_unit, 'qty', v_qty, 'amount', v_amount);
    when 'payment_demo' then
      v_vars := jsonb_build_object('amount', 15000, 'payer', 'Chidi Okafor');
    else raise exception 'Unknown announcement.';
  end case;
  return jsonb_build_object('kind', p_kind, 'business', o.name, 'voice_id', o.voice_id, 'lang', o.voice_lang,
    'offering', coalesce(o.offering, 'goods'), 'enabled', private.feature_on(p_org, 'payment_voice') and (p_kind = 'payment_demo' or coalesce((o.voice_events->>p_kind)::boolean, true)), 'vars', v_vars);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.svc_pos_connection_save(jsonb), public.svc_pos_connection(uuid), public.svc_pos_by_token(text, text),
  public.svc_pos_note(uuid, jsonb), public.svc_pos_remove(uuid), public.svc_pos_request_context(uuid), public.svc_pos_request_update(uuid, jsonb),
  public.svc_pos_transaction(uuid, jsonb), public.svc_pos_due() from public, anon, authenticated;
grant execute on function public.svc_pos_connection_save(jsonb), public.svc_pos_connection(uuid), public.svc_pos_by_token(text, text),
  public.svc_pos_note(uuid, jsonb), public.svc_pos_remove(uuid), public.svc_pos_request_context(uuid), public.svc_pos_request_update(uuid, jsonb),
  public.svc_pos_transaction(uuid, jsonb), public.svc_pos_due() to service_role;
revoke execute on function public.pos_overview(uuid), public.pos_connect_check(uuid), public.pos_connection_manage(uuid), public.pos_connection_update(uuid, jsonb),
  public.pos_terminal_save(uuid, jsonb), public.pos_till_terminals(uuid, uuid), public.get_pos_request(uuid), public.pos_sale_requests(uuid),
  public.pos_waiting(uuid, uuid), public.pos_retry(uuid, uuid, text), public.pos_cancel(uuid), public.pos_test_request(uuid, uuid),
  public.pos_test_answer(uuid, text), public.pos_unassigned(uuid), public.pos_assign(uuid, jsonb) from public, anon;
grant execute on function public.pos_overview(uuid), public.pos_connect_check(uuid), public.pos_connection_manage(uuid), public.pos_connection_update(uuid, jsonb),
  public.pos_terminal_save(uuid, jsonb), public.pos_till_terminals(uuid, uuid), public.get_pos_request(uuid), public.pos_sale_requests(uuid),
  public.pos_waiting(uuid, uuid), public.pos_retry(uuid, uuid, text), public.pos_cancel(uuid), public.pos_test_request(uuid, uuid),
  public.pos_test_answer(uuid, text), public.pos_unassigned(uuid), public.pos_assign(uuid, jsonb) to authenticated, service_role;
revoke all on function private.pos_provider_name(text), private.pos_terminal_name(public.pos_terminals), private.pos_conn_json(public.pos_connections),
  private.pos_request_json(public.pos_requests), private.pos_txn_json(public.pos_transactions), private.pos_require_owner(uuid), private.pos_require_manager(uuid),
  private.pos_require_books(uuid), private.pos_owner_member(uuid), private.pos_new_reference(), private.pos_vault_put(uuid, text, text),
  private.pos_hold(public.pos_transactions, public.pos_connections, text),
  private.pos_txn_sale(public.pos_transactions, public.pos_connections, public.members, text, numeric),
  private.pos_pay_request(public.pos_requests, public.pos_transactions, public.pos_connections, text),
  private.pos_walk_up(public.pos_transactions, public.pos_connections),
  private.open_pos_request(uuid, uuid, uuid, numeric, text, public.members, uuid, text),
  private.pos_settle_line(public.bank_lines, public.bank_accounts, public.members) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Every two minutes: requests still waiting on a terminal, and each account's history every six hours
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-pos';
    -- Only when some business has a terminal connected, so the function is not called for nothing.
    perform cron.schedule('counta-pos', '*/2 * * * *', $c$select private.call_function('pos', '{"action":"poll"}'::jsonb)
      where exists (select 1 from public.pos_connections where status in ('live', 'error'))$c$);
  end if;
end $$;
