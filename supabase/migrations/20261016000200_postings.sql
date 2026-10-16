-- Counta — posting engine and read models
-- Every write that touches stock, cost or price goes through these functions.

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
create or replace function private.next_no(p_org uuid, p_kind text, p_start int) returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into public.org_counters (org_id, kind, next_val) values (p_org, p_kind, p_start + 1)
  on conflict (org_id, kind) do update set next_val = public.org_counters.next_val + 1
  returning next_val - 1 into v;
  return v;
end $$;

create or replace function private.require(p_org uuid, p_perm text) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.me(p_org);
  if m.id is null then
    raise exception 'You are not a member of this business.' using errcode = '42501';
  end if;
  if p_perm is not null and not private.perm_of(m, p_perm) then
    raise exception 'Your role does not allow this (%).', replace(p_perm, '_', ' ') using errcode = '42501';
  end if;
  return m;
end $$;

create or replace function private.local_day(p_org uuid, p_at timestamptz) returns date
language sql stable security definer set search_path = public as $$
  select (p_at at time zone coalesce((select timezone from public.orgs where id = p_org), 'Africa/Lagos'))::date
$$;

create or replace function private.post_journal(
  p_org uuid, p_memo text, p_source_type text, p_source_id uuid,
  p_author uuid, p_approver uuid, p_lines jsonb, p_at timestamptz default now()
) returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; v_dr numeric := 0; v_cr numeric := 0; x jsonb;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    v_dr := v_dr + round(coalesce((x->>'debit')::numeric, 0), 2);
    v_cr := v_cr + round(coalesce((x->>'credit')::numeric, 0), 2);
  end loop;
  if v_dr <> v_cr then
    raise exception 'Journal does not balance (Dr % / Cr %).', v_dr, v_cr;
  end if;
  insert into public.journals (org_id, je_no, entry_date, memo, source_type, source_id, posted_by, approved_by, created_at)
  values (p_org, private.next_no(p_org, 'JE', 1001), private.local_day(p_org, p_at), p_memo, p_source_type, p_source_id, p_author, p_approver, p_at)
  returning * into j;
  insert into public.journal_lines (journal_id, org_id, account_code, debit, credit, location_id, item_id, memo)
  select j.id, p_org, e->>'code',
         round(coalesce((e->>'debit')::numeric, 0), 2), round(coalesce((e->>'credit')::numeric, 0), 2),
         nullif(e->>'location_id', '')::uuid, nullif(e->>'item_id', '')::uuid, e->>'memo'
  from jsonb_array_elements(p_lines) e
  where round(coalesce((e->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((e->>'credit')::numeric, 0), 2) <> 0;
  return j;
end $$;

create or replace function private.add_movement(
  p_org uuid, p_type text, p_item uuid, p_location uuid, p_qty numeric, p_unit_cost numeric,
  p_unit_price numeric, p_journal uuid, p_author uuid, p_channel text,
  p_at timestamptz default now(), p_extra jsonb default '{}'::jsonb
) returns public.movements
language plpgsql security definer set search_path = public as $$
declare mv public.movements;
begin
  insert into public.movements (
    org_id, type, item_id, location_id, qty, unit_cost, unit_price, journal_id, author_id, channel,
    recorded_at, synced_at, receipt_id, transfer_id, count_session_id, batch_id, reason, note,
    approver_id, device_id, offline, client_uuid, review_status)
  values (
    p_org, p_type, p_item, p_location, p_qty, coalesce(p_unit_cost, 0), p_unit_price, p_journal, p_author, coalesce(p_channel, 'App'),
    p_at, case when coalesce((p_extra->>'offline')::boolean, false) then now() else p_at end,
    nullif(p_extra->>'receipt_id', '')::uuid, nullif(p_extra->>'transfer_id', '')::uuid,
    nullif(p_extra->>'count_session_id', '')::uuid, nullif(p_extra->>'batch_id', '')::uuid,
    p_extra->>'reason', p_extra->>'note', nullif(p_extra->>'approver_id', '')::uuid,
    p_extra->>'device_id', coalesce((p_extra->>'offline')::boolean, false),
    nullif(p_extra->>'client_uuid', '')::uuid, p_extra->>'review_status')
  returning * into mv;
  return mv;
end $$;

-- First-expiry-first-out consumption. Returns the allocations made.
create or replace function private.consume_batches(p_item uuid, p_location uuid, p_qty numeric, p_day date default current_date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare b record; v_left numeric := p_qty; v_take numeric; v_alloc jsonb := '[]'::jsonb;
begin
  if p_qty <= 0 then return v_alloc; end if;
  for b in
    select id, batch_no, expiry_date, qty_remaining from public.batches
    where item_id = p_item and location_id = p_location and not quarantined and qty_remaining > 0
      and (expiry_date is null or expiry_date >= p_day)
    order by expiry_date nulls last, created_at
    for update
  loop
    exit when v_left <= 0;
    v_take := least(b.qty_remaining, v_left);
    update public.batches set qty_remaining = qty_remaining - v_take where id = b.id;
    v_alloc := v_alloc || jsonb_build_object('batch_id', b.id, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date, 'qty', v_take);
    v_left := v_left - v_take;
  end loop;
  return v_alloc;
end $$;

create or replace function private.fmt_qty(n numeric) returns text
language sql immutable as $$
  select case when n = trunc(n) then to_char(n, 'FM999,999,999,990')
    else rtrim(rtrim(to_char(n, 'FM999,999,999,990.999'), '0'), '.') end
$$;

create or replace function private.round_price(p numeric) returns numeric
language sql immutable as $$ select greatest(10, round(p / 10.0) * 10) $$;

-- Suggest a price that keeps the item's usual margin (never below threshold + 1.5 pts).
create or replace function private.suggest_price(p_old_price numeric, p_old_cost numeric, p_new_cost numeric, p_threshold numeric)
returns jsonb
language plpgsql immutable as $$
declare v_usual numeric; v_target numeric; v_price numeric;
begin
  v_usual := case when p_old_price > 0 and p_old_cost is not null then (p_old_price - p_old_cost) / p_old_price * 100 else 0 end;
  v_target := greatest(v_usual, coalesce(p_threshold, 8) + 1.5);
  if v_target >= 95 then v_target := 95; end if;
  v_price := private.round_price(p_new_cost / (1 - v_target / 100));
  if v_price <= p_new_cost then v_price := private.round_price(p_new_cost * 1.1 + 10); end if;
  return jsonb_build_object('price', v_price, 'target', round((v_price - p_new_cost) / v_price * 100, 2));
end $$;

create or replace function private.propose_price(p_item uuid, p_kind text, p_old_cost numeric, p_new_cost numeric, p_source text)
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare it public.items; o public.orgs; s jsonb; v_id uuid;
begin
  select * into it from public.items where id = p_item;
  select * into o from public.orgs where id = it.org_id;
  s := private.suggest_price(it.price, p_old_cost, p_new_cost, o.margin_threshold);
  if (s->>'price')::numeric <= it.price and p_kind = 'cost_increase' then
    -- current price already protects the margin; nothing to propose
    return null;
  end if;
  select id into v_id from public.price_proposals where item_id = p_item and status = 'open';
  if v_id is not null then
    update public.price_proposals set kind = p_kind, old_cost = p_old_cost, new_cost = p_new_cost, old_price = it.price,
      suggested_price = (s->>'price')::numeric, target_margin = (s->>'target')::numeric, source_ref = p_source, created_at = now()
    where id = v_id;
  else
    insert into public.price_proposals (org_id, item_id, kind, old_cost, new_cost, old_price, suggested_price, target_margin, source_ref)
    values (it.org_id, p_item, p_kind, p_old_cost, p_new_cost, it.price, (s->>'price')::numeric, (s->>'target')::numeric, p_source)
    returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function private.role_template(p_role text) returns jsonb
language sql immutable as $$
  select case p_role
    when 'owner' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":true,"edit_prices":true,"approve_pos":true,"transfer_stock":true,"see_margins":true}'
    when 'manager' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":true,"see_margins":true}'
    when 'staff' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false}'
    else '{"record_sales":true,"receive_stock":false,"count_stock":false,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false}'
  end::jsonb
$$;

create or replace function private.channel_for(p_source text) returns text
language sql immutable as $$
  select case p_source when 'pdf' then 'PDF invoice' when 'photo_typed' then 'Photo · OCR'
    when 'photo_handwritten' then 'Photo + OCR' else 'Manual entry' end
$$;

-- ---------------------------------------------------------------------------
-- Businesses and people
-- ---------------------------------------------------------------------------
create or replace function public.create_org(
  p_name text, p_email text default null, p_phone text default null, p_display_name text default null,
  p_locations jsonb default '[]'::jsonb, p_vat_registered boolean default true, p_is_sample boolean default false
) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_uid uuid := auth.uid(); l jsonb; v_i int := 0; v_email text; v_code text; v_base text; v_n int; p jsonb;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Business name is required.'; end if;
  select email into v_email from auth.users where id = v_uid;
  insert into orgs (name, email, phone, vat_registered, created_by, is_sample)
  values (trim(p_name), coalesce(nullif(trim(p_email), ''), v_email), nullif(trim(p_phone), ''), coalesce(p_vat_registered, true), v_uid, coalesce(p_is_sample, false))
  returning id into v_org;

  for l in select * from jsonb_array_elements(coalesce(p_locations, '[]'::jsonb)) loop
    continue when coalesce(trim(l->>'name'), '') = '';
    v_i := v_i + 1;
    v_base := coalesce(nullif(upper(trim(l->>'code')), ''), upper(left(regexp_replace(l->>'name', '[^A-Za-z]', '', 'g'), 3)));
    if v_base = '' then v_base := 'LOC'; end if;
    v_code := v_base; v_n := 1;
    while exists (select 1 from locations where org_id = v_org and code = v_code) loop
      v_n := v_n + 1; v_code := v_base || v_n;
    end loop;
    insert into locations (org_id, name, code, address, is_main)
    values (v_org, trim(l->>'name'), v_code, nullif(trim(l->>'address'), ''), v_i = 1);
  end loop;
  if v_i = 0 then
    insert into locations (org_id, name, code, is_main) values (v_org, 'Main store', 'MAIN', true);
  end if;

  p := private.role_template('owner');
  insert into members (org_id, user_id, email, display_name, role, title, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, v_uid, v_email, coalesce(nullif(trim(p_display_name), ''), split_part(v_email, '@', 1)), 'owner', 'Owner', 'active',
    true, true, true, true, true, true, true, true);
  return v_org;
end $$;

create or replace function public.claim_invites() returns int
language plpgsql security definer set search_path = public as $$
declare v_email text; n int;
begin
  if auth.uid() is null then return 0; end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is null then return 0; end if;
  update members m set user_id = auth.uid(), status = 'active'
  where m.user_id is null and m.status = 'invited' and lower(m.email) = v_email
    and not exists (select 1 from members m2 where m2.org_id = m.org_id and m2.user_id = auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.invite_member(
  p_org uuid, p_name text, p_email text, p_role text, p_title text default null,
  p_location uuid default null, p_phone text default null
) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; p jsonb; v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email, ''))), ''); v_uid uuid;
begin
  m := private.require(p_org, 'owner');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the person''s name.'; end if;
  if p_role not in ('manager', 'staff', 'cashier') then raise exception 'Choose a role.'; end if;
  if v_email is not null and exists (select 1 from members where org_id = p_org and lower(email) = v_email) then
    raise exception '% is already on your team.', v_email;
  end if;
  if p_location is not null and not exists (select 1 from locations where id = p_location and org_id = p_org) then
    raise exception 'Unknown branch.';
  end if;
  if v_email is not null then
    select id into v_uid from auth.users where lower(email) = v_email;
  end if;
  p := private.role_template(p_role);
  insert into members (org_id, user_id, email, display_name, phone, role, title, location_id, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (p_org, v_uid, v_email, trim(p_name), nullif(trim(p_phone), ''), p_role,
    coalesce(nullif(trim(p_title), ''), initcap(p_role)), p_location,
    case when v_uid is not null or v_email is null then 'active' else 'invited' end,
    (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean,
    (p->>'approve_adjustments')::boolean, (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean,
    (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_member(p_member uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; p jsonb; v_role text;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'owner');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status') then
    raise exception 'The owner keeps every permission.';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'manager', 'staff', 'cashier') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  p := case when p_patch ? 'role' and p_patch->>'role' <> t.role and not (p_patch ? 'perms')
            then private.role_template(v_role) else coalesce(p_patch->'perms', '{}'::jsonb) end;
  update members set
    role = v_role,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status),
    p_record_sales = coalesce((p->>'record_sales')::boolean, p_record_sales),
    p_receive_stock = coalesce((p->>'receive_stock')::boolean, p_receive_stock),
    p_count_stock = coalesce((p->>'count_stock')::boolean, p_count_stock),
    p_approve_adjustments = coalesce((p->>'approve_adjustments')::boolean, p_approve_adjustments),
    p_edit_prices = coalesce((p->>'edit_prices')::boolean, p_edit_prices),
    p_approve_pos = coalesce((p->>'approve_pos')::boolean, p_approve_pos),
    p_transfer_stock = coalesce((p->>'transfer_stock')::boolean, p_transfer_stock),
    p_see_margins = coalesce((p->>'see_margins')::boolean, p_see_margins)
  where id = p_member;
exception when check_violation then
  raise exception 'Someone who records sales cannot also edit prices or approve adjustments.';
end $$;

-- ---------------------------------------------------------------------------
-- Item master
-- ---------------------------------------------------------------------------
create or replace function public.upsert_item(p_org uuid, p_item jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_id uuid := nullif(p_item->>'id', '')::uuid; v_old public.items;
  v_name text := trim(coalesce(p_item->>'name', '')); v_pack numeric; v_price numeric; v_cost numeric; v_qty numeric;
  v_barcode text := nullif(trim(coalesce(p_item->>'barcode', '')), ''); v_su text;
begin
  m := private.require(p_org, 'edit_prices');
  if v_name = '' then raise exception 'Product name is required.'; end if;
  begin
    v_pack := nullif(p_item->>'pack_size', '')::numeric;
    v_price := nullif(p_item->>'price', '')::numeric;
    v_cost := nullif(p_item->>'cost', '')::numeric;
  exception when others then raise exception 'Pack size, cost and price must be numbers.';
  end;
  if v_pack is null or v_pack < 1 or v_pack <> floor(v_pack) then raise exception 'Pack size must be a whole number, at least 1.'; end if;
  if v_price is null or v_price <= 0 then raise exception 'Enter a selling price.'; end if;
  if v_cost is not null and v_cost < 0 then raise exception 'Cost cannot be negative.'; end if;
  if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode and id is distinct from v_id) then
    raise exception 'Another item already uses barcode %.', v_barcode;
  end if;
  v_su := coalesce(nullif(trim(p_item->>'selling_unit'), ''), 'piece');

  if v_id is null then
    if v_cost is null then raise exception 'Enter a cost per selling unit.'; end if;
    insert into items (org_id, name, barcode, sku, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit,
      informal_unit, track_batches, reorder_floor, preferred_vendor_id, alt_vendor_id, price, import_priced, photo_path, created_by)
    values (p_org, v_name, v_barcode, nullif(trim(p_item->>'sku'), ''), coalesce(nullif(trim(p_item->>'category'), ''), 'General'),
      coalesce(nullif(p_item->>'vat_treatment', ''), 'standard'), nullif(trim(p_item->>'nafdac_no'), ''),
      coalesce(nullif(trim(p_item->>'purchase_unit'), ''), 'Carton'), v_pack::int, v_su,
      coalesce((p_item->>'informal_unit')::boolean, v_su in ('derica', 'mudu', 'paint bucket')),
      coalesce((p_item->>'track_batches')::boolean, false), coalesce(nullif(p_item->>'reorder_floor', '')::numeric, 0),
      nullif(p_item->>'preferred_vendor_id', '')::uuid, nullif(p_item->>'alt_vendor_id', '')::uuid,
      v_price, coalesce((p_item->>'import_priced')::boolean, false), nullif(p_item->>'photo_path', ''), m.id)
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, p_org, v_cost, v_cost);
  else
    select * into v_old from items where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Item not found.'; end if;
    update items set
      name = v_name, barcode = v_barcode,
      sku = case when p_item ? 'sku' then nullif(trim(p_item->>'sku'), '') else sku end,
      category = coalesce(nullif(trim(p_item->>'category'), ''), category),
      vat_treatment = coalesce(nullif(p_item->>'vat_treatment', ''), vat_treatment),
      nafdac_no = case when p_item ? 'nafdac_no' then nullif(trim(p_item->>'nafdac_no'), '') else nafdac_no end,
      purchase_unit = coalesce(nullif(trim(p_item->>'purchase_unit'), ''), purchase_unit),
      pack_size = v_pack::int, selling_unit = v_su,
      informal_unit = coalesce((p_item->>'informal_unit')::boolean, v_su in ('derica', 'mudu', 'paint bucket')),
      track_batches = coalesce((p_item->>'track_batches')::boolean, track_batches),
      reorder_floor = coalesce(nullif(p_item->>'reorder_floor', '')::numeric, reorder_floor),
      preferred_vendor_id = case when p_item ? 'preferred_vendor_id' then nullif(p_item->>'preferred_vendor_id', '')::uuid else preferred_vendor_id end,
      alt_vendor_id = case when p_item ? 'alt_vendor_id' then nullif(p_item->>'alt_vendor_id', '')::uuid else alt_vendor_id end,
      price = v_price,
      import_priced = coalesce((p_item->>'import_priced')::boolean, import_priced),
      photo_path = case when p_item ? 'photo_path' then nullif(p_item->>'photo_path', '') else photo_path end,
      needs_review = case when p_item ? 'needs_review' then (p_item->>'needs_review')::boolean else false end
    where id = v_id;
    if v_old.price <> v_price then
      insert into price_changes (org_id, item_id, old_price, new_price, reason, changed_by)
      values (p_org, v_id, v_old.price, v_price, coalesce(nullif(p_item->>'price_reason', ''), 'Manual edit'), m.id);
    end if;
    if v_cost is not null then
      select coalesce(sum(qty), 0) into v_qty from stock_levels where item_id = v_id;
      if v_qty = 0 then
        update item_costs set wac = v_cost, last_cost = coalesce(last_cost, v_cost), updated_at = now() where item_id = v_id;
      end if;
    end if;
  end if;
  return v_id;
end $$;

create or replace function public.set_item_photo(p_item uuid, p_path text) returns void
language plpgsql security definer set search_path = public, private as $$
declare it public.items;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  if not (private.has_perm(it.org_id, 'receive_stock') or private.has_perm(it.org_id, 'edit_prices') or private.has_perm(it.org_id, 'count_stock')) then
    raise exception 'Your role does not allow this.';
  end if;
  update items set photo_path = nullif(p_path, '') where id = p_item;
end $$;

-- Spreadsheet import → items + opening balances (Dr 1310 / Cr 3100)
create or replace function public.import_items(p_org uuid, p_location uuid, p_rows jsonb, p_file_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r jsonb; v_idx int := 0; v_id uuid; v_created int := 0; v_skipped jsonb := '[]'::jsonb;
  v_total numeric := 0; v_lines jsonb := '[]'::jsonb; v_name text; v_price numeric; v_cost numeric; v_qty numeric; v_pack numeric;
  j public.journals; v_ops jsonb := '[]'::jsonb; op jsonb; v_su text; v_barcode text;
begin
  m := private.require(p_org, 'edit_prices');
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Choose a branch for the opening stock.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_idx := v_idx + 1;
    v_name := trim(coalesce(r->>'name', ''));
    begin
      v_price := nullif(regexp_replace(coalesce(r->>'price', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_cost := nullif(regexp_replace(coalesce(r->>'cost', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_qty := nullif(regexp_replace(coalesce(r->>'qty', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_pack := nullif(regexp_replace(coalesce(r->>'pack_size', ''), '[^0-9.]', '', 'g'), '')::numeric;
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'Numbers could not be read');
      continue;
    end;
    if v_name = '' then v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', '', 'reason', 'No product name'); continue; end if;
    if v_price is null or v_price <= 0 then v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'No selling price'); continue; end if;
    if v_pack is null or v_pack < 1 then v_pack := 1; end if;
    v_pack := floor(v_pack);
    v_barcode := nullif(regexp_replace(coalesce(r->>'barcode', ''), '\s', '', 'g'), '');
    if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode) then v_barcode := null; end if;
    if exists (select 1 from items where org_id = p_org and lower(name) = lower(v_name) and not archived) then
      v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'Already in your items'); continue;
    end if;
    v_su := coalesce(nullif(trim(r->>'selling_unit'), ''), 'piece');
    insert into items (org_id, name, sku, barcode, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit,
      price, notes, needs_review, created_by, track_batches, reorder_floor)
    values (p_org, v_name, nullif(trim(r->>'sku'), ''), v_barcode, coalesce(nullif(trim(r->>'category'), ''), 'General'),
      case when r->>'vat_treatment' in ('standard', 'zero', 'exempt') then r->>'vat_treatment' else 'standard' end,
      coalesce(nullif(trim(r->>'purchase_unit'), ''), case when v_pack > 1 then 'Carton' else 'Pack' end), v_pack::int, v_su,
      v_su in ('derica', 'mudu', 'paint bucket'), v_price, coalesce(r->'notes', '{}'::jsonb),
      coalesce(r->'notes', '{}'::jsonb) <> '{}'::jsonb, m.id, coalesce((r->>'track_batches')::boolean, false),
      coalesce(nullif(regexp_replace(coalesce(r->>'reorder_floor', ''), '[^0-9.]', '', 'g'), '')::numeric, 0))
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, p_org, greatest(coalesce(v_cost, 0), 0), v_cost);
    v_created := v_created + 1;
    if coalesce(v_qty, 0) > 0 then
      v_total := v_total + round(v_qty * greatest(coalesce(v_cost, 0), 0), 2);
      v_ops := v_ops || jsonb_build_object('item_id', v_id, 'qty', v_qty, 'cost', greatest(coalesce(v_cost, 0), 0));
    end if;
  end loop;

  if jsonb_array_length(v_ops) > 0 then
    j := private.post_journal(p_org, 'Opening stock · ' || coalesce(p_file_name, 'import'), 'opening', null, m.id, null,
      jsonb_build_array(
        jsonb_build_object('code', '1310', 'debit', v_total, 'location_id', p_location),
        jsonb_build_object('code', '3100', 'credit', v_total, 'location_id', p_location)));
    for op in select * from jsonb_array_elements(v_ops) loop
      perform private.add_movement(p_org, 'opening', (op->>'item_id')::uuid, p_location, (op->>'qty')::numeric,
        (op->>'cost')::numeric, null, j.id, m.id, 'Import', now(), jsonb_build_object('note', coalesce(p_file_name, 'Spreadsheet import')));
    end loop;
  end if;
  return jsonb_build_object('created', v_created, 'skipped', v_skipped, 'journal_ref', j.ref, 'opening_value', v_total);
end $$;

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------
create or replace function private.post_receipt_internal(p_receipt uuid, p_member uuid, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; l public.receipt_lines; it public.items; v public.vendors; o public.orgs;
  v_bad int; v_net numeric := 0; v_vat_base numeric := 0; v_vat numeric := 0; v_gross numeric; v_line numeric;
  v_vat_t text; v_pack int; v_su_qty numeric; v_cost_su numeric; v_old_last numeric; v_on_hand numeric; v_wac numeric;
  j public.journals; v_item uuid; v_batch uuid; v_new jsonb; v_price numeric; v_props int := 0; v_can_price boolean; v_pid uuid;
  v_memo text;
begin
  select * into r from receipts where id = p_receipt for update;
  if not found then raise exception 'Receipt not found.'; end if;
  select * into m from members where id = p_member;
  select * into o from orgs where id = r.org_id;
  if r.status <> 'needs_review' then raise exception 'This receipt is already %.', replace(r.status, '_', ' '); end if;
  if r.location_id is null then raise exception 'Choose the branch receiving this stock.'; end if;
  if r.vendor_id is null and coalesce(trim(r.vendor_name), '') = '' then raise exception 'Choose or name the vendor.'; end if;
  if not exists (select 1 from receipt_lines where receipt_id = r.id) then raise exception 'Add at least one line.'; end if;
  select count(*) into v_bad from receipt_lines
  where receipt_id = r.id and (not confirmed or qty <= 0 or unit_cost <= 0
    or (item_id is null and coalesce(trim(new_item->>'name'), '') = ''));
  if v_bad > 0 then
    raise exception '% line% still need% confirmation before posting.', v_bad,
      case when v_bad > 1 then 's' else '' end, case when v_bad > 1 then '' else 's' end;
  end if;

  if r.vendor_id is null then
    select id into r.vendor_id from vendors where org_id = r.org_id and lower(name) = lower(trim(r.vendor_name)) limit 1;
    if r.vendor_id is null then
      insert into vendors (org_id, name, vat_registered, channel)
      values (r.org_id, trim(r.vendor_name), r.vendor_vat_registered, 'whatsapp') returning id into r.vendor_id;
    end if;
    update receipts set vendor_id = r.vendor_id where id = r.id;
  end if;
  select * into v from vendors where id = r.vendor_id;
  v_can_price := private.perm_of(m, 'edit_prices');

  -- Totals first: the journal must exist before any movement references it.
  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_line := round(l.qty * l.unit_cost, 2);
    if l.item_id is not null then select vat_treatment into v_vat_t from items where id = l.item_id;
    else v_vat_t := coalesce(nullif(l.new_item->>'vat_treatment', ''), 'standard'); end if;
    v_net := v_net + v_line;
    if v_vat_t = 'standard' then v_vat_base := v_vat_base + v_line; end if;
  end loop;
  v_vat := case when r.vendor_vat_registered then round(v_vat_base * 0.075, 2) else 0 end;
  v_gross := v_net + v_vat;
  v_memo := v.name || coalesce(' · ' || nullif(r.invoice_no, ''), '');

  j := private.post_journal(r.org_id, v_memo, 'receipt', r.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', '1310', 'debit', v_net, 'location_id', r.location_id, 'memo', 'Stock received'),
      jsonb_build_object('code', '1420', 'debit', v_vat, 'memo', 'Input VAT 7.5%'),
      jsonb_build_object('code', '2010', 'credit', v_gross, 'memo', 'Payable to ' || v.name)), p_at);

  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_item := l.item_id;
    if v_item is null then
      v_new := l.new_item;
      v_pack := greatest(1, coalesce(nullif(v_new->>'pack_size', '')::numeric, 1)::int);
      v_cost_su := l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end;
      v_price := nullif(v_new->>'price', '')::numeric;
      if not v_can_price or v_price is null or v_price <= 0 then
        v_price := private.round_price(v_cost_su * 1.15);
      end if;
      insert into items (org_id, name, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit, track_batches,
        preferred_vendor_id, price, needs_review, created_by, barcode)
      values (r.org_id, trim(v_new->>'name'), coalesce(nullif(trim(v_new->>'category'), ''), 'General'),
        coalesce(nullif(v_new->>'vat_treatment', ''), 'standard'), coalesce(nullif(trim(v_new->>'purchase_unit'), ''), 'Carton'), v_pack,
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece'),
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece') in ('derica', 'mudu', 'paint bucket'),
        coalesce((v_new->>'track_batches')::boolean, false), r.vendor_id, v_price,
        not (v_can_price and nullif(v_new->>'price', '')::numeric > 0), m.id,
        case when nullif(trim(v_new->>'barcode'), '') is not null
              and not exists (select 1 from items where org_id = r.org_id and barcode = trim(v_new->>'barcode'))
             then trim(v_new->>'barcode') end)
      returning id into v_item;
      insert into item_costs (item_id, org_id, wac) values (v_item, r.org_id, 0);
      update receipt_lines set item_id = v_item where id = l.id;
    end if;

    select * into it from items where id = v_item;
    v_pack := it.pack_size;
    v_su_qty := l.qty * case when l.unit_kind = 'purchase' then v_pack else 1 end;
    v_cost_su := round(l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end, 4);

    -- Weighted average cost, recalculated on every receipt.
    select coalesce(sum(qty), 0) into v_on_hand from stock_levels where item_id = v_item;
    select wac, last_cost into v_wac, v_old_last from item_costs where item_id = v_item for update;
    if v_on_hand <= 0 or coalesce(v_wac, 0) = 0 then v_wac := v_cost_su;
    else v_wac := round((v_on_hand * v_wac + v_su_qty * v_cost_su) / (v_on_hand + v_su_qty), 4); end if;
    update item_costs set wac = v_wac, last_cost = v_cost_su, replacement_cost = v_cost_su,
      replacement_source = j.ref || ' · ' || v.name, updated_at = now()
    where item_id = v_item;

    v_batch := null;
    if it.track_batches then
      insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, receipt_id, created_at)
      values (r.org_id, v_item, r.location_id, coalesce(nullif(trim(l.batch_no), ''), 'R' || j.je_no || '-' || l.line_no),
        l.expiry_date, v_su_qty, v_su_qty, r.id, p_at)
      returning id into v_batch;
    end if;

    perform private.add_movement(r.org_id, 'receipt', v_item, r.location_id, v_su_qty, v_cost_su, null, j.id, m.id,
      private.channel_for(r.source), p_at,
      jsonb_build_object('receipt_id', r.id, 'batch_id', v_batch, 'device_id', r.device_id, 'offline', r.offline,
        'note', coalesce(l.raw_text, '')));

    if it.preferred_vendor_id is null then update items set preferred_vendor_id = r.vendor_id where id = v_item; end if;

    if v_old_last is not null and v_cost_su > v_old_last + 0.004 then
      v_pid := private.propose_price(v_item, 'cost_increase', v_old_last, v_cost_su,
        j.ref || ' · ' || v.name || ' · ' || to_char(private.local_day(r.org_id, p_at), 'DD Mon'));
      if v_pid is not null then v_props := v_props + 1; end if;
    end if;
  end loop;

  update receipts set status = 'posted', net = v_net, input_vat = v_vat, gross = v_gross, journal_id = j.id, ref = j.ref,
    posted_by = m.id, posted_at = p_at, vendor_id = r.vendor_id
  where id = r.id;
  if r.po_id is not null then
    update purchase_orders set status = 'received', received_at = p_at where id = r.po_id and status = 'sent';
  end if;
  return jsonb_build_object('journal_ref', j.ref, 'net', v_net, 'vat', v_vat, 'gross', v_gross, 'proposals', v_props);
end $$;

create or replace function public.post_receipt(p_receipt uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from receipts where id = p_receipt;
  if v_org is null then raise exception 'Receipt not found.'; end if;
  m := private.require(v_org, 'receive_stock');
  return private.post_receipt_internal(p_receipt, m.id, now());
end $$;

-- ---------------------------------------------------------------------------
-- Sales (phone, voice, day close)
-- ---------------------------------------------------------------------------
create or replace function private.sale_internal(
  p_org uuid, p_item uuid, p_location uuid, p_qty numeric, p_unit_price numeric, p_author uuid, p_channel text,
  p_type text, p_at timestamptz, p_extra jsonb, p_journal uuid default null
) returns public.movements
language plpgsql security definer set search_path = public, private as $$
declare it public.items; v_wac numeric; v_alloc jsonb; j public.journals; v_journal uuid := p_journal; v_price numeric; mv public.movements;
begin
  select * into it from items where id = p_item and org_id = p_org;
  if not found then raise exception 'Item not found.'; end if;
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  select wac into v_wac from item_costs where item_id = p_item;
  v_price := coalesce(p_unit_price, it.price);
  v_alloc := private.consume_batches(p_item, p_location, p_qty, private.local_day(p_org, p_at));
  if v_journal is null then
    j := private.post_journal(p_org, 'Sale · ' || it.name, 'sale', null, p_author, null,
      jsonb_build_array(
        jsonb_build_object('code', '5100', 'debit', round(p_qty * coalesce(v_wac, 0), 2), 'location_id', p_location, 'item_id', p_item),
        jsonb_build_object('code', '1310', 'credit', round(p_qty * coalesce(v_wac, 0), 2), 'location_id', p_location, 'item_id', p_item)), p_at);
    v_journal := j.id;
  end if;
  mv := private.add_movement(p_org, p_type, p_item, p_location, -p_qty, coalesce(v_wac, 0), v_price, v_journal, p_author, p_channel, p_at,
    coalesce(p_extra, '{}'::jsonb) || jsonb_build_object('batch_id', (v_alloc->0->>'batch_id')));
  return mv;
end $$;

create or replace function public.record_sale(
  p_org uuid, p_item uuid, p_location uuid, p_qty numeric, p_unit_price numeric default null,
  p_channel text default 'Phone app', p_voice boolean default false, p_note text default null,
  p_voice_clean boolean default true, p_client_uuid uuid default null, p_device text default null,
  p_offline boolean default false, p_recorded_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; mv public.movements; v_review text; v_at timestamptz := coalesce(p_recorded_at, now());
begin
  m := private.require(p_org, 'record_sales');
  if p_client_uuid is not null then
    select * into mv from movements where client_uuid = p_client_uuid;
    if found then return jsonb_build_object('duplicate', true, 'movement_id', mv.id); end if;
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a quantity above zero.'; end if;
  if v_at > now() + interval '5 minutes' then v_at := now(); end if;
  select * into o from orgs where id = p_org;
  if p_voice then
    v_review := case when m.voice_confirmed >= o.voice_trust_threshold then 'reviewed' else 'pending' end;
    if p_voice_clean then update members set voice_confirmed = voice_confirmed + 1 where id = m.id; end if;
  end if;
  mv := private.sale_internal(p_org, p_item, p_location, p_qty, p_unit_price, m.id, p_channel,
    case when p_voice then 'voice_sale' else 'sale' end, v_at,
    jsonb_build_object('note', p_note, 'client_uuid', p_client_uuid, 'device_id', p_device, 'offline', p_offline, 'review_status', v_review));
  return jsonb_build_object('movement_id', mv.id, 'journal_ref', (select ref from journals where id = mv.journal_id),
    'review_status', v_review, 'voice_confirmed', m.voice_confirmed + case when p_voice and p_voice_clean then 1 else 0 end,
    'voice_threshold', o.voice_trust_threshold);
end $$;

-- One journal for a whole day's takings at a branch (used by the invoicing rail and imports).
create or replace function private.post_day_close(p_org uuid, p_location uuid, p_author uuid, p_lines jsonb, p_at timestamptz, p_channel text default 'Invoicing rail')
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; v_cogs numeric := 0; j public.journals; v_wac numeric; v_loc text;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    select wac into v_wac from item_costs where item_id = (x->>'item_id')::uuid;
    v_cogs := v_cogs + round((x->>'qty')::numeric * coalesce(v_wac, 0), 2);
  end loop;
  if v_cogs = 0 and jsonb_array_length(p_lines) = 0 then return null; end if;
  select name into v_loc from locations where id = p_location;
  j := private.post_journal(p_org, 'Day close · ' || v_loc, 'sale', null, p_author, null,
    jsonb_build_array(
      jsonb_build_object('code', '5100', 'debit', v_cogs, 'location_id', p_location),
      jsonb_build_object('code', '1310', 'credit', v_cogs, 'location_id', p_location)), p_at);
  for x in select * from jsonb_array_elements(p_lines) loop
    perform private.sale_internal(p_org, (x->>'item_id')::uuid, p_location, (x->>'qty')::numeric, nullif(x->>'price', '')::numeric,
      p_author, p_channel, 'sale', p_at, '{}'::jsonb, j.id);
  end loop;
  return j.id;
end $$;

create or replace function public.mark_voice_reviewed(p_movement uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid;
begin
  select org_id into v_org from movements where id = p_movement;
  if v_org is null then raise exception 'Entry not found.'; end if;
  perform private.require(v_org, 'approve_adjustments');
  update movements set review_status = 'reviewed' where id = p_movement and review_status = 'pending';
end $$;

-- ---------------------------------------------------------------------------
-- Transfers (Cr 1310 origin / Dr 1315 in transit, then Dr 1310 destination / Cr 1315)
-- ---------------------------------------------------------------------------
create or replace function public.create_transfer(
  p_org uuid, p_item uuid, p_from uuid, p_to uuid, p_qty numeric,
  p_client_uuid uuid default null, p_device text default null, p_offline boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; it public.items; v_avail numeric; v_wac numeric; v_ref text; v_id uuid; j public.journals;
  v_from text; v_to text; v_alloc jsonb; v_val numeric;
begin
  m := private.require(p_org, 'transfer_stock');
  if p_client_uuid is not null and exists (select 1 from transfers where client_uuid = p_client_uuid) then
    return (select jsonb_build_object('duplicate', true, 'ref', ref) from transfers where client_uuid = p_client_uuid);
  end if;
  select * into it from items where id = p_item and org_id = p_org;
  if not found then raise exception 'Choose an item.'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Choose two different locations.'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'Enter a quantity.'; end if;
  select name into v_from from locations where id = p_from and org_id = p_org;
  select name into v_to from locations where id = p_to and org_id = p_org;
  if v_from is null or v_to is null then raise exception 'Unknown branch.'; end if;
  select coalesce(qty, 0) into v_avail from stock_levels where item_id = p_item and location_id = p_from;
  v_avail := coalesce(v_avail, 0);
  if p_qty > v_avail then
    raise exception 'Only % % available at %.', private.fmt_qty(v_avail), it.selling_unit, v_from;
  end if;
  select wac into v_wac from item_costs where item_id = p_item;
  v_val := round(p_qty * coalesce(v_wac, 0), 2);
  v_ref := 'TR-' || lpad(private.next_no(p_org, 'TR', 1)::text, 4, '0');
  v_alloc := private.consume_batches(p_item, p_from, p_qty);
  insert into transfers (org_id, ref, item_id, qty, unit_cost, from_location_id, to_location_id, batch_alloc, created_by, client_uuid)
  values (p_org, v_ref, p_item, p_qty, coalesce(v_wac, 0), p_from, p_to, v_alloc, m.id, p_client_uuid) returning id into v_id;
  j := private.post_journal(p_org, 'Transfer ' || v_ref || ' · ' || v_from || ' → ' || v_to, 'transfer', v_id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', '1315', 'debit', v_val, 'item_id', p_item, 'memo', 'In transit to ' || v_to),
      jsonb_build_object('code', '1310', 'credit', v_val, 'location_id', p_from, 'item_id', p_item)));
  perform private.add_movement(p_org, 'transfer_out', p_item, p_from, -p_qty, coalesce(v_wac, 0), null, j.id, m.id,
    case when p_device is not null then 'Phone app' else 'App' end, now(),
    jsonb_build_object('transfer_id', v_id, 'device_id', p_device, 'offline', p_offline, 'note', v_from || ' → ' || v_to));
  return jsonb_build_object('ref', v_ref, 'id', v_id);
end $$;

create or replace function private.receive_transfer_internal(p_transfer uuid, p_member uuid, p_at timestamptz) returns text
language plpgsql security definer set search_path = public, private as $$
declare t public.transfers; j public.journals; v_val numeric; a jsonb; v_from text; v_to text; v_batch uuid;
begin
  select * into t from transfers where id = p_transfer for update;
  if t.status <> 'in_transit' then raise exception 'This transfer was already received.'; end if;
  select name into v_from from locations where id = t.from_location_id;
  select name into v_to from locations where id = t.to_location_id;
  v_val := round(t.qty * t.unit_cost, 2);
  j := private.post_journal(t.org_id, 'Transfer ' || t.ref || ' received at ' || v_to, 'transfer_receive', t.id, p_member, null,
    jsonb_build_array(
      jsonb_build_object('code', '1310', 'debit', v_val, 'location_id', t.to_location_id, 'item_id', t.item_id),
      jsonb_build_object('code', '1315', 'credit', v_val, 'item_id', t.item_id)), p_at);
  for a in select * from jsonb_array_elements(t.batch_alloc) loop
    insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, created_at)
    values (t.org_id, t.item_id, t.to_location_id, a->>'batch_no', nullif(a->>'expiry_date', '')::date, (a->>'qty')::numeric, (a->>'qty')::numeric, p_at)
    returning id into v_batch;
  end loop;
  perform private.add_movement(t.org_id, 'transfer_in', t.item_id, t.to_location_id, t.qty, t.unit_cost, null, j.id, p_member,
    'App', p_at, jsonb_build_object('transfer_id', t.id, 'note', v_from || ' → ' || v_to || ' · received'));
  update transfers set status = 'received', received_by = p_member, received_at = p_at where id = t.id;
  return j.ref;
end $$;

create or replace function public.receive_transfer(p_transfer uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from transfers where id = p_transfer;
  if v_org is null then raise exception 'Transfer not found.'; end if;
  m := private.require(v_org, null);
  if not (private.perm_of(m, 'transfer_stock') or private.perm_of(m, 'receive_stock')) then
    raise exception 'Your role does not allow receiving transfers.';
  end if;
  return private.receive_transfer_internal(p_transfer, m.id, now());
end $$;

-- ---------------------------------------------------------------------------
-- Stock counts (blind) and adjustments (Dr 5200 / Cr 1310)
-- ---------------------------------------------------------------------------
create or replace function public.create_count_session(
  p_org uuid, p_location uuid, p_area text, p_assignee uuid, p_item_ids uuid[] default null, p_category text default null
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; a public.members; v_id uuid; v_ref text; n int;
begin
  m := private.require(p_org, 'approve_adjustments');
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Choose a location.'; end if;
  select * into a from members where id = p_assignee and org_id = p_org and status <> 'disabled';
  if not found then raise exception 'Choose who will count.'; end if;
  if not private.perm_of(a, 'count_stock') then raise exception '% does not have the Count stock permission.', a.display_name; end if;
  v_ref := 'CS-' || lpad(private.next_no(p_org, 'CS', 1)::text, 3, '0');
  insert into count_sessions (org_id, ref, location_id, area, assignee_id, created_by)
  values (p_org, v_ref, p_location, coalesce(nullif(trim(p_area), ''), 'Whole store'), p_assignee, m.id) returning id into v_id;
  insert into count_lines (session_id, org_id, item_id)
  select v_id, p_org, i.id from items i
  where i.org_id = p_org and not i.archived
    and (p_item_ids is null or i.id = any(p_item_ids))
    and (p_category is null or p_category = '' or i.category = p_category)
    and (p_item_ids is not null or p_category is not null or exists (select 1 from stock_levels s where s.item_id = i.id and s.location_id = p_location and s.qty <> 0));
  get diagnostics n = row_count;
  if n = 0 then
    insert into count_lines (session_id, org_id, item_id)
    select v_id, p_org, i.id from items i where i.org_id = p_org and not i.archived;
    get diagnostics n = row_count;
  end if;
  if n = 0 then raise exception 'There are no items to count yet.'; end if;
  return jsonb_build_object('id', v_id, 'ref', v_ref, 'items', n);
end $$;

-- What the counter sees: items only, never the expected quantities.
create or replace function public.get_count_sheet(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.count_sessions; m public.members; v jsonb; v_can_see boolean;
begin
  select * into s from count_sessions where id = p_session;
  if not found then raise exception 'Count not found.'; end if;
  m := private.require(s.org_id, null);
  v_can_see := private.perm_of(m, 'approve_adjustments');
  if not (s.assignee_id = m.id or v_can_see) then raise exception 'This count is assigned to someone else.'; end if;
  select jsonb_build_object(
    'session', to_jsonb(s) || jsonb_build_object('location_name', (select name from locations where id = s.location_id)),
    'lines', coalesce(jsonb_agg(jsonb_build_object(
      'item_id', i.id, 'name', i.name, 'selling_unit', i.selling_unit, 'purchase_unit', i.purchase_unit, 'pack_size', i.pack_size,
      'photo_path', i.photo_path, 'barcode', i.barcode, 'qr_code', i.qr_code, 'category', i.category,
      'counted', cl.counted,
      'reason', cl.reason, 'note', cl.note,
      'variance', case when s.status <> 'open' and cl.counted is not null and cl.expected is not null then cl.counted - cl.expected end
    ) order by i.category, i.name), '[]'::jsonb))
  into v
  from count_lines cl join items i on i.id = cl.item_id
  where cl.session_id = p_session;
  return v;
end $$;

create or replace function public.submit_count(
  p_session uuid, p_lines jsonb, p_device text default null, p_offline boolean default false, p_client_uuid uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.count_sessions; m public.members; x jsonb; v_missing int; v_var jsonb; v_n int;
begin
  select * into s from count_sessions where id = p_session for update;
  if not found then raise exception 'Count not found.'; end if;
  m := private.require(s.org_id, 'count_stock');
  if s.assignee_id is distinct from m.id and not private.perm_of(m, 'approve_adjustments') then raise exception 'This count is assigned to someone else.'; end if;
  if p_client_uuid is not null and s.client_uuid = p_client_uuid then
    return jsonb_build_object('duplicate', true);
  end if;
  if s.status <> 'open' then raise exception 'This count was already submitted.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    if nullif(x->>'counted', '') is not null then
      if (x->>'counted')::numeric < 0 then raise exception 'Counts cannot be negative.'; end if;
      update count_lines set counted = (x->>'counted')::numeric
      where session_id = s.id and item_id = (x->>'item_id')::uuid;
    end if;
  end loop;
  select count(*) into v_missing from count_lines where session_id = s.id and counted is null;
  if v_missing > 0 then
    select count(*) into v_n from count_lines where session_id = s.id;
    raise exception 'Count all % items to submit.', v_n;
  end if;
  -- Snapshot expected at the moment the count is locked.
  update count_lines cl set expected = coalesce((select qty from stock_levels sl where sl.item_id = cl.item_id and sl.location_id = s.location_id), 0)
  where cl.session_id = s.id;
  select coalesce(jsonb_agg(jsonb_build_object('item_id', cl.item_id, 'name', i.name, 'selling_unit', i.selling_unit,
    'variance', cl.counted - cl.expected) order by i.name), '[]'::jsonb)
  into v_var
  from count_lines cl join items i on i.id = cl.item_id
  where cl.session_id = s.id and cl.counted <> cl.expected;
  update count_sessions set status = case when jsonb_array_length(v_var) > 0 then 'awaiting_reasons' else 'awaiting_approval' end,
    submitted_at = now(), device_id = p_device, offline = coalesce(p_offline, false), client_uuid = coalesce(p_client_uuid, client_uuid)
  where id = s.id;
  return jsonb_build_object('variances', v_var);
end $$;

create or replace function public.set_count_reasons(p_session uuid, p_reasons jsonb) returns text
language plpgsql security definer set search_path = public, private as $$
declare s public.count_sessions; m public.members; x jsonb; v_left int;
begin
  select * into s from count_sessions where id = p_session for update;
  if not found then raise exception 'Count not found.'; end if;
  m := private.require(s.org_id, null);
  if not (s.assignee_id = m.id or private.perm_of(m, 'approve_adjustments')) then raise exception 'This count is assigned to someone else.'; end if;
  if s.status not in ('awaiting_reasons', 'awaiting_approval') then raise exception 'Reasons can only be given after the count is submitted.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_reasons, '[]'::jsonb)) loop
    if x->>'reason' not in ('Breakage', 'Expired', 'Theft suspected', 'Miscount', 'Unrecorded sale', 'Other') then
      raise exception 'Pick a reason from the list.';
    end if;
    if x->>'reason' = 'Other' and coalesce(trim(x->>'note'), '') = '' then raise exception 'Add a note when the reason is Other.'; end if;
    update count_lines set reason = x->>'reason', note = nullif(trim(x->>'note'), '')
    where session_id = s.id and item_id = (x->>'item_id')::uuid;
  end loop;
  select count(*) into v_left from count_lines where session_id = s.id and counted <> expected and reason is null;
  update count_sessions set status = case when v_left = 0 then 'awaiting_approval' else 'awaiting_reasons' end where id = s.id;
  return case when v_left = 0 then 'awaiting_approval' else 'awaiting_reasons' end;
end $$;

create or replace function private.approve_count_internal(p_session uuid, p_member uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.count_sessions; cl record; v_wac numeric; v_diff numeric; v_val numeric; j public.journals; v_refs jsonb := '[]'::jsonb;
  v_total numeric := 0; v_left int; v_batch uuid; v_alloc jsonb;
begin
  select * into s from count_sessions where id = p_session for update;
  if s.status not in ('awaiting_approval', 'awaiting_reasons') then raise exception 'Only submitted counts can be approved.'; end if;
  select count(*) into v_left from count_lines where session_id = s.id and counted <> expected and reason is null;
  if v_left > 0 then raise exception '% variance% still need% a reason.', v_left, case when v_left > 1 then 's' else '' end, case when v_left > 1 then '' else 's' end; end if;
  for cl in select c.*, i.name as item_name from count_lines c join items i on i.id = c.item_id
            where c.session_id = s.id and c.counted <> c.expected order by i.name loop
    v_diff := cl.counted - cl.expected;
    select wac into v_wac from item_costs where item_id = cl.item_id;
    v_val := round(abs(v_diff) * coalesce(v_wac, 0), 2);
    v_total := v_total + sign(v_diff) * v_val;
    j := private.post_journal(s.org_id, 'Count ' || s.ref || ' · ' || cl.item_name || ' · ' || cl.reason, 'adjustment', s.id,
      (select assignee_id from count_sessions where id = s.id), p_member,
      case when v_diff < 0 then jsonb_build_array(
        jsonb_build_object('code', '5200', 'debit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id),
        jsonb_build_object('code', '1310', 'credit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id))
      else jsonb_build_array(
        jsonb_build_object('code', '1310', 'debit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id),
        jsonb_build_object('code', '5200', 'credit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id)) end, p_at);
    v_batch := null;
    if v_diff < 0 then
      v_alloc := private.consume_batches(cl.item_id, s.location_id, -v_diff);
      v_batch := (v_alloc->0->>'batch_id')::uuid;
    else
      select id into v_batch from batches where item_id = cl.item_id and location_id = s.location_id and not quarantined
        order by expiry_date desc nulls first limit 1;
      if v_batch is not null then update batches set qty_remaining = qty_remaining + v_diff where id = v_batch; end if;
    end if;
    perform private.add_movement(s.org_id, 'adjustment', cl.item_id, s.location_id, v_diff, coalesce(v_wac, 0), null, j.id,
      s.assignee_id, 'Camera count', p_at,
      jsonb_build_object('count_session_id', s.id, 'reason', cl.reason, 'note', cl.note, 'approver_id', p_member,
        'batch_id', v_batch, 'device_id', s.device_id, 'offline', s.offline));
    v_refs := v_refs || to_jsonb(j.ref);
  end loop;
  update count_sessions set status = 'approved', approved_by = p_member, approved_at = p_at where id = s.id;
  return jsonb_build_object('journals', v_refs, 'net_value', v_total);
end $$;

create or replace function public.approve_count(p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from count_sessions where id = p_session;
  if v_org is null then raise exception 'Count not found.'; end if;
  m := private.require(v_org, 'approve_adjustments');
  return private.approve_count_internal(p_session, m.id, now());
end $$;

create or replace function public.reject_count(p_session uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare s public.count_sessions;
begin
  select * into s from count_sessions where id = p_session for update;
  if not found then raise exception 'Count not found.'; end if;
  perform private.require(s.org_id, 'approve_adjustments');
  if s.status = 'approved' then raise exception 'Approved counts cannot be reopened.'; end if;
  update count_lines set counted = null, expected = null, reason = null, note = null where session_id = s.id;
  update count_sessions set status = 'open', submitted_at = null, rejected_count = rejected_count + 1, client_uuid = null where id = s.id;
end $$;

-- ---------------------------------------------------------------------------
-- Pricing: nothing reprices without an owner tap
-- ---------------------------------------------------------------------------
create or replace function private.refresh_price_alerts_internal(p_org uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare r record; o public.orgs; n int := 0; v_margin numeric;
begin
  select * into o from orgs where id = p_org;
  for r in
    select i.id, i.price, c.wac, c.replacement_cost, c.replacement_source
    from items i join item_costs c on c.item_id = i.id
    where i.org_id = p_org and not i.archived and c.wac > 0
      and not exists (select 1 from price_proposals p where p.item_id = i.id and p.status = 'open')
  loop
    if r.replacement_cost is not null and r.replacement_cost > r.price then
      if not exists (select 1 from price_proposals p where p.item_id = r.id and p.kind = 'below_replacement'
                     and p.status = 'dismissed' and p.decided_at > now() - interval '14 days') then
        perform private.propose_price(r.id, 'below_replacement', r.wac, r.replacement_cost,
          'Replacement cost · ' || coalesce(r.replacement_source, 'latest invoice'));
        n := n + 1;
      end if;
    else
      v_margin := (r.price - r.wac) / r.price * 100;
      if v_margin < o.margin_threshold and not exists (
        select 1 from price_proposals p where p.item_id = r.id and p.kind = 'margin_compressed'
          and p.status = 'dismissed' and p.decided_at > now() - interval '14 days') then
        perform private.propose_price(r.id, 'margin_compressed', r.wac, r.wac,
          'Margin below your ' || trim(to_char(o.margin_threshold, 'FM990.##')) || '% threshold');
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.refresh_price_alerts(p_org uuid) returns int
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'edit_prices');
  return private.refresh_price_alerts_internal(p_org);
end $$;

create or replace function private.set_price(p_item uuid, p_price numeric, p_reason text, p_member uuid, p_proposal uuid default null)
returns void
language plpgsql security definer set search_path = public as $$
declare it public.items;
begin
  select * into it from items where id = p_item for update;
  if p_price is null or p_price <= 0 then raise exception 'Enter a price above zero.'; end if;
  if it.price = p_price then return; end if;
  update items set price = p_price where id = p_item;
  insert into price_changes (org_id, item_id, old_price, new_price, reason, proposal_id, changed_by)
  values (it.org_id, p_item, it.price, p_price, p_reason, p_proposal, p_member);
end $$;

create or replace function public.decide_proposal(p_proposal uuid, p_apply boolean, p_price numeric default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare p public.price_proposals; m public.members; v_price numeric;
begin
  select * into p from price_proposals where id = p_proposal for update;
  if not found then raise exception 'Proposal not found.'; end if;
  m := private.require(p.org_id, 'edit_prices');
  if p.status <> 'open' then raise exception 'This proposal was already %.', p.status; end if;
  if p_apply then
    v_price := coalesce(p_price, p.suggested_price);
    perform private.set_price(p.item_id, v_price,
      case p.kind when 'cost_increase' then 'Cost increase' when 'below_replacement' then 'Below replacement cost' else 'Margin below threshold' end,
      m.id, p.id);
    update price_proposals set status = 'applied', decided_by = m.id, decided_at = now() where id = p.id;
  else
    update price_proposals set status = 'dismissed', decided_by = m.id, decided_at = now() where id = p.id;
  end if;
  return jsonb_build_object('status', case when p_apply then 'applied' else 'dismissed' end, 'price', v_price);
end $$;

create or replace function public.change_price(p_item uuid, p_price numeric, p_reason text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from items where id = p_item;
  if v_org is null then raise exception 'Item not found.'; end if;
  m := private.require(v_org, 'edit_prices');
  perform private.set_price(p_item, p_price, coalesce(nullif(trim(p_reason), ''), 'Manual edit'), m.id);
end $$;

-- Staff can see that proposals exist, but costs and margins stay masked for them.
create or replace function public.get_price_proposals(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', p.id, 'item_id', p.item_id, 'item_name', i.name, 'selling_unit', i.selling_unit, 'kind', p.kind, 'status', p.status,
    'old_cost', case when v_cost then p.old_cost end, 'new_cost', case when v_cost then p.new_cost end,
    'old_price', p.old_price, 'suggested_price', p.suggested_price,
    'target_margin', case when v_cost then p.target_margin end,
    'source_ref', p.source_ref, 'created_at', p.created_at, 'decided_at', p.decided_at,
    'decided_by_name', (select display_name from members where id = p.decided_by)
  ) order by (p.status = 'open') desc, p.created_at desc)
  from price_proposals p join items i on i.id = p.item_id
  where p.org_id = p_org and (p.status = 'open' or p.decided_at > now() - interval '30 days')), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Batches & expiry
-- ---------------------------------------------------------------------------
create or replace function private.quarantine_internal(p_batch uuid, p_member uuid, p_channel text, p_at timestamptz) returns text
language plpgsql security definer set search_path = public, private as $$
declare b public.batches; it public.items; v_wac numeric; v_val numeric; j public.journals;
begin
  select * into b from batches where id = p_batch for update;
  if b.quarantined then raise exception 'Batch % is already quarantined.', b.batch_no; end if;
  select * into it from items where id = b.item_id;
  select wac into v_wac from item_costs where item_id = b.item_id;
  if b.qty_remaining > 0 then
    v_val := round(b.qty_remaining * coalesce(v_wac, 0), 2);
    j := private.post_journal(b.org_id, 'Batch ' || b.batch_no || ' quarantined · ' || it.name ||
        coalesce(' · expiry ' || to_char(b.expiry_date, 'DD Mon YYYY'), ''), 'quarantine', b.id, p_member, p_member,
      jsonb_build_array(
        jsonb_build_object('code', '5200', 'debit', v_val, 'location_id', b.location_id, 'item_id', b.item_id),
        jsonb_build_object('code', '1310', 'credit', v_val, 'location_id', b.location_id, 'item_id', b.item_id)), p_at);
    perform private.add_movement(b.org_id, 'quarantine', b.item_id, b.location_id, -b.qty_remaining, coalesce(v_wac, 0), null, j.id,
      p_member, p_channel, p_at, jsonb_build_object('batch_id', b.id, 'reason', case when b.expiry_date < private.local_day(b.org_id, p_at) then 'Expired' else 'Quarantined' end,
        'note', 'Batch ' || b.batch_no || ' · out of sellable stock'));
  end if;
  update batches set quarantined = true, quarantined_at = p_at, quarantined_by = p_member where id = b.id;
  return j.ref;
end $$;

create or replace function public.quarantine_batch(p_batch uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from batches where id = p_batch;
  if v_org is null then raise exception 'Batch not found.'; end if;
  m := private.require(v_org, 'approve_adjustments');
  return private.quarantine_internal(p_batch, m.id, 'App', now());
end $$;

create or replace function private.auto_quarantine_expired() returns int
language plpgsql security definer set search_path = public, private as $$
declare b record; n int := 0;
begin
  for b in select id from batches where not quarantined and qty_remaining > 0 and expiry_date < private.local_day(org_id, now()) loop
    perform private.quarantine_internal(b.id, null, 'Expiry rule', now());
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Purchasing
-- ---------------------------------------------------------------------------
create or replace function public.save_po(
  p_org uuid, p_vendor uuid, p_lines jsonb, p_location uuid default null, p_send boolean default false,
  p_sent_via text default null, p_fx_note text default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.vendors; v_id uuid; v_ref text; x jsonb; v_total numeric := 0;
begin
  m := private.require(p_org, 'approve_pos');
  select * into v from vendors where id = p_vendor and org_id = p_org;
  if not found then raise exception 'Choose a vendor.'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then raise exception 'Add at least one line.'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    if nullif(x->>'qty', '') is null or (x->>'qty')::numeric < 1 then raise exception 'Quantity must be at least 1.'; end if;
    if not exists (select 1 from items where id = (x->>'item_id')::uuid and org_id = p_org) then raise exception 'Unknown item on the order.'; end if;
  end loop;
  v_ref := 'PO-' || lpad(private.next_no(p_org, 'PO', 1)::text, 4, '0');
  insert into purchase_orders (org_id, ref, vendor_id, location_id, status, sent_via, fx_note, note, created_by, approved_by, sent_at)
  values (p_org, v_ref, p_vendor, coalesce(p_location, (select id from locations where org_id = p_org and is_main limit 1)),
    case when p_send then 'sent' else 'draft' end, case when p_send then coalesce(p_sent_via, v.channel) end,
    p_fx_note, p_note, m.id, case when p_send then m.id end, case when p_send then now() end)
  returning id into v_id;
  insert into po_lines (po_id, org_id, item_id, qty, unit_cost)
  select v_id, p_org, (e->>'item_id')::uuid, (e->>'qty')::numeric, coalesce(nullif(e->>'unit_cost', '')::numeric, 0)
  from jsonb_array_elements(p_lines) e;
  select coalesce(sum(total), 0) into v_total from po_lines where po_id = v_id;
  update purchase_orders set total = v_total where id = v_id;
  update reorder_snoozes set until = current_date - 1
  where org_id = p_org and item_id in (select (e->>'item_id')::uuid from jsonb_array_elements(p_lines) e);
  return jsonb_build_object('id', v_id, 'ref', v_ref, 'total', v_total, 'status', case when p_send then 'sent' else 'draft' end,
    'vendor', v.name, 'channel', coalesce(p_sent_via, v.channel), 'phone', v.phone, 'email', v.email);
end $$;

create or replace function public.send_po(p_po uuid, p_sent_via text default null, p_qty numeric default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.purchase_orders; m public.members; v public.vendors;
begin
  select * into po from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found.'; end if;
  m := private.require(po.org_id, 'approve_pos');
  if po.status <> 'draft' then raise exception 'This order was already %.', po.status; end if;
  if p_qty is not null then
    if p_qty < 1 then raise exception 'Quantity must be at least 1.'; end if;
    update po_lines set qty = p_qty where po_id = po.id;
    update purchase_orders set total = (select coalesce(sum(total), 0) from po_lines where po_id = po.id) where id = po.id;
  end if;
  select * into v from vendors where id = po.vendor_id;
  update purchase_orders set status = 'sent', sent_via = coalesce(p_sent_via, v.channel), approved_by = m.id, sent_at = now() where id = po.id;
  return jsonb_build_object('ref', po.ref, 'vendor', v.name, 'channel', coalesce(p_sent_via, v.channel), 'phone', v.phone, 'email', v.email,
    'total', (select total from purchase_orders where id = po.id));
end $$;

create or replace function public.cancel_po(p_po uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare po public.purchase_orders;
begin
  select * into po from purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found.'; end if;
  perform private.require(po.org_id, 'approve_pos');
  if po.status not in ('draft', 'sent') then raise exception 'Only open orders can be cancelled.'; end if;
  update purchase_orders set status = 'cancelled' where id = p_po;
end $$;

create or replace function public.snooze_reorder(p_org uuid, p_item uuid, p_days int default 7) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'approve_pos');
  insert into reorder_snoozes (org_id, item_id, until, snoozed_by)
  values (p_org, p_item, current_date + greatest(1, coalesce(p_days, 7)), m.id)
  on conflict (org_id, item_id) do update set until = excluded.until, snoozed_by = excluded.snoozed_by;
end $$;

-- ---------------------------------------------------------------------------
-- Cash vs stock (Numens inputs)
-- ---------------------------------------------------------------------------
create or replace function public.record_takings(p_org uuid, p_location uuid, p_day date, p_cash numeric, p_pos numeric, p_transfers numeric)
returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'see_margins');
  if m.role not in ('owner', 'manager') then raise exception 'Only the owner or a manager records takings.'; end if;
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  if coalesce(p_cash, 0) < 0 or coalesce(p_pos, 0) < 0 or coalesce(p_transfers, 0) < 0 then raise exception 'Amounts cannot be negative.'; end if;
  insert into cash_takings (org_id, location_id, day, cash, pos, transfers, source, created_by)
  values (p_org, p_location, p_day, coalesce(p_cash, 0), coalesce(p_pos, 0), coalesce(p_transfers, 0), 'manual', m.id)
  on conflict (org_id, location_id, day) do update set cash = excluded.cash, pos = excluded.pos, transfers = excluded.transfers,
    source = 'manual', created_by = excluded.created_by;
end $$;

create or replace function public.get_cash_vs_stock(p_org uuid, p_days int default 42) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_tz text; v_from date;
begin
  m := private.require(p_org, 'see_margins');
  select timezone into v_tz from orgs where id = p_org;
  v_from := (now() at time zone v_tz)::date - p_days;
  return jsonb_build_object(
    'implied', coalesce((
      select jsonb_agg(jsonb_build_object('day', d, 'location_id', location_id, 'implied', implied, 'authors', authors) order by d)
      from (
        select (mv.recorded_at at time zone v_tz)::date d, mv.location_id,
               round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2) implied,
               jsonb_agg(distinct mb.display_name) filter (where mb.display_name is not null) authors
        from movements mv left join members mb on mb.id = mv.author_id
        where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and (mv.recorded_at at time zone v_tz)::date >= v_from
        group by 1, 2) t), '[]'::jsonb),
    'recorded', coalesce((
      select jsonb_agg(jsonb_build_object('day', day, 'location_id', location_id, 'cash', cash, 'pos', pos, 'transfers', transfers,
        'recorded', cash + pos + transfers, 'source', source) order by day)
      from cash_takings where org_id = p_org and day >= v_from), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------
create or replace function public.get_inventory(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_tz text; v jsonb;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  with sales as (
    select item_id,
      sum(-qty) filter (where recorded_at >= now() - interval '30 days') sold_30,
      sum(-qty) filter (where recorded_at >= now() - interval '60 days' and recorded_at < now() - interval '30 days') sold_prev30,
      sum(-qty * coalesce(unit_price, 0)) filter (where recorded_at >= now() - interval '30 days') revenue_30,
      sum(-qty * unit_cost) filter (where recorded_at >= now() - interval '30 days') cogs_30,
      max(recorded_at) last_sale_at
    from movements where org_id = p_org and type in ('sale', 'voice_sale')
    group by item_id),
  firsts as (
    select item_id, min(recorded_at) first_at, max(recorded_at) last_move_at from movements where org_id = p_org group by item_id),
  lv as (
    select item_id, jsonb_object_agg(location_id, qty) q from stock_levels where org_id = p_org group by item_id)
  select jsonb_build_object(
    'org', (select to_jsonb(o) from orgs o where o.id = p_org),
    'me', to_jsonb(m),
    'can_see_costs', v_cost,
    'now', now(),
    'today', (now() at time zone v_tz)::date,
    'locations', (select coalesce(jsonb_agg(to_jsonb(l) order by l.is_main desc, l.created_at), '[]'::jsonb) from locations l where l.org_id = p_org),
    'vendors', (select coalesce(jsonb_agg(to_jsonb(vd) order by vd.name), '[]'::jsonb) from vendors vd where vd.org_id = p_org),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', mb.id, 'display_name', mb.display_name, 'role', mb.role, 'title', mb.title, 'location_id', mb.location_id,
        'status', mb.status, 'email', mb.email, 'phone', mb.phone, 'has_login', mb.user_id is not null, 'is_me', mb.id = m.id,
        'voice_confirmed', mb.voice_confirmed,
        'perms', jsonb_build_object('record_sales', private.perm_of(mb, 'record_sales'), 'receive_stock', private.perm_of(mb, 'receive_stock'),
          'count_stock', private.perm_of(mb, 'count_stock'), 'approve_adjustments', private.perm_of(mb, 'approve_adjustments'),
          'edit_prices', private.perm_of(mb, 'edit_prices'), 'approve_pos', private.perm_of(mb, 'approve_pos'),
          'transfer_stock', private.perm_of(mb, 'transfer_stock'), 'see_margins', private.perm_of(mb, 'see_margins'))
      ) order by (mb.role = 'owner') desc, mb.created_at), '[]'::jsonb) from members mb where mb.org_id = p_org and mb.status <> 'disabled'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'photo_path', i.photo_path, 'barcode', i.barcode, 'sku', i.sku, 'qr_code', i.qr_code,
        'category', i.category, 'vat_treatment', i.vat_treatment, 'nafdac_no', i.nafdac_no, 'purchase_unit', i.purchase_unit,
        'pack_size', i.pack_size, 'selling_unit', i.selling_unit, 'informal_unit', i.informal_unit, 'track_batches', i.track_batches,
        'reorder_floor', i.reorder_floor, 'preferred_vendor_id', i.preferred_vendor_id, 'alt_vendor_id', i.alt_vendor_id,
        'price', i.price, 'import_priced', i.import_priced, 'notes', i.notes, 'needs_review', i.needs_review, 'created_at', i.created_at,
        'wac', case when v_cost then c.wac end, 'last_cost', case when v_cost then c.last_cost end,
        'replacement_cost', case when v_cost then c.replacement_cost end,
        'replacement_source', case when v_cost then c.replacement_source end,
        'qty', coalesce(lv.q, '{}'::jsonb),
        'sold_30', coalesce(s.sold_30, 0), 'sold_prev30', coalesce(s.sold_prev30, 0), 'revenue_30', coalesce(s.revenue_30, 0),
        'cogs_30', case when v_cost then coalesce(s.cogs_30, 0) end,
        'last_sale_at', s.last_sale_at, 'first_at', f.first_at, 'last_move_at', f.last_move_at,
        'snoozed_until', (select until from reorder_snoozes rs where rs.item_id = i.id)
      ) order by i.name), '[]'::jsonb)
      from items i left join item_costs c on c.item_id = i.id left join sales s on s.item_id = i.id
        left join firsts f on f.item_id = i.id left join lv on lv.item_id = i.id
      where i.org_id = p_org and not i.archived),
    'batches', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'item_id', b.item_id, 'location_id', b.location_id, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date,
        'qty_remaining', b.qty_remaining, 'qty_received', b.qty_received, 'quarantined', b.quarantined, 'quarantined_at', b.quarantined_at
      ) order by b.expiry_date nulls last), '[]'::jsonb)
      from batches b where b.org_id = p_org and (b.qty_remaining > 0 or b.quarantined_at > now() - interval '60 days'))
  ) into v;
  return v;
end $$;

-- Movement ledger. Grouped mode folds multi-line postings (receipts, day close) into one row per journal.
create or replace function public.get_ledger(
  p_org uuid, p_limit int default 50, p_location uuid default null, p_item uuid default null, p_grouped boolean default true
) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  if p_grouped then
    return coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.recorded_at desc) from (
      select coalesce(mv.journal_id, mv.id) gid, min(mv.type) type, count(*) n, count(distinct mv.item_id) n_items,
        (array_agg(mv.item_id))[1] item_id, (array_agg(i.name order by i.name))[1] item_name,
        (array_agg(i.selling_unit))[1] selling_unit, (array_agg(i.purchase_unit))[1] purchase_unit, (array_agg(i.pack_size))[1] pack_size,
        sum(mv.qty) qty, case when v_cost then sum(mv.value) end as value,
        sum(-mv.qty * coalesce(mv.unit_price, 0)) filter (where mv.type in ('sale', 'voice_sale')) sales_value,
        max(mv.recorded_at) recorded_at, max(mv.synced_at) synced_at, bool_or(mv.offline) offline,
        (array_agg(mv.location_id))[1] location_id, (array_agg(distinct mv.location_id)) location_ids,
        (array_agg(mb.display_name))[1] author_name, (array_agg(mv.channel))[1] channel, (array_agg(mv.device_id))[1] device_id,
        (array_agg(mv.reason))[1] reason, (array_agg(mv.note))[1] note, (array_agg(mv.review_status))[1] review_status,
        (array_agg(mv.id))[1] movement_id,
        j.ref journal_ref, j.memo journal_memo, r.ref receipt_ref, r.document_path, r.vendor_name, r.id receipt_id,
        (array_agg(mv.count_session_id))[1] count_session_id, (array_agg(mv.transfer_id))[1] transfer_id
      from movements mv join items i on i.id = mv.item_id
        left join members mb on mb.id = mv.author_id left join journals j on j.id = mv.journal_id
        left join receipts r on r.id = mv.receipt_id
      where mv.org_id = p_org and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
        and mv.recorded_at > now() - interval '120 days'
      group by coalesce(mv.journal_id, mv.id), j.ref, j.memo, r.ref, r.document_path, r.vendor_name, r.id
      order by max(mv.recorded_at) desc
      limit greatest(1, least(p_limit, 500))) t), '[]'::jsonb);
  end if;
  return coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.recorded_at desc) from (
    select mv.id gid, mv.id movement_id, mv.type, 1 n, 1 n_items, mv.item_id, i.name item_name, i.selling_unit, i.purchase_unit, i.pack_size,
      mv.qty, case when v_cost then mv.value end as value, case when v_cost then mv.unit_cost end as unit_cost,
      case when mv.type in ('sale', 'voice_sale') then -mv.qty * coalesce(mv.unit_price, 0) end sales_value,
      mv.recorded_at, mv.synced_at, mv.offline, mv.location_id, array[mv.location_id] location_ids, mb.display_name author_name,
      ap.display_name approver_name, mv.channel, mv.device_id, mv.reason, mv.note, mv.review_status,
      j.ref journal_ref, j.memo journal_memo, r.ref receipt_ref, r.document_path, r.vendor_name, r.id receipt_id,
      mv.count_session_id, mv.transfer_id
    from movements mv join items i on i.id = mv.item_id
      left join members mb on mb.id = mv.author_id left join members ap on ap.id = mv.approver_id
      left join journals j on j.id = mv.journal_id left join receipts r on r.id = mv.receipt_id
    where mv.org_id = p_org and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
    order by mv.recorded_at desc
    limit greatest(1, least(p_limit, 500))) t), '[]'::jsonb);
end $$;

create or replace function public.get_journal(p_journal_ref text, p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'see_margins');
  return (select jsonb_build_object('journal', to_jsonb(j) || jsonb_build_object(
      'posted_by_name', (select display_name from members where id = j.posted_by),
      'approved_by_name', (select display_name from members where id = j.approved_by)),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('code', jl.account_code, 'name', a.name, 'debit', jl.debit, 'credit', jl.credit,
        'location', (select name from locations where id = jl.location_id), 'memo', jl.memo) order by jl.debit desc, jl.id), '[]'::jsonb)
      from journal_lines jl join accounts a on a.code = jl.account_code where jl.journal_id = j.id),
    'document_path', (select document_path from receipts where journal_id = j.id limit 1))
  from journals j where j.org_id = p_org and j.ref = p_journal_ref);
end $$;

-- Vendor history feeding the explainable score.
create or replace function public.get_vendor_stats(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'approve_pos') or private.perm_of(m, 'see_margins')) then raise exception 'Your role does not allow this.'; end if;
  return coalesce((select jsonb_object_agg(v.id, jsonb_build_object(
    'receipts', (select count(*) from receipts r where r.vendor_id = v.id and r.status = 'posted'),
    'last_receipt_at', (select max(posted_at) from receipts r where r.vendor_id = v.id and r.status = 'posted'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('item_id', x.item_id, 'avg_cost', x.avg_cost, 'min_cost', x.min_cost,
        'max_cost', x.max_cost, 'n', x.n, 'cv', x.cv)), '[]'::jsonb)
      from (select mv.item_id, round(avg(mv.unit_cost), 4) avg_cost, min(mv.unit_cost) min_cost, max(mv.unit_cost) max_cost, count(*) n,
              case when avg(mv.unit_cost) > 0 then round(coalesce(stddev_pop(mv.unit_cost), 0) / avg(mv.unit_cost), 4) else 0 end cv
            from movements mv join receipts r on r.id = mv.receipt_id
            where r.vendor_id = v.id and mv.type = 'receipt' and mv.recorded_at > now() - interval '180 days'
            group by mv.item_id) x),
    'po_ordered', (select coalesce(sum(pl.qty * i.pack_size), 0) from purchase_orders po join po_lines pl on pl.po_id = po.id
      join items i on i.id = pl.item_id where po.vendor_id = v.id and po.status = 'received'),
    'po_received', (select coalesce(sum(mv.qty), 0) from purchase_orders po join receipts r on r.po_id = po.id
      join movements mv on mv.receipt_id = r.id where po.vendor_id = v.id and po.status = 'received'),
    'lead_days_measured', (select round(avg(extract(epoch from (r.posted_at - po.sent_at)) / 86400)::numeric, 1)
      from purchase_orders po join receipts r on r.po_id = po.id where po.vendor_id = v.id and po.sent_at is not null and r.posted_at is not null)
  )) from vendors v where v.org_id = p_org), '{}'::jsonb);
end $$;

