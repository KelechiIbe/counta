-- Counta · What the app reads after the Atlas, selling and payments work: the inventory snapshot now carries the
-- book-keeping and payment permissions, and each item's VAT decision (who made it, how sure, under which section).

create or replace function public.get_inventory(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_tz text; v jsonb; v_today date;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  -- Usage counts sales and stock issued to jobs (less returns). Past sales brought over from another system fill in
  -- the days before Counta has its own.
  with sales as (
    select item_id,
      sum(-qty) filter (where recorded_at >= now() - interval '30 days') sold_30,
      sum(-qty) filter (where recorded_at >= now() - interval '60 days' and recorded_at < now() - interval '30 days') sold_prev30,
      sum(-qty * coalesce(unit_price, 0)) filter (where recorded_at >= now() - interval '30 days' and type in ('sale', 'voice_sale')) revenue_30,
      sum(-qty * unit_cost) filter (where recorded_at >= now() - interval '30 days' and type in ('sale', 'voice_sale')) cogs_30,
      max(recorded_at) filter (where qty < 0) last_sale_at
    from movements where org_id = p_org and type in ('sale', 'voice_sale', 'issue', 'issue_return')
    group by item_id),
  hist as (
    select item_id,
      sum(qty * private.overlap_days(day_from, day_to, v_today - 29, v_today) / (day_to - day_from + 1)) sold_30,
      sum(qty * private.overlap_days(day_from, day_to, v_today - 59, v_today - 30) / (day_to - day_from + 1)) sold_prev30,
      sum(coalesce(revenue, 0) * private.overlap_days(day_from, day_to, v_today - 29, v_today) / (day_to - day_from + 1)) revenue_30,
      min(day_from) first_day, max(day_to) last_day
    from sales_history where org_id = p_org group by item_id),
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
          'transfer_stock', private.perm_of(mb, 'transfer_stock'), 'see_margins', private.perm_of(mb, 'see_margins'),
          'issue_stock', private.perm_of(mb, 'issue_stock'), 'keep_books', private.perm_of(mb, 'keep_books'),
          'make_payments', private.perm_of(mb, 'make_payments'))
      ) order by (mb.role = 'owner') desc, mb.created_at), '[]'::jsonb) from members mb where mb.org_id = p_org and mb.status <> 'disabled'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'photo_path', i.photo_path, 'barcode', i.barcode, 'sku', i.sku, 'qr_code', i.qr_code,
        'category', i.category, 'vat_treatment', i.vat_treatment, 'nafdac_no', i.nafdac_no, 'purchase_unit', i.purchase_unit,
        'pack_size', i.pack_size, 'selling_unit', i.selling_unit, 'informal_unit', i.informal_unit, 'track_batches', i.track_batches,
        'reorder_floor', i.reorder_floor, 'preferred_vendor_id', i.preferred_vendor_id, 'alt_vendor_id', i.alt_vendor_id,
        'price', i.price, 'import_priced', i.import_priced, 'notes', i.notes, 'needs_review', i.needs_review, 'created_at', i.created_at,
        'item_type', i.item_type, 'brand', i.brand, 'description', i.description, 'attributes', i.attributes,
        'inventory_account', i.inventory_account,
        'vat_basis', i.vat_basis, 'vat_review', i.vat_review, 'vat_confidence', i.vat_confidence, 'vat_checked', i.vat_checked_at is not null,
        'wac', case when v_cost then c.wac end, 'last_cost', case when v_cost then c.last_cost end,
        'replacement_cost', case when v_cost then c.replacement_cost end,
        'replacement_source', case when v_cost then c.replacement_source end,
        'qty', coalesce(lv.q, '{}'::jsonb),
        'sold_30', round(coalesce(s.sold_30, 0) + coalesce(h.sold_30, 0), 3), 'sold_prev30', round(coalesce(s.sold_prev30, 0) + coalesce(h.sold_prev30, 0), 3),
        'revenue_30', round(coalesce(s.revenue_30, 0) + coalesce(h.revenue_30, 0), 2),
        'cogs_30', case when v_cost then coalesce(s.cogs_30, 0) end,
        'last_sale_at', greatest(s.last_sale_at, (h.last_day::timestamp + interval '12 hours') at time zone v_tz),
        'first_at', least(f.first_at, h.first_day::timestamp at time zone v_tz), 'last_move_at', f.last_move_at,
        'has_history', h.item_id is not null,
        'snoozed_until', (select until from reorder_snoozes rs where rs.item_id = i.id)
      ) order by i.name), '[]'::jsonb)
      from items i left join item_costs c on c.item_id = i.id left join sales s on s.item_id = i.id left join hist h on h.item_id = i.id
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

revoke all on function public.get_inventory(uuid) from public, anon;
grant execute on function public.get_inventory(uuid) to authenticated;

-- The till shows the price each line will be charged before checkout: the customer's price list, quantity tiers and the
-- purchase unit (a carton of 40 at the carton price). The same rule create_sale applies.
-- p_lines: [{item_id, qty, unit: 'selling'|'purchase'}] -> [{item_id, unit, price}]
create or replace function public.till_prices(p_org uuid, p_list uuid, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare x jsonb; it public.items; v_factor numeric; v_qty numeric; v_out jsonb := '[]'::jsonb;
begin
  perform private.require(p_org, 'record_sales');
  if jsonb_typeof(p_lines) <> 'array' then return v_out; end if;
  for x in select * from jsonb_array_elements(p_lines) limit 300 loop
    select * into it from items where id = nullif(x->>'item_id', '')::uuid and org_id = p_org;
    continue when not found;
    v_factor := case when x->>'unit' = 'purchase' then it.pack_size else 1 end;
    v_qty := greatest(coalesce(private.num(x->>'qty'), 1), 0);
    v_out := v_out || jsonb_build_object('item_id', it.id, 'unit', coalesce(x->>'unit', 'selling'),
      'price', round(coalesce(private.list_price(p_org, it.id, p_list, v_qty * v_factor), it.price) * v_factor, 2));
  end loop;
  return v_out;
end $$;
revoke all on function public.till_prices(uuid, uuid, jsonb) from public, anon;
grant execute on function public.till_prices(uuid, uuid, jsonb) to authenticated;

-- An order taken by staff (by phone, by a sales rep, or for delivery from a van). It waits unposted until it is
-- confirmed, the same way an online shop order does; deposits paid against it sit as customer advances.
create or replace function public.save_order(p_org uuid, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.sales;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_doc->>'customer_id', '') is null and coalesce(trim(p_doc->'customer'->>'name'), '') = '' then raise exception 'Choose the customer.'; end if;
  s := private.create_sale(p_org, (p_doc - 'tenders' - 'pay_in_full' - 'id') || jsonb_build_object('doc_type', 'order', 'status', 'issue',
    'channel', coalesce(nullif(p_doc->>'channel', ''), 'phone')), m);
  perform private.notify_perm(p_org, 'record_sales', 'order', 'New order ' || s.number || ' · ' || s.customer_name,
    '₦' || to_char(s.total, 'FM999,999,999,990.00') || coalesce(' · ' || s.delivery_method, ''), '/sell/orders', 'order-' || s.id, m.id);
  return private.sale_json(s.id, private.can_see_costs(p_org));
end $$;
revoke all on function public.save_order(uuid, jsonb) from public, anon;
grant execute on function public.save_order(uuid, jsonb) to authenticated;

-- How the statements are framed (IFRS or IFRS for SMEs, the principal activity in note 1) and the small-company WHT
-- exemption (suppliers with a TIN, bills under ₦2m). Owner only.
create or replace function public.update_books_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes how the books are reported.' using errcode = '42501'; end if;
  if p_patch ? 'reporting_framework' and p_patch->>'reporting_framework' not in ('ifrs', 'ifrs_sme') then raise exception 'Choose IFRS or IFRS for SMEs.'; end if;
  update orgs set
    reporting_framework = coalesce(nullif(p_patch->>'reporting_framework', ''), reporting_framework),
    principal_activity = case when p_patch ? 'principal_activity' then nullif(trim(p_patch->>'principal_activity'), '') else principal_activity end,
    wht_small_company = coalesce((p_patch->>'wht_small_company')::boolean, wht_small_company)
  where id = p_org returning * into o;
  return jsonb_build_object('reporting_framework', o.reporting_framework, 'principal_activity', o.principal_activity, 'wht_small_company', o.wht_small_company);
end $$;
revoke all on function public.update_books_settings(uuid, jsonb) from public, anon;
grant execute on function public.update_books_settings(uuid, jsonb) to authenticated;
