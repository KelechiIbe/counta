-- Counta · Payments: a wallet per business, pay-by-transfer at checkout, payment links, NQR, payouts,
-- provider webhooks, a wallet feed into banking, and nightly reconciliation of every wallet.
--
-- Rails. Flutterwave is the default rail. A partner integrating TaxStreem can register its own rail that speaks the
-- Counta Rail API (docs/payment-rails.md); a business on that rail then collects and pays out through the partner
-- instead of Flutterwave. Everything below is rail-neutral: the `payments` edge function talks to the rail, and
-- calls the svc_* functions here (service role only) with what the rail reported, after verifying it.
--
-- Money flow on Flutterwave. Each business gets a payout subaccount (its wallet, with its own NUBAN at Flutterwave MFB).
-- A checkout transfer goes to a one-off virtual account, a payment link or an NQR code; the money lands in TaxStreem's
-- Flutterwave balance and is swept into the business's wallet at once. The business's books see it the moment it is
-- confirmed: Dr wallet (net) + Dr 6701 fee / Cr 1101 customer. Payouts leave from the wallet.

-- ---------------------------------------------------------------------------
-- 1. Rails, wallets, settings
-- ---------------------------------------------------------------------------
create table if not exists public.payment_rails (
  code text primary key check (code ~ '^[a-z0-9_]{2,32}$'),
  name text not null,
  kind text not null check (kind in ('flutterwave', 'http')),
  base_url text check (base_url is null or base_url ~ '^https://'),
  capabilities text[] not null default '{wallet,account,link,qr,payout}',
  api_key_secret text,
  webhook_secret text,
  support_contact text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (kind = 'flutterwave' or base_url is not null)
);
insert into public.payment_rails (code, name, kind, capabilities)
values ('flutterwave', 'Flutterwave', 'flutterwave', '{wallet,account,link,qr,payout}')
on conflict (code) do nothing;
-- Rails are platform settings, read only through get_payments and the service role.
alter table public.payment_rails enable row level security;
revoke all on public.payment_rails from anon, authenticated;

alter table public.orgs add column if not exists payment_rail text not null default 'flutterwave';
alter table public.orgs drop constraint if exists orgs_payment_rail_fk;
alter table public.orgs add constraint orgs_payment_rail_fk foreign key (payment_rail) references public.payment_rails(code);
alter table public.orgs add column if not exists payout_approval_threshold numeric(16,2) not null default 0;
alter table public.orgs add column if not exists payment_methods text[] not null default '{account,link,qr}';

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  rail text not null references public.payment_rails(code),
  bank_account_id uuid references public.bank_accounts(id),
  account_ref text,
  barter_id text,
  account_number text,
  bank_name text,
  account_name text,
  status text not null default 'creating' check (status in ('creating', 'active', 'failed', 'closed')),
  error text,
  provider_available numeric(16,2),
  provider_ledger numeric(16,2),
  balance_at timestamptz,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, rail)
);
create unique index if not exists wallets_ref on public.wallets(rail, account_ref) where account_ref is not null;
create index if not exists wallets_bank_fk on public.wallets(bank_account_id);
create index if not exists wallets_created_by_fk on public.wallets(created_by);

alter table public.payment_requests add column if not exists wallet_id uuid references public.wallets(id) on delete set null;
alter table public.payment_requests add column if not exists sweep_status text check (sweep_status in ('not_needed', 'pending', 'sent', 'done', 'failed'));
alter table public.payment_requests add column if not exists sweep_ref text;
alter table public.payment_requests add column if not exists swept_at timestamptz;
alter table public.payment_requests add column if not exists sweep_error text;
alter table public.payment_requests add column if not exists collection_id uuid references public.collections(id) on delete set null;
alter table public.payment_requests add column if not exists public_request boolean not null default false;
alter table public.payment_requests add column if not exists checked_at timestamptz;
create index if not exists payment_requests_wallet_fk on public.payment_requests(wallet_id);
create index if not exists payment_requests_collection_fk on public.payment_requests(collection_id);
create index if not exists payment_requests_sweep on public.payment_requests(sweep_status) where sweep_status in ('pending', 'sent', 'failed');

-- Every webhook and verification result, once. The key is what the rail calls the event (its transaction id and status).
create table if not exists public.payment_events (
  id bigint generated always as identity primary key,
  rail text not null,
  event text not null,
  event_key text not null,
  org_id uuid references public.orgs(id) on delete set null,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  outcome text,
  error text,
  unique (rail, event_key)
);
create index if not exists payment_events_org on public.payment_events(org_id, received_at desc);

-- ---------------------------------------------------------------------------
-- 2. Bank lines: every movement on a bank account or wallet, from statements or the wallet feed
-- ---------------------------------------------------------------------------
create table if not exists public.bank_lines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  line_date date not null,
  amount numeric(16,2) not null check (amount <> 0),
  balance_after numeric(16,2),
  description text not null default '',
  reference text,
  counterparty text,
  counterparty_account text,
  counterparty_bank text,
  source text not null check (source in ('statement', 'wallet', 'rail', 'manual', 'api')),
  provider_ref text,
  import_id uuid,
  fingerprint text not null,
  status text not null default 'unmatched' check (status in ('unmatched', 'matched', 'posted', 'proposed', 'ignored')),
  journal_id uuid references public.journals(id) on delete set null,
  proposal_id uuid references public.ai_proposals(id) on delete set null,
  matched_by text check (matched_by in ('system', 'rule', 'ai', 'user')),
  confidence numeric(4,3),
  note text,
  created_at timestamptz not null default now(),
  unique (bank_account_id, fingerprint)
);
create index if not exists bank_lines_org on public.bank_lines(org_id, status, line_date desc);
create index if not exists bank_lines_account on public.bank_lines(bank_account_id, line_date desc);
create index if not exists bank_lines_journal_fk on public.bank_lines(journal_id);
create index if not exists bank_lines_proposal_fk on public.bank_lines(proposal_id);
create unique index if not exists bank_lines_provider on public.bank_lines(bank_account_id, provider_ref) where provider_ref is not null;

-- ---------------------------------------------------------------------------
-- 3. Payouts from the wallet
-- ---------------------------------------------------------------------------
create table if not exists public.payouts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  wallet_id uuid not null references public.wallets(id),
  purpose text not null check (purpose in ('vendor', 'withdrawal', 'expense', 'refund', 'staff', 'other')),
  vendor_id uuid references public.vendors(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  to_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  amount numeric(16,2) not null check (amount > 0),
  fee numeric(16,2) not null default 0 check (fee >= 0),
  currency text not null default 'NGN',
  bank_code text not null,
  bank_name text,
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null,
  narration text not null,
  lines jsonb not null default '[]'::jsonb,
  reference text not null unique,
  provider_ref text,
  status text not null default 'pending_approval' check (status in ('pending_approval', 'approved', 'processing', 'successful', 'failed', 'cancelled', 'reversed')),
  requested_by uuid references public.members(id) on delete set null,
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  sent_at timestamptz,
  completed_at timestamptz,
  journal_id uuid references public.journals(id) on delete set null,
  error text,
  raw jsonb,
  client_uuid uuid unique,
  created_at timestamptz not null default now(),
  unique (org_id, number)
);
create index if not exists payouts_org on public.payouts(org_id, created_at desc);
create index if not exists payouts_wallet_fk on public.payouts(wallet_id);
create index if not exists payouts_vendor_fk on public.payouts(vendor_id);
create index if not exists payouts_customer_fk on public.payouts(customer_id);
create index if not exists payouts_to_bank_fk on public.payouts(to_bank_account_id);
create index if not exists payouts_requested_by_fk on public.payouts(requested_by);
create index if not exists payouts_approved_by_fk on public.payouts(approved_by);
create index if not exists payouts_journal_fk on public.payouts(journal_id);
create index if not exists payouts_open on public.payouts(status) where status in ('pending_approval', 'approved', 'processing');

create table if not exists public.wallet_reconciliations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  at timestamptz not null default now(),
  provider_balance numeric(16,2) not null,
  books_balance numeric(16,2) not null,
  in_transit numeric(16,2) not null default 0,
  difference numeric(16,2) not null,
  status text not null check (status in ('matched', 'difference')),
  details jsonb not null default '{}'::jsonb
);
create index if not exists wallet_reconciliations_wallet on public.wallet_reconciliations(wallet_id, at desc);
create index if not exists wallet_reconciliations_org on public.wallet_reconciliations(org_id);

create or replace function private.can_handle_money(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.has_perm(p_org, 'keep_books') or private.has_perm(p_org, 'make_payments') or private.has_perm(p_org, 'see_margins')
$$;

alter table public.wallets enable row level security;
alter table public.payment_events enable row level security;
alter table public.bank_lines enable row level security;
alter table public.payouts enable row level security;
alter table public.wallet_reconciliations enable row level security;
drop policy if exists wallets_read on public.wallets;
create policy wallets_read on public.wallets for select to authenticated using ((select private.is_member(org_id)));
drop policy if exists bank_lines_read on public.bank_lines;
create policy bank_lines_read on public.bank_lines for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists payouts_read on public.payouts;
create policy payouts_read on public.payouts for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists wallet_reconciliations_read on public.wallet_reconciliations;
create policy wallet_reconciliations_read on public.wallet_reconciliations for select to authenticated using ((select private.can_handle_money(org_id)));

-- ---------------------------------------------------------------------------
-- 4. Requests for payment (staff and the public)
-- ---------------------------------------------------------------------------
create or replace function private.request_json(r public.payment_requests) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', r.id, 'tx_ref', r.tx_ref, 'method', r.method, 'rail', r.rail, 'amount', r.amount, 'currency', r.currency, 'status', r.status,
    'account_number', r.account_number, 'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'qr_image', r.qr_image,
    'expires_at', r.expires_at, 'paid_amount', r.paid_amount, 'paid_at', r.paid_at, 'error', r.error, 'sale_id', r.sale_id,
    'sale_number', (select number from sales where id = r.sale_id), 'sale_status', (select status from sales where id = r.sale_id),
    'payer', case when r.status = 'paid' then r.payer->>'name' end)
$$;

-- Everything the edge function needs to ask the rail for a payment.
create or replace function private.request_context(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('request', private.request_json(r), 'org_id', r.org_id, 'org_name', o.name, 'org_email', o.email, 'org_phone', o.phone,
    'logo_path', o.logo_path, 'rail', r.rail, 'rail_kind', pr.kind, 'base_url', pr.base_url, 'api_key_secret', pr.api_key_secret,
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'barter_id', w.barter_id) from wallets w where w.id = r.wallet_id),
    'customer', jsonb_build_object('name', coalesce(c.name, s.customer_name, 'Customer'), 'email', coalesce(c.email, s.customer_email),
       'phone', coalesce(c.phone, s.customer_phone), 'walk_in', coalesce(c.is_walk_in, false)),
    'public_token', s.public_token, 'narration', coalesce(s.number, 'Payment') || ' · ' || o.name)
  from payment_requests r join orgs o on o.id = r.org_id join payment_rails pr on pr.code = r.rail
  left join sales s on s.id = r.sale_id left join customers c on c.id = coalesce(r.customer_id, s.customer_id)
  where r.id = p_request
$$;

-- Opens a request for money against a sale, an order or a customer's balance. A request still waiting for the same
-- amount by the same method is reused, so pressing the button twice never gives the customer two accounts to pay.
create or replace function private.open_request(p_org uuid, p_sale uuid, p_customer uuid, p_method text, p_amount numeric, m public.members,
  p_public boolean, p_shift uuid) returns public.payment_requests
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s public.sales; w public.wallets; r public.payment_requests; v_amt numeric; v_due numeric; v_pending numeric; pr public.payment_rails;
begin
  select * into o from orgs where id = p_org;
  select * into pr from payment_rails where code = o.payment_rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  if p_method not in ('account', 'link', 'qr') then raise exception 'Choose transfer, link or QR.'; end if;
  if not (p_method = any(pr.capabilities)) or not (p_method = any(o.payment_methods)) then raise exception 'This way of paying is not switched on.'; end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments before taking payments.'; end if;
  if p_sale is not null then
    select * into s from sales where id = p_sale and org_id = p_org for update;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
    if s.status in ('void', 'cancelled', 'draft', 'converted', 'paid', 'credited') then raise exception '% has nothing to pay.', s.number; end if;
    v_due := s.total - s.amount_paid - s.credited;
    select coalesce(sum(a.amount), 0) into v_pending from collection_allocations a join collections c on c.id = a.collection_id
      where a.sale_id = s.id and c.status = 'pending';
    v_amt := round(coalesce(p_amount, v_due - v_pending), 2);
    if v_amt > v_due + 0.004 then raise exception 'Only % is owed on %.', to_char(v_due, 'FM999,999,999,990.00'), s.number; end if;
  else
    if p_customer is null or not exists (select 1 from customers where id = p_customer and org_id = p_org and not is_walk_in) then
      raise exception 'Choose the customer.';
    end if;
    v_amt := round(coalesce(p_amount, greatest(private.customer_balance(p_org, p_customer), 0)), 2);
  end if;
  if coalesce(v_amt, 0) < 100 then raise exception 'The amount to collect must be at least ₦100.'; end if;
  select * into r from payment_requests
  where org_id = p_org and sale_id is not distinct from p_sale and customer_id is not distinct from coalesce(p_customer, s.customer_id)
    and method = p_method and amount = v_amt and status = 'pending' and (expires_at is null or expires_at > now() + interval '5 minutes')
  order by created_at desc limit 1;
  if found then return r; end if;
  -- Earlier requests for the same sale that were never paid are withdrawn.
  update payment_requests set status = 'cancelled' where sale_id = p_sale and p_sale is not null and status in ('creating', 'pending') and method = p_method;
  insert into payment_requests (org_id, sale_id, customer_id, purpose, method, rail, amount, tx_ref, status, shift_id, created_by, wallet_id, public_request)
  values (p_org, p_sale, coalesce(p_customer, s.customer_id), case when p_sale is null then 'customer_balance' when s.doc_type = 'order' then 'order' else 'sale' end,
    p_method, o.payment_rail, v_amt, 'CNT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), 'creating', p_shift, m.id, w.id, p_public)
  returning * into r;
  return r;
end $$;

create or replace function public.create_payment_request(p_org uuid, p_request jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r public.payment_requests;
begin
  m := private.require(p_org, 'record_sales');
  r := private.open_request(p_org, nullif(p_request->>'sale_id', '')::uuid, nullif(p_request->>'customer_id', '')::uuid,
    coalesce(nullif(p_request->>'method', ''), 'account'), private.num(p_request->>'amount'), m, false, nullif(p_request->>'shift_id', '')::uuid);
  return private.request_context(r.id);
end $$;

create or replace function public.get_payment_request(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r public.payment_requests;
begin
  select * into r from payment_requests where id = p_request;
  if not found then raise exception 'Payment request not found.'; end if;
  perform private.require(r.org_id, null);
  return private.request_json(r);
end $$;

create or replace function public.cancel_payment_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.payment_requests;
begin
  select * into r from payment_requests where id = p_request for update;
  if not found then raise exception 'Payment request not found.'; end if;
  perform private.require(r.org_id, 'record_sales');
  if r.status not in ('creating', 'pending') then raise exception 'This request is already %.', r.status; end if;
  update payment_requests set status = 'cancelled' where id = r.id returning * into r;
  return private.request_json(r);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Payouts
-- ---------------------------------------------------------------------------
create or replace function private.wallet_balance(p_wallet uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join bank_accounts b on b.ledger_code = l.account_code and b.org_id = l.org_id
  join wallets w on w.bank_account_id = b.id where w.id = p_wallet
$$;

-- p: {purpose, amount, bank_code, bank_name, account_number, account_name, narration, vendor_id, customer_id, to_bank_account_id,
--     expense_account, client_uuid}. Vendor bill payments come through pay_bill (payables), which builds its own lines.
create or replace function private.create_payout(p_org uuid, p jsonb, p_lines jsonb, m public.members) returns public.payouts
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; po public.payouts; v_amt numeric := round(private.num(p->>'amount'), 2); v_status text; v_inflight numeric;
begin
  if nullif(p->>'client_uuid', '') is not null then
    select * into po from payouts where client_uuid = (p->>'client_uuid')::uuid;
    if found then return po; end if;
  end if;
  select * into o from orgs where id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments first.'; end if;
  if not exists (select 1 from payment_rails where code = w.rail and 'payout' = any(capabilities)) then raise exception 'This payment rail does not make payouts.'; end if;
  if coalesce(v_amt, 0) < 100 then raise exception 'A payout must be at least ₦100.'; end if;
  if coalesce(p->>'account_number', '') !~ '^[0-9]{10}$' then raise exception 'Enter the 10-digit account number.'; end if;
  if coalesce(trim(p->>'bank_code'), '') = '' then raise exception 'Choose the bank.'; end if;
  if coalesce(trim(p->>'account_name'), '') = '' then raise exception 'Check the account name before paying.'; end if;
  select coalesce(sum(amount + fee), 0) into v_inflight from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval');
  if v_amt > private.wallet_balance(w.id) - v_inflight + 0.004 then
    raise exception 'The wallet holds % after payouts already waiting. Fund it first.', to_char(private.wallet_balance(w.id) - v_inflight, 'FM999,999,999,990.00');
  end if;
  v_status := case when o.payout_approval_threshold > 0 and v_amt >= o.payout_approval_threshold and m.role <> 'owner' then 'pending_approval' else 'approved' end;
  insert into payouts (org_id, number, wallet_id, purpose, vendor_id, customer_id, to_bank_account_id, amount, bank_code, bank_name, account_number, account_name,
    narration, lines, reference, status, requested_by, approved_by, approved_at, client_uuid)
  values (p_org, 'PO-' || lpad(private.next_no(p_org, 'PO', 1)::text, 5, '0'), w.id, coalesce(nullif(p->>'purpose', ''), 'other'),
    nullif(p->>'vendor_id', '')::uuid, nullif(p->>'customer_id', '')::uuid, nullif(p->>'to_bank_account_id', '')::uuid, v_amt, trim(p->>'bank_code'),
    nullif(trim(p->>'bank_name'), ''), p->>'account_number', left(trim(p->>'account_name'), 120), left(coalesce(nullif(trim(p->>'narration'), ''), o.name), 80),
    p_lines, 'CNTP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), v_status, m.id,
    case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid)
  returning * into po;
  if v_status = 'pending_approval' then
    perform private.notify_perm(p_org, 'make_payments', 'payout', 'Approve a payout of ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
      po.account_name || ' · ' || po.narration || ' · asked by ' || coalesce(m.display_name, ''), '/payments', 'payout-' || po.id, m.id);
  end if;
  return po;
end $$;

-- Debits for a payout that is not a bill: a withdrawal to the business's own bank, an expense paid directly, a customer refund.
create or replace function public.request_payout(p_org uuid, p_payout jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_purpose text := coalesce(nullif(p_payout->>'purpose', ''), 'other'); v_amt numeric := round(private.num(p_payout->>'amount'), 2);
  v_lines jsonb; v_code text; b public.bank_accounts; po public.payouts; v_bal numeric; v_ar numeric; v_adv numeric;
begin
  m := private.require(p_org, 'make_payments');
  if v_purpose = 'withdrawal' then
    select * into b from bank_accounts where id = nullif(p_payout->>'to_bank_account_id', '')::uuid and org_id = p_org and active and kind = 'bank';
    if not found then raise exception 'Choose which of the business''s bank accounts to send it to.'; end if;
    v_lines := jsonb_build_array(jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', 'From wallet'));
    p_payout := p_payout || jsonb_build_object('account_number', coalesce(nullif(p_payout->>'account_number', ''), b.account_number),
      'account_name', coalesce(nullif(p_payout->>'account_name', ''), b.account_name, (select name from orgs where id = p_org)),
      'bank_code', coalesce(nullif(p_payout->>'bank_code', ''), b.bank_code),
      'bank_name', coalesce(nullif(p_payout->>'bank_name', ''), b.bank_name));
  elsif v_purpose = 'expense' then
    v_code := nullif(p_payout->>'expense_account', '');
    if v_code is null or v_code !~ '^[5-7]' or not private.postable(p_org, v_code) then raise exception 'Choose the expense account.'; end if;
    v_lines := jsonb_build_array(jsonb_build_object('code', v_code, 'debit', v_amt, 'memo', p_payout->>'narration'));
  elsif v_purpose = 'refund' then
    if nullif(p_payout->>'customer_id', '') is null or not exists (select 1 from customers where id = (p_payout->>'customer_id')::uuid and org_id = p_org) then
      raise exception 'Choose the customer being refunded.';
    end if;
    if not (private.perm_of(m, 'approve_adjustments') or m.role = 'owner') then raise exception 'Only a manager or the owner refunds customers.'; end if;
    v_bal := private.customer_balance(p_org, (p_payout->>'customer_id')::uuid);
    if v_amt > -v_bal + 0.004 then raise exception 'The customer has % of credit to refund.', to_char(greatest(-v_bal, 0), 'FM999,999,999,990.00'); end if;
    select coalesce(sum(debit - credit), 0) into v_ar from journal_lines where org_id = p_org and party_type = 'customer'
      and party_id = (p_payout->>'customer_id')::uuid and account_code in ('1101', '1102');
    v_adv := greatest(v_amt - greatest(-v_ar, 0), 0);
    v_lines := jsonb_build_array(
      jsonb_build_object('code', private.acct(p_org, 'receivables'), 'debit', v_amt - v_adv, 'party_type', 'customer', 'party_id', p_payout->>'customer_id'),
      jsonb_build_object('code', private.acct(p_org, 'customer_advances'), 'debit', v_adv, 'party_type', 'customer', 'party_id', p_payout->>'customer_id'));
  elsif v_purpose in ('vendor', 'staff', 'other') then
    raise exception 'Pay suppliers from their bill, and staff through payroll, so the books show what was paid for.';
  else
    raise exception 'Unknown payout purpose.';
  end if;
  po := private.create_payout(p_org, p_payout || jsonb_build_object('purpose', v_purpose), v_lines, m);
  return to_jsonb(po);
end $$;

create or replace function public.approve_payout(p_payout uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'make_payments');
  if po.status <> 'pending_approval' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  if po.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then nullif(trim(p_note), '') else error end
  where id = po.id returning * into po;
  return to_jsonb(po);
end $$;

create or replace function public.cancel_payout(p_payout uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'make_payments');
  if po.status not in ('pending_approval', 'approved') then raise exception '% is %.', po.number, po.status; end if;
  update payouts set status = 'cancelled' where id = po.id returning * into po;
  return to_jsonb(po);
end $$;

-- Marks an approved payout as being sent and hands the edge function what the rail needs. Called with the user's own token.
create or replace function public.payout_to_send(p_payout uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; m public.members; w public.wallets; pr public.payment_rails;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'make_payments');
  if po.status <> 'approved' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  select * into w from wallets where id = po.wallet_id;
  select * into pr from payment_rails where code = w.rail;
  update payouts set status = 'processing', sent_at = now() where id = po.id returning * into po;
  return jsonb_build_object('payout', to_jsonb(po), 'rail', w.rail, 'rail_kind', pr.kind, 'base_url', pr.base_url, 'api_key_secret', pr.api_key_secret,
    'wallet', jsonb_build_object('account_ref', w.account_ref, 'barter_id', w.barter_id));
end $$;

-- Posts a payout that the rail says went through: Dr what it paid for / Cr wallet, and the transfer fee.
create or replace function private.post_payout(p_payout uuid) returns public.payouts
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; w public.wallets; b public.bank_accounts; v_jl jsonb; j public.journals;
begin
  select * into po from payouts where id = p_payout for update;
  if po.journal_id is not null then return po; end if;
  select * into w from wallets where id = po.wallet_id;
  select * into b from bank_accounts where id = w.bank_account_id;
  v_jl := po.lines || jsonb_build_array(jsonb_build_object('code', b.ledger_code, 'credit', po.amount + po.fee, 'memo', po.number || ' · ' || po.account_name));
  if po.fee > 0 then
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(po.org_id, 'payment_fees'), 'debit', po.fee, 'memo', 'Transfer fee ' || po.number));
  end if;
  j := private.post_entry(po.org_id, 'Payout ' || po.number || ' · ' || po.account_name || ' · ' || po.narration, 'payout', po.id, po.requested_by, po.approved_by, v_jl,
    coalesce(po.completed_at, now()),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'provider', 'rail', w.rail, 'ref', coalesce(po.provider_ref, po.reference)))));
  update payouts set journal_id = j.id where id = po.id returning * into po;
  -- The wallet's own statement shows the money leaving, already matched to this journal.
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, source, provider_ref,
    fingerprint, status, journal_id, matched_by, confidence)
  values (po.org_id, b.id, private.local_day(po.org_id, coalesce(po.completed_at, now())), -(po.amount + po.fee), po.narration, po.reference, po.account_name,
    po.account_number, 'wallet', coalesce(po.provider_ref, po.reference), 'payout:' || po.reference, 'matched', j.id, 'system', 1)
  on conflict do nothing;
  return po;
end $$;

-- ---------------------------------------------------------------------------
-- 6. What the payments edge function calls (service role only)
-- ---------------------------------------------------------------------------
create or replace function public.svc_rail(p_code text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(r) from payment_rails r where r.code = p_code
$$;

create or replace function public.svc_secret(p_name text) returns text
language sql stable security definer set search_path = public, vault as $$
  -- Rail keys and webhook secrets named on payment_rails, plus the Flutterwave and messaging keys.
  select s.decrypted_secret from vault.decrypted_secrets s
  where s.name = p_name
    and (p_name in ('FLW_SECRET_KEY', 'FLW_PUBLIC_KEY', 'FLW_WEBHOOK_HASH', 'RESEND_API_KEY', 'RESEND_FROM', 'WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID',
                     'WHATSAPP_BUSINESS_ACCOUNT_ID', 'WHATSAPP_APP_SECRET', 'WHATSAPP_VERIFY_TOKEN', 'TAXSTREEM_SSO_SECRET', 'NUMENS_API_URL', 'NUMENS_API_KEY')
         or p_name in (select api_key_secret from public.payment_rails where api_key_secret is not null
                       union select webhook_secret from public.payment_rails where webhook_secret is not null))
  order by s.created_at desc limit 1
$$;

create or replace function public.svc_wallet_to_open(p_org uuid, p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; pr public.payment_rails; m public.members;
begin
  select * into o from orgs where id = p_org;
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if m.id is null or not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or m.role = 'owner') then
    raise exception 'Only the owner or someone who keeps the books opens the wallet.';
  end if;
  select * into pr from payment_rails where code = o.payment_rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  if found and w.status = 'active' then return jsonb_build_object('wallet', to_jsonb(w), 'ready', true); end if;
  if not found then
    insert into wallets (org_id, rail, status, created_by) values (p_org, o.payment_rail, 'creating', m.id) returning * into w;
  else
    update wallets set status = 'creating', error = null where id = w.id returning * into w;
  end if;
  return jsonb_build_object('wallet', to_jsonb(w), 'ready', false, 'rail', to_jsonb(pr) - 'api_key_secret' - 'webhook_secret',
    'api_key_secret', pr.api_key_secret, 'org', jsonb_build_object('name', o.name, 'email', o.email, 'phone', o.phone, 'id', o.id));
end $$;

-- d: {account_ref, barter_id, account_number, bank_name, account_name} or {error}
create or replace function public.svc_wallet_ready(p_wallet uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; b public.bank_accounts;
begin
  select * into w from wallets where id = p_wallet for update;
  if not found then raise exception 'Wallet not found.'; end if;
  if nullif(d->>'error', '') is not null then
    update wallets set status = 'failed', error = left(d->>'error', 500) where id = w.id returning * into w;
    return to_jsonb(w);
  end if;
  if w.bank_account_id is null then
    b := private.open_bank_account(w.org_id, 'wallet', coalesce(nullif(d->>'bank_name', ''), 'Wallet') || ' wallet · ' || coalesce(right(d->>'account_number', 4), ''),
      jsonb_build_object('provider', case when w.rail = 'flutterwave' then 'flutterwave' else 'rail' end, 'provider_ref', d->>'account_ref',
        'account_number', d->>'account_number', 'bank_name', d->>'bank_name', 'account_name', d->>'account_name', 'is_collection', true,
        'provider_meta', jsonb_build_object('rail', w.rail, 'barter_id', d->>'barter_id')), w.created_by);
  end if;
  update wallets set status = 'active', error = null, account_ref = d->>'account_ref', barter_id = nullif(d->>'barter_id', ''),
    account_number = d->>'account_number', bank_name = d->>'bank_name', account_name = d->>'account_name', bank_account_id = coalesce(bank_account_id, b.id)
  where id = w.id returning * into w;
  return to_jsonb(w);
end $$;

-- A payer opening a shared document asks to pay it. Ten requests an hour per document at most.
create or replace function public.svc_public_request(p_token text, p_method text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; r public.payment_requests; m public.members;
begin
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if (select count(*) from payment_requests where sale_id = s.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many attempts. Try again later.';
  end if;
  r := private.open_request(s.org_id, s.id, null, coalesce(nullif(p_method, ''), 'account'), null, m, true, null);
  return private.request_context(r.id);
end $$;

create or replace function public.svc_request_context(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.request_context(p_request)
$$;

-- d: {status: 'pending'|'failed', provider_ref, account_number, bank_name, account_name, link_url, qr_image, expires_at, error}
create or replace function public.svc_request_update(p_request uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.payment_requests;
begin
  update payment_requests set
    status = case when status in ('creating', 'pending') then coalesce(nullif(d->>'status', ''), status) else status end,
    provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref),
    account_number = coalesce(nullif(d->>'account_number', ''), account_number),
    bank_name = coalesce(nullif(d->>'bank_name', ''), bank_name),
    account_name = coalesce(nullif(d->>'account_name', ''), account_name),
    link_url = coalesce(nullif(d->>'link_url', ''), link_url),
    qr_image = coalesce(nullif(d->>'qr_image', ''), qr_image),
    expires_at = coalesce(nullif(d->>'expires_at', '')::timestamptz, expires_at),
    error = case when d->>'status' = 'failed' then left(d->>'error', 500) else error end,
    checked_at = now()
  where id = p_request returning * into r;
  return private.request_json(r);
end $$;

-- The rail confirmed money for a request (after Counta verified it with the rail). Idempotent on the request.
-- d: {amount, charged_amount, fee, provider_ref, payer:{name, account, bank}, paid_at}
create or replace function public.svc_payment_confirmed(p_tx_ref text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.payment_requests; w public.wallets; c public.collections; s public.sales; v_amt numeric; v_fee numeric; m public.members;
begin
  select * into r from payment_requests where tx_ref = p_tx_ref for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if r.status = 'paid' then return jsonb_build_object('ok', true, 'duplicate', true, 'request', private.request_json(r)); end if;
  v_amt := round(coalesce(private.num(d->>'amount'), 0), 2);
  if v_amt <= 0 then return jsonb_build_object('ok', false, 'reason', 'no_amount'); end if;
  v_fee := least(greatest(round(coalesce(private.num(d->>'fee'), 0), 2), 0), v_amt);
  select * into w from wallets where id = r.wallet_id;
  -- The money arrived even if the request was cancelled or expired in the meantime: it still belongs to this customer.
  update payment_requests set status = 'paid', paid_amount = v_amt, fee = v_fee, paid_at = coalesce(nullif(d->>'paid_at', '')::timestamptz, now()),
    provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), payer = d->'payer',
    sweep_status = case when r.rail = 'flutterwave' and w.barter_id is not null then 'pending' else 'not_needed' end
  where id = r.id returning * into r;
  m := (select mm from members mm where mm.id = r.created_by);
  if r.sale_id is not null then
    select * into s from sales where id = r.sale_id for update;
    -- A till sale waiting for this transfer posts now, and takes its stock.
    if s.doc_type = 'receipt' and s.journal_id is null and s.status not in ('cancelled', 'void', 'draft') then
      perform private.post_sale(s.id, coalesce(m, jsonb_populate_record(null::public.members, jsonb_build_object('id', s.created_by))), r.paid_at);
      select * into s from sales where id = s.id;
    end if;
  end if;
  c := private.add_collection(r.org_id, coalesce(r.customer_id, s.customer_id), v_amt, case when r.rail = 'flutterwave' then 'flutterwave' else 'rail' end,
    jsonb_build_object('bank_account_id', w.bank_account_id, 'fee', v_fee, 'provider_ref', coalesce(nullif(d->>'provider_ref', ''), r.tx_ref),
      'reference', r.tx_ref, 'payment_request_id', r.id, 'received_at', r.paid_at, 'shift_id', r.shift_id,
      'note', 'Paid by ' || coalesce(d->'payer'->>'name', 'customer') || coalesce(' from ' || (d->'payer'->>'bank'), ''),
      'spread', case when (s.id is null or s.status in ('void', 'cancelled'))
                      and not (select is_walk_in from customers where id = coalesce(r.customer_id, s.customer_id)) then 'true' else 'false' end),
    null::public.members, 'confirmed',
    case when s.id is not null and s.status not in ('void', 'cancelled') then array[s.id] end);
  -- The rail confirmed it, not a person; the request's author stays on record as who asked for it.
  update collections set created_by = r.created_by where id = c.id;
  update payment_requests set collection_id = c.id where id = r.id returning * into r;
  -- Tell whoever asked for it, and the people who look after money.
  if m.user_id is not null then
    perform private.notify(r.org_id, m.user_id, 'payment', 'Paid ₦' || to_char(v_amt, 'FM999,999,999,990.00') || coalesce(' for ' || s.number, ''),
      coalesce(d->'payer'->>'name', 'Customer') || ' paid by ' || case r.method when 'account' then 'transfer' when 'link' then 'payment link' else 'QR' end,
      case when s.id is not null then '/sell/sales/' || s.id else '/sell/customers' end, 'paid-' || r.id);
  end if;
  return jsonb_build_object('ok', true, 'request', private.request_json(r), 'collection', c.number, 'org_id', r.org_id,
    'sweep', case when r.sweep_status = 'pending' then jsonb_build_object('barter_id', w.barter_id, 'amount', v_amt - v_fee, 'reference', 'SWP-' || r.tx_ref) end);
end $$;

-- p_ref is the transfer reference actually used: a retry after a failed sweep needs a fresh one, because the rail keeps
-- every reference it has seen, failed or not.
create or replace function public.svc_sweep_update(p_tx_ref text, p_status text, p_error text default null, p_ref text default null) returns void
language sql security definer set search_path = public, private as $$
  update public.payment_requests set sweep_status = p_status, sweep_ref = coalesce(nullif(p_ref, ''), sweep_ref, 'SWP-' || tx_ref),
    swept_at = case when p_status in ('sent', 'done') then coalesce(swept_at, now()) else swept_at end,
    sweep_error = case when p_status = 'failed' then left(p_error, 500) else null end
  where tx_ref = p_tx_ref and p_status in ('sent', 'done', 'failed');
$$;

-- d: {status: 'successful'|'failed'|'processing', fee, provider_ref, error, raw}
create or replace function public.svc_payout_update(p_reference text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; v_status text := lower(coalesce(d->>'status', ''));
begin
  select * into po from payouts where reference = p_reference for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if po.status in ('successful', 'failed', 'cancelled', 'reversed') and po.status <> 'failed' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'status', po.status);
  end if;
  if v_status in ('successful', 'success', 'completed') then
    update payouts set status = 'successful', completed_at = coalesce(nullif(d->>'completed_at', '')::timestamptz, now()),
      fee = round(coalesce(private.num(d->>'fee'), fee), 2), provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), raw = coalesce(d->'raw', raw), error = null
    where id = po.id;
    po := private.post_payout(po.id);
    perform private.notify_perm(po.org_id, 'make_payments', 'payout', 'Paid ₦' || to_char(po.amount, 'FM999,999,999,990.00') || ' to ' || po.account_name,
      po.narration, '/payments', 'payout-done-' || po.id);
  elsif v_status in ('failed', 'error', 'reversed') then
    if po.journal_id is not null then
      perform private.reverse_entry(po.journal_id, po.requested_by, 'Payout ' || po.number || ' reversed by the bank', null);
    end if;
    update payouts set status = case when po.journal_id is not null then 'reversed' else 'failed' end, error = left(coalesce(d->>'error', 'The transfer failed.'), 500),
      raw = coalesce(d->'raw', raw), provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref)
    where id = po.id returning * into po;
    perform private.notify_perm(po.org_id, 'make_payments', 'payout', 'Payout to ' || po.account_name || ' failed', coalesce(po.error, ''), '/payments', 'payout-fail-' || po.id);
  else
    update payouts set provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), raw = coalesce(d->'raw', raw),
      fee = round(coalesce(private.num(d->>'fee'), fee), 2) where id = po.id returning * into po;
  end if;
  select * into po from payouts where id = po.id;
  return jsonb_build_object('ok', true, 'status', po.status, 'number', po.number);
end $$;

-- Money that reached a wallet's own account number directly (not through a checkout request): a customer paying the
-- business's account, the owner topping up, or our own sweep arriving. Sweeps are matched at once; everything else is a
-- bank line for the bookkeeper agent. d: {amount, reference, narration, sender:{name, account, bank}, at, provider_ref}
create or replace function public.svc_wallet_inflow(p_rail text, p_account_ref text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; r public.payment_requests; bl public.bank_lines; v_amt numeric := round(private.num(d->>'amount'), 2); v_at timestamptz;
  v_ref text := coalesce(nullif(d->>'provider_ref', ''), nullif(d->>'reference', ''));
begin
  select * into w from wallets where rail = p_rail and (account_ref = p_account_ref or account_number = p_account_ref) order by (account_ref = p_account_ref) desc limit 1;
  if not found or coalesce(v_amt, 0) = 0 or v_ref is null then return jsonb_build_object('ok', false, 'reason', 'unknown_wallet'); end if;
  v_at := coalesce(nullif(d->>'at', '')::timestamptz, now());
  -- Our own sweep of a checkout payment: the collection already posted it.
  select * into r from payment_requests where wallet_id = w.id and sweep_status in ('sent', 'pending', 'failed')
    and (sweep_ref = d->>'reference' or coalesce(d->>'narration', '') like '%' || tx_ref || '%' or coalesce(d->>'reference', '') like '%' || tx_ref || '%'
         or (round(paid_amount - coalesce(fee, 0), 2) = v_amt and paid_at > v_at - interval '2 days'
             and coalesce(d->'sender'->>'name', '') ~* '(flutterwave|taxstreem|counta)'))
  order by (sweep_ref = d->>'reference') desc nulls last, paid_at limit 1;
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
    provider_ref, fingerprint, status, journal_id, matched_by, confidence)
  values (w.org_id, w.bank_account_id, private.local_day(w.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
    d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref,
    case when r.id is not null then 'matched' else 'unmatched' end, (select journal_id from collections where id = r.collection_id),
    case when r.id is not null then 'system' end, case when r.id is not null then 1 end)
  on conflict do nothing
  returning * into bl;
  if r.id is not null then
    update payment_requests set sweep_status = 'done', swept_at = coalesce(swept_at, v_at) where id = r.id;
  end if;
  -- Everything else goes through the same pipeline as a bank statement line (a customer paying an invoice into the wallet, say).
  if bl.id is not null and bl.status = 'unmatched' then
    if private.match_bank_line(bl.id) is null then
      perform private.notify_perm(w.org_id, 'keep_books', 'bank', 'Money into the wallet: ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
        coalesce(d->'sender'->>'name', 'Unknown sender') || coalesce(' · ' || (d->>'narration'), ''), '/accounting/banking', 'inflow-' || bl.id);
      perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', w.org_id));
    end if;
    select * into bl from bank_lines where id = bl.id;
  end if;
  return jsonb_build_object('ok', true, 'matched', bl.status <> 'unmatched', 'stage', bl.stage, 'bank_line', bl.id);
end $$;

-- The rail's balance for a wallet, compared with the books. Money swept but not yet arrived and payouts still processing
-- are the only acceptable gap.
create or replace function public.svc_wallet_balance(p_wallet uuid, p_available numeric, p_ledger numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; v_books numeric; v_transit numeric; v_diff numeric; rec public.wallet_reconciliations; v_out numeric;
begin
  select * into w from wallets where id = p_wallet for update;
  if not found then raise exception 'Wallet not found.'; end if;
  update wallets set provider_available = p_available, provider_ledger = p_ledger, balance_at = now() where id = w.id;
  v_books := private.wallet_balance(w.id);
  -- Confirmed in the books but not yet in the wallet: sweeps on their way. Left the wallet but not yet in the books: payouts processing.
  -- A sweep the rail accepted more than two days ago and that never arrived is no longer "in transit": it shows as a difference.
  select coalesce(sum(paid_amount - coalesce(fee, 0)), 0) into v_transit from payment_requests where wallet_id = w.id and status = 'paid'
    and (sweep_status in ('pending', 'failed') or (sweep_status = 'sent' and coalesce(swept_at, paid_at) > now() - interval '2 days'));
  select coalesce(sum(amount + fee), 0) into v_out from payouts where wallet_id = w.id and status = 'processing';
  v_diff := round(coalesce(p_ledger, p_available) - (v_books - v_transit - v_out), 2);
  insert into wallet_reconciliations (org_id, wallet_id, provider_balance, books_balance, in_transit, difference, status, details)
  values (w.org_id, w.id, coalesce(p_ledger, p_available), v_books, v_transit + v_out, v_diff, case when abs(v_diff) < 0.01 then 'matched' else 'difference' end,
    jsonb_build_object('available', p_available, 'ledger', p_ledger, 'sweeps_in_transit', v_transit, 'payouts_processing', v_out,
      'unmatched_lines', (select count(*) from bank_lines where bank_account_id = w.bank_account_id and status = 'unmatched')))
  returning * into rec;
  if rec.status = 'difference' then
    update ai_proposals set status = 'superseded' where org_id = w.org_id and kind = 'wallet_difference' and status = 'pending' and proposal->>'wallet_id' = w.id::text;
    insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount)
    values (w.org_id, 'reconciler', 'wallet_difference', 'wallet_reconciliation', rec.id,
      'Wallet differs from the books by ₦' || to_char(abs(v_diff), 'FM999,999,999,990.00'),
      case when v_diff > 0 then 'The wallet holds more than the books show. Is there money in it that was never recorded?'
           else 'The books show more than the wallet holds. Was something paid out or charged that the books do not know about?' end,
      jsonb_build_object('wallet_id', w.id, 'difference', v_diff, 'books', v_books, 'provider', coalesce(p_ledger, p_available), 'in_transit', v_transit + v_out),
      0, 'Nightly wallet reconciliation', 'reconcile', 'pending', abs(v_diff))
    on conflict do nothing;
  end if;
  return to_jsonb(rec);
end $$;

-- Work for the edge function's regular sweep: requests to re-check with the rail, sweeps to retry, payouts to re-check,
-- wallets to reconcile.
create or replace function public.svc_work(p_kind text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if p_kind = 'requests' then
    update payment_requests set status = 'expired' where status = 'pending' and expires_at < now() - interval '30 minutes';
    update payment_requests set status = 'failed', error = coalesce(error, 'The payment rail did not answer.') where status = 'creating' and created_at < now() - interval '10 minutes';
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tx_ref', tx_ref, 'rail', rail, 'org_id', org_id)), '[]'::jsonb) from (
      select id, tx_ref, rail, org_id from payment_requests
      where status = 'pending' and created_at < now() - interval '2 minutes' and created_at > now() - interval '2 days'
        and (checked_at is null or checked_at < now() - interval '4 minutes')
      order by created_at limit 50) x);
  elsif p_kind = 'sweeps' then
    return (select coalesce(jsonb_agg(jsonb_build_object('tx_ref', r.tx_ref, 'amount', r.paid_amount - coalesce(r.fee, 0), 'barter_id', w.barter_id,
        'reference', 'SWP-' || r.tx_ref, 'last_reference', r.sweep_ref, 'status', r.sweep_status)), '[]'::jsonb)
      from payment_requests r join wallets w on w.id = r.wallet_id
      where r.status = 'paid' and r.sweep_status in ('pending', 'failed') and w.barter_id is not null and r.paid_at > now() - interval '30 days');
  elsif p_kind = 'payouts' then
    return (select coalesce(jsonb_agg(jsonb_build_object('reference', p.reference, 'rail', w.rail, 'provider_ref', p.provider_ref)), '[]'::jsonb)
      from payouts p join wallets w on w.id = p.wallet_id where p.status = 'processing' and p.sent_at < now() - interval '5 minutes');
  elsif p_kind = 'wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'rail', w.rail, 'account_ref', w.account_ref, 'org_id', w.org_id)), '[]'::jsonb)
      from wallets w where w.status = 'active');
  end if;
  raise exception 'Unknown work kind.';
end $$;

-- Each webhook or verification is recorded once; a repeat returns false and is not processed again.
create or replace function public.svc_event(p_rail text, p_event text, p_key text, p_payload jsonb) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_id bigint;
begin
  insert into payment_events (rail, event, event_key, payload) values (p_rail, left(p_event, 80), left(p_key, 200), p_payload)
  on conflict (rail, event_key) do nothing returning id into v_id;
  return v_id is not null;
end $$;

create or replace function public.svc_event_done(p_rail text, p_key text, p_outcome text, p_error text default null, p_org uuid default null) returns void
language sql security definer set search_path = public, private as $$
  update public.payment_events set processed_at = now(), outcome = left(p_outcome, 200), error = left(p_error, 1000), org_id = coalesce(p_org, org_id)
  where rail = p_rail and event_key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- 7. Reading and settings
-- ---------------------------------------------------------------------------
create or replace function public.get_payments(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; w public.wallets; v_money boolean;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  v_money := private.can_handle_money(p_org);
  return jsonb_build_object(
    'rail', (select to_jsonb(r) - 'api_key_secret' - 'webhook_secret' from payment_rails r where r.code = o.payment_rail),
    'rails', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'capabilities', capabilities) order by code = 'flutterwave' desc, name), '[]'::jsonb)
              from payment_rails where active),
    'wallet', case when w.id is not null then to_jsonb(w) - 'provider_available' - 'provider_ledger' || jsonb_build_object(
        'books_balance', case when v_money then private.wallet_balance(w.id) end,
        'provider_balance', case when v_money then coalesce(w.provider_ledger, w.provider_available) end,
        'available', case when v_money then private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id
           and status in ('approved', 'processing', 'pending_approval')), 0) end) end,
    'settings', jsonb_build_object('payment_methods', o.payment_methods, 'payout_approval_threshold', o.payout_approval_threshold),
    'requests', (select coalesce(jsonb_agg(private.request_json(r) || jsonb_build_object('created_at', r.created_at, 'customer_name', c.name,
        'created_by_name', (select display_name from members where id = r.created_by), 'sweep_status', case when v_money then r.sweep_status end,
        'fee', case when v_money then r.fee end) order by r.created_at desc), '[]'::jsonb)
      from (select * from payment_requests where org_id = p_org and created_at > now() - interval '60 days' order by created_at desc limit 300) r
      left join customers c on c.id = r.customer_id),
    'payouts', case when v_money then (select coalesce(jsonb_agg(to_jsonb(p) - 'raw' - 'lines' || jsonb_build_object(
        'requested_by_name', (select display_name from members where id = p.requested_by), 'approved_by_name', (select display_name from members where id = p.approved_by),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from payouts where org_id = p_org order by created_at desc limit 300) p) end,
    'reconciliations', case when v_money then (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
      from (select * from wallet_reconciliations where org_id = p_org order by at desc limit 30) x) end,
    'can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'), 'open_wallet', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'settings', m.role = 'owner'));
end $$;

create or replace function public.update_payment_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_methods text[];
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  if p_patch ? 'payment_rail' then
    if not exists (select 1 from payment_rails where code = p_patch->>'payment_rail' and active) then raise exception 'Unknown payment rail.'; end if;
    if exists (select 1 from wallets where org_id = p_org and rail <> p_patch->>'payment_rail' and status = 'active' and private.wallet_balance(id) <> 0) then
      raise exception 'Empty the current wallet before moving to another payment rail.';
    end if;
  end if;
  if jsonb_typeof(p_patch->'payment_methods') = 'array' then
    select array_agg(distinct v) into v_methods from jsonb_array_elements_text(p_patch->'payment_methods') v where v in ('account', 'link', 'qr');
  end if;
  update orgs set payment_rail = coalesce(nullif(p_patch->>'payment_rail', ''), payment_rail),
    payment_methods = coalesce(v_methods, payment_methods),
    payout_approval_threshold = case when p_patch ? 'payout_approval_threshold' then greatest(coalesce(private.num(p_patch->>'payout_approval_threshold'), 0), 0)
                                     else payout_approval_threshold end
  where id = p_org returning * into o;
  return jsonb_build_object('payment_rail', o.payment_rail, 'payment_methods', o.payment_methods, 'payout_approval_threshold', o.payout_approval_threshold);
end $$;

-- Public view of a request on a shared document: is it paid yet?
create or replace function public.public_payment_status(p_token text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('status', s.status, 'balance', s.total - s.amount_paid - s.credited,
    'request', (select private.request_json(r) - 'sale_id' - 'payer' from payment_requests r where r.sale_id = s.id order by r.created_at desc limit 1))
  from sales s where s.public_token = p_token and s.status <> 'draft'
$$;

-- ---------------------------------------------------------------------------
-- 8. Schedules: re-check open requests and sweeps every five minutes; reconcile wallets nightly
-- ---------------------------------------------------------------------------
create or replace function private.payments_tick(p_action text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from wallets where status = 'active') or exists (select 1 from payment_requests where status = 'pending') then
    perform private.call_function('payments', jsonb_build_object('action', p_action));
  end if;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('counta-payments-poll', 'counta-wallet-reconcile');
    perform cron.schedule('counta-payments-poll', '*/5 * * * *', $c$select private.payments_tick('poll')$c$);
    perform cron.schedule('counta-wallet-reconcile', '40 0 * * *', $c$select private.payments_tick('reconcile')$c$);
  end if;
end $$;

grant execute on function public.create_payment_request(uuid, jsonb), public.get_payment_request(uuid), public.cancel_payment_request(uuid),
  public.request_payout(uuid, jsonb), public.approve_payout(uuid, boolean, text), public.cancel_payout(uuid), public.payout_to_send(uuid),
  public.get_payments(uuid), public.update_payment_settings(uuid, jsonb) to authenticated;
revoke execute on function public.create_payment_request(uuid, jsonb), public.get_payment_request(uuid), public.cancel_payment_request(uuid),
  public.request_payout(uuid, jsonb), public.approve_payout(uuid, boolean, text), public.cancel_payout(uuid), public.payout_to_send(uuid),
  public.get_payments(uuid), public.update_payment_settings(uuid, jsonb) from public, anon;
grant execute on function public.public_payment_status(text) to anon, authenticated;
revoke execute on function public.svc_rail(text), public.svc_secret(text), public.svc_wallet_to_open(uuid, uuid), public.svc_wallet_ready(uuid, jsonb),
  public.svc_public_request(text, text), public.svc_request_context(uuid), public.svc_request_update(uuid, jsonb), public.svc_payment_confirmed(text, jsonb),
  public.svc_sweep_update(text, text, text, text), public.svc_payout_update(text, jsonb), public.svc_wallet_inflow(text, text, jsonb),
  public.svc_wallet_balance(uuid, numeric, numeric), public.svc_work(text), public.svc_event(text, text, text, jsonb), public.svc_event_done(text, text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_rail(text), public.svc_secret(text), public.svc_wallet_to_open(uuid, uuid), public.svc_wallet_ready(uuid, jsonb),
  public.svc_public_request(text, text), public.svc_request_context(uuid), public.svc_request_update(uuid, jsonb), public.svc_payment_confirmed(text, jsonb),
  public.svc_sweep_update(text, text, text, text), public.svc_payout_update(text, jsonb), public.svc_wallet_inflow(text, text, jsonb),
  public.svc_wallet_balance(uuid, numeric, numeric), public.svc_work(text), public.svc_event(text, text, text, jsonb), public.svc_event_done(text, text, text, text, uuid)
  to service_role;
revoke execute on function private.can_handle_money(uuid), private.request_json(public.payment_requests), private.request_context(uuid),
  private.open_request(uuid, uuid, uuid, text, numeric, public.members, boolean, uuid), private.wallet_balance(uuid),
  private.create_payout(uuid, jsonb, jsonb, public.members), private.post_payout(uuid), private.payments_tick(text) from public, anon, authenticated;
