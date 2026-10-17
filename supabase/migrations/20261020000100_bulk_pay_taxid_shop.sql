-- Counta · Photo uploads that work, the Tax ID, shop descriptions and bulk payments.
--
-- 1. Storage: uploads to item-photos ran as an upsert, which Postgres checks against a SELECT policy as well as INSERT
--    and UPDATE. The bucket had no SELECT policy, so every logo and product photo was refused with "new row violates
--    row-level security policy". Members can now read their own business's folder. The bucket stays public, so the
--    shop and documents show the pictures to anyone with the link.
-- 2. Tax ID: the 13-digit number that replaced the TIN. A number typed in by hand must have 13 digits (customers abroad
--    excepted). Numbers already on file, imports and TaxStreem sign-in are left as they are, so an old TIN keeps
--    printing until someone replaces it. Statements and checks say "Tax ID".
-- 3. Shop: a storefront description per item, separate from the staff note.
-- 4. Bulk payments: a sheet of payments checked, approved once and sent from the wallet, with one result per row.

-- ---------------------------------------------------------------------------
-- 1. Storage
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "photos read by members" on storage.objects;
    create policy "photos read by members" on storage.objects for select to authenticated
      using (bucket_id = 'item-photos' and (select private.is_member_text((storage.foldername(name))[1])));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Tax ID
-- ---------------------------------------------------------------------------
create or replace function private.clean_tax_id(p text) returns text
language sql immutable set search_path = public as $$
  select nullif(regexp_replace(coalesce(p, ''), '[\s\-./]', '', 'g'), '')
$$;

-- A Tax ID typed in by hand has 13 digits. The number already on file is kept as it is (an old TIN keeps working)
-- until someone types a different one.
create or replace function private.tax_id_input(p_new text, p_old text, p_who text) returns text
language plpgsql immutable set search_path = public, private as $$
declare v text := private.clean_tax_id(p_new);
begin
  if v is null then return null; end if;
  if v is not distinct from private.clean_tax_id(p_old) then return p_old; end if;
  if v !~ '^[0-9]{13}$' then
    raise exception '% must have 13 digits. Individuals get theirs from their NIN and companies from their RC number on the NRS Tax ID portal.', p_who;
  end if;
  return v;
end $$;

create or replace function public.update_org_settings(p_org uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_rev text;
begin
  m := private.require(p_org, 'owner');
  v_rev := nullif(p_patch->>'revenue_account', '');
  if v_rev is not null and v_rev !~ '^41(0[1-9]|1[0-9]|2[01])$' then raise exception 'Choose a revenue account from 4101 to 4121.'; end if;
  if p_patch ? 'fiscal_year_start' and coalesce((p_patch->>'fiscal_year_start')::int, 0) not between 1 and 12 then raise exception 'Choose the month the financial year ends.'; end if;
  update orgs set
    name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    email = case when p_patch ? 'email' then nullif(trim(p_patch->>'email'), '') else email end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    tin = case when p_patch ? 'tin' then private.tax_id_input(p_patch->>'tin', tin, 'Your Tax ID') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    logo_path = case when p_patch ? 'logo_path' then nullif(trim(p_patch->>'logo_path'), '') else logo_path end,
    legal_form = coalesce(nullif(p_patch->>'legal_form', ''), legal_form),
    fiscal_year_start = coalesce((p_patch->>'fiscal_year_start')::int, fiscal_year_start),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered),
    prices_include_vat = coalesce((p_patch->>'prices_include_vat')::boolean, prices_include_vat),
    invoice_terms_days = coalesce((p_patch->>'invoice_terms_days')::int, invoice_terms_days),
    invoice_note = case when p_patch ? 'invoice_note' then nullif(trim(p_patch->>'invoice_note'), '') else invoice_note end,
    revenue_account = coalesce(v_rev, revenue_account),
    cash_sales_without_invoices = coalesce((p_patch->>'cash_sales_without_invoices')::boolean, cash_sales_without_invoices),
    capitalisation_threshold = coalesce((p_patch->>'capitalisation_threshold')::numeric, capitalisation_threshold),
    auto_post_threshold = coalesce((p_patch->>'auto_post_threshold')::numeric, auto_post_threshold),
    books_start = case when p_patch ? 'books_start' then private.date_or_null(p_patch->>'books_start') else books_start end
  where id = p_org;
  if v_rev is not null then
    insert into posting_rules (org_id, role, account_code, updated_by) values (p_org, 'sales_revenue', v_rev, m.id)
    on conflict (org_id, role) do update set account_code = excluded.account_code, updated_by = excluded.updated_by, updated_at = now();
  end if;
end $$;

-- Customers in Nigeria have a Tax ID; a customer abroad keeps whatever tax number their country uses.
create or replace function public.save_customer(p_org uuid, p_customer jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.customers; v_country text;
begin
  m := private.require(p_org, 'record_sales');
  if p_customer ? 'tin' then
    if nullif(p_customer->>'id', '') is not null then
      select * into c from customers where id = (p_customer->>'id')::uuid and org_id = p_org;
    end if;
    v_country := coalesce(upper(nullif(trim(p_customer->>'country'), '')), c.country, 'NG');
    p_customer := p_customer || jsonb_build_object('tin', case when v_country = 'NG' then private.tax_id_input(p_customer->>'tin', c.tin, 'The customer''s Tax ID')
      else nullif(left(trim(p_customer->>'tin'), 40), '') end);
  end if;
  return private.upsert_customer(p_org, p_customer, m);
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
    tin = case when p_patch ? 'tin' then private.tax_id_input(p_patch->>'tin', tin, 'The vendor''s Tax ID') else tin end,
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

-- A bill typed in for a new vendor carries that vendor's Tax ID. Bills read from invoices by the books inbox keep
-- whatever number the invoice prints.
create or replace function public.save_bill(p_org uuid, p_bill jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bills;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_pos')) then
    raise exception 'Only someone who keeps the books or approves purchases enters bills.' using errcode = '42501';
  end if;
  if nullif(p_bill->>'vendor_id', '') is null and jsonb_typeof(p_bill->'vendor') = 'object' and nullif(trim(p_bill->'vendor'->>'tin'), '') is not null
     and not exists (select 1 from vendors where org_id = p_org and lower(name) = lower(trim(p_bill->'vendor'->>'name'))) then
    p_bill := jsonb_set(p_bill, '{vendor,tin}', to_jsonb(private.tax_id_input(p_bill->'vendor'->>'tin', null, 'The vendor''s Tax ID')));
  end if;
  b := private.write_bill(p_org, p_bill - 'source' - 'external_ref', m);
  if p_bill->>'status' = 'approve' then return public.approve_bill(b.id); end if;
  return private.bill_json(b.id);
end $$;

-- The statements, their notes and the checks before printing say "Tax ID".
do $$
declare f text; v_def text;
begin
  foreach f in array array['private.note_rows(uuid,date,date,date,date,date)', 'public.statement_extra(uuid,text,date,date,jsonb)',
                           'public.financial_statements_pack(uuid,date,date)'] loop
    if to_regprocedure(f) is null then continue; end if;
    v_def := pg_get_functiondef(to_regprocedure(f));
    v_def := replace(v_def, 'Its tax identification number is ', 'Its Tax ID is ');
    v_def := replace(v_def, 'Tax identification number', 'Tax ID');
    v_def := replace(v_def, 'Add the RC number and TIN under', 'Add the RC number and Tax ID under');
    execute v_def;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Shop descriptions
-- ---------------------------------------------------------------------------
alter table public.items add column if not exists shop_description text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'items_shop_description_len') then
    alter table public.items add constraint items_shop_description_len check (shop_description is null or length(shop_description) <= 4000);
  end if;
end $$;
-- The shop used to show the staff note. Items already on sale keep that text as their storefront description, and
-- from now on the two are kept apart.
update public.items set shop_description = left(description, 4000)
where shop_description is null and nullif(trim(description), '') is not null and not archived and price > 0 and item_type in ('merchandise', 'finished_good');

create or replace function public.set_item_shop_details(p_item uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  if not (private.has_perm(it.org_id, 'edit_prices') or private.has_perm(it.org_id, 'receive_stock') or private.has_perm(it.org_id, 'count_stock')) then
    raise exception 'Your role does not allow this.' using errcode = '42501';
  end if;
  if length(coalesce(p->>'shop_description', '')) > 4000 then raise exception 'Keep the shop description under 4,000 characters.'; end if;
  update items set shop_description = case when p ? 'shop_description' then nullif(trim(p->>'shop_description'), '') else shop_description end
  where id = p_item returning * into it;
  return jsonb_build_object('id', it.id, 'shop_description', it.shop_description, 'photo_path', it.photo_path);
end $$;

create or replace function public.shop_catalog(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  return jsonb_build_object(
    'shop', jsonb_build_object('slug', o.shop_slug, 'name', o.name, 'title', coalesce(o.shop_title, o.name), 'note', o.shop_note, 'whatsapp', o.shop_whatsapp,
      'phone', o.phone, 'email', o.email, 'address', o.address, 'website', o.website, 'logo_path', o.logo_path, 'banner_path', o.shop_banner_path,
      'tagline', o.shop_tagline, 'brand_color', o.brand_color, 'socials', o.shop_socials, 'delivery_fee', o.shop_delivery_fee, 'pickup', o.shop_pickup,
      'delivery', o.shop_delivery, 'pay_on_delivery', o.shop_pay_on_delivery, 'min_order', o.shop_min_order,
      'pickup_address', (select coalesce(nullif(l.address, ''), o.address) from locations l where l.id = coalesce(o.shop_location_id,
        (select id from locations where org_id = o.id order by is_main desc, created_at limit 1))),
      'vat_registered', o.vat_registered, 'prices_include_vat', o.prices_include_vat,
      'online_payments', exists (select 1 from wallets w where w.org_id = o.id and w.rail = o.payment_rail and w.status = 'active')),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'category', i.category, 'brand', i.brand,
        'description', i.shop_description, 'price', i.price, 'unit', i.selling_unit, 'photo_path', i.photo_path,
        'available', coalesce(st.qty, 0) > 0,
        'stock', case when o.shop_show_stock then greatest(floor(coalesce(st.qty, 0)), 0) end) order by i.category nulls last, i.name), '[]'::jsonb)
      from items i
      left join (select item_id, sum(qty) qty from stock_levels where org_id = o.id and (o.shop_location_id is null or location_id = o.shop_location_id) group by item_id) st
        on st.item_id = i.id
      where i.org_id = o.id and not i.archived and i.price > 0 and i.item_type in ('merchandise', 'finished_good')
        and (o.shop_categories is null or i.category = any(o.shop_categories))));
end $$;

-- ---------------------------------------------------------------------------
-- 4. Bulk payments
-- ---------------------------------------------------------------------------
create table if not exists public.payout_batches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  title text not null,
  wallet_id uuid not null references public.wallets(id),
  default_account text,
  status text not null default 'pending_approval'
    check (status in ('pending_approval', 'approved', 'sending', 'completed', 'partly_failed', 'failed', 'cancelled')),
  -- 'transfers': one Flutterwave transfer per row from the business wallet. 'bulk': one Flutterwave bulk transfer.
  mode text not null default 'transfers' check (mode in ('transfers', 'bulk')),
  row_count int not null default 0,
  total numeric(16,2) not null default 0,
  wht_total numeric(16,2) not null default 0,
  fee_estimate numeric(16,2) not null default 0,
  paid_count int not null default 0,
  paid_total numeric(16,2) not null default 0,
  failed_count int not null default 0,
  failed_total numeric(16,2) not null default 0,
  cancelled_count int not null default 0,
  fee_total numeric(16,2) not null default 0,
  file_name text,
  provider_batch_ids text[] not null default '{}',
  requested_by uuid references public.members(id) on delete set null,
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  sent_by uuid references public.members(id) on delete set null,
  sent_at timestamptz,
  completed_at timestamptz,
  note text,
  client_uuid uuid unique,
  created_at timestamptz not null default now(),
  unique (org_id, number)
);
create index if not exists payout_batches_org on public.payout_batches(org_id, created_at desc);
create index if not exists payout_batches_wallet_fk on public.payout_batches(wallet_id);
create index if not exists payout_batches_requested_by_fk on public.payout_batches(requested_by);
create index if not exists payout_batches_approved_by_fk on public.payout_batches(approved_by);
create index if not exists payout_batches_sent_by_fk on public.payout_batches(sent_by);
create index if not exists payout_batches_open on public.payout_batches(status) where status in ('pending_approval', 'approved', 'sending');
alter table public.payout_batches enable row level security;
drop policy if exists payout_batches_read on public.payout_batches;
create policy payout_batches_read on public.payout_batches for select to authenticated using ((select private.can_handle_money(org_id)));

alter table public.payouts add column if not exists batch_id uuid references public.payout_batches(id) on delete set null;
alter table public.payouts add column if not exists batch_row int;
alter table public.payouts add column if not exists your_reference text;
create index if not exists payouts_batch on public.payouts(batch_id, batch_row) where batch_id is not null;

-- What Flutterwave charges for one NGN transfer, for the estimate shown before sending. The fee it reports is what posts.
create or replace function private.transfer_fee(p_amount numeric) returns numeric
language sql immutable set search_path = public as $$
  select case when p_amount <= 5000 then 10.75 when p_amount <= 50000 then 26.88 else 53.75 end::numeric
$$;

-- Payouts made inside a bulk payment take the batch's status, carry its row number and send no notice of their own.
create or replace function private.create_payout(p_org uuid, p jsonb, p_lines jsonb, m public.members) returns public.payouts
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; po public.payouts; v_amt numeric := round(private.num(p->>'amount'), 2); v_status text; v_inflight numeric;
  v_batch uuid := nullif(current_setting('counta.payout_batch', true), '')::uuid; v_row jsonb := nullif(current_setting('counta.payout_row', true), '')::jsonb;
  pb public.payout_batches;
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
  if v_batch is not null then
    select * into pb from payout_batches where id = v_batch and org_id = p_org;
    if not found then raise exception 'Bulk payment not found.'; end if;
    v_status := pb.status;
  else
    v_status := case when o.payout_approval_threshold > 0 and v_amt >= o.payout_approval_threshold and m.role <> 'owner' then 'pending_approval' else 'approved' end;
  end if;
  insert into payouts (org_id, number, wallet_id, purpose, vendor_id, customer_id, to_bank_account_id, amount, bank_code, bank_name, account_number, account_name,
    narration, lines, reference, status, requested_by, approved_by, approved_at, client_uuid, batch_id, batch_row, your_reference)
  values (p_org, 'PO-' || lpad(private.next_no(p_org, 'PO', 1)::text, 5, '0'), w.id, coalesce(nullif(p->>'purpose', ''), 'other'),
    nullif(p->>'vendor_id', '')::uuid, nullif(p->>'customer_id', '')::uuid, nullif(p->>'to_bank_account_id', '')::uuid, v_amt, trim(p->>'bank_code'),
    nullif(trim(p->>'bank_name'), ''), p->>'account_number', left(trim(p->>'account_name'), 120), left(coalesce(nullif(trim(p->>'narration'), ''), o.name), 80),
    p_lines, 'CNTP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), v_status, m.id,
    case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid,
    pb.id, case when pb.id is not null then (v_row->>'row')::int end, case when pb.id is not null then nullif(left(trim(v_row->>'ref'), 60), '') end)
  returning * into po;
  if v_status = 'pending_approval' and pb.id is null then
    perform private.notify_perm(p_org, 'make_payments', 'payout', 'Approve a payout of ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
      po.account_name || ' · ' || po.narration || ' · asked by ' || coalesce(m.display_name, ''), '/payments', 'payout-' || po.id, m.id);
  end if;
  return po;
end $$;

-- A row of a bulk payment belongs to its batch: approve the batch, not the row.
create or replace function public.approve_payout(p_payout uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'make_payments');
  if po.batch_id is not null then
    raise exception 'Approve % with its bulk payment %.', po.number, (select number from payout_batches where id = po.batch_id);
  end if;
  if po.status <> 'pending_approval' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  if po.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then nullif(trim(p_note), '') else error end
  where id = po.id returning * into po;
  return to_jsonb(po);
end $$;

-- A batch row that completes or fails is summed up in the batch's own notice, not one notice per row.
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
    if po.batch_id is null then
      perform private.notify_perm(po.org_id, 'make_payments', 'payout', 'Paid ₦' || to_char(po.amount, 'FM999,999,999,990.00') || ' to ' || po.account_name,
        po.narration, '/payments', 'payout-done-' || po.id);
    end if;
  elsif v_status in ('failed', 'error', 'reversed') then
    if po.journal_id is not null then
      perform private.reverse_entry(po.journal_id, po.requested_by, 'Payout ' || po.number || ' reversed by the bank', null);
    end if;
    update payouts set status = case when po.journal_id is not null then 'reversed' else 'failed' end, error = left(coalesce(d->>'error', 'The transfer failed.'), 500),
      raw = coalesce(d->'raw', raw), provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref)
    where id = po.id returning * into po;
    if po.batch_id is null then
      perform private.notify_perm(po.org_id, 'make_payments', 'payout', 'Payout to ' || po.account_name || ' failed', coalesce(po.error, ''), '/payments', 'payout-fail-' || po.id);
    end if;
  else
    update payouts set provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), raw = coalesce(d->'raw', raw),
      fee = round(coalesce(private.num(d->>'fee'), fee), 2) where id = po.id returning * into po;
  end if;
  select * into po from payouts where id = po.id;
  return jsonb_build_object('ok', true, 'status', po.status, 'number', po.number);
end $$;

-- Totals and status of a batch from its rows. Called after any change to its payouts.
create or replace function private.refresh_payout_batch(p_batch uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; c record; v_status text;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then return; end if;
  select count(*) filter (where status = 'pending_approval') pend, count(*) filter (where status = 'approved') appr,
    count(*) filter (where status = 'processing') proc, count(*) filter (where status = 'successful') paid,
    count(*) filter (where status in ('failed', 'reversed')) bad, count(*) filter (where status = 'cancelled') gone,
    coalesce(sum(amount) filter (where status = 'successful'), 0) paid_total, coalesce(sum(amount) filter (where status in ('failed', 'reversed')), 0) bad_total,
    coalesce(sum(fee) filter (where status = 'successful'), 0) fees
  into c from payouts where batch_id = p_batch;
  v_status := case
    when c.pend > 0 then 'pending_approval'
    when c.proc > 0 then 'sending'
    when c.appr > 0 then case when pb.status = 'sending' then 'sending' else 'approved' end
    when c.paid = 0 and c.bad = 0 then 'cancelled'
    when c.bad = 0 then 'completed'
    when c.paid = 0 then 'failed'
    else 'partly_failed' end;
  update payout_batches set status = v_status, paid_count = c.paid, paid_total = c.paid_total, failed_count = c.bad, failed_total = c.bad_total,
    cancelled_count = c.gone, fee_total = c.fees,
    completed_at = case when v_status in ('completed', 'partly_failed', 'failed', 'cancelled') then coalesce(completed_at, now()) else null end
  where id = p_batch;
  if pb.status in ('sending', 'approved') and v_status in ('completed', 'partly_failed', 'failed') then
    perform private.notify_perm(pb.org_id, 'make_payments', 'payout',
      'Bulk payment ' || pb.number || ': ' || c.paid || ' of ' || (c.paid + c.bad) || ' paid',
      pb.title || case when c.bad > 0 then ' · ' || c.bad || ' failed (₦' || to_char(c.bad_total, 'FM999,999,999,990.00') || '), see the results' else '' end,
      '/payments?tab=bulk&batch=' || pb.id, 'batch-done-' || pb.id);
  end if;
end $$;

create or replace function private.on_payouts_batch() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v uuid;
begin
  for v in select distinct batch_id from changed where batch_id is not null loop
    perform private.refresh_payout_batch(v);
  end loop;
  return null;
end $$;
drop trigger if exists payouts_batches on public.payouts;
create trigger payouts_batches after update on public.payouts referencing new table as changed for each statement execute function private.on_payouts_batch();

-- Accounts a bulk payment can be posted to: anything postable except money accounts and the ledgers that need a
-- customer or supplier on every line (those are paid through a bill or the supplier column).
create or replace function private.bulk_account_ok(p_org uuid, p_code text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select p_code is not null and private.postable(p_org, p_code)
    and p_code <> all (array['1102', private.acct(p_org, 'receivables'), private.acct(p_org, 'payables'), private.acct(p_org, 'customer_advances'),
      private.acct(p_org, 'inventory'), private.acct(p_org, 'goods_in_transit'), private.acct(p_org, 'opening_equity'), private.acct(p_org, 'retained_earnings'),
      private.acct(p_org, 'suspense'), private.acct(p_org, 'bank_clearing'), private.acct(p_org, 'cash_on_hand')])
    and not exists (select 1 from bank_accounts where org_id = p_org and ledger_code = p_code)
    and not exists (select 1 from org_accounts where org_id = p_org and code = p_code and kind in ('bank', 'wallet', 'cash'))
$$;

-- One row of a bulk payment sheet against the books. r: {row, name, bank_code, bank_name, account_number, account_name,
-- amount (what the person receives), narration, bill, supplier, account, reference}
create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text;
begin
  if coalesce(r->>'account_number', '') !~ '^[0-9]{10}$' then v_err := v_err || 'Account numbers have 10 digits.'::text; end if;
  if coalesce(trim(r->>'bank_code'), '') = '' then v_err := v_err || 'Choose the bank.'::text; end if;
  if coalesce(trim(r->>'account_name'), '') = '' then v_err := v_err || 'The bank has not confirmed the account name.'::text; end if;
  if v_bill_ref is not null then
    select * into b from bills where org_id = p_org and status <> 'void' and lower(number) = lower(v_bill_ref) limit 1;
    if not found then
      select * into b from bills where org_id = p_org and status in ('approved', 'partially_paid') and lower(vendor_ref) = lower(v_bill_ref)
        and (v_supplier is null or vendor_id in (select id from vendors where org_id = p_org and lower(name) = lower(v_supplier)))
      order by bill_date limit 1;
    end if;
    if b.id is null then
      v_err := v_err || format('No bill %s in Counta.', v_bill_ref);
    else
      select * into v from vendors where id = b.vendor_id;
      v_kind := 'bill'; v_label := b.number || ' · ' || v.name;
      if v_supplier is not null and lower(v.name) <> lower(v_supplier) then
        v_err := v_err || format('%s is from %s, not %s.', b.number, v.name, v_supplier);
      end if;
      if b.status not in ('approved', 'partially_paid') then
        v_err := v_err || format('%s is %s.', b.number, replace(b.status, '_', ' '));
      else
        v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
        v_left_wht := greatest(b.wht_expected - coalesce((select sum(wht) from bill_payments where bill_id = b.id and status in ('paid', 'processing')), 0), 0);
        v_full_net := v_due - v_left_wht;
        v_rate := coalesce(b.wht_expected / nullif(b.total, 0), 0);
        if v_due <= 0.004 then
          v_err := v_err || format('Nothing is left to pay on %s.', b.number);
        elsif v_amt is null then
          v_gross := v_due; v_wht := v_left_wht; v_amt := v_full_net;
        elsif v_amt > v_full_net + 0.004 then
          v_err := v_err || format('%s has ₦%s left to pay, which is ₦%s after withholding tax.', b.number,
            to_char(v_due, 'FM999,999,999,990.00'), to_char(v_full_net, 'FM999,999,999,990.00'));
        elsif v_amt >= v_full_net - 0.004 then
          v_gross := v_due; v_wht := v_due - v_amt;
        else
          v_gross := round(v_amt / (1 - v_rate), 2); v_wht := v_gross - v_amt;
        end if;
        v_purpose := 'vendor';
      end if;
    end if;
  elsif v_supplier is not null then
    select * into v from vendors where org_id = p_org and lower(name) = lower(v_supplier) limit 1;
    if not found then
      v_err := v_err || format('No supplier named %s in Counta.', v_supplier);
    else
      v_kind := 'vendor'; v_purpose := 'vendor'; v_gross := v_amt; v_label := v.name || ' · on account';
      v_lines := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_amt, 'party_type', 'vendor', 'party_id', v.id,
        'memo', 'Paid on account · ' || coalesce(nullif(trim(r->>'narration'), ''), v.name)));
    end if;
  else
    v_code := coalesce(nullif(trim(r->>'account'), ''), p_default);
    if v_code is null then
      v_err := v_err || 'Say what this payment is for: a bill number, a supplier or an account code.'::text;
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
    'amount', v_amt, 'gross', v_gross, 'wht', v_wht, 'fee', case when v_amt is not null then private.transfer_fee(v_amt) end,
    'bill_id', b.id, 'bill_number', b.number, 'vendor_id', v.id, 'vendor_name', v.name, 'account', v_code, 'purpose', v_purpose, 'lines', v_lines);
end $$;

-- p: {title, default_account, rows:[...], file_name, client_uuid}
create or replace function private.bulk_check(p_org uuid, p jsonb, m public.members) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; v_default text := nullif(trim(p->>'default_account'), ''); x jsonb; res jsonb; v_rows jsonb := '[]'::jsonb;
  v_bills uuid[] := '{}'; v_total numeric := 0; v_wht numeric := 0; v_fees numeric := 0; v_ok int := 0; v_bad int := 0; v_avail numeric; v_n int;
begin
  select * into o from orgs where id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments first.'; end if;
  if v_default is not null and not private.bulk_account_ok(p_org, v_default) then
    raise exception 'Account % cannot take a payment. Choose an expense or liability account.', v_default;
  end if;
  v_n := jsonb_array_length(coalesce(p->'rows', '[]'::jsonb));
  if v_n = 0 then raise exception 'The file has no payments.'; end if;
  if v_n > 500 then raise exception 'Send at most 500 payments in one bulk payment.'; end if;
  for x in select value from jsonb_array_elements(p->'rows') loop
    res := private.bulk_row(p_org, x, v_default);
    if (res->>'bill_id') is not null then
      if (res->>'bill_id')::uuid = any(v_bills) then
        res := res || jsonb_build_object('ok', false, 'errors', (res->'errors') || to_jsonb(format('%s appears more than once in this file. Pay it on one row.', res->>'bill_number')));
      end if;
      v_bills := v_bills || (res->>'bill_id')::uuid;
    end if;
    if (res->>'ok')::boolean then
      v_ok := v_ok + 1; v_total := v_total + (res->>'amount')::numeric; v_wht := v_wht + coalesce((res->>'wht')::numeric, 0); v_fees := v_fees + (res->>'fee')::numeric;
    else
      v_bad := v_bad + 1;
    end if;
    v_rows := v_rows || jsonb_build_array(res);
  end loop;
  v_avail := private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval')), 0);
  return jsonb_build_object('rows', v_rows, 'ok_count', v_ok, 'error_count', v_bad, 'total', v_total, 'wht_total', v_wht, 'fee_estimate', v_fees,
    'available', v_avail, 'short', greatest(v_total + v_fees - v_avail, 0),
    'needs_approval', o.payout_approval_threshold > 0 and v_total >= o.payout_approval_threshold and m.role <> 'owner',
    'mode', case when exists (select 1 from payment_rails where code = w.rail and 'bulk_payout' = any(capabilities)) then 'bulk' else 'transfers' end,
    'wallet_id', w.id);
end $$;

create or replace function public.check_payout_batch(p_org uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'make_payments');
  return private.bulk_check(p_org, p, m) - 'wallet_id';
end $$;

create or replace function private.batch_json(p_batch uuid, p_rows boolean default true) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(b) || jsonb_build_object(
    'requested_by_name', (select display_name from members where id = b.requested_by),
    'approved_by_name', (select display_name from members where id = b.approved_by),
    'sent_by_name', (select display_name from members where id = b.sent_by),
    'pending_count', (select count(*) from payouts where batch_id = b.id and status = 'pending_approval'),
    'approved_count', (select count(*) from payouts where batch_id = b.id and status = 'approved'),
    'processing_count', (select count(*) from payouts where batch_id = b.id and status = 'processing'),
    'rows', case when p_rows then (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'row', p.batch_row, 'number', p.number, 'reference', p.reference,
        'your_reference', p.your_reference, 'account_name', p.account_name, 'bank_name', p.bank_name, 'bank_code', p.bank_code, 'account_number', p.account_number,
        'amount', p.amount, 'fee', p.fee, 'narration', p.narration, 'purpose', p.purpose, 'status', p.status, 'error', p.error, 'sent_at', p.sent_at,
        'completed_at', p.completed_at, 'provider_ref', p.provider_ref, 'journal_ref', (select ref from journals where id = p.journal_id),
        'bill_number', bp.number, 'wht', bp.wht, 'gross', bp.gross, 'vendor_name', (select name from vendors where id = p.vendor_id),
        'account_code', case when p.vendor_id is null then p.lines->0->>'code' end,
        'account_label', case when p.vendor_id is null and p.lines->0->>'code' is not null then private.account_name(p.org_id, p.lines->0->>'code') end)
      order by p.batch_row, p.created_at), '[]'::jsonb)
      from payouts p
      left join lateral (select b2.number, x.wht, x.gross from bill_payments x join bills b2 on b2.id = x.bill_id where x.payout_id = p.id limit 1) bp on true
      where p.batch_id = b.id) end)
  from payout_batches b where b.id = p_batch
$$;

-- Creates the batch and one payout per row. Bills are paid through pay_bill, so withholding tax is deducted and the
-- bill clears when the bank confirms.
create or replace function public.create_payout_batch(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; c jsonb; pb public.payout_batches; r jsonb; v_src jsonb; v_status text; v_title text; v_first text;
begin
  m := private.require(p_org, 'make_payments');
  if nullif(p->>'client_uuid', '') is not null then
    select * into pb from payout_batches where client_uuid = (p->>'client_uuid')::uuid and org_id = p_org;
    if found then return private.batch_json(pb.id); end if;
  end if;
  select * into o from orgs where id = p_org;
  c := private.bulk_check(p_org, p, m);
  if (c->>'error_count')::int > 0 then
    select format('Row %s: %s', x->>'row', x->'errors'->>0) into v_first from jsonb_array_elements(c->'rows') x where not (x->>'ok')::boolean limit 1;
    raise exception '%', v_first;
  end if;
  if (c->>'total')::numeric + (c->>'fee_estimate')::numeric > (c->>'available')::numeric + 0.004 then
    raise exception 'The wallet has ₦% available. These payments need ₦% with transfer fees. Fund the wallet first.',
      to_char((c->>'available')::numeric, 'FM999,999,999,990.00'), to_char((c->>'total')::numeric + (c->>'fee_estimate')::numeric, 'FM999,999,999,990.00');
  end if;
  v_status := case when (c->>'needs_approval')::boolean then 'pending_approval' else 'approved' end;
  v_title := left(coalesce(nullif(trim(p->>'title'), ''), 'Bulk payment ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon YYYY')), 80);
  insert into payout_batches (org_id, number, title, wallet_id, default_account, status, mode, row_count, total, wht_total, fee_estimate, file_name, requested_by,
    approved_by, approved_at, client_uuid)
  values (p_org, 'BP-' || lpad(private.next_no(p_org, 'BP', 1)::text, 5, '0'), v_title, (c->>'wallet_id')::uuid, nullif(trim(p->>'default_account'), ''), v_status,
    c->>'mode', (c->>'ok_count')::int, (c->>'total')::numeric, (c->>'wht_total')::numeric, (c->>'fee_estimate')::numeric, left(nullif(trim(p->>'file_name'), ''), 200),
    m.id, case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid)
  returning * into pb;
  perform set_config('counta.payout_batch', pb.id::text, true);
  for r in select value from jsonb_array_elements(c->'rows') loop
    select value into v_src from jsonb_array_elements(p->'rows') where value->'row' = r->'row' limit 1;
    perform set_config('counta.payout_row', jsonb_build_object('row', r->'row', 'ref', v_src->>'reference')::text, true);
    if r->>'kind' = 'bill' then
      perform public.pay_bill((r->>'bill_id')::uuid, jsonb_build_object('method', 'wallet', 'amount', (r->>'gross')::numeric, 'wht', (r->>'wht')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', nullif(trim(v_src->>'narration'), '')));
    else
      perform private.create_payout(p_org, jsonb_build_object('purpose', r->>'purpose', 'vendor_id', r->>'vendor_id', 'amount', (r->>'amount')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', coalesce(nullif(trim(v_src->>'narration'), ''), v_title)), r->'lines', m);
    end if;
  end loop;
  perform set_config('counta.payout_batch', '', true);
  perform set_config('counta.payout_row', '', true);
  perform private.refresh_payout_batch(pb.id);
  if v_status = 'pending_approval' then
    perform private.notify_perm(p_org, 'make_payments', 'payout',
      'Approve a bulk payment of ₦' || to_char(pb.total, 'FM999,999,999,990.00') || ' to ' || pb.row_count || ' account' || case when pb.row_count = 1 then '' else 's' end,
      pb.number || ' · ' || pb.title || ' · asked by ' || coalesce(m.display_name, ''), '/payments?tab=bulk&batch=' || pb.id, 'batch-' || pb.id, m.id);
  end if;
  return private.batch_json(pb.id);
end $$;

create or replace function public.approve_payout_batch(p_batch uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'make_payments');
  if pb.status <> 'pending_approval' then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  if pb.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payout_batches set approved_by = m.id, approved_at = now(), note = case when not p_approve then nullif(trim(p_note), '') else note end where id = pb.id;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then coalesce(nullif(trim(p_note), ''), 'Not approved') else error end
  where batch_id = pb.id and status = 'pending_approval';
  return private.batch_json(pb.id);
end $$;

-- Cancels what has not gone yet. Rows already sent finish on their own.
create or replace function public.cancel_payout_batch(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members; v_n int;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'make_payments');
  if pb.status not in ('pending_approval', 'approved', 'sending') then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  update payouts set status = 'cancelled', error = coalesce(error, 'Cancelled by ' || coalesce(m.display_name, 'a user'))
  where batch_id = pb.id and status in ('pending_approval', 'approved');
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Nothing is left to cancel: the rest of % has gone to the bank.', pb.number; end if;
  return private.batch_json(pb.id);
end $$;

-- Starts (or carries on) sending an approved batch. Called with the user's own token by the payments edge function.
create or replace function public.payout_batch_to_send(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members; w public.wallets; pr public.payment_rails;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'make_payments');
  if pb.status not in ('approved', 'sending') then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  select * into w from wallets where id = pb.wallet_id;
  if w.status <> 'active' then raise exception 'The wallet is not active.'; end if;
  select * into pr from payment_rails where code = w.rail;
  update payout_batches set status = 'sending', sent_by = coalesce(sent_by, m.id), sent_at = coalesce(sent_at, now()) where id = pb.id returning * into pb;
  -- A batch made for a bulk transfer goes one transfer per row if the rail has since stopped offering bulk transfers.
  return jsonb_build_object('batch', jsonb_build_object('id', pb.id, 'number', pb.number, 'title', pb.title, 'mode', pb.mode,
      'bulk', pb.mode = 'bulk' and 'bulk_payout' = any(pr.capabilities)), 'rail', w.rail, 'rail_kind', pr.kind,
    'wallet', jsonb_build_object('account_ref', w.account_ref, 'barter_id', w.barter_id),
    'remaining', (select count(*) from payouts where batch_id = pb.id and status = 'approved'));
end $$;

-- The edge function takes the next rows to send. Each row moves to "processing" once, so a row is never sent twice
-- even when the page and the five-minute check run at the same moment.
create or replace function public.svc_batch_claim(p_batch uuid, p_limit int) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v jsonb;
begin
  if not exists (select 1 from payout_batches where id = p_batch and status = 'sending') then return '[]'::jsonb; end if;
  with picked as (
    select id from payouts where batch_id = p_batch and status = 'approved' order by batch_row nulls last, created_at limit greatest(least(p_limit, 100), 1)
    for update skip locked
  ), done as (
    update payouts p set status = 'processing', sent_at = now() from picked where p.id = picked.id returning p.*
  )
  select coalesce(jsonb_agg(to_jsonb(done) - 'lines' - 'raw' order by batch_row), '[]'::jsonb) into v from done;
  return v;
end $$;

-- d: {provider_batch_id}
create or replace function public.svc_batch_update(p_batch uuid, d jsonb) returns void
language sql security definer set search_path = public, private as $$
  update public.payout_batches set provider_batch_ids = provider_batch_ids || (d->>'provider_batch_id')
  where id = p_batch and nullif(d->>'provider_batch_id', '') is not null and not ((d->>'provider_batch_id') = any(provider_batch_ids));
$$;

create or replace function public.get_payout_batch(p_batch uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, null);
  if not private.can_handle_money(pb.org_id) then raise exception 'Your role does not see payments.' using errcode = '42501'; end if;
  return private.batch_json(pb.id) || jsonb_build_object('can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'),
    'approve', private.perm_of(m, 'make_payments') and (pb.requested_by is distinct from m.id or m.role = 'owner')));
end $$;

-- Work for the edge function's regular sweep, now including bulk payments that are being sent.
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

-- The payments page: single payouts as before (rows of a bulk payment live under it), and the bulk payments.
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
      from (select * from payouts where org_id = p_org and batch_id is null order by created_at desc limit 300) p) end,
    'batches', case when v_money then (select coalesce(jsonb_agg(private.batch_json(b.id, false) order by b.created_at desc), '[]'::jsonb)
      from (select id, created_at from payout_batches where org_id = p_org order by created_at desc limit 100) b) end,
    'reconciliations', case when v_money then (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
      from (select * from wallet_reconciliations where org_id = p_org order by at desc limit 30) x) end,
    'can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'), 'open_wallet', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'settings', m.role = 'owner'),
    'me', m.id);
end $$;

grant execute on function public.check_payout_batch(uuid, jsonb), public.create_payout_batch(uuid, jsonb), public.approve_payout_batch(uuid, boolean, text),
  public.cancel_payout_batch(uuid), public.payout_batch_to_send(uuid), public.get_payout_batch(uuid), public.set_item_shop_details(uuid, jsonb),
  public.save_customer(uuid, jsonb), public.save_vendor_details(uuid, uuid, jsonb), public.save_bill(uuid, jsonb), public.update_org_settings(uuid, jsonb),
  public.approve_payout(uuid, boolean, text), public.get_payments(uuid) to authenticated;
revoke execute on function public.check_payout_batch(uuid, jsonb), public.create_payout_batch(uuid, jsonb), public.approve_payout_batch(uuid, boolean, text),
  public.cancel_payout_batch(uuid), public.payout_batch_to_send(uuid), public.get_payout_batch(uuid), public.set_item_shop_details(uuid, jsonb),
  public.save_customer(uuid, jsonb), public.save_vendor_details(uuid, uuid, jsonb), public.save_bill(uuid, jsonb), public.update_org_settings(uuid, jsonb),
  public.approve_payout(uuid, boolean, text), public.get_payments(uuid) from public, anon;
revoke execute on function public.svc_batch_claim(uuid, int), public.svc_batch_update(uuid, jsonb), public.svc_work(text), public.svc_payout_update(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_batch_claim(uuid, int), public.svc_batch_update(uuid, jsonb), public.svc_work(text), public.svc_payout_update(text, jsonb) to service_role;
revoke execute on function private.clean_tax_id(text), private.tax_id_input(text, text, text), private.transfer_fee(numeric), private.refresh_payout_batch(uuid),
  private.on_payouts_batch(), private.bulk_account_ok(uuid, text), private.bulk_row(uuid, jsonb, text), private.bulk_check(uuid, jsonb, public.members),
  private.batch_json(uuid, boolean), private.create_payout(uuid, jsonb, jsonb, public.members) from public, anon, authenticated;
