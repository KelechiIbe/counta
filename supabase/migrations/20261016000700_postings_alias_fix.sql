-- Counta — rename aliases that clashed with PL/pgSQL loop variables (applied as a hotfix; 0200 already carries the fix)

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
