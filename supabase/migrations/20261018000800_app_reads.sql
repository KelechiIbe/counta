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
