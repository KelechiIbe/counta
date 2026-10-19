-- Counta, 26 October 2026: periods on every data screen, Tax IDs checked with the NRS, and bills with withholding tax held
-- until the supplier's Tax ID is checked.
--
-- 1. Tax IDs. The business's own Tax ID and each supplier's are checked against the NRS record (through Mono's Tax ID
--    lookup, run by the mono edge function): the record must exist and its name must match the business or the supplier.
--    The outcome is kept on orgs and vendors (tin_status: verified, mismatch, not_found, confirmed by a person). A Tax ID
--    typed or changed goes back to unchecked. The Tax ID printed on a supplier's invoice is kept on the bill, fills an
--    empty supplier record, and is flagged when it differs from the record.
-- 2. A bill with withholding tax to deduct from a supplier in Nigeria is not paid (one by one or in a bulk payment) until
--    that supplier's Tax ID is on record and checked: the WHT schedule needs it. The bill shows why, and can be sent back.
-- 3. Periods: the Home figures, the payments lists and the bank lines take a period.

-- ---------------------------------------------------------------------------
-- 1. Tax ID checks
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists tin_status text;
alter table public.orgs add column if not exists tin_checked_at timestamptz;
alter table public.orgs add column if not exists tin_check jsonb;
alter table public.vendors add column if not exists tin_status text;
alter table public.vendors add column if not exists tin_checked_at timestamptz;
alter table public.vendors add column if not exists tin_check jsonb;
alter table public.orgs drop constraint if exists orgs_tin_status_check;
alter table public.orgs add constraint orgs_tin_status_check check (tin_status in ('verified', 'mismatch', 'not_found', 'confirmed'));
alter table public.vendors drop constraint if exists vendors_tin_status_check;
alter table public.vendors add constraint vendors_tin_status_check check (tin_status in ('verified', 'mismatch', 'not_found', 'confirmed'));
comment on column public.vendors.tin_status is 'The Tax ID checked with the NRS: verified (record found, name matches or none given), mismatch (the NRS name differs), not_found, confirmed (a person confirmed a mismatch is the same business). Null: not checked.';
-- The Tax ID printed on the supplier's invoice (from Prism or an invoice Counta read), as printed.
alter table public.bills add column if not exists invoice_tin text;
alter table public.receipts add column if not exists vendor_tin text;

-- Every lookup asked for, so a business cannot run up lookups without limit.
create table if not exists public.tin_checks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  vendor_id uuid references public.vendors(id) on delete cascade,
  number text,
  channel text,
  outcome text not null default 'asked',
  member_id uuid,
  at timestamptz not null default now()
);
alter table public.tin_checks enable row level security;
create index if not exists tin_checks_org_at on public.tin_checks(org_id, at desc);
create index if not exists tin_checks_vendor on public.tin_checks(vendor_id) where vendor_id is not null;

-- Names compared the way the NRS and CAC spell them: case, punctuation and "Limited/Ltd/Plc/Nigeria/Company" do not count.
create or replace function private.taxpayer_words(p text) returns text[]
language sql immutable set search_path = public as $$
  select coalesce(array_agg(w order by n), '{}'::text[])
  from regexp_split_to_table(trim(regexp_replace(regexp_replace(replace(upper(coalesce(p, '')), '&', ' AND '), '[^A-Z0-9 ]', ' ', 'g'), '\s+', ' ', 'g')), ' ')
    with ordinality as x(w, n)
  where w <> '' and w not in ('LIMITED', 'LTD', 'LIMTED', 'PLC', 'NIGERIA', 'NIG', 'NG', 'COMPANY', 'CO', 'THE', 'AND', 'OF', 'GTE', 'LLP', 'LP', 'INC', 'INCORPORATED')
$$;

create or replace function private.same_taxpayer(a text, b text) returns boolean
language plpgsql immutable set search_path = public, private as $$
declare x text[] := private.taxpayer_words(a); y text[] := private.taxpayer_words(b); s text[]; l text[];
begin
  if cardinality(x) = 0 or cardinality(y) = 0 then return false; end if;
  -- Same words in any order, or the same letters with the spaces moved ("Tax Streem" and "Taxstreem").
  if (select array_agg(w order by w) from unnest(x) w) = (select array_agg(w order by w) from unnest(y) w) then return true; end if;
  if array_to_string(x, '') = array_to_string(y, '') then return true; end if;
  -- One name is the other with a single extra word ("Ade Ventures" and "Ade Ventures International").
  if cardinality(x) <= cardinality(y) then s := x; l := y; else s := y; l := x; end if;
  return cardinality(s) >= 2 and cardinality(l) - cardinality(s) <= 1 and s <@ l;
end $$;

-- A Tax ID typed or changed is not checked yet. A check sets tin_checked_at in the same update and keeps its outcome.
create or replace function private.vendor_tin_status() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if tg_op = 'UPDATE' and (new.tin is not distinct from old.tin or new.tin_checked_at is distinct from old.tin_checked_at) then return new; end if;
  if tg_op = 'INSERT' and new.tin_checked_at is not null then return new; end if;
  new.tin_status := null; new.tin_checked_at := null; new.tin_check := null;
  return new;
end $$;
drop trigger if exists vendors_tin_status on public.vendors;
create trigger vendors_tin_status before insert or update of tin on public.vendors for each row execute function private.vendor_tin_status();

-- The business's Tax ID: set in onboarding from the NRS record for its RC number, so that lookup is its check (the names are
-- compared here); typed in Settings, it waits for a check.
create or replace function private.org_tin_status() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare k record;
begin
  if new.tin is not distinct from old.tin or new.tin_checked_at is distinct from old.tin_checked_at then return new; end if;
  new.tin_status := null; new.tin_checked_at := null; new.tin_check := null;
  if new.tin is null then return new; end if;
  select kp.tin, kp.cac into k from kyc_profiles kp
  where (kp.org_id = new.id or kp.user_id = auth.uid()) and kp.tin is not null
    and regexp_replace(coalesce(kp.tin->>'nrs_tin', ''), '\D', '', 'g') = private.clean_tax_id(new.tin)
  order by kp.updated_at desc limit 1;
  if found then
    new.tin_checked_at := coalesce(nullif(k.tin->>'at', '')::timestamptz, now());
    new.tin_status := case when nullif(trim(k.tin->>'taxpayer_name'), '') is null then 'verified'
      when private.same_taxpayer(k.tin->>'taxpayer_name', k.cac->'profile'->>'approved_name') or private.same_taxpayer(k.tin->>'taxpayer_name', new.name) then 'verified'
      else 'mismatch' end;
    new.tin_check := jsonb_build_object('taxpayer_name', nullif(trim(k.tin->>'taxpayer_name'), ''), 'tin_type', k.tin->>'tin_type', 'tax_office', k.tin->>'tax_office',
      'channel', 'cac', 'name_checked', nullif(trim(k.tin->>'taxpayer_name'), '') is not null,
      'compared_with', coalesce(k.cac->'profile'->>'approved_name', new.name), 'source', 'onboarding');
  end if;
  return new;
end $$;
drop trigger if exists orgs_tin_status on public.orgs;
create trigger orgs_tin_status before update of tin on public.orgs for each row execute function private.org_tin_status();

-- Businesses already set up from an NRS lookup get its outcome now.
update public.orgs o set tin_checked_at = coalesce(nullif(k.tin->>'at', '')::timestamptz, now()),
  tin_status = case when nullif(trim(k.tin->>'taxpayer_name'), '') is null then 'verified'
    when private.same_taxpayer(k.tin->>'taxpayer_name', k.cac->'profile'->>'approved_name') or private.same_taxpayer(k.tin->>'taxpayer_name', o.name) then 'verified'
    else 'mismatch' end,
  tin_check = jsonb_build_object('taxpayer_name', nullif(trim(k.tin->>'taxpayer_name'), ''), 'tin_type', k.tin->>'tin_type', 'tax_office', k.tin->>'tax_office',
    'channel', 'cac', 'name_checked', nullif(trim(k.tin->>'taxpayer_name'), '') is not null,
    'compared_with', coalesce(k.cac->'profile'->>'approved_name', o.name), 'source', 'onboarding')
from (select distinct on (kp.org_id) kp.org_id, kp.tin, kp.cac from kyc_profiles kp where kp.org_id is not null and kp.tin is not null order by kp.org_id, kp.updated_at desc) k
where k.org_id = o.id and o.tin_status is null and o.tin is not null
  and regexp_replace(coalesce(k.tin->>'nrs_tin', ''), '\D', '', 'g') = private.clean_tax_id(o.tin);

-- What to look up for the business (p_vendor null) or one supplier. Called by the mono edge function as the signed-in person,
-- who must be allowed to see it; at most 60 lookups a business a day.
create or replace function public.tin_check_target(p_org uuid, p_vendor uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.vendors; o public.orgs; v_num text; v_channel text; v_rc text; v_id uuid;
begin
  if p_vendor is null then
    m := private.require(p_org, 'manage_settings');
    select * into o from orgs where id = p_org;
    v_num := private.clean_tax_id(o.tin); v_rc := regexp_replace(coalesce(o.rc_number, ''), '\D', '', 'g');
  else
    m := private.require(p_org, null);
    if not (private.can_handle_money(p_org) or private.perm_of(m, 'approve_pos')) then raise exception 'Your role does not see suppliers'' tax details.' using errcode = '42501'; end if;
    select * into v from vendors where id = p_vendor and org_id = p_org;
    if not found then raise exception 'Vendor not found.'; end if;
    if not coalesce(v.resident, true) then raise exception '% is outside Nigeria, so there is no Nigerian Tax ID to check.', v.name; end if;
    v_num := private.clean_tax_id(v.tin); v_rc := regexp_replace(coalesce(v.rc_number, ''), '\D', '', 'g');
  end if;
  if v_num is not null then v_channel := 'tin';
  elsif v_rc <> '' then v_channel := 'cac'; v_num := v_rc;
  else raise exception 'Add % Tax ID or RC number first.', case when p_vendor is null then 'your' else v.name || '''s' end;
  end if;
  if (select count(*) from tin_checks where org_id = p_org and at > now() - interval '1 day') >= 60 then
    raise exception 'Counta has checked many Tax IDs for this business today. Try again tomorrow.';
  end if;
  insert into tin_checks (org_id, vendor_id, number, channel, member_id) values (p_org, p_vendor, v_num, v_channel, m.id) returning id into v_id;
  return jsonb_build_object('check_id', v_id, 'kind', case when p_vendor is null then 'org' else 'vendor' end, 'number', v_num, 'channel', v_channel,
    'name', coalesce(v.name, o.name));
end $$;

-- The NRS answer (through the mono edge function). p: {check_id, found, nrs_tin, taxpayer_name, tin_type, tax_office, channel, number}.
-- A found record whose name matches (or that gives no name, as the NRS does for individuals) is verified; a 13-digit Tax ID
-- found by RC number or for an old TIN goes on the record.
create or replace function public.svc_tin_result(p_org uuid, p_vendor uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.vendors; o public.orgs; v_found boolean := coalesce((p->>'found')::boolean, false); v_nrs text; v_tp text; v_status text; v_check jsonb;
  v_cmp text; v_cmp2 text; v_cur text; v_new text;
begin
  v_nrs := regexp_replace(coalesce(p->>'nrs_tin', ''), '\D', '', 'g');
  if v_nrs !~ '^[0-9]{13}$' then v_nrs := null; end if;
  v_tp := nullif(trim(p->>'taxpayer_name'), '');
  if p_vendor is not null then
    select * into v from vendors where id = p_vendor and org_id = p_org for update;
    if not found then raise exception 'Vendor not found.'; end if;
    v_cmp := v.name; v_cmp2 := v.account_name; v_cur := v.tin;
  else
    select * into o from orgs where id = p_org for update;
    v_cmp := coalesce((select k.cac->'profile'->>'approved_name' from kyc_profiles k where k.org_id = p_org and k.cac is not null order by k.updated_at desc limit 1), o.name);
    v_cmp2 := o.name; v_cur := o.tin;
  end if;
  v_status := case when not v_found then 'not_found' when v_tp is null then 'verified'
    when private.same_taxpayer(v_tp, v_cmp) or private.same_taxpayer(v_tp, v_cmp2) then 'verified' else 'mismatch' end;
  v_check := jsonb_build_object('taxpayer_name', v_tp, 'tin_type', upper(nullif(p->>'tin_type', '')), 'tax_office', nullif(p->>'tax_office', ''),
    'channel', p->>'channel', 'number', p->>'number', 'name_checked', v_found and v_tp is not null, 'compared_with', v_cmp, 'source', 'nrs');
  -- The 13-digit Tax ID replaces nothing typed by the person, except an old TIN it was looked up from.
  v_new := case when v_nrs is not null and (private.clean_tax_id(v_cur) is null or (p->>'channel' = 'tin' and private.clean_tax_id(v_cur) !~ '^[0-9]{13}$'))
    then v_nrs else v_cur end;
  if p_vendor is not null then
    update vendors set tin = v_new, tin_status = v_status, tin_checked_at = now(), tin_check = v_check where id = v.id;
    -- Drafts from this supplier work their WHT out again (a Tax ID found stops the doubled rate).
    perform private.bill_wht(b.id) from bills b where b.vendor_id = v.id and b.status = 'draft';
  else
    update orgs set tin = v_new, tin_status = v_status, tin_checked_at = now(), tin_check = v_check where id = o.id;
  end if;
  update tin_checks set outcome = v_status where id = nullif(p->>'check_id', '')::uuid and org_id = p_org;
  return jsonb_build_object('status', v_status, 'tin', v_new, 'check', v_check);
end $$;

-- A person who knows the business confirms a Tax ID whose NRS name is spelt differently (a trading name, say).
create or replace function public.confirm_tin(p_org uuid, p_vendor uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_stamp jsonb;
begin
  if p_vendor is null then m := private.require(p_org, 'manage_settings'); else m := private.require(p_org, 'keep_books'); end if;
  v_stamp := jsonb_build_object('confirmed_by', m.display_name, 'confirmed_at', now());
  if p_vendor is null then
    update orgs set tin_status = 'confirmed', tin_check = coalesce(tin_check, '{}'::jsonb) || v_stamp where id = p_org and tin_status = 'mismatch';
    if not found then raise exception 'Only a Tax ID whose NRS name differs needs confirming.'; end if;
    return jsonb_build_object('status', 'confirmed');
  end if;
  update vendors set tin_status = 'confirmed', tin_check = coalesce(tin_check, '{}'::jsonb) || v_stamp where id = p_vendor and org_id = p_org and tin_status = 'mismatch';
  if not found then raise exception 'Only a Tax ID whose NRS name differs needs confirming.'; end if;
  return jsonb_build_object('status', 'confirmed');
end $$;

-- Why a bill cannot be paid yet for its supplier's Tax ID, or null. Only bills with withholding tax to deduct from a supplier
-- in Nigeria (pay to staff aside), since the WHT schedule needs the beneficiary's Tax ID.
create or replace function private.bill_tin_hold(p_bill uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select case
    when not coalesce(v.resident, true) then null
    when not exists (select 1 from bill_lines l where l.bill_id = b.id and l.wht > 0 and coalesce(l.wht_category, b.wht_category, '') <> 'compensation') then null
    when private.clean_tax_id(v.tin) is null then 'no_tin'
    when v.tin_status in ('verified', 'confirmed') then null
    when v.tin_status = 'mismatch' then 'tin_mismatch'
    when v.tin_status = 'not_found' then 'tin_not_found'
    else 'tin_unchecked' end
  from bills b join vendors v on v.id = b.vendor_id where b.id = p_bill
$$;

create or replace function private.tin_hold_text(p_reason text, p_vendor text, p_bill text) returns text
language sql immutable set search_path = public as $$
  select case p_reason
    when 'no_tin' then format('%s has no Tax ID. A bill with withholding tax is paid only once the supplier''s Tax ID is on record and checked with the NRS, because the WHT schedule needs it. Add it to the supplier, or send %s back for it.', p_vendor, p_bill)
    when 'tin_unchecked' then format('%s''s Tax ID has not been checked with the NRS yet. Check it before paying %s.', p_vendor, p_bill)
    when 'tin_not_found' then format('The NRS has no record of %s''s Tax ID. Correct it, or send %s back for the right one.', p_vendor, p_bill)
    when 'tin_mismatch' then format('The NRS name for %s''s Tax ID is different. Confirm it is the same business or correct the Tax ID before paying %s.', p_vendor, p_bill)
  end
$$;

-- The Tax ID on a supplier's invoice fills an empty supplier record (to be checked like any other), and an invoice read by
-- Counta brings the one it read.
create or replace function private.bill_invoice_tin_in() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.invoice_tin is null and new.receipt_id is not null then
    select nullif(trim(vendor_tin), '') into new.invoice_tin from receipts where id = new.receipt_id;
  end if;
  return new;
end $$;
drop trigger if exists bills_invoice_tin_in on public.bills;
create trigger bills_invoice_tin_in before insert on public.bills for each row execute function private.bill_invoice_tin_in();

create or replace function private.bill_invoice_tin_apply() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_tin text := private.clean_tax_id(new.invoice_tin);
begin
  if v_tin is null or v_tin !~ '^[0-9]{8,13}$' then return null; end if;
  update vendors set tin = v_tin where id = new.vendor_id and private.clean_tax_id(tin) is null;
  return null;
end $$;
drop trigger if exists bills_invoice_tin_apply on public.bills;
create trigger bills_invoice_tin_apply after insert or update of invoice_tin on public.bills for each row execute function private.bill_invoice_tin_apply();

-- Bill flags gain the Tax ID check.
create or replace function private.bill_tax_flags(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'missing_tin', not (pf->>'has_tin')::boolean and exists (select 1 from bill_lines l where l.bill_id = b.id and l.wht > 0
      and coalesce(l.wht_category, b.wht_category, '') <> 'compensation'),
    'missing_state', (pf->>'state_missing')::boolean and exists (select 1 from bill_lines l where l.bill_id = b.id and l.wht > 0
      and (coalesce(l.wht_category, b.wht_category, '') = 'compensation' or (not (pf->>'corporate')::boolean and (pf->>'resident')::boolean))),
    'tin_hold', case when b.status in ('draft', 'approved', 'partially_paid') then private.bill_tin_hold(b.id) end,
    'tin_status', v.tin_status, 'tin_checked_at', v.tin_checked_at, 'tin_check', v.tin_check,
    'invoice_tin', b.invoice_tin,
    'tin_differs', private.clean_tax_id(b.invoice_tin) is not null and private.clean_tax_id(v.tin) is not null and private.clean_tax_id(b.invoice_tin) <> private.clean_tax_id(v.tin),
    'can_return', b.status in ('draft', 'approved') and b.source <> 'receipt'
      and not exists (select 1 from bill_payments p where p.bill_id = b.id and p.status in ('paid', 'processing'))
      and not exists (select 1 from fixed_assets a where a.bill_id = b.id and a.status = 'active'))
  from bills b join vendors v on v.id = b.vendor_id cross join lateral (select private.vendor_wht_profile(b.vendor_id) pf) x
  where b.id = p_bill
$$;


-- A bill with WHT is paid only once the supplier's Tax ID is checked.
create or replace function public.pay_bill(p_bill uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members; v public.vendors; v_gross numeric; v_wht numeric; v_wvat numeric; v_net numeric; v_due numeric;
  v_method text := coalesce(nullif(p->>'method', ''), 'wallet'); ba public.bank_accounts; j public.journals; po public.payouts; bp public.bill_payments;
  v_at timestamptz; v_split jsonb; v_jl jsonb; v_hold text;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'make_payments');
  if b.status not in ('approved', 'partially_paid') then raise exception '% is %.', b.number, b.status; end if;
  select * into v from vendors where id = b.vendor_id;
  v_hold := private.bill_tin_hold(b.id);
  if v_hold is not null then raise exception '%', private.tin_hold_text(v_hold, v.name, b.number); end if;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  v_gross := round(coalesce(private.num(p->>'amount'), v_due), 2);
  if v_gross <= 0 or v_gross > v_due + 0.004 then raise exception 'Up to % is still owed on %.', to_char(v_due, 'FM999,999,999,990.00'), b.number; end if;
  -- WHT and withholding VAT are kept back in proportion to what this payment settles, so part payments add up to the bill's.
  v_split := private.bill_withholding(b.id, v_gross);
  v_wht := greatest(round(coalesce(private.num(p->>'wht'), (v_split->>'wht')::numeric), 2), 0);
  v_wvat := greatest(round(coalesce(private.num(p->>'wvat'), (v_split->>'wvat')::numeric), 2), 0);
  if v_wht + v_wvat >= v_gross then raise exception 'What is withheld cannot be the whole payment.'; end if;
  if v_wht > 0 and coalesce((private.bill_tax_flags(b.id)->>'missing_state')::boolean, false) then
    raise exception 'Add the state of % first: the withholding tax on % goes to its state revenue service.', v.name, b.number;
  end if;
  v_net := v_gross - v_wht - v_wvat;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', v_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number),
    jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number),
    jsonb_build_object('code', private.acct(b.org_id, 'wvat_payable'), 'credit', v_wvat, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', 'VAT withheld on ' || b.number));
  if v_method = 'wallet' then
    po := private.create_payout(b.org_id, jsonb_build_object('purpose', 'vendor', 'vendor_id', v.id, 'amount', v_net,
      'bank_code', coalesce(nullif(p->>'bank_code', ''), v.bank_code), 'bank_name', coalesce(nullif(p->>'bank_name', ''), v.bank_name),
      'account_number', coalesce(nullif(p->>'account_number', ''), v.account_number), 'account_name', coalesce(nullif(p->>'account_name', ''), v.account_name),
      'narration', left(coalesce(nullif(trim(p->>'narration'), ''), b.number || coalesce(' ' || b.vendor_ref, '')), 80), 'client_uuid', p->>'client_uuid'), v_jl, m);
    -- Keep the vendor's account details for next time.
    update vendors set bank_code = coalesce(bank_code, po.bank_code), bank_name = coalesce(bank_name, po.bank_name),
      account_number = coalesce(account_number, po.account_number), account_name = coalesce(account_name, po.account_name) where id = v.id;
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, payout_id, paid_at, reference, created_by)
    values (b.org_id, b.id, 'wallet', 'processing', v_gross, v_wht, v_wvat, v_net, po.id, v_at, po.reference, m.id) returning * into bp;
    return jsonb_build_object('bill', private.bill_json(b.id), 'payout', to_jsonb(po) - 'lines' - 'raw');
  end if;
  if v_method not in ('bank', 'cash') then raise exception 'Pay from the wallet, a bank account or cash.'; end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = b.org_id and active and kind = case when v_method = 'cash' then 'cash' else 'bank' end;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  perform private.require_open_day(b.org_id, private.local_day(b.org_id, v_at));
  j := private.post_entry(b.org_id, 'Paid ' || v.name || ' · ' || b.number, 'bill_payment', b.id, m.id, m.id,
    v_jl || jsonb_build_array(jsonb_build_object('code', ba.ledger_code, 'credit', v_net, 'memo', b.number || ' · ' || v.name || coalesce(' · ' || nullif(trim(p->>'reference'), ''), ''))),
    v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p->>'reference'), ''), 'by', m.display_name))));
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, bank_account_id, paid_at, reference, journal_id, created_by)
  values (b.org_id, b.id, v_method, 'paid', v_gross, v_wht, v_wvat, v_net, ba.id, v_at, nullif(trim(p->>'reference'), ''), j.id, m.id);
  b := private.refresh_bill(b.id);
  return jsonb_build_object('bill', private.bill_json(b.id));
end $$;


create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text; sv public.vendors;
begin
  if coalesce(r->>'account_number', '') !~ '^[0-9]{10}$' then v_err := v_err || 'Account numbers have 10 digits.'::text; end if;
  if coalesce(trim(r->>'bank_code'), '') = '' then v_err := v_err || 'Choose the bank.'::text; end if;
  if coalesce(trim(r->>'account_name'), '') = '' then v_err := v_err || 'The bank has not confirmed the account name.'::text; end if;
  if v_supplier is not null then sv := private.find_vendor(p_org, v_supplier); end if;
  if v_bill_ref is not null then
    b := private.find_bill(p_org, v_bill_ref, sv.id);
    if b.id is null and sv.id is not null then b := private.find_bill(p_org, v_bill_ref, null); end if;
    if b.id is null then
      v_err := v_err || format('No bill %s in Counta%s.', v_bill_ref, case when sv.id is not null then ' from ' || sv.name else '' end);
    else
      select * into v from vendors where id = b.vendor_id;
      v_kind := 'bill'; v_label := b.number || ' · ' || v.name;
      if v_supplier is not null and sv.id is distinct from v.id then
        v_err := v_err || format('%s is from %s, not %s.', b.number, v.name, v_supplier);
      end if;
      if b.status not in ('approved', 'partially_paid') then
        v_err := v_err || format('%s is %s.', b.number, replace(b.status, '_', ' '));
      elsif private.bill_tin_hold(b.id) is not null then
        v_err := v_err || private.tin_hold_text(private.bill_tin_hold(b.id), v.name, b.number);
      else
        v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
        v_left_wht := greatest(b.wht_expected + b.wvat_expected - coalesce((select sum(wht + wvat) from bill_payments where bill_id = b.id and status in ('paid', 'processing')), 0), 0);
        v_full_net := v_due - v_left_wht;
        v_rate := coalesce((b.wht_expected + b.wvat_expected) / nullif(b.total, 0), 0);
        if v_due <= 0.004 then
          v_err := v_err || format('Nothing is left to pay on %s.', b.number);
        elsif v_amt is null then
          v_gross := v_due; v_amt := v_full_net;
        elsif v_amt > v_full_net + 0.004 then
          v_err := v_err || format('%s has ₦%s left to pay, which is ₦%s after withholding tax.', b.number,
            to_char(v_due, 'FM999,999,999,990.00'), to_char(v_full_net, 'FM999,999,999,990.00'));
        elsif v_amt >= v_full_net - 0.004 then
          v_gross := v_due;
        else
          v_gross := round(v_amt / (1 - v_rate), 2);
        end if;
        v_purpose := 'vendor';
        -- What pay_bill keeps back for this gross: WHT for the WHT column; withholding VAT on top.
        if v_gross is not null then v_wht := v_gross - v_amt - coalesce((private.bill_withholding(b.id, v_gross)->>'wvat')::numeric, 0); end if;
        -- A supplier whose WHT goes to a state revenue service needs its state first (TaxStreem sign-off W-2).
        if coalesce((private.bill_tax_flags(b.id)->>'missing_state')::boolean, false) then
          v_err := v_err || format('Add the state of %s before paying %s: its withholding tax goes to that state''s revenue service.', v.name, b.number);
        end if;
      end if;
    end if;
  elsif v_supplier is not null then
    if sv.id is null then
      v_err := v_err || format('No supplier named %s in Counta.', v_supplier);
    else
      v := sv;
      v_kind := 'vendor'; v_purpose := 'vendor'; v_gross := v_amt; v_label := v.name || ' · on account';
      v_lines := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_amt, 'party_type', 'vendor', 'party_id', v.id,
        'memo', 'Paid on account · ' || coalesce(nullif(trim(r->>'narration'), ''), v.name)));
    end if;
  else
    v_code := coalesce(private.find_account(p_org, nullif(trim(r->>'account'), '')), p_default);
    if v_code is null then
      v_err := v_err || 'Say what this payment is for: a bill number, a supplier or an account code.'::text;
    elsif v_code !~ '^[0-9]' then
      v_err := v_err || format('No account called %s in your chart. Use its code.', v_code);
    elsif not private.bulk_account_ok(p_org, v_code) then
      v_err := v_err || format('Account %s cannot take a payment. Use an expense or liability account, or a bill.', v_code);
    else
      v_kind := 'account'; v_gross := v_amt; v_label := v_code || ' ' || private.account_name(p_org, v_code);
      v_purpose := case when v_code ~ '^[5-7]' then 'expense' else 'other' end;
      v_lines := jsonb_build_array(jsonb_build_object('code', v_code, 'debit', v_amt, 'memo', coalesce(nullif(trim(r->>'narration'), ''), r->>'account_name')));
    end if;
  end if;
  if v_amt is null or v_amt < 100 then v_err := v_err || 'Each payment must be at least ₦100.'::text; end if;
  return jsonb_build_object('row', r->'row', 'ok', cardinality(v_err) = 0, 'errors', to_jsonb(v_err), 'kind', v_kind, 'label', v_label,
    'amount', v_amt, 'gross', v_gross, 'wht', v_wht, 'wvat', case when v_kind = 'bill' and v_gross is not null then (private.bill_withholding(b.id, v_gross)->>'wvat')::numeric else 0 end, 'fee', case when v_amt is not null then private.transfer_fee(v_amt) end,
    'bill_id', b.id, 'bill_number', b.number, 'vendor_id', v.id, 'vendor_name', v.name, 'account', v_code, 'purpose', v_purpose, 'lines', v_lines);
end $$;

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
        'ai_confidence', b.ai_confidence, 'returned_reason', b.returned_reason,
        'tin_hold', case when b.status in ('draft', 'approved', 'partially_paid') then private.bill_tin_hold(b.id) end) order by b.created_at desc), '[]'::jsonb)
      from bills b join vendors v on v.id = b.vendor_id
      where b.org_id = p_org and (nullif(p_filter->>'status', '') is null or b.status = any(string_to_array(p_filter->>'status', ',')))
        and (nullif(p_filter->>'vendor_id', '') is null or b.vendor_id = (p_filter->>'vendor_id')::uuid)
        and (nullif(p_filter->>'from', '') is null or b.bill_date >= (p_filter->>'from')::date)
        and (nullif(p_filter->>'to', '') is null or b.bill_date <= (p_filter->>'to')::date)),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'wht_category', v.wht_category,
        'bank_code', v.bank_code, 'bank_name', v.bank_name, 'account_number', v.account_number, 'account_name', v.account_name, 'credit_days', v.credit_days,
        'vat_registered', v.vat_registered, 'balance', private.vendor_balance(p_org, v.id), 'phone', v.phone, 'email', v.email, 'address', v.address,
        'default_account', v.default_account, 'tin_status', v.tin_status, 'tin_checked_at', v.tin_checked_at, 'resident', coalesce(v.resident, true)) order by v.name), '[]'::jsonb)
      from vendors v where v.org_id = p_org),
    'wht_rates', (select jsonb_agg(to_jsonb(r) order by r.sort) from wht_rates r),
    'asset_classes', (select jsonb_agg(to_jsonb(a) order by a.cost_account) from asset_classes a),
    'unassigned_payables', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and account_code in ('2101', '2102') and party_id is null));
end $$;


create or replace function public.vendor_tax_details(p_org uuid, p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v public.vendors; pf jsonb; v_auth text;
begin
  m := private.require(p_org, null);
  -- The NIN and what was withheld are for those who pay suppliers or keep the books (as bills are).
  if not (private.can_handle_money(p_org) or private.perm_of(m, 'approve_pos')) then raise exception 'Your role does not see suppliers'' tax details.' using errcode = '42501'; end if;
  select * into v from vendors where id = p_vendor and org_id = p_org;
  if not found then raise exception 'Vendor not found.'; end if;
  pf := private.vendor_wht_profile(v.id);
  v_auth := case when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
  return jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'rc_number', v.rc_number, 'nin', private.vendor_nin(v.id), 'entity_type', v.entity_type,
    'is_individual', v.is_individual, 'resident', coalesce(v.resident, true), 'country', coalesce(v.country, 'NG'), 'state', v.state, 'address', v.address,
    'wht_category', v.wht_category, 'is_manufacturer', coalesce(v.is_manufacturer, false), 'wht_exempt', coalesce(v.wht_exempt, false),
    'digital_supplier', coalesce(v.digital_supplier, false), 'connected_person', coalesce(v.connected_person, false), 'vat_registered', v.vat_registered,
    'wht_profile', pf || jsonb_build_object('authority', v_auth, 'authority_name', (select coalesce(short_name, name) from tax_authorities where code = v_auth),
      'state_needed', v_auth is null),
    'wht_withheld', (select coalesce(sum(amount), 0) from wht_deductions where vendor_id = v.id and kind = 'wht' and status in ('deducted', 'remitted')),
    'tin_status', v.tin_status, 'tin_checked_at', v.tin_checked_at, 'tin_check', v.tin_check,
    'bills_held', (select count(*) from bills b where b.vendor_id = v.id and b.status in ('draft', 'approved', 'partially_paid') and private.bill_tin_hold(b.id) is not null));
end $$;


create or replace function public.svc_prism_bill(p_org uuid, p_bill jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members; v_ref text := nullif(trim(p_bill->>'prism_id'), '');
begin
  if v_ref is null then raise exception 'prism_id is required.'; end if;
  select * into b from bills where org_id = p_org and source = 'prism' and external_ref = v_ref;
  if found then return jsonb_build_object('duplicate', true, 'bill', private.bill_json(b.id)); end if;
  select * into m from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
  b := private.write_bill(p_org, (p_bill - 'id' - 'status') || jsonb_build_object('source', 'prism', 'external_ref', v_ref), m);
  update bills set created_by = null, invoice_tin = nullif(trim(coalesce(p_bill->'vendor'->>'tin', p_bill->>'vendor_tin')), '') where id = b.id;
  perform private.notify_perm(p_org, 'keep_books', 'bill', 'New bill from Prism: ' || (select name from vendors where id = b.vendor_id),
    '₦' || to_char(b.total, 'FM999,999,999,990.00') || coalesce(' · ' || b.vendor_ref, '') || ' · check and approve it', '/purchases/bills?open=' || b.id, 'bill-' || b.id);
  return jsonb_build_object('duplicate', false, 'bill', private.bill_json(b.id));
end $$;


-- ---------------------------------------------------------------------------
-- 3. Periods
-- ---------------------------------------------------------------------------
-- Home: income and profit for a period (this month when none is given) beside the period before it, and the balances at its
-- end (today's working figures when it ends today).
drop function if exists public.get_finance_overview(uuid);
create or replace function public.get_finance_overview(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_today date; v_cashacc text[]; v_cash numeric; v_burn numeric; v_in numeric; t jsonb; tl jsonb; v_fy date;
  v_from date; v_to date; v_pfrom date; v_pto date; v_now boolean;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then return null; end if;
  v_today := private.local_day(p_org, now());
  v_to := least(coalesce(p_to, v_today), v_today);
  v_from := least(coalesce(p_from, date_trunc('month', v_to)::date), v_to);
  v_now := v_to = v_today;
  -- The period before: a whole month (or this month so far) beside the whole month before; any other period beside the
  -- same number of days just before it.
  if v_from = date_trunc('month', v_from)::date and (v_to = (date_trunc('month', v_from) + interval '1 month - 1 day')::date or (p_from is null and p_to is null)) then
    v_pfrom := (v_from - interval '1 month')::date; v_pto := v_from - 1;
  else
    v_pfrom := v_from - (v_to - v_from + 1); v_pto := v_from - 1;
  end if;
  v_fy := private.fy_start(p_org, v_to);
  select array_agg(code) into v_cashacc from private.acct_meta(p_org) where ifrs_line = 'Cash and cash equivalents';
  select coalesce(sum(bal), 0) into v_cash from private.balances_at(p_org, v_to) where code = any(v_cashacc);
  select coalesce(sum(l.credit - l.debit) filter (where l.credit > l.debit), 0), coalesce(sum(l.debit - l.credit) filter (where l.debit > l.credit), 0) into v_burn, v_in
  from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and l.account_code = any(v_cashacc) and j.entry_date between v_to - 29 and v_to
    and not exists (select 1 from journal_lines x where x.journal_id = j.id and x.account_code = any(v_cashacc) and x.id <> l.id);
  t := private.pl_totals(private.pl_map(p_org, v_from, v_to));
  tl := private.pl_totals(private.pl_map(p_org, v_pfrom, v_pto));
  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'prev_from', v_pfrom, 'prev_to', v_pto, 'as_at_today', v_now,
    'cash', v_cash,
    'receivables', case when v_now then (select coalesce(sum(total - amount_paid - credited), 0) from sales where org_id = p_org and status in ('open', 'partially_paid') and journal_id is not null)
      else private.role_balance(p_org, 'receivables', v_to) end,
    'receivables_overdue', case when v_now then (select coalesce(sum(total - amount_paid - credited), 0) from sales where org_id = p_org and status in ('open', 'partially_paid') and journal_id is not null and due_date < v_today) end,
    'payables', case when v_now then (select coalesce(sum(total - amount_paid), 0) from bills where org_id = p_org and status in ('approved', 'partially_paid'))
      else private.role_balance(p_org, 'payables', v_to, true) end,
    'bills_to_pay', case when v_now then (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid')) end,
    'revenue', private.v(t, 'revenue'), 'gross_profit', private.v(t, 'gross_profit'), 'profit', private.v(t, 'profit'),
    'revenue_prev', private.v(tl, 'revenue'), 'profit_prev', private.v(tl, 'profit'),
    'revenue_mtd', private.v(t, 'revenue'), 'gross_profit_mtd', private.v(t, 'gross_profit'), 'profit_mtd', private.v(t, 'profit'),
    'revenue_last_month', private.v(tl, 'revenue'), 'profit_last_month', private.v(tl, 'profit'),
    'revenue_ytd', private.v(private.pl_totals(private.pl_map(p_org, v_fy, v_to)), 'revenue'),
    'gross_burn_30d', v_burn, 'net_burn_30d', v_burn - v_in,
    'runway_months', case when v_burn - v_in > 0 and v_cash > 0 then round(v_cash / (v_burn - v_in), 1) when v_burn - v_in > 0 then 0 end,
    'vat_payable', -coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '2201'), 0)
                   - coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '1402'), 0),
    'suspense', coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code like '9%'), 0),
    'inbox', (select count(*) from ai_proposals where org_id = p_org and status = 'pending'),
    'closed_through', private.closed_through(p_org));
end $$;


-- Payments: p_filter {from, to} (days in the business's time zone) narrows the requests, payouts and bulk payments to that
-- period; without one, requests from the last 60 days and the latest payouts and batches come back as before.
drop function if exists public.get_payments(uuid);
create or replace function public.get_payments(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; w public.wallets; v_money boolean; v_from date := nullif(p_filter->>'from', '')::date;
  v_to date := nullif(p_filter->>'to', '')::date; v_lo timestamptz; v_hi timestamptz;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_lo := case when v_from is not null then (v_from::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
  v_hi := case when v_to is not null then ((v_to + 1)::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
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
      from (select * from payment_requests where org_id = p_org
              and created_at >= coalesce(v_lo, case when v_hi is null then now() - interval '60 days' end, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) r
      left join customers c on c.id = r.customer_id),
    'payouts', case when v_money then (select coalesce(jsonb_agg(to_jsonb(p) - 'raw' - 'lines' || jsonb_build_object(
        'requested_by_name', (select display_name from members where id = p.requested_by), 'approved_by_name', (select display_name from members where id = p.approved_by),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from payouts where org_id = p_org and batch_id is null and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) p) end,
    'batches', case when v_money then (select coalesce(jsonb_agg(private.batch_json(b.id, false) order by b.created_at desc), '[]'::jsonb)
      from (select id, created_at from payout_batches where org_id = p_org and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 100 else 500 end) b) end,
    'reconciliations', case when v_money then (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
      from (select * from wallet_reconciliations where org_id = p_org order by at desc limit 30) x) end,
    'can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'), 'open_wallet', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'settings', m.role = 'owner'),
    'me', m.id, 'period', case when v_from is not null or v_to is not null then jsonb_build_object('from', v_from, 'to', v_to) end);
end $$;


-- Banking: p_filter {from, to} narrows the bank lines to those days; each account says the first day it has lines for, so
-- the screen can ask for statements before it.
drop function if exists public.get_banking(uuid);
create or replace function public.get_banking(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_from date := nullif(p_filter->>'from', '')::date; v_to date := nullif(p_filter->>'to', '')::date;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see bank accounts.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', (select coalesce(jsonb_agg(to_jsonb(b) - 'provider_meta' || jsonb_build_object(
        'book_balance', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = b.ledger_code),
        'unmatched', (select count(*) from bank_lines where bank_account_id = b.id and status = 'unmatched'),
        'questions', (select count(*) from bank_lines where bank_account_id = b.id and status = 'proposed'),
        'last_line', (select max(line_date) from bank_lines where bank_account_id = b.id),
        'first_line', (select min(line_date) from bank_lines where bank_account_id = b.id),
        'feed', private.feed_json(b.id),
        'last_import', (select jsonb_build_object('file_name', i.file_name, 'source', i.source, 'created_at', i.created_at, 'from', coalesce(i.period_from, i.from_date),
            'to', coalesce(i.period_to, i.to_date), 'added', i.lines_added, 'balance_check', i.balance_check, 'closing_balance', i.closing_balance)
          from bank_imports i where i.bank_account_id = b.id and i.source <> 'feed' order by i.created_at desc limit 1),
        'last_reconciliation', (select jsonb_build_object('as_of', as_of, 'status', status, 'difference', difference) from bank_reconciliations
           where bank_account_id = b.id order by as_of desc limit 1)) order by b.kind, b.name), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active),
    'lines', (select coalesce(jsonb_agg(to_jsonb(x) - 'fingerprint' || jsonb_build_object('journal_ref', (select ref from journals where id = x.journal_id),
        'account_name', (select name from bank_accounts where id = x.bank_account_id)) order by x.line_date desc, x.created_at desc), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org and line_date >= coalesce(v_from, '-infinity'::date) and line_date <= coalesce(v_to, 'infinity'::date)
            order by line_date desc, created_at desc limit case when v_from is null and v_to is null then 1000 else 5000 end) x),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'),
    'clearing', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9002'),
    'rules', (select coalesce(jsonb_agg(to_jsonb(r) order by r.hits desc), '[]'::jsonb) from entity_rules r where r.org_id = p_org));
end $$;


-- ---------------------------------------------------------------------------
-- 4. Bank feeds back to January 2023
-- ---------------------------------------------------------------------------
-- The mono edge function fetches a linked account's history in windows, oldest first, and records how far it has got
-- (provider_meta.history_to, history_done) so the next run carries on from there even through months with no transactions.
create or replace function public.svc_feed_accounts(p_org uuid default null) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'org_id', b.org_id, 'mono_id', b.provider_ref, 'name', b.name,
      'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date', 'history_to', b.provider_meta->>'history_to',
      'history_done', coalesce((b.provider_meta->>'history_done')::boolean, false), 'data_status', b.provider_meta->>'data_status',
      'linked_at', b.provider_meta->>'linked_at', 'books_start', (select books_start from orgs where id = b.org_id),
      'reauth_required', coalesce((b.provider_meta->>'reauth_required')::boolean, false))
    order by coalesce(b.provider_meta->>'last_synced_at', '') asc), '[]'::jsonb)
  from bank_accounts b where b.provider = 'mono' and b.provider_ref is not null and b.active and (p_org is null or b.org_id = p_org)
$$;


create or replace function public.svc_feed_account(p_mono_id text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', b.id, 'org_id', b.org_id, 'mono_id', b.provider_ref, 'last_synced_at', b.provider_meta->>'last_synced_at',
    'last_line_date', b.provider_meta->>'last_line_date', 'linked_at', b.provider_meta->>'linked_at', 'history_to', b.provider_meta->>'history_to',
    'history_done', coalesce((b.provider_meta->>'history_done')::boolean, false), 'data_status', b.provider_meta->>'data_status')
  from bank_accounts b where b.provider = 'mono' and b.provider_ref = p_mono_id and b.active
$$;


create or replace function public.bank_feed_account(p_bank_account uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  select * into b from bank_accounts where id = p_bank_account;
  if not found then raise exception 'Account not found.'; end if;
  perform private.require(b.org_id, 'keep_books');
  return jsonb_build_object('id', b.id, 'org_id', b.org_id, 'name', b.name, 'provider', b.provider, 'mono_id', case when b.provider = 'mono' then b.provider_ref end,
    'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date', 'linked_at', b.provider_meta->>'linked_at',
    'history_to', b.provider_meta->>'history_to', 'history_done', coalesce((b.provider_meta->>'history_done')::boolean, false),
    'books_start', (select books_start from orgs where id = b.org_id));
end $$;


create or replace function private.feed_json(p_bank_account uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when b.provider = 'mono' then jsonb_build_object('provider', 'mono', 'linked', true,
    'institution', b.provider_meta->'institution'->>'name', 'data_status', b.provider_meta->>'data_status',
    'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date',
    'balance', (b.provider_meta->>'balance')::numeric, 'balance_at', b.provider_meta->>'balance_at',
    'reauth_required', coalesce((b.provider_meta->>'reauth_required')::boolean, false), 'last_error', b.provider_meta->>'last_error',
    'lines', (select count(*) from bank_lines where bank_account_id = b.id and source = 'api'),
    'first_feed_line', (select min(line_date) from bank_lines where bank_account_id = b.id and source = 'api'),
    'history_to', b.provider_meta->>'history_to', 'history_from', b.provider_meta->>'history_from', 'history_done', coalesce((b.provider_meta->>'history_done')::boolean, false))
    else jsonb_build_object('linked', false) end
  from bank_accounts b where b.id = p_bank_account
$$;


-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
grant execute on function public.tin_check_target(uuid, uuid), public.confirm_tin(uuid, uuid), public.get_finance_overview(uuid, date, date),
  public.get_payments(uuid, jsonb), public.get_banking(uuid, jsonb) to authenticated;
revoke execute on function public.tin_check_target(uuid, uuid), public.confirm_tin(uuid, uuid), public.get_finance_overview(uuid, date, date),
  public.get_payments(uuid, jsonb), public.get_banking(uuid, jsonb) from public, anon;
revoke all on function public.svc_tin_result(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_tin_result(uuid, uuid, jsonb) to service_role;
revoke all on function private.taxpayer_words(text), private.same_taxpayer(text, text), private.bill_tin_hold(uuid), private.tin_hold_text(text, text, text),
  private.vendor_tin_status(), private.org_tin_status(), private.bill_invoice_tin_in(), private.bill_invoice_tin_apply() from public, anon, authenticated;
