-- Counta — sample business (Kelandellen Company Limited, Surulere + Yaba)
-- Builds a separate, clearly-marked sample business for the signed-in user, with
-- ~130 days of history generated relative to today. Every number in it is posted
-- through the same journal engine the real app uses.

create or replace function private.seed_receipt(
  p_org uuid, p_vendor uuid, p_loc uuid, p_source text, p_invoice text, p_vat boolean,
  p_lines jsonb, p_author uuid, p_at timestamptz, p_post boolean, p_doc text default null
) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; x jsonb; v_n int := 0; v_vendor text;
begin
  select name into v_vendor from vendors where id = p_vendor;
  insert into receipts (org_id, ref, vendor_id, vendor_name, location_id, source, invoice_no, invoice_date, vendor_vat_registered,
    status, created_by, created_at, document_path, ai_model)
  values (p_org, 'DR-' || lpad(private.next_no(p_org, 'DR', 201)::text, 4, '0'), p_vendor, v_vendor, p_loc, p_source, p_invoice,
    private.local_day(p_org, p_at), p_vat, 'needs_review', p_author, p_at, p_doc,
    case when p_source <> 'manual' then 'sample' end)
  returning id into v_id;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    insert into receipt_lines (receipt_id, org_id, line_no, raw_text, item_id, qty, unit_kind, unit_label, unit_cost, confidence,
      alt_reading, confirmed, model_reading)
    values (v_id, p_org, v_n, x->>'raw', (x->>'item_id')::uuid, (x->>'qty')::numeric, coalesce(x->>'kind', 'purchase'),
      x->>'unit', (x->>'cost')::numeric, coalesce((x->>'conf')::int, 98), x->'alt', coalesce((x->>'ok')::boolean, true),
      jsonb_build_object('qty', (x->>'qty')::numeric, 'unit_cost', (x->>'cost')::numeric));
  end loop;
  if p_post then perform private.post_receipt_internal(v_id, p_author, p_at); end if;
  return v_id;
end $$;

create or replace function private.seed_items(p jsonb)
returns table (k text, id uuid, name text, cat text, barcode text, pu text, pack int, su text, cost numeric, price numeric,
  sur numeric, yab numeric, floor numeric, vel numeric, vendor uuid, alt uuid, vat text, informal boolean, nafdac text,
  imp boolean, uplift numeric, share numeric)
language sql immutable as $$
  select * from jsonb_to_recordset(p) as x(k text, id uuid, name text, cat text, barcode text, pu text, pack int, su text,
    cost numeric, price numeric, sur numeric, yab numeric, floor numeric, vel numeric, vendor uuid, alt uuid, vat text,
    informal boolean, nafdac text, imp boolean, uplift numeric, share numeric)
$$;

-- Deterministic daily sales for one item at one branch.
create or replace function private.seed_qty(p_k text, p_vel numeric, p_share numeric, p_uplift numeric, p_day date, p_code text, p_today date)
returns numeric
language sql immutable as $$
  select case when p_vel < 1 then 0 else greatest(0, round(p_vel
    * case when p_code = 'SUR' then p_share else 1 - p_share end
    * case extract(isodow from p_day) when 6 then 1.25 when 7 then 0.78 when 5 then 1.08 else 0.97 end
    * case when p_day > p_today - 30 then 1 else 1 / (1 + p_uplift) end
    * (0.86 + (abs(hashtext(p_k || p_day::text || p_code)::bigint) % 280) / 1000.0))) end
$$;

create or replace function public.create_sample_business() returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := auth.uid(); v_org uuid; v_owner uuid; v_sur uuid; v_yab uuid;
  v_musa uuid; v_blessing uuid; v_tunde uuid; v_name text; v_tz text := 'Africa/Lagos'; v_today date;
  v_dufil uuid; v_chidi uuid; v_ojodu uuid; v_ebuka uuid; v_nbc uuid; v_nkechi uuid;
  r record; d int; v_day date; v_at timestamptz; j public.journals; v_lines jsonb; v_total numeric;
  v_cs uuid; v_tr uuid; v_id uuid; v_loc uuid; v_code text; v_ref text; v_val numeric; v_qty numeric;
  v_raw jsonb; v_si jsonb := '[]'::jsonb; v_ids jsonb := '{}'::jsonb; v_open jsonb;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  select o.id into v_org from orgs o join members m on m.org_id = o.id
  where o.is_sample and m.user_id = v_uid and m.status = 'active' limit 1;
  if v_org is not null then return v_org; end if;

  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), initcap(split_part(email, '@', 1))) into v_name
  from auth.users where id = v_uid;
  v_org := public.create_org('Kelandellen Company Limited', 'kelandellen@outlook.com', '+234 803 555 0142', v_name,
    '[{"name":"Surulere","code":"SUR","address":"14 Adeniran Ogunsanya St · main"},{"name":"Yaba","code":"YAB","address":"23 Herbert Macaulay Way"}]'::jsonb,
    true, true);
  update orgs set cash_available = 1840000 where id = v_org;
  v_today := (now() at time zone v_tz)::date;
  select id into v_owner from members where org_id = v_org and user_id = v_uid;
  select id into v_sur from locations where org_id = v_org and code = 'SUR';
  select id into v_yab from locations where org_id = v_org and code = 'YAB';

  -- Team without logins (sample staff)
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Musa Ibrahim', 'manager', 'Branch manager', v_yab, 'active', '+2348035550101', true, true, true, false, false, false, true, true)
  returning id into v_musa;
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Blessing Okafor', 'staff', 'Store assistant', v_sur, 'active', '+2348035550102', true, true, true, false, false, false, false, false)
  returning id into v_blessing;
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Tunde Adeyemi', 'cashier', 'Cashier', v_sur, 'active', '+2348035550103', true, false, false, false, false, false, false, false)
  returning id into v_tunde;

  -- Vendors
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Dufil Prima Foods', 'Ota depot', 'email', '+2348035550201', 'orders.dufil@example.com', true, 2, 14, 98, 'High', 'Direct from manufacturer')
  returning id into v_dufil;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Chidi & Sons Distribution', 'Trade Fair, Lagos', 'whatsapp', '+2348035550202', null, true, 1, 7, 94, 'Medium', null)
  returning id into v_chidi;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Ojodu Foods (Nestlé)', 'Ojodu Berger', 'whatsapp', '+2348035550203', null, true, 3, 0, 88, 'High', null)
  returning id into v_ojodu;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Ebuka Stores', 'Onitsha Main Market', 'whatsapp', '+2348035550204', null, false, 4, 30, 100, 'Low', null)
  returning id into v_ebuka;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'NBC Depot Ijora', 'Ijora, Lagos', 'email', '+2348035550205', 'ijora.depot@example.com', true, 1, 7, 97, 'High', 'Bottler depot')
  returning id into v_nbc;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Mama Nkechi Stores', 'Idumota market', 'whatsapp', '+2348035550206', null, false, 0, 0, 100, 'Low', 'Same-day cash purchases')
  returning id into v_nkechi;

  -- Item master; sur/yab are today's on-hand per branch, vel is units/day across both.
  v_raw := jsonb_build_array(
    jsonb_build_object('k','indomie','name','Indomie Chicken 70g','cat','Noodles','barcode','6156000012345','pu','Carton','pack',40,'su','pack','cost',265,'price',300,'sur',4440,'yab',960,'floor',1200,'vel',310,'vendor',v_dufil,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0.18),
    jsonb_build_object('k','peak','name','Peak Evaporated Milk 160g','cat','Dairy','barcode','8716200321234','pu','Carton','pack',48,'su','tin','cost',505,'price',550,'sur',384,'yab',144,'floor',480,'vel',62,'vendor',v_chidi,'alt',v_ojodu,'vat','standard','informal',false,'imp',true,'uplift',0),
    jsonb_build_object('k','milo','name','Milo Activ-Go 400g','cat','Beverages','barcode','7613036123457','pu','Carton','pack',12,'su','tin','cost',2650,'price',2950,'sur',72,'yab',36,'floor',48,'vel',9,'vendor',v_ojodu,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0.12),
    jsonb_build_object('k','semo','name','Golden Penny Semovita 1kg','cat','Staples','barcode','6151100021116','pu','Bag','pack',10,'su','pack','cost',1480,'price',1650,'sur',210,'yab',80,'floor',100,'vel',18,'vendor',v_chidi,'vat','zero','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','rice','name','Mama''s Pride Rice 50kg','cat','Staples','pu','Bag','pack',52,'su','derica','cost',1750,'price',2000,'sur',416,'yab',0,'floor',208,'vel',35,'vendor',v_ebuka,'alt',v_chidi,'vat','zero','informal',true,'imp',false,'uplift',0),
    jsonb_build_object('k','sugar','name','Dangote Sugar 1kg','cat','Staples','barcode','6154000011220','pu','Bale','pack',20,'su','pack','cost',1380,'price',1500,'sur',140,'yab',60,'floor',120,'vel',14,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','coke','name','Coca-Cola 50cl PET','cat','Drinks','barcode','5449000000996','pu','Pack','pack',12,'su','bottle','cost',245,'price',300,'sur',600,'yab',276,'floor',360,'vel',85,'vendor',v_nbc,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','eva','name','Eva Water 75cl','cat','Drinks','barcode','6156000234567','pu','Pack','pack',12,'su','bottle','cost',180,'price',250,'sur',216,'yab',120,'floor',360,'vel',70,'vendor',v_nbc,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','dettol','name','Dettol Soap 110g','cat','Personal care','barcode','6001106110086','pu','Carton','pack',72,'su','bar','cost',520,'price',600,'sur',288,'yab',144,'floor',144,'vel',11,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','omo','name','OMO Detergent 900g','cat','Household','barcode','6001087357623','pu','Bag','pack',12,'su','sachet','cost',1900,'price',2200,'sur',48,'yab',24,'floor',36,'vel',4,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','goldenmorn','name','Golden Morn 1kg','cat','Breakfast','barcode','7613035012349','pu','Carton','pack',10,'su','pack','cost',3400,'price',3600,'sur',60,'yab',20,'floor',30,'vel',2.5,'vendor',v_ojodu,'vat','standard','informal',false,'imp',true,'uplift',0.15),
    jsonb_build_object('k','kingsoil','name','Kings Vegetable Oil 3L','cat','Staples','barcode','6156000345678','pu','Carton','pack',6,'su','bottle','cost',7400,'price',7900,'sur',36,'yab',12,'floor',24,'vel',3,'vendor',v_chidi,'vat','zero','informal',false,'imp',true,'uplift',0),
    jsonb_build_object('k','panadol','name','Panadol Extra (24 tabs)','cat','OTC medicine','barcode','5000347012345','pu','Carton','pack',100,'su','pack','cost',900,'price',1100,'sur',100,'yab',60,'floor',60,'vel',5,'vendor',v_ojodu,'vat','exempt','informal',false,'nafdac','A4-0271','imp',false,'uplift',0),
    jsonb_build_object('k','harpic','name','Harpic Toilet Cleaner 500ml','cat','Household','barcode','8901396350019','pu','Carton','pack',12,'su','bottle','cost',1650,'price',1900,'sur',84,'yab',0,'floor',24,'vel',0,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','ovaltine','name','Ovaltine 400g','cat','Beverages','barcode','7612100055366','pu','Carton','pack',12,'su','tin','cost',2400,'price',2700,'sur',60,'yab',0,'floor',24,'vel',0,'vendor',v_ojodu,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','closeup','name','Close-Up Red Hot 140g','cat','Personal care','barcode','6001087378024','pu','Carton','pack',72,'su','tube','cost',780,'price',900,'sur',216,'yab',72,'floor',144,'vel',12,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0));

  for r in select * from private.seed_items(v_raw) loop
    insert into items (org_id, name, barcode, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit, informal_unit,
      track_batches, reorder_floor, preferred_vendor_id, alt_vendor_id, price, import_priced, created_by, created_at)
    values (v_org, r.name, r.barcode, r.cat, r.vat, r.nafdac, r.pu, r.pack, r.su, coalesce(r.informal, false), false, r.floor, r.vendor, r.alt,
      r.price, coalesce(r.imp, false), v_owner, now() - interval '140 days')
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, v_org, r.cost, r.cost);
    v_ids := v_ids || jsonb_build_object(r.k, v_id);
    v_si := v_si || jsonb_build_array(to_jsonb(r) || jsonb_build_object('id', v_id,
      'share', case when r.yab = 0 then 1 else least(0.85, greatest(0.55, r.sur / (r.sur + r.yab))) end));
  end loop;

  -- Back-solve opening balances: today's stock, minus planned receipts/transfers/adjustments, plus 60 days of sales.
  with pe(k, code, qty) as (values
    ('indomie', 'SUR', 2400), ('indomie', 'SUR', 200), ('peak', 'SUR', 96), ('sugar', 'SUR', 10), ('closeup', 'SUR', 216), ('eva', 'SUR', 120),
    ('coke', 'SUR', 240), ('eva', 'SUR', 480),
    ('peak', 'SUR', 480), ('semo', 'SUR', 100), ('sugar', 'SUR', 80), ('dettol', 'SUR', 144), ('kingsoil', 'SUR', 24),
    ('indomie', 'SUR', -400), ('indomie', 'YAB', 400), ('peak', 'SUR', -192), ('peak', 'YAB', 192),
    ('coke', 'YAB', -6), ('eva', 'YAB', -4), ('indomie', 'YAB', -120),
    ('harpic', 'SUR', -6), ('ovaltine', 'SUR', -4))
  select jsonb_object_agg(s.k || '|' || c.code,
      (case when c.code = 'SUR' then s.sur else s.yab end)
      - coalesce((select sum(pe.qty) from pe where pe.k = s.k and pe.code = c.code), 0)
      + coalesce((select sum(private.seed_qty(s.k, s.vel, s.share, s.uplift, g.day::date, c.code, v_today))
                  from generate_series(v_today - 60, v_today - 1, interval '1 day') g(day)), 0))
  into v_open
  from private.seed_items(v_si) s cross join (values ('SUR'), ('YAB')) c(code);

  for v_code in select unnest(array['SUR', 'YAB']) loop
    v_loc := case when v_code = 'SUR' then v_sur else v_yab end;
    v_at := ((v_today - 130) + time '08:00') at time zone v_tz;
    select coalesce(sum(round((v_open->>(s.k || '|' || v_code))::numeric * s.cost, 2)), 0) into v_total
    from private.seed_items(v_si) s where (v_open->>(s.k || '|' || v_code))::numeric > 0;
    j := private.post_journal(v_org, 'Opening stock · ' || case when v_code = 'SUR' then 'Surulere' else 'Yaba' end || ' · stock_list_jun.xlsx',
      'opening', null, v_owner, null,
      jsonb_build_array(jsonb_build_object('code', '1310', 'debit', v_total, 'location_id', v_loc),
                        jsonb_build_object('code', '3100', 'credit', v_total, 'location_id', v_loc)), v_at);
    for r in select * from private.seed_items(v_si) s where (v_open->>(s.k || '|' || v_code))::numeric > 0 loop
      perform private.add_movement(v_org, 'opening', r.id, v_loc, (v_open->>(r.k || '|' || v_code))::numeric,
        r.cost, null, j.id, v_owner, 'Import', v_at, '{"note":"stock_list_jun.xlsx"}'::jsonb);
    end loop;
  end loop;

  -- The last sales of what is now dead stock
  perform private.sale_internal(v_org, (v_ids->>'harpic')::uuid, v_sur, 6, null, v_tunde, 'Invoicing rail', 'sale',
    ((v_today - 118) + time '17:40') at time zone v_tz, '{}'::jsonb);
  perform private.sale_internal(v_org, (v_ids->>'ovaltine')::uuid, v_sur, 4, null, v_tunde, 'Invoicing rail', 'sale',
    ((v_today - 96) + time '12:15') at time zone v_tz, '{}'::jsonb);

  -- Walk forward day by day
  for d in reverse 60..0 loop
    v_day := v_today - d;

    if d = 16 then
      insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, approved_by, approved_at, device_id, offline, created_at)
      values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_sur, 'Aisle 1 · Staples', v_blessing, 'approved', v_owner,
        (v_day + time '18:05') at time zone v_tz, v_owner, (v_day + time '21:00') at time zone v_tz, 'Itel A70 · Blessing', true,
        (v_day + time '09:00') at time zone v_tz)
      returning id into v_cs;
      insert into count_lines (session_id, org_id, item_id, expected, counted)
      select v_cs, v_org, s.id, coalesce(sl.qty, 0), coalesce(sl.qty, 0)
      from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_sur where s.cat = 'Staples';
    end if;

    if d = 13 then
      perform private.seed_receipt(v_org, v_chidi, v_sur, 'photo_typed', 'CSD/24/1187', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'peak', 'raw', 'PEAK EVAP MILK 160G x48 — 10 CTN', 'qty', 10, 'unit', 'ctn', 'cost', 24240),
        jsonb_build_object('item_id', v_ids->>'semo', 'raw', 'G/PENNY SEMOVITA 1KG x10 — 10 BAG', 'qty', 10, 'unit', 'bag', 'cost', 14800),
        jsonb_build_object('item_id', v_ids->>'sugar', 'raw', 'DANGOTE SUGAR 1KG x20 — 4 BALE', 'qty', 4, 'unit', 'bale', 'cost', 27600),
        jsonb_build_object('item_id', v_ids->>'dettol', 'raw', 'DETTOL SOAP 110G x72 — 2 CTN', 'qty', 2, 'unit', 'ctn', 'cost', 37440),
        jsonb_build_object('item_id', v_ids->>'kingsoil', 'raw', 'KINGS VEG OIL 3L x6 — 4 CTN', 'qty', 4, 'unit', 'ctn', 'cost', 44400)),
        v_blessing, (v_day + time '10:20') at time zone v_tz, true);
    end if;

    if d = 9 then
      insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, device_id, offline, created_at)
      values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_yab, 'Whole store', v_musa, 'awaiting_approval', v_owner,
        (v_day + time '19:10') at time zone v_tz, 'Tecno Spark 10 · Musa', false, (v_day + time '08:30') at time zone v_tz)
      returning id into v_cs;
      insert into count_lines (session_id, org_id, item_id, expected, counted, reason)
      select v_cs, v_org, s.id, coalesce(sl.qty, 0),
        coalesce(sl.qty, 0) + case s.k when 'coke' then -6 when 'eva' then -4 else 0 end,
        case s.k when 'coke' then 'Breakage' when 'eva' then 'Unrecorded sale' end
      from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_yab
      where coalesce(sl.qty, 0) > 0 or s.k in ('coke', 'eva');
      perform private.approve_count_internal(v_cs, v_owner, (v_day + time '21:15') at time zone v_tz);
    end if;

    if d = 8 then
      perform private.seed_receipt(v_org, v_ebuka, v_sur, 'photo_handwritten', null, false, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'rice', 'raw', '2 bag Mama Pride rice', 'qty', 2, 'unit', 'bag', 'cost', 91000, 'conf', 93),
        jsonb_build_object('item_id', v_ids->>'semo', 'raw', '1 bag semo', 'qty', 1, 'unit', 'bag', 'cost', 14800, 'conf', 61,
          'ok', false, 'alt', jsonb_build_object('label', '11 bags', 'qty', 11))),
        v_blessing, (v_day + time '16:05') at time zone v_tz, false);
    end if;

    if d = 7 then
      perform private.seed_receipt(v_org, v_nbc, v_sur, 'pdf', 'NBC-IJR-55120', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'coke', 'raw', 'COKE 50CL PET x12 — 20 PK', 'qty', 20, 'unit', 'pk', 'cost', 2940),
        jsonb_build_object('item_id', v_ids->>'eva', 'raw', 'EVA WATER 75CL x12 — 40 PK', 'qty', 40, 'unit', 'pk', 'cost', 2160)),
        v_owner, (v_day + time '11:00') at time zone v_tz, true);
    end if;

    if d in (6, 1) then
      v_id := (v_ids->>(case when d = 6 then 'indomie' else 'peak' end))::uuid;
      v_qty := case when d = 6 then 400 else 192 end;
      v_at := (v_day + case when d = 6 then time '12:00' else time '15:40' end) at time zone v_tz;
      v_val := round(v_qty * (select wac from item_costs where item_id = v_id), 2);
      v_ref := 'TR-' || lpad(private.next_no(v_org, 'TR', 6)::text, 4, '0');
      insert into transfers (org_id, ref, item_id, qty, unit_cost, from_location_id, to_location_id, created_by, created_at)
      values (v_org, v_ref, v_id, v_qty, (select wac from item_costs where item_id = v_id), v_sur, v_yab, v_owner, v_at)
      returning id into v_tr;
      j := private.post_journal(v_org, 'Transfer ' || v_ref || ' · Surulere → Yaba', 'transfer', v_tr, v_owner, null,
        jsonb_build_array(jsonb_build_object('code', '1315', 'debit', v_val, 'item_id', v_id),
                          jsonb_build_object('code', '1310', 'credit', v_val, 'location_id', v_sur, 'item_id', v_id)), v_at);
      perform private.add_movement(v_org, 'transfer_out', v_id, v_sur, -v_qty, (select wac from item_costs where item_id = v_id),
        null, j.id, v_owner, 'App', v_at, jsonb_build_object('transfer_id', v_tr, 'note', 'Surulere → Yaba'));
      perform private.receive_transfer_internal(v_tr, v_musa, v_at + interval '90 minutes');
    end if;

    if d = 4 then
      perform private.sale_internal(v_org, (v_ids->>'indomie')::uuid, v_yab, 120, null, v_musa, 'Voice (Pidgin)', 'voice_sale',
        (v_day + time '09:30') at time zone v_tz,
        jsonb_build_object('note', '"I don sell three cartons of Indomie"', 'review_status', 'reviewed', 'device_id', 'Tecno Spark 10 · Musa'));
    end if;

    if d = 3 then
      perform private.seed_receipt(v_org, v_nkechi, v_sur, 'photo_handwritten', null, false, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'indomie', 'raw', '5 ctn Indomie chikin', 'qty', 5, 'unit', 'ctn', 'cost', 10600, 'conf', 97),
        jsonb_build_object('item_id', v_ids->>'peak', 'raw', '2 ctn Peak milk', 'qty', 2, 'unit', 'ctn', 'cost', 25200, 'conf', 91),
        jsonb_build_object('item_id', v_ids->>'sugar', 'raw', 'half bag Dangote sugar', 'qty', 10, 'kind', 'selling', 'unit', 'pack', 'cost', 1380, 'conf', 58,
          'alt', jsonb_build_object('label', '1 bag (20 packs)', 'qty', 20)),
        jsonb_build_object('item_id', v_ids->>'closeup', 'raw', '3 ctn Close Up 140g', 'qty', 3, 'unit', 'ctn', 'cost', 56160, 'conf', 88),
        jsonb_build_object('item_id', v_ids->>'eva', 'raw', '10 pk Eva water', 'qty', 10, 'unit', 'pk', 'cost', 2160, 'conf', 44,
          'alt', jsonb_build_object('label', '16 packs', 'qty', 16))),
        v_blessing, (v_day + time '13:48') at time zone v_tz, true);
    end if;

    if d = 0 then
      perform private.seed_receipt(v_org, v_dufil, v_sur, 'pdf', 'INV-88231', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'indomie', 'raw', 'Indomie Chicken 70g × 40 — 60 CTN', 'qty', 60, 'unit', 'ctn', 'cost', 10600, 'conf', 99)),
        v_owner, least(now() - interval '5 minutes', (v_day + time '09:12') at time zone v_tz), true);
    end if;

    -- Day close at each branch (Saturdays at Surulere are split across two cashiers)
    if d >= 1 then
      v_at := (v_day + time '20:05') at time zone v_tz;
      for v_code in select unnest(array['SUR', 'YAB']) loop
        v_loc := case when v_code = 'SUR' then v_sur else v_yab end;
        if v_code = 'SUR' and extract(isodow from v_day) = 6 then
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0 and abs(hashtext(s.k)::bigint) % 2 = 0;
          if jsonb_array_length(v_lines) > 0 then perform private.post_day_close(v_org, v_loc, v_tunde, v_lines, v_at); end if;
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0 and abs(hashtext(s.k)::bigint) % 2 = 1;
          if jsonb_array_length(v_lines) > 0 then perform private.post_day_close(v_org, v_loc, v_blessing, v_lines, v_at + interval '2 minutes'); end if;
        else
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0;
          if jsonb_array_length(v_lines) > 0 then
            perform private.post_day_close(v_org, v_loc, case when v_code = 'SUR' then v_tunde else v_musa end, v_lines,
              v_at + case when v_code = 'SUR' then interval '0 minutes' else interval '4 minutes' end);
          end if;
        end if;
      end loop;
    end if;
  end loop;

  -- Batch tracking for regulated / perishable lines, matching today's stock
  update items set track_batches = true where id in ((v_ids->>'peak')::uuid, (v_ids->>'panadol')::uuid, (v_ids->>'goldenmorn')::uuid);
  insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, created_at) values
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK24020', v_today - 16, 240, 24, now() - interval '120 days'),
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK24091', v_today + 17, 480, 144, now() - interval '40 days'),
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK25033', v_today + 150, 480, 216, now() - interval '13 days'),
    (v_org, (v_ids->>'peak')::uuid, v_yab, 'PK25033', v_today + 150, 192, 144, now() - interval '1 day'),
    (v_org, (v_ids->>'panadol')::uuid, v_sur, 'PE7731', v_today + 12, 100, 40, now() - interval '100 days'),
    (v_org, (v_ids->>'panadol')::uuid, v_sur, 'PE8104', v_today + 472, 100, 60, now() - interval '60 days'),
    (v_org, (v_ids->>'panadol')::uuid, v_yab, 'PE8104', v_today + 472, 60, 60, now() - interval '60 days'),
    (v_org, (v_ids->>'goldenmorn')::uuid, v_sur, 'GM26C', v_today + 65, 100, 60, now() - interval '50 days'),
    (v_org, (v_ids->>'goldenmorn')::uuid, v_yab, 'GM26C', v_today + 65, 30, 20, now() - interval '50 days');

  -- A fresh supplier quote that sits above the current shelf price
  update item_costs set replacement_cost = 8200, replacement_source = 'Chidi quote · ' || to_char(v_today - 1, 'DD Mon')
  where item_id = (v_ids->>'kingsoil')::uuid;

  -- Count waiting for the owner: Aisle 3 at Surulere
  insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, device_id, offline, created_at)
  values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_sur, 'Aisle 3 · Drinks & dairy', v_blessing, 'awaiting_approval',
    v_owner, ((v_today - 2) + time '17:22') at time zone v_tz, 'Itel A70 · Blessing', true, ((v_today - 2) + time '09:00') at time zone v_tz)
  returning id into v_cs;
  insert into count_lines (session_id, org_id, item_id, expected, counted, reason)
  select v_cs, v_org, s.id, coalesce(sl.qty, 0),
    coalesce(sl.qty, 0) + case s.k when 'coke' then -12 when 'eva' then -6 when 'peak' then 2 else 0 end,
    case s.k when 'coke' then 'Breakage' when 'eva' then 'Unrecorded sale' when 'peak' then 'Miscount' end
  from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_sur
  where s.k in ('coke', 'eva', 'peak', 'milo');

  -- Recorded takings (cash + POS + transfers). Saturdays at Surulere run short for four weeks.
  insert into cash_takings (org_id, location_id, day, cash, pos, transfers, source)
  select v_org, x.location_id, x.d, round(t.rec * 0.41), round(t.rec * 0.44), t.rec - round(t.rec * 0.41) - round(t.rec * 0.44), 'sample'
  from (
    select (mv.recorded_at at time zone v_tz)::date d, mv.location_id, round(sum(-mv.qty * coalesce(mv.unit_price, 0))) implied
    from movements mv where mv.org_id = v_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at > now() - interval '43 days'
    group by 1, 2
  ) x
  cross join lateral (select case
      when x.location_id = v_sur and extract(isodow from x.d) = 6 and x.d >= v_today - 28
        then x.implied - (40000 + (abs(hashtext(x.d::text)::bigint) % 25000))
      else round(x.implied * (0.994 + (abs(hashtext(x.d::text || x.location_id::text)::bigint) % 6) / 1000.0)) end as rec) t
  where x.d < v_today;

  perform private.refresh_price_alerts_internal(v_org);
  return v_org;
end $$;

-- Removing a sample business takes everyone off it; nothing is erased from the ledger.
create or replace function public.remove_sample_business(p_org uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs;
begin
  perform private.require(p_org, 'owner');
  select * into o from orgs where id = p_org;
  if not o.is_sample then raise exception 'Only the sample business can be removed here.'; end if;
  update members set status = 'disabled' where org_id = p_org;
end $$;
