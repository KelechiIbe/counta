-- Counta · how customers pay a business by transfer
--
-- Each business chooses how a customer pays it by bank transfer:
--   wallet    the business's own wallet account number, with a reference on the transfer (the default). Counta matches
--             the money by the reference, or by the exact amount when the customer leaves the reference out.
--   one_time  a fresh account number for each payment (a Flutterwave virtual account in TaxStreem's name, swept to the
--             business's wallet once paid). No reference is needed: the account itself says which payment it is.
-- One-time accounts are named "TaxStreem/<business>" (the prefix is private.config 'va_prefix'), using the business's
-- short name unless the owner sets another. Because the bank decides how that name is shown, the owner can ask Counta to
-- check it: Counta opens one ₦100 one-time account, asks the bank for its name, and keeps what it saw. Nobody pays it; it
-- expires within an hour. At most three checks a day per business.

alter table public.orgs add column if not exists transfer_mode text not null default 'wallet';
alter table public.orgs drop constraint if exists orgs_transfer_mode_check;
alter table public.orgs add constraint orgs_transfer_mode_check check (transfer_mode in ('wallet', 'one_time'));
alter table public.orgs add column if not exists transfer_name text;
alter table public.orgs drop constraint if exists orgs_transfer_name_check;
alter table public.orgs add constraint orgs_transfer_name_check check (transfer_name is null or (length(transfer_name) between 2 and 30 and transfer_name !~ '[<>{}\\/]'));

insert into private.config (key, value) values ('va_prefix', 'TaxStreem') on conflict (key) do nothing;

-- A business's name without its legal ending: "Kelandellen Company Limited" is "Kelandellen".
create or replace function private.transfer_short(p_name text) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'); w text;
begin
  loop
    w := regexp_replace(v, '[\s,.]+(limited|ltd\.?|plc|llc|llp|company|co\.?|incorporated|inc\.?|nig\.?|nigeria|enterprises?|ent\.?)$', '', 'i');
    exit when w = v or w = '';
    v := w;
  end loop;
  return left(trim(v, ' ,.'), 30);
end $$;

-- The name on a one-time account.
create or replace function private.transfer_label(o public.orgs) returns text
language sql stable security definer set search_path = public, private as $$
  select left(coalesce((select value from private.config where key = 'va_prefix'), 'TaxStreem') || '/'
    || coalesce(nullif(trim(o.transfer_name), ''), nullif(private.transfer_short(o.name), ''), o.name), 50)
$$;

-- Each check of the name a bank shows for a one-time account.
create table if not exists public.transfer_name_checks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  label text not null,
  shown text,
  bank text,
  error text,
  checked_by uuid references public.members(id) on delete set null,
  at timestamptz not null default now()
);
create index if not exists transfer_name_checks_org on public.transfer_name_checks(org_id, at desc);
create index if not exists transfer_name_checks_by on public.transfer_name_checks(checked_by);
alter table public.transfer_name_checks enable row level security;
revoke all on public.transfer_name_checks from anon, authenticated;

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
  -- The business chooses. Its own wallet number with a reference (the default): no account to ask the rail for, so the
  -- request waits at once. Or a one-time account for each payment: TaxStreem's virtual account, named TaxStreem/<business>,
  -- swept to the wallet once paid.
  v_direct := p_method = 'account' and 'direct_account' = any(pr.capabilities) and w.account_number is not null
    and coalesce(o.transfer_mode, 'wallet') = 'wallet';
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

-- What the payments function needs to ask the rail for a payment, now with the one-time account's name.
create or replace function private.request_context(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('request', private.request_json(r), 'org_id', r.org_id, 'org_name', o.name, 'org_email', o.email, 'org_phone', o.phone,
    'logo_path', o.logo_path, 'rail', r.rail, 'rail_kind', pr.kind, 'base_url', pr.base_url, 'api_key_secret', pr.api_key_secret,
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'barter_id', w.barter_id) from wallets w where w.id = r.wallet_id),
    'customer', jsonb_build_object('name', coalesce(c.name, s.customer_name, 'Customer'), 'email', coalesce(c.email, s.customer_email),
       'phone', coalesce(c.phone, s.customer_phone), 'walk_in', coalesce(c.is_walk_in, false)),
    'public_token', s.public_token, 'narration', coalesce(s.number, 'Payment') || ' · ' || o.name,
    'va_name', private.transfer_label(o))
  from payment_requests r join orgs o on o.id = r.org_id join payment_rails pr on pr.code = r.rail
  left join sales s on s.id = r.sale_id left join customers c on c.id = coalesce(r.customer_id, s.customer_id)
  where r.id = p_request
$$;

-- The transfer settings for the Payments screen.
create or replace function public.transfer_settings(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; c public.transfer_name_checks;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into c from transfer_name_checks where org_id = p_org and label = private.transfer_label(o) order by at desc limit 1;
  return jsonb_build_object('mode', o.transfer_mode, 'name', o.transfer_name, 'default_name', private.transfer_short(o.name),
    'prefix', coalesce((select value from private.config where key = 'va_prefix'), 'TaxStreem'), 'label', private.transfer_label(o),
    'seen', case when c.id is not null then jsonb_build_object('label', c.label, 'shown', c.shown, 'bank', c.bank, 'error', c.error, 'at', c.at) end,
    'checks_today', (select count(*) from transfer_name_checks where org_id = p_org and at > now() - interval '1 day'),
    'can_change', m.role = 'owner');
end $$;

-- p: {mode: wallet | one_time, name: text or null (the business's short name)}
create or replace function public.set_transfer_settings(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_name text := nullif(regexp_replace(trim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), '');
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  if p ? 'mode' and coalesce(p->>'mode', '') not in ('wallet', 'one_time') then raise exception 'Choose the wallet number or a one-time account.'; end if;
  if v_name is not null and (length(v_name) < 2 or length(v_name) > 30) then raise exception 'The name on one-time accounts has 2 to 30 characters.'; end if;
  if v_name ~ '[<>{}\\/]' then raise exception 'Leave out slashes and brackets in the name.'; end if;
  update orgs set transfer_mode = coalesce(nullif(p->>'mode', ''), transfer_mode),
    transfer_name = case when p ? 'name' then case when v_name = private.transfer_short(name) then null else v_name end else transfer_name end
  where id = p_org;
  return public.transfer_settings(p_org);
end $$;

-- Before the payments function opens an account to check the name: who may, and what the name is. Three a day.
create or replace function public.transfer_name_check_start(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_id uuid;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  perform private.require_payments_open(p_org);
  if (select count(*) from transfer_name_checks where org_id = p_org and at > now() - interval '1 day') >= 3 then
    raise exception 'That is three checks today. Try again tomorrow.';
  end if;
  select * into o from orgs where id = p_org;
  insert into transfer_name_checks (org_id, label, checked_by) values (p_org, private.transfer_label(o), m.id) returning id into v_id;
  return jsonb_build_object('check_id', v_id, 'label', private.transfer_label(o), 'org_name', o.name,
    'email', coalesce(nullif(o.email, ''), 'payments+' || left(o.id::text, 8) || '@counta.ng'), 'phone', o.phone);
end $$;

-- p: {shown, bank, error}
create or replace function public.svc_transfer_name_seen(p_check uuid, p jsonb) returns void
language sql security definer set search_path = public as $$
  update transfer_name_checks set shown = left(nullif(p->>'shown', ''), 120), bank = left(nullif(p->>'bank', ''), 80), error = left(nullif(p->>'error', ''), 300)
  where id = p_check
$$;

grant execute on function public.transfer_settings(uuid), public.set_transfer_settings(uuid, jsonb), public.transfer_name_check_start(uuid) to authenticated;
revoke execute on function public.transfer_settings(uuid), public.set_transfer_settings(uuid, jsonb), public.transfer_name_check_start(uuid) from public, anon;
revoke execute on function public.svc_transfer_name_seen(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_transfer_name_seen(uuid, jsonb) to service_role;
