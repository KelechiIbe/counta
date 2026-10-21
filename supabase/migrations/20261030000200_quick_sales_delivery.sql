-- Counta, 30 October 2026: sales logged by voice or by scanning, settled later; goods held until the money is confirmed.
--
-- 1. A sale logged on the phone (by voice, several at once, or by scanning products into a basket) can leave the way it
--    was paid for later: it posts at once (stock out, revenue and VAT in), and someone who keeps the books settles it from
--    Sales, choosing cash (which drawer), a transfer (which bank account) or POS (which account the terminal pays into).
--    A customer's name said or typed is kept on the sale, matched to the customer when the business has one by that name.
-- 2. Goods leave only once the money is confirmed (Sell, Online shop; on by default): a delivery is not dispatched or delivered while
--    its sale is unpaid, waiting for a transfer, or paid by a transfer not yet confirmed against the bank, unless a manager
--    agreed payment on delivery.

alter table public.sales add column if not exists settle_later boolean not null default false;
create index if not exists sales_settle_later on public.sales(org_id, issue_date) where settle_later;
alter table public.orgs add column if not exists release_after_payment boolean not null default true;
alter table public.deliveries add column if not exists collect_on_delivery boolean not null default false;
alter table public.deliveries add column if not exists collect_agreed_by uuid references public.members(id) on delete set null;
create index if not exists deliveries_collect_agreed_by on public.deliveries(collect_agreed_by) where collect_agreed_by is not null;

-- ---------------------------------------------------------------------------
-- 1. create_sale takes "later" as the way it was paid (receipts only)
-- ---------------------------------------------------------------------------
create or replace function private.create_sale(p_org uuid, p jsonb, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; o public.orgs; c public.customers; v_type text := coalesce(nullif(p->>'doc_type', ''), 'receipt');
  v_at timestamptz := coalesce(nullif(p->>'recorded_at', '')::timestamptz, now()); v_loc uuid; v_shift public.shifts; t jsonb; v_credit numeric := 0;
  v_cust uuid; v_owed numeric; v_paid numeric; v_tendered numeric := 0; v_issue boolean; v_bank uuid; v_method text; v_change numeric := 0;
  v_tenders jsonb; v_day date; v_today date; v_manager boolean; v_amt numeric; v_instant numeric := 0; v_later boolean := false;
begin
  if nullif(p->>'client_uuid', '') is not null then
    select * into s from sales where client_uuid = (p->>'client_uuid')::uuid;
    if found then return s; end if;
  end if;
  if v_type not in ('receipt', 'invoice', 'quote', 'order') then raise exception 'Unknown document type.'; end if;
  if v_at > now() + interval '5 minutes' then v_at := now(); end if;
  select * into o from orgs where id = p_org;
  v_manager := coalesce(private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books'), false);
  v_loc := coalesce(nullif(p->>'location_id', '')::uuid, m.location_id, (select id from locations where org_id = p_org order by is_main desc, created_at limit 1));
  if not exists (select 1 from locations where id = v_loc and org_id = p_org) then raise exception 'Choose the branch selling.'; end if;
  if nullif(p->>'shift_id', '') is not null then
    select * into v_shift from shifts where id = (p->>'shift_id')::uuid and org_id = p_org;
    if not found or v_shift.status <> 'open' then raise exception 'This till shift is closed. Open a new shift.'; end if;
  end if;
  v_today := private.local_day(p_org, now());
  v_day := coalesce(nullif(p->>'issue_date', '')::date, private.local_day(p_org, v_at));
  if v_day > v_today then raise exception 'A sale cannot be dated in the future.'; end if;
  -- Customer: chosen, matched by phone, created on the spot, or the walk-in customer.
  v_cust := nullif(p->>'customer_id', '')::uuid;
  if v_cust is null and coalesce(trim(p->'customer'->>'name'), '') <> '' then
    select id into v_cust from customers where org_id = p_org and phone = private.clean_phone(p->'customer'->>'phone') and not archived;
    if v_cust is null then v_cust := private.upsert_customer(p_org, (p->'customer') - 'id' - 'credit_limit' - 'terms_days', m); end if;
  end if;
  if v_cust is null then
    if v_type in ('invoice', 'quote') then raise exception 'Choose the customer.'; end if;
    v_cust := private.walk_in(p_org);
  end if;
  select * into c from customers where id = v_cust and org_id = p_org and not archived;
  if not found then raise exception 'Customer not found.'; end if;
  v_issue := coalesce(p->>'status', 'issue') = 'issue' and v_type in ('receipt', 'invoice');
  if v_issue then perform private.require_open_day(p_org, v_day); end if;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, shift_id, price_list_id, channel, issue_date, due_date, prices_include_vat, vat_registered, delivery_fee, reference, notes, terms,
    delivery_method, delivery_address, client_uuid, device_id, offline, created_by, created_at)
  values (p_org, v_type, private.doc_number(p_org, v_type),
    case when v_type = 'quote' then 'open' when v_type = 'order' then 'pending' when v_issue then 'open' else 'draft' end,
    c.id, c.name, c.phone, c.email, c.tin, c.address, v_loc, v_shift.id,
    case when coalesce((p->>'retail_only')::boolean, false) then null
         when nullif(p->>'price_list_id', '') is not null and exists (select 1 from price_lists where id = (p->>'price_list_id')::uuid and org_id = p_org)
         then (p->>'price_list_id')::uuid else c.price_list_id end,
    coalesce(nullif(p->>'channel', ''), case v_type when 'invoice' then 'invoice' when 'quote' then 'invoice' when 'order' then 'online' else 'till' end),
    v_day,
    case when v_type = 'quote' then coalesce(nullif(p->>'due_date', '')::date, v_day + 14)
         else coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(c.terms_days, 0), case when v_type = 'receipt' then 0 else o.invoice_terms_days end, 0)) end,
    case when v_type in ('invoice', 'quote') then coalesce((p->>'prices_include_vat')::boolean, o.prices_include_vat) else o.prices_include_vat end,
    o.vat_registered, round(greatest(coalesce(private.num(p->>'delivery_fee'), 0), 0), 2), nullif(trim(p->>'reference'), ''),
    nullif(trim(p->>'notes'), ''), coalesce(nullif(trim(p->>'terms'), ''), case when v_type = 'invoice' then o.invoice_note end),
    nullif(p->>'delivery_method', ''), nullif(trim(p->>'delivery_address'), ''), nullif(p->>'client_uuid', '')::uuid,
    nullif(p->>'device', ''), coalesce((p->>'offline')::boolean, false), m.id, v_at)
  returning * into s;
  s := private.write_lines(s, p->'lines', private.num(p->>'cart_discount'), m);
  if s.total <= 0 and v_type <> 'quote' then raise exception 'The total must be above zero.'; end if;
  if not v_issue then return s; end if;
  -- What the customer paid now. Anything not covered is credit.
  v_tenders := case when nullif(p->>'pay_in_full', '') is not null then jsonb_build_array(jsonb_build_object('method', p->>'pay_in_full', 'amount', s.total))
                    else coalesce(p->'tenders', '[]'::jsonb) end;
  if jsonb_typeof(v_tenders) <> 'array' then raise exception 'Payments must be a list.'; end if;
  for t in select * from jsonb_array_elements(v_tenders) loop
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    if v_amt < 0 then raise exception 'A payment cannot be negative.'; end if;
    if coalesce(t->>'method', '') not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other', 'credit', 'account', 'link', 'qr', 'later') then
      raise exception 'Unknown way of paying: %.', coalesce(t->>'method', '(none)');
    end if;
    -- Paid, but how is decided later on the platform (a sale logged by voice or by scanning): no money is recorded yet.
    if t->>'method' = 'later' then
      if v_type <> 'receipt' then raise exception 'Only a receipt can leave the way it was paid for later.'; end if;
      v_later := true;
      continue;
    end if;
    if t->>'method' in ('account', 'link', 'qr') then
      if v_type <> 'receipt' then raise exception 'Send a payment link from the invoice instead.'; end if;
      v_instant := v_instant + v_amt;
    end if;
    v_tendered := v_tendered + v_amt;
  end loop;
  if v_tendered > s.total + 0.004 then
    -- Cash handed over above the total is change, not income.
    v_change := v_tendered - s.total;
    if (select coalesce(sum(round(private.num(e->>'amount'), 2)), 0) from jsonb_array_elements(v_tenders) e where e->>'method' = 'cash') < v_change - 0.004 then
      raise exception 'The payments are more than the total. Only cash can be more than the total, as change.';
    end if;
  end if;
  v_credit := greatest(s.total - v_tendered, 0);
  if v_credit > 0.004 and v_type = 'receipt' and not v_later then
    if c.is_walk_in then raise exception 'A walk-in customer cannot buy on credit. Choose or add the customer.'; end if;
    if c.credit_limit = 0 and not v_manager then
      raise exception '% has no credit limit. Set one on the customer, or ask a manager.', c.name;
    end if;
  end if;
  if v_credit > 0.004 and not v_later then
    v_owed := private.customer_balance(p_org, c.id) + v_credit;
    if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not v_manager then
      raise exception '% would owe % against a credit limit of %. A manager can approve it.', c.name,
        to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
    end if;
  end if;
  -- Paying by instant transfer, link or QR: the sale waits, unposted, until the rail confirms the money. Then it posts and takes the stock.
  if v_instant > 0 then
    update sales set status = 'pending' where id = s.id returning * into s;
  else
    s := private.post_sale(s.id, m, private.posting_time(p_org, v_day, v_at));
  end if;
  for t in select * from jsonb_array_elements(v_tenders) loop
    v_method := t->>'method';
    continue when v_method = 'later';
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    v_paid := v_amt;
    if v_method = 'cash' and v_change > 0 then
      v_paid := v_amt - least(v_change, v_amt);
      v_change := v_change - least(v_change, v_amt);
    end if;
    continue when v_paid <= 0;
    if v_method = 'credit' then
      perform private.use_customer_credit(s.id, v_paid, m);
      continue;
    end if;
    if v_method in ('account', 'link', 'qr') then
      perform private.open_request(p_org, s.id, null, v_method, v_paid, m, false, v_shift.id);
      continue;
    end if;
    if v_method = 'cash' then
      v_bank := coalesce(v_shift.cash_account_id, (private.cash_drawer(p_org, v_loc, m)).id);
    else
      v_bank := nullif(t->>'bank_account_id', '')::uuid;
    end if;
    perform private.add_collection(p_org, c.id, v_paid, v_method,
      jsonb_build_object('bank_account_id', v_bank, 'shift_id', v_shift.id, 'reference', t->>'reference', 'received_at', v_at, 'spread', false,
        'note', case when v_method <> 'cash' then 'Recorded at the till by ' || coalesce(m.display_name, 'staff') end),
      m, case when v_method = 'cash' then 'confirmed' else 'pending' end, array[s.id]);
  end loop;
  if v_later then update sales set settle_later = true where id = s.id; end if;
  return private.refresh_sale(s.id);
end $$;


-- A quick sale from the phone: one or more products, an optional customer's name, and how it was paid (or "later").
create or replace function public.record_quick_sale(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; s public.sales; x jsonb; v_lines jsonb := '[]'::jsonb; v_pay text := coalesce(nullif(p->>'pay', ''), 'later');
  v_voice boolean := coalesce((p->>'voice')::boolean, false); v_name text := nullif(left(trim(regexp_replace(coalesce(p->>'customer_name', ''), '\s+', ' ', 'g')), 120), '');
  v_cust uuid := nullif(p->>'customer_id', '')::uuid; v_review text; v_qty numeric; v_n int := 0;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p->>'client_uuid', '') is not null then
    select * into s from sales where client_uuid = (p->>'client_uuid')::uuid and org_id = p_org;
    if found then return jsonb_build_object('duplicate', true, 'sale_id', s.id, 'number', s.number, 'total', s.total); end if;
  end if;
  if coalesce(v_pay, '') not in ('later', 'cash', 'transfer', 'pos', 'card') then raise exception 'Say how it was paid: cash, transfer, POS, or later.'; end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one product.'; end if;
  if jsonb_array_length(p->'lines') > 50 then raise exception 'Record at most 50 products in one sale.'; end if;
  for x in select value from jsonb_array_elements(p->'lines') loop
    v_n := v_n + 1;
    if not exists (select 1 from items where id = nullif(x->>'item_id', '')::uuid and org_id = p_org) then raise exception 'Product % is not in this business.', v_n; end if;
    v_qty := round(private.num(x->>'qty'), 3);
    if v_qty is null or v_qty <= 0 then raise exception 'Enter a quantity above zero for product %.', v_n; end if;
    v_lines := v_lines || jsonb_build_object('item_id', x->>'item_id', 'qty', v_qty, 'unit', case when x->>'unit' = 'purchase' then 'purchase' else 'selling' end);
  end loop;
  select * into o from orgs where id = p_org;
  -- The customer named, when the business has one by that name; otherwise the name stays on the sale.
  if v_cust is not null and not exists (select 1 from customers where id = v_cust and org_id = p_org and not archived) then raise exception 'Customer not found.'; end if;
  if v_cust is null and v_name is not null then
    select id into v_cust from customers where org_id = p_org and not archived and not is_walk_in and lower(name) = lower(v_name) order by created_at limit 1;
  end if;
  if v_voice then
    v_review := case when m.voice_confirmed >= o.voice_trust_threshold then 'reviewed' else 'pending' end;
    if coalesce((p->>'voice_clean')::boolean, true) then update members set voice_confirmed = voice_confirmed + 1 where id = m.id; end if;
  end if;
  s := private.create_sale(p_org, jsonb_strip_nulls(jsonb_build_object('doc_type', 'receipt', 'status', 'issue', 'location_id', nullif(p->>'location_id', ''),
    'client_uuid', nullif(p->>'client_uuid', ''), 'channel', case when v_voice then 'voice' else 'phone' end, 'recorded_at', nullif(p->>'recorded_at', ''),
    'device', nullif(p->>'device', ''), 'offline', coalesce((p->>'offline')::boolean, false),
    'notes', nullif(left(trim(coalesce(p->>'note', '')), 500), ''), 'customer_id', v_cust, 'pay_in_full', v_pay, 'lines', v_lines)), m);
  if v_cust is null and v_name is not null then update sales set customer_name = v_name where id = s.id returning * into s; end if;
  if v_review is not null then update movements set review_status = v_review where sale_id = s.id; end if;
  return jsonb_build_object('sale_id', s.id, 'number', s.number, 'total', s.total, 'vat', s.vat_total, 'status', s.status, 'settle_later', s.settle_later,
    'customer_name', s.customer_name, 'review_status', v_review, 'journal_ref', (select ref from journals where id = s.journal_id));
end $$;

-- Sales whose way of paying is still to be chosen.
create or replace function public.sales_to_settle(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'keep_books');
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'number', s.number, 'issue_date', s.issue_date, 'created_at', s.created_at,
        'customer_name', s.customer_name, 'channel', s.channel, 'total', s.total, 'balance', s.total - s.amount_paid - s.credited,
        'location_id', s.location_id, 'location', l.name, 'recorded_by', mb.display_name,
        'items', (select string_agg(coalesce(i.name, sl.description) || ' × ' || trim_scale(sl.qty)::text, ', ' order by sl.line_no)
                  from sale_lines sl left join items i on i.id = sl.item_id where sl.sale_id = s.id)) order by s.created_at), '[]'::jsonb)
      from sales s left join locations l on l.id = s.location_id left join members mb on mb.id = s.created_by
      where s.org_id = p_org and s.settle_later and s.status not in ('void', 'cancelled') and s.total - s.amount_paid - s.credited > 0.004
        and (nullif(p->>'location_id', '') is null or s.location_id = (p->>'location_id')::uuid)),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'bank_name', b.bank_name, 'location_id', b.location_id)
        order by b.kind, b.name), '[]'::jsonb) from bank_accounts b where b.org_id = p_org and b.active));
end $$;

-- Settles sales logged with the way of paying left for later: cash into a drawer, a transfer into a bank account, POS into
-- the account the terminal pays into. Each sale is paid in full by one payment, confirmed by the person settling.
create or replace function public.settle_sales(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_method text := nullif(p->>'method', ''); ba public.bank_accounts; s public.sales; v_id uuid; v_n int := 0; v_total numeric := 0; v_due numeric;
begin
  m := private.require(p_org, 'keep_books');
  if coalesce(v_method, '') not in ('cash', 'transfer', 'pos', 'card') then raise exception 'Choose cash, transfer or POS.'; end if;
  if nullif(p->>'bank_account_id', '') is not null then
    select * into ba from bank_accounts where id = (p->>'bank_account_id')::uuid and org_id = p_org and active;
    if not found then raise exception 'Choose the account the money went into.'; end if;
    if v_method = 'cash' and ba.kind <> 'cash' then raise exception 'Cash goes into a cash drawer or the safe.'; end if;
    if v_method <> 'cash' and ba.kind = 'cash' then raise exception 'A transfer or POS payment goes into a bank account.'; end if;
  elsif v_method <> 'cash' then
    raise exception 'Choose the account the money went into.';
  end if;
  if jsonb_typeof(p->'sales') <> 'array' or jsonb_array_length(p->'sales') = 0 then raise exception 'Choose the sales to settle.'; end if;
  for v_id in select (value #>> '{}')::uuid from jsonb_array_elements(p->'sales') loop
    select * into s from sales where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Sale not found.'; end if;
    if not s.settle_later then raise exception '% was paid at the time of sale.', s.number; end if;
    v_due := s.total - s.amount_paid - s.credited;
    continue when v_due <= 0.004 or s.status in ('void', 'cancelled');
    perform public.record_payment(p_org, jsonb_strip_nulls(jsonb_build_object('sale_id', s.id, 'amount', v_due, 'method', v_method,
      'bank_account_id', ba.id, 'confirmed', true, 'reference', nullif(trim(p->>'reference'), ''),
      'received_at', coalesce(nullif(p->>'paid_at', ''), s.created_at::text), 'note', 'Settled from Sales by ' || coalesce(m.display_name, 'staff'))));
    update sales set settle_later = false where id = s.id;
    v_n := v_n + 1; v_total := v_total + v_due;
  end loop;
  return jsonb_build_object('settled', v_n, 'total', v_total);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Deliveries: goods leave once the money is confirmed
-- ---------------------------------------------------------------------------
create or replace function public.save_delivery(p_org uuid, p_delivery jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; d public.deliveries; v_id uuid := nullif(p_delivery->>'id', '')::uuid; s public.sales; v_status text := nullif(p_delivery->>'status', '');
  o public.orgs; v_due numeric; v_manager boolean;
begin
  m := private.require(p_org, 'record_sales');
  select * into o from orgs where id = p_org;
  v_manager := m.role in ('owner', 'manager') or private.perm_of(m, 'approve_adjustments');
  if nullif(p_delivery->>'driver_id', '') is not null and not exists (select 1 from members where id = (p_delivery->>'driver_id')::uuid and org_id = p_org) then
    raise exception 'Choose a driver from the team.';
  end if;
  if nullif(p_delivery->>'vehicle_location_id', '') is not null
     and not exists (select 1 from locations where id = (p_delivery->>'vehicle_location_id')::uuid and org_id = p_org and kind = 'van') then
    raise exception 'Choose one of the business''s vans.';
  end if;
  if v_id is null then
    select * into s from sales where id = nullif(p_delivery->>'sale_id', '')::uuid and org_id = p_org;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') or s.status in ('void', 'cancelled', 'draft') then raise exception 'Choose the sale being delivered.'; end if;
    insert into deliveries (org_id, number, sale_id, driver_id, vehicle_location_id, address, contact_phone, scheduled_for, notes, created_by)
    values (p_org, 'DN-' || lpad(private.next_no(p_org, 'DN', 1)::text, 5, '0'), s.id, nullif(p_delivery->>'driver_id', '')::uuid,
      nullif(p_delivery->>'vehicle_location_id', '')::uuid, coalesce(nullif(trim(p_delivery->>'address'), ''), s.delivery_address, s.customer_address),
      coalesce(private.clean_phone(p_delivery->>'contact_phone'), s.customer_phone), nullif(p_delivery->>'scheduled_for', '')::date,
      nullif(trim(p_delivery->>'notes'), ''), m.id)
    returning * into d;
    -- Payment on delivery, agreed by a manager: the goods may leave unpaid and the driver collects.
    if coalesce((p_delivery->>'collect_on_delivery')::boolean, false) then
      if not v_manager then raise exception 'Only a manager can agree payment on delivery.'; end if;
      update deliveries set collect_on_delivery = true, collect_agreed_by = m.id where id = d.id returning * into d;
    end if;
  else
    select * into d from deliveries where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Delivery not found.'; end if;
    if v_status is not null and v_status not in ('pending', 'dispatched', 'delivered', 'failed', 'cancelled') then raise exception 'Unknown delivery status.'; end if;
    if d.status in ('delivered', 'cancelled') and v_status is not null and v_status <> d.status then raise exception '% is already %.', d.number, d.status; end if;
    if v_status = 'delivered' and coalesce(nullif(trim(p_delivery->>'received_by'), ''), d.received_by, '') = '' then
      raise exception 'Enter the name of the person who received the goods.';
    end if;
    if p_delivery ? 'collect_on_delivery' and coalesce((p_delivery->>'collect_on_delivery')::boolean, false) <> d.collect_on_delivery then
      if not v_manager then raise exception 'Only a manager can agree payment on delivery.'; end if;
      update deliveries set collect_on_delivery = (p_delivery->>'collect_on_delivery')::boolean,
        collect_agreed_by = case when (p_delivery->>'collect_on_delivery')::boolean then m.id end where id = d.id returning * into d;
    end if;
    -- Goods leave only once the money is confirmed (the rail's confirmation, or a payment confirmed against the bank),
    -- unless a manager agreed payment on delivery.
    if v_status in ('dispatched', 'delivered') and d.status not in ('dispatched', 'delivered') and o.release_after_payment and not d.collect_on_delivery then
      select * into s from sales where id = d.sale_id;
      v_due := s.total - s.amount_paid - s.credited;
      if s.status = 'pending' or v_due > 0.004 then
        raise exception '% has % not yet confirmed as paid. Goods leave once the payment is confirmed: take it by Pay by transfer (confirmed in seconds) or confirm the transfer against the bank. A manager can agree payment on delivery instead.',
          s.number, private.naira(case when s.status = 'pending' then s.total else v_due end);
      end if;
    end if;
    update deliveries set status = coalesce(v_status, status),
      driver_id = case when p_delivery ? 'driver_id' then nullif(p_delivery->>'driver_id', '')::uuid else driver_id end,
      vehicle_location_id = case when p_delivery ? 'vehicle_location_id' then nullif(p_delivery->>'vehicle_location_id', '')::uuid else vehicle_location_id end,
      address = coalesce(nullif(trim(p_delivery->>'address'), ''), address),
      contact_phone = coalesce(private.clean_phone(p_delivery->>'contact_phone'), contact_phone),
      scheduled_for = case when p_delivery ? 'scheduled_for' then nullif(p_delivery->>'scheduled_for', '')::date else scheduled_for end,
      dispatched_at = case when v_status in ('dispatched', 'delivered') and dispatched_at is null then now() else dispatched_at end,
      delivered_at = case when v_status = 'delivered' then now() else delivered_at end,
      received_by = coalesce(nullif(trim(p_delivery->>'received_by'), ''), received_by),
      proof_path = coalesce(nullif(p_delivery->>'proof_path', ''), proof_path),
      notes = case when p_delivery ? 'notes' then nullif(trim(p_delivery->>'notes'), '') else notes end
    where id = d.id returning * into d;
  end if;
  return to_jsonb(d);
end $$;


-- The deliveries list says which wait for the money (held), and who agreed payment on delivery.
create or replace function public.get_deliveries(p_org uuid, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_hold boolean;
begin
  m := private.require(p_org, null);
  select release_after_payment into v_hold from orgs where id = p_org;
  return (select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('sale_number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
      'balance', s.total - s.amount_paid - s.credited, 'sale_status', s.status, 'public_token', s.public_token,
      'driver_name', (select display_name from members where id = d.driver_id), 'vehicle_name', (select name from locations where id = d.vehicle_location_id),
      'collect_agreed_by_name', (select display_name from members where id = d.collect_agreed_by),
      'held', coalesce(v_hold, true) and d.status = 'pending' and not d.collect_on_delivery
        and (s.status = 'pending' or s.total - s.amount_paid - s.credited > 0.004),
      'lines', (select jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label) order by l.line_no)
                from sale_lines l where l.sale_id = s.id and l.kind <> 'delivery'))
    order by d.created_at desc), '[]'::jsonb)
    from deliveries d join sales s on s.id = d.sale_id
    where d.org_id = p_org and (d.status in ('pending', 'dispatched') or d.created_at > now() - make_interval(days => greatest(coalesce(p_days, 30), 1))));
end $$;

-- The owner turns the hold on deliveries on or off (Sell, Online shop).
create or replace function public.set_release_after_payment(p_org uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'owner');
  update orgs set release_after_payment = coalesce(p_on, true) where id = p_org;
  return jsonb_build_object('release_after_payment', coalesce(p_on, true));
end $$;

revoke all on function public.record_quick_sale(uuid, jsonb), public.sales_to_settle(uuid, jsonb), public.settle_sales(uuid, jsonb),
  public.set_release_after_payment(uuid, boolean) from public, anon;
grant execute on function public.record_quick_sale(uuid, jsonb), public.sales_to_settle(uuid, jsonb), public.settle_sales(uuid, jsonb),
  public.set_release_after_payment(uuid, boolean) to authenticated;
