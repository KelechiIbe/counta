-- Counta, 27 October 2026: sale transfers into the business's own wallet number, a tax wallet for each business, VAT from
-- uploaded sales schedules and purchase invoices, a count on every menu item with alerts by the channel each deserves, and
-- payments matched to invoices and bills for a person to confirm.
--
-- 1. A customer paying a sale by transfer is shown the business's own wallet number (in the business's name) instead of a
--    one-off account on TaxStreem's Flutterwave account, and the transfer is matched to the sale when it reaches the wallet.
-- 2. Each business gets a tax wallet next to its business wallet. The VAT on money received and the WHT kept back from
--    suppliers move into it automatically; it pays only tax; what was set aside beyond the tax due goes back once paid.
-- 3. Sales schedules from other POS systems, purchase invoices showing VAT, and money received without a Counta invoice all
--    feed the VAT return.
-- 4. Every menu item with work waiting shows a count; tax deadlines, invoices due and transactions to confirm before the
--    returns are sent by push, email and WhatsApp as they deserve, and Martina calls the day before a return is due and,
--    when a business asks for it, follows up customers' overdue invoices.
-- 5. Bank lines and schedule lines that look like payments of open invoices and bills (by name, reference, goods and
--    amount, including the amount less WHT or bank charges) are put to a person to confirm.

-- ---------------------------------------------------------------------------
-- 1. Transfers for a sale go to the business's own wallet number
-- ---------------------------------------------------------------------------
-- On Flutterwave a "pay by transfer" request used to get a one-off account on TaxStreem's own Flutterwave account: the payer
-- saw TaxStreem's name and the money waited in TaxStreem's balance for a sweep into the business's wallet. Now the payer
-- is shown the business's own wallet number (opened in the business's name), and the transfer is matched to the sale
-- waiting for it when it reaches the wallet: by the sale's number in the narration first, else by the amount. Card, USSD
-- and QR still go through Flutterwave checkout and are swept as before. The rail's capability 'direct_account' switches
-- this on (TaxStreem can take it off a rail to go back to one-off accounts).
alter table public.payment_requests add column if not exists direct boolean not null default false;
alter table public.payment_requests add column if not exists pay_ref text;
create index if not exists payment_requests_direct on public.payment_requests(wallet_id, amount) where direct;
update public.payment_rails set capabilities = capabilities || array['direct_account']
where code = 'flutterwave' and not ('direct_account' = any(capabilities));

-- ---------------------------------------------------------------------------
-- 2. The tax wallet: a second account number for each business, for tax only
-- ---------------------------------------------------------------------------
-- Opened next to the business wallet at the same rail (a second payout subaccount on Flutterwave). The VAT on every
-- payment that reaches the business wallet, and the WHT and withholding VAT kept back when a supplier is paid from it,
-- move into the tax wallet automatically. Money leaves it only to pay tax: to an account TaxStreem lists for that tax,
-- with the tax payment reference. Once a month's VAT is paid, whatever was set aside for that month beyond what was due
-- (input VAT credit) goes back to the business wallet.
create table if not exists public.tax_wallets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique references public.orgs(id) on delete cascade,
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
  created_at timestamptz not null default now()
);
create unique index if not exists tax_wallets_ref on public.tax_wallets(rail, account_ref) where account_ref is not null;
create index if not exists tax_wallets_bank_fk on public.tax_wallets(bank_account_id);
create index if not exists tax_wallets_created_by_fk on public.tax_wallets(created_by);

-- One transfer between the two wallets carries every move waiting at that moment, so a busy till does not send a transfer
-- per sale. direction 'in': business wallet to tax wallet; 'out': back to the business wallet.
create table if not exists public.tax_transfers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  tax_wallet_id uuid not null references public.tax_wallets(id) on delete cascade,
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  amount numeric(16,2) not null check (amount > 0),
  reference text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sent', 'done', 'failed', 'cancelled')),
  attempts int not null default 0,
  next_try_at timestamptz,
  provider_ref text,
  error text,
  journal_id uuid references public.journals(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  done_at timestamptz
);
create index if not exists tax_transfers_org on public.tax_transfers(org_id, created_at desc);
create index if not exists tax_transfers_open on public.tax_transfers(status) where status in ('pending', 'failed');
create index if not exists tax_transfers_tax_wallet_fk on public.tax_transfers(tax_wallet_id);
create index if not exists tax_transfers_wallet_fk on public.tax_transfers(wallet_id);
create index if not exists tax_transfers_journal_fk on public.tax_transfers(journal_id);

-- Each amount owed to (or released from) the tax wallet, with what it came from. Idempotent on its source.
create table if not exists public.tax_moves (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  tax_wallet_id uuid not null references public.tax_wallets(id) on delete cascade,
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  kind text not null check (kind in ('vat', 'wht', 'release')),
  amount numeric(16,2) not null check (amount > 0),
  period date,
  source_type text not null check (source_type in ('allocation', 'bill_payment', 'release', 'sale')),
  source_id uuid not null,
  description text,
  status text not null default 'pending' check (status in ('pending', 'sending', 'done', 'cancelled')),
  transfer_id uuid references public.tax_transfers(id) on delete set null,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  unique (source_type, source_id, kind)
);
create index if not exists tax_moves_org on public.tax_moves(org_id, created_at desc);
create index if not exists tax_moves_pending on public.tax_moves(org_id) where status in ('pending', 'sending');
create index if not exists tax_moves_tax_wallet_fk on public.tax_moves(tax_wallet_id);
create index if not exists tax_moves_wallet_fk on public.tax_moves(wallet_id);
create index if not exists tax_moves_transfer_fk on public.tax_moves(transfer_id);

-- Where tax may be paid from the tax wallet, as TaxStreem sets it in the admin portal.
create table if not exists public.tax_payees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kinds text[] not null default '{vat}' check (kinds <@ array['vat', 'wht', 'wvat']::text[] and cardinality(kinds) > 0),
  authority text references public.tax_authorities(code),
  bank_code text not null,
  bank_name text,
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null,
  note text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists tax_payees_authority_fk on public.tax_payees(authority);
create index if not exists tax_payees_created_by_fk on public.tax_payees(created_by);

create table if not exists public.tax_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  tax_wallet_id uuid not null references public.tax_wallets(id) on delete cascade,
  payee_id uuid references public.tax_payees(id) on delete set null,
  kind text not null check (kind in ('vat', 'wht', 'wvat')),
  authority text references public.tax_authorities(code),
  period date not null,
  amount numeric(16,2) not null check (amount > 0),
  tax_reference text not null,
  reference text not null unique,
  bank_code text not null,
  account_number text not null,
  account_name text not null,
  status text not null default 'approved' check (status in ('approved', 'processing', 'successful', 'failed')),
  provider_ref text,
  fee numeric(16,2) not null default 0,
  error text,
  journal_id uuid references public.journals(id) on delete set null,
  requested_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  completed_at timestamptz
);
create index if not exists tax_payments_org on public.tax_payments(org_id, created_at desc);
create index if not exists tax_payments_tax_wallet_fk on public.tax_payments(tax_wallet_id);
create index if not exists tax_payments_payee_fk on public.tax_payments(payee_id);
create index if not exists tax_payments_authority_fk on public.tax_payments(authority);
create index if not exists tax_payments_journal_fk on public.tax_payments(journal_id);
create index if not exists tax_payments_requested_by_fk on public.tax_payments(requested_by);
create index if not exists tax_payments_open on public.tax_payments(status) where status = 'processing';

alter table public.tax_wallets enable row level security;
alter table public.tax_transfers enable row level security;
alter table public.tax_moves enable row level security;
alter table public.tax_payees enable row level security;
alter table public.tax_payments enable row level security;
drop policy if exists tax_wallets_read on public.tax_wallets;
create policy tax_wallets_read on public.tax_wallets for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists tax_transfers_read on public.tax_transfers;
create policy tax_transfers_read on public.tax_transfers for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists tax_moves_read on public.tax_moves;
create policy tax_moves_read on public.tax_moves for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists tax_payments_read on public.tax_payments;
create policy tax_payments_read on public.tax_payments for select to authenticated using ((select private.can_handle_money(org_id)));
revoke all on public.tax_payees from anon, authenticated;
revoke insert, update, delete on public.tax_wallets, public.tax_transfers, public.tax_moves, public.tax_payments from anon, authenticated;
-- Read through the policies above (Supabase grants new tables to these roles by default; said here so it does not depend on that).
revoke all on public.tax_wallets, public.tax_transfers, public.tax_moves, public.tax_payments from anon;
grant select on public.tax_wallets, public.tax_transfers, public.tax_moves, public.tax_payments to authenticated;

-- The business wallet's balance in the books, and what of it may be spent: the tax waiting to move to the tax wallet is not.
create or replace function private.wallet_ledger(p_wallet uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join bank_accounts b on b.ledger_code = l.account_code and b.org_id = l.org_id
  join wallets w on w.bank_account_id = b.id where w.id = p_wallet
$$;
create or replace function private.wallet_balance(p_wallet uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select private.wallet_ledger(p_wallet) - coalesce((select sum(amount) from tax_moves where wallet_id = p_wallet and direction = 'in' and status in ('pending', 'sending')), 0)
$$;
create or replace function private.tax_wallet_ledger(p_tax_wallet uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join bank_accounts b on b.ledger_code = l.account_code and b.org_id = l.org_id
  join tax_wallets t on t.bank_account_id = b.id where t.id = p_tax_wallet
$$;
-- What the tax wallet can pay: its balance less tax payments under way and money on its way back to the business wallet.
create or replace function private.tax_wallet_spendable(p_tax_wallet uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select private.tax_wallet_ledger(p_tax_wallet)
    - coalesce((select sum(amount + fee) from tax_payments where tax_wallet_id = p_tax_wallet and status in ('approved', 'processing')), 0)
    - coalesce((select sum(amount) from tax_moves where tax_wallet_id = p_tax_wallet and direction = 'out' and status in ('pending', 'sending')), 0)
$$;

-- Opening the tax wallet (the payments edge function opens it at the rail right after, or alongside, the business wallet).
create or replace function public.svc_tax_wallet_to_open(p_org uuid, p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; t public.tax_wallets; pr public.payment_rails; m public.members;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if m.id is null or not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or m.role = 'owner') then
    raise exception 'Only the owner or someone who keeps the books opens the tax wallet.';
  end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet first.'; end if;
  select * into pr from payment_rails where code = w.rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  select * into t from tax_wallets where org_id = p_org;
  if found and t.status = 'active' then return jsonb_build_object('tax_wallet', to_jsonb(t), 'ready', true); end if;
  if not found then
    insert into tax_wallets (org_id, rail, status, created_by) values (p_org, w.rail, 'creating', m.id) returning * into t;
  else
    update tax_wallets set status = 'creating', error = null, rail = w.rail where id = t.id returning * into t;
  end if;
  return jsonb_build_object('tax_wallet', to_jsonb(t), 'ready', false, 'rail', to_jsonb(pr) - 'api_key_secret' - 'webhook_secret',
    'org', jsonb_build_object('name', o.name || ' Tax', 'email', o.email, 'phone', o.phone, 'id', o.id, 'purpose', 'tax'));
end $$;

create or replace function public.svc_tax_wallet_ready(p_wallet uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.tax_wallets; b public.bank_accounts;
begin
  select * into t from tax_wallets where id = p_wallet for update;
  if not found then raise exception 'Tax wallet not found.'; end if;
  if nullif(d->>'error', '') is not null then
    update tax_wallets set status = 'failed', error = left(d->>'error', 500) where id = t.id returning * into t;
    return to_jsonb(t);
  end if;
  if t.bank_account_id is null then
    b := private.open_bank_account(t.org_id, 'wallet', 'Tax wallet · ' || coalesce(right(d->>'account_number', 4), ''),
      jsonb_build_object('provider', case when t.rail = 'flutterwave' then 'flutterwave' else 'rail' end, 'provider_ref', d->>'account_ref',
        'account_number', d->>'account_number', 'bank_name', d->>'bank_name', 'account_name', d->>'account_name', 'is_collection', false,
        'provider_meta', jsonb_build_object('rail', t.rail, 'barter_id', d->>'barter_id', 'tax_wallet', true)), t.created_by);
  end if;
  update tax_wallets set status = 'active', error = null, account_ref = d->>'account_ref', barter_id = nullif(d->>'barter_id', ''),
    account_number = d->>'account_number', bank_name = d->>'bank_name', account_name = d->>'account_name', bank_account_id = coalesce(bank_account_id, b.id)
  where id = t.id returning * into t;
  return to_jsonb(t);
end $$;

-- The VAT in money that reached the business wallet: each allocation of a confirmed collection into the wallet carries
-- the share of its sale that is VAT. Queued once per allocation; nothing moves for a business without a tax wallet.
-- An allocation has no id of its own (it is a collection and a sale): its key for tax_moves is made from the two.
create or replace function private.alloc_key(p_collection uuid, p_sale uuid) returns uuid
language sql immutable set search_path = public, private as $$
  select md5('alloc:' || p_collection::text || ':' || p_sale::text)::uuid
$$;

create or replace function private.queue_vat_moves(p_collection uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; w public.wallets; t public.tax_wallets; a record; v_vat numeric; v_n int := 0;
begin
  select * into c from collections where id = p_collection;
  if c.id is null or c.status <> 'confirmed' or c.journal_id is null or c.direction <> 'in' or c.bank_account_id is null
     or c.method in ('wht_credit', 'wvat_credit', 'advance') then return 0; end if;
  select * into w from wallets where bank_account_id = c.bank_account_id and status = 'active';
  if w.id is null then return 0; end if;
  select * into t from tax_wallets where org_id = c.org_id and status = 'active';
  if t.id is null then return 0; end if;
  for a in select private.alloc_key(ca.collection_id, ca.sale_id) id, ca.amount, s.id sale_id, s.number, s.total, s.vat_total, s.issue_date from collection_allocations ca join sales s on s.id = ca.sale_id
           where ca.collection_id = c.id and s.vat_total > 0 and s.total > 0 loop
    v_vat := round(a.amount * a.vat_total / a.total, 2);
    continue when v_vat <= 0;
    insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
    values (c.org_id, t.id, w.id, 'in', 'vat', v_vat, date_trunc('month', a.issue_date)::date, 'allocation', a.id, 'VAT on ' || a.number)
    on conflict (source_type, source_id, kind) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

-- VAT on a sale posted straight from a wallet line (money paid to the business's number with no request or invoice).
create or replace function private.queue_sale_vat_move(p_sale uuid, p_bank uuid) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; w public.wallets; t public.tax_wallets;
begin
  select * into s from sales where id = p_sale;
  if s.id is null or coalesce(s.vat_total, 0) <= 0 then return false; end if;
  select * into w from wallets where bank_account_id = p_bank and status = 'active';
  if w.id is null then return false; end if;
  select * into t from tax_wallets where org_id = s.org_id and status = 'active';
  if t.id is null then return false; end if;
  insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
  values (s.org_id, t.id, w.id, 'in', 'vat', s.vat_total, date_trunc('month', s.issue_date)::date, 'sale', s.id, 'VAT on ' || s.number)
  on conflict (source_type, source_id, kind) do nothing;
  return found;
end $$;

create or replace function private.collections_tax_moves() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'confirmed' and new.journal_id is not null and (tg_op = 'INSERT' or old.status is distinct from new.status or old.journal_id is distinct from new.journal_id) then
    perform private.queue_vat_moves(new.id);
  elsif new.status in ('rejected', 'reversed') and tg_op = 'UPDATE' and old.status = 'confirmed' then
    -- Taken back before it moved: nothing to set aside.
    update tax_moves set status = 'cancelled' where source_type = 'allocation' and status = 'pending'
      and source_id in (select private.alloc_key(collection_id, sale_id) from collection_allocations where collection_id = new.id);
  end if;
  return null;
end $$;
drop trigger if exists collections_tax_moves on public.collections;
create trigger collections_tax_moves after insert or update of status, journal_id on public.collections
  for each row execute function private.collections_tax_moves();

-- Allocations made after the collection posted (a customer's payment spread over invoices later).
create or replace function private.allocations_tax_moves() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from collections where id = new.collection_id and status = 'confirmed' and journal_id is not null) then
    perform private.queue_vat_moves(new.collection_id);
  end if;
  return null;
end $$;
drop trigger if exists allocations_tax_moves on public.collection_allocations;
create trigger allocations_tax_moves after insert on public.collection_allocations
  for each row execute function private.allocations_tax_moves();

-- WHT and withholding VAT kept back when a supplier is paid from the business wallet.
create or replace function private.bill_payments_tax_moves() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; t public.tax_wallets; v_amt numeric := round(coalesce(new.wht, 0) + coalesce(new.wvat, 0), 2); v_number text;
begin
  if new.status <> 'paid' or v_amt <= 0 or (new.bank_account_id is null and new.payout_id is null) then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
  -- Paid from the wallet: a payout from it, or (recorded by hand) the wallet's own bank account.
  select * into w from wallets where status = 'active'
    and (id = (select wallet_id from payouts where id = new.payout_id) or (new.bank_account_id is not null and bank_account_id = new.bank_account_id))
  limit 1;
  if w.id is null then return null; end if;
  select * into t from tax_wallets where org_id = new.org_id and status = 'active';
  if t.id is null then return null; end if;
  select number into v_number from bills where id = new.bill_id;
  insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
  values (new.org_id, t.id, w.id, 'in', 'wht', v_amt, date_trunc('month', private.local_day(new.org_id, new.paid_at))::date, 'bill_payment', new.id,
    'WHT kept back on ' || coalesce(v_number, 'a bill'))
  on conflict (source_type, source_id, kind) do nothing;
  return null;
end $$;
drop trigger if exists bill_payments_tax_moves on public.bill_payments;
create trigger bill_payments_tax_moves after insert or update of status on public.bill_payments
  for each row execute function private.bill_payments_tax_moves();

-- What the tax wallet must keep: the VAT set aside for months not yet paid, and the WHT set aside for deductions not yet
-- paid over. Anything above that (input VAT credit, or tax paid from another account) goes back to the business wallet.
create or replace function private.vault_reserve(p_org uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce((select sum(mv.amount) from tax_moves mv
                   where mv.org_id = p_org and mv.kind = 'vat' and mv.status = 'done'
                     and not exists (select 1 from vat_periods vp where vp.org_id = p_org and vp.period = mv.period and vp.status = 'paid')), 0)
       + coalesce((select sum(mv.amount) from tax_moves mv
                   where mv.org_id = p_org and mv.kind = 'wht' and mv.status = 'done'
                     and exists (select 1 from wht_deductions d where d.bill_payment_id = mv.source_id and d.status in ('pending', 'deducted'))), 0)
$$;

create or replace function private.vault_release(p_org uuid) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare t public.tax_wallets; w public.wallets; v_excess numeric;
begin
  select * into t from tax_wallets where org_id = p_org and status = 'active';
  if t.id is null then return 0; end if;
  select * into w from wallets where org_id = p_org and rail = t.rail and status = 'active';
  if w.id is null then return 0; end if;
  v_excess := round(private.tax_wallet_spendable(t.id) - private.vault_reserve(p_org), 2);
  if v_excess < 1 then return 0; end if;
  insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
  values (p_org, t.id, w.id, 'out', 'release', v_excess, null, 'release', gen_random_uuid(),
    'Set aside beyond the tax that was due, back to the business wallet');
  return v_excess;
end $$;

create or replace function private.vat_periods_release() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then perform private.vault_release(new.org_id); end if;
  return null;
end $$;
drop trigger if exists vat_periods_release on public.vat_periods;
create trigger vat_periods_release after insert or update of status on public.vat_periods for each row execute function private.vat_periods_release();

-- Deductions paid over (from the tax wallet or any other account): the WHT set aside for them is no longer needed.
create or replace function private.wht_remittances_release() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid;
begin
  for v_org in select distinct n.org_id from new_rows n join old_rows o on o.id = n.id where n.status = 'remitted' and o.status is distinct from 'remitted' loop
    perform private.vault_release(v_org);
  end loop;
  return null;
end $$;
drop trigger if exists wht_remittances_release on public.wht_remittances;
drop trigger if exists wht_deductions_release on public.wht_deductions;
create trigger wht_deductions_release after update on public.wht_deductions referencing old table as old_rows new table as new_rows
  for each statement execute function private.wht_remittances_release();

-- Gathers the moves waiting into one transfer each way, and lists the transfers to send now.
create or replace function private.tax_transfers_due() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare g record; tr public.tax_transfers;
begin
  for g in select mv.org_id, mv.tax_wallet_id, mv.wallet_id, mv.direction, sum(mv.amount) total
           from tax_moves mv join tax_wallets t on t.id = mv.tax_wallet_id and t.status = 'active' join wallets w on w.id = mv.wallet_id and w.status = 'active'
           where mv.status = 'pending' and mv.transfer_id is null
             -- one transfer each way at a time per business
             and not exists (select 1 from tax_transfers x where x.tax_wallet_id = mv.tax_wallet_id and x.direction = mv.direction and x.status in ('pending', 'failed'))
           group by mv.org_id, mv.tax_wallet_id, mv.wallet_id, mv.direction loop
    continue when g.total < 0.01;
    insert into tax_transfers (org_id, tax_wallet_id, wallet_id, direction, amount, reference)
    values (g.org_id, g.tax_wallet_id, g.wallet_id, g.direction, round(g.total, 2),
      'TAXB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)))
    returning * into tr;
    update tax_moves set transfer_id = tr.id, status = 'sending'
    where tax_wallet_id = g.tax_wallet_id and wallet_id = g.wallet_id and direction = g.direction and status = 'pending' and transfer_id is null;
  end loop;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'org_id', x.org_id, 'reference', x.reference, 'direction', x.direction, 'amount', x.amount,
      'rail', t.rail, 'attempts', x.attempts, 'last_reference', x.provider_ref,
      'from_ref', case when x.direction = 'in' then w.account_ref else t.account_ref end,
      'to_barter', case when x.direction = 'in' then t.barter_id else w.barter_id end,
      'to_account_ref', case when x.direction = 'in' then t.account_ref else w.account_ref end) order by x.created_at), '[]'::jsonb)
    from tax_transfers x join tax_wallets t on t.id = x.tax_wallet_id join wallets w on w.id = x.wallet_id
    where x.status in ('pending', 'failed') and x.attempts < 30 and (x.next_try_at is null or x.next_try_at <= now()));
end $$;

-- What the rail said about a transfer between the two wallets. 'sent': it accepted it, and the books move the money at once;
-- 'failed': refused (a later webhook may also say so after 'sent'); 'waiting': not tried (transfers are not switched on).
create or replace function public.svc_tax_transfer_update(p_reference text, p_status text, p_error text default null, p_provider_ref text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare tr public.tax_transfers; t public.tax_wallets; w public.wallets; tb public.bank_accounts; wb public.bank_accounts; j public.journals; v_owner public.members;
begin
  select * into tr from tax_transfers where reference = p_reference or (p_reference like reference || '-%') for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  select * into t from tax_wallets where id = tr.tax_wallet_id;
  select * into w from wallets where id = tr.wallet_id;
  select * into tb from bank_accounts where id = t.bank_account_id;
  select * into wb from bank_accounts where id = w.bank_account_id;
  if p_status = 'sent' then
    if tr.status in ('sent', 'done') then return jsonb_build_object('ok', true, 'duplicate', true); end if;
    select * into v_owner from members where org_id = tr.org_id and role = 'owner' and status = 'active' order by created_at limit 1;
    if tr.journal_id is null then
      j := private.post_entry(tr.org_id, case when tr.direction = 'in' then 'Tax set aside in the tax wallet' else 'Back from the tax wallet: set aside beyond the tax due' end,
        'tax_wallet', tr.id, v_owner.id, null,
        case when tr.direction = 'in' then jsonb_build_array(
            jsonb_build_object('code', tb.ledger_code, 'debit', tr.amount, 'memo', tr.reference),
            jsonb_build_object('code', wb.ledger_code, 'credit', tr.amount, 'memo', tr.reference))
          else jsonb_build_array(
            jsonb_build_object('code', wb.ledger_code, 'debit', tr.amount, 'memo', tr.reference),
            jsonb_build_object('code', tb.ledger_code, 'credit', tr.amount, 'memo', tr.reference)) end,
        now(), jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_transfer', 'id', tr.id, 'ref', tr.reference))));
    end if;
    update tax_transfers set status = 'sent', sent_at = coalesce(sent_at, now()), error = null, journal_id = coalesce(journal_id, j.id),
      provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref) where id = tr.id returning * into tr;
    update tax_moves set status = 'done', done_at = now() where transfer_id = tr.id and status = 'sending';
  elsif p_status = 'done' then
    update tax_transfers set status = 'done', done_at = coalesce(done_at, now()) where id = tr.id and status = 'sent';
  elsif p_status = 'failed' then
    -- Refused after the books moved it: the entry is taken back and the moves wait for the next try.
    if tr.journal_id is not null then
      perform private.reverse_entry(tr.journal_id, null, 'Transfer between the wallets failed: ' || coalesce(p_error, ''), null);
      update tax_moves set status = 'sending', done_at = null where transfer_id = tr.id;
    end if;
    update tax_transfers set status = 'failed', journal_id = null, attempts = attempts + 1, error = left(coalesce(p_error, 'The transfer failed.'), 500),
      next_try_at = now() + least(interval '10 minutes' * (attempts + 1), interval '6 hours'),
      provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref) where id = tr.id returning * into tr;
  elsif p_status = 'waiting' then
    update tax_transfers set error = left(coalesce(p_error, 'Waiting for transfers to be switched on.'), 500), next_try_at = now() + interval '30 minutes'
    where id = tr.id returning * into tr;
  else
    raise exception 'Unknown status.';
  end if;
  return jsonb_build_object('ok', true, 'status', tr.status, 'reference', tr.reference);
end $$;

-- The tax wallet's balance at the rail, for the Payments page.
create or replace function public.svc_tax_wallet_balance(p_wallet uuid, p_available numeric, p_ledger numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.tax_wallets; v_books numeric; v_transit numeric;
begin
  update tax_wallets set provider_available = p_available, provider_ledger = p_ledger, balance_at = now() where id = p_wallet returning * into t;
  if not found then raise exception 'Tax wallet not found.'; end if;
  v_books := private.tax_wallet_ledger(t.id);
  select coalesce(sum(amount + fee), 0) into v_transit from tax_payments where tax_wallet_id = t.id and status = 'processing';
  return jsonb_build_object('books', v_books, 'provider', coalesce(p_ledger, p_available), 'difference', round(coalesce(p_ledger, p_available) - (v_books - v_transit), 2));
end $$;

-- ---------------------------------------------------------------------------
-- Paying tax from the tax wallet
-- ---------------------------------------------------------------------------
create or replace function public.admin_tax_payees() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return (select coalesce(jsonb_agg(to_jsonb(p) order by p.active desc, p.name), '[]'::jsonb) from tax_payees p);
end $$;

-- p: {id?, name, kinds[], authority, bank_code, bank_name, account_number, account_name, note, active}
create or replace function public.admin_save_tax_payee(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_kinds text[]; x public.tax_payees; v_old jsonb;
begin
  perform private.require_staff();
  v_kinds := array(select jsonb_array_elements_text(coalesce(p->'kinds', '["vat"]'::jsonb)));
  if cardinality(v_kinds) = 0 or not (v_kinds <@ array['vat', 'wht', 'wvat']::text[]) then raise exception 'Choose which taxes this account takes: VAT, WHT or withholding VAT.'; end if;
  if nullif(trim(p->>'name'), '') is null then raise exception 'Name the account.'; end if;
  if coalesce(p->>'account_number', '') !~ '^[0-9]{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if coalesce(p->>'bank_code', '') !~ '^[0-9A-Za-z]{3,10}$' then raise exception 'Choose the bank.'; end if;
  if nullif(trim(p->>'account_name'), '') is null then raise exception 'Check the account name with the bank first.'; end if;
  if nullif(p->>'authority', '') is not null and not exists (select 1 from tax_authorities where code = p->>'authority') then raise exception 'Unknown tax authority.'; end if;
  if ('wht' = any(v_kinds)) and nullif(p->>'authority', '') is null then raise exception 'Say which tax authority this WHT account belongs to.'; end if;
  if v_id is null then
    insert into tax_payees (name, kinds, authority, bank_code, bank_name, account_number, account_name, note, active, created_by)
    values (left(trim(p->>'name'), 120), v_kinds, nullif(p->>'authority', ''), p->>'bank_code', nullif(trim(p->>'bank_name'), ''), p->>'account_number',
      left(trim(p->>'account_name'), 120), nullif(left(trim(coalesce(p->>'note', '')), 300), ''), coalesce((p->>'active')::boolean, true), auth.uid())
    returning * into x;
  else
    select to_jsonb(t) into v_old from tax_payees t where id = v_id;
    if v_old is null then raise exception 'Not found.'; end if;
    update tax_payees set name = left(trim(p->>'name'), 120), kinds = v_kinds, authority = nullif(p->>'authority', ''), bank_code = p->>'bank_code',
      bank_name = nullif(trim(p->>'bank_name'), ''), account_number = p->>'account_number', account_name = left(trim(p->>'account_name'), 120),
      note = nullif(left(trim(coalesce(p->>'note', '')), 300), ''), active = coalesce((p->>'active')::boolean, active), updated_at = now()
    where id = v_id returning * into x;
  end if;
  perform private.audit('save_tax_payee', x.id::text, jsonb_build_object('from', v_old, 'to', to_jsonb(x)));
  return to_jsonb(x);
end $$;

-- A business asks to pay a month's VAT, or a month's WHT for one authority, from its tax wallet.
-- p: {kind 'vat'|'wht'|'wvat', period, authority (WHT), payee_id, tax_reference}
create or replace function public.request_tax_payment(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; t public.tax_wallets; py public.tax_payees; v_kind text := coalesce(nullif(p->>'kind', ''), 'vat'); v_period date;
  v_auth text := nullif(p->>'authority', ''); v_amt numeric; vp public.vat_periods; v_ref text := nullif(trim(p->>'tax_reference'), ''); x public.tax_payments;
begin
  m := private.require(p_org, 'make_payments');
  if not (m.role = 'owner' or private.perm_of(m, 'approve_payments')) then
    raise exception 'Tax payments from the tax wallet need someone who approves payments.' using errcode = '42501';
  end if;
  perform private.require_payments_open(p_org);
  select * into t from tax_wallets where org_id = p_org and status = 'active';
  if not found then raise exception 'Open the tax wallet first.'; end if;
  if v_kind not in ('vat', 'wht', 'wvat') then raise exception 'Pay VAT, WHT or withholding VAT from the tax wallet.'; end if;
  v_period := date_trunc('month', nullif(p->>'period', '')::date)::date;
  if v_period is null then raise exception 'Choose the month.'; end if;
  if v_ref is null or length(v_ref) > 60 then raise exception 'Enter the payment reference the tax authority gave for this payment.'; end if;
  select * into py from tax_payees where id = nullif(p->>'payee_id', '')::uuid and active;
  if not found or not (v_kind = any(py.kinds)) then raise exception 'Choose an account TaxStreem lists for this tax.'; end if;
  if v_kind = 'vat' then
    select * into vp from vat_periods where org_id = p_org and period = v_period;
    if not found then raise exception 'File the % VAT return first.', to_char(v_period, 'FMMonth YYYY'); end if;
    if vp.status = 'paid' then raise exception 'The % VAT is already paid.', to_char(v_period, 'FMMonth YYYY'); end if;
    v_amt := vp.payable;
    v_auth := 'NRS';
  else
    if v_kind = 'wvat' then v_auth := 'NRS'; end if;
    if v_auth is null then raise exception 'Choose who the WHT is paid to.'; end if;
    if py.authority is not null and py.authority <> v_auth then raise exception 'That account is for %, not %.', py.authority, v_auth; end if;
    select coalesce(sum(amount), 0) into v_amt from wht_deductions where org_id = p_org and authority = v_auth and period = v_period and status = 'deducted'
      and (kind = 'wht') = (v_kind = 'wht');
  end if;
  if coalesce(v_amt, 0) <= 0 then raise exception 'Nothing is due for % in %.', upper(v_kind), to_char(v_period, 'FMMonth YYYY'); end if;
  if exists (select 1 from tax_payments where org_id = p_org and kind = v_kind and period = v_period and authority is not distinct from v_auth
             and status in ('approved', 'processing', 'successful')) then
    raise exception 'A payment for this is already on its way or made.';
  end if;
  if v_amt > private.tax_wallet_spendable(t.id) + 0.004 then
    raise exception 'The tax wallet holds % that can be paid out; % is due. Top it up from the business wallet or a bank.',
      private.naira(private.tax_wallet_spendable(t.id)), private.naira(v_amt);
  end if;
  insert into tax_payments (org_id, tax_wallet_id, payee_id, kind, authority, period, amount, tax_reference, reference, bank_code, account_number, account_name, requested_by)
  values (p_org, t.id, py.id, v_kind, v_auth, v_period, v_amt, v_ref, 'CNTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    py.bank_code, py.account_number, py.account_name, m.id)
  returning * into x;
  return to_jsonb(x);
end $$;

create or replace function public.tax_payment_to_send(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.tax_payments; m public.members; t public.tax_wallets;
begin
  select * into x from tax_payments where id = p_payment for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(x.org_id, 'make_payments');
  if x.status <> 'approved' then raise exception 'This payment is already %.', x.status; end if;
  select * into t from tax_wallets where id = x.tax_wallet_id and status = 'active';
  if not found then raise exception 'The tax wallet is not open.'; end if;
  update tax_payments set status = 'processing', sent_at = now() where id = x.id returning * into x;
  return jsonb_build_object('payment', jsonb_build_object('reference', x.reference, 'amount', x.amount, 'bank_code', x.bank_code, 'account_number', x.account_number,
      'account_name', x.account_name, 'narration', upper(x.kind) || ' ' || to_char(x.period, 'Mon YYYY') || ' ' || x.tax_reference),
    'rail', t.rail, 'tax_wallet', jsonb_build_object('account_ref', t.account_ref));
end $$;

-- d: {status: 'successful'|'failed'|'processing', provider_ref, fee, error}
create or replace function public.svc_tax_payment_update(p_reference text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.tax_payments; t public.tax_wallets; tb public.bank_accounts; j public.journals; v_status text := lower(coalesce(d->>'status', '')); m public.members;
  rm public.wht_remittances; v_fee numeric;
begin
  select * into x from tax_payments where reference = p_reference for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if x.status in ('successful', 'failed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', x.status); end if;
  select * into t from tax_wallets where id = x.tax_wallet_id;
  select * into tb from bank_accounts where id = t.bank_account_id;
  select * into m from members where id = x.requested_by;
  if v_status in ('successful', 'success', 'completed') then
    v_fee := round(greatest(coalesce(private.num(d->>'fee'), 0), 0), 2);
    j := private.post_entry(x.org_id, case x.kind when 'vat' then 'VAT' when 'wht' then 'WHT' else 'Withholding VAT' end || ' paid from the tax wallet for '
        || to_char(x.period, 'FMMonth YYYY'), 'tax_payment', x.id, m.id, m.id,
      jsonb_build_array(
        jsonb_build_object('code', private.acct(x.org_id, case x.kind when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
          'debit', x.amount, 'memo', x.tax_reference),
        jsonb_build_object('code', '6701', 'debit', v_fee, 'memo', 'Transfer fee'),
        jsonb_build_object('code', tb.ledger_code, 'credit', x.amount + v_fee, 'memo', x.tax_reference || ' · ' || x.account_name)),
      now(), jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', x.tax_reference, 'authority', x.authority, 'by', m.display_name))));
    update tax_payments set status = 'successful', completed_at = now(), fee = v_fee, journal_id = j.id, provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), error = null
    where id = x.id returning * into x;
    if x.kind = 'vat' then
      update vat_periods set status = 'paid', paid_at = now(), payment_journal_id = j.id, reference = x.tax_reference where org_id = x.org_id and period = x.period and status <> 'paid';
    else
      insert into wht_remittances (org_id, kind, authority, period, amount, paid_at, bank_account_id, reference, journal_id, created_by)
      values (x.org_id, x.kind, x.authority, x.period, x.amount, now(), tb.id, x.tax_reference, j.id, x.requested_by) returning * into rm;
      update wht_deductions set status = 'remitted', remittance_id = rm.id where org_id = x.org_id and authority = x.authority and period = x.period and status = 'deducted'
        and (kind = 'wht') = (x.kind = 'wht');
    end if;
    perform private.notify_perm(x.org_id, 'make_payments', 'payout', 'Paid ' || upper(x.kind) || ' of ' || private.naira(x.amount) || ' from the tax wallet',
      to_char(x.period, 'FMMonth YYYY') || ' · ' || x.tax_reference, '/payments?tab=tax', 'taxpay-' || x.id);
  elsif v_status in ('failed', 'error', 'reversed') then
    update tax_payments set status = 'failed', error = left(coalesce(d->>'error', 'The transfer failed.'), 500), provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref)
    where id = x.id returning * into x;
    perform private.notify_perm(x.org_id, 'make_payments', 'payout', 'Tax payment from the tax wallet failed', coalesce(x.error, ''), '/payments?tab=tax', 'taxpay-fail-' || x.id);
  else
    update tax_payments set provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref) where id = x.id returning * into x;
  end if;
  return jsonb_build_object('ok', true, 'status', x.status);
end $$;

-- The tax wallet for the Payments page: the wallet, what it holds against what is owed, the moves, the payments.
create or replace function public.get_tax_wallet(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; t public.tax_wallets; w public.wallets; o public.orgs; v_vat numeric; v_wht numeric;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'The tax wallet needs See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  select * into t from tax_wallets where org_id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  -- Tax owed in the books: output VAT less input VAT (and VAT customers withheld), and WHT and withholding VAT not yet paid over.
  v_vat := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and (account_code = private.acct(p_org, 'output_vat')
            or account_code = private.acct(p_org, 'input_vat') or account_code = private.acct(p_org, 'vat_withheld_by_customers'))), 0);
  v_wht := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and (account_code = private.acct(p_org, 'wht_payable')
            or account_code = private.acct(p_org, 'wvat_payable'))), 0);
  return jsonb_build_object(
    'tax_wallet', case when t.id is not null then to_jsonb(t) - 'provider_available' - 'provider_ledger' || jsonb_build_object(
      'books_balance', private.tax_wallet_ledger(t.id), 'spendable', private.tax_wallet_spendable(t.id), 'provider_balance', coalesce(t.provider_ledger, t.provider_available)) end,
    'business_wallet', case when w.id is not null then jsonb_build_object('id', w.id, 'account_number', w.account_number, 'bank_name', w.bank_name) end,
    'owed', jsonb_build_object('vat', round(v_vat, 2), 'wht', round(v_wht, 2), 'total', round(v_vat + v_wht, 2)),
    'reserve', case when t.id is not null then private.vault_reserve(p_org) end,
    'waiting', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and direction = 'in' and status in ('pending', 'sending')),
    'set_aside', jsonb_build_object(
      'vat', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'vat' and status = 'done'),
      'wht', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'wht' and status = 'done'),
      'released', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'release' and status = 'done')),
    'moves', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'kind', mv.kind, 'direction', mv.direction, 'amount', mv.amount, 'period', mv.period,
        'description', mv.description, 'status', mv.status, 'created_at', mv.created_at, 'done_at', mv.done_at,
        'error', case when mv.status in ('pending', 'sending') then tr.error end) order by mv.created_at desc), '[]'::jsonb)
      from (select * from tax_moves where org_id = p_org order by created_at desc limit 200) mv left join tax_transfers tr on tr.id = mv.transfer_id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('requested_by_name', (select display_name from members where id = x.requested_by),
        'journal_ref', (select ref from journals where id = x.journal_id)) order by x.created_at desc), '[]'::jsonb)
      from (select * from tax_payments where org_id = p_org order by created_at desc limit 100) x),
    'payees', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kinds', kinds, 'authority', authority, 'bank_name', bank_name,
        'account_number', account_number, 'account_name', account_name, 'note', note) order by name), '[]'::jsonb) from tax_payees where active),
    'due', jsonb_build_object(
      'vat', (select coalesce(jsonb_agg(jsonb_build_object('period', period, 'payable', payable) order by period), '[]'::jsonb)
              from vat_periods where org_id = p_org and status = 'filed' and payable > 0),
      'wht', (select coalesce(jsonb_agg(jsonb_build_object('period', period, 'authority', authority, 'kind', kind, 'amount', amt) order by period, authority), '[]'::jsonb)
              from (select period, authority, kind, sum(amount) amt from wht_deductions where org_id = p_org and status = 'deducted' and kind in ('wht', 'wvat')
                    group by period, authority, kind) z)),
    'can', jsonb_build_object('open', m.role = 'owner' or private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'pay', private.perm_of(m, 'make_payments') and (m.role = 'owner' or private.perm_of(m, 'approve_payments'))));
end $$;

-- Money that reached a wallet's own account number directly (not through a checkout request it was swept for): a customer
-- paying the business's number (a checkout transfer to it is matched to the sale waiting for it), the owner topping up, a
-- sweep arriving, or money moving between the business wallet and its tax wallet. Recorded once, by the rail's reference.
-- d: {amount, reference, narration, sender:{name, account, bank}, at, provider_ref}
create or replace function public.svc_wallet_inflow(p_rail text, p_account_ref text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; tw public.tax_wallets; r public.payment_requests; bl public.bank_lines; v_amt numeric := round(private.num(d->>'amount'), 2); v_at timestamptz;
  v_ref text := coalesce(nullif(d->>'provider_ref', ''), nullif(d->>'reference', '')); v_text text; v_n int; v_named boolean; conf jsonb; tr public.tax_transfers;
  v_journal uuid;
begin
  select * into w from wallets where rail = p_rail and (account_ref = p_account_ref or account_number = p_account_ref) order by (account_ref = p_account_ref) desc limit 1;
  if w.id is null then
    select * into tw from tax_wallets where rail = p_rail and (account_ref = p_account_ref or account_number = p_account_ref) order by (account_ref = p_account_ref) desc limit 1;
  end if;
  if (w.id is null and tw.id is null) or coalesce(v_amt, 0) = 0 or v_ref is null then return jsonb_build_object('ok', false, 'reason', 'unknown_wallet'); end if;
  v_at := coalesce(nullif(d->>'at', '')::timestamptz, now());
  v_text := upper(coalesce(d->>'narration', '') || ' ' || coalesce(d->>'reference', ''));

  if tw.id is not null then
    if exists (select 1 from bank_lines where bank_account_id = tw.bank_account_id and fingerprint = 'wallet:' || v_ref) then
      return jsonb_build_object('ok', true, 'duplicate', true);
    end if;
    -- Our own transfer from the business wallet: its entry is already in the books.
    select * into tr from tax_transfers where tax_wallet_id = tw.id and direction = 'in' and status in ('sent', 'done')
      and (position(reference in v_text) > 0 or (amount = v_amt and sent_at > v_at - interval '2 days'
           and not exists (select 1 from bank_lines bx where bx.bank_account_id = tw.bank_account_id and bx.journal_id = tax_transfers.journal_id)))
    order by (position(reference in v_text) > 0) desc, sent_at limit 1;
    insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
      provider_ref, fingerprint, status, journal_id, matched_by, confidence, stage)
    values (tw.org_id, tw.bank_account_id, private.local_day(tw.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
      d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref,
      case when tr.id is not null then 'matched' else 'unmatched' end, tr.journal_id, case when tr.id is not null then 'system' end,
      case when tr.id is not null then 1 end, case when tr.id is not null then 'tax_transfer' end)
    on conflict do nothing returning * into bl;
    if tr.id is not null then update tax_transfers set status = 'done', done_at = coalesce(done_at, v_at) where id = tr.id; end if;
    if bl.id is not null and bl.status = 'unmatched' then
      perform private.match_bank_line(bl.id);
      select * into bl from bank_lines where id = bl.id;
    end if;
    return jsonb_build_object('ok', true, 'matched', coalesce(bl.status, 'matched') <> 'unmatched', 'bank_line', bl.id, 'tax_wallet', true);
  end if;

  if exists (select 1 from bank_lines where bank_account_id = w.bank_account_id and fingerprint = 'wallet:' || v_ref) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  -- A customer's transfer to the business's own number for a sale (or a balance) waiting for it: the narration naming it
  -- first, then a request still waiting, the oldest first.
  select count(*) into v_n from payment_requests where wallet_id = w.id and direct and status in ('pending', 'expired', 'cancelled') and amount = v_amt
    and created_at <= v_at + interval '10 minutes' and created_at > v_at - interval '4 days';
  if v_n > 0 then
    select * into r from payment_requests where wallet_id = w.id and direct and status in ('pending', 'expired', 'cancelled') and amount = v_amt
      and created_at <= v_at + interval '10 minutes' and created_at > v_at - interval '4 days'
    order by (pay_ref is not null and position(upper(pay_ref) in v_text) > 0) desc, (status = 'pending') desc, (status = 'expired') desc, created_at
    limit 1;
    v_named := r.pay_ref is not null and position(upper(r.pay_ref) in v_text) > 0;
    conf := public.svc_payment_confirmed(r.tx_ref, jsonb_build_object('amount', v_amt, 'fee', 0, 'provider_ref', v_ref, 'paid_at', v_at,
      'payer', coalesce(d->'sender', '{}'::jsonb)));
    select c.journal_id into v_journal from payment_requests pr join collections c on c.id = pr.collection_id where pr.id = r.id;
    insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
      provider_ref, fingerprint, status, journal_id, matched_by, confidence, stage)
    values (w.org_id, w.bank_account_id, private.local_day(w.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
      d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref, 'matched', v_journal, 'system',
      case when v_named or v_n = 1 then 1 else 0.8 end, 'wallet_request')
    on conflict do nothing returning * into bl;
    -- Several waiting for the same amount and nothing in the narration to tell them apart: matched to the oldest, and someone checks.
    if v_n > 1 and not v_named and bl.id is not null then
      insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
      values (w.org_id, 'bookkeeper', 'wallet_payment_check', 'bank_line', bl.id,
        'Check which sale ' || private.naira(v_amt) || ' paid',
        v_n || ' payments of ' || private.naira(v_amt) || ' were waiting when this transfer reached the wallet, and its narration does not say which. Counta gave it to '
          || coalesce((select number from sales where id = r.sale_id), 'the oldest') || '. Ask the cashier if that is right.',
        jsonb_build_object('request_id', r.id, 'sale_id', r.sale_id), 0.8, 'Wallet transfer matched by amount only', 'wallet_request', 'info', v_amt, v_journal)
      on conflict do nothing;
    end if;
    return jsonb_build_object('ok', true, 'matched', true, 'request', conf->'request', 'bank_line', bl.id);
  end if;

  -- Our own sweep of a checkout payment: the collection already posted it.
  select * into r from payment_requests where wallet_id = w.id and sweep_status in ('sent', 'pending', 'failed')
    and (sweep_ref = d->>'reference' or coalesce(d->>'narration', '') like '%' || tx_ref || '%' or coalesce(d->>'reference', '') like '%' || tx_ref || '%'
         or (round(paid_amount - coalesce(fee, 0), 2) = v_amt and paid_at > v_at - interval '2 days'
             and coalesce(d->'sender'->>'name', '') ~* '(flutterwave|taxstreem|counta)'))
  order by (sweep_ref = d->>'reference') desc nulls last, paid_at limit 1;
  -- Money back from the tax wallet.
  if r.id is null then
    select * into tr from tax_transfers where wallet_id = w.id and direction = 'out' and status in ('sent', 'done')
      and (position(reference in v_text) > 0 or (amount = v_amt and sent_at > v_at - interval '2 days'
           and not exists (select 1 from bank_lines bx where bx.bank_account_id = w.bank_account_id and bx.journal_id = tax_transfers.journal_id)))
    order by (position(reference in v_text) > 0) desc, sent_at limit 1;
  end if;
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
    provider_ref, fingerprint, status, journal_id, matched_by, confidence)
  values (w.org_id, w.bank_account_id, private.local_day(w.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
    d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref,
    case when r.id is not null or tr.id is not null then 'matched' else 'unmatched' end,
    coalesce((select journal_id from collections where id = r.collection_id), tr.journal_id),
    case when r.id is not null or tr.id is not null then 'system' end, case when r.id is not null or tr.id is not null then 1 end)
  on conflict do nothing
  returning * into bl;
  if r.id is not null then
    update payment_requests set sweep_status = 'done', swept_at = coalesce(swept_at, v_at) where id = r.id;
  end if;
  if tr.id is not null then update tax_transfers set status = 'done', done_at = coalesce(done_at, v_at) where id = tr.id; end if;
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

-- Work for the payments function's five-minute poll.
create or replace function public.svc_work(p_kind text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if p_kind = 'requests' then
    update payment_requests set status = 'expired' where status = 'pending' and expires_at < now() - interval '30 minutes';
    update payment_requests set status = 'failed', error = coalesce(error, 'The payment rail did not answer.') where status = 'creating' and created_at < now() - interval '10 minutes';
    -- Transfers to the business's own number are found on the wallet's statement, not by asking the rail about the request.
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tx_ref', tx_ref, 'rail', rail, 'org_id', org_id)), '[]'::jsonb) from (
      select id, tx_ref, rail, org_id from payment_requests
      where status = 'pending' and not direct and created_at < now() - interval '2 minutes' and created_at > now() - interval '2 days'
        and (checked_at is null or checked_at < now() - interval '4 minutes')
      order by created_at limit 50) x);
  elsif p_kind = 'direct_wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'rail', w.rail, 'account_ref', w.account_ref, 'org_id', w.org_id)), '[]'::jsonb)
      from wallets w where w.status = 'active' and w.account_ref is not null
        and exists (select 1 from payment_requests r where r.wallet_id = w.id and r.direct and r.status = 'pending' and r.created_at > now() - interval '3 days'));
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
  elsif p_kind = 'tax_wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'rail', t.rail, 'account_ref', t.account_ref, 'org_id', t.org_id, 'tax', true)), '[]'::jsonb)
      from tax_wallets t where t.status = 'active' and t.account_ref is not null);
  elsif p_kind = 'tax_transfers' then
    return private.tax_transfers_due();
  elsif p_kind = 'tax_payments' then
    return (select coalesce(jsonb_agg(jsonb_build_object('reference', x.reference, 'rail', t.rail, 'provider_ref', x.provider_ref)), '[]'::jsonb)
      from tax_payments x join tax_wallets t on t.id = x.tax_wallet_id where x.status = 'processing' and x.sent_at < now() - interval '5 minutes');
  elsif p_kind = 'batches' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'title', b.title, 'mode', b.mode, 'rail', w.rail, 'account_ref', w.account_ref,
        'bulk', b.mode = 'bulk' and exists (select 1 from payment_rails r where r.code = w.rail and 'bulk_payout' = any(r.capabilities)),
        'barter_id', w.barter_id, 'provider_batch_ids', b.provider_batch_ids,
        'approved', (select count(*) from payouts where batch_id = b.id and status = 'approved'),
        'processing', (select count(*) from payouts where batch_id = b.id and status = 'processing')) order by b.sent_at), '[]'::jsonb)
      from payout_batches b join wallets w on w.id = b.wallet_id where b.status = 'sending');
  end if;
  raise exception 'Unknown work kind.';
end $$;

create or replace function private.open_request(p_org uuid, p_sale uuid, p_customer uuid, p_method text, p_amount numeric, m public.members,
  p_public boolean, p_shift uuid) returns public.payment_requests
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s public.sales; w public.wallets; r public.payment_requests; v_amt numeric; v_due numeric; v_pending numeric; pr public.payment_rails;
  v_tx text; v_direct boolean;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
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
  v_tx := 'CNT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
  -- A transfer goes to the business's own wallet number: no account to ask the rail for, the request waits at once.
  v_direct := p_method = 'account' and 'direct_account' = any(pr.capabilities) and w.account_number is not null;
  insert into payment_requests (org_id, sale_id, customer_id, purpose, method, rail, amount, tx_ref, status, shift_id, created_by, wallet_id, public_request,
    direct, pay_ref, account_number, bank_name, account_name, expires_at)
  values (p_org, p_sale, coalesce(p_customer, s.customer_id), case when p_sale is null then 'customer_balance' when s.doc_type = 'order' then 'order' else 'sale' end,
    p_method, o.payment_rail, v_amt, v_tx, case when v_direct then 'pending' else 'creating' end, p_shift, m.id, w.id, p_public,
    v_direct, case when v_direct then coalesce(s.number, right(v_tx, 6)) end, case when v_direct then w.account_number end, case when v_direct then w.bank_name end,
    case when v_direct then coalesce(w.account_name, o.name) end,
    case when v_direct then now() + case when p_public then interval '3 days' else interval '30 minutes' end end)
  returning * into r;
  return r;
end $$;


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
    'org', private.org_brand(s.org_id),
    'customer', (select jsonb_build_object('city', c.city, 'state', c.state, 'country', c.country, 'contact_person', c.contact_person)
      from customers c where c.id = s.customer_id),
    'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
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
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref,
        'direct', r.direct, 'pay_ref', r.pay_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end)
  from sales s where s.id = p_sale
$$;


create or replace function private.request_json(r public.payment_requests) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', r.id, 'tx_ref', r.tx_ref, 'method', r.method, 'rail', r.rail, 'amount', r.amount, 'currency', r.currency, 'status', r.status,
    'account_number', r.account_number, 'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'qr_image', r.qr_image,
    'expires_at', r.expires_at, 'paid_amount', r.paid_amount, 'paid_at', r.paid_at, 'error', r.error, 'sale_id', r.sale_id,
    'sale_number', (select number from sales where id = r.sale_id), 'sale_status', (select status from sales where id = r.sale_id),
    'payer', case when r.status = 'paid' then r.payer->>'name' end, 'direct', r.direct, 'pay_ref', r.pay_ref)
$$;


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
    sweep_status = case when r.rail = 'flutterwave' and w.barter_id is not null and not r.direct then 'pending' else 'not_needed' end
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
      case when s.id is not null then '/sell/sales?open=' || s.id else '/sell/customers' end, 'paid-' || r.id);
  end if;
  return jsonb_build_object('ok', true, 'request', private.request_json(r), 'collection', c.number, 'org_id', r.org_id,
    'sweep', case when r.sweep_status = 'pending' then jsonb_build_object('barter_id', w.barter_id, 'amount', v_amt - v_fee, 'reference', 'SWP-' || r.tx_ref) end);
end $$;


create or replace function public.svc_wallet_balance(p_wallet uuid, p_available numeric, p_ledger numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; v_books numeric; v_transit numeric; v_diff numeric; rec public.wallet_reconciliations; v_out numeric;
begin
  select * into w from wallets where id = p_wallet for update;
  if not found then raise exception 'Wallet not found.'; end if;
  update wallets set provider_available = p_available, provider_ledger = p_ledger, balance_at = now() where id = w.id;
  v_books := private.wallet_ledger(w.id);
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
    ('FLW_RELAY_SECRET', 'flutterwave', 'Transfer relay secret', true, 'The RELAY_SECRET set on the relay server. Signs every request Counta sends through it.', 305),
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
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902)
$$;


create or replace function public.admin_set_secret(p_name text, p_value text) returns jsonb
language plpgsql security definer set search_path = public, private, vault as $$
declare c record; v text := btrim(coalesce(p_value, '')); v_id uuid; v_shown text; j jsonb;
begin
  perform private.require_staff();
  select * into c from private.secret_catalog() x where x.name = p_name;
  if not found then raise exception 'Unknown setting.'; end if;
  if v = '' then raise exception 'Paste the value first. To clear it, use Remove.'; end if;
  if length(v) > 20000 then raise exception 'That is too long for a key.'; end if;
  if p_name = 'GOOGLE_APPLICATION_CREDENTIALS_JSON' then
    begin j := v::jsonb; exception when others then raise exception 'Paste the whole JSON key file, from { to }.'; end;
    if jsonb_typeof(j) <> 'object' or coalesce(j->>'type', '') = '' then raise exception 'That JSON has no "type". Paste the whole key file.'; end if;
    v_shown := coalesce(j->>'client_email', j->>'type');
  elsif c.secret then
    if length(v) < 8 then raise exception 'That is too short for a key.'; end if;
    v_shown := '•••• ' || right(v, 4);
  else
    if p_name in ('NUMENS_API_URL', 'FLUX_URL', 'APP_URL', 'FLW_RELAY_URL') and v !~ '^https://[^\s]+$' then raise exception 'Enter an https:// address.'; end if;
    if p_name = 'RESEND_FROM' and v !~* '[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}' then raise exception 'Enter an email address, such as billing@taxstreem.com.'; end if;
    if p_name = 'VAPID_SUBJECT' and v !~ '^(mailto:[^\s@]+@[^\s@]+|https://[^\s]+)$' then raise exception 'Enter mailto: and an email address.'; end if;
    if p_name in ('GOOGLE_CLOUD_LOCATION', 'GEMINI_MODEL', 'ELEVENLABS_TTS_MODEL', 'TAXSTREEM_SSO_ISSUER', 'GOOGLE_CLOUD_PROJECT') and v !~ '^[A-Za-z0-9._-]{2,80}$' then
      raise exception 'Use letters, numbers, dots and dashes only.';
    end if;
    if p_name in ('ELEVENLABS_PHONE_NUMBER_ID', 'WHATSAPP_PHONE_NUMBER_ID', 'WHATSAPP_BUSINESS_ACCOUNT_ID', 'FLW_PUBLIC_KEY', 'MONO_PUBLIC_KEY')
       and v !~ '^[A-Za-z0-9_-]{3,120}$' then raise exception 'That does not look like an id or a public key.'; end if;
    if p_name = 'WHATSAPP_TEMPLATE_LANG' and v !~ '^[a-z]{2}(_[A-Z]{2})?$' then raise exception 'Use a language code such as en or en_US.'; end if;
    v_shown := left(v, 200);
  end if;
  select id into v_id from vault.secrets where name = p_name order by created_at desc limit 1;
  if v_id is null then perform vault.create_secret(v, p_name, 'Set in the Counta admin portal');
  else perform vault.update_secret(v_id, v); end if;
  insert into platform_secrets (name, shown, set_by, set_at) values (p_name, v_shown, auth.uid(), now())
  on conflict (name) do update set shown = excluded.shown, set_by = excluded.set_by, set_at = excluded.set_at;
  perform private.audit('set_key', p_name, jsonb_build_object('shown', v_shown));
  return jsonb_build_object('name', p_name, 'shown', v_shown, 'secret', c.secret);
end $$;


-- ---------------------------------------------------------------------------
-- 5. Matching money in and out to invoices and bills, for a person to confirm
-- ---------------------------------------------------------------------------
-- A bank line (from a statement, a bank feed or the wallet) or a line of an uploaded sales schedule is compared with the
-- open invoices (money in) or bills (money out): the customer's or vendor's name in the narration, the document's number
-- or the goods on it in the narration or reference, and the amount: exactly what is owed, what is owed less withholding
-- tax at 2, 5 or 10% (and VAT for a customer who withholds VAT), or a little less (or more, for a bill) for bank charges.
-- Up to three candidates are put to a person in the books inbox, best first; nothing settles an invoice or a bill until
-- they confirm. Only the strongest evidence still settles on its own: a payment the cashier recorded and the statement
-- confirms, or the document's own number in the narration with the exact amount (or the amount less WHT).

-- Words of a name that tell it apart (not "Limited", "Nigeria", "Enterprises" and the like), upper case.
create or replace function private.name_words(p text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct w), '{}') from regexp_split_to_table(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+') w
  where length(w) >= 3 and w not in ('LTD', 'LIMITED', 'PLC', 'NIG', 'NIGERIA', 'ENTERPRISE', 'ENTERPRISES', 'VENTURE', 'VENTURES', 'COMPANY', 'THE', 'AND',
    'INTERNATIONAL', 'GLOBAL', 'SERVICES', 'SERVICE', 'GROUP', 'HOLDINGS', 'INVESTMENT', 'INVESTMENTS', 'TRADING', 'STORES', 'STORE', 'SHOP', 'MRS', 'MR', 'MISS',
    'TRF', 'TRANSFER', 'FROM', 'NIP', 'POS', 'WEB', 'USSD', 'MOB', 'MOBILE', 'PAYMENT', 'PAY', 'FOR', 'INV', 'INVOICE', 'BILL', 'REF')
$$;

-- How much of a name is in a text: the share of its distinguishing words found there (0 to 1).
create or replace function private.name_score(p_name text, p_text text) returns numeric
language sql immutable set search_path = '' as $$
  select case when cardinality(n) = 0 then 0 else round((select count(*) from unnest(n) x where x = any(t))::numeric / cardinality(n), 2) end
  from (select private.name_words(p_name) n, private.name_words(p_text) t) z
$$;

-- Whether a text names a customer or vendor: their name as Counta has it, or every word that tells the name apart (so
-- "OKAFOR BROTHERS NIG" names Okafor Brothers Nigeria Limited). A one-word name needs six letters or more.
create or replace function private.name_match(p_name text, p_text text) returns boolean
language sql immutable set search_path = public, private as $$
  select private.name_in(p_name, p_text) or coalesce((select private.name_score(p_name, p_text) = 1
    and (cardinality(w) >= 2 or (cardinality(w) = 1 and length(w[1]) >= 6)) from (select private.name_words(p_name) w) z), false)
$$;

-- Whether a line of goods or services is named in a text (any word of four letters or more that is not a common word).
create or replace function private.words_in(p_line text, p_text text) returns boolean
language sql immutable set search_path = '' as $$
  select exists (select 1 from unnest(private.name_words(p_line)) w where length(w) >= 4 and w = any(private.name_words(p_text)))
$$;

-- Open invoices a payment of p_amt could settle, best first (up to three). p_text: the narration, reference and the payer's name.
create or replace function private.invoice_candidates(p_org uuid, p_amt numeric, p_text text, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r record; v_out jsonb := '[]'::jsonb; v_tol numeric; v_split jsonb; v_basis text; v_wht numeric; v_wvat numeric; v_fee numeric; v_score numeric;
  v_named boolean; v_ns numeric; v_ref boolean; v_items boolean; v_rate numeric; v_reasons text[]; v_cust record; v_sum numeric; v_ids uuid[]; v_nums text[]; s record;
begin
  for r in
    select x.id, x.number, x.subtotal, x.total, x.issue_date, x.due_date, x.customer_id, cu.name cust_name,
      x.total - x.amount_paid - x.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = x.id and cc.status = 'pending'), 0) due
    from sales x join customers cu on cu.id = x.customer_id
    where x.org_id = p_org and x.doc_type in ('invoice', 'order', 'receipt') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and not cu.is_walk_in and x.issue_date between p_day - 400 and p_day + 1
      and ((x.total - x.amount_paid - x.credited) between p_amt - 0.01 and p_amt * 1.25 + 300
           or private.doc_in_text(x.number, p_text) or private.name_match(cu.name, p_text))
  loop
    continue when r.due <= 0.004;
    v_tol := greatest(100, round(r.due * 0.005, 2));
    v_named := private.name_match(r.cust_name, p_text);
    v_ns := private.name_score(r.cust_name, p_text);
    v_ref := private.doc_in_text(r.number, p_text);
    v_items := exists (select 1 from sale_lines l where l.sale_id = r.id and private.words_in(l.description, p_text));
    v_basis := null; v_wht := 0; v_wvat := 0; v_fee := 0;
    if abs(r.due - p_amt) < 0.005 then v_basis := 'exact';
    elsif p_amt < r.due then
      v_split := private.customer_short_split(r.id, r.due, p_amt);
      if v_split is not null then
        v_basis := 'less_wht'; v_wht := (v_split->>'wht')::numeric; v_wvat := coalesce((v_split->>'wvat')::numeric, 0);
      elsif r.due - p_amt <= v_tol then
        v_basis := 'bank_charge'; v_fee := round(r.due - p_amt, 2);
      else
        foreach v_rate in array array[0.02, 0.05, 0.10] loop
          v_wht := round(r.subtotal * v_rate, 2);
          if r.due - v_wht - p_amt > 0.004 and r.due - v_wht - p_amt <= v_tol then v_basis := 'less_wht_charge'; v_fee := round(r.due - v_wht - p_amt, 2); exit; end if;
          v_wht := 0;
        end loop;
        if v_basis is null and (v_named or v_ref) then v_basis := 'part'; end if;
      end if;
    elsif v_named or v_ref then
      v_basis := 'over';
    end if;
    continue when v_basis is null;
    v_score := case v_basis when 'exact' then 40 when 'less_wht' then 36 when 'bank_charge' then 30 when 'less_wht_charge' then 28 when 'over' then 12 else 8 end
      + case when v_ref then 50 else 0 end + case when v_named then 30 else round(v_ns * 25) end + case when v_items then 8 else 0 end
      + case when p_day between r.issue_date - 1 and coalesce(r.due_date, r.issue_date) + 60 then 4 else 0 end;
    v_reasons := array_remove(array[
      case when v_ref then r.number || ' is in the narration' end,
      case when v_named then r.cust_name || ' is named' when v_ns > 0 then 'Part of ' || r.cust_name || '''s name is in the narration' end,
      case v_basis when 'exact' then 'Exactly what is owed'
        when 'less_wht' then 'What is owed less ' || case when v_wvat > 0 and v_wht > 0 then 'WHT and VAT withheld' when v_wvat > 0 then 'VAT withheld' else 'WHT at ' || round(v_wht / nullif(r.subtotal, 0) * 100) || '%' end
        when 'bank_charge' then 'What is owed less ' || private.naira(v_fee) || ', likely a bank charge'
        when 'less_wht_charge' then 'What is owed less WHT and ' || private.naira(v_fee) || ' in charges'
        when 'over' then 'More than is owed'
        else 'Part of what is owed' end,
      case when v_items then 'The goods or service on it are in the narration' end], null);
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'sale', 'id', r.id, 'number', r.number, 'party_id', r.customer_id, 'party_name', r.cust_name,
      'due', r.due, 'basis', v_basis, 'wht', v_wht, 'wvat', v_wvat, 'fee', v_fee, 'score', v_score, 'reasons', to_jsonb(v_reasons)));
  end loop;
  -- A named customer paying several open invoices at once: the oldest ones adding up to the amount.
  for v_cust in select cu.id, cu.name from customers cu where cu.org_id = p_org and not cu.is_walk_in and not cu.archived and private.name_match(cu.name, p_text)
                order by length(cu.name) desc limit 2 loop
    v_sum := 0; v_ids := '{}'; v_nums := '{}';
    for s in select x.id, x.number, x.total - x.amount_paid - x.credited due from sales x where x.customer_id = v_cust.id and x.status in ('open', 'partially_paid')
             and x.journal_id is not null and x.doc_type in ('invoice', 'order', 'receipt') order by coalesce(x.due_date, x.issue_date), x.created_at limit 8 loop
      v_sum := v_sum + s.due; v_ids := v_ids || s.id; v_nums := v_nums || s.number;
      exit when v_sum >= p_amt - 0.004;
    end loop;
    if cardinality(v_ids) >= 2 and abs(v_sum - p_amt) < 0.005 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'sales', 'ids', to_jsonb(v_ids), 'number', array_to_string(v_nums, ', '),
        'party_id', v_cust.id, 'party_name', v_cust.name, 'due', v_sum, 'basis', 'several', 'wht', 0, 'wvat', 0, 'fee', 0, 'score', 85,
        'reasons', jsonb_build_array(v_cust.name || ' is named', 'Exactly what is owed on ' || cardinality(v_ids) || ' invoices')));
    end if;
  end loop;
  return (select coalesce(jsonb_agg(c order by (c->>'score')::numeric desc, c->>'number'), '[]'::jsonb)
          from (select c from jsonb_array_elements(v_out) c order by (c->>'score')::numeric desc, c->>'number' limit 3) z);
end $$;

-- Open bills a payment of p_amt could settle, best first (up to three). p_account: the payee's account number, if known.
create or replace function private.bill_candidates(p_org uuid, p_amt numeric, p_text text, p_day date, p_account text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r record; v_out jsonb := '[]'::jsonb; v_tol numeric; v_basis text; v_wht numeric; v_fee numeric; v_gross numeric; v_score numeric; v_named boolean;
  v_ns numeric; v_ref boolean; v_reasons text[]; v_rate numeric;
begin
  for r in
    select x.id, x.number, x.vendor_ref, x.total, x.bill_date, x.due_date, x.vendor_id, v.name vendor_name, v.account_number vacct, x.wht_expected, x.wvat_expected,
      x.total - x.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = x.id and status = 'processing'), 0) due,
      greatest(x.wht_expected + x.wvat_expected - x.wht_withheld - x.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = x.id and status = 'processing'), 0), 0) wht_left
    from bills x join vendors v on v.id = x.vendor_id
    where x.org_id = p_org and x.status in ('approved', 'partially_paid') and x.bill_date between p_day - 400 and p_day + 1
      and ((x.total - x.amount_paid) between p_amt * 0.995 - 300 and p_amt * 1.25 + 300
           or private.doc_in_text(x.number, p_text) or private.ref_in_text(x.vendor_ref, p_text) or private.name_match(v.name, p_text)
           or (v.account_number is not null and position(v.account_number in coalesce(p_account, '') || ' ' || p_text) > 0))
  loop
    continue when r.due <= 0.004;
    v_tol := greatest(100, round(r.due * 0.005, 2));
    v_named := private.name_match(r.vendor_name, p_text) or (r.vacct is not null and position(r.vacct in coalesce(p_account, '') || ' ' || p_text) > 0);
    v_ns := private.name_score(r.vendor_name, p_text);
    v_ref := private.doc_in_text(r.number, p_text) or (r.vendor_ref is not null and private.ref_in_text(r.vendor_ref, p_text));
    v_basis := null; v_wht := 0; v_fee := 0; v_gross := null;
    if abs(r.due - p_amt) < 0.005 then v_basis := 'exact'; v_gross := r.due;
    elsif r.wht_left > 0 and abs(r.due - r.wht_left - p_amt) < 0.005 then v_basis := 'less_wht'; v_gross := r.due; v_wht := r.wht_left;
    elsif p_amt - r.due > 0.004 and p_amt - r.due <= v_tol then v_basis := 'bank_charge'; v_gross := r.due; v_fee := round(p_amt - r.due, 2);
    elsif r.wht_left > 0 and p_amt - (r.due - r.wht_left) > 0.004 and p_amt - (r.due - r.wht_left) <= v_tol then
      v_basis := 'less_wht_charge'; v_gross := r.due; v_wht := r.wht_left; v_fee := round(p_amt - (r.due - r.wht_left), 2);
    elsif p_amt < r.due - r.wht_left and (v_named or v_ref) then
      v_rate := coalesce((r.wht_expected + r.wvat_expected) / nullif(r.total, 0), 0);
      v_basis := 'part'; v_gross := round(p_amt / (1 - v_rate), 2); v_wht := greatest(v_gross - p_amt, 0);
    end if;
    continue when v_basis is null;
    v_score := case v_basis when 'exact' then 40 when 'less_wht' then 38 when 'bank_charge' then 30 when 'less_wht_charge' then 28 else 8 end
      + case when v_ref then 50 else 0 end + case when v_named then 30 else round(v_ns * 25) end
      + case when p_day between r.bill_date - 1 and coalesce(r.due_date, r.bill_date) + 60 then 4 else 0 end;
    v_reasons := array_remove(array[
      case when v_ref then coalesce(r.vendor_ref, r.number) || ' is in the narration' end,
      case when v_named then r.vendor_name || ' is named' when v_ns > 0 then 'Part of ' || r.vendor_name || '''s name is in the narration' end,
      case v_basis when 'exact' then 'Exactly what is owed' when 'less_wht' then 'What is owed less the WHT to keep back'
        when 'bank_charge' then 'What is owed plus ' || private.naira(v_fee) || ', likely a bank charge'
        when 'less_wht_charge' then 'What is owed less WHT, plus ' || private.naira(v_fee) || ' in charges' else 'Part of what is owed' end], null);
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'bill', 'id', r.id, 'number', r.number, 'vendor_ref', r.vendor_ref, 'party_id', r.vendor_id,
      'party_name', r.vendor_name, 'due', r.due, 'basis', v_basis, 'gross', v_gross, 'wht', v_wht, 'fee', v_fee, 'score', v_score, 'reasons', to_jsonb(v_reasons)));
  end loop;
  return (select coalesce(jsonb_agg(c order by (c->>'score')::numeric desc, c->>'number'), '[]'::jsonb)
          from (select c from jsonb_array_elements(v_out) c order by (c->>'score')::numeric desc, c->>'number' limit 3) z);
end $$;

-- A bank line's candidates.
create or replace function private.match_candidates(p_line uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when bl.amount > 0
    then private.invoice_candidates(bl.org_id, abs(bl.amount), coalesce(bl.counterparty, '') || ' ' || coalesce(bl.description, '') || ' ' || coalesce(bl.reference, ''), bl.line_date)
    else private.bill_candidates(bl.org_id, abs(bl.amount), coalesce(bl.counterparty, '') || ' ' || coalesce(bl.description, '') || ' ' || coalesce(bl.reference, ''),
      bl.line_date, bl.counterparty_account) end
  from bank_lines bl where bl.id = p_line
$$;

-- Holds a line in suspense and puts its candidates to a person in the books inbox.
create or replace function private.propose_match(p_line uuid, p_candidates jsonb, p_stage text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; c jsonb := p_candidates->0; v_id uuid; v_in boolean; v_title text; v_q text;
begin
  select * into bl from bank_lines where id = p_line;
  v_in := bl.amount > 0;
  v_title := case when jsonb_array_length(p_candidates) > 1 then 'Which ' || case when v_in then 'invoice' else 'bill' end || ' does ' || private.naira(abs(bl.amount)) || ' pay?'
    else case when v_in then 'Payment for ' else 'Payment of ' end || (c->>'number') || '?' end;
  v_q := 'Is this ' || private.naira(abs(bl.amount)) || case when v_in then ' from ' else ' to ' end || (c->>'party_name') || ' for ' || (c->>'number')
    || case when jsonb_array_length(p_candidates) > 1 then ', or one of the others?' else '?' end || ' Confirm it, or say what it was.';
  v_id := private.suspend_line(bl.id, v_title, v_q,
    jsonb_build_object('kind', case when v_in then 'invoice_match' else 'bill_match' end,
      'sale_id', case when c->>'kind' = 'sale' then c->>'id' end, 'bill_id', case when c->>'kind' = 'bill' then c->>'id' end,
      'number', c->>'number', 'vendor_ref', c->>'vendor_ref',
      'customer_id', case when v_in then c->>'party_id' end, 'customer_name', case when v_in then c->>'party_name' end,
      'vendor_id', case when not v_in then c->>'party_id' end, 'vendor_name', case when not v_in then c->>'party_name' end,
      'party_type', case when v_in then 'customer' else 'vendor' end, 'party_id', c->>'party_id',
      'account_code', private.acct(bl.org_id, case when v_in then 'receivables' else 'payables' end),
      'candidates', p_candidates),
    least(0.95, round(((c->>'score')::numeric) / 130, 2)), array_to_string(array(select jsonb_array_elements_text(c->'reasons')), '; '), p_stage);
  perform private.notify_perm(bl.org_id, 'keep_books', 'bank', v_title, v_q, '/accounting/inbox', 'match-' || bl.id);
  return v_id;
end $$;

create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb;
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

-- Settles a line against the invoice(s) or bill a person chose, on what is owed now: exactly, less WHT (and VAT withheld),
-- less a bank charge, part of it, or more than it (the extra held as customer credit).
create or replace function private.apply_match(p_line uuid, c jsonb, m public.members, p_holding uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; s public.sales; bb public.bills; col public.collections; j public.journals; v_amt numeric; v_due numeric;
  v_split jsonb; v_at timestamptz; v_ref text; v_fee numeric; v_wht numeric; v_left_wht numeric; v_gross numeric; v_rate numeric; v_ids uuid[]; x uuid; v_tol numeric;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_ref := coalesce(bl.reference, left(bl.description, 60));
  if c->>'kind' = 'sales' then
    v_ids := array(select (jsonb_array_elements_text(c->'ids'))::uuid);
    foreach x in array v_ids loop
      if not exists (select 1 from sales where id = x and status in ('open', 'partially_paid')) then raise exception 'One of those invoices is no longer open. Say what this payment was.'; end if;
    end loop;
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || (c->>'number'), null); end if;
    col := private.add_collection(bl.org_id, (c->>'party_id')::uuid, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
      'reference', v_ref, 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person'), 'spread', false), m, 'confirmed', v_ids);
    update bank_lines set status = 'matched', journal_id = col.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    return jsonb_build_object('journal_id', col.journal_id, 'settled', c->>'number');
  elsif c->>'kind' = 'sale' then
    select * into s from sales where id = (c->>'id')::uuid for update;
    if s.id is null or s.status not in ('open', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(s.number, 'The invoice'); end if;
    v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
      where a.sale_id = s.id and cc.status = 'pending'), 0);
    v_tol := greatest(100, round(v_due * 0.005, 2));
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || s.number, null); end if;
    v_fee := 0;
    if v_amt < v_due - 0.004 then
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if v_split is null and c->>'basis' = 'less_wht_charge' and coalesce((c->>'wht')::numeric, 0) > 0
         and v_due - (c->>'wht')::numeric - v_amt > 0.004 and v_due - (c->>'wht')::numeric - v_amt <= v_tol then
        v_rate := round((c->>'wht')::numeric / nullif(s.subtotal, 0), 4);
        v_split := jsonb_build_object('wht', (c->>'wht')::numeric, 'wht_rate', v_rate, 'wvat', 0);
        v_fee := round(v_due - (c->>'wht')::numeric - v_amt, 2);
      elsif v_split is null and c->>'basis' in ('bank_charge', 'less_wht_charge') and v_due - v_amt <= v_tol then
        v_fee := round(v_due - v_amt, 2);
      end if;
      if v_split is not null then perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m); end if;
    end if;
    -- A bank charge taken out of the payment: the invoice is settled in full and the charge is the business's cost.
    col := private.add_collection(bl.org_id, s.customer_id, v_amt + v_fee, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
      'reference', v_ref, 'fee', v_fee, 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person')
        || case when v_fee > 0 then ' · ' || private.naira(v_fee) || ' bank charge' else '' end, 'spread', false), m, 'confirmed', array[s.id]);
    update bank_lines set status = 'matched', journal_id = col.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    if v_amt > v_due + 0.004 then
      insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
      values (bl.org_id, 'bookkeeper', 'overpaid_invoice', 'bank_line', bl.id, s.customer_name || ' paid more than ' || s.number,
        'The extra is held as customer credit. Refund it or use it on their next invoice.', jsonb_build_object('sale_id', s.id, 'customer_id', s.customer_id), 0.9,
        'AR: payment exceeds what is owed', 'user', 'info', v_amt - v_due, col.journal_id) on conflict do nothing;
    end if;
    return jsonb_build_object('journal_id', col.journal_id, 'settled', s.number);
  elsif c->>'kind' = 'bill' then
    select * into bb from bills where id = (c->>'id')::uuid for update;
    if bb.id is null or bb.status not in ('approved', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(bb.number, 'The bill'); end if;
    v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
    v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld, 0);
    v_tol := greatest(100, round(v_due * 0.005, 2));
    v_fee := 0;
    v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                    when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                    when v_amt - v_due > 0.004 and v_amt - v_due <= v_tol then v_due
                    when v_left_wht > 0 and v_amt - (v_due - v_left_wht) > 0.004 and v_amt - (v_due - v_left_wht) <= v_tol then v_due
                    when v_amt < v_due - v_left_wht then round(v_amt / (1 - coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0)), 2) end;
    if v_gross is null then raise exception '% has only % left to pay.', bb.number, private.naira(v_due); end if;
    v_wht := case when abs(v_due - v_amt) < 0.005 or (v_amt - v_due > 0.004 and v_amt - v_due <= v_tol) then 0
                  when v_amt < v_due - v_left_wht then greatest(v_gross - v_amt, 0)
                  else v_left_wht end;
    v_fee := round(greatest(v_amt - (v_gross - v_wht), 0), 2);
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || bb.number, null); end if;
    j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, v_ref, m);
    -- Charges the bank added on top of the payment.
    if v_fee > 0 then
      perform private.post_entry(bl.org_id, 'Bank charge on paying ' || bb.number, 'bank', bl.id, m.id, m.id, jsonb_build_array(
          jsonb_build_object('code', '6701', 'debit', v_fee, 'memo', 'Charge on ' || bb.number),
          jsonb_build_object('code', b.ledger_code, 'credit', v_fee, 'memo', bl.description)), v_at,
        jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id))));
    end if;
    update bank_lines set status = 'matched', journal_id = j.id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    return jsonb_build_object('journal_id', j.id, 'settled', bb.number);
  end if;
  raise exception 'Choose the invoice or bill this paid.';
end $$;

-- p: {action: 'approve'|'change'|'ignore'|'dismiss', account_code, party_type, party_id, remember, note,
--     candidate (which of the proposed invoices or bills, 0 first), sale_id | bill_id (the same, by id)}
-- A proposed invoice or bill match, approved, settles that document: the suspense entry is taken back and the payment
-- recorded against it, so the bank moves once and the receivable (or payable) falls. Money in posted to sales without a
-- Counta invoice becomes a sale with its VAT (see private.bank_line_sale).
create or replace function public.resolve_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; m public.members; bl public.bank_lines; v_code text; v_action text := coalesce(nullif(p->>'action', ''), 'approve'); j public.journals;
  b public.bank_accounts; v_amt numeric; v_party_type text := nullif(p->>'party_type', ''); v_party uuid := nullif(p->>'party_id', '')::uuid;
  v_at timestamptz; v_cands jsonb; v_pick jsonb; v_res jsonb; v_i int;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(pr.org_id, 'keep_books');
  if pr.status not in ('pending', 'auto_posted', 'info') then raise exception 'This was already decided.'; end if;
  if v_action = 'dismiss' then
    if pr.status = 'pending' and pr.holding_journal_id is not null then raise exception 'Choose where this goes, or mark it as not a real transaction.'; end if;
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'dismissed');
  end if;
  if pr.source_type <> 'bank_line' then
    raise exception 'Open the % to decide it.', replace(pr.kind, '_', ' ');
  end if;
  select * into bl from bank_lines where id = pr.source_id for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  if v_action = 'ignore' then
    -- Not a real transaction (a duplicate or a reversed transfer on the statement): the suspense entry is taken back.
    if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Not a real transaction: ' || coalesce(p->>'note', ''), null); end if;
    if pr.status = 'auto_posted' and pr.journal_id is not null and not private.undo_bank_line_sale(bl.id, m, 'Not a real transaction') then
      perform private.reverse_entry(pr.journal_id, m.id, 'Not a real transaction', null);
    end if;
    update bank_lines set status = 'ignored', note = nullif(trim(p->>'note'), '') where id = bl.id;
    update ai_proposals set status = 'rejected', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'ignored');
  end if;
  v_at := private.line_time(pr.org_id, bl.line_date);
  -- Confirming one of the invoices or bills the matcher proposed (the first unless another is chosen).
  if pr.status = 'pending' and pr.proposal->>'kind' in ('invoice_match', 'bill_match') and v_action = 'approve'
     and (nullif(p->>'account_code', '') is null or (p->>'account_code' = pr.proposal->>'account_code' and coalesce(p->>'party_id', pr.proposal->>'party_id') = pr.proposal->>'party_id')
          or p ? 'candidate' or p ? 'sale_id' or p ? 'bill_id') then
    v_cands := coalesce(pr.proposal->'candidates',
      jsonb_build_array(jsonb_build_object('kind', case when pr.proposal->>'kind' = 'invoice_match' then 'sale' else 'bill' end,
        'id', coalesce(pr.proposal->>'sale_id', pr.proposal->>'bill_id'), 'number', pr.proposal->>'number', 'party_id', pr.proposal->>'party_id',
        'basis', null)));
    if nullif(p->>'sale_id', '') is not null or nullif(p->>'bill_id', '') is not null then
      select c into v_pick from jsonb_array_elements(v_cands) c where c->>'id' = coalesce(nullif(p->>'sale_id', ''), p->>'bill_id') limit 1;
      if v_pick is null then raise exception 'Choose one of the documents proposed, or say what this payment was.'; end if;
    else
      v_i := coalesce(nullif(p->>'candidate', '')::int, 0);
      v_pick := v_cands->v_i;
      if v_pick is null then raise exception 'Choose one of the documents proposed.'; end if;
    end if;
    v_res := private.apply_match(bl.id, v_pick, m, case when pr.status = 'pending' then pr.holding_journal_id end);
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('chosen', v_pick),
      journal_id = (v_res->>'journal_id')::uuid where id = pr.id;
    return jsonb_build_object('status', 'approved', 'journal_ref', (select ref from journals where id = (v_res->>'journal_id')::uuid), 'settled', v_res->>'settled');
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), pr.proposal->>'account_code');
  if v_code is null or not private.postable(pr.org_id, v_code) or v_code = b.ledger_code then raise exception 'Choose the account this belongs to.'; end if;
  if v_code ~ '^(1101|1102)' and v_party_type is distinct from 'customer' then raise exception 'Say which customer.'; end if;
  if v_code ~ '^(2101|2102)' and v_party_type is distinct from 'vendor' then raise exception 'Say which vendor.'; end if;
  if v_code ~ '^(2201|1402|2202|1401)' then raise exception 'VAT and WHT come only from invoices and bills, not from bank lines.'; end if;
  -- The agent took it as a sale and a person says otherwise: the sale is taken back and the line posted where they say.
  if pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code'
     and private.undo_bank_line_sale(bl.id, m, 'Corrected by ' || coalesce(m.display_name, 'a person')) then
    j := private.post_bank_line(bl.id, v_code, v_party_type, v_party, bl.description, 'user', jsonb_build_object('matched_by', 'user'));
  -- Money in taken as sales with no Counta invoice behind it: a sale with its VAT, as the business answered for such money.
  elsif bl.amount > 0 and private.is_sales_account(pr.org_id, v_code) and private.vat_on_sales(pr.org_id)
     and ((pr.status = 'pending' and pr.holding_journal_id is not null) or (pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code')) then
    perform private.reverse_entry(case when pr.status = 'pending' then pr.holding_journal_id else pr.journal_id end, m.id, 'Taken as a sale with VAT', null);
    update bank_lines set status = 'unmatched', journal_id = null where id = bl.id;
    j := private.bank_line_sale(bl.id, v_code, v_party_type, v_party, 'user', jsonb_build_object('matched_by', 'user'), m);
  elsif pr.status = 'pending' and pr.holding_journal_id is not null then
    -- Out of suspense into the account chosen.
    j := private.post_entry(pr.org_id, 'Confirmed: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      case when bl.amount > 0 then jsonb_build_array(
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'debit', v_amt, 'memo', 'Out of suspense'),
          jsonb_build_object('code', v_code, 'credit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description))
        else jsonb_build_array(
          jsonb_build_object('code', v_code, 'debit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description),
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'credit', v_amt, 'memo', 'Out of suspense')) end,
      v_at,
      jsonb_build_object('origin', 'manual', 'ai_confidence', pr.confidence, 'ai_proposal_id', pr.id,
        'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', p->>'note'))));
    update bank_lines set status = 'posted', stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code' then
    -- The agent posted it, a person says otherwise: move it.
    j := private.post_entry(pr.org_id, 'Corrected: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      private.reclass_pair(v_code, pr.proposal->>'account_code', case when bl.amount > 0 then -v_amt else v_amt end, null, null), now(),
      jsonb_build_object('origin', 'manual', 'ai_proposal_id', pr.id));
  end if;
  update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('account_code', v_code),
    journal_id = coalesce(j.id, journal_id) where id = pr.id;
  -- Learn the party for next time (CLS-05).
  if coalesce((p->>'remember')::boolean, false) and bl.party_key is not null then
    insert into entity_rules (org_id, party_key, direction, account_code, vendor_id, customer_id, note, source, created_by)
    values (pr.org_id, bl.party_key, case when bl.amount > 0 then 'in' else 'out' end, v_code,
      case when v_party_type = 'vendor' then v_party end, case when v_party_type = 'customer' then v_party end, nullif(trim(p->>'note'), ''), 'reviewer', m.id)
    on conflict (org_id, party_key, direction) do update set account_code = excluded.account_code, vendor_id = excluded.vendor_id, customer_id = excluded.customer_id,
      note = coalesce(excluded.note, entity_rules.note);
  end if;
  return jsonb_build_object('status', 'approved', 'journal_ref', j.ref);
end $$;

-- ---------------------------------------------------------------------------
-- 3. VAT from sales schedules, purchase invoices and money received without a Counta invoice
-- ---------------------------------------------------------------------------
-- A business whose sales are recorded in another POS uploads the system's transactions schedule (CSV or Excel). Counta asks
-- once per upload whether the amounts already include VAT. If they do, the VAT is worked back (amount / 1.075 is the
-- price before VAT); if not, VAT is added on top at 7.5% and, as the customer was not charged it, the business bears it.
-- Each line's VAT treatment comes from the product it names (a Counta item of that name), else from the VAT engine (Numens,
-- or Gemini until Numens is connected), else standard. The schedule posts as one sale per day (and customer, when the
-- schedule names customers), so the VAT return and its NRS schedules are built from it like any other sale. A line that
-- looks like payment of one of the business's own invoices is put to the person as that instead of a new sale.
-- Input VAT is claimed on uploaded purchase invoices that show VAT (read by the AI, checked by a person), and money into a
-- bank account posted to sales with no Counta invoice behind it becomes a sale with VAT the same way.
alter table public.sales drop constraint if exists sales_channel_check;
alter table public.sales add constraint sales_channel_check
  check (channel in ('till', 'invoice', 'online', 'whatsapp', 'van', 'phone', 'voice', 'api', 'import', 'schedule', 'bank'));
alter table public.orgs add column if not exists vat_on_receipts text check (vat_on_receipts in ('inclusive', 'exclusive'));
alter table public.orgs add column if not exists receipts_vat_treatment text not null default 'standard' check (receipts_vat_treatment in ('standard', 'zero', 'exempt'));

create table if not exists public.sales_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  file_name text,
  source text,
  vat_inclusive boolean not null,
  location_id uuid references public.locations(id) on delete set null,
  settle_to uuid references public.bank_accounts(id) on delete set null,
  status text not null default 'draft' check (status in ('draft', 'posted', 'void')),
  date_from date,
  date_to date,
  line_count int not null default 0,
  amount numeric(16,2) not null default 0,
  net numeric(16,2) not null default 0,
  vat numeric(16,2) not null default 0,
  sale_ids uuid[] not null default '{}',
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_by uuid references public.members(id) on delete set null,
  posted_at timestamptz,
  voided_by uuid references public.members(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  unique (org_id, number)
);
create index if not exists sales_schedules_location_fk on public.sales_schedules(location_id);
create index if not exists sales_schedules_settle_fk on public.sales_schedules(settle_to);
create index if not exists sales_schedules_created_by_fk on public.sales_schedules(created_by);
create index if not exists sales_schedules_posted_by_fk on public.sales_schedules(posted_by);
create index if not exists sales_schedules_voided_by_fk on public.sales_schedules(voided_by);

create table if not exists public.sales_schedule_lines (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.sales_schedules(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  row_no int not null,
  line_date date not null,
  description text not null,
  reference text,
  customer_name text,
  customer_tin text,
  method text not null default 'other' check (method in ('cash', 'card', 'transfer', 'pos', 'other')),
  amount numeric(16,2) not null,
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard', 'zero', 'exempt')),
  treatment_source text not null default 'default' check (treatment_source in ('item', 'engine', 'person', 'default')),
  item_id uuid references public.items(id) on delete set null,
  nrs_label text,
  net numeric(16,2) not null default 0,
  vat numeric(16,2) not null default 0,
  excluded boolean not null default false,
  exclude_reason text,
  invoice_id uuid references public.sales(id) on delete set null,
  invoice_basis jsonb,
  use_invoice boolean not null default false,
  sale_id uuid references public.sales(id) on delete set null
);
create index if not exists sales_schedule_lines_schedule on public.sales_schedule_lines(schedule_id, row_no);
create index if not exists sales_schedule_lines_org on public.sales_schedule_lines(org_id, line_date);
create index if not exists sales_schedule_lines_item_fk on public.sales_schedule_lines(item_id);
create index if not exists sales_schedule_lines_invoice_fk on public.sales_schedule_lines(invoice_id);
create index if not exists sales_schedule_lines_sale_fk on public.sales_schedule_lines(sale_id);
alter table public.sales_schedules enable row level security;
alter table public.sales_schedule_lines enable row level security;
drop policy if exists sales_schedules_read on public.sales_schedules;
create policy sales_schedules_read on public.sales_schedules for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists sales_schedule_lines_read on public.sales_schedule_lines;
create policy sales_schedule_lines_read on public.sales_schedule_lines for select to authenticated using ((select private.can_handle_money(org_id)));
revoke insert, update, delete on public.sales_schedules, public.sales_schedule_lines from anon, authenticated;
revoke all on public.sales_schedules, public.sales_schedule_lines from anon;
grant select on public.sales_schedules, public.sales_schedule_lines to authenticated;

create or replace function private.is_sales_account(p_org uuid, p_code text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_code ~ '^41(0[1-9]|1[0-9]|2[01])($|-)', false)
$$;
create or replace function private.vat_on_sales(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select vat_registered from orgs where id = p_org), false)
$$;
create or replace function private.main_location(p_org uuid) returns uuid
language sql stable security definer set search_path = public, private as $$
  select id from locations where org_id = p_org order by is_main desc, created_at limit 1
$$;

-- Who may load sales schedules and purchase invoices for VAT: someone who keeps the books or files tax.
create or replace function private.require_vat_work(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')) then
    raise exception 'Only someone who keeps the books or files tax does this.' using errcode = '42501';
  end if;
  return m;
end $$;

-- How the business answered for money received without a Counta invoice: whether the amounts include VAT, and the VAT
-- treatment of what it sells. p: {vat_on_receipts: 'inclusive'|'exclusive', receipts_vat_treatment}
create or replace function public.set_receipts_vat(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require_vat_work(p_org);
  if p ? 'vat_on_receipts' and coalesce(p->>'vat_on_receipts', '') not in ('inclusive', 'exclusive') then raise exception 'Say whether the amounts include VAT.'; end if;
  if p ? 'receipts_vat_treatment' and coalesce(p->>'receipts_vat_treatment', '') not in ('standard', 'zero', 'exempt') then raise exception 'Choose standard, zero-rated or exempt.'; end if;
  update orgs set vat_on_receipts = coalesce(nullif(p->>'vat_on_receipts', ''), vat_on_receipts),
    receipts_vat_treatment = coalesce(nullif(p->>'receipts_vat_treatment', ''), receipts_vat_treatment)
  where id = p_org returning * into o;
  return jsonb_build_object('vat_on_receipts', o.vat_on_receipts, 'receipts_vat_treatment', o.receipts_vat_treatment);
end $$;

-- Money into a bank account posted to sales with no Counta invoice behind it: a sale (channel 'bank') with its VAT,
-- worked back from the amount or added on top as the business answered, so the VAT return counts it.
create or replace function private.bank_line_sale(p_line uuid, p_account text, p_party_type text, p_party uuid, p_stage text, p_meta jsonb,
  m public.members) returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; o public.orgs; s public.sales; j public.journals; v_amt numeric; v_rate numeric; v_net numeric; v_vat numeric;
  v_absorbed numeric; v_cust uuid; v_name text; v_treat text; v_incl boolean;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  select * into o from orgs where id = bl.org_id;
  v_amt := abs(bl.amount);
  v_treat := coalesce(o.receipts_vat_treatment, 'standard');
  v_incl := coalesce(o.vat_on_receipts, 'inclusive') = 'inclusive';
  v_rate := case when v_treat = 'standard' then private.vat_rate(bl.line_date) else 0 end;
  if v_incl then v_net := round(v_amt / (1 + v_rate), 2); v_vat := v_amt - v_net; v_absorbed := 0;
  else v_net := v_amt; v_vat := round(v_amt * v_rate, 2); v_absorbed := v_vat; end if;
  v_cust := case when p_party_type = 'customer' and p_party is not null and exists (select 1 from customers where id = p_party and org_id = bl.org_id) then p_party
             else private.walk_in(bl.org_id) end;
  select name into v_name from customers where id = v_cust;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, location_id, channel, issue_date, prices_include_vat, vat_registered,
    subtotal, vat_total, total, amount_paid, reference, notes, created_by, issued_at)
  values (bl.org_id, 'receipt', private.doc_number(bl.org_id, 'receipt'), 'paid', v_cust, v_name, private.main_location(bl.org_id), 'bank', bl.line_date, v_incl, true,
    v_net, v_vat, v_net + v_vat, v_net + v_vat, nullif(left(coalesce(bl.reference, ''), 60), ''),
    left('Received into ' || b.name || ' with no Counta invoice: ' || coalesce(nullif(bl.description, ''), 'payment'), 300), m.id, now())
  returning * into s;
  insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account, nrs_vat_label)
  values (s.id, bl.org_id, 1, 'goods', left(coalesce(nullif(trim(bl.description), ''), 'Sale'), 300), 1, 'sale', v_net, v_treat, v_rate, v_net, v_vat, v_net + v_vat, p_account,
    case when v_treat <> 'standard' then private.nrs_label_guess(v_treat, bl.description) end);
  j := private.post_entry(bl.org_id, 'Sale ' || s.number || ' · received with no invoice · ' || left(coalesce(bl.description, ''), 80), 'sale', s.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', '6512', 'debit', v_absorbed, 'memo', 'VAT on ' || s.number || ' not charged to the customer'),
      jsonb_build_object('code', p_account, 'credit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || v_name),
      jsonb_build_object('code', private.acct(bl.org_id, 'output_vat'), 'credit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id,
        'memo', 'Output VAT ' || s.number)),
    private.line_time(bl.org_id, bl.line_date),
    coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source,
      'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'stage', p_stage), jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = s.id;
  perform private.queue_sale_vat_move(s.id, b.id);
  update bank_lines set status = 'posted', journal_id = j.id, stage = p_stage,
    matched_by = coalesce(nullif(p_meta->>'matched_by', ''), case when p_stage = 'ai' then 'ai' when p_stage = 'user' then 'user' else 'rule' end),
    confidence = coalesce(nullif(p_meta->>'ai_confidence', '')::numeric, 1)
  where id = bl.id;
  return j;
end $$;

-- The VAT treatment of a schedule line from the business's own products: an item of that name, SKU or barcode.
-- Takes back a sale that was posted from a bank line (a person says the line was something else, or not real): the entry
-- is reversed, the receipt voided so it leaves the VAT return, and VAT not yet moved to the tax wallet stays where it is.
-- Returns false when the line's entry is not such a sale.
create or replace function private.undo_bank_line_sale(p_line uuid, m public.members, p_reason text) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; s public.sales;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.journal_id is null then return false; end if;
  select * into s from sales where journal_id = bl.journal_id and channel = 'bank' and doc_type = 'receipt' for update;
  if s.id is null then return false; end if;
  if exists (select 1 from vat_periods where org_id = s.org_id and period = date_trunc('month', s.issue_date)::date and status in ('filed', 'paid')) then
    raise exception 'The % VAT return including this sale is filed. Reopen it first.', to_char(s.issue_date, 'FMMonth YYYY');
  end if;
  perform private.reverse_entry(s.journal_id, m.id, left(coalesce(p_reason, 'Taken back'), 200), null);
  update sales set status = 'void', voided_by = m.id, voided_at = now(), void_reason = left(coalesce(p_reason, 'Taken back'), 300) where id = s.id;
  update tax_moves set status = 'cancelled' where source_type = 'sale' and source_id = s.id and status = 'pending';
  update bank_lines set status = 'unmatched', journal_id = null where id = bl.id;
  return true;
end $$;

create or replace function private.schedule_item(p_org uuid, p_text text, p_ref text) returns public.items
language sql stable security definer set search_path = public, private as $$
  select i.* from items i where i.org_id = p_org and coalesce(i.archived, false) = false and (lower(i.name) = lower(trim(coalesce(p_text, '')))
    or (nullif(trim(coalesce(p_ref, '')), '') is not null and (i.sku = trim(p_ref) or i.barcode = trim(p_ref))))
  order by (lower(i.name) = lower(trim(coalesce(p_text, '')))) desc limit 1
$$;

create or replace function private.schedule_json(p_schedule uuid, p_lines boolean default true) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(sc) || jsonb_build_object(
    'created_by_name', (select display_name from members where id = sc.created_by),
    'posted_by_name', (select display_name from members where id = sc.posted_by),
    'location_name', (select name from locations where id = sc.location_id),
    'settle_to_name', (select name from bank_accounts where id = sc.settle_to),
    'by_month', (select coalesce(jsonb_agg(jsonb_build_object('month', mth, 'lines', n, 'amount', amt, 'net', net, 'vat', vat,
        'standard', std, 'zero', zero, 'exempt', exempt) order by mth), '[]'::jsonb)
      from (select date_trunc('month', line_date)::date mth, count(*) n, sum(amount) amt, sum(net) net, sum(vat) vat,
              sum(net) filter (where vat_treatment = 'standard') std, sum(net) filter (where vat_treatment = 'zero') zero,
              sum(net) filter (where vat_treatment = 'exempt') exempt
            from sales_schedule_lines where schedule_id = sc.id and not excluded and not use_invoice group by 1) z),
    'counts', (select jsonb_build_object('included', count(*) filter (where not excluded and not use_invoice), 'excluded', count(*) filter (where excluded),
        'invoice_payments', count(*) filter (where use_invoice and not excluded), 'invoice_candidates', count(*) filter (where invoice_id is not null),
        'guessed', count(*) filter (where treatment_source = 'default' and not excluded and not use_invoice),
        'zero', count(*) filter (where vat_treatment = 'zero' and not excluded and not use_invoice),
        'exempt', count(*) filter (where vat_treatment = 'exempt' and not excluded and not use_invoice))
      from sales_schedule_lines where schedule_id = sc.id),
    'lines', case when p_lines then (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('invoice_number', (select number from sales where id = l.invoice_id),
        'sale_number', (select number from sales where id = l.sale_id)) order by l.row_no), '[]'::jsonb)
      from (select * from sales_schedule_lines where schedule_id = sc.id order by excluded, (invoice_id is null), row_no limit 3000) l) end)
  from sales_schedules sc where sc.id = p_schedule
$$;

-- A schedule as uploaded, kept as a draft to review. p: {id?, file_name, source, vat_inclusive, location_id, settle_to,
-- lines: [{row, date, description, reference, customer, customer_tin, amount, method, vat_treatment?, treatment_source?, nrs_label?}]}
create or replace function public.save_sales_schedule(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; sc public.sales_schedules; x jsonb; v_n int := 0; v_day date; v_amt numeric; v_desc text; v_treat text; v_src text;
  it public.items; v_rate numeric; v_net numeric; v_vat numeric; v_incl boolean; v_today date; v_cands jsonb; v_excl boolean; v_reason text; v_method text;
  v_label text; v_id uuid := nullif(p->>'id', '')::uuid; v_loc uuid; v_settle uuid; v_dup uuid;
begin
  m := private.require_vat_work(p_org);
  select * into o from orgs where id = p_org;
  if not o.vat_registered then raise exception 'Turn on charging VAT (Tax returns, VAT) before loading sales for the VAT return.'; end if;
  if coalesce(jsonb_typeof(p->'vat_inclusive'), '') <> 'boolean' then raise exception 'Say whether the amounts already include VAT.'; end if;
  v_incl := (p->>'vat_inclusive')::boolean;
  if coalesce(jsonb_typeof(p->'lines'), '') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'The schedule has no lines.'; end if;
  if jsonb_array_length(p->'lines') > 20000 then raise exception 'Load at most 20,000 lines at a time. Split the schedule by month.'; end if;
  v_loc := coalesce((select id from locations where id = nullif(p->>'location_id', '')::uuid and org_id = p_org), private.main_location(p_org));
  v_settle := (select id from bank_accounts where id = nullif(p->>'settle_to', '')::uuid and org_id = p_org and active);
  v_today := private.local_day(p_org, now());
  if v_id is not null then
    select * into sc from sales_schedules where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Schedule not found.'; end if;
    if sc.status <> 'draft' then raise exception '% is already posted.', sc.number; end if;
    delete from sales_schedule_lines where schedule_id = sc.id;
    update sales_schedules set file_name = coalesce(nullif(p->>'file_name', ''), file_name), source = nullif(left(trim(coalesce(p->>'source', '')), 80), ''),
      vat_inclusive = v_incl, location_id = v_loc, settle_to = v_settle where id = sc.id returning * into sc;
  else
    insert into sales_schedules (org_id, number, file_name, source, vat_inclusive, location_id, settle_to, created_by)
    values (p_org, 'SCH-' || lpad(private.next_no(p_org, 'SCH', 1)::text, 4, '0'), nullif(left(coalesce(p->>'file_name', ''), 200), ''),
      nullif(left(trim(coalesce(p->>'source', '')), 80), ''), v_incl, v_loc, v_settle, m.id)
    returning * into sc;
  end if;
  for x in select * from jsonb_array_elements(p->'lines') loop
    v_n := v_n + 1;
    begin v_day := nullif(x->>'date', '')::date; exception when others then v_day := null; end;
    v_amt := round(private.num(x->>'amount'), 2);
    v_desc := left(coalesce(nullif(trim(x->>'description'), ''), 'Sale'), 300);
    v_excl := false; v_reason := null;
    if v_day is null then raise exception 'Row %: the date is missing or not a date.', coalesce(x->>'row', v_n::text); end if;
    if v_day > v_today + 1 or v_day < date '2000-01-01' then raise exception 'Row %: % is not a date this schedule can have.', coalesce(x->>'row', v_n::text), v_day; end if;
    if v_amt is null then raise exception 'Row %: the amount is missing.', coalesce(x->>'row', v_n::text); end if;
    if v_amt <= 0 then v_excl := true; v_reason := case when v_amt = 0 then 'Nothing was paid' else 'A refund: record it as a credit note' end; end if;
    v_method := case lower(coalesce(x->>'method', '')) when 'cash' then 'cash' when 'card' then 'card' when 'transfer' then 'transfer' when 'pos' then 'pos' else 'other' end;
    -- The product decides the treatment; then the VAT engine's answer the page sends; then standard.
    it := private.schedule_item(p_org, v_desc, x->>'reference');
    if it.id is not null then v_treat := coalesce(it.vat_treatment, 'standard'); v_src := 'item'; v_label := it.nrs_vat_label;
    elsif coalesce(x->>'vat_treatment', '') in ('standard', 'zero', 'exempt') then
      v_treat := x->>'vat_treatment'; v_src := case when x->>'treatment_source' = 'person' then 'person' else 'engine' end; v_label := nullif(x->>'nrs_label', '');
    else v_treat := 'standard'; v_src := 'default'; v_label := null; end if;
    if v_treat <> 'standard' and v_label is null then v_label := private.nrs_label_guess(v_treat, v_desc); end if;
    v_rate := case when v_treat = 'standard' then private.vat_rate(v_day) else 0 end;
    if v_incl then v_net := round(greatest(v_amt, 0) / (1 + v_rate), 2); v_vat := greatest(v_amt, 0) - v_net;
    else v_net := greatest(v_amt, 0); v_vat := round(greatest(v_amt, 0) * v_rate, 2); end if;
    -- Loaded before in a posted schedule (same day, amount, reference and description): left out.
    if not v_excl then
      select l.id into v_dup from sales_schedule_lines l join sales_schedules s2 on s2.id = l.schedule_id
      where l.org_id = p_org and s2.status = 'posted' and l.line_date = v_day and l.amount = v_amt and l.description = v_desc
        and coalesce(l.reference, '') = coalesce(nullif(trim(x->>'reference'), ''), '') and not l.excluded limit 1;
      if v_dup is not null then v_excl := true; v_reason := 'Already loaded in an earlier schedule'; end if;
    end if;
    -- Payment of one of the business's own invoices? Only with a customer's name or the invoice's number to go on.
    v_cands := null;
    if not v_excl and (nullif(trim(x->>'customer'), '') is not null or nullif(trim(x->>'reference'), '') is not null) then
      v_cands := private.invoice_candidates(p_org, v_amt, coalesce(x->>'customer', '') || ' ' || coalesce(x->>'reference', '') || ' ' || v_desc, v_day);
      v_cands := (select c from jsonb_array_elements(v_cands) c where c->>'kind' = 'sale' and (c->>'score')::numeric >= 60 and c->>'basis' in ('exact', 'less_wht', 'bank_charge', 'less_wht_charge')
                  order by (c->>'score')::numeric desc limit 1);
    end if;
    insert into sales_schedule_lines (schedule_id, org_id, row_no, line_date, description, reference, customer_name, customer_tin, method, amount, vat_treatment,
      treatment_source, item_id, nrs_label, net, vat, excluded, exclude_reason, invoice_id, invoice_basis, use_invoice)
    values (sc.id, p_org, coalesce(nullif(x->>'row', '')::int, v_n), v_day, v_desc, nullif(left(trim(coalesce(x->>'reference', '')), 120), ''),
      nullif(left(trim(coalesce(x->>'customer', '')), 160), ''), nullif(regexp_replace(coalesce(x->>'customer_tin', ''), '[^0-9-]', '', 'g'), ''), v_method, v_amt,
      v_treat, v_src, it.id, v_label, v_net, v_vat, v_excl, v_reason, (v_cands->>'id')::uuid, v_cands, v_cands is not null);
  end loop;
  perform private.schedule_totals(sc.id);
  return private.schedule_json(sc.id);
end $$;

create or replace function private.schedule_totals(p_schedule uuid) returns void
language sql security definer set search_path = public, private as $$
  update sales_schedules sc set line_count = x.n, amount = x.amt, net = x.net, vat = x.vat, date_from = x.f, date_to = x.t
  from (select count(*) n, coalesce(sum(amount), 0) amt, coalesce(sum(net), 0) net, coalesce(sum(vat), 0) vat, min(line_date) f, max(line_date) t
        from sales_schedule_lines where schedule_id = p_schedule and not excluded and not use_invoice) x
  where sc.id = p_schedule
$$;

-- A person changes one line before posting. p: {vat_treatment, excluded, use_invoice}
create or replace function public.update_schedule_line(p_line uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.sales_schedule_lines; sc public.sales_schedules; m public.members; v_rate numeric; v_net numeric; v_vat numeric; v_treat text;
begin
  select * into l from sales_schedule_lines where id = p_line for update;
  if not found then raise exception 'Line not found.'; end if;
  m := private.require_vat_work(l.org_id);
  select * into sc from sales_schedules where id = l.schedule_id;
  if sc.status <> 'draft' then raise exception '% is already posted.', sc.number; end if;
  v_treat := coalesce(nullif(p->>'vat_treatment', ''), l.vat_treatment);
  if v_treat not in ('standard', 'zero', 'exempt') then raise exception 'Choose standard, zero-rated or exempt.'; end if;
  if coalesce((p->>'use_invoice')::boolean, false) and l.invoice_id is null then raise exception 'Counta found no invoice this line pays.'; end if;
  v_rate := case when v_treat = 'standard' then private.vat_rate(l.line_date) else 0 end;
  if sc.vat_inclusive then v_net := round(greatest(l.amount, 0) / (1 + v_rate), 2); v_vat := greatest(l.amount, 0) - v_net;
  else v_net := greatest(l.amount, 0); v_vat := round(greatest(l.amount, 0) * v_rate, 2); end if;
  update sales_schedule_lines set vat_treatment = v_treat, treatment_source = case when p ? 'vat_treatment' then 'person' else treatment_source end,
    nrs_label = case when v_treat = 'standard' then null when v_treat <> l.vat_treatment then private.nrs_label_guess(v_treat, l.description) else nrs_label end,
    net = v_net, vat = v_vat,
    excluded = case when p ? 'excluded' then coalesce((p->>'excluded')::boolean, excluded) else excluded end,
    exclude_reason = case when p ? 'excluded' then case when (p->>'excluded')::boolean then coalesce(exclude_reason, 'Left out by ' || m.display_name) end else exclude_reason end,
    use_invoice = case when p ? 'use_invoice' then coalesce((p->>'use_invoice')::boolean, false) else use_invoice end
  where id = l.id returning * into l;
  if l.amount <= 0 and not l.excluded then raise exception 'Refunds and empty lines cannot go in as sales.'; end if;
  perform private.schedule_totals(sc.id);
  return to_jsonb(l) || jsonb_build_object('schedule', private.schedule_json(sc.id, false));
end $$;

-- Where cash taken at another POS goes: the location's cash drawer, else the business's cash account, else a new one.
create or replace function private.schedule_cash_account(p_org uuid, p_location uuid, m public.members) returns public.bank_accounts
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  select * into b from bank_accounts where org_id = p_org and kind = 'cash' and active
  order by (location_id is not distinct from p_location) desc, (location_id is null) desc, created_at limit 1;
  if b.id is null then
    b := private.open_bank_account(p_org, 'cash', 'Cash from sales schedules', '{}'::jsonb, m.id);
  end if;
  return b;
end $$;

-- Posts a reviewed schedule: one sale per day (and customer, where the schedule names customers), paid into the account
-- chosen (or held as payments being confirmed until the bank shows them; cash as cash in the till); the VAT not charged to
-- customers, when amounts excluded it, is the business's cost. Lines paying the business's own invoices settle those.
create or replace function public.post_sales_schedule(p_schedule uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare sc public.sales_schedules; m public.members; g record; s public.sales; j public.journals; v_cust uuid; v_name text; v_lines jsonb; v_no int; ln record;
  v_settle text; v_cash text; v_sales uuid[] := '{}'; v_jl jsonb; v_rev text; v_vat_acct text; l public.sales_schedule_lines; inv public.sales; c public.collections;
  v_split jsonb; v_due numeric; v_method text; v_bank uuid; v_cash_acct public.bank_accounts;
begin
  select * into sc from sales_schedules where id = p_schedule for update;
  if not found then raise exception 'Schedule not found.'; end if;
  m := private.require_vat_work(sc.org_id);
  if sc.status <> 'draft' then raise exception '% is already %.', sc.number, sc.status; end if;
  if not exists (select 1 from sales_schedule_lines where schedule_id = sc.id and not excluded) then raise exception 'Every line is left out: nothing to post.'; end if;
  for g in select distinct line_date from sales_schedule_lines where schedule_id = sc.id and not excluded loop
    perform private.require_open_day(sc.org_id, g.line_date);
  end loop;
  v_settle := coalesce((select ledger_code from bank_accounts where id = sc.settle_to), private.acct(sc.org_id, 'bank_clearing'));
  if exists (select 1 from sales_schedule_lines where schedule_id = sc.id and not excluded and method = 'cash') then
    v_cash_acct := private.schedule_cash_account(sc.org_id, sc.location_id, m);
    v_cash := v_cash_acct.ledger_code;
  end if;
  v_rev := private.acct(sc.org_id, 'sales_revenue');
  v_vat_acct := private.acct(sc.org_id, 'output_vat');
  -- Sales: by day and customer.
  for g in select line_date, lower(coalesce(customer_name, '')) ckey, min(customer_name) customer_name, min(customer_tin) customer_tin,
             sum(net) net, sum(vat) vat, sum(amount) amount,
             sum(amount) filter (where method = 'cash') cash_amt, sum(amount) filter (where method <> 'cash') other_amt
           from sales_schedule_lines where schedule_id = sc.id and not excluded and not use_invoice
           group by line_date, lower(coalesce(customer_name, '')) order by line_date, 2 loop
    if g.ckey = '' then v_cust := private.walk_in(sc.org_id);
    else
      select id into v_cust from customers where org_id = sc.org_id and not is_walk_in and lower(name) = g.ckey limit 1;
      if v_cust is null then
        insert into customers (org_id, name, kind, tin) values (sc.org_id, left(trim(g.customer_name), 120), case when g.customer_tin is not null then 'business' else 'individual' end,
          g.customer_tin) returning id into v_cust;
      end if;
    end if;
    select name into v_name from customers where id = v_cust;
    insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_tin, location_id, channel, issue_date, prices_include_vat, vat_registered,
      subtotal, vat_total, total, amount_paid, reference, notes, created_by, issued_at)
    values (sc.org_id, 'receipt', private.doc_number(sc.org_id, 'receipt'), 'paid', v_cust, v_name, g.customer_tin, coalesce(sc.location_id, private.main_location(sc.org_id)),
      'schedule', g.line_date, sc.vat_inclusive, true, g.net, g.vat, g.net + g.vat, g.net + g.vat, sc.number,
      left('From sales schedule ' || sc.number || coalesce(' (' || sc.file_name || ')', ''), 300), m.id, now())
    returning * into s;
    v_no := 0;
    for ln in select description, vat_treatment, nrs_label, min(item_id::text)::uuid item_id, count(*) n, sum(net) net, sum(vat) vat
              from sales_schedule_lines where schedule_id = sc.id and not excluded and not use_invoice and line_date = g.line_date
                and lower(coalesce(customer_name, '')) = g.ckey
              group by description, vat_treatment, nrs_label order by description loop
      v_no := v_no + 1;
      insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account,
        nrs_vat_label)
      values (s.id, sc.org_id, v_no, 'goods', null, ln.description, ln.n, 'sale', round(ln.net / ln.n, 2), ln.vat_treatment,
        case when ln.vat_treatment = 'standard' then private.vat_rate(g.line_date) else 0 end, ln.net, ln.vat, ln.net + ln.vat, v_rev, ln.nrs_label);
    end loop;
    v_jl := jsonb_build_array(
      jsonb_build_object('code', coalesce(v_cash, v_settle), 'debit', coalesce(g.cash_amt, 0), 'memo', s.number || ' cash'),
      jsonb_build_object('code', v_settle, 'debit', coalesce(g.other_amt, 0), 'memo', s.number || ' paid by card, transfer or POS'),
      jsonb_build_object('code', '6512', 'debit', case when sc.vat_inclusive then 0 else g.vat end, 'memo', 'VAT on ' || s.number || ' not charged to customers'),
      jsonb_build_object('code', v_rev, 'credit', g.net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || v_name),
      jsonb_build_object('code', v_vat_acct, 'credit', g.vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', 'Output VAT ' || s.number));
    j := private.post_entry(sc.org_id, 'Sales ' || s.number || ' · ' || to_char(g.line_date, 'DD Mon YYYY') || ' from ' || sc.number, 'sale', s.id, m.id, m.id, v_jl,
      private.posting_time(sc.org_id, g.line_date),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sales_schedule', 'id', sc.id, 'ref', sc.number), jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
    update sales set journal_id = j.id where id = s.id;
    update sales_schedule_lines set sale_id = s.id where schedule_id = sc.id and not excluded and not use_invoice and line_date = g.line_date
      and lower(coalesce(customer_name, '')) = g.ckey;
    v_sales := v_sales || s.id;
  end loop;
  -- Lines paying the business's own invoices: recorded against them, waiting for the bank to confirm (cash straight in).
  for l in select * from sales_schedule_lines where schedule_id = sc.id and not excluded and use_invoice and invoice_id is not null order by row_no loop
    select * into inv from sales where id = l.invoice_id for update;
    continue when inv.id is null or inv.status not in ('open', 'partially_paid');
    v_due := inv.total - inv.amount_paid - inv.credited;
    v_split := private.customer_short_split(inv.id, v_due, l.amount);
    if v_split is not null then perform private.book_customer_withholding(sc.org_id, inv.customer_id, inv.id, v_split, private.posting_time(sc.org_id, l.line_date), m); end if;
    v_method := case l.method when 'cash' then 'cash' when 'card' then 'card' when 'pos' then 'pos' when 'transfer' then 'transfer' else 'other' end;
    v_bank := case when l.method = 'cash' then v_cash_acct.id else sc.settle_to end;
    c := private.add_collection(sc.org_id, inv.customer_id, l.amount, v_method, jsonb_build_object('bank_account_id', v_bank, 'received_at', private.posting_time(sc.org_id, l.line_date),
      'reference', coalesce(l.reference, sc.number), 'note', 'From sales schedule ' || sc.number || ', row ' || l.row_no, 'spread', false), m,
      case when v_bank is not null then 'confirmed' else 'pending' end, array[inv.id]);
    update sales_schedule_lines set sale_id = inv.id where id = l.id;
  end loop;
  update sales_schedules set status = 'posted', posted_by = m.id, posted_at = now(), sale_ids = v_sales where id = sc.id returning * into sc;
  return private.schedule_json(sc.id, false);
end $$;

-- Takes a posted schedule back: its sales are voided and their entries reversed. Payments it recorded against invoices stay
-- (reverse those from the invoice if they were wrong).
create or replace function public.void_sales_schedule(p_schedule uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare sc public.sales_schedules; m public.members; s public.sales;
begin
  select * into sc from sales_schedules where id = p_schedule for update;
  if not found then raise exception 'Schedule not found.'; end if;
  m := private.require_vat_work(sc.org_id);
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Say why.'; end if;
  if sc.status = 'void' then raise exception '% is already taken back.', sc.number; end if;
  if sc.status = 'draft' then
    delete from sales_schedules where id = sc.id;
    return jsonb_build_object('deleted', true);
  end if;
  for s in select * from sales where id = any(sc.sale_ids) for update loop
    if exists (select 1 from vat_periods where org_id = sc.org_id and period = date_trunc('month', s.issue_date)::date) then
      raise exception 'The % VAT return including these sales is filed. Reopen it first.', to_char(s.issue_date, 'FMMonth YYYY');
    end if;
    perform private.require_open_day(sc.org_id, s.issue_date);
    if s.journal_id is not null then perform private.reverse_entry(s.journal_id, m.id, 'Sales schedule ' || sc.number || ' taken back: ' || p_reason, null); end if;
    update sales set status = 'void', voided_by = m.id, voided_at = now(), void_reason = left(p_reason, 300) where id = s.id;
  end loop;
  update sales_schedules set status = 'void', voided_by = m.id, voided_at = now(), void_reason = left(p_reason, 300) where id = sc.id returning * into sc;
  return private.schedule_json(sc.id, false);
end $$;

create or replace function public.get_sales_schedules(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see VAT work.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  return jsonb_build_object('schedules', (select coalesce(jsonb_agg(private.schedule_json(id, false) order by created_at desc), '[]'::jsonb)
      from (select id, created_at from sales_schedules where org_id = p_org order by created_at desc limit 60) x),
    'settings', jsonb_build_object('vat_on_receipts', o.vat_on_receipts, 'receipts_vat_treatment', o.receipts_vat_treatment, 'vat_registered', o.vat_registered),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind) order by kind, name), '[]'::jsonb)
      from bank_accounts where org_id = p_org and active),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'vendor', v.name, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date,
        'net', b.subtotal, 'vat', b.vat_total, 'total', b.total, 'status', b.status, 'document_path', b.document_path) order by b.created_at desc), '[]'::jsonb)
      from (select * from bills where org_id = p_org and source = 'ai' and notes like 'Input VAT claim%' order by created_at desc limit 100) b join vendors v on v.id = b.vendor_id),
    'can', jsonb_build_object('work', private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')));
end $$;

create or replace function public.get_sales_schedule(p_schedule uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare sc public.sales_schedules;
begin
  select * into sc from sales_schedules where id = p_schedule;
  if not found then raise exception 'Schedule not found.'; end if;
  perform private.require(sc.org_id, null);
  if not private.can_handle_money(sc.org_id) then raise exception 'Your role does not see VAT work.' using errcode = '42501'; end if;
  return private.schedule_json(sc.id);
end $$;

-- A purchase invoice uploaded to claim its input VAT, as read by the AI and checked by a person: a bill for the VAT shown
-- on it, approved and paid from the account the person names (or settling the bank line it was paid by).
-- p: {document_path, supplier_name, supplier_tin, invoice_no, invoice_date, description, net, vat, total, account_code,
--     paid_from (bank_account_id), bank_line_id}
create or replace function public.save_vat_purchase(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_vendor uuid; v_name text := nullif(trim(p->>'supplier_name'), ''); v_tin text := nullif(regexp_replace(coalesce(p->>'supplier_tin', ''), '[^0-9]', '', 'g'), '');
  v_net numeric := round(private.num(p->>'net'), 2); v_vat numeric := round(private.num(p->>'vat'), 2); v_total numeric; v_day date; v_rate numeric; v_vatable numeric;
  v_rest numeric; b public.bills; v_code text; v_lines jsonb; bl public.bank_lines; ba public.bank_accounts; j public.journals; v_old uuid; v_prop public.ai_proposals;
begin
  m := private.require_vat_work(p_org);
  select * into o from orgs where id = p_org;
  if not o.vat_registered then raise exception 'Input VAT is claimed only by a business that charges VAT.'; end if;
  if v_name is null then raise exception 'Name the supplier on the invoice.'; end if;
  if coalesce(v_vat, 0) <= 0 then raise exception 'This invoice shows no VAT, so there is no input VAT to claim.'; end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount before VAT.'; end if;
  v_total := coalesce(round(private.num(p->>'total'), 2), v_net + v_vat);
  if abs(v_total - (v_net + v_vat)) > 1 then raise exception 'The total (%) is not the amount before VAT plus the VAT (%).', private.naira(v_total), private.naira(v_net + v_vat); end if;
  begin v_day := nullif(p->>'invoice_date', '')::date; exception when others then raise exception 'Check the invoice date.'; end;
  if v_day is null then raise exception 'Enter the invoice date.'; end if;
  if v_day > private.local_day(p_org, now()) then raise exception 'The invoice is dated in the future.'; end if;
  v_rate := private.vat_rate(v_day);
  if v_vat > round(v_net * v_rate, 2) + 1 then raise exception 'The VAT (%) is more than % of the amount before VAT. Check the figures.', private.naira(v_vat), (v_rate * 100)::numeric(5,2) || '%'; end if;
  -- The supplier: by Tax ID, else by name, else a new one.
  select id into v_vendor from vendors where org_id = p_org and ((v_tin is not null and length(v_tin) >= 8 and tin = v_tin) or lower(name) = lower(v_name))
  order by (v_tin is not null and tin = v_tin) desc limit 1;
  if v_vendor is null then
    insert into vendors (org_id, name, tin, vat_registered, channel, entity_type) values (p_org, left(v_name, 120), v_tin, true, 'email', 'company') returning id into v_vendor;
  end if;
  if nullif(trim(p->>'invoice_no'), '') is not null and exists (select 1 from bills where org_id = p_org and vendor_id = v_vendor and status <> 'void'
       and lower(vendor_ref) = lower(trim(p->>'invoice_no'))) then
    raise exception 'Invoice % from % is already in the books.', trim(p->>'invoice_no'), v_name;
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), (select default_account from vendors where id = v_vendor),
    case when exists (select 1 from items where org_id = p_org) then private.acct(p_org, 'purchases') else private.acct(p_org, 'expenses_default') end);
  -- The part of the price that carries VAT, from the VAT shown; whatever else is on the invoice carries none.
  v_vatable := least(round(v_vat / v_rate, 2), v_net);
  v_rest := round(v_net - v_vatable, 2);
  v_lines := jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(p->>'description'), ''), 'Purchase'), 300), 'account_code', v_code,
    'qty', 1, 'unit_cost', v_vatable, 'vat_treatment', 'standard'));
  if v_rest >= 0.01 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', 'Part of the invoice with no VAT', 'account_code', v_code, 'qty', 1, 'unit_cost', v_rest,
      'vat_treatment', 'exempt'));
  end if;
  b := private.write_bill(p_org, jsonb_build_object('vendor_id', v_vendor, 'vendor_ref', nullif(trim(p->>'invoice_no'), ''), 'source', 'ai', 'bill_date', v_day,
    'due_date', v_day, 'prices_include_vat', false, 'vat_charged', true, 'wht_category', 'none', 'document_path', nullif(p->>'document_path', ''),
    'notes', 'Input VAT claim from an uploaded invoice', 'lines', v_lines), m);
  -- The VAT as printed (the bill worked it out from the rate; a kobo or two of rounding is the invoice's).
  update bill_lines set vat = v_vat, gross = net + v_vat where bill_id = b.id and line_no = 1;
  update bills set vat_total = (select sum(vat) from bill_lines where bill_id = b.id), total = (select sum(gross) from bill_lines where bill_id = b.id) where id = b.id;
  b := private.post_bill(b.id, m);
  select * into b from bills where id = b.id;
  if nullif(p->>'bank_line_id', '') is not null then
    select * into bl from bank_lines where id = (p->>'bank_line_id')::uuid and org_id = p_org for update;
    if not found or bl.amount >= 0 then raise exception 'Choose the payment out of the bank that paid this invoice.'; end if;
    if bl.status in ('matched', 'ignored') then raise exception 'That bank line is already settled. Choose another.'; end if;
    if abs(abs(bl.amount) - b.total) > greatest(100, b.total * 0.005) then
      raise exception 'The bank line (%) and the invoice (%) differ by more than bank charges.', private.naira(abs(bl.amount)), private.naira(b.total);
    end if;
    -- Whatever the line was posted to before (suspense, or an expense with no VAT) is taken back.
    if bl.journal_id is not null then perform private.reverse_entry(bl.journal_id, m.id, 'Paid ' || b.number || ' with input VAT from the invoice', null); end if;
    update ai_proposals set status = 'superseded' where source_type = 'bank_line' and source_id = bl.id and status in ('pending', 'info', 'auto_posted');
    update bank_lines set status = 'unmatched', journal_id = null, proposal_id = null where id = bl.id;
    perform private.apply_match(bl.id, jsonb_build_object('kind', 'bill', 'id', b.id, 'basis', 'exact'), m, null);
  else
    select * into ba from bank_accounts where id = nullif(p->>'paid_from', '')::uuid and org_id = p_org and active;
    if not found then raise exception 'Say which account paid this invoice.'; end if;
    j := private.record_bill_payment(b.id, ba.id, b.total, 0, private.posting_time(p_org, v_day), coalesce(nullif(trim(p->>'invoice_no'), ''), b.number), m);
  end if;
  select * into b from bills where id = b.id;
  return jsonb_build_object('bill', jsonb_build_object('id', b.id, 'number', b.number, 'status', b.status, 'net', b.subtotal, 'vat', b.vat_total, 'total', b.total),
    'vendor_id', v_vendor);
end $$;

create or replace function private.post_bank_line(p_line uuid, p_account text, p_party_type text, p_party uuid, p_memo text, p_stage text,
  p_meta jsonb, p_status text default 'posted') returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; j public.journals; v_amt numeric;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  if not private.postable(bl.org_id, p_account) then raise exception 'Account % cannot take postings.', p_account; end if;
  if p_account = b.ledger_code then raise exception 'A bank line cannot post to its own account.'; end if;
  v_amt := abs(bl.amount);
  -- Money in taken as sales with no Counta invoice behind it: a sale with its VAT, as the business answered for such money.
  if bl.amount > 0 and p_status = 'posted' and private.is_sales_account(bl.org_id, p_account) and private.vat_on_sales(bl.org_id) then
    return private.bank_line_sale(bl.id, p_account, p_party_type, p_party, p_stage, p_meta, null::public.members);
  end if;
  j := private.post_entry(bl.org_id, coalesce(p_memo, bl.description), 'bank', bl.id, null, null, case when bl.amount > 0 then jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', p_account, 'credit', v_amt, 'party_type', p_party_type, 'party_id', p_party, 'memo', coalesce(p_memo, bl.description)))
    else jsonb_build_array(
      jsonb_build_object('code', p_account, 'debit', v_amt, 'party_type', p_party_type, 'party_id', p_party, 'memo', coalesce(p_memo, bl.description)),
      jsonb_build_object('code', b.ledger_code, 'credit', v_amt, 'memo', bl.description)) end,
    private.line_time(bl.org_id, bl.line_date),
    coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source,
      'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'stage', p_stage))));
  update bank_lines set status = p_status, journal_id = j.id, stage = p_stage,
    matched_by = coalesce(nullif(p_meta->>'matched_by', ''), case when p_stage = 'ai' then 'ai' when p_stage = 'user' then 'user' else 'rule' end),
    confidence = coalesce(nullif(p_meta->>'ai_confidence', '')::numeric, 1)
  where id = bl.id;
  return j;
end $$;


-- ---------------------------------------------------------------------------
-- 4. What needs doing: a count on every menu item, and alerts by the channel each deserves
-- ---------------------------------------------------------------------------
-- Everything that needs someone's action shows as a number beside its menu item and arrives as a push notification. The
-- important ones go further, cheapest first: email, then WhatsApp (a paid utility template), then a call from Martina
-- (the dearest, so only for a tax return due tomorrow, and for customers' overdue invoices when the business asks for it):
--   tax returns due (VAT and WHT on the 21st, CIT six months after the year end): push from a week before; email and WhatsApp
--     three days and one day before, and when late; Martina calls the owner the day before;
--   invoices due and overdue: push every morning; email and WhatsApp once a week (and when an invoice first goes overdue);
--   transactions still to confirm for the month's VAT and WHT returns: push from the 10th; email and WhatsApp on the 15th and 19th;
--   Martina follows up a customer's overdue invoice by phone, after a reminder went unanswered, if the business switched it on.
-- TaxStreem sets all of it in the admin portal (settings key 'alerts'); a business can stop emails, WhatsApp messages and
-- calls to itself, and chooses whether Martina calls its customers.
alter table public.platform_settings drop constraint if exists platform_settings_key_check;
alter table public.platform_settings add constraint platform_settings_key_check check (key in ('martina', 'limits', 'switches', 'alerts'));

alter table public.orgs add column if not exists alert_prefs jsonb not null default '{}'::jsonb;

create table if not exists public.alert_log (
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null,
  key text not null,
  channel text not null check (channel in ('push', 'email', 'whatsapp', 'call')),
  sent_at timestamptz not null default now(),
  primary key (org_id, kind, key, channel)
);
create index if not exists alert_log_sent on public.alert_log(sent_at);
alter table public.alert_log enable row level security;
revoke all on public.alert_log from anon, authenticated;

alter table public.messages drop constraint if exists messages_template_check;
alter table public.messages add constraint messages_template_check
  check (template in ('document', 'reminder', 'receipt', 'statement', 'order', 'custom', 'bill_returned', 'invite', 'alert'));

alter table public.voice_calls add column if not exists sale_id uuid references public.sales(id) on delete set null;
alter table public.voice_calls add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter table public.voice_calls add column if not exists call_after timestamptz;
create index if not exists voice_calls_sale_fk on public.voice_calls(sale_id);
create index if not exists voice_calls_customer_fk on public.voice_calls(customer_id);
create index if not exists voice_calls_due on public.voice_calls(call_after) where status = 'queued' and call_after is not null;
alter table public.voice_calls drop constraint if exists voice_calls_kind_check;
alter table public.voice_calls add constraint voice_calls_kind_check check (kind in ('vendor_order', 'reminder', 'guide_followup', 'tax_deadline', 'customer_followup'));

-- The business's own choices. p: {email, whatsapp, owner_calls, customer_calls} (true or false)
create or replace function public.save_alert_prefs(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; k text; x jsonb; v jsonb;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner or someone who manages settings changes alerts.' using errcode = '42501'; end if;
  select alert_prefs into v from orgs where id = p_org;
  for k, x in select * from jsonb_each(coalesce(p, '{}'::jsonb)) loop
    if k not in ('email', 'whatsapp', 'owner_calls', 'customer_calls') then raise exception 'Unknown alert setting: %.', k; end if;
    if jsonb_typeof(x) <> 'boolean' then raise exception 'Alert settings are on or off.'; end if;
    v := v || jsonb_build_object(k, x);
  end loop;
  update orgs set alert_prefs = v where id = p_org;
  return private.alert_prefs(p_org);
end $$;

-- What applies to one business: TaxStreem's settings and its own choices.
create or replace function private.alert_prefs(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'email', coalesce((o.alert_prefs->>'email')::boolean, true),
    'whatsapp', coalesce((o.alert_prefs->>'whatsapp')::boolean, true),
    'owner_calls', coalesce((o.alert_prefs->>'owner_calls')::boolean, true),
    'customer_calls', coalesce((o.alert_prefs->>'customer_calls')::boolean, false),
    'platform', private.setting('alerts'))
  from orgs o where o.id = p_org
$$;

create or replace function public.get_alert_prefs(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return private.alert_prefs(p_org) || jsonb_build_object('can_change', m.role = 'owner' or private.perm_of(m, 'manage_settings'),
    'owner', (select jsonb_build_object('name', display_name, 'phone', phone, 'email', email) from members where org_id = p_org and role = 'owner' and status = 'active'
              order by created_at limit 1),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'summary', c.summary, 'outcome', c.outcome,
        'created_at', c.created_at, 'to', (select name from customers where id = c.customer_id), 'sale', (select number from sales where id = c.sale_id))
        order by c.created_at desc), '[]'::jsonb)
      from (select * from voice_calls where org_id = p_org and kind in ('tax_deadline', 'customer_followup') order by created_at desc limit 30) c));
end $$;

-- Once per business, kind, key and channel.
create or replace function private.alert_once(p_org uuid, p_kind text, p_key text, p_channel text) returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  insert into alert_log (org_id, kind, key, channel) values (p_org, p_kind, p_key, p_channel) on conflict do nothing;
  return found;
end $$;

-- Email and WhatsApp to the owner (and push to whoever the work is for), each once for its key.
-- p: {perm, title, body, url, lines[], button, wa_name, wa_params[], subject}
create or replace function private.alert_send(p_org uuid, p_kind text, p_key text, p_channels text[], p jsonb) returns text[]
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; ow public.members; v_prefs jsonb := private.alert_prefs(p_org); v_sent text[] := '{}'; v_link text;
begin
  select * into o from orgs where id = p_org;
  select * into ow from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || coalesce(p->>'url', '/home');
  if 'push' = any(p_channels) and private.alert_once(p_org, p_kind, p_key, 'push') then
    perform private.notify_perm(p_org, coalesce(p->>'perm', 'keep_books'), p_kind, p->>'title', p->>'body', p->>'url', p_kind || ':' || p_key);
    v_sent := v_sent || 'push'::text;
  end if;
  -- Sample businesses never message anyone.
  if o.is_sample or ow.id is null then return v_sent; end if;
  if 'email' = any(p_channels) and (v_prefs->>'email')::boolean and private.feature_on(p_org, 'email') and nullif(trim(coalesce(ow.email, '')), '') is not null
     and private.alert_once(p_org, p_kind, p_key, 'email') then
    begin
      perform private.queue_message(p_org, 'email', ow.email, 'alert', coalesce(p->>'subject', p->>'title'),
        jsonb_build_object('kind', p_kind, 'person_name', ow.display_name, 'business', o.name, 'heading', p->>'title', 'lines', coalesce(p->'lines', jsonb_build_array(p->>'body')),
          'button', coalesce(p->>'button', 'Open Counta'), 'link', v_link, 'automatic', true), null, null, ow.id);
      v_sent := v_sent || 'email'::text;
    exception when others then null;
    end;
  end if;
  if 'whatsapp' = any(p_channels) and (v_prefs->>'whatsapp')::boolean and private.feature_on(p_org, 'whatsapp') and private.e164(ow.phone) is not null
     and p ? 'wa_name' and private.alert_once(p_org, p_kind, p_key, 'whatsapp') then
    begin
      perform private.queue_message(p_org, 'whatsapp', ow.phone, 'alert', coalesce(p->>'subject', p->>'title'),
        jsonb_build_object('kind', p_kind, 'person_name', ow.display_name, 'business', o.name, 'heading', p->>'title', 'lines', coalesce(p->'lines', jsonb_build_array(p->>'body')),
          'link', v_link, 'wa', jsonb_build_object('name', p->>'wa_name', 'params', p->'wa_params'), 'automatic', true), null, null, ow.id);
      v_sent := v_sent || 'whatsapp'::text;
    exception when others then null;
    end;
  end if;
  return v_sent;
end $$;

-- Lagos (or the business's) wall clock as a time today, for "call from 9 o'clock".
create or replace function private.local_hour_at(p_org uuid, p_day date, p_hour int) returns timestamptz
language sql stable security definer set search_path = public, private as $$
  select (p_day::timestamp + make_interval(hours => p_hour)) at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos')
$$;

-- What a business owes the tax authorities next, with the date it is due: the last month's VAT return, WHT deducted, and
-- the companies income tax return for the year last ended.
create or replace function private.tax_deadlines(p_org uuid) returns table (tax text, label text, period date, due date, amount numeric, url text)
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_today date := private.local_day(p_org, now()); v_last date; vp public.vat_periods; r record; v_year int; v_from date; v_to date; cy record;
begin
  select * into o from orgs where id = p_org;
  -- VAT: every month that ended since the books started, not filed (or filed and not paid), due on the 21st after it.
  if o.vat_registered then
    for r in select g::date mth from generate_series(date_trunc('month', greatest(coalesce(o.books_start, o.created_at::date), v_today - 400))::date,
                                                      (date_trunc('month', v_today) - interval '1 month')::date, interval '1 month') g loop
      select * into vp from vat_periods where org_id = p_org and period = r.mth;
      if vp.period is null or (vp.status = 'filed' and vp.payable > 0) then
        tax := 'vat'; label := case when vp.period is null then 'VAT return' else 'VAT payment' end; period := r.mth;
        due := (r.mth + interval '1 month')::date + 20; amount := case when vp.period is not null then vp.payable end; url := '/tax/vat';
        return next;
      end if;
    end loop;
  end if;
  -- WHT and withholding VAT deducted and not yet paid over, by month and authority.
  for r in select d.period, d.authority, d.kind, min(d.due_date) due_date, sum(d.amount) amt from wht_deductions d
           where d.org_id = p_org and d.status = 'deducted' and d.kind in ('wht', 'wvat') group by d.period, d.authority, d.kind loop
    tax := case when r.kind = 'wht' then 'wht' else 'wvat' end; label := case when r.kind = 'wht' then 'WHT to ' || r.authority else 'Withholding VAT' end;
    period := r.period; due := r.due_date; amount := r.amt; url := '/tax/wht';
    return next;
  end loop;
  -- CIT: the year that ended most recently, due six months after its end.
  v_year := extract(year from v_today)::int;
  select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year);
  if v_to >= v_today then v_year := v_year - 1; select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year); end if;
  if v_to is not null and coalesce(o.books_start, v_to) <= v_to
     and not exists (select 1 from cit_years where org_id = p_org and accounting_year = v_year and status in ('sent', 'filed')) then
    tax := 'cit'; label := 'Companies income tax return'; period := v_from; due := (v_to + interval '6 months')::date; amount := null; url := '/tax/cit?year=' || v_year;
    return next;
  end if;
end $$;

-- Every morning: tax deadlines, invoices due, transactions to confirm before the returns, and customers' overdue invoices.
create or replace function private.alerts_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cfg jsonb := private.setting('alerts'); o record; d record; v_today date; v_left int; v_ch text[]; v_n int; v_amt numeric; v_oldest text; v_prefs jsonb;
  ow public.members; v_out jsonb := '{}'::jsonb; v_cnt int := 0; s record; v_calls int; v_per_day int; v_mth date; v_due21 date; v_key text; v_days int[];
begin
  for o in select x.* from orgs x where exists (select 1 from members m where m.org_id = x.id and m.role = 'owner' and m.status = 'active') loop
    v_today := private.local_day(o.id, now());
    v_prefs := private.alert_prefs(o.id);
    select * into ow from members where org_id = o.id and role = 'owner' and status = 'active' order by created_at limit 1;
    -- ---- tax deadlines
    v_days := array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'days_before'))::int);
    for d in select * from private.tax_deadlines(o.id) loop
      v_left := d.due - v_today;
      v_key := d.tax || ':' || d.period || ':' || v_left;
      v_ch := '{}';
      if (cfg->'tax_deadline'->>'push')::boolean and (v_left = any(v_days) or v_left = 0 or (v_left < 0 and v_left % 3 = 0)) then v_ch := v_ch || 'push'::text; end if;
      if (v_left = any(array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'message_days_before'))::int)) or v_left = 0 or (v_left < 0 and v_left % 7 = 0)) then
        if (cfg->'tax_deadline'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'tax_deadline'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      if cardinality(v_ch) > 0 then
        perform private.alert_send(o.id, 'tax_deadline', v_key, v_ch, jsonb_build_object('perm', 'file_tax',
          'title', d.label || ' for ' || to_char(d.period, 'FMMonth YYYY') || case when v_left > 1 then ' is due in ' || v_left || ' days'
            when v_left = 1 then ' is due tomorrow' when v_left = 0 then ' is due today' else ' is ' || -v_left || ' days late' end,
          'body', 'Due on ' || to_char(d.due, 'FMDD Mon YYYY') || coalesce(' · ' || private.naira(d.amount), '') || '. Open Counta to finish it.',
          'url', d.url, 'button', 'Open the return',
          'lines', jsonb_build_array(o.name || '''s ' || lower(d.label) || ' for ' || to_char(d.period, 'FMMonth YYYY') || ' is due on ' || to_char(d.due, 'FMDD Mon YYYY') || '.',
            case when d.amount is not null then private.naira(d.amount) || ' is due.' else 'Counta has prepared it from the books; check it and file.' end,
            case when v_left < 0 then 'It is late: penalties and interest grow each month it stays unfiled.' end),
          'wa_name', 'counta_tax_deadline', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, lower(d.label),
            to_char(d.period, 'FMMonth YYYY'), to_char(d.due, 'FMDD Mon YYYY'), coalesce(private.naira(d.amount), 'prepared in Counta'))));
        v_cnt := v_cnt + 1;
      end if;
      -- Martina calls the owner the day before.
      if v_left = coalesce((cfg->'tax_deadline'->>'call_days_before')::int, 1) and (cfg->'tax_deadline'->>'call')::boolean and (v_prefs->>'owner_calls')::boolean
         and not o.is_sample and private.feature_on(o.id, 'phone_calls') and private.e164(ow.phone) is not null
         and private.alert_once(o.id, 'tax_deadline', d.tax || ':' || d.period, 'call') then
        insert into voice_calls (org_id, kind, member_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'tax_deadline', ow.id, d.tax, private.e164(ow.phone), jsonb_build_object('business_name', o.name, 'person_name', ow.display_name,
            'person_first_name', split_part(ow.display_name, ' ', 1), 'tax_name', d.label, 'period', to_char(d.period, 'FMMonth YYYY'),
            'due_date', to_char(d.due, 'FMDay DD FMMonth'), 'amount', coalesce(private.naira(d.amount), 'the amount Counta worked out'),
            'what_to_do', case d.tax when 'vat' then 'Open Counta, go to Tax returns and VAT, check the month and file it, then pay what is due.'
              when 'cit' then 'Open Counta, go to Tax returns and Companies income tax, check the computation and approve it for filing.'
              else 'Open Counta, go to Tax returns and Withholding tax, and pay what was deducted with the schedule.' end),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
      end if;
    end loop;
    -- ---- invoices due and overdue
    select count(*), coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0), min(s2.number) filter (where s2.due_date = (select min(due_date) from sales s3 where s3.org_id = o.id
             and s3.doc_type = 'invoice' and s3.status in ('open', 'partially_paid') and s3.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3)))
      into v_n, v_amt, v_oldest
    from sales s2 where s2.org_id = o.id and s2.doc_type = 'invoice' and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
      and s2.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3);
    if v_n > 0 then
      v_ch := case when (cfg->'invoices'->>'push')::boolean then array['push'] else '{}' end;
      -- The week's digest, and the day an invoice first goes overdue.
      if extract(isodow from v_today)::int = coalesce((cfg->'invoices'->>'digest_weekday')::int, 1)
         or exists (select 1 from sales s4 where s4.org_id = o.id and s4.doc_type = 'invoice' and s4.status in ('open', 'partially_paid') and s4.due_date = v_today - 1) then
        if (cfg->'invoices'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'invoices'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      perform private.alert_send(o.id, 'invoices', v_today::text, v_ch, jsonb_build_object('perm', 'record_sales',
        'title', v_n || ' invoice' || case when v_n = 1 then ' is' else 's are' end || ' due or overdue',
        'body', private.naira(v_amt) || ' in all' || coalesce(' · the oldest is ' || v_oldest, ''),
        'url', '/sell/sales?status=overdue', 'button', 'See the invoices',
        'lines', jsonb_build_array(o.name || ' has ' || v_n || ' invoice' || case when v_n = 1 then '' else 's' end || ' due in the next few days or overdue, ' || private.naira(v_amt) || ' in all.',
          'Counta reminds the customers on the days set in Settings; you can send a reminder or a statement from each invoice.'),
        'wa_name', 'counta_invoices_due', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, private.naira(v_amt),
          coalesce(v_oldest, '-'))));
    end if;
    -- ---- transactions to confirm before the month's VAT and WHT returns (from the 10th to the 20th)
    v_mth := (date_trunc('month', v_today) - interval '1 month')::date;
    v_due21 := (date_trunc('month', v_today))::date + 20;
    if extract(day from v_today) between coalesce((cfg->'confirm'->>'push_from_day')::int, 10) and 20 then
      select count(*) into v_n from bank_lines bl where bl.org_id = o.id and bl.status in ('unmatched', 'proposed') and bl.line_date between v_mth and (v_mth + interval '1 month' - interval '1 day')::date;
      v_n := v_n + (select count(*) from receipts r where r.org_id = o.id and r.status = 'needs_review' and r.created_at::date between v_mth and v_due21)
                 + (select count(*) from sales_schedules sc where sc.org_id = o.id and sc.status = 'draft');
      if v_n > 0 then
        v_ch := array['push'];
        if extract(day from v_today)::int = any(array(select (jsonb_array_elements_text(cfg->'confirm'->'message_days'))::int)) then
          if (cfg->'confirm'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
          if (cfg->'confirm'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
        end if;
        perform private.alert_send(o.id, 'confirm', v_today::text, v_ch, jsonb_build_object('perm', 'keep_books',
          'title', v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' to confirm before the returns',
          'body', 'From ' || to_char(v_mth, 'FMMonth') || '. The VAT and WHT returns are due on ' || to_char(v_due21, 'FMDD Mon') || '.',
          'url', '/accounting/inbox', 'button', 'Confirm them',
          'lines', jsonb_build_array(v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' from ' || to_char(v_mth, 'FMMonth YYYY') || ' still need your answer before they go into the returns.',
            'The VAT and WHT returns for ' || to_char(v_mth, 'FMMonth') || ' are due on ' || to_char(v_due21, 'FMDD Mon YYYY') || '.'),
          'wa_name', 'counta_confirm_items', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, to_char(v_mth, 'FMMonth YYYY'),
            to_char(v_due21, 'FMDD Mon'))));
      end if;
    end if;
    -- ---- Martina follows up customers' overdue invoices, when the business asked for it
    if (v_prefs->>'customer_calls')::boolean and (cfg->'customer_calls'->>'enabled')::boolean and not o.is_sample and private.feature_on(o.id, 'phone_calls') then
      v_per_day := coalesce((cfg->'customer_calls'->>'per_org_per_day')::int, 5);
      select count(*) into v_calls from voice_calls where org_id = o.id and kind = 'customer_followup' and created_at > now() - interval '20 hours';
      for s in select sa.*, cu.phone cphone, cu.name cname from sales sa join customers cu on cu.id = sa.customer_id
               where sa.org_id = o.id and sa.doc_type = 'invoice' and sa.status in ('open', 'partially_paid') and sa.journal_id is not null and not cu.is_walk_in
                 and sa.due_date <= v_today - coalesce((cfg->'customer_calls'->>'min_days_overdue')::int, 7)
                 and sa.total - sa.amount_paid - sa.credited >= coalesce((cfg->'customer_calls'->>'min_amount')::numeric, 10000)
                 and private.e164(cu.phone) is not null
                 -- a reminder went at least two days ago and was not answered with payment
                 and sa.reminded_at is not null and sa.reminded_at < now() - interval '2 days'
                 and not exists (select 1 from voice_calls vc where vc.sale_id = sa.id
                                 and vc.created_at > now() - make_interval(days => coalesce((cfg->'customer_calls'->>'repeat_days')::int, 7)))
               order by sa.total - sa.amount_paid - sa.credited desc limit 20 loop
        exit when v_calls >= v_per_day;
        insert into voice_calls (org_id, kind, sale_id, customer_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'customer_followup', s.id, s.customer_id, 'overdue_invoice', private.e164(s.cphone), jsonb_build_object('business_name', o.name,
            'customer_name', s.cname, 'customer_first_name', split_part(s.cname, ' ', 1), 'invoice_number', s.number,
            'amount_due', private.naira(s.total - s.amount_paid - s.credited), 'due_date', to_char(s.due_date, 'FMDD FMMonth YYYY'),
            'days_overdue', (v_today - s.due_date)::text, 'contact_name', ow.display_name, 'contact_phone', coalesce(o.phone, ow.phone, ''),
            'pay_link', private.doc_link(s.public_token)),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
        v_calls := v_calls + 1;
      end loop;
    end if;
  end loop;
  delete from alert_log where sent_at < now() - interval '120 days';
  return jsonb_build_object('alerts', v_cnt);
end $$;

-- Calls queued by the morning's alerts, placed by the voice function within calling hours (weekdays only for customers).
create or replace function public.svc_calls_due(p_limit int default 10) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cfg jsonb := private.setting('alerts'); v_from int := coalesce((cfg->'calls'->'hours'->>0)::int, 9); v_to int := coalesce((cfg->'calls'->'hours'->>1)::int, 17);
  v_out jsonb := '[]'::jsonb; c record; v_local timestamp;
begin
  for c in select vc.* from voice_calls vc where vc.status = 'queued' and vc.call_after is not null and vc.call_after <= now()
             and vc.kind in ('tax_deadline', 'customer_followup') and vc.created_at > now() - interval '4 days'
           order by vc.call_after limit greatest(least(p_limit, 50), 1) for update skip locked loop
    v_local := now() at time zone coalesce((select timezone from orgs where id = c.org_id), 'Africa/Lagos');
    -- Outside the hours (or a weekend, for customers): tried again at the next opening.
    if extract(hour from v_local) < v_from or extract(hour from v_local) >= v_to
       or (c.kind = 'customer_followup' and coalesce((cfg->'customer_calls'->>'weekdays_only')::boolean, true) and extract(isodow from v_local) > 5) then
      update voice_calls set call_after = private.local_hour_at(c.org_id, (v_local::date + case when extract(hour from v_local) >= v_from then 1 else 0 end), v_from)
      where id = c.id;
      continue;
    end if;
    -- The invoice was paid since the call was queued: nothing to chase.
    if c.kind = 'customer_followup' and not exists (select 1 from sales where id = c.sale_id and status in ('open', 'partially_paid')) then
      update voice_calls set status = 'failed', error = 'Paid before the call', call_after = null where id = c.id;
      continue;
    end if;
    update voice_calls set call_after = null where id = c.id;
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', c.kind, 'call_id', c.id, 'to_number', c.to_number, 'variables', c.variables, 'org_id', c.org_id));
  end loop;
  return v_out;
end $$;

create or replace function private.calls_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from voice_calls where status = 'queued' and call_after is not null and call_after <= now() and kind in ('tax_deadline', 'customer_followup')) then
    perform private.call_function('voice', jsonb_build_object('action', 'place_due'));
  end if;
end $$;

-- What needs doing, as a count for each menu item, for this person's role.
create or replace function public.get_attention(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_today date; v_books boolean; v_pay boolean; v_sales boolean; v_tax boolean; v_vat int := 0; v_wht int := 0; v_cit int := 0;
  r record;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_books := private.perm_of(m, 'keep_books');
  v_pay := private.perm_of(m, 'make_payments');
  v_sales := private.perm_of(m, 'record_sales') or v_books;
  v_tax := v_books or private.perm_of(m, 'file_tax');
  if v_tax then
    for r in select * from private.tax_deadlines(p_org) where due <= v_today + 7 loop
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax = 'cit' then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax = 'cit' and t.due <= v_today + 30) then 1 else 0 end;
  end if;
  return jsonb_build_object(
    'invoices_overdue', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid')
      and journal_id is not null and due_date < v_today) else 0 end,
    'orders_to_confirm', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'order' and status = 'pending') else 0 end,
    'payments_to_confirm', case when v_books or private.perm_of(m, 'approve_adjustments') then (select count(*) from collections where org_id = p_org and status = 'pending') else 0 end,
    'bills_overdue', case when v_books or v_pay then (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid') and due_date < v_today) else 0 end,
    'bank_lines', case when v_books then (select count(*) from bank_lines where org_id = p_org and status = 'unmatched') else 0 end,
    'proposals', case when v_books then (select count(*) from ai_proposals where org_id = p_org and status = 'pending') else 0 end,
    'schedules_draft', case when v_tax then (select count(*) from sales_schedules where org_id = p_org and status = 'draft') else 0 end,
    'vat', v_vat, 'wht', v_wht, 'cit', v_cit,
    'tax_wallet', case when v_pay or v_books then
      (case when exists (select 1 from wallets where org_id = p_org and status = 'active') and not exists (select 1 from tax_wallets where org_id = p_org and status = 'active') then 1 else 0 end)
      + (select count(*) from tax_payments where org_id = p_org and status = 'failed' and created_at > now() - interval '7 days') else 0 end,
    'tax_id', case when m.role = 'owner' or private.perm_of(m, 'manage_settings') then
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end);
end $$;

create or replace function private.setting_defaults(p_key text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_key
    when 'martina' then '{"tone": "calm", "default_voice_id": null}'::jsonb
    when 'limits' then '{"guide_day": 8, "guide_week": 25, "assistant_day": 30, "assistant_week": 150,
      "voice_org_phrases": 600, "voice_org_chars": 60000, "voice_user_phrases": 60, "voice_user_chars": 6000,
      "lookups": {"search": 20, "profile": 6, "tin": 6, "status_report": 3, "web": 8, "document": 6, "nin": 5, "nin_slip": 4, "product": 200}}'::jsonb
    when 'alerts' then '{"tax_deadline": {"push": true, "email": true, "whatsapp": true, "call": true, "days_before": [7, 3, 1], "message_days_before": [3, 1], "call_days_before": 1},
      "invoices": {"push": true, "email": true, "whatsapp": true, "due_soon_days": 3, "digest_weekday": 1},
      "confirm": {"push_from_day": 10, "email": true, "whatsapp": true, "message_days": [15, 19]},
      "customer_calls": {"enabled": true, "min_days_overdue": 7, "min_amount": 10000, "per_org_per_day": 5, "repeat_days": 7, "weekdays_only": true},
      "calls": {"hours": [9, 17]}}'::jsonb
    when 'switches' then '{"new_businesses": true, "martina": true, "phone_calls": true, "payment_voice": true, "ai_reading": true,
      "email": true, "whatsapp": true, "payments": true}'::jsonb
    else '{}'::jsonb end
$$;


create or replace function public.admin_save_setting(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_cur jsonb := private.setting(p_key); v_new jsonb; k text; x jsonb; n numeric; v_old jsonb; g text; gx jsonb; e jsonb; v_def jsonb;
begin
  perform private.require_staff();
  if p_key not in ('martina', 'limits', 'switches', 'alerts') then raise exception 'Unknown setting.'; end if;
  if jsonb_typeof(coalesce(p_value, 'null'::jsonb)) <> 'object' then raise exception 'Nothing to save.'; end if;
  v_new := v_cur;
  if p_key = 'martina' then
    if p_value ? 'tone' then
      if p_value->>'tone' not in ('calm', 'warm', 'lively') then raise exception 'Choose calm, warm or lively.'; end if;
      v_new := v_new || jsonb_build_object('tone', p_value->>'tone');
    end if;
    if p_value ? 'default_voice_id' then
      if nullif(p_value->>'default_voice_id', '') is not null
         and not exists (select 1 from tts_voices where voice_id = p_value->>'default_voice_id' and active) then
        raise exception 'Choose one of the voices on offer.';
      end if;
      v_new := v_new || jsonb_build_object('default_voice_id', nullif(p_value->>'default_voice_id', ''));
    end if;
  elsif p_key = 'limits' then
    for k, x in select * from jsonb_each(p_value) loop
      if k = 'lookups' then
        if jsonb_typeof(x) <> 'object' then raise exception 'Unknown limit.'; end if;
        for k, x in select * from jsonb_each(p_value->'lookups') loop
          if not (private.setting_defaults('limits')->'lookups' ? k) then raise exception 'Unknown lookup: %.', k; end if;
          begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
          if n is null or n <> trunc(n) or n < 0 or n > 100000 then raise exception 'Limits are whole numbers from 0 to 100,000.'; end if;
          v_new := jsonb_set(v_new, array['lookups', k], to_jsonb(n::int));
        end loop;
      else
        if not (private.setting_defaults('limits') ? k) then raise exception 'Unknown limit: %.', k; end if;
        begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
        if n is null or n <> trunc(n) or n < 0 or n > 10000000 then raise exception 'Limits are whole numbers from 0 to 10,000,000.'; end if;
        v_new := v_new || jsonb_build_object(k, n::int);
      end if;
    end loop;
    if (v_new->>'guide_week')::int < (v_new->>'guide_day')::int or (v_new->>'assistant_week')::int < (v_new->>'assistant_day')::int then
      raise exception 'A week''s limit cannot be smaller than a day''s.';
    end if;
  elsif p_key = 'alerts' then
    -- Only the settings that exist, each as the kind of value it is: on/off, a whole number, or a list of whole numbers.
    v_def := private.setting_defaults('alerts');
    for g, gx in select * from jsonb_each(p_value) loop
      if not (v_def ? g) or jsonb_typeof(gx) <> 'object' then raise exception 'Unknown alert setting: %.', g; end if;
      for k, x in select * from jsonb_each(gx) loop
        if not (v_def->g ? k) then raise exception 'Unknown alert setting: %.%.', g, k; end if;
        if jsonb_typeof(x) <> jsonb_typeof(v_def->g->k) then raise exception 'Alert setting %.% must be %.', g, k,
          case jsonb_typeof(v_def->g->k) when 'boolean' then 'on or off' when 'number' then 'a whole number' else 'a list of whole numbers' end; end if;
        if jsonb_typeof(x) = 'number' and ((x #>> '{}')::numeric <> trunc((x #>> '{}')::numeric) or (x #>> '{}')::numeric < 0 or (x #>> '{}')::numeric > 100000000) then
          raise exception 'Alert setting %.% must be a whole number from 0.', g, k;
        end if;
        if jsonb_typeof(x) = 'array' then
          for e in select * from jsonb_array_elements(x) loop
            if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric <> trunc((e #>> '{}')::numeric) or (e #>> '{}')::numeric < 0 or (e #>> '{}')::numeric > 60 then
              raise exception 'Alert setting %.% is a list of whole numbers from 0 to 60.', g, k;
            end if;
          end loop;
          if jsonb_array_length(x) > 10 then raise exception 'Alert setting %.% takes at most 10 numbers.', g, k; end if;
        end if;
        v_new := jsonb_set(v_new, array[g, k], x);
      end loop;
    end loop;
    if jsonb_array_length(v_new->'calls'->'hours') <> 2 or (v_new->'calls'->'hours'->>0)::int >= (v_new->'calls'->'hours'->>1)::int
       or (v_new->'calls'->'hours'->>1)::int > 22 or (v_new->'calls'->'hours'->>0)::int < 7 then
      raise exception 'Calling hours are a start and an end between 7 and 22, the start first.';
    end if;
    if (v_new->'invoices'->>'digest_weekday')::int not between 1 and 7 then raise exception 'The weekly email day is 1 (Monday) to 7 (Sunday).'; end if;
  else
    for k, x in select * from jsonb_each(p_value) loop
      if not (k = any (private.feature_keys())) then raise exception 'Unknown switch: %.', k; end if;
      if jsonb_typeof(x) <> 'boolean' then raise exception 'Switches are on or off.'; end if;
      v_new := v_new || jsonb_build_object(k, x);
    end loop;
  end if;
  select value into v_old from platform_settings where key = p_key;
  insert into platform_settings (key, value, updated_by, updated_at) values (p_key, v_new, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform private.audit('save_' || p_key, p_key, jsonb_build_object('from', coalesce(v_old, v_cur), 'to', v_new));
  return v_new;
end $$;


create or replace function public.voice_call_update(p_call uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare c public.voice_calls; v_final boolean; v_outcome jsonb; v_vendor text; v_when text; v_title text; v_body text;
begin
  select * into c from voice_calls where id = p_call for update;
  if not found then return; end if;
  update voice_calls set
    status = coalesce(p_patch->>'status', status),
    conversation_id = coalesce(p_patch->>'conversation_id', conversation_id),
    call_sid = coalesce(p_patch->>'call_sid', call_sid),
    outcome = case when p_patch ? 'outcome' then p_patch->'outcome' else outcome end,
    summary = coalesce(p_patch->>'summary', summary),
    transcript = case when p_patch ? 'transcript' then p_patch->'transcript' else transcript end,
    duration_secs = coalesce((p_patch->>'duration_secs')::int, duration_secs),
    error = coalesce(p_patch->>'error', error),
    ended_at = case when p_patch->>'status' in ('completed', 'no_answer', 'busy', 'voicemail', 'failed') then coalesce(ended_at, now()) else ended_at end,
    synced_at = now()
  where id = c.id;

  v_final := p_patch->>'status' in ('completed', 'no_answer', 'busy', 'voicemail', 'failed')
             and c.status not in ('completed', 'no_answer', 'busy', 'voicemail', 'failed');
  if not v_final then return; end if;
  v_outcome := coalesce(p_patch->'outcome', '{}'::jsonb);

  if c.kind = 'guide_followup' then
    if p_patch->>'status' = 'completed' and coalesce((v_outcome->>'stop_calls')::boolean, false) then
      update guide_progress set followup_status = 'declined', call_consent = false, call_phone = null where user_id = c.user_id;
    else
      update guide_progress set followup_status = case p_patch->>'status' when 'completed' then 'done' when 'failed' then 'failed' else 'no_answer' end
      where user_id = c.user_id;
    end if;
    return;
  end if;

  if c.kind = 'vendor_order' then
    v_vendor := coalesce(c.variables->>'vendor_name', 'The vendor');
    v_when := nullif(trim(v_outcome->>'delivery_date'), '');
    if p_patch->>'status' = 'completed' and coalesce((v_outcome->>'order_confirmed')::boolean, false) then
      update purchase_orders set
        status = case when status = 'draft' then 'sent' else status end,
        sent_via = case when status = 'draft' then 'phone call' else sent_via end,
        sent_at = coalesce(sent_at, now()),
        approved_by = coalesce(approved_by, c.created_by),
        note = left(trim(coalesce(note || E'\n', '') || 'Phone call ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon HH24:MI') || ': confirmed'
          || coalesce(', delivery ' || v_when, '')
          || coalesce('. Not available: ' || nullif(trim(v_outcome->>'unavailable_items'), ''), '')
          || coalesce('. Price changes: ' || nullif(trim(v_outcome->>'price_changes'), ''), '') || '.'), 2000)
      where id = c.po_id;
      v_title := v_vendor || ' confirmed ' || coalesce(c.variables->>'po_ref', 'the order');
      v_body := coalesce('Delivery ' || v_when || '. ', '') || coalesce('Not available: ' || nullif(trim(v_outcome->>'unavailable_items'), '') || '. ', '')
        || coalesce('Price changes: ' || nullif(trim(v_outcome->>'price_changes'), '') || '.', '');
    elsif p_patch->>'status' = 'completed' then
      v_title := v_vendor || ' did not confirm ' || coalesce(c.variables->>'po_ref', 'the order');
      v_body := coalesce(nullif(p_patch->>'summary', ''), 'Open the call to see what they said.');
    else
      v_title := 'Could not reach ' || v_vendor;
      v_body := case p_patch->>'status' when 'no_answer' then 'No one picked up.' when 'busy' then 'The line was busy.' when 'voicemail' then 'The call went to voicemail.'
                else coalesce('The call failed: ' || nullif(p_patch->>'error', ''), 'The call failed.') end || ' Try again later or send the order on WhatsApp.';
    end if;
    perform private.notify(c.org_id, (select user_id from members where id = c.created_by), 'call_result', v_title, coalesce(nullif(v_body, ''), 'Open Counta for the details.'),
      '/inventory/reorder', 'call:' || c.id);
  elsif c.kind = 'customer_followup' then
    v_when := nullif(trim(v_outcome->>'promised_date'), '');
    v_title := case when p_patch->>'status' = 'completed' then 'Martina called ' || coalesce(c.variables->>'customer_name', 'the customer') || ' about ' || coalesce(c.variables->>'invoice_number', 'their invoice')
                    else 'Martina could not reach ' || coalesce(c.variables->>'customer_name', 'the customer') end;
    v_body := case when p_patch->>'status' = 'completed'
                   then coalesce(case when coalesce((v_outcome->>'paid_already')::boolean, false) then 'They say they have already paid'
                                   || coalesce(': ' || nullif(trim(v_outcome->>'paid_how'), ''), '') || '. Check the bank for it.' end,
                                 case when coalesce((v_outcome->>'will_pay')::boolean, false) then 'They said they will pay' || coalesce(' ' || v_when, '') || '.' end,
                                 case when nullif(trim(v_outcome->>'dispute'), '') is not null then 'They query it: ' || trim(v_outcome->>'dispute') end,
                                 nullif(p_patch->>'summary', ''), 'Open Counta for the details.')
                   else case p_patch->>'status' when 'no_answer' then 'No one picked up.' when 'busy' then 'The line was busy.' when 'voicemail' then 'The call went to voicemail.'
                        else 'The call did not connect.' end end;
    if p_patch->>'status' = 'completed' and c.sale_id is not null then
      update sales set notes = left(trim(coalesce(notes || E'\n', '') || 'Martina called ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon HH24:MI') || ': ' || v_body), 4000)
      where id = c.sale_id;
    end if;
    perform private.notify_perm(c.org_id, 'record_sales', 'call_result', v_title, v_body, '/sell/sales?open=' || coalesce(c.sale_id::text, ''), 'call:' || c.id);
  elsif c.kind = 'tax_deadline' then
    v_title := case when p_patch->>'status' = 'completed' then 'Martina reminded you: ' || coalesce(c.variables->>'tax_name', 'a tax return') || ' due ' || coalesce(c.variables->>'due_date', 'tomorrow')
                    else 'Martina tried to call about ' || coalesce(c.variables->>'tax_name', 'a tax return') end;
    v_body := case when p_patch->>'status' = 'completed' then coalesce(nullif(p_patch->>'summary', ''), 'Open Counta to finish it.')
                   else 'The call did not connect. ' || coalesce(c.variables->>'what_to_do', '') end;
    perform private.notify(c.org_id, (select user_id from members where id = c.member_id), 'call_result', v_title, v_body,
      case c.topic when 'vat' then '/tax/vat' when 'cit' then '/tax/cit' else '/tax/wht' end, 'call:' || c.id);
  else
    v_title := case when p_patch->>'status' = 'completed' then 'Reminder call to ' || coalesce(c.variables->>'person_first_name', 'your colleague') || ' done'
                    else 'Could not reach ' || coalesce(c.variables->>'person_first_name', 'your colleague') end;
    v_body := case when p_patch->>'status' = 'completed'
                   then coalesce(case when (v_outcome->>'will_act')::boolean then 'They said they will handle it' || coalesce(' ' || nullif(trim(v_outcome->>'when'), ''), '') || '.' end,
                                 nullif(p_patch->>'summary', ''), 'Open Counta for the details.')
                   else 'The call did not connect.' end;
    perform private.notify(c.org_id, (select user_id from members where id = c.created_by), 'call_result', v_title, v_body, '/inventory/locations', 'call:' || c.id);
  end if;
end $$;


create or replace function public.admin_settings() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'martina', private.setting('martina'), 'limits', private.setting('limits'), 'switches', private.setting('switches'), 'alerts', private.setting('alerts'),
    'defaults', jsonb_build_object('martina', private.setting_defaults('martina'), 'limits', private.setting_defaults('limits'),
      'switches', private.setting_defaults('switches'), 'alerts', private.setting_defaults('alerts')),
    'voices', (select coalesce(jsonb_agg(jsonb_build_object('voice_id', v.voice_id, 'name', v.name, 'gender', v.gender, 'age', v.age, 'accent', v.accent,
        'description', v.description, 'preview_url', v.preview_url, 'source', v.source, 'active', v.active, 'sort', v.sort,
        'businesses', (select count(*) from orgs o where o.voice_id = v.voice_id)) order by v.active desc, v.sort, v.name), '[]'::jsonb) from tts_voices v),
    'overrides', (select coalesce(jsonb_agg(jsonb_build_object('org_id', s.org_id, 'business', o.name, 'feature', s.feature, 'enabled', s.enabled,
        'note', s.note, 'set_at', s.set_at) order by o.name, s.feature), '[]'::jsonb) from org_switches s join orgs o on o.id = s.org_id),
    'updated', (select coalesce(jsonb_object_agg(p.key, jsonb_build_object('at', p.updated_at, 'by', (select email from auth.users u where u.id = p.updated_by))), '{}'::jsonb)
      from platform_settings p));
end $$;



-- ---------------------------------------------------------------------------
-- Schedules
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('counta-alerts', 'counta-calls');
    perform cron.schedule('counta-alerts', '5 7 * * *', 'select private.alerts_tick()');
    perform cron.schedule('counta-calls', '*/15 * * * *', 'select private.calls_tick()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
grant execute on function public.request_tax_payment(uuid, jsonb), public.tax_payment_to_send(uuid), public.get_tax_wallet(uuid),
  public.set_receipts_vat(uuid, jsonb), public.save_sales_schedule(uuid, jsonb), public.update_schedule_line(uuid, jsonb), public.post_sales_schedule(uuid),
  public.void_sales_schedule(uuid, text), public.get_sales_schedules(uuid), public.get_sales_schedule(uuid), public.save_vat_purchase(uuid, jsonb),
  public.save_alert_prefs(uuid, jsonb), public.get_alert_prefs(uuid), public.get_attention(uuid), public.resolve_proposal(uuid, jsonb),
  public.admin_tax_payees(), public.admin_save_tax_payee(jsonb) to authenticated;
revoke execute on function public.request_tax_payment(uuid, jsonb), public.tax_payment_to_send(uuid), public.get_tax_wallet(uuid),
  public.set_receipts_vat(uuid, jsonb), public.save_sales_schedule(uuid, jsonb), public.update_schedule_line(uuid, jsonb), public.post_sales_schedule(uuid),
  public.void_sales_schedule(uuid, text), public.get_sales_schedules(uuid), public.get_sales_schedule(uuid), public.save_vat_purchase(uuid, jsonb),
  public.save_alert_prefs(uuid, jsonb), public.get_alert_prefs(uuid), public.get_attention(uuid), public.resolve_proposal(uuid, jsonb),
  public.admin_tax_payees(), public.admin_save_tax_payee(jsonb) from public, anon;
revoke all on function public.svc_tax_wallet_to_open(uuid, uuid), public.svc_tax_wallet_ready(uuid, jsonb), public.svc_tax_transfer_update(text, text, text, text),
  public.svc_tax_wallet_balance(uuid, numeric, numeric), public.svc_tax_payment_update(text, jsonb), public.svc_calls_due(int), public.svc_wallet_inflow(text, text, jsonb),
  public.svc_work(text), public.svc_payment_confirmed(text, jsonb), public.svc_wallet_balance(uuid, numeric, numeric) from public, anon, authenticated;
grant execute on function public.svc_tax_wallet_to_open(uuid, uuid), public.svc_tax_wallet_ready(uuid, jsonb), public.svc_tax_transfer_update(text, text, text, text),
  public.svc_tax_wallet_balance(uuid, numeric, numeric), public.svc_tax_payment_update(text, jsonb), public.svc_calls_due(int), public.svc_wallet_inflow(text, text, jsonb),
  public.svc_work(text), public.svc_payment_confirmed(text, jsonb), public.svc_wallet_balance(uuid, numeric, numeric) to service_role;
revoke all on function private.wallet_ledger(uuid), private.wallet_balance(uuid), private.tax_wallet_ledger(uuid), private.tax_wallet_spendable(uuid),
  private.queue_vat_moves(uuid), private.collections_tax_moves(), private.allocations_tax_moves(), private.bill_payments_tax_moves(), private.vault_reserve(uuid),
  private.vault_release(uuid), private.vat_periods_release(), private.wht_remittances_release(), private.tax_transfers_due(),
  private.name_words(text), private.name_score(text, text), private.name_match(text, text), private.words_in(text, text), private.invoice_candidates(uuid, numeric, text, date),
  private.bill_candidates(uuid, numeric, text, date, text), private.match_candidates(uuid), private.propose_match(uuid, jsonb, text),
  private.apply_match(uuid, jsonb, public.members, uuid), private.is_sales_account(uuid, text), private.vat_on_sales(uuid), private.main_location(uuid),
  private.require_vat_work(uuid), private.bank_line_sale(uuid, text, text, uuid, text, jsonb, public.members), private.schedule_item(uuid, text, text),
  private.schedule_json(uuid, boolean), private.schedule_totals(uuid), private.alert_prefs(uuid), private.alert_once(uuid, text, text, text),
  private.alert_send(uuid, text, text, text[], jsonb), private.local_hour_at(uuid, date, int), private.tax_deadlines(uuid), private.alerts_tick(),
  private.calls_tick(), private.schedule_cash_account(uuid, uuid, public.members), private.queue_sale_vat_move(uuid, uuid), private.undo_bank_line_sale(uuid, public.members, text), private.alloc_key(uuid, uuid)
  from public, anon, authenticated;
