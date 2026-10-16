-- Counta · industries, richer item records, spreadsheet import and reports
--
-- 1. A business picks its industry (retail, pharmacy, restaurant, fashion, electronics, building
--    materials, agro, manufacturing, auto parts, beauty, industrial supplies...). The app shows the
--    item fields that industry needs; they live in items.attributes, keyed by field.
-- 2. Items gain a type. Merchandise and finished goods are sold and need a price. Raw materials,
--    packaging, work in progress, consumables, spare parts and chemicals may have no selling price,
--    and their stock sits in the matching TaxStreem inventory account (1201, 1202, 1205, 1206).
-- 3. import_inventory() takes rows already mapped from a spreadsheet: new items with opening stock
--    per branch (and batches), or updates to existing items matched by catalogue ID, barcode or name.
-- 4. inventory_report() returns the rows for the Reports page: stock valuation, movement summary,
--    stock card, ledgers, purchases, input VAT, sales, adjustments, transfers and more.

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists industry text not null default 'retail';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orgs_industry_check') then
    alter table public.orgs add constraint orgs_industry_check check (industry in (
      'retail', 'wholesale', 'pharmacy', 'food', 'fashion', 'electronics', 'building', 'agro',
      'manufacturing', 'auto', 'beauty', 'industrial', 'other'));
  end if;
end $$;

alter table public.items
  add column if not exists item_type text not null default 'merchandise',
  add column if not exists brand text,
  add column if not exists description text,
  add column if not exists attributes jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'items_item_type_check') then
    alter table public.items add constraint items_item_type_check check (item_type in (
      'merchandise', 'finished_good', 'raw_material', 'packaging', 'work_in_progress', 'consumable', 'spare_part', 'chemical'));
  end if;
  if exists (select 1 from pg_constraint where conname = 'items_price_check'
             and pg_get_constraintdef(oid) = 'CHECK ((price > (0)::numeric))') then
    alter table public.items drop constraint items_price_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_price_rule') then
    alter table public.items add constraint items_price_rule check (
      price > 0 or (price = 0 and item_type not in ('merchandise', 'finished_good')));
  end if;
end $$;

create index if not exists items_org_sku on public.items(org_id, lower(sku)) where sku is not null;
create index if not exists items_org_lname on public.items(org_id, lower(name));

comment on column public.items.item_type is 'merchandise and finished_good are sold and need a price; the rest may be held at price 0.';
comment on column public.items.attributes is 'Industry fields (strength, size, colour, part number...), keyed by the field key in the app catalogue.';

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
create or replace function private.sells(p_type text) returns boolean
language sql immutable as $$
  select coalesce(p_type, 'merchandise') in ('merchandise', 'finished_good')
$$;

create or replace function private.type_account(p_type text) returns text
language sql immutable as $$
  select case p_type
    when 'raw_material' then '1201' when 'packaging' then '1201'
    when 'work_in_progress' then '1202'
    when 'consumable' then '1205' when 'spare_part' then '1205'
    when 'chemical' then '1206'
    else null end
$$;

create or replace function private.num(p text) returns numeric
language plpgsql immutable as $$
declare s text := regexp_replace(coalesce(p, ''), '[^0-9.\-]', '', 'g');
begin
  if s in ('', '-', '.', '-.') then return null; end if;
  return s::numeric;
exception when others then
  return null;
end $$;

create or replace function private.date_or_null(p text) returns date
language plpgsql immutable as $$
begin
  if coalesce(trim(p), '') = '' then return null; end if;
  return trim(p)::date;
exception when others then
  return null;
end $$;

create or replace function private.clean_attrs(p jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(left(key, 60),
           case when jsonb_typeof(value) = 'string' then to_jsonb(left(trim(value #>> '{}'), 500)) else value end), '{}'::jsonb)
  from (
    select key, value from jsonb_each(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end)
    where jsonb_typeof(value) in ('string', 'number', 'boolean') and trim(value #>> '{}') <> ''
    limit 80
  ) x
$$;

-- Moves an item to another inventory account, carrying its stock value with a reclass journal.
-- Used when an item's type changes (for example merchandise to raw material).
create or replace function private.move_item_account(p_item uuid, p_code text, p_member uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare it public.items; v_old text; v_new text; v_wac numeric; v_lines jsonb := '[]'::jsonb; x record;
begin
  select * into it from items where id = p_item;
  v_old := private.inv_acct(p_item);
  v_new := coalesce(p_code, private.acct(it.org_id, 'inventory'));
  if v_old <> v_new then
    select wac into v_wac from item_costs where item_id = p_item;
    for x in select location_id, round(qty * coalesce(v_wac, 0), 2) as val from stock_levels
             where item_id = p_item and round(qty * coalesce(v_wac, 0), 2) <> 0 loop
      v_lines := v_lines || private.reclass_pair(v_new, v_old, x.val, x.location_id, p_item);
    end loop;
    if jsonb_array_length(v_lines) > 0 then
      perform private.post_journal(it.org_id, 'Reclass · ' || it.name || ' from ' || v_old || ' to ' || v_new, 'reclass', p_item, p_member, p_member, v_lines);
    end if;
  end if;
  perform set_config('app.reclass', 'on', true);
  update items set inventory_account = p_code where id = p_item;
  perform set_config('app.reclass', 'off', true);
end $$;

-- Items held at price 0 (raw materials, spares...) never get price proposals.
create or replace function private.propose_price(p_item uuid, p_kind text, p_old_cost numeric, p_new_cost numeric, p_source text)
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare it public.items; o public.orgs; s jsonb; v_id uuid;
begin
  select * into it from public.items where id = p_item;
  if it.price is null or it.price <= 0 then return null; end if;
  select * into o from public.orgs where id = it.org_id;
  s := private.suggest_price(it.price, p_old_cost, p_new_cost, o.margin_threshold);
  if (s->>'price')::numeric <= it.price and p_kind = 'cost_increase' then
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

create or replace function private.refresh_price_alerts_internal(p_org uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare r record; o public.orgs; n int := 0; v_margin numeric;
begin
  select * into o from orgs where id = p_org;
  for r in
    select i.id, i.price, c.wac, c.replacement_cost, c.replacement_source
    from items i join item_costs c on c.item_id = i.id
    where i.org_id = p_org and not i.archived and c.wac > 0 and i.price > 0
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

-- ---------------------------------------------------------------------------
-- 3. Creating and editing items
-- ---------------------------------------------------------------------------
create or replace function public.upsert_item(p_org uuid, p_item jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_id uuid := nullif(p_item->>'id', '')::uuid; v_old public.items;
  v_name text := trim(coalesce(p_item->>'name', '')); v_pack numeric; v_price numeric; v_cost numeric; v_qty numeric;
  v_barcode text := nullif(trim(coalesce(p_item->>'barcode', '')), ''); v_su text;
  v_type text := coalesce(nullif(p_item->>'item_type', ''), 'merchandise'); v_attrs jsonb := private.clean_attrs(p_item->'attributes');
begin
  m := private.require(p_org, 'edit_prices');
  if v_name = '' then raise exception 'Product name is required.'; end if;
  if v_type not in ('merchandise', 'finished_good', 'raw_material', 'packaging', 'work_in_progress', 'consumable', 'spare_part', 'chemical') then
    raise exception 'Choose what kind of item this is.';
  end if;
  begin
    v_pack := nullif(p_item->>'pack_size', '')::numeric;
    v_price := nullif(p_item->>'price', '')::numeric;
    v_cost := nullif(p_item->>'cost', '')::numeric;
  exception when others then raise exception 'Pack size, cost and price must be numbers.';
  end;
  if v_price is null and not private.sells(v_type) then v_price := 0; end if;
  if v_pack is null or v_pack < 1 or v_pack <> floor(v_pack) then raise exception 'Pack size must be a whole number, at least 1.'; end if;
  if v_price is null or v_price < 0 or (v_price = 0 and private.sells(v_type)) then raise exception 'Enter a selling price.'; end if;
  if v_cost is not null and v_cost < 0 then raise exception 'Cost cannot be negative.'; end if;
  if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode and id is distinct from v_id) then
    raise exception 'Another item already uses barcode %.', v_barcode;
  end if;
  v_su := coalesce(nullif(trim(p_item->>'selling_unit'), ''), 'piece');

  if v_id is null then
    if v_cost is null then raise exception 'Enter a cost per selling unit.'; end if;
    insert into items (org_id, name, barcode, sku, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit,
      informal_unit, track_batches, reorder_floor, preferred_vendor_id, alt_vendor_id, price, import_priced, photo_path, created_by,
      item_type, brand, description, attributes, inventory_account)
    values (p_org, v_name, v_barcode, nullif(trim(p_item->>'sku'), ''), coalesce(nullif(trim(p_item->>'category'), ''), 'General'),
      coalesce(nullif(p_item->>'vat_treatment', ''), 'standard'), nullif(trim(p_item->>'nafdac_no'), ''),
      coalesce(nullif(trim(p_item->>'purchase_unit'), ''), 'Carton'), v_pack::int, v_su,
      coalesce((p_item->>'informal_unit')::boolean, v_su in ('derica', 'mudu', 'paint bucket')),
      coalesce((p_item->>'track_batches')::boolean, false), coalesce(nullif(p_item->>'reorder_floor', '')::numeric, 0),
      nullif(p_item->>'preferred_vendor_id', '')::uuid, nullif(p_item->>'alt_vendor_id', '')::uuid,
      v_price, coalesce((p_item->>'import_priced')::boolean, false), nullif(p_item->>'photo_path', ''), m.id,
      v_type, nullif(trim(p_item->>'brand'), ''), nullif(trim(p_item->>'description'), ''), v_attrs, private.type_account(v_type))
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
      item_type = v_type,
      brand = case when p_item ? 'brand' then nullif(trim(p_item->>'brand'), '') else brand end,
      description = case when p_item ? 'description' then nullif(trim(p_item->>'description'), '') else description end,
      attributes = case when p_item ? 'attributes' then v_attrs else attributes end,
      import_priced = coalesce((p_item->>'import_priced')::boolean, import_priced),
      photo_path = case when p_item ? 'photo_path' then nullif(p_item->>'photo_path', '') else photo_path end,
      needs_review = case when p_item ? 'needs_review' then (p_item->>'needs_review')::boolean else false end
    where id = v_id;
    if v_old.item_type <> v_type then
      perform private.move_item_account(v_id, private.type_account(v_type), m.id);
    end if;
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

-- ---------------------------------------------------------------------------
-- 4. Spreadsheet import
-- ---------------------------------------------------------------------------
-- p_rows: [{row, name, sku, barcode, category, brand, description, item_type, vat_treatment, nafdac_no,
--           purchase_unit, pack_size, selling_unit, price, cost, reorder_floor, track_batches, import_priced,
--           vendor, attributes{}, notes{}, stock: [{location_id, qty, batch_no, expiry_date}]}]
-- p_options: {mode: 'skip' | 'update', location_id (default branch), file_name}
-- Quantities and costs arrive in selling units. Quantities only post for new items, as opening stock;
-- an existing item's stock changes through a count, so the books keep one story.
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
begin
  m := private.require(p_org, 'edit_prices');
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
    j := private.post_journal(p_org, 'Opening stock · ' || v_file, 'opening', null, m.id, null, v_jl);
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
      (op->>'cost')::numeric, null, j.id, m.id, 'Import', now(), jsonb_build_object('note', v_file, 'batch_id', v_batch));
  end loop;
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped, 'stock_ignored', v_ignored,
    'zero_cost', v_zero, 'journal_ref', j.ref, 'opening_value', v_total, 'stock_lines', jsonb_array_length(v_ops));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Reports
-- ---------------------------------------------------------------------------
-- Every report returns {rows: [...], extra: {...}, truncated}. Dates are the business's local days.
-- Value columns need "See margins" or "Edit prices"; reports that are mostly values refuse without it,
-- the rest come back with the value columns empty.
create or replace function public.inventory_report(
  p_org uuid, p_report text, p_from date default null, p_to date default null,
  p_location uuid default null, p_item uuid default null, p_accounts text[] default null
) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_tz text; v_today date; v_from date; v_to date; v_f timestamptz; v_t timestamptz;
  v_rows jsonb; v_extra jsonb := '{}'::jsonb; v_cap int := 50000; v_inv_re text; v_git text; v_accts text[];
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_to := least(coalesce(p_to, v_today), v_today + 1);
  v_from := coalesce(p_from, date_trunc('month', v_to)::date);
  if v_from > v_to then raise exception 'The start date is after the end date.'; end if;
  v_f := v_from::timestamp at time zone v_tz;
  v_t := (v_to + 1)::timestamp at time zone v_tz;
  select allowed into v_inv_re from posting_roles where role = 'inventory';
  v_git := private.acct(p_org, 'goods_in_transit');

  if p_report in ('valuation', 'movement_summary', 'gl', 'journals', 'trial_balance', 'purchases', 'purchase_lines', 'input_vat',
                  'vendors', 'cash_vs_stock', 'purchase_orders') and not v_cost then
    raise exception 'This report shows costs, which your role does not see.' using errcode = '42501';
  end if;

  if p_report = 'valuation' then
    with mv as (
      select item_id, location_id, sum(qty) q, sum(value) v from movements
      where org_id = p_org and recorded_at < v_t group by 1, 2),
    landed as (
      select (a->>'item_id')::uuid item_id, sum((a->>'allocated')::numeric) amt
      from landed_costs lc cross join lateral jsonb_array_elements(lc.allocation) a
      where lc.org_id = p_org and lc.created_at < v_t and coalesce((a->>'absorbed')::boolean, false) group by 1),
    book as (
      select mv.item_id, sum(mv.q) q, sum(mv.v) + coalesce(max(l.amt), 0) bv
      from mv left join landed l on l.item_id = mv.item_id group by mv.item_id),
    rows as (
      select i.name, i.sku, i.category, i.item_type, i.brand, i.selling_unit, i.purchase_unit, i.pack_size, i.price,
        coalesce(i.inventory_account, private.acct(p_org, 'inventory')) acct, l.name loc, mv.q,
        case when b.q <> 0 then b.bv / b.q end uc
      from mv join book b on b.item_id = mv.item_id join items i on i.id = mv.item_id join locations l on l.id = mv.location_id
      where mv.q <> 0 and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item))
    select jsonb_agg(jsonb_build_object(
        'item', name, 'sku', sku, 'category', category, 'item_type', item_type, 'brand', brand, 'account', acct, 'location', loc,
        'qty', q, 'unit', selling_unit, 'cartons', case when pack_size > 1 then round(q / pack_size, 2) end, 'purchase_unit', purchase_unit,
        'unit_cost', round(uc, 4), 'value', round(q * coalesce(uc, 0), 2), 'price', price, 'retail_value', round(q * price, 2),
        'margin_pct', case when price > 0 and uc is not null then round((price - uc) / price * 100, 1) end)
      order by name, loc)
    into v_rows from rows;
    select jsonb_build_object(
      'as_at', v_to,
      'gl_inventory', coalesce(sum(jl.debit - jl.credit) filter (where jl.account_code ~ v_inv_re), 0),
      'gl_in_transit', coalesce(sum(jl.debit - jl.credit) filter (where jl.account_code = v_git), 0))
    into v_extra
    from journal_lines jl join journals j on j.id = jl.journal_id
    where jl.org_id = p_org and j.entry_date <= v_to and (p_location is null or jl.location_id = p_location);

  elsif p_report = 'movement_summary' then
    with lc as (
      select (a->>'item_id')::uuid item_id, lc.created_at at, (a->>'allocated')::numeric amt
      from landed_costs lc cross join lateral jsonb_array_elements(lc.allocation) a
      where lc.org_id = p_org and coalesce((a->>'absorbed')::boolean, false)),
    bf as (select item_id, sum(qty) q, sum(value) v from movements where org_id = p_org and recorded_at < v_f group by 1),
    bt as (select item_id, sum(qty) q, sum(value) v from movements where org_id = p_org and recorded_at < v_t group by 1),
    uf as (select bf.item_id, case when bf.q <> 0 then (bf.v + coalesce((select sum(amt) from lc where lc.item_id = bf.item_id and lc.at < v_f), 0)) / bf.q end uc from bf),
    ut as (select bt.item_id, case when bt.q <> 0 then (bt.v + coalesce((select sum(amt) from lc where lc.item_id = bt.item_id and lc.at < v_t), 0)) / bt.q end uc from bt),
    sf as (select item_id, sum(qty) q from movements where org_id = p_org and recorded_at < v_f and (p_location is null or location_id = p_location) group by 1),
    st as (select item_id, sum(qty) q from movements where org_id = p_org and recorded_at < v_t and (p_location is null or location_id = p_location) group by 1),
    fl as (
      select item_id,
        coalesce(sum(qty) filter (where type = 'opening'), 0) open_q, coalesce(sum(value) filter (where type = 'opening'), 0) open_v,
        coalesce(sum(qty) filter (where type = 'receipt'), 0) rec_q, coalesce(sum(value) filter (where type = 'receipt'), 0) rec_v,
        coalesce(sum(-qty) filter (where type in ('sale', 'voice_sale')), 0) sold_q, coalesce(sum(-value) filter (where type in ('sale', 'voice_sale')), 0) cogs,
        coalesce(sum(-qty * coalesce(unit_price, 0)) filter (where type in ('sale', 'voice_sale')), 0) revenue,
        coalesce(sum(qty) filter (where type = 'transfer_in'), 0) tin_q, coalesce(sum(value) filter (where type = 'transfer_in'), 0) tin_v,
        coalesce(sum(-qty) filter (where type = 'transfer_out'), 0) tout_q, coalesce(sum(-value) filter (where type = 'transfer_out'), 0) tout_v,
        coalesce(sum(qty) filter (where type in ('adjustment', 'write_off', 'quarantine')), 0) adj_q,
        coalesce(sum(value) filter (where type in ('adjustment', 'write_off', 'quarantine')), 0) adj_v
      from movements where org_id = p_org and recorded_at >= v_f and recorded_at < v_t and (p_location is null or location_id = p_location)
      group by 1),
    r as (
      select i.id, i.name, i.sku, i.category, i.item_type, i.selling_unit,
        coalesce(sf.q, 0) oq, round(coalesce(sf.q, 0) * coalesce(uf.uc, 0), 2) ov,
        coalesce(st.q, 0) cq, round(coalesce(st.q, 0) * coalesce(ut.uc, 0), 2) cv,
        coalesce(fl.open_q, 0) open_q, coalesce(fl.open_v, 0) open_v, coalesce(fl.rec_q, 0) rec_q, coalesce(fl.rec_v, 0) rec_v,
        coalesce(fl.sold_q, 0) sold_q, coalesce(fl.cogs, 0) cogs, coalesce(fl.revenue, 0) revenue,
        coalesce(fl.tin_q, 0) tin_q, coalesce(fl.tin_v, 0) tin_v, coalesce(fl.tout_q, 0) tout_q, coalesce(fl.tout_v, 0) tout_v,
        coalesce(fl.adj_q, 0) adj_q, coalesce(fl.adj_v, 0) adj_v
      from items i left join sf on sf.item_id = i.id left join st on st.item_id = i.id left join fl on fl.item_id = i.id
        left join uf on uf.item_id = i.id left join ut on ut.item_id = i.id
      where i.org_id = p_org and (p_item is null or i.id = p_item)
        and (coalesce(sf.q, 0) <> 0 or coalesce(st.q, 0) <> 0 or fl.item_id is not null))
    select jsonb_agg(jsonb_build_object(
        'item', name, 'sku', sku, 'category', category, 'item_type', item_type, 'unit', selling_unit,
        'opening_qty', oq, 'opening_value', ov, 'added_qty', open_q, 'added_value', open_v,
        'received_qty', rec_q, 'received_value', rec_v, 'sold_qty', sold_q, 'cogs', cogs, 'revenue', revenue,
        'transfer_in_qty', tin_q, 'transfer_in_value', tin_v, 'transfer_out_qty', tout_q, 'transfer_out_value', tout_v,
        'adjust_qty', adj_q, 'adjust_value', adj_v,
        'cost_adjust', round(cv - (ov + open_v + rec_v - cogs + tin_v - tout_v + adj_v), 2),
        'closing_qty', cq, 'closing_value', cv)
      order by name)
    into v_rows from r;

  elsif p_report = 'stock_card' then
    with base as (
      select mv.*, sum(mv.qty) over (partition by mv.item_id, mv.location_id order by mv.recorded_at, mv.created_at, mv.id
                                     rows between unbounded preceding and current row) bal
      from movements mv
      where mv.org_id = p_org and (p_item is null or mv.item_id = p_item) and (p_location is null or mv.location_id = p_location)
        and mv.recorded_at < v_t),
    opening as (
      select item_id, location_id, sum(qty) q from base where recorded_at < v_f group by 1, 2),
    lines as (
      select i.name as item, i.sku, l.name as loc, v_from as dt, null::text as ref, 'Balance brought forward' as kind, null::text as doc,
        null::numeric as qin, null::numeric as qout, o.q as bal, null::numeric as uc, null::numeric as vin, null::numeric as vout,
        null::text as who, null::text as chan, null::text as note, '0' as srt, null::timestamptz as ts
      from opening o join items i on i.id = o.item_id join locations l on l.id = o.location_id
      where o.q <> 0 or exists (select 1 from base b where b.item_id = o.item_id and b.location_id = o.location_id and b.recorded_at >= v_f)
      union all
      select i.name, i.sku, l.name, (b.recorded_at at time zone v_tz)::date, j.ref,
        case b.type when 'opening' then 'Opening stock' when 'receipt' then 'Receipt' when 'sale' then 'Sale' when 'voice_sale' then 'Sale (voice)'
          when 'transfer_out' then 'Transfer out' when 'transfer_in' then 'Transfer in' when 'adjustment' then 'Count adjustment'
          when 'write_off' then 'Write-off' when 'quarantine' then 'Quarantine' else b.type end,
        coalesce((select rc.ref from receipts rc where rc.id = b.receipt_id), (select t.ref from transfers t where t.id = b.transfer_id),
          (select cs.ref from count_sessions cs where cs.id = b.count_session_id)),
        case when b.qty > 0 then b.qty end, case when b.qty < 0 then -b.qty end, b.bal,
        b.unit_cost, case when b.qty > 0 then b.value end, case when b.qty < 0 then -b.value end,
        (select mb.display_name from members mb where mb.id = b.author_id), b.channel, coalesce(b.reason, b.note), '1', b.recorded_at
      from base b join items i on i.id = b.item_id join locations l on l.id = b.location_id left join journals j on j.id = b.journal_id
      where b.recorded_at >= v_f)
    select jsonb_agg(jsonb_build_object('item', item, 'sku', sku, 'location', loc, 'date', dt, 'journal', ref, 'type', kind, 'document', doc,
        'qty_in', qin, 'qty_out', qout, 'balance', bal,
        'unit_cost', case when v_cost then round(uc, 4) end, 'value_in', case when v_cost then vin end, 'value_out', case when v_cost then vout end,
        'by', who, 'channel', chan, 'note', note) order by item, loc, srt, ts)
    into v_rows from (select * from lines order by item, loc, srt, ts limit v_cap) x;

  elsif p_report = 'gl' or p_report = 'trial_balance' then
    if p_accounts is null or cardinality(p_accounts) = 0 then
      if p_report = 'gl' then
        select array_agg(code order by code) into v_accts from accounts where code ~ v_inv_re or code = v_git;
      else
        select array_agg(distinct account_code) into v_accts from journal_lines where org_id = p_org;
      end if;
    elsif p_accounts = array['*'] then
      select array_agg(distinct account_code) into v_accts from journal_lines where org_id = p_org;
    else
      v_accts := p_accounts;
    end if;
    if p_report = 'gl' then
      with lines as (
        select jl.id, jl.account_code, jl.debit, jl.credit, jl.memo lmemo, jl.location_id, jl.item_id,
          j.entry_date, j.ref, j.je_no, j.memo, j.source_type
        from journal_lines jl join journals j on j.id = jl.journal_id
        where jl.org_id = p_org and jl.account_code = any(v_accts) and j.entry_date <= v_to
          and (p_location is null or jl.location_id = p_location)),
      ob as (select account_code, sum(debit - credit) b from lines where entry_date < v_from group by 1),
      per as (
        select l.*, coalesce(ob.b, 0) + sum(l.debit - l.credit) over (partition by l.account_code order by l.entry_date, l.je_no, l.id
                                                                       rows between unbounded preceding and current row) run
        from lines l left join ob on ob.account_code = l.account_code where l.entry_date >= v_from),
      allrows as (
        select a.code, a.name as aname, v_from as dt, null::text as ref, 'Opening balance' as memo, null::text as src, null::text as loc, null::text as item,
          null::numeric as dr, null::numeric as cr, coalesce(ob.b, 0) as bal, 0 as srt, 0 as je, 0::bigint as lid
        from accounts a left join ob on ob.account_code = a.code
        where a.code = any(v_accts) and (ob.b is not null or exists (select 1 from per where per.account_code = a.code))
        union all
        select p.account_code, a.name, p.entry_date, p.ref, coalesce(nullif(p.lmemo, ''), p.memo), p.source_type,
          (select name from locations where id = p.location_id), (select name from items where id = p.item_id),
          p.debit, p.credit, p.run, 1, p.je_no, p.id
        from per p join accounts a on a.code = p.account_code)
      select jsonb_agg(jsonb_build_object('account', code, 'account_name', aname, 'date', dt, 'journal', ref, 'memo', memo,
          'source', src, 'location', loc, 'item', item, 'debit', dr, 'credit', cr, 'balance', bal) order by code, srt, dt, je, lid)
      into v_rows from (select * from allrows order by code, srt, dt, je, lid limit v_cap) x;
    else
      with lines as (
        select jl.account_code, jl.debit, jl.credit, j.entry_date
        from journal_lines jl join journals j on j.id = jl.journal_id
        where jl.org_id = p_org and jl.account_code = any(v_accts) and j.entry_date <= v_to
          and (p_location is null or jl.location_id = p_location)),
      agg as (
        select account_code,
          coalesce(sum(debit - credit) filter (where entry_date < v_from), 0) ob,
          coalesce(sum(debit) filter (where entry_date >= v_from), 0) dr,
          coalesce(sum(credit) filter (where entry_date >= v_from), 0) cr
        from lines group by 1)
      select jsonb_agg(jsonb_build_object('account', a.code, 'account_name', a.name, 'kind', a.kind, 'normal_balance', a.normal_balance,
          'opening', g.ob, 'debit', g.dr, 'credit', g.cr, 'closing', g.ob + g.dr - g.cr,
          'closing_dr', case when g.ob + g.dr - g.cr > 0 then g.ob + g.dr - g.cr end,
          'closing_cr', case when g.ob + g.dr - g.cr < 0 then -(g.ob + g.dr - g.cr) end) order by a.code)
      into v_rows from agg g join accounts a on a.code = g.account_code
      where g.ob <> 0 or g.dr <> 0 or g.cr <> 0;
    end if;

  elsif p_report = 'journals' then
    select jsonb_agg(x order by (x->>'date'), (x->>'je_no')::int, (x->>'line')::bigint) into v_rows from (
      select jsonb_build_object('date', j.entry_date, 'journal', j.ref, 'je_no', j.je_no, 'memo', j.memo, 'source', j.source_type,
        'account', jl.account_code, 'account_name', a.name, 'debit', jl.debit, 'credit', jl.credit,
        'location', (select name from locations where id = jl.location_id), 'item', (select name from items where id = jl.item_id),
        'line_memo', jl.memo, 'posted_by', (select display_name from members where id = j.posted_by),
        'approved_by', (select display_name from members where id = j.approved_by), 'line', jl.id) x
      from journals j join journal_lines jl on jl.journal_id = j.id join accounts a on a.code = jl.account_code
      where j.org_id = p_org and j.entry_date between v_from and v_to and (p_location is null or jl.location_id = p_location)
      order by j.entry_date, j.je_no, jl.id
      limit v_cap) s;

  elsif p_report = 'purchases' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'invoice_date', r.invoice_date, 'ref', r.ref,
        'vendor', coalesce(v.name, r.vendor_name), 'invoice_no', r.invoice_no, 'location', l.name,
        'source', case r.source when 'pdf' then 'PDF invoice' when 'photo_typed' then 'Photo (typed)' when 'photo_handwritten' then 'Photo (handwritten)' else 'Manual' end,
        'lines', (select count(*) from receipt_lines rl where rl.receipt_id = r.id), 'net', r.net, 'vat', r.input_vat, 'gross', r.gross,
        'landed', (select coalesce(sum(total), 0) from landed_costs lc where lc.receipt_id = r.id), 'journal', j.ref,
        'posted_by', (select display_name from members where id = r.posted_by)) x
      from receipts r left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id left join journals j on j.id = r.journal_id
      where r.org_id = p_org and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'purchase_lines' then
    select jsonb_agg(x order by x->>'date', x->>'ref', (x->>'line')::int) into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'ref', r.ref, 'vendor', coalesce(v.name, r.vendor_name),
        'invoice_no', r.invoice_no, 'location', l.name, 'line', rl.line_no, 'item', coalesce(i.name, rl.new_item->>'name', rl.raw_text),
        'sku', i.sku, 'qty', rl.qty,
        'unit', coalesce(rl.unit_label, case when rl.unit_kind = 'purchase' then i.purchase_unit else i.selling_unit end),
        'unit_cost', rl.unit_cost, 'line_total', round(rl.qty * rl.unit_cost, 2),
        'vat_treatment', coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard'),
        'batch_no', rl.batch_no, 'expiry_date', rl.expiry_date) x
      from receipts r join receipt_lines rl on rl.receipt_id = r.id left join items i on i.id = rl.item_id
        left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id
      where r.org_id = p_org and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location) and (p_item is null or rl.item_id = p_item)
      limit v_cap) s;

  elsif p_report = 'input_vat' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'invoice_date', r.invoice_date, 'ref', r.ref,
        'vendor', coalesce(v.name, r.vendor_name), 'invoice_no', r.invoice_no, 'location', l.name,
        'taxable', (select coalesce(sum(round(rl.qty * rl.unit_cost, 2)), 0) from receipt_lines rl left join items i on i.id = rl.item_id
                    where rl.receipt_id = r.id and coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard') = 'standard'),
        'non_taxable', (select coalesce(sum(round(rl.qty * rl.unit_cost, 2)), 0) from receipt_lines rl left join items i on i.id = rl.item_id
                    where rl.receipt_id = r.id and coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard') <> 'standard'),
        'vat', r.input_vat, 'gross', r.gross, 'journal', j.ref) x
      from receipts r left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id left join journals j on j.id = r.journal_id
      where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'vendors' then
    select jsonb_agg(x order by (x->>'gross')::numeric desc) into v_rows from (
      select jsonb_build_object('vendor', v.name, 'vat_registered', v.vat_registered, 'receipts', count(r.id),
        'net', coalesce(sum(r.net), 0), 'vat', coalesce(sum(r.input_vat), 0), 'gross', coalesce(sum(r.gross), 0),
        'items', (select count(distinct rl.item_id) from receipt_lines rl join receipts r2 on r2.id = rl.receipt_id
                  where r2.vendor_id = v.id and r2.status = 'posted' and r2.posted_at >= v_f and r2.posted_at < v_t),
        'last_receipt', max((r.posted_at at time zone v_tz)::date), 'lead_time_days', v.lead_time_days, 'credit_days', v.credit_days,
        'phone', v.phone, 'email', v.email) x
      from vendors v join receipts r on r.vendor_id = v.id and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      where v.org_id = p_org
      group by v.id) s;

  elsif p_report = 'purchase_orders' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (po.created_at at time zone v_tz)::date, 'ref', po.ref, 'vendor', v.name, 'location', l.name,
        'status', initcap(po.status), 'sent_via', po.sent_via, 'sent', (po.sent_at at time zone v_tz)::date,
        'received', (po.received_at at time zone v_tz)::date,
        'lines', (select string_agg(trim(to_char(pl.qty, 'FM999,999,990.###')) || ' ' || i.purchase_unit || ' ' || i.name, '; ')
                  from po_lines pl join items i on i.id = pl.item_id where pl.po_id = po.id),
        'total', po.total, 'created_by', (select display_name from members where id = po.created_by)) x
      from purchase_orders po left join vendors v on v.id = po.vendor_id left join locations l on l.id = po.location_id
      where po.org_id = p_org and po.created_at >= v_f and po.created_at < v_t and (p_location is null or po.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'sales_by_item' then
    select jsonb_agg(x order by (x->>'revenue')::numeric desc) into v_rows from (
      select jsonb_build_object('item', i.name, 'sku', i.sku, 'category', i.category, 'unit', i.selling_unit,
        'sales', count(*), 'qty', sum(-mv.qty), 'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'avg_price', round(sum(-mv.qty * coalesce(mv.unit_price, 0)) / nullif(sum(-mv.qty), 0), 2),
        'cogs', case when v_cost then round(sum(-mv.value), 2) end,
        'gross_profit', case when v_cost then round(sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value), 2) end,
        'margin_pct', case when v_cost and sum(-mv.qty * coalesce(mv.unit_price, 0)) > 0 then
          round((sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value)) / sum(-mv.qty * coalesce(mv.unit_price, 0)) * 100, 1) end) x
      from movements mv join items i on i.id = mv.item_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by i.id) s;

  elsif p_report = 'sales_by_day' then
    select jsonb_agg(x order by x->>'date', x->>'location') into v_rows from (
      select jsonb_build_object('date', (mv.recorded_at at time zone v_tz)::date, 'location', l.name, 'sales', count(*),
        'voice', count(*) filter (where mv.type = 'voice_sale'), 'qty', sum(-mv.qty),
        'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'cogs', case when v_cost then round(sum(-mv.value), 2) end,
        'gross_profit', case when v_cost then round(sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value), 2) end) x
      from movements mv join locations l on l.id = mv.location_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by (mv.recorded_at at time zone v_tz)::date, l.name) s;

  elsif p_report = 'sales_by_staff' then
    select jsonb_agg(x order by (x->>'revenue')::numeric desc) into v_rows from (
      select jsonb_build_object('person', coalesce(mb.display_name, 'Unknown'), 'role', initcap(mb.role), 'sales', count(*),
        'voice', count(*) filter (where mv.type = 'voice_sale'), 'offline', count(*) filter (where mv.offline),
        'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'first', min((mv.recorded_at at time zone v_tz)::date), 'last', max((mv.recorded_at at time zone v_tz)::date)) x
      from movements mv left join members mb on mb.id = mv.author_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by mb.id, mb.display_name, mb.role) s;

  elsif p_report = 'adjustments' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('date', (mv.recorded_at at time zone v_tz)::date, 'journal', j.ref,
        'count', (select cs.ref from count_sessions cs where cs.id = mv.count_session_id), 'type', initcap(replace(mv.type, '_', ' ')),
        'item', i.name, 'sku', i.sku, 'location', l.name, 'qty', mv.qty, 'unit', i.selling_unit,
        'value', case when v_cost then mv.value end, 'reason', mv.reason, 'note', mv.note,
        'by', (select display_name from members where id = mv.author_id), 'approved_by', (select display_name from members where id = mv.approver_id)) x
      from movements mv join items i on i.id = mv.item_id join locations l on l.id = mv.location_id left join journals j on j.id = mv.journal_id
      where mv.org_id = p_org and mv.type in ('adjustment', 'write_off', 'quarantine') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      order by mv.recorded_at
      limit v_cap) s;

  elsif p_report = 'transfers' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (t.created_at at time zone v_tz)::date, 'ref', t.ref, 'item', i.name, 'sku', i.sku,
        'qty', t.qty, 'unit', i.selling_unit, 'from', lf.name, 'to', lt.name,
        'status', case t.status when 'in_transit' then 'In transit' else 'Received' end,
        'received', (t.received_at at time zone v_tz)::date, 'value', case when v_cost then round(t.qty * t.unit_cost, 2) end,
        'sent_by', (select display_name from members where id = t.created_by), 'received_by', (select display_name from members where id = t.received_by)) x
      from transfers t join items i on i.id = t.item_id join locations lf on lf.id = t.from_location_id join locations lt on lt.id = t.to_location_id
      where t.org_id = p_org and t.created_at >= v_f and t.created_at < v_t
        and (p_location is null or t.from_location_id = p_location or t.to_location_id = p_location) and (p_item is null or t.item_id = p_item)
      limit v_cap) s;

  elsif p_report = 'price_changes' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('date', (pc.created_at at time zone v_tz)::date, 'item', i.name, 'sku', i.sku,
        'old_price', pc.old_price, 'new_price', pc.new_price,
        'change_pct', case when pc.old_price > 0 then round((pc.new_price - pc.old_price) / pc.old_price * 100, 1) end,
        'reason', pc.reason, 'by', (select display_name from members where id = pc.changed_by)) x
      from price_changes pc join items i on i.id = pc.item_id
      where pc.org_id = p_org and pc.created_at >= v_f and pc.created_at < v_t and (p_item is null or pc.item_id = p_item)
      order by pc.created_at
      limit v_cap) s;

  elsif p_report = 'cash_vs_stock' then
    with implied as (
      select (mv.recorded_at at time zone v_tz)::date d, mv.location_id, round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2) amt
      from movements mv
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
      group by 1, 2),
    days as (
      select d, location_id from implied
      union select ct.day, ct.location_id from cash_takings ct where ct.org_id = p_org and ct.day between v_from and v_to)
    select jsonb_agg(jsonb_build_object('date', ds.d, 'location', l.name, 'implied', coalesce(im.amt, 0),
        'cash', ct.cash, 'pos', ct.pos, 'transfers', ct.transfers,
        'recorded', case when ct.id is not null then ct.cash + ct.pos + ct.transfers end,
        'gap', case when ct.id is not null then coalesce(im.amt, 0) - (ct.cash + ct.pos + ct.transfers) end) order by ds.d, l.name)
    into v_rows
    from days ds join locations l on l.id = ds.location_id
      left join implied im on im.d = ds.d and im.location_id = ds.location_id
      left join cash_takings ct on ct.org_id = p_org and ct.day = ds.d and ct.location_id = ds.location_id
    where p_location is null or ds.location_id = p_location;

  elsif p_report = 'batches' then
    select jsonb_agg(x order by x->>'expiry_date' nulls last) into v_rows from (
      select jsonb_build_object('item', i.name, 'sku', i.sku, 'nafdac_no', i.nafdac_no, 'batch_no', b.batch_no, 'location', l.name,
        'expiry_date', b.expiry_date, 'days_left', b.expiry_date - v_today, 'qty_received', b.qty_received, 'qty_remaining', b.qty_remaining,
        'unit', i.selling_unit, 'value', case when v_cost then round(b.qty_remaining * coalesce(c.wac, 0), 2) end,
        'status', case when b.quarantined then 'Quarantined' when b.expiry_date is null then 'No expiry'
          when b.expiry_date < v_today then 'Expired' when b.expiry_date - v_today <= 30 then 'Expiring'
          when b.expiry_date - v_today <= 90 then 'Watch' else 'OK' end) x
      from batches b join items i on i.id = b.item_id join locations l on l.id = b.location_id left join item_costs c on c.item_id = b.item_id
      where b.org_id = p_org and (b.qty_remaining > 0 or b.quarantined)
        and (p_location is null or b.location_id = p_location) and (p_item is null or b.item_id = p_item)
      limit v_cap) s;

  else
    raise exception 'Unknown report %.', p_report;
  end if;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'extra', v_extra, 'from', v_from, 'to', v_to,
    'truncated', jsonb_array_length(coalesce(v_rows, '[]'::jsonb)) >= v_cap, 'can_see_costs', v_cost);
end $$;

-- The inventory payload carries the new item fields.
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
        'item_type', i.item_type, 'brand', i.brand, 'description', i.description, 'attributes', i.attributes,
        'inventory_account', i.inventory_account,
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

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prokind = 'f'
      and p.proname in ('sells', 'type_account', 'num', 'date_or_null', 'clean_attrs', 'move_item_account',
        'import_inventory', 'inventory_report', 'upsert_item', 'get_inventory')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
