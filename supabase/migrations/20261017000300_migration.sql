-- Counta: moving from another inventory system.
-- A move has a go-live date. Items and their stock as at close of business that day post as opening stock dated that
-- day, so the first month in Counta opens on exactly the figure the old system closed on. Suppliers and past sales
-- come across too; past sales feed reorder and slow-stock rules without touching stock or the books. Every upload is
-- recorded so it can be undone while nothing has happened to what it created.

create table if not exists public.imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('items', 'vendors', 'sales_history')),
  source_system text,
  file_name text,
  as_of date,
  journal_ids uuid[] not null default '{}',
  created_items uuid[] not null default '{}',
  created_vendors uuid[] not null default '{}',
  rows_created int not null default 0,
  rows_updated int not null default 0,
  rows_skipped int not null default 0,
  opening_value numeric(16,2) not null default 0,
  expected_value numeric(16,2),
  period_from date,
  period_to date,
  status text not null default 'posted' check (status in ('posted', 'reversed')),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  reversed_by uuid references public.members(id) on delete set null,
  reversed_at timestamptz
);
create index if not exists imports_org on public.imports(org_id, created_at desc);
create index if not exists imports_created_by_fk on public.imports(created_by);
create index if not exists imports_reversed_by_fk on public.imports(reversed_by);

create table if not exists public.sales_history (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  location_id uuid references public.locations(id) on delete set null,
  day_from date not null,
  day_to date not null,
  qty numeric(14,3) not null check (qty >= 0),
  revenue numeric(16,2),
  import_id uuid references public.imports(id) on delete cascade,
  check (day_to >= day_from)
);
create index if not exists sales_history_item on public.sales_history(org_id, item_id, day_to);
create index if not exists sales_history_import on public.sales_history(import_id);
create index if not exists sales_history_item_fk on public.sales_history(item_id);
create index if not exists sales_history_location_fk on public.sales_history(location_id);

alter table public.imports enable row level security;
alter table public.sales_history enable row level security;
drop policy if exists imports_read on public.imports;
create policy imports_read on public.imports for select to authenticated using ((select private.can_see_costs(org_id)));
drop policy if exists sales_history_read on public.sales_history;
create policy sales_history_read on public.sales_history for select to authenticated using ((select private.is_member(org_id)));

alter table public.vendors add column if not exists tin text;

create or replace function private.overlap_days(a1 date, a2 date, b1 date, b2 date) returns int
language sql immutable set search_path = '' as $$
  select greatest(0, least(a2, b2) - greatest(a1, b1) + 1)
$$;

create or replace function private.yes(p text) returns boolean
language sql immutable set search_path = '' as $$
  select case when p is null or trim(p) = '' then null
              when lower(trim(p)) in ('yes', 'y', 'true', 't', '1', 'registered', 'vat', 'vatable', 'x', 'on') then true
              else false end
$$;

-- ---------------------------------------------------------------------------
-- Items and opening stock (adds go-live date and upload tracking)
-- ---------------------------------------------------------------------------
-- p_options also takes: as_of (go-live date), import_id (one id across chunks of one upload), source (old system),
-- expected_value (what the old system said the stock was worth).
create or replace function public.import_inventory(p_org uuid, p_rows jsonb, p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r jsonb; s jsonb; x record; v_idx int := 0; v_row int; v_id uuid; v_ex public.items;
  v_created int := 0; v_updated int := 0; v_skipped jsonb := '[]'::jsonb; v_ignored int := 0; v_zero int := 0;
  v_name text; v_price numeric; v_cost numeric; v_qty numeric; v_pack numeric; v_floor numeric; v_type text; v_su text; v_pu text;
  v_barcode text; v_sku text; v_vat text; v_vendor uuid; v_vname text; v_loc uuid; v_batch uuid; v_bno text; v_exp date;
  v_mode text := coalesce(nullif(p_options->>'mode', ''), 'skip');
  v_file text := left(coalesce(nullif(trim(p_options->>'file_name'), ''), 'Spreadsheet import'), 120);
  v_default_loc uuid := nullif(p_options->>'location_id', '')::uuid;
  v_ops jsonb := '[]'::jsonb; op jsonb; v_by jsonb := '{}'::jsonb; v_key text; v_total numeric := 0; v_jl jsonb := '[]'::jsonb;
  j public.journals; v_acct text; v_amt numeric; v_attrs jsonb; v_track boolean; v_locs uuid[]; v_has_stock boolean; v_new_type text;
  v_zero_flag boolean;
  v_import uuid := nullif(p_options->>'import_id', '')::uuid; v_asof date := private.date_or_null(p_options->>'as_of');
  v_at timestamptz := now(); v_tz text; v_today date; v_closed date; v_created_ids uuid[] := '{}';
begin
  m := private.require(p_org, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  if v_asof is not null then
    if v_asof > v_today then raise exception 'The go-live date cannot be in the future.'; end if;
    v_closed := private.closed_through(p_org);
    if v_closed is not null and v_asof <= v_closed then
      raise exception 'Stock up to % is in a closed month. Choose a later go-live date, or reopen that month first.', to_char(v_closed, 'DD Mon YYYY');
    end if;
    v_at := least(((v_asof + 1)::timestamp at time zone v_tz) - interval '1 second', now());
  end if;
  if v_import is not null and exists (select 1 from imports where id = v_import and (org_id <> p_org or status <> 'posted')) then
    raise exception 'This upload was already undone. Start it again.';
  end if;
  if v_mode not in ('skip', 'update') then raise exception 'Unknown import mode.'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'No rows to import.'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'Send at most 1,000 rows at a time.'; end if;
  select array_agg(id) into v_locs from locations where org_id = p_org;
  if v_default_loc is not null and not (v_default_loc = any(v_locs)) then raise exception 'Choose one of your branches for the opening stock.'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    v_row := coalesce(private.num(r->>'row')::int, v_idx);
    v_name := left(regexp_replace(trim(coalesce(r->>'name', '')), '\s+', ' ', 'g'), 200);
    v_price := private.num(r->>'price');
    v_cost := private.num(r->>'cost');
    v_pack := private.num(r->>'pack_size');
    v_floor := private.num(r->>'reorder_floor');
    if v_name = '' then
      v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', '', 'reason', 'No product name'); continue;
    end if;
    if v_cost is not null and v_cost < 0 then
      v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', v_name, 'reason', 'Cost is negative'); continue;
    end if;
    v_type := coalesce(nullif(trim(r->>'item_type'), ''), 'merchandise');
    if v_type not in ('merchandise', 'finished_good', 'raw_material', 'packaging', 'work_in_progress', 'consumable', 'spare_part', 'chemical') then
      v_type := 'merchandise';
    end if;
    v_sku := nullif(left(trim(coalesce(r->>'sku', '')), 80), '');
    v_barcode := nullif(left(regexp_replace(coalesce(r->>'barcode', ''), '\s', '', 'g'), 64), '');
    v_attrs := private.clean_attrs(r->'attributes');
    v_vat := case lower(coalesce(r->>'vat_treatment', '')) when 'zero' then 'zero' when 'exempt' then 'exempt' else 'standard' end;
    v_vname := nullif(left(trim(coalesce(r->>'vendor', '')), 120), '');
    v_vendor := null;
    if v_vname is not null then
      select id into v_vendor from vendors where org_id = p_org and lower(name) = lower(v_vname) limit 1;
      if v_vendor is null then
        insert into vendors (org_id, name) values (p_org, v_vname) returning id into v_vendor;
      end if;
    end if;

    select * into v_ex from items i where i.org_id = p_org and not i.archived and (
        (v_sku is not null and lower(i.sku) = lower(v_sku)) or (v_barcode is not null and i.barcode = v_barcode) or lower(i.name) = lower(v_name))
      order by (v_sku is not null and lower(i.sku) = lower(v_sku)) desc, (v_barcode is not null and i.barcode = v_barcode) desc
      limit 1;

    if v_ex.id is not null then
      if v_mode = 'skip' then
        v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', v_name, 'reason', 'Already in your items'); continue;
      end if;
      v_new_type := case when nullif(trim(r->>'item_type'), '') is not null then v_type else v_ex.item_type end;
      if private.sells(v_new_type) and coalesce(nullif(v_price, 0), v_ex.price) <= 0 then
        v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', v_name, 'reason', 'Needs a selling price'); continue;
      end if;
      if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode and id <> v_ex.id) then
        v_barcode := null;
      end if;
      select exists (select 1 from movements where item_id = v_ex.id) into v_has_stock;
      update items set
        name = v_name,
        sku = coalesce(v_sku, sku), barcode = coalesce(v_barcode, barcode),
        category = coalesce(nullif(left(trim(r->>'category'), 60), ''), category),
        brand = coalesce(nullif(left(trim(r->>'brand'), 80), ''), brand),
        description = coalesce(nullif(left(trim(r->>'description'), 1000), ''), description),
        vat_treatment = case when nullif(r->>'vat_treatment', '') is not null then v_vat else vat_treatment end,
        nafdac_no = coalesce(nullif(left(trim(r->>'nafdac_no'), 40), ''), nafdac_no),
        purchase_unit = case when v_has_stock then purchase_unit else coalesce(nullif(left(trim(r->>'purchase_unit'), 30), ''), purchase_unit) end,
        selling_unit = case when v_has_stock then selling_unit else coalesce(nullif(left(trim(r->>'selling_unit'), 30), ''), selling_unit) end,
        pack_size = case when v_has_stock or v_pack is null or v_pack < 1 then pack_size else floor(v_pack)::int end,
        reorder_floor = coalesce(case when v_floor >= 0 then v_floor end, reorder_floor),
        track_batches = coalesce((r->>'track_batches')::boolean, track_batches),
        import_priced = coalesce((r->>'import_priced')::boolean, import_priced),
        preferred_vendor_id = coalesce(v_vendor, preferred_vendor_id),
        price = case when v_price > 0 then v_price else price end,
        item_type = v_new_type,
        attributes = attributes || v_attrs,
        notes = notes || case when jsonb_typeof(r->'notes') = 'object' then r->'notes' else '{}'::jsonb end
      where id = v_ex.id;
      if v_new_type <> v_ex.item_type then
        perform private.move_item_account(v_ex.id, private.type_account(v_new_type), m.id);
      end if;
      if v_price > 0 and v_price <> v_ex.price then
        insert into price_changes (org_id, item_id, old_price, new_price, reason, changed_by)
        values (p_org, v_ex.id, v_ex.price, v_price, 'Spreadsheet import · ' || v_file, m.id);
      end if;
      if v_cost is not null and not exists (select 1 from stock_levels where item_id = v_ex.id and qty <> 0) then
        update item_costs set wac = v_cost, last_cost = coalesce(last_cost, v_cost), updated_at = now() where item_id = v_ex.id;
      end if;
      if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(r->'stock') = 'array' then r->'stock' else '[]'::jsonb end) e
                 where coalesce(private.num(e->>'qty'), 0) <> 0) then
        v_ignored := v_ignored + 1;
      end if;
      v_updated := v_updated + 1;
      continue;
    end if;

    if v_price is null or v_price <= 0 then
      if private.sells(v_type) then
        v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', v_name, 'reason', 'No selling price'); continue;
      end if;
      v_price := 0;
    end if;
    v_pack := greatest(1, floor(coalesce(v_pack, 1)));
    if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode) then v_barcode := null; end if;
    v_su := coalesce(nullif(left(trim(r->>'selling_unit'), 30), ''), 'piece');
    v_pu := coalesce(nullif(left(trim(r->>'purchase_unit'), 30), ''), case when v_pack > 1 then 'Carton' else initcap(v_su) end);
    v_track := coalesce((r->>'track_batches')::boolean, false)
      or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(r->'stock') = 'array' then r->'stock' else '[]'::jsonb end) e
                 where nullif(trim(e->>'batch_no'), '') is not null or private.date_or_null(e->>'expiry_date') is not null);
    insert into items (org_id, name, sku, barcode, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit, informal_unit,
      price, notes, needs_review, created_by, track_batches, reorder_floor, import_priced, preferred_vendor_id,
      item_type, brand, description, attributes, inventory_account)
    values (p_org, v_name, v_sku, v_barcode, coalesce(nullif(left(trim(r->>'category'), 60), ''), 'General'), v_vat,
      nullif(left(trim(r->>'nafdac_no'), 40), ''), v_pu, v_pack::int, v_su, v_su in ('derica', 'mudu', 'paint bucket'),
      v_price, case when jsonb_typeof(r->'notes') = 'object' then r->'notes' else '{}'::jsonb end, false, m.id, v_track,
      greatest(coalesce(v_floor, 0), 0), coalesce((r->>'import_priced')::boolean, false), v_vendor,
      v_type, nullif(left(trim(r->>'brand'), 80), ''), nullif(left(trim(r->>'description'), 1000), ''), v_attrs, private.type_account(v_type))
    returning id into v_id;
    v_created_ids := v_created_ids || v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, p_org, greatest(coalesce(v_cost, 0), 0), v_cost);
    v_created := v_created + 1;

    v_zero_flag := false;
    for s in select * from jsonb_array_elements(case when jsonb_typeof(r->'stock') = 'array' then r->'stock' else '[]'::jsonb end) loop
      v_qty := private.num(s->>'qty');
      if coalesce(v_qty, 0) <= 0 then continue; end if;
      v_loc := coalesce(nullif(s->>'location_id', '')::uuid, v_default_loc);
      if v_loc is null or not (v_loc = any(v_locs)) then continue; end if;
      if coalesce(v_cost, 0) = 0 then v_zero_flag := true; end if;
      v_amt := round(v_qty * greatest(coalesce(v_cost, 0), 0), 2);
      v_acct := coalesce(private.type_account(v_type), private.acct(p_org, 'inventory'));
      v_key := v_acct || '|' || v_loc::text;
      v_by := jsonb_set(v_by, array[v_key], to_jsonb(coalesce((v_by->>v_key)::numeric, 0) + v_amt));
      v_total := v_total + v_amt;
      v_ops := v_ops || jsonb_build_object('item_id', v_id, 'loc', v_loc, 'qty', v_qty, 'cost', greatest(coalesce(v_cost, 0), 0),
        'batch_no', nullif(left(trim(s->>'batch_no'), 60), ''), 'expiry', private.date_or_null(s->>'expiry_date'));
    end loop;
    if v_zero_flag then v_zero := v_zero + 1; end if;
  end loop;

  if v_total > 0 then
    for v_key, v_amt in select key, value::numeric from jsonb_each_text(v_by) where value::numeric <> 0 order by key loop
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', split_part(v_key, '|', 1), 'debit', v_amt,
        'location_id', split_part(v_key, '|', 2), 'memo', 'Opening stock'));
    end loop;
    for x in select split_part(key, '|', 2) as loc, sum(value::numeric) as amt from jsonb_each_text(v_by) group by 1 having sum(value::numeric) <> 0 loop
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'opening_equity'), 'credit', x.amt, 'location_id', x.loc,
        'memo', 'Opening stock · ' || v_file));
    end loop;
    j := private.post_journal(p_org, 'Opening stock · ' || v_file
      || case when v_asof is not null then ' · as at ' || to_char(v_asof, 'DD Mon YYYY') else '' end, 'opening', v_import, m.id, null, v_jl, v_at);
  end if;
  for op in select * from jsonb_array_elements(v_ops) loop
    v_batch := null;
    if op->>'batch_no' is not null or op->>'expiry' is not null then
      insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining)
      values (p_org, (op->>'item_id')::uuid, (op->>'loc')::uuid, coalesce(op->>'batch_no', 'OPENING'), (op->>'expiry')::date,
        (op->>'qty')::numeric, (op->>'qty')::numeric)
      returning id into v_batch;
    end if;
    perform private.add_movement(p_org, 'opening', (op->>'item_id')::uuid, (op->>'loc')::uuid, (op->>'qty')::numeric,
      (op->>'cost')::numeric, null, j.id, m.id, 'Import', v_at, jsonb_build_object('note', v_file, 'batch_id', v_batch));
  end loop;
  if v_import is not null then
    insert into imports (id, org_id, kind, source_system, file_name, as_of, journal_ids, created_items, rows_created, rows_updated,
      rows_skipped, opening_value, expected_value, created_by)
    values (v_import, p_org, 'items', nullif(left(trim(p_options->>'source'), 60), ''), v_file, v_asof,
      case when j.id is not null then array[j.id] else '{}'::uuid[] end, v_created_ids, v_created, v_updated,
      jsonb_array_length(v_skipped), v_total, private.num(p_options->>'expected_value'), m.id)
    on conflict (id) do update set journal_ids = imports.journal_ids || excluded.journal_ids,
      created_items = imports.created_items || excluded.created_items, rows_created = imports.rows_created + excluded.rows_created,
      rows_updated = imports.rows_updated + excluded.rows_updated, rows_skipped = imports.rows_skipped + excluded.rows_skipped,
      opening_value = imports.opening_value + excluded.opening_value,
      expected_value = coalesce(excluded.expected_value, imports.expected_value)
    where imports.org_id = p_org and imports.status = 'posted';
  end if;
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped, 'stock_ignored', v_ignored,
    'zero_cost', v_zero, 'journal_ref', j.ref, 'opening_value', v_total, 'stock_lines', jsonb_array_length(v_ops),
    'import_id', v_import, 'as_of', v_asof);
end $$;
-- ---------------------------------------------------------------------------
-- Suppliers
-- ---------------------------------------------------------------------------
-- p_rows: [{row, name, phone, email, channel, location, vat_registered, tin, lead_time_days, credit_days, notes}]
create or replace function public.import_vendors(p_org uuid, p_rows jsonb, p_options jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r jsonb; v public.vendors; v_name text; v_phone text; v_email text; v_channel text; v_lead int; v_credit int;
  v_created int := 0; v_updated int := 0; v_skipped jsonb := '[]'::jsonb; v_ids uuid[] := '{}'; v_row int; v_idx int := 0;
  v_mode text := coalesce(nullif(p_options->>'mode', ''), 'update'); v_import uuid := nullif(p_options->>'import_id', '')::uuid;
  v_vat boolean;
begin
  m := private.require(p_org, 'edit_prices');
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'No rows to import.'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Send at most 2,000 suppliers at a time.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    v_row := coalesce(private.num(r->>'row')::int, v_idx);
    v_name := left(regexp_replace(trim(coalesce(r->>'name', '')), '\s+', ' ', 'g'), 120);
    if v_name = '' then v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', '', 'reason', 'No supplier name'); continue; end if;
    v_phone := nullif(left(regexp_replace(coalesce(r->>'phone', ''), '[^0-9+]', '', 'g'), 20), '');
    v_email := nullif(lower(left(trim(coalesce(r->>'email', '')), 120)), '');
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
    v_channel := lower(coalesce(r->>'channel', ''));
    v_channel := case when v_channel like '%mail%' then 'email' when v_channel like '%call%' or v_channel = 'phone' then 'phone'
                      when v_channel like '%whatsapp%' then 'whatsapp' when v_phone is not null then 'whatsapp' when v_email is not null then 'email' else null end;
    v_lead := greatest(0, least(365, private.num(r->>'lead_time_days')::int));
    v_credit := greatest(0, least(365, private.num(r->>'credit_days')::int));
    v_vat := private.yes(r->>'vat_registered');
    select * into v from vendors where org_id = p_org and lower(name) = lower(v_name) limit 1;
    if found then
      if v_mode = 'skip' then v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', v_name, 'reason', 'Already a supplier'); continue; end if;
      update vendors set phone = coalesce(v_phone, phone), email = coalesce(v_email, email), channel = coalesce(v_channel, channel),
        location = coalesce(nullif(left(trim(r->>'location'), 120), ''), location), vat_registered = coalesce(v_vat, vat_registered),
        tin = coalesce(nullif(left(trim(r->>'tin'), 30), ''), tin), lead_time_days = coalesce(v_lead, lead_time_days),
        credit_days = coalesce(v_credit, credit_days), notes = coalesce(nullif(left(trim(r->>'notes'), 500), ''), notes)
      where id = v.id;
      v_updated := v_updated + 1;
    else
      insert into vendors (org_id, name, phone, email, channel, location, vat_registered, tin, lead_time_days, credit_days, notes)
      values (p_org, v_name, v_phone, v_email, coalesce(v_channel, 'whatsapp'), nullif(left(trim(r->>'location'), 120), ''),
        coalesce(v_vat, false), nullif(left(trim(r->>'tin'), 30), ''), coalesce(v_lead, 2), coalesce(v_credit, 0),
        nullif(left(trim(r->>'notes'), 500), ''))
      returning * into v;
      v_ids := v_ids || v.id;
      v_created := v_created + 1;
    end if;
  end loop;
  if v_import is not null then
    insert into imports (id, org_id, kind, source_system, file_name, created_vendors, rows_created, rows_updated, rows_skipped, created_by)
    values (v_import, p_org, 'vendors', nullif(left(trim(p_options->>'source'), 60), ''), left(coalesce(nullif(trim(p_options->>'file_name'), ''), 'Suppliers'), 120),
      v_ids, v_created, v_updated, jsonb_array_length(v_skipped), m.id)
    on conflict (id) do update set created_vendors = imports.created_vendors || excluded.created_vendors,
      rows_created = imports.rows_created + excluded.rows_created, rows_updated = imports.rows_updated + excluded.rows_updated,
      rows_skipped = imports.rows_skipped + excluded.rows_skipped
    where imports.org_id = p_org and imports.status = 'posted';
  end if;
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped, 'import_id', v_import);
end $$;

-- ---------------------------------------------------------------------------
-- Past sales
-- ---------------------------------------------------------------------------
-- p_rows: [{row, item, sku, barcode, location, date | (day_from, day_to), qty, revenue}]. Rows without a date use
-- p_options.period_from / period_to (a "sales by item" summary for a period). History stops the day before the
-- business's first sale in Counta so nothing is counted twice.
create or replace function public.import_sales_history(p_org uuid, p_rows jsonb, p_options jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r jsonb; v_tz text; v_today date; v_first date; v_cut date; v_from date; v_to date; v_item uuid; v_loc uuid;
  v_qty numeric; v_rev numeric; v_row int; v_idx int := 0; v_n int := 0; v_skipped jsonb := '[]'::jsonb; v_items uuid[] := '{}';
  v_pfrom date := private.date_or_null(p_options->>'period_from'); v_pto date := private.date_or_null(p_options->>'period_to');
  v_import uuid := coalesce(nullif(p_options->>'import_id', '')::uuid, gen_random_uuid()); v_min date; v_max date; v_qsum numeric := 0;
begin
  m := private.require(p_org, 'edit_prices');
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'No rows to import.'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Send at most 5,000 rows at a time.'; end if;
  if exists (select 1 from imports where id = v_import and (org_id <> p_org or status <> 'posted')) then
    raise exception 'This upload was already undone. Start it again.';
  end if;
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  select min((recorded_at at time zone v_tz)::date) into v_first from movements where org_id = p_org and type in ('sale', 'voice_sale');
  v_cut := coalesce(v_first, v_today + 1) - 1;
  insert into imports (id, org_id, kind, source_system, file_name, period_from, period_to, created_by)
  values (v_import, p_org, 'sales_history', nullif(left(trim(p_options->>'source'), 60), ''),
    left(coalesce(nullif(trim(p_options->>'file_name'), ''), 'Sales history'), 120), v_pfrom, v_pto, m.id)
  on conflict (id) do nothing;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    v_row := coalesce(private.num(r->>'row')::int, v_idx);
    v_qty := private.num(r->>'qty');
    if coalesce(v_qty, 0) <= 0 then continue; end if;
    v_rev := private.num(r->>'revenue');
    v_from := coalesce(private.date_or_null(r->>'date'), private.date_or_null(r->>'day_from'), v_pfrom);
    v_to := coalesce(private.date_or_null(r->>'date'), private.date_or_null(r->>'day_to'), v_pto, v_from);
    if v_from is null then v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', r->>'item', 'reason', 'No date and no period chosen'); continue; end if;
    if v_to < v_from then v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', r->>'item', 'reason', 'Period ends before it starts'); continue; end if;
    if v_from > v_cut then
      v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', r->>'item', 'reason', 'Counta already records sales from this date'); continue;
    end if;
    if v_to > v_cut then
      v_qty := v_qty * (v_cut - v_from + 1) / (v_to - v_from + 1);
      v_rev := v_rev * (v_cut - v_from + 1) / (v_to - v_from + 1);
      v_to := v_cut;
    end if;
    select id into v_item from items i where i.org_id = p_org and not i.archived and (
        (nullif(trim(r->>'sku'), '') is not null and lower(i.sku) = lower(trim(r->>'sku')))
        or (nullif(trim(r->>'barcode'), '') is not null and i.barcode = regexp_replace(r->>'barcode', '\s', '', 'g'))
        or lower(i.name) = lower(regexp_replace(trim(coalesce(r->>'item', '')), '\s+', ' ', 'g')))
      order by (nullif(trim(r->>'sku'), '') is not null and lower(i.sku) = lower(trim(r->>'sku'))) desc limit 1;
    if v_item is null then
      v_skipped := v_skipped || jsonb_build_object('row', v_row, 'name', coalesce(r->>'item', r->>'sku'), 'reason', 'No matching item in Counta'); continue;
    end if;
    v_loc := null;
    if nullif(trim(r->>'location'), '') is not null then
      select id into v_loc from locations where org_id = p_org and (lower(name) = lower(trim(r->>'location')) or lower(code) = lower(trim(r->>'location')));
    end if;
    insert into sales_history (org_id, item_id, location_id, day_from, day_to, qty, revenue, import_id)
    values (p_org, v_item, v_loc, v_from, v_to, round(v_qty, 3), round(v_rev, 2), v_import);
    v_n := v_n + 1; v_qsum := v_qsum + v_qty;
    if not v_item = any(v_items) then v_items := v_items || v_item; end if;
    v_min := least(coalesce(v_min, v_from), v_from); v_max := greatest(coalesce(v_max, v_to), v_to);
  end loop;
  update imports set rows_created = rows_created + v_n, rows_skipped = rows_skipped + jsonb_array_length(v_skipped),
    period_from = least(coalesce(period_from, v_min), v_min), period_to = greatest(coalesce(period_to, v_max), v_max)
  where id = v_import;
  -- An upload that brought nothing in leaves no trace in the uploads list.
  delete from imports where id = v_import and rows_created = 0 and not exists (select 1 from sales_history where import_id = v_import);
  return jsonb_build_object('imported', v_n, 'items', cardinality(v_items), 'qty', round(v_qsum, 3), 'skipped', v_skipped,
    'from', v_min, 'to', v_max, 'import_id', v_import, 'cutoff', v_cut);
end $$;

-- ---------------------------------------------------------------------------
-- Undo an upload
-- ---------------------------------------------------------------------------
create or replace function public.undo_import(p_import uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare im public.imports; m public.members; jid uuid; oj public.journals; rj public.journals; v_refs jsonb := '[]'::jsonb; mv record;
  v_vendors int := 0; v_hist int := 0; v_items int := 0;
begin
  select * into im from imports where id = p_import for update;
  if not found then raise exception 'Upload not found.'; end if;
  m := private.require(im.org_id, 'owner');
  if im.status <> 'posted' then raise exception 'This upload was already undone.'; end if;
  if im.kind = 'items' then
    if exists (select 1 from movements x where x.item_id = any(im.created_items)
               and not (x.type = 'opening' and x.journal_id = any(im.journal_ids))) then
      raise exception 'Some of these items have been sold, received, counted or moved since the upload, so it cannot be undone. Correct them with a stock count instead.';
    end if;
    foreach jid in array im.journal_ids loop
      select * into oj from journals where id = jid;
      if not found then continue; end if;
      rj := private.post_journal(im.org_id, 'Undo · ' || oj.memo, 'opening', im.id, m.id, m.id,
        (select jsonb_agg(jsonb_build_object('code', jl.account_code, 'debit', jl.credit, 'credit', jl.debit, 'location_id', jl.location_id,
           'item_id', jl.item_id, 'memo', 'Undo ' || oj.ref)) from journal_lines jl where jl.journal_id = oj.id),
        oj.created_at);
      v_refs := v_refs || to_jsonb(rj.ref);
      for mv in select * from movements where journal_id = oj.id and type = 'opening' loop
        perform private.add_movement(im.org_id, 'opening', mv.item_id, mv.location_id, -mv.qty, mv.unit_cost, null, rj.id, m.id, 'Import',
          oj.created_at, jsonb_build_object('note', 'Upload undone', 'batch_id', mv.batch_id));
      end loop;
    end loop;
    update batches set qty_remaining = 0 where item_id = any(im.created_items);
    update items set archived = true where id = any(im.created_items);
    get diagnostics v_items = row_count;
  elsif im.kind = 'vendors' then
    delete from vendors v where v.id = any(im.created_vendors)
      and not exists (select 1 from items i where i.preferred_vendor_id = v.id or i.alt_vendor_id = v.id)
      and not exists (select 1 from receipts r where r.vendor_id = v.id)
      and not exists (select 1 from purchase_orders po where po.vendor_id = v.id);
    get diagnostics v_vendors = row_count;
  else
    delete from sales_history where import_id = im.id;
    get diagnostics v_hist = row_count;
  end if;
  update imports set status = 'reversed', reversed_by = m.id, reversed_at = now() where id = im.id;
  return jsonb_build_object('journals', v_refs, 'items_archived', v_items, 'vendors_removed', v_vendors, 'history_rows_removed', v_hist);
end $$;

create or replace function public.get_imports(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices')) then
    raise exception 'Uploads show costs, which your role does not see.' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', im.id, 'kind', im.kind, 'source_system', im.source_system, 'file_name', im.file_name, 'as_of', im.as_of,
      'rows_created', im.rows_created, 'rows_updated', im.rows_updated, 'rows_skipped', im.rows_skipped,
      'opening_value', im.opening_value, 'expected_value', im.expected_value, 'period_from', im.period_from, 'period_to', im.period_to,
      'items', cardinality(im.created_items), 'vendors', cardinality(im.created_vendors),
      'journals', (select jsonb_agg(ref order by je_no) from journals where id = any(im.journal_ids)),
      'by_location', (select jsonb_object_agg(l.name, t.v) from (
          select jl.location_id, sum(jl.debit - jl.credit) v from journal_lines jl
          where jl.journal_id = any(im.journal_ids) and jl.account_code <> private.acct(im.org_id, 'opening_equity') group by 1) t
        join locations l on l.id = t.location_id),
      'status', im.status, 'created_at', im.created_at, 'created_by', (select display_name from members where id = im.created_by),
      'reversed_at', im.reversed_at,
      'can_undo', im.status = 'posted' and (im.kind <> 'items' or not exists (
          select 1 from movements x where x.item_id = any(im.created_items) and not (x.type = 'opening' and x.journal_id = any(im.journal_ids)))))
    order by im.created_at desc) from imports im where im.org_id = p_org), '[]'::jsonb);
end $$;
