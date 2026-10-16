-- Counta — open a receipt draft (DR number, PO prefill) and landed-cost allocation (Phase 4)

create or replace function public.start_receipt(
  p_org uuid, p_source text, p_document_path text default null, p_document_mime text default null,
  p_location uuid default null, p_vendor uuid default null, p_po uuid default null,
  p_client_uuid uuid default null, p_device text default null, p_offline boolean default false
) returns public.receipts
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r public.receipts; v public.vendors; po public.purchase_orders;
begin
  m := private.require(p_org, 'receive_stock');
  if p_client_uuid is not null then
    select * into r from receipts where client_uuid = p_client_uuid;
    if found then return r; end if;
  end if;
  if p_source not in ('pdf', 'photo_typed', 'photo_handwritten', 'manual') then raise exception 'Unknown receipt source.'; end if;
  if p_document_path is not null and split_part(p_document_path, '/', 1) <> p_org::text then raise exception 'That file belongs to another business.'; end if;
  if p_po is not null then
    select * into po from purchase_orders where id = p_po and org_id = p_org;
    if not found then raise exception 'Purchase order not found.'; end if;
    p_vendor := coalesce(p_vendor, po.vendor_id);
    p_location := coalesce(p_location, po.location_id);
  end if;
  if p_vendor is not null then select * into v from vendors where id = p_vendor and org_id = p_org; end if;
  insert into receipts (org_id, ref, source, document_path, document_mime, location_id, vendor_id, vendor_name, vendor_vat_registered,
    po_id, status, created_by, client_uuid, device_id, offline)
  values (p_org, 'DR-' || lpad(private.next_no(p_org, 'DR', 201)::text, 4, '0'), p_source, p_document_path, p_document_mime,
    coalesce(p_location, m.location_id, (select id from locations where org_id = p_org and is_main limit 1)),
    v.id, v.name, coalesce(v.vat_registered, false), p_po,
    case when p_source = 'manual' or p_document_path is null then 'needs_review' else 'reading' end,
    m.id, p_client_uuid, p_device, coalesce(p_offline, false))
  returning * into r;
  if p_po is not null then
    insert into receipt_lines (receipt_id, org_id, line_no, item_id, qty, unit_kind, unit_label, unit_cost, confidence, confirmed, raw_text, model_reading)
    select r.id, p_org, (row_number() over (order by pl.id))::int, pl.item_id, pl.qty, 'purchase', i.purchase_unit, pl.unit_cost, 100, true,
      'Ordered on ' || po.ref, jsonb_build_object('qty', pl.qty, 'unit_cost', pl.unit_cost)
    from po_lines pl join items i on i.id = pl.item_id where pl.po_id = p_po;
  end if;
  return r;
end $$;

create table if not exists public.landed_costs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  receipt_id uuid not null references public.receipts(id) on delete cascade,
  charges jsonb not null,
  total numeric(16,2) not null,
  basis text not null default 'value',
  allocation jsonb not null default '[]'::jsonb,
  journal_id uuid references public.journals(id) on delete set null,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists landed_costs_org on public.landed_costs(org_id, created_at desc);
alter table public.landed_costs enable row level security;
create policy landed_costs_read on public.landed_costs for select to authenticated using ((select private.can_see_costs(org_id)));

-- Shipment charges (duty, clearing, haulage, agent) allocated across a posted receipt by line value.
-- Stock still on hand absorbs its share into weighted average cost; anything already sold goes to cost of sales.
create or replace function public.post_landed_cost(p_receipt uuid, p_charges jsonb, p_payee text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; k text; v numeric; v_total numeric := 0; v_lines numeric; v_alloc numeric; v_left numeric;
  x record; v_onhand numeric; v_absorb numeric := 0; v_expense numeric := 0; v_out jsonb := '[]'::jsonb; j public.journals; v_n int; v_i int := 0;
begin
  select * into r from receipts where id = p_receipt;
  if not found then raise exception 'Receipt not found.'; end if;
  m := private.require(r.org_id, 'edit_prices');
  if r.status <> 'posted' then raise exception 'Post the receipt before allocating landed cost.'; end if;
  for k, v in select key, nullif(value #>> '{}', '')::numeric from jsonb_each(coalesce(p_charges, '{}'::jsonb)) loop
    if v is null then continue; end if;
    if v < 0 then raise exception 'Charges cannot be negative.'; end if;
    v_total := v_total + v;
  end loop;
  v_total := round(v_total, 2);
  if v_total <= 0 then raise exception 'Enter at least one charge.'; end if;
  select coalesce(sum(value), 0), count(*) into v_lines, v_n from movements where receipt_id = r.id and type = 'receipt';
  if v_lines <= 0 then raise exception 'This receipt has no stock lines to allocate to.'; end if;
  v_left := v_total;
  for x in select mv.item_id, sum(mv.qty) qty, sum(mv.value) val, max(i.name) name from movements mv join items i on i.id = mv.item_id
           where mv.receipt_id = r.id and mv.type = 'receipt' group by mv.item_id order by sum(mv.value) desc loop
    v_i := v_i + 1;
    v_alloc := case when v_i = (select count(distinct item_id) from movements where receipt_id = r.id and type = 'receipt') then v_left
                    else round(v_total * x.val / v_lines, 2) end;
    v_left := v_left - v_alloc;
    select coalesce(sum(qty), 0) into v_onhand from stock_levels where item_id = x.item_id;
    if v_onhand > 0 then
      update item_costs set wac = round(wac + v_alloc / v_onhand, 4), updated_at = now() where item_id = x.item_id;
      v_absorb := v_absorb + v_alloc;
    else
      v_expense := v_expense + v_alloc;
    end if;
    v_out := v_out || jsonb_build_object('item_id', x.item_id, 'name', x.name, 'invoice', x.val, 'share', round(x.val / v_lines, 4), 'allocated', v_alloc,
      'absorbed', v_onhand > 0);
  end loop;
  j := private.post_journal(r.org_id, 'Landed cost · ' || r.ref || coalesce(' · ' || nullif(trim(p_payee), ''), ''), 'landed_cost', r.id, m.id, m.id,
    jsonb_build_array(
      jsonb_build_object('code', '1310', 'debit', v_absorb, 'location_id', r.location_id, 'memo', 'Duty, clearing and haulage into stock value'),
      jsonb_build_object('code', '5100', 'debit', v_expense, 'memo', 'Share on stock already sold'),
      jsonb_build_object('code', '2010', 'credit', v_total, 'memo', coalesce(nullif(trim(p_payee), ''), 'Clearing and haulage'))));
  insert into landed_costs (org_id, receipt_id, charges, total, allocation, journal_id, created_by)
  values (r.org_id, r.id, p_charges, v_total, v_out, j.id, m.id);
  return jsonb_build_object('journal_ref', j.ref, 'total', v_total, 'absorbed', v_absorb, 'expensed', v_expense, 'allocation', v_out);
end $$;

grant execute on function public.start_receipt(uuid, text, text, text, uuid, uuid, uuid, uuid, text, boolean) to authenticated;
grant execute on function public.post_landed_cost(uuid, jsonb, text) to authenticated;
