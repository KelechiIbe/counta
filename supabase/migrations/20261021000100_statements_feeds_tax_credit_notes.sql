-- Counta · Bulk payment sheets read as people fill them, credit notes for price changes and from suppliers, PDF bank
-- statements, bank feeds from Mono, reconciliation of money paid straight into the bank, and the tax computation and
-- capital allowance schedule printed with the financial statements.
--
-- 1. Bulk payments: a bill named as "Bill 12" or "12", the supplier's own invoice number written with or without its
--    punctuation, a supplier named a little differently ("Adex Consulting" for "Adex Consulting Ltd") and an account
--    named by its name instead of its code are all found.
-- 2. Credit notes: a customer credited for an amount (a price reduction, an allowance or a service not delivered)
--    without goods coming back; and credit notes received from suppliers, with or without stock going back.
-- 3. Bank statements: one import for Excel, CSV and PDF statements from any Nigerian bank. The opening and closing
--    balances are kept, and a line already in the books from the bank feed is not added twice.
-- 4. Bank feeds: accounts linked through Mono Connect bring their transactions into the same pipeline as statements.
-- 5. Reconciliation: money paid straight into the bank is matched to the invoice it names (INV-0042 in the narration),
--    and a payment that matches exactly one open invoice by amount is put to a person to confirm.
-- 6. Tax: the companies income tax computation and the capital allowance schedule under the Nigeria Tax Act 2025,
--    from rules kept in a table so the rule book can change them, printed with the financial statements.

-- ---------------------------------------------------------------------------
-- 1. Bulk payments: finding what a sheet names
-- ---------------------------------------------------------------------------
-- A name compared without case, punctuation, doubled spaces or the company suffix: "ADEX CONSULTING LTD." is
-- "Adex Consulting Limited".
create or replace function private.name_norm(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(lower(coalesce(p, '')), '&', ' and ', 'g'), '[^a-z0-9 ]+', ' ', 'g'),
    '\m(ltd|limited|plc|nig|nigeria|co|company|enterprises?|ventures|inc|llc)\M', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;

-- The supplier a sheet names: the exact name first, then the same name without suffix and punctuation, then a name
-- that starts with what the sheet gives when only one does.
create or replace function private.find_vendor(p_org uuid, p_name text) returns public.vendors
language plpgsql stable security definer set search_path = public, private as $$
declare v public.vendors; v_n int; v_key text := private.name_norm(p_name);
begin
  if v_key is null then return v; end if;
  select * into v from vendors where org_id = p_org and lower(name) = lower(trim(p_name)) limit 1;
  if found then return v; end if;
  select count(*) into v_n from vendors where org_id = p_org and private.name_norm(name) = v_key;
  if v_n = 1 then select * into v from vendors where org_id = p_org and private.name_norm(name) = v_key; return v; end if;
  if v_n = 0 and length(v_key) >= 4 then
    select count(*) into v_n from vendors where org_id = p_org and private.name_norm(name) like v_key || '%';
    if v_n = 1 then select * into v from vendors where org_id = p_org and private.name_norm(name) like v_key || '%'; end if;
  end if;
  return v;
end $$;

-- The bill a sheet names: BILL-0012 as Counta numbers it, "Bill 12" or "12", or the supplier's own invoice number with
-- or without its punctuation (only bills still to pay, and only that supplier's when the row names one).
create or replace function private.find_bill(p_org uuid, p_ref text, p_vendor uuid default null) returns public.bills
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bills; v_ref text := lower(trim(coalesce(p_ref, ''))); v_digits text; v_flat text;
begin
  if v_ref = '' then return b; end if;
  select * into b from bills where org_id = p_org and status <> 'void' and lower(number) = v_ref limit 1;
  if found then return b; end if;
  if v_ref ~ '^(bill)?[\s\-#:.no]*0*[0-9]+$' then
    v_digits := ltrim(regexp_replace(v_ref, '\D', '', 'g'), '0');
    select * into b from bills where org_id = p_org and status <> 'void' and number ~ '^BILL-[0-9]+$'
      and ltrim(substr(number, 6), '0') = v_digits and (p_vendor is null or vendor_id = p_vendor) limit 1;
    if found then return b; end if;
  end if;
  v_flat := regexp_replace(v_ref, '[^a-z0-9]', '', 'g');
  if v_flat = '' then return b; end if;
  select * into b from bills where org_id = p_org and status in ('approved', 'partially_paid') and (p_vendor is null or vendor_id = p_vendor)
    and regexp_replace(lower(coalesce(vendor_ref, '')), '[^a-z0-9]', '', 'g') = v_flat
  order by bill_date limit 1;
  return b;
end $$;

-- The account a sheet names: its code, "6101 Salaries", or its name when one account has that name.
create or replace function private.find_account(p_org uuid, p_text text) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare v_t text := trim(coalesce(p_text, '')); v_code text; v_n int;
begin
  if v_t = '' then return null; end if;
  v_code := substring(v_t from '^([0-9]{3,6}(-[0-9]+)?)\M');
  if v_code is not null then return v_code; end if;
  select count(*), min(a.code) into v_n, v_code from private.accounts_of(p_org) a
  where a.active and not a.is_group and private.name_norm(a.name) = private.name_norm(v_t);
  if v_n = 1 then return v_code; end if;
  return v_t;
end $$;

-- One row of a bulk payment sheet against the books (as before, with the finding above).
create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text; sv public.vendors;
begin
  if coalesce(r->>'account_number', '') !~ '^[0-9]{10}$' then v_err := v_err || 'Account numbers have 10 digits.'::text; end if;
  if coalesce(trim(r->>'bank_code'), '') = '' then v_err := v_err || 'Choose the bank.'::text; end if;
  if coalesce(trim(r->>'account_name'), '') = '' then v_err := v_err || 'The bank has not confirmed the account name.'::text; end if;
  if v_supplier is not null then sv := private.find_vendor(p_org, v_supplier); end if;
  if v_bill_ref is not null then
    b := private.find_bill(p_org, v_bill_ref, sv.id);
    if b.id is null and sv.id is not null then b := private.find_bill(p_org, v_bill_ref, null); end if;
    if b.id is null then
      v_err := v_err || format('No bill %s in Counta%s.', v_bill_ref, case when sv.id is not null then ' from ' || sv.name else '' end);
    else
      select * into v from vendors where id = b.vendor_id;
      v_kind := 'bill'; v_label := b.number || ' · ' || v.name;
      if v_supplier is not null and sv.id is distinct from v.id then
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
    if sv.id is null then
      v_err := v_err || format('No supplier named %s in Counta.', v_supplier);
    else
      v := sv;
      v_kind := 'vendor'; v_purpose := 'vendor'; v_gross := v_amt; v_label := v.name || ' · on account';
      v_lines := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_amt, 'party_type', 'vendor', 'party_id', v.id,
        'memo', 'Paid on account · ' || coalesce(nullif(trim(r->>'narration'), ''), v.name)));
    end if;
  else
    v_code := coalesce(private.find_account(p_org, nullif(trim(r->>'account'), '')), p_default);
    if v_code is null then
      v_err := v_err || 'Say what this payment is for: a bill number, a supplier or an account code.'::text;
    elsif v_code !~ '^[0-9]' then
      v_err := v_err || format('No account called %s in your chart. Use its code.', v_code);
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

-- ---------------------------------------------------------------------------
-- 2. Credit notes
-- ---------------------------------------------------------------------------
-- 2a. Customers: a credit note for an amount, with no goods coming back. Each line it credits keeps its VAT rate, so
--     output VAT falls by the VAT inside the amount; the rest reduces revenue (4131 for goods, the line's own revenue
--     account for services). Lines already credited (by a return or an earlier credit note) cannot be credited twice.
alter table public.sale_lines add column if not exists adjustment boolean not null default false;

-- What can still be credited on each line of a sale.
create or replace function private.sale_line_creditable(p_line uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select greatest(l.gross - coalesce((select sum(c.gross) from sale_lines c join sales cn on cn.id = c.sale_id
    where c.original_line_id = l.id and cn.status <> 'void'), 0), 0)
  from sale_lines l where l.id = p_line
$$;

create or replace function public.sale_creditable(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  perform private.require(s.org_id, null);
  return jsonb_build_object('sale_id', s.id, 'number', s.number, 'due', greatest(s.total - s.amount_paid - s.credited, 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'description', l.description, 'kind', l.kind, 'qty', l.qty,
        'returned_qty', l.returned_qty, 'gross', l.gross, 'vat', l.vat, 'vat_rate', l.vat_rate, 'creditable', private.sale_line_creditable(l.id)) order by l.line_no), '[]'::jsonb)
      from sale_lines l where l.sale_id = s.id));
end $$;

-- What a new credit note does to its sale: it first clears what is still owed on it, then pays money back if asked,
-- and the rest stays with the customer as credit for their next purchase.
create or replace function private.settle_credit_note(p_cn uuid, p_sale uuid, p_refund jsonb, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cn public.sales; s public.sales; v_due numeric; v_apply numeric; v_refund numeric; v_bank uuid; col public.collections;
begin
  select * into cn from sales where id = p_cn for update;
  s := private.refresh_sale(p_sale);
  v_due := s.total - s.amount_paid - s.credited;
  v_apply := least(greatest(v_due, 0), cn.total);
  if v_apply > 0 then
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, s.id, s.org_id, v_apply, m.id);
    s := private.refresh_sale(s.id);
  end if;
  v_refund := least(round(coalesce(private.num(p_refund->>'amount'), 0), 2), cn.total - v_apply);
  if v_refund > 0 then
    v_bank := nullif(p_refund->>'bank_account_id', '')::uuid;
    if v_bank is null and coalesce(nullif(p_refund->>'method', ''), 'cash') = 'cash' then v_bank := (private.cash_drawer(s.org_id, s.location_id, m)).id; end if;
    if v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = s.org_id and active) then
      raise exception 'Choose the account the refund is paid from.';
    end if;
    if coalesce(nullif(p_refund->>'method', ''), 'cash') not in ('cash', 'transfer', 'cheque', 'other') then raise exception 'Unknown refund method.'; end if;
    insert into collections (org_id, number, direction, customer_id, sale_id, amount, method, status, bank_account_id, shift_id, reference, received_at,
      confirmed_by, confirmed_at, note, created_by)
    values (s.org_id, private.pay_no(s.org_id), 'out', s.customer_id, cn.id, v_refund, coalesce(nullif(p_refund->>'method', ''), 'cash'), 'confirmed', v_bank,
      (select id from shifts where cash_account_id = v_bank and status = 'open'), cn.number, now(), m.id, now(), 'Refund for ' || s.number, m.id)
    returning * into col;
    perform private.post_collection(col.id, m);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, s.org_id, v_refund, m.id);
  end if;
  update sales set credited = v_apply + v_refund, status = case when v_apply + v_refund >= cn.total - 0.004 then 'paid' else 'open' end where id = cn.id;
  return jsonb_build_object('refunded', v_refund, 'applied', v_apply, 'store_credit', cn.total - v_apply - v_refund);
end $$;

-- p: {reason, lines:[{sale_line_id, amount}] | amount (spread over the lines in proportion to what each can still take),
--     refund:{method, amount, bank_account_id}}. Amounts include VAT, as the customer paid them.
create or replace function public.credit_sale(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; cn public.sales; l public.sale_lines; x jsonb; v_amt numeric; v_left numeric; v_vat numeric; v_net numeric;
  v_jl jsonb := '[]'::jsonb; v_no int := 0; v_tot numeric := 0; v_vtot numeric := 0; j public.journals; v_lines jsonb; v_pool numeric; v_want numeric;
  v_spread numeric; v_i int := 0; v_n int; v_res jsonb; v_reason text := trim(coalesce(p->>'reason', ''));
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'approve_adjustments');
  if s.doc_type not in ('receipt', 'invoice', 'order') or s.journal_id is null or s.status in ('void', 'cancelled', 'draft') then
    raise exception '% cannot take a credit note.', s.number;
  end if;
  if v_reason = '' then raise exception 'Give the reason for the credit note.'; end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  -- One amount for the whole sale: shared over the lines by what each can still be credited.
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    v_want := round(coalesce(private.num(p->>'amount'), 0), 2);
    if v_want <= 0 then raise exception 'Enter the amount to credit.'; end if;
    select coalesce(sum(private.sale_line_creditable(id)), 0), count(*) filter (where private.sale_line_creditable(id) > 0) into v_pool, v_n
    from sale_lines where sale_id = s.id;
    if v_want > v_pool + 0.004 then raise exception 'At most % can still be credited on %.', to_char(v_pool, 'FM999,999,999,990.00'), s.number; end if;
    v_lines := '[]'::jsonb; v_spread := 0;
    for l in select * from sale_lines where sale_id = s.id and private.sale_line_creditable(id) > 0 order by line_no loop
      v_i := v_i + 1;
      v_amt := case when v_i = v_n then v_want - v_spread else round(v_want * private.sale_line_creditable(l.id) / v_pool, 2) end;
      v_spread := v_spread + v_amt;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('sale_line_id', l.id, 'amount', v_amt));
    end loop;
  else
    v_lines := p->'lines';
  end if;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, prices_include_vat, vat_registered, original_sale_id, notes, created_by, issued_at, customer_country, export)
  values (s.org_id, 'credit_note', private.doc_number(s.org_id, 'credit_note'), 'open', s.customer_id, s.customer_name, s.customer_phone, s.customer_email,
    s.customer_tin, s.customer_address, s.location_id, s.channel, private.local_day(s.org_id, now()), s.prices_include_vat, s.vat_registered, s.id,
    v_reason, m.id, now(), s.customer_country, s.export)
  returning * into cn;
  for x in select * from jsonb_array_elements(v_lines) loop
    select * into l from sale_lines where id = nullif(x->>'sale_line_id', '')::uuid and sale_id = s.id for update;
    if not found then raise exception 'A credited line is not on %.', s.number; end if;
    v_amt := round(coalesce(private.num(x->>'amount'), 0), 2);
    continue when v_amt <= 0;
    v_left := private.sale_line_creditable(l.id);
    if v_amt > v_left + 0.004 then raise exception 'Only % can still be credited on %.', to_char(v_left, 'FM999,999,999,990.00'), l.description; end if;
    -- The VAT inside the amount, at the line's own rate; the last kobo follows the line when it is credited in full.
    v_vat := case when l.gross = 0 then 0 when v_amt >= v_left - 0.004 then l.vat - coalesce((select sum(c.vat) from sale_lines c join sales x2 on x2.id = c.sale_id
               where c.original_line_id = l.id and x2.status <> 'void'), 0) else round(v_amt * l.vat / l.gross, 2) end;
    v_net := v_amt - v_vat;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount, vat_treatment,
      vat_rate, net, vat, gross, cost, revenue_account, original_line_id, adjustment, item_vat_treatment)
    values (cn.id, s.org_id, v_no, case when l.kind = 'delivery' then 'delivery' else 'service' end, null, left(l.description || ' · price adjustment', 300), 1, 'adjustment', 1,
      v_amt, null, 0, l.vat_treatment, l.vat_rate, v_net, v_vat, v_amt, 0, l.revenue_account, l.id, true, l.item_vat_treatment);
    v_tot := v_tot + v_amt; v_vtot := v_vtot + v_vat;
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.kind = 'goods' then private.acct(s.org_id, 'sales_returns') else coalesce(l.revenue_account, private.acct(s.org_id, 'sales_revenue')) end,
      'debit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', l.description || ' · price adjustment'));
  end loop;
  if v_tot <= 0 then raise exception 'Enter the amount to credit.'; end if;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'debit', v_vtot, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', 'VAT on ' || cn.number),
    jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'credit', v_tot, 'location_id', s.location_id, 'party_type', 'customer',
      'party_id', s.customer_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', cn.number || ' for ' || s.number));
  update sales set subtotal = v_tot - v_vtot, vat_total = v_vtot, total = v_tot where id = cn.id;
  j := private.post_entry(s.org_id, 'Credit note ' || cn.number || ' for ' || s.number || ' · ' || v_reason, 'sale', cn.id, m.id, m.id, v_jl, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = cn.id;
  v_res := private.settle_credit_note(cn.id, s.id, coalesce(p->'refund', '{}'::jsonb), m);
  return jsonb_build_object('credit_note', private.sale_json(cn.id, private.can_see_costs(s.org_id))) || v_res;
end $$;

-- A price adjustment changes the money, not the quantity sold: it shows under the item it adjusts, with no units.
create or replace function private.sales_analysis(p_org uuid, p_from date, p_to date, p_by text, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'documents', docs, 'qty', qty, 'net', net, 'vat', vat, 'gross', gross,
      'cost', case when p_cost then cost end, 'margin', case when p_cost then net - cost end,
      'margin_pct', case when p_cost and net <> 0 then round((net - cost) / net * 100, 1) end) order by net desc), '[]'::jsonb)
  from (
    select case p_by when 'customer' then s.customer_name when 'channel' then initcap(s.channel) when 'branch' then (select name from locations where id = s.location_id)
                when 'cashier' then coalesce((select display_name from members where id = s.created_by), 'Online') when 'month' then to_char(s.issue_date, 'YYYY-MM')
                when 'day' then to_char(s.issue_date, 'YYYY-MM-DD')
                when 'vat_status' then case l.vat_status when 0 then '0 · VATable (7.5%)' when 1 then '1 · Exempt' else '2 · Zero-rated' end
                  || case when s.export and l.vat_status = 2 then ', export' else '' end
                else case when l.adjustment then coalesce((select o.description from sale_lines o where o.id = l.original_line_id), l.description) else l.description end end k,
      count(distinct s.id) docs, sum(case when l.adjustment then 0 when s.doc_type = 'credit_note' then -l.qty else l.qty end * l.unit_factor) qty,
      sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) net, sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end) vat,
      sum(case when s.doc_type = 'credit_note' then -l.gross else l.gross end) gross, sum(case when s.doc_type = 'credit_note' then -coalesce(l.cost, 0) else coalesce(l.cost, 0) end) cost
    from sales s join sale_lines l on l.sale_id = s.id
    where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to
      and (p_by <> 'item' or l.kind <> 'delivery' or l.adjustment and (select o.kind from sale_lines o where o.id = l.original_line_id) <> 'delivery')
    group by 1) x
$$;

-- 2b. Suppliers: a credit note received against a bill (or on account). It reduces what is owed to them, takes back the
--     input VAT it carries, and can send stock back to them. Applied to its bill first; anything over that stays on the
--     supplier's account to use against their next bill or to be refunded.
insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('purchase_returns', 'Purchase returns', 'Credit notes from suppliers for stock: goods sent back, and price allowances on stock bought.', '5103', '^(5103|5101|5102)$', 46)
on conflict (role) do nothing;

alter table public.bill_payments drop constraint if exists bill_payments_method_check;
alter table public.bill_payments add constraint bill_payments_method_check check (method in ('wallet', 'bank', 'cash', 'offset', 'credit_note'));
alter table public.bill_payments add column if not exists vendor_credit_id uuid;

alter table public.movements drop constraint if exists movements_type_check;
alter table public.movements add constraint movements_type_check check (type in (
  'opening', 'receipt', 'sale', 'voice_sale', 'transfer_out', 'transfer_in', 'adjustment', 'write_off', 'quarantine',
  'issue', 'issue_return', 'production_in', 'sale_return', 'purchase_return'));

create table if not exists public.vendor_credits (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  vendor_id uuid not null references public.vendors(id),
  bill_id uuid references public.bills(id) on delete set null,
  vendor_ref text,
  credit_date date not null,
  reason text not null,
  subtotal numeric(16,2) not null default 0,
  vat_total numeric(16,2) not null default 0,
  total numeric(16,2) not null default 0 check (total >= 0),
  applied numeric(16,2) not null default 0,
  refunded numeric(16,2) not null default 0,
  status text not null default 'open' check (status in ('open', 'used', 'void')),
  journal_id uuid references public.journals(id) on delete set null,
  document_path text,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, number)
);
create index if not exists vendor_credits_org on public.vendor_credits(org_id, credit_date desc);
create index if not exists vendor_credits_vendor on public.vendor_credits(vendor_id);
create index if not exists vendor_credits_bill on public.vendor_credits(bill_id);
create index if not exists vendor_credits_journal_fk on public.vendor_credits(journal_id);
create index if not exists vendor_credits_created_by_fk on public.vendor_credits(created_by);

create table if not exists public.vendor_credit_lines (
  id uuid primary key default gen_random_uuid(),
  credit_id uuid not null references public.vendor_credits(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  line_no int not null,
  description text not null,
  account_code text not null,
  bill_line_id uuid references public.bill_lines(id) on delete set null,
  item_id uuid references public.items(id) on delete set null,
  qty numeric(14,3),
  location_id uuid references public.locations(id) on delete set null,
  net numeric(16,2) not null,
  vat numeric(16,2) not null default 0,
  gross numeric(16,2) not null,
  stock_cost numeric(16,2)
);
create index if not exists vendor_credit_lines_credit on public.vendor_credit_lines(credit_id);
create index if not exists vendor_credit_lines_org on public.vendor_credit_lines(org_id);
create index if not exists vendor_credit_lines_bill_line on public.vendor_credit_lines(bill_line_id);
create index if not exists vendor_credit_lines_item on public.vendor_credit_lines(item_id);
create index if not exists vendor_credit_lines_location on public.vendor_credit_lines(location_id);
alter table public.bill_payments drop constraint if exists bill_payments_vendor_credit_fk;
alter table public.bill_payments add constraint bill_payments_vendor_credit_fk foreign key (vendor_credit_id) references public.vendor_credits(id) on delete set null;
create index if not exists bill_payments_vendor_credit on public.bill_payments(vendor_credit_id);

alter table public.vendor_credits enable row level security;
alter table public.vendor_credit_lines enable row level security;
drop policy if exists vendor_credits_read on public.vendor_credits;
create policy vendor_credits_read on public.vendor_credits for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists vendor_credit_lines_read on public.vendor_credit_lines;
create policy vendor_credit_lines_read on public.vendor_credit_lines for select to authenticated using ((select private.can_handle_money(org_id)));

-- What a bill line can still be credited by.
create or replace function private.bill_line_creditable(p_line uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select greatest(bl.gross - coalesce((select sum(c.gross) from vendor_credit_lines c join vendor_credits vc on vc.id = c.credit_id
    where c.bill_line_id = bl.id and vc.status <> 'void'), 0), 0)
  from bill_lines bl where bl.id = p_line
$$;

create or replace function private.vendor_credit_json(p_credit uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(vc) || jsonb_build_object(
    'vendor_name', (select name from vendors where id = vc.vendor_id),
    'bill_number', (select number from bills where id = vc.bill_id),
    'remaining', vc.total - vc.applied - vc.refunded,
    'journal_ref', (select ref from journals where id = vc.journal_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('account_name', private.account_name(vc.org_id, l.account_code),
        'item_name', (select name from items where id = l.item_id)) order by l.line_no), '[]'::jsonb) from vendor_credit_lines l where l.credit_id = vc.id),
    'used_on', (select coalesce(jsonb_agg(jsonb_build_object('bill_id', bp.bill_id, 'number', b.number, 'amount', bp.gross, 'at', bp.paid_at) order by bp.paid_at), '[]'::jsonb)
      from bill_payments bp join bills b on b.id = bp.bill_id where bp.vendor_credit_id = vc.id and bp.status = 'paid'))
  from vendor_credits vc where vc.id = p_credit
$$;

-- Uses part of a supplier credit against one of their bills. Both sit in payables for the same supplier, so no journal
-- is needed; the bill's withholding tax falls with the value the credit takes off it.
create or replace function private.use_vendor_credit(p_credit uuid, p_bill uuid, p_amount numeric, m public.members) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare vc public.vendor_credits; b public.bills; v_due numeric; v_take numeric; v_net_off numeric; v_withheld numeric;
begin
  select * into vc from vendor_credits where id = p_credit for update;
  select * into b from bills where id = p_bill for update;
  if b.vendor_id <> vc.vendor_id then raise exception '% is not from the same supplier.', b.number; end if;
  if b.status not in ('approved', 'partially_paid') then return 0; end if;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  v_take := least(greatest(v_due, 0), vc.total - vc.applied - vc.refunded, coalesce(p_amount, vc.total));
  if v_take <= 0 then return 0; end if;
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, paid_at, reference, journal_id, created_by, vendor_credit_id)
  values (b.org_id, b.id, 'credit_note', 'paid', v_take, 0, v_take, now(), vc.number || coalesce(' · ' || vc.vendor_ref, ''), vc.journal_id, m.id, vc.id);
  -- WHT is due on what is finally paid for the supply: the credit's share of the bill comes off the expected WHT.
  if b.wht_expected > 0 and b.total > 0 then
    v_net_off := round(v_take * b.subtotal / b.total, 2);
    select coalesce(sum(wht), 0) into v_withheld from bill_payments where bill_id = b.id and status in ('paid', 'processing');
    update bills set wht_expected = greatest(round(wht_expected - v_net_off * wht_rate, 2), v_withheld, 0) where id = b.id;
  end if;
  update vendor_credits set applied = applied + v_take, status = case when applied + v_take + refunded >= total - 0.004 then 'used' else 'open' end where id = vc.id;
  perform private.refresh_bill(b.id);
  return v_take;
end $$;

-- p: {bill_id | vendor_id, vendor_ref, credit_date, reason, document_path,
--     lines:[{bill_line_id | account_code + vat_treatment, description, amount (with VAT), item_id, qty (selling units), location_id}]}
create or replace function public.record_vendor_credit(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; b public.bills; v public.vendors; vc public.vendor_credits; x jsonb; bl public.bill_lines; v_no int := 0;
  v_amt numeric; v_vat numeric; v_net numeric; v_code text; v_treat text; v_left numeric; v_jl jsonb := '[]'::jsonb; v_vat_total numeric := 0; v_total numeric := 0;
  v_item public.items; v_qty numeric; v_loc uuid; v_wac numeric; v_cost numeric; v_avail numeric; v_alloc jsonb; j public.journals; v_day date; v_desc text;
  v_inv boolean; fa public.fixed_assets; v_stock jsonb := '[]'::jsonb; s jsonb; v_recov boolean;
begin
  m := private.require(p_org, 'keep_books');
  select * into o from orgs where id = p_org;
  if nullif(p->>'bill_id', '') is not null then
    select * into b from bills where id = (p->>'bill_id')::uuid and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status not in ('approved', 'partially_paid', 'paid') then raise exception '% is %; only an approved bill takes a credit note.', b.number, b.status; end if;
    select * into v from vendors where id = b.vendor_id;
  else
    select * into v from vendors where id = nullif(p->>'vendor_id', '')::uuid and org_id = p_org;
    if not found then raise exception 'Choose the supplier.'; end if;
  end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Give the reason for the credit note.'; end if;
  v_day := coalesce(nullif(p->>'credit_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A credit note cannot be dated in the future.'; end if;
  if b.id is not null and v_day < b.bill_date then raise exception 'The credit note is dated before % itself.', b.number; end if;
  perform private.require_open_day(p_org, v_day);
  if nullif(trim(p->>'vendor_ref'), '') is not null and exists (select 1 from vendor_credits where org_id = p_org and vendor_id = v.id
      and lower(vendor_ref) = lower(trim(p->>'vendor_ref')) and status <> 'void') then
    raise exception 'Credit note % from % is already recorded.', trim(p->>'vendor_ref'), v.name;
  end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add what the credit note is for.'; end if;
  insert into vendor_credits (org_id, number, vendor_id, bill_id, vendor_ref, credit_date, reason, document_path, created_by)
  values (p_org, 'VCN-' || lpad(private.next_no(p_org, 'VCN', 1)::text, 4, '0'), v.id, b.id, nullif(trim(p->>'vendor_ref'), ''), v_day, trim(p->>'reason'),
    nullif(p->>'document_path', ''), m.id)
  returning * into vc;
  for x in select * from jsonb_array_elements(p->'lines') loop
    v_amt := round(coalesce(private.num(x->>'amount'), 0), 2);
    continue when v_amt <= 0 and coalesce(private.num(x->>'qty'), 0) <= 0;
    v_no := v_no + 1;
    bl := null; v_item := null; v_qty := null; v_loc := null; v_cost := null;
    if nullif(x->>'bill_line_id', '') is not null then
      select * into bl from bill_lines where id = (x->>'bill_line_id')::uuid and bill_id = b.id;
      if not found then raise exception 'Line %: that line is not on %.', v_no, b.number; end if;
      v_left := private.bill_line_creditable(bl.id);
      if v_amt > v_left + 0.004 then raise exception 'Line %: only % can still be credited on "%".', v_no, to_char(v_left, 'FM999,999,999,990.00'), bl.description; end if;
      v_code := bl.account_code; v_recov := bl.vat_recoverable;
      v_vat := case when bl.gross = 0 then 0 else round(v_amt * bl.vat / bl.gross, 2) end;
      v_desc := coalesce(nullif(trim(x->>'description'), ''), bl.description);
    else
      v_code := coalesce(nullif(trim(x->>'account_code'), ''), case when b.id is not null then (select account_code from bill_lines where bill_id = b.id order by line_no limit 1) end);
      if v_code is null or not private.bill_account_ok(p_org, v_code) then raise exception 'Line %: choose the account the credit reduces.', v_no; end if;
      v_treat := coalesce(nullif(x->>'vat_treatment', ''), case when coalesce(b.vat_charged, v.vat_registered, true) then 'standard' else 'none' end);
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_vat := case when v_treat = 'standard' then round(v_amt * 0.075 / 1.075, 2) else 0 end;
      v_recov := o.vat_registered;
      v_desc := coalesce(nullif(trim(x->>'description'), ''), 'Credit from ' || v.name);
    end if;
    v_net := v_amt - case when v_recov then v_vat else 0 end;
    if not v_recov then v_vat := 0; end if;
    v_inv := v_code ~ '^120[1-7]' or v_code = private.acct(p_org, 'inventory');
    -- Goods going back to the supplier leave stock at what they cost us; what the supplier credits beyond that cost (or
    -- short of it) is a purchase return.
    if nullif(x->>'item_id', '') is not null and coalesce(private.num(x->>'qty'), 0) > 0 then
      select * into v_item from items where id = (x->>'item_id')::uuid and org_id = p_org;
      if not found then raise exception 'Line %: item not found.', v_no; end if;
      v_qty := round(private.num(x->>'qty'), 3);
      v_loc := coalesce(nullif(x->>'location_id', '')::uuid, bl.location_id, (select id from locations where org_id = p_org order by created_at limit 1));
      if not exists (select 1 from locations where id = v_loc and org_id = p_org) then raise exception 'Line %: unknown branch.', v_no; end if;
      select coalesce(qty, 0) into v_avail from stock_levels where item_id = v_item.id and location_id = v_loc;
      if coalesce(v_avail, 0) < v_qty - 0.0005 then
        raise exception 'Line %: only % % of % at that branch.', v_no, private.fmt_qty(coalesce(v_avail, 0)), v_item.selling_unit, v_item.name;
      end if;
      select wac into v_wac from item_costs where item_id = v_item.id;
      v_cost := round(v_qty * coalesce(v_wac, 0), 2);
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.inv_acct(v_item.id), 'credit', v_cost, 'location_id', v_loc, 'item_id', v_item.id,
        'memo', 'Returned to ' || v.name || ' · ' || v_item.name, 'doc_type', 'vendor_credit', 'doc_id', vc.id));
      if v_net - v_cost <> 0 then
        v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'purchase_returns'),
          case when v_net > v_cost then 'credit' else 'debit' end, abs(v_net - v_cost), 'location_id', v_loc, 'memo', 'Price difference on goods returned · ' || v_item.name,
          'doc_type', 'vendor_credit', 'doc_id', vc.id));
      end if;
      v_stock := v_stock || jsonb_build_array(jsonb_build_object('item_id', v_item.id, 'qty', v_qty, 'location_id', v_loc, 'wac', coalesce(v_wac, 0), 'cost', v_cost));
      v_desc := coalesce(nullif(trim(x->>'description'), ''), v_item.name || ' returned');
    elsif v_inv then
      -- Stock cannot lose value without units leaving it: an allowance on stock bought is a purchase return.
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'purchase_returns'), 'credit', v_net, 'memo', v_desc, 'doc_type', 'vendor_credit', 'doc_id', vc.id));
    else
      if exists (select 1 from asset_classes where cost_account = v_code) then
        select * into fa from fixed_assets where bill_line_id = bl.id and status <> 'rejected' limit 1;
        if fa.id is not null and fa.status = 'active' then
          raise exception 'Line %: % is already in use. Correct its cost from the asset register instead.', v_no, fa.number;
        elsif fa.id is not null then
          update fixed_assets set cost = greatest(cost - v_net, 0), residual = least(residual, greatest(cost - v_net, 0)) where id = fa.id;
        end if;
      end if;
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_code, 'credit', v_net, 'memo', v_desc, 'doc_type', 'vendor_credit', 'doc_id', vc.id,
        'location_id', bl.location_id));
    end if;
    insert into vendor_credit_lines (credit_id, org_id, line_no, description, account_code, bill_line_id, item_id, qty, location_id, net, vat, gross, stock_cost)
    values (vc.id, p_org, v_no, left(v_desc, 300), case when v_item.id is not null then private.inv_acct(v_item.id) when v_inv then private.acct(p_org, 'purchase_returns') else v_code end,
      bl.id, v_item.id, v_qty, v_loc, v_net, v_vat, v_amt, v_cost);
    v_vat_total := v_vat_total + v_vat; v_total := v_total + v_amt;
  end loop;
  if v_total <= 0 then raise exception 'Enter the amount the supplier credits.'; end if;
  v_jl := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_total, 'party_type', 'vendor', 'party_id', v.id,
      'doc_type', 'vendor_credit', 'doc_id', vc.id, 'memo', vc.number || coalesce(' · ' || vc.vendor_ref, '') || coalesce(' for ' || b.number, '')))
    || v_jl
    || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', v_vat_total, 'memo', 'Input VAT given back · ' || v.name,
      'doc_type', 'vendor_credit', 'doc_id', vc.id));
  j := private.post_entry(p_org, 'Credit note ' || vc.number || ' from ' || v.name || coalesce(' for ' || b.number, '') || ' · ' || trim(p->>'reason'), 'bill', vc.id,
    m.id, m.id, v_jl, private.posting_time(p_org, v_day),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'vendor_credit', 'id', vc.id, 'ref', coalesce(vc.vendor_ref, vc.number), 'document', vc.document_path))));
  update vendor_credits set subtotal = v_total - v_vat_total, vat_total = v_vat_total, total = v_total, journal_id = j.id where id = vc.id returning * into vc;
  for s in select * from jsonb_array_elements(v_stock) loop
    v_alloc := private.consume_batches((s->>'item_id')::uuid, (s->>'location_id')::uuid, (s->>'qty')::numeric, v_day);
    perform private.add_movement(p_org, 'purchase_return', (s->>'item_id')::uuid, (s->>'location_id')::uuid, -(s->>'qty')::numeric, (s->>'wac')::numeric, null, j.id, m.id,
      'Credit note', private.posting_time(p_org, v_day), jsonb_build_object('note', vc.number || ' · returned to ' || v.name, 'reason', 'Returned to supplier',
        'batch_id', v_alloc->0->>'batch_id'));
  end loop;
  if b.id is not null then perform private.use_vendor_credit(vc.id, b.id, null, m); end if;
  return private.vendor_credit_json(vc.id);
end $$;

-- What is left of a supplier credit: used against another of their bills, or paid back into a bank account.
create or replace function public.use_vendor_credit(p_credit uuid, p_bill uuid, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare vc public.vendor_credits; m public.members; v_take numeric;
begin
  select * into vc from vendor_credits where id = p_credit;
  if not found then raise exception 'Credit note not found.'; end if;
  m := private.require(vc.org_id, 'keep_books');
  if vc.status <> 'open' then raise exception '% is already used.', vc.number; end if;
  v_take := private.use_vendor_credit(vc.id, p_bill, p_amount, m);
  if v_take <= 0 then raise exception 'Nothing is owed on that bill.'; end if;
  return private.vendor_credit_json(vc.id);
end $$;

-- p: {bank_account_id, amount, received_at, reference}
create or replace function public.refund_vendor_credit(p_credit uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare vc public.vendor_credits; m public.members; ba public.bank_accounts; v_amt numeric; v_at timestamptz; v_name text;
begin
  select * into vc from vendor_credits where id = p_credit for update;
  if not found then raise exception 'Credit note not found.'; end if;
  m := private.require(vc.org_id, 'keep_books');
  if vc.status <> 'open' then raise exception '% is already used.', vc.number; end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = vc.org_id and active;
  if not found then raise exception 'Choose the account the money came into.'; end if;
  v_amt := round(coalesce(private.num(p->>'amount'), vc.total - vc.applied - vc.refunded), 2);
  if v_amt <= 0 or v_amt > vc.total - vc.applied - vc.refunded + 0.004 then
    raise exception 'Up to % is left on %.', to_char(vc.total - vc.applied - vc.refunded, 'FM999,999,999,990.00'), vc.number;
  end if;
  v_at := least(coalesce(nullif(p->>'received_at', '')::timestamptz, now()), now());
  perform private.require_open_day(vc.org_id, private.local_day(vc.org_id, v_at));
  select name into v_name from vendors where id = vc.vendor_id;
  perform private.post_entry(vc.org_id, 'Refund from ' || v_name || ' · ' || vc.number, 'bill_payment', vc.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', ba.ledger_code, 'debit', v_amt, 'memo', 'Refund · ' || vc.number || coalesce(' · ' || nullif(trim(p->>'reference'), ''), '')),
      jsonb_build_object('code', private.acct(vc.org_id, 'payables'), 'credit', v_amt, 'party_type', 'vendor', 'party_id', vc.vendor_id,
        'doc_type', 'vendor_credit', 'doc_id', vc.id, 'memo', 'Refund of ' || vc.number)), v_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p->>'reference'), ''), 'by', m.display_name))));
  update vendor_credits set refunded = refunded + v_amt, status = case when applied + refunded + v_amt >= total - 0.004 then 'used' else 'open' end where id = vc.id;
  return private.vendor_credit_json(vc.id);
end $$;

create or replace function public.get_vendor_credits(p_org uuid, p_vendor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see supplier credit notes.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(private.vendor_credit_json(id) order by credit_date desc, number desc), '[]'::jsonb)
    from vendor_credits where org_id = p_org and (p_vendor is null or vendor_id = p_vendor));
end $$;

-- The bill shows its credit notes and what is creditable on each line.
create or replace function private.bill_json(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(b) || jsonb_build_object(
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'bank_code', v.bank_code, 'bank_name', v.bank_name,
        'account_number', v.account_number, 'account_name', v.account_name, 'wht_category', v.wht_category) from vendors v where v.id = b.vendor_id),
    'balance', case when b.status in ('approved', 'partially_paid') then b.total - b.amount_paid else 0 end,
    'in_progress', (select coalesce(sum(gross), 0) from bill_payments where bill_id = b.id and status = 'processing'),
    'overdue_days', case when b.status in ('approved', 'partially_paid') then greatest(private.local_day(b.org_id, now()) - b.due_date, 0) end,
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('account_name', private.account_name(b.org_id, l.account_code),
        'creditable', private.bill_line_creditable(l.id)) order by l.line_no), '[]'::jsonb)
              from bill_lines l where l.bill_id = b.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' || jsonb_build_object('payout_number', (select number from payouts where id = p.payout_id),
        'payout_status', (select status from payouts where id = p.payout_id)) order by p.paid_at), '[]'::jsonb) from bill_payments p where p.bill_id = b.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', vc.id, 'number', vc.number, 'vendor_ref', vc.vendor_ref, 'total', vc.total, 'credit_date', vc.credit_date,
        'reason', vc.reason, 'status', vc.status) order by vc.credit_date), '[]'::jsonb) from vendor_credits vc where vc.bill_id = b.id and vc.status <> 'void'),
    'supplier_credit', (select coalesce(sum(vc.total - vc.applied - vc.refunded), 0) from vendor_credits vc where vc.vendor_id = b.vendor_id and vc.status = 'open'),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'number', a.number, 'name', a.name, 'status', a.status)), '[]'::jsonb) from fixed_assets a where a.bill_id = b.id),
    'journal_ref', (select ref from journals where id = b.journal_id),
    'created_by_name', (select display_name from members where id = b.created_by),
    'approved_by_name', (select display_name from members where id = b.approved_by))
  from bills b where b.id = p_bill
$$;

-- The VAT return takes supplier credit notes off input VAT in the month they are dated.
create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  bi as (select coalesce(sum(bl.vat) filter (where bl.vat_recoverable), 0) vat, coalesce(sum(bl.net) filter (where bl.vat > 0), 0) base from bills b join bill_lines bl on bl.bill_id = b.id
         where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date between p_from and p_to),
  rc as (select coalesce(sum(input_vat), 0) vat, coalesce(sum(net) filter (where input_vat > 0), 0) base from receipts
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between p_from and p_to),
  vcr as (select coalesce(sum(vat_total), 0) vat, coalesce(sum(subtotal) filter (where vat_total > 0), 0) base from vendor_credits
          where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between p_from and p_to),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
    private.fr('Output VAT charged', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('Less credit notes from suppliers (taxable value ' || to_char(vcr.base, 'FM999,999,999,990.00') || ')', -vcr.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + rc.vat - vcr.vat, null, 'subtotal', 0),
    private.fr('VAT payable / (refundable) for the month', so.vat - bi.vat - rc.vat + vcr.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills, receipts and supplier credit notes', led.in_ledger, null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + rc.vat - vcr.vat - led.in_ledger), null, 'subtotal', 0))
  from so, bi, rc, vcr, led
$$;

-- ---------------------------------------------------------------------------
-- 3. Bank statements from any file, and the same transaction never twice
-- ---------------------------------------------------------------------------
alter table public.bank_imports add column if not exists source text not null default 'statement';
alter table public.bank_imports drop constraint if exists bank_imports_source_check;
alter table public.bank_imports add constraint bank_imports_source_check check (source in ('statement', 'excel', 'csv', 'pdf', 'feed'));
alter table public.bank_imports add column if not exists opening_balance numeric(16,2);
alter table public.bank_imports add column if not exists statement_account text;
alter table public.bank_imports add column if not exists bank_name text;
alter table public.bank_imports add column if not exists period_from date;
alter table public.bank_imports add column if not exists period_to date;
alter table public.bank_imports add column if not exists balance_check text check (balance_check in ('agrees', 'differs', 'unknown'));
alter table public.bank_imports add column if not exists already_in int not null default 0;
alter table public.bank_imports add column if not exists read_by text;
create index if not exists bank_lines_account_day on public.bank_lines(bank_account_id, line_date, amount);
create index if not exists bank_lines_provider_ref on public.bank_lines(bank_account_id, provider_ref) where provider_ref is not null;

-- The words that say who or what a narration is about, for comparing two copies of the same line (a statement and the
-- bank feed write it differently: "TRF FRM ADA OKORO/GTB" and "ADA OKORO TRANSFER").
create or replace function private.narr_words(p text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct w), '{}') from regexp_split_to_table(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]+', ' ', 'g')), ' ') w
  where length(w) >= 3 and w !~ '^(TRF|TRANSFER|FROM|FRM|NIP|FIP|MOB|USSD|POS|WEB|REF|NARR|PAYMENT|FOR|VIA|THE|AND|ACCOUNT|ACCT|CREDIT|DEBIT|PURCHASE)$'
$$;

create or replace function private.narr_like(a text, b text) returns boolean
language sql immutable set search_path = public, private as $$
  select case when cardinality(private.narr_words(a)) = 0 or cardinality(private.narr_words(b)) = 0 then upper(trim(coalesce(a, ''))) = upper(trim(coalesce(b, '')))
    else (select count(*) from unnest(private.narr_words(a)) x where x = any(private.narr_words(b)))::numeric
         / least(cardinality(private.narr_words(a)), cardinality(private.narr_words(b))) >= 0.5 end
$$;

-- A line already here from another source (the feed, or a statement of the same period in another format). With a
-- balance on both copies the balance decides. Otherwise a feed line and a statement line are the same when their
-- narrations share most of their words (the bank and Mono write them differently), and two statements' lines only when
-- they fall on the same day with the same narration, so a second ₦45,000 to the same person that day stays a second
-- payment. Each existing line answers for one new line only (p_claimed), so two identical charges on one day stay two.
create or replace function private.narr_key(p text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]+', '', 'g'))
$$;

create or replace function private.same_line(p_bank uuid, p_day date, p_amount numeric, p_balance numeric, p_desc text, p_import uuid, p_claimed uuid[],
  p_feed boolean) returns uuid
language sql stable security definer set search_path = public, private as $$
  select x.id from bank_lines x
  where x.bank_account_id = p_bank and x.amount = p_amount and x.line_date between p_day - 1 and p_day + 1
    and x.import_id is distinct from p_import and x.id <> all(coalesce(p_claimed, '{}'))
    and (not p_feed or x.source is distinct from 'api')
    and case when x.balance_after is not null and p_balance is not null then x.balance_after = p_balance
             when p_feed or x.source = 'api' then private.narr_like(x.description, p_desc)
             else x.line_date = p_day and private.narr_key(x.description) = private.narr_key(p_desc) end
  order by (x.balance_after is not null and x.balance_after = p_balance) desc, abs(x.line_date - p_day), x.created_at
  limit 1
$$;

-- p_lines: [{date, amount (+in / -out) | credit, debit, description, reference, balance, counterparty, counterparty_account}]
-- p_meta: {file_name, source (excel|csv|pdf), read_by (columns|ai), bank_name, account_number, period_from, period_to, opening_balance,
--          closing_balance, account_confirmed}
create or replace function public.import_bank_lines(p_org uuid, p_bank_account uuid, p_lines jsonb, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bank_accounts; imp public.bank_imports; x jsonb; v_day date; v_amt numeric; v_desc text; v_fp text; v_seen jsonb := '{}'::jsonb;
  v_n int; v_added int := 0; v_in int := 0; v_id uuid; v_last_bal numeric; v_last_day date; v_res jsonb; v_bal numeric; v_same uuid; v_claimed uuid[] := '{}';
  v_already int := 0; v_sum numeric := 0; v_open numeric := round(private.num(p_meta->>'opening_balance'), 2); v_close numeric := round(private.num(p_meta->>'closing_balance'), 2);
  v_stmt_acct text := nullif(regexp_replace(coalesce(p_meta->>'account_number', ''), '\D', '', 'g'), ''); v_src text := lower(coalesce(nullif(p_meta->>'source', ''), 'statement'));
begin
  m := private.require(p_org, 'keep_books');
  select * into b from bank_accounts where id = p_bank_account and org_id = p_org and active;
  if not found then raise exception 'Choose the bank account this statement is for.'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'The statement has no lines.'; end if;
  if jsonb_array_length(p_lines) > 5000 then raise exception 'Import up to 5,000 lines at a time.'; end if;
  if v_src not in ('statement', 'excel', 'csv', 'pdf') then v_src := 'statement'; end if;
  -- A statement for another account is stopped before it reaches the books.
  if v_stmt_acct is not null and length(v_stmt_acct) >= 6 and b.account_number is not null and length(regexp_replace(b.account_number, '\D', '', 'g')) >= 6
     and right(v_stmt_acct, 4) <> right(regexp_replace(b.account_number, '\D', '', 'g'), 4) and not coalesce((p_meta->>'account_confirmed')::boolean, false) then
    raise exception 'This statement is for account ending %, not % (ending %). Choose the right account.', right(v_stmt_acct, 4), b.name,
      right(regexp_replace(b.account_number, '\D', '', 'g'), 4);
  end if;
  insert into bank_imports (org_id, bank_account_id, file_name, lines_in_file, created_by, source, opening_balance, statement_account, bank_name, period_from, period_to, read_by)
  values (p_org, b.id, left(p_meta->>'file_name', 200), jsonb_array_length(p_lines), m.id, v_src, v_open, v_stmt_acct, left(nullif(trim(p_meta->>'bank_name'), ''), 120),
    private.date_or_null(p_meta->>'period_from'), private.date_or_null(p_meta->>'period_to'), left(nullif(p_meta->>'read_by', ''), 20))
  returning * into imp;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_in := v_in + 1;
    v_day := private.date_or_null(x->>'date');
    v_amt := coalesce(private.num(x->>'amount'), coalesce(private.num(x->>'credit'), 0) - coalesce(private.num(x->>'debit'), 0));
    v_desc := left(regexp_replace(coalesce(x->>'description', ''), '\s+', ' ', 'g'), 500);
    v_bal := round(private.num(x->>'balance'), 2);
    if v_day is null then raise exception 'Line %: the date is not readable.', v_in; end if;
    continue when coalesce(round(v_amt, 2), 0) = 0;
    v_amt := round(v_amt, 2);
    v_sum := v_sum + v_amt;
    if v_bal is not null and (v_last_day is null or v_day >= v_last_day) then v_last_bal := v_bal; v_last_day := v_day; end if;
    -- The same line twice in one statement is real (two SMS charges a day); the same line in two overlapping statements is not.
    v_fp := md5(b.id::text || '|' || v_day || '|' || v_amt || '|' || coalesce(upper(trim(x->>'reference')), '') || '|' || upper(v_desc));
    v_n := coalesce((v_seen->>v_fp)::int, 0) + 1;
    v_seen := jsonb_set(v_seen, array[v_fp], to_jsonb(v_n));
    if exists (select 1 from bank_lines where bank_account_id = b.id and fingerprint = v_fp || ':' || v_n) then continue; end if;
    -- Already here from the bank feed, or from this statement in another format.
    v_same := private.same_line(b.id, v_day, v_amt, v_bal, v_desc, imp.id, v_claimed, false);
    if v_same is not null then
      v_claimed := v_claimed || v_same; v_already := v_already + 1;
      update bank_lines set balance_after = coalesce(balance_after, v_bal), reference = coalesce(reference, nullif(trim(x->>'reference'), '')) where id = v_same;
      continue;
    end if;
    insert into bank_lines (org_id, bank_account_id, line_date, amount, balance_after, description, reference, counterparty, counterparty_account, source, import_id, fingerprint)
    values (p_org, b.id, v_day, v_amt, v_bal, v_desc, nullif(trim(x->>'reference'), ''), nullif(trim(x->>'counterparty'), ''),
      nullif(trim(x->>'counterparty_account'), ''), 'statement', imp.id, v_fp || ':' || v_n)
    on conflict do nothing returning id into v_id;
    if v_id is not null then v_added := v_added + 1; end if;
  end loop;
  update bank_imports set lines_added = v_added, already_in = v_already,
    from_date = coalesce((select min(line_date) from bank_lines where import_id = imp.id), period_from),
    to_date = coalesce((select max(line_date) from bank_lines where import_id = imp.id), period_to),
    closing_balance = coalesce(v_close, v_last_bal),
    balance_check = case when v_open is null or coalesce(v_close, v_last_bal) is null then 'unknown'
                         when abs(v_open + v_sum - coalesce(v_close, v_last_bal)) < 0.01 then 'agrees' else 'differs' end
  where id = imp.id returning * into imp;
  if imp.closing_balance is not null and coalesce(imp.period_to, imp.to_date) is not null then
    update bank_accounts set anchor_balance = imp.closing_balance, anchor_at = private.line_time(p_org, coalesce(imp.period_to, imp.to_date)) + interval '11 hours 59 minutes', anchor_source = 'statement'
    where id = b.id and (anchor_at is null or anchor_at <= private.line_time(p_org, coalesce(imp.period_to, imp.to_date)) + interval '11 hours 59 minutes');
  end if;
  v_res := private.run_matching(p_org, b.id);
  return jsonb_build_object('import_id', imp.id, 'in_file', v_in, 'added', v_added, 'duplicates', v_in - v_added - v_already, 'already_in', v_already,
    'balance_check', imp.balance_check, 'movement', v_sum) || v_res;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Bank feeds (Mono Connect)
-- ---------------------------------------------------------------------------
-- One Counta bank account per linked account; a linked account belongs to one business.
create unique index if not exists bank_accounts_feed on public.bank_accounts(provider, provider_ref) where provider = 'mono' and provider_ref is not null;

-- Who may link a bank account, and what Mono needs to know about the business. Called with the person's own token.
create or replace function public.bank_feed_context(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, 'keep_books');
  select * into o from orgs where id = p_org;
  return jsonb_build_object('org_id', o.id, 'org_name', o.name, 'member_id', m.id, 'email', coalesce(nullif(o.email, ''), (select email from auth.users where id = m.user_id)),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'account_number', b.account_number, 'bank_name', b.bank_name, 'provider', b.provider,
        'provider_ref', b.provider_ref) order by b.name), '[]'::jsonb) from bank_accounts b where b.org_id = p_org and b.active and b.kind = 'bank'));
end $$;

-- d: {mono_id, institution:{name, bank_code, type}, account_number, account_name, currency, balance (naira), data_status, auth_method}
-- p_bank_account: the Counta account to feed, or null to use the one with the same account number (or open a new one).
create or replace function public.svc_feed_link(p_org uuid, p_member uuid, p_bank_account uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; m public.members; v_num text := nullif(regexp_replace(coalesce(d->>'account_number', ''), '\D', '', 'g'), '');
  v_bank text := nullif(trim(d->'institution'->>'name'), ''); v_meta jsonb;
begin
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if not found then raise exception 'You are not a member of this business.'; end if;
  if upper(coalesce(nullif(d->>'currency', ''), 'NGN')) <> 'NGN' then raise exception 'Only naira accounts can be fed into the books for now.'; end if;
  if exists (select 1 from bank_accounts where provider = 'mono' and provider_ref = d->>'mono_id' and org_id <> p_org) then
    raise exception 'That bank account is already linked to another business.';
  end if;
  select * into b from bank_accounts where provider = 'mono' and provider_ref = d->>'mono_id' and org_id = p_org;
  if b.id is null and p_bank_account is not null then
    select * into b from bank_accounts where id = p_bank_account and org_id = p_org and active and kind = 'bank';
    if not found then raise exception 'Choose one of the business''s bank accounts.'; end if;
    if b.provider = 'mono' and b.provider_ref is distinct from d->>'mono_id' then raise exception '% is already linked to another bank login. Unlink it first.', b.name; end if;
    if v_num is not null and b.account_number is not null and right(regexp_replace(b.account_number, '\D', '', 'g'), 4) <> right(v_num, 4) then
      raise exception 'The bank returned account ending %, but % is account ending %.', right(v_num, 4), b.name, right(regexp_replace(b.account_number, '\D', '', 'g'), 4);
    end if;
  end if;
  if b.id is null and v_num is not null then
    select * into b from bank_accounts where org_id = p_org and active and kind = 'bank' and regexp_replace(coalesce(account_number, ''), '\D', '', 'g') = v_num
      and provider in ('manual', 'statement') limit 1;
  end if;
  v_meta := jsonb_build_object('institution', d->'institution', 'account_name', d->>'account_name', 'data_status', d->>'data_status', 'auth_method', d->>'auth_method',
    'linked_at', now(), 'linked_by', p_member, 'balance', round(private.num(d->>'balance'), 2), 'balance_at', now(), 'reauth_required', false);
  if b.id is null then
    b := private.open_bank_account(p_org, 'bank', coalesce(v_bank, 'Bank') || coalesce(' ' || right(v_num, 4), ''),
      jsonb_build_object('bank_name', v_bank, 'bank_code', d->'institution'->>'bank_code', 'account_number', v_num, 'account_name', d->>'account_name',
        'provider', 'mono', 'provider_ref', d->>'mono_id', 'provider_meta', v_meta), p_member);
  else
    update bank_accounts set provider = 'mono', provider_ref = d->>'mono_id', provider_meta = coalesce(provider_meta, '{}'::jsonb) || v_meta,
      bank_name = coalesce(bank_name, v_bank), account_number = coalesce(account_number, v_num), account_name = coalesce(account_name, d->>'account_name'),
      bank_code = coalesce(bank_code, d->'institution'->>'bank_code')
    where id = b.id returning * into b;
  end if;
  return to_jsonb(b) - 'provider_meta' || jsonb_build_object('feed', private.feed_json(b.id));
end $$;

create or replace function private.feed_json(p_bank_account uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when b.provider = 'mono' then jsonb_build_object('provider', 'mono', 'linked', true,
    'institution', b.provider_meta->'institution'->>'name', 'data_status', b.provider_meta->>'data_status',
    'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date',
    'balance', (b.provider_meta->>'balance')::numeric, 'balance_at', b.provider_meta->>'balance_at',
    'reauth_required', coalesce((b.provider_meta->>'reauth_required')::boolean, false), 'last_error', b.provider_meta->>'last_error',
    'lines', (select count(*) from bank_lines where bank_account_id = b.id and source = 'api'))
    else jsonb_build_object('linked', false) end
  from bank_accounts b where b.id = p_bank_account
$$;

-- The accounts the feed should fetch for, oldest fetch first. p_org limits it to one business.
create or replace function public.svc_feed_accounts(p_org uuid default null) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'org_id', b.org_id, 'mono_id', b.provider_ref, 'name', b.name,
      'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date',
      'linked_at', b.provider_meta->>'linked_at', 'books_start', (select books_start from orgs where id = b.org_id),
      'reauth_required', coalesce((b.provider_meta->>'reauth_required')::boolean, false))
    order by coalesce(b.provider_meta->>'last_synced_at', '') asc), '[]'::jsonb)
  from bank_accounts b where b.provider = 'mono' and b.provider_ref is not null and b.active and (p_org is null or b.org_id = p_org)
$$;

-- d: {data_status, reauth_required, last_error, balance, institution, ...} merged into the account's feed state.
create or replace function public.svc_feed_status(p_mono_id text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  update bank_accounts set provider_meta = coalesce(provider_meta, '{}'::jsonb) || jsonb_strip_nulls(d)
  where provider = 'mono' and provider_ref = p_mono_id returning * into b;
  if not found then return null; end if;
  if coalesce((d->>'reauth_required')::boolean, false) and not coalesce((select (provider_meta->>'reauth_noticed')::boolean from bank_accounts where id = b.id), false) then
    perform private.notify_perm(b.org_id, 'keep_books', 'banking', 'Sign in to ' || coalesce(b.bank_name, 'the bank') || ' again',
      b.name || ': the bank asks for your login again before it shares new transactions.', '/accounting/banking', 'feed-' || b.id, null);
    update bank_accounts set provider_meta = provider_meta || '{"reauth_noticed": true}'::jsonb where id = b.id;
  elsif d ? 'reauth_required' and not coalesce((d->>'reauth_required')::boolean, false) then
    update bank_accounts set provider_meta = provider_meta - 'reauth_noticed' where id = b.id;
  end if;
  return jsonb_build_object('bank_account_id', b.id, 'org_id', b.org_id);
end $$;

-- Transactions from the feed: [{id, date, amount (+in / -out, naira), narration, balance (naira), category}]. A line the
-- feed sends again is skipped; one a statement already brought in takes the feed's id instead of coming in twice.
create or replace function public.svc_feed_import(p_bank_account uuid, p_lines jsonb, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; imp public.bank_imports; x jsonb; v_day date; v_amt numeric; v_id uuid; v_added int := 0; v_skip int := 0; v_merged int := 0;
  v_claimed uuid[] := '{}'; v_same uuid; v_ref text; v_bal numeric; v_last date; v_res jsonb := '{}'::jsonb; v_desc text;
begin
  select * into b from bank_accounts where id = p_bank_account and active;
  if not found or b.provider <> 'mono' then raise exception 'That account is not linked to a bank feed.'; end if;
  if jsonb_typeof(p_lines) = 'array' and jsonb_array_length(p_lines) > 0 then
    insert into bank_imports (org_id, bank_account_id, file_name, lines_in_file, source, read_by)
    values (b.org_id, b.id, 'Bank feed · ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon YYYY HH24:MI'), jsonb_array_length(p_lines), 'feed', 'mono')
    returning * into imp;
    for x in select * from jsonb_array_elements(p_lines) order by value->>'date', value->>'id' loop
      v_ref := nullif(x->>'id', '');
      v_day := private.date_or_null(left(x->>'date', 10));
      v_amt := round(private.num(x->>'amount'), 2);
      v_bal := round(private.num(x->>'balance'), 2);
      v_desc := left(regexp_replace(coalesce(x->>'narration', ''), '\s+', ' ', 'g'), 500);
      continue when v_ref is null or v_day is null or coalesce(v_amt, 0) = 0;
      if exists (select 1 from bank_lines where bank_account_id = b.id and provider_ref = v_ref) then v_skip := v_skip + 1; continue; end if;
      v_last := greatest(v_last, v_day);
      v_same := private.same_line(b.id, v_day, v_amt, v_bal, v_desc, imp.id, v_claimed, true);
      if v_same is not null then
        update bank_lines set provider_ref = v_ref where id = v_same;
        v_claimed := v_claimed || v_same; v_merged := v_merged + 1;
        continue;
      end if;
      insert into bank_lines (org_id, bank_account_id, line_date, amount, balance_after, description, source, provider_ref, import_id, fingerprint, note)
      values (b.org_id, b.id, v_day, v_amt, v_bal, v_desc, 'api', v_ref, imp.id, 'feed:' || v_ref, nullif(x->>'category', ''))
      on conflict do nothing returning id into v_id;
      if v_id is not null then v_added := v_added + 1; end if;
    end loop;
    update bank_imports set lines_added = v_added, already_in = v_merged + v_skip, from_date = (select min(line_date) from bank_lines where import_id = imp.id),
      to_date = (select max(line_date) from bank_lines where import_id = imp.id) where id = imp.id;
  end if;
  update bank_accounts set provider_meta = (coalesce(provider_meta, '{}'::jsonb) - 'last_error' - 'reauth_noticed') || jsonb_strip_nulls(jsonb_build_object(
      'last_synced_at', now(), 'last_line_date', greatest(v_last, nullif(provider_meta->>'last_line_date', '')::date),
      'balance', round(private.num(p_meta->>'balance'), 2), 'balance_at', case when private.num(p_meta->>'balance') is not null then now() end,
      'data_status', p_meta->>'data_status', 'reauth_required', false))
  where id = b.id returning * into b;
  if private.num(p_meta->>'balance') is not null then
    update bank_accounts set anchor_balance = round(private.num(p_meta->>'balance'), 2), anchor_at = now(), anchor_source = 'feed' where id = b.id;
  end if;
  if v_added > 0 then v_res := private.run_matching(b.org_id, b.id); end if;
  return jsonb_build_object('bank_account_id', b.id, 'added', v_added, 'already_in', v_merged, 'skipped', v_skip) || v_res;
end $$;

-- Stops the feed. Lines already brought in stay; statements can be uploaded again.
create or replace function public.svc_feed_unlink(p_bank_account uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  update bank_accounts set provider = 'manual', provider_meta = coalesce(provider_meta, '{}'::jsonb) || jsonb_build_object('unlinked_at', now(), 'unlinked_reason', p_reason,
      'former_feed', provider_ref), provider_ref = null
  where id = p_bank_account and provider = 'mono' returning * into b;
  if not found then return null; end if;
  return to_jsonb(b) - 'provider_meta';
end $$;

-- The Counta account behind a feed, for the webhook.
create or replace function public.svc_feed_account(p_mono_id text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', b.id, 'org_id', b.org_id, 'mono_id', b.provider_ref, 'last_synced_at', b.provider_meta->>'last_synced_at',
    'last_line_date', b.provider_meta->>'last_line_date', 'linked_at', b.provider_meta->>'linked_at')
  from bank_accounts b where b.provider = 'mono' and b.provider_ref = p_mono_id and b.active
$$;

-- A person may run the feed for an account of their business (the edge function checks with their own token).
create or replace function public.bank_feed_account(p_bank_account uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  select * into b from bank_accounts where id = p_bank_account;
  if not found then raise exception 'Account not found.'; end if;
  perform private.require(b.org_id, 'keep_books');
  return jsonb_build_object('id', b.id, 'org_id', b.org_id, 'name', b.name, 'provider', b.provider, 'mono_id', case when b.provider = 'mono' then b.provider_ref end,
    'last_synced_at', b.provider_meta->>'last_synced_at', 'last_line_date', b.provider_meta->>'last_line_date', 'linked_at', b.provider_meta->>'linked_at',
    'books_start', (select books_start from orgs where id = b.org_id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Money paid straight into (or out of) the bank, matched to the document it settles
-- ---------------------------------------------------------------------------
-- Whether a narration names a document: INV-0042 as "INV-0042", "inv 42", "INV0042" or "Invoice no. 42".
create or replace function private.doc_in_text(p_number text, p_text text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_number ~ '^[A-Z]+-[0-9]+$' and ltrim(split_part(p_number, '-', 2), '0') <> ''
    and upper(coalesce(p_text, '')) ~ ('(^|[^A-Z0-9])(' || split_part(p_number, '-', 1) || case split_part(p_number, '-', 1) when 'INV' then '|INVOICE' when 'ORD' then '|ORDER' else '' end
      || ')[\s\-#:/.]*(NO\.?\s*)?0*' || ltrim(split_part(p_number, '-', 2), '0') || '([^0-9]|$)'), false)
$$;

-- Whether a narration carries the supplier's own invoice number (ADX/2026/044 as ADX2026044 or ADX-2026-044).
create or replace function private.ref_in_text(p_ref text, p_text text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(length(regexp_replace(upper(p_ref), '[^A-Z0-9]', '', 'g')) >= 4 and regexp_replace(upper(p_ref), '[^A-Z0-9]', '', 'g') ~ '[0-9]'
    and position(regexp_replace(upper(p_ref), '[^A-Z0-9]', '', 'g') in regexp_replace(upper(coalesce(p_text, '')), '[^A-Z0-9]', '', 'g')) > 0, false)
$$;

create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  select * into m from members where org_id = bl.org_id and role = 'owner' and status = 'active' order by created_at limit 1;

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- Short by withholding tax at a standard rate: the difference is the customer's WHT credit.
      v_rate := null;
      foreach v_rate in array array[0.02, 0.05, 0.10] loop
        exit when abs(round(v_due - round(s.subtotal * v_rate, 2), 2) - v_amt) < 0.005;
        v_rate := null;
      end loop;
      if v_rate is not null and v_amt < v_due - 0.004 then
        perform private.add_collection(bl.org_id, s.customer_id, v_due - v_amt, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', v_rate,
          'received_at', v_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[s.id]);
      end if;
      c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system',
        confidence = case when v_amt <= v_due + 0.004 then 1 else 0.9 end where id = bl.id;
      if v_amt > v_due + 0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'overpaid_invoice', 'bank_line', bl.id, s.customer_name || ' paid more than ' || s.number,
          'The extra is held as customer credit. Refund it or use it on their next invoice.', jsonb_build_object('sale_id', s.id, 'customer_id', s.customer_id), 0.9,
          'AR: payment names the invoice and exceeds what is owed', 'invoice_ref', 'info', v_amt - v_due, c.journal_id) on conflict do nothing;
      end if;
      return 'invoice_ref';
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names (Counta's number or the supplier's own invoice number).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text) or private.ref_in_text(bb2.vendor_ref, v_text))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected - bb.wht_withheld - coalesce((select sum(wht) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce(bb.wht_expected / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                      when v_amt < v_due - v_left_wht then round(v_amt / (1 - v_rate), 2) end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration paying open sales (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Exactly what is owed on one sale, or on all of them.
      select s2.id into r from sales s2 where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
        and s2.total - s2.amount_paid - s2.credited = v_amt order by s2.due_date limit 1;
      if r.id is not null or abs(v_due - v_amt) < 0.005 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', r.id is null), m, 'confirmed',
          case when r.id is not null then array[r.id] end);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'customer';
      end if;
      -- Short by withholding tax at a standard rate: the difference is a WHT credit (AR-03, TAX-03).
      foreach v_rate in array array[0.02, 0.05, 0.10] loop
        select s2.id, s2.total - s2.amount_paid - s2.credited due into r from sales s2 where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid')
          and s2.journal_id is not null and abs(round((s2.total - s2.amount_paid - s2.credited) - round(s2.subtotal * v_rate, 2), 2) - v_amt) < 0.005
        order by s2.due_date limit 1;
        if r.id is not null then
          perform private.add_collection(bl.org_id, v_cust.id, r.due - v_amt, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', v_rate,
            'received_at', v_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[r.id]);
          c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
            'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', false), m, 'confirmed', array[r.id]);
          update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_wht', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'customer_wht';
        end if;
      end loop;
      -- Paying part of what is owed: oldest first. Paying with nothing owed: held as an advance, flagged (AR rule).
      c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', case when v_due > 0 then 'Part payment matched from the bank statement'
          else 'No invoice open: held as customer credit' end, 'spread', true), m, 'confirmed', null);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = case when v_due > 0 then 'customer_part' else 'customer_advance' end,
        matched_by = 'system', confidence = case when v_due > 0 then 0.9 else 0.8 end where id = bl.id;
      if v_due <= 0 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
      end if;
      return case when v_due > 0 then 'customer_part' else 'customer_advance' end;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      for r in select bb2.*, bb2.total - bb2.amount_paid due, greatest(bb2.wht_expected - bb2.wht_withheld, 0) wht_left from bills bb2
          where bb2.vendor_id = v_vendor.id and bb2.status in ('approved', 'partially_paid') order by bb2.due_date loop
        v_gross := null;
        if abs(r.due - v_amt) < 0.005 then v_gross := r.due; v_wht := 0;
        elsif r.wht_left > 0 and abs(r.due - r.wht_left - v_amt) < 0.005 then v_gross := r.due; v_wht := r.wht_left;
        end if;
        if v_gross is not null then
          j := private.record_bill_payment(r.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
          update bank_lines set status = 'matched', journal_id = j.id, stage = 'vendor_bill', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'vendor_bill';
        end if;
      end loop;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    perform private.post_bank_line(bl.id, v_rule.account_code,
      case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
      null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named, but exactly one open invoice (or bill) is for this amount, as it stands or less a standard WHT rate:
  --   held in suspense and put to a person to confirm in one tap.
  if v_in then
    select count(*) into v_cnt from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid')
      and x.journal_id is not null and x.issue_date between bl.line_date - 180 and bl.line_date + 1
      and (abs(x.total - x.amount_paid - x.credited - v_amt) < 0.005
           or exists (select 1 from unnest(array[0.02, 0.05, 0.10]) w where abs(round(x.total - x.amount_paid - x.credited - round(x.subtotal * w, 2), 2) - v_amt) < 0.005));
    if v_cnt = 1 then
      select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid')
        and x.journal_id is not null and x.issue_date between bl.line_date - 180 and bl.line_date + 1
        and (abs(x.total - x.amount_paid - x.credited - v_amt) < 0.005
             or exists (select 1 from unnest(array[0.02, 0.05, 0.10]) w where abs(round(x.total - x.amount_paid - x.credited - round(x.subtotal * w, 2), 2) - v_amt) < 0.005));
      v_pid := private.suspend_line(bl.id, 'Payment for ' || s.number || '?',
        'Is this ₦' || to_char(v_amt, 'FM999,999,999,990.00') || ' from ' || s.customer_name || ' for ' || s.number || '? Confirm it, or say what it was.',
        jsonb_build_object('kind', 'invoice_match', 'sale_id', s.id, 'number', s.number, 'customer_id', s.customer_id, 'customer_name', s.customer_name,
          'party_type', 'customer', 'party_id', s.customer_id, 'account_code', private.acct(bl.org_id, 'receivables')),
        0.75, 'Only open invoice for this amount', 'invoice_amount');
      return 'invoice_amount';
    end if;
  else
    select count(*) into v_cnt from bills x where x.org_id = bl.org_id and x.status in ('approved', 'partially_paid') and x.bill_date <= bl.line_date + 1
      and (abs(x.total - x.amount_paid - v_amt) < 0.005 or (x.wht_expected - x.wht_withheld > 0 and abs(x.total - x.amount_paid - (x.wht_expected - x.wht_withheld) - v_amt) < 0.005));
    if v_cnt = 1 then
      select * into bb from bills x where x.org_id = bl.org_id and x.status in ('approved', 'partially_paid') and x.bill_date <= bl.line_date + 1
        and (abs(x.total - x.amount_paid - v_amt) < 0.005 or (x.wht_expected - x.wht_withheld > 0 and abs(x.total - x.amount_paid - (x.wht_expected - x.wht_withheld) - v_amt) < 0.005));
      v_pid := private.suspend_line(bl.id, 'Payment of ' || bb.number || '?',
        'Is this ₦' || to_char(v_amt, 'FM999,999,999,990.00') || ' paid to ' || (select name from vendors where id = bb.vendor_id) || ' for ' || bb.number
          || coalesce(' (their ' || bb.vendor_ref || ')', '') || '? Confirm it, or say what it was.',
        jsonb_build_object('kind', 'bill_match', 'bill_id', bb.id, 'number', bb.number, 'vendor_id', bb.vendor_id, 'vendor_name', (select name from vendors where id = bb.vendor_id),
          'party_type', 'vendor', 'party_id', bb.vendor_id, 'account_code', private.acct(bl.org_id, 'payables')),
        0.75, 'Only open bill for this amount', 'bill_amount');
      return 'bill_amount';
    end if;
  end if;
  return null;
end $$;

-- p: {action: 'approve'|'change'|'ignore'|'dismiss', account_code, party_type, party_id, remember, note}
-- A proposed invoice or bill match, approved, settles that document: the suspense entry is taken back and the payment
-- recorded against it, so the bank moves once and the receivable (or payable) falls.
create or replace function public.resolve_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; m public.members; bl public.bank_lines; v_code text; v_action text := coalesce(nullif(p->>'action', ''), 'approve'); j public.journals;
  b public.bank_accounts; v_amt numeric; v_party_type text := nullif(p->>'party_type', ''); v_party uuid := nullif(p->>'party_id', '')::uuid;
  s public.sales; bb public.bills; c public.collections; v_due numeric; v_rate numeric; v_gross numeric; v_left_wht numeric; v_at timestamptz;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(pr.org_id, 'keep_books');
  if pr.status not in ('pending', 'auto_posted', 'info') then raise exception 'This was already decided.'; end if;
  if v_action = 'dismiss' then
    if pr.status = 'pending' and pr.holding_journal_id is not null then raise exception 'Choose where this goes, or mark it as not a real transaction.'; end if;
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'dismissed');
  end if;
  if pr.source_type <> 'bank_line' then
    raise exception 'Open the % to decide it.', replace(pr.kind, '_', ' ');
  end if;
  select * into bl from bank_lines where id = pr.source_id for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  if v_action = 'ignore' then
    -- Not a real transaction (a duplicate or a reversed transfer on the statement): the suspense entry is taken back.
    if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Not a real transaction: ' || coalesce(p->>'note', ''), null); end if;
    if pr.status = 'auto_posted' and pr.journal_id is not null then perform private.reverse_entry(pr.journal_id, m.id, 'Not a real transaction', null); end if;
    update bank_lines set status = 'ignored', note = nullif(trim(p->>'note'), '') where id = bl.id;
    update ai_proposals set status = 'rejected', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'ignored');
  end if;
  v_at := private.line_time(pr.org_id, bl.line_date);
  -- Confirming the invoice or bill the matcher proposed.
  -- (Approving with the proposal's own account and party, as the generic answer form sends it, is the same yes.)
  if pr.status = 'pending' and pr.proposal->>'kind' in ('invoice_match', 'bill_match') and v_action = 'approve'
     and (nullif(p->>'account_code', '') is null or (p->>'account_code' = pr.proposal->>'account_code' and coalesce(p->>'party_id', pr.proposal->>'party_id') = pr.proposal->>'party_id')) then
    if pr.proposal->>'kind' = 'invoice_match' then
      select * into s from sales where id = (pr.proposal->>'sale_id')::uuid for update;
      if s.id is null or s.status not in ('open', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(s.number, 'The invoice'); end if;
      v_due := s.total - s.amount_paid - s.credited;
      if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Matched to ' || s.number, null); end if;
      v_rate := null;
      if v_amt < v_due - 0.004 then
        foreach v_rate in array array[0.02, 0.05, 0.10] loop
          exit when abs(round(v_due - round(s.subtotal * v_rate, 2), 2) - v_amt) < 0.005;
          v_rate := null;
        end loop;
        if v_rate is not null then
          perform private.add_collection(pr.org_id, s.customer_id, v_due - v_amt, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', v_rate,
            'received_at', v_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[s.id]);
        end if;
      end if;
      c := private.add_collection(pr.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person'), 'spread', false),
        m, 'confirmed', array[s.id]);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
      update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p, journal_id = c.journal_id where id = pr.id;
      return jsonb_build_object('status', 'approved', 'journal_ref', (select ref from journals where id = c.journal_id), 'settled', s.number);
    else
      select * into bb from bills where id = (pr.proposal->>'bill_id')::uuid for update;
      if bb.id is null or bb.status not in ('approved', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(bb.number, 'The bill'); end if;
      v_due := bb.total - bb.amount_paid;
      v_left_wht := greatest(bb.wht_expected - bb.wht_withheld, 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due when abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                      when v_amt < v_due then round(v_amt / (1 - coalesce(bb.wht_expected / nullif(bb.total, 0), 0)), 2) end;
      if v_gross is null then raise exception '% has only % left to pay.', bb.number, to_char(v_due, 'FM999,999,999,990.00'); end if;
      if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Matched to ' || bb.number, null); end if;
      j := private.record_bill_payment(bb.id, b.id, v_gross, greatest(v_gross - v_amt, 0), v_at, coalesce(bl.reference, left(bl.description, 60)), m);
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
      update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p, journal_id = j.id where id = pr.id;
      return jsonb_build_object('status', 'approved', 'journal_ref', j.ref, 'settled', bb.number);
    end if;
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), pr.proposal->>'account_code');
  if v_code is null or not private.postable(pr.org_id, v_code) or v_code = b.ledger_code then raise exception 'Choose the account this belongs to.'; end if;
  if v_code ~ '^(1101|1102)' and v_party_type is distinct from 'customer' then raise exception 'Say which customer.'; end if;
  if v_code ~ '^(2101|2102)' and v_party_type is distinct from 'vendor' then raise exception 'Say which vendor.'; end if;
  if v_code ~ '^(2201|1402|2202|1401)' then raise exception 'VAT and WHT come only from invoices and bills, not from bank lines.'; end if;
  if pr.status = 'pending' and pr.holding_journal_id is not null then
    -- Out of suspense into the account chosen.
    j := private.post_entry(pr.org_id, 'Confirmed: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      case when bl.amount > 0 then jsonb_build_array(
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'debit', v_amt, 'memo', 'Out of suspense'),
          jsonb_build_object('code', v_code, 'credit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description))
        else jsonb_build_array(
          jsonb_build_object('code', v_code, 'debit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description),
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'credit', v_amt, 'memo', 'Out of suspense')) end,
      v_at,
      jsonb_build_object('origin', 'manual', 'ai_confidence', pr.confidence, 'ai_proposal_id', pr.id,
        'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', p->>'note'))));
    update bank_lines set status = 'posted', stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code' then
    -- The agent posted it, a person says otherwise: move it.
    j := private.post_entry(pr.org_id, 'Corrected: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      private.reclass_pair(v_code, pr.proposal->>'account_code', case when bl.amount > 0 then -v_amt else v_amt end, null, null), now(),
      jsonb_build_object('origin', 'manual', 'ai_proposal_id', pr.id));
  end if;
  update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('account_code', v_code),
    journal_id = coalesce(j.id, journal_id) where id = pr.id;
  -- Learn the party for next time (CLS-05).
  if coalesce((p->>'remember')::boolean, false) and bl.party_key is not null then
    insert into entity_rules (org_id, party_key, direction, account_code, vendor_id, customer_id, note, source, created_by)
    values (pr.org_id, bl.party_key, case when bl.amount > 0 then 'in' else 'out' end, v_code,
      case when v_party_type = 'vendor' then v_party end, case when v_party_type = 'customer' then v_party end, nullif(trim(p->>'note'), ''), 'reviewer', m.id)
    on conflict (org_id, party_key, direction) do update set account_code = excluded.account_code, vendor_id = excluded.vendor_id, customer_id = excluded.customer_id,
      note = coalesce(excluded.note, entity_rules.note);
  end if;
  return jsonb_build_object('status', 'approved', 'journal_ref', j.ref);
end $$;

-- Banking shows each account's feed and each import's balance check.
create or replace function public.get_banking(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see bank accounts.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', (select coalesce(jsonb_agg(to_jsonb(b) - 'provider_meta' || jsonb_build_object(
        'book_balance', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = b.ledger_code),
        'unmatched', (select count(*) from bank_lines where bank_account_id = b.id and status = 'unmatched'),
        'questions', (select count(*) from bank_lines where bank_account_id = b.id and status = 'proposed'),
        'last_line', (select max(line_date) from bank_lines where bank_account_id = b.id),
        'feed', private.feed_json(b.id),
        'last_import', (select jsonb_build_object('file_name', i.file_name, 'source', i.source, 'created_at', i.created_at, 'from', coalesce(i.period_from, i.from_date),
            'to', coalesce(i.period_to, i.to_date), 'added', i.lines_added, 'balance_check', i.balance_check, 'closing_balance', i.closing_balance)
          from bank_imports i where i.bank_account_id = b.id and i.source <> 'feed' order by i.created_at desc limit 1),
        'last_reconciliation', (select jsonb_build_object('as_of', as_of, 'status', status, 'difference', difference) from bank_reconciliations
           where bank_account_id = b.id order by as_of desc limit 1)) order by b.kind, b.name), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active),
    'lines', (select coalesce(jsonb_agg(to_jsonb(x) - 'fingerprint' || jsonb_build_object('journal_ref', (select ref from journals where id = x.journal_id),
        'account_name', (select name from bank_accounts where id = x.bank_account_id)) order by x.line_date desc, x.created_at desc), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org order by line_date desc, created_at desc limit 1000) x),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'),
    'clearing', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9002'),
    'rules', (select coalesce(jsonb_agg(to_jsonb(r) order by r.hits desc), '[]'::jsonb) from entity_rules r where r.org_id = p_org));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Tax computation and capital allowances (Nigeria Tax Act 2025)
-- ---------------------------------------------------------------------------
-- The rules, effective-dated so the rule book can add or change one without new code. Rates are fractions.
create table if not exists public.tax_rules (
  key text not null,
  effective_from date not null,
  value numeric,
  label text not null,
  source text,
  primary key (key, effective_from)
);
alter table public.tax_rules enable row level security;
drop policy if exists tax_rules_read on public.tax_rules;
create policy tax_rules_read on public.tax_rules for select to authenticated using (true);

insert into public.tax_rules (key, effective_from, value, label, source) values
  ('cit_rate', '2026-01-01', 0.30, 'Companies income tax rate', 'NTA 2025 s.56'),
  ('small_company_rate', '2026-01-01', 0.00, 'Companies income tax rate for a small company', 'NTA 2025 s.56'),
  ('small_company_turnover', '2026-01-01', 100000000, 'Small company: gross turnover not above', 'NTA 2025 s.202'),
  ('small_company_fixed_assets', '2026-01-01', 250000000, 'Small company: total fixed assets not above', 'NTA 2025 s.202'),
  ('development_levy_rate', '2026-01-01', 0.04, 'Development levy on assessable profits (not small or non-resident companies)', 'NTA 2025 s.59'),
  ('met_rate', '2026-01-01', 0.15, 'Minimum effective tax rate', 'NTA 2025 s.57'),
  ('met_turnover', '2026-01-01', 50000000000, 'Minimum effective tax applies from aggregate turnover of', 'NTA 2025 s.57; NRS Information Circular 2026/01'),
  ('donations_cap', '2026-01-01', 0.10, 'Donations deductible up to this share of profit before the donation', 'NTA 2025'),
  ('rd_cap', '2026-01-01', 0.05, 'Research and development deductible up to this share of turnover', 'NTA 2025'),
  ('ca_retention', '2026-01-01', 0.01, 'Share of qualifying cost kept until the asset is disposed of', 'NTA 2025 First Schedule'),
  ('ca_restriction', '2026-01-01', 1.00, 'Share of assessable profit capital allowances may absorb in a year', 'NTA 2025 (no restriction)'),
  -- Annual allowance on cost, straight line. 10%: buildings, agricultural assets, masts and towers, heavy transport;
  -- 20%: plant, equipment, furniture and fittings; 25%: motor vehicles and other capital expenditure.
  ('ca_rate:1501', '2026-01-01', 0.00, 'Freehold land', 'Land does not qualify'),
  ('ca_rate:1502', '2026-01-01', 0.10, 'Non-industrial buildings', 'NTA 2025 First Schedule'),
  ('ca_rate:1503', '2026-01-01', 0.10, 'Industrial buildings', 'NTA 2025 First Schedule'),
  ('ca_rate:1504', '2026-01-01', 0.20, 'Plant', 'NTA 2025 First Schedule'),
  ('ca_rate:1505', '2026-01-01', 0.10, 'Ships, boats and yachts', 'NTA 2025 First Schedule (heavy transportation)'),
  ('ca_rate:1506', '2026-01-01', 0.20, 'Heavy equipment', 'NTA 2025 First Schedule'),
  ('ca_rate:1507', '2026-01-01', 0.10, 'Aircraft engines and fuselage', 'NTA 2025 First Schedule (heavy transportation)'),
  ('ca_rate:1508', '2026-01-01', 0.20, 'Aircraft and vessel furnishing', 'NTA 2025 First Schedule (furniture and fittings)'),
  ('ca_rate:1509', '2026-01-01', 0.10, 'Towers and cables', 'NTA 2025 First Schedule (masts)'),
  ('ca_rate:1510', '2026-01-01', 0.10, 'Trains and tracks', 'NTA 2025 First Schedule (heavy transportation)'),
  ('ca_rate:1511', '2026-01-01', 0.25, 'Motor vehicles', 'NTA 2025 First Schedule'),
  ('ca_rate:1512', '2026-01-01', 0.25, 'Buses and trucks', 'NTA 2025 First Schedule (motor vehicles)'),
  ('ca_rate:1513', '2026-01-01', 0.20, 'Tools and equipment', 'NTA 2025 First Schedule'),
  ('ca_rate:1514', '2026-01-01', 0.20, 'Office equipment', 'NTA 2025 First Schedule'),
  ('ca_rate:1515', '2026-01-01', 0.20, 'Medical equipment', 'NTA 2025 First Schedule'),
  ('ca_rate:1516', '2026-01-01', 0.20, 'Household equipment', 'NTA 2025 First Schedule'),
  ('ca_rate:1517', '2026-01-01', 0.20, 'Computer hardware', 'NTA 2025 First Schedule (equipment)'),
  ('ca_rate:1518', '2026-01-01', 0.20, 'Office fixtures', 'NTA 2025 First Schedule (furniture and fittings)'),
  ('ca_rate:1519', '2026-01-01', 0.20, 'Furniture and fittings', 'NTA 2025 First Schedule'),
  ('ca_rate:1520', '2026-01-01', 0.00, 'Assets under construction', 'No allowance until the asset is in use'),
  ('ca_rate:1521', '2026-01-01', 0.00, 'Capital work in progress', 'No allowance until the asset is in use'),
  ('ca_rate:1522', '2026-01-01', 0.10, 'Bearer plants', 'NTA 2025 First Schedule (agricultural)'),
  ('ca_rate:1523', '2026-01-01', 0.10, 'Biological assets', 'NTA 2025 First Schedule (agricultural)'),
  ('ca_rate:1524', '2026-01-01', null, 'Petroleum development costs', 'Hydrocarbon rules apply: set the rate from the rule book'),
  ('ca_rate:1525', '2026-01-01', 0.10, 'Distribution network', 'NTA 2025 First Schedule (infrastructure)'),
  ('ca_rate:1526', '2026-01-01', 0.10, 'Leasehold improvements', 'NTA 2025 First Schedule (buildings)'),
  ('ca_rate:1527', '2026-01-01', 0.25, 'Other property, plant and equipment', 'NTA 2025 First Schedule (other capital expenditure)')
on conflict (key, effective_from) do nothing;

-- The rule in force on a day; the earliest rule stands for days before the rule book begins.
create or replace function private.tax_rule(p_key text, p_at date) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce((select value from tax_rules where key = p_key and effective_from <= p_at order by effective_from desc limit 1),
                  (select value from tax_rules where key = p_key order by effective_from limit 1))
$$;

-- What the business tells the computation for a financial year (keyed by the year's last day): whether it provides
-- professional services (never a small company), losses and unabsorbed allowances brought forward, its own adjustments
-- with reasons, and the charge posted from the computation.
create table if not exists public.tax_settings (
  org_id uuid not null references public.orgs(id) on delete cascade,
  period_end date not null,
  professional_services boolean not null default false,
  losses_bf numeric(16,2) not null default 0 check (losses_bf >= 0),
  unabsorbed_ca_bf numeric(16,2) not null default 0 check (unabsorbed_ca_bf >= 0),
  adjustments jsonb not null default '[]'::jsonb,
  notes text,
  posted_journal_id uuid references public.journals(id) on delete set null,
  posted_from date,
  posted_to date,
  posted_cit numeric(16,2),
  posted_levy numeric(16,2),
  posted_at timestamptz,
  posted_by uuid references public.members(id) on delete set null,
  computed jsonb,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, period_end)
);
create index if not exists tax_settings_journal_fk on public.tax_settings(posted_journal_id);
create index if not exists tax_settings_posted_by_fk on public.tax_settings(posted_by);
create index if not exists tax_settings_updated_by_fk on public.tax_settings(updated_by);
alter table public.tax_settings enable row level security;
drop policy if exists tax_settings_read on public.tax_settings;
create policy tax_settings_read on public.tax_settings for select to authenticated using ((select private.can_handle_money(org_id)));

create or replace function private.tax_year_end(p_org uuid, p_day date) returns date
language sql stable security definer set search_path = public, private as $$
  select (private.fy_start(p_org, p_day) + interval '1 year' - interval '1 day')::date
$$;

-- Capital allowances for a basis period, asset by asset from the register. Straight line on cost at the class rate
-- (no initial allowance), a full year for an asset owned and in use at the end of the period, pro-rated only when the
-- period is shorter than twelve months, 1% of cost kept until disposal, and a balancing charge or allowance on disposal.
-- An asset in use before this period has had one year of allowance for each earlier year end it was in use (the
-- transitional rule counts the years already claimed against the new allowable period).
create or replace function private.ca_schedule(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare a record; v_rate numeric; v_ret numeric := coalesce(private.tax_rule('ca_retention', p_to), 0.01); v_years int; v_first_end date; v_start date;
  v_annual numeric; v_floor numeric; v_twdv numeric; v_allow numeric; v_bc numeric; v_ba numeric; v_add numeric; v_disp numeric; v_cf numeric; v_months int;
  v_factor numeric; v_assets jsonb := '[]'::jsonb; v_cls jsonb := '{}'::jsonb; k text; c jsonb; v_rows jsonb := '[]'::jsonb; v_tot jsonb;
  v_t_bf numeric := 0; v_t_add numeric := 0; v_t_disp numeric := 0; v_t_allow numeric := 0; v_t_bc numeric := 0; v_t_ba numeric := 0; v_t_cf numeric := 0;
  v_missing text[] := '{}';
begin
  -- A period shorter than a year (a year-to-date view, or a first or last period) gets its share of the year's allowance.
  v_months := (extract(year from age(p_to + 1, p_from)) * 12 + extract(month from age(p_to + 1, p_from)))::int;
  v_factor := least((v_months + extract(day from age(p_to + 1, p_from)) / 30.0) / 12.0, 1);
  for a in select fa.*, ac.name class_name from fixed_assets fa join asset_classes ac on ac.cost_account = fa.class_account
           where fa.org_id = p_org and fa.status in ('active', 'disposed') and coalesce(fa.available_date, fa.created_at::date) <= p_to
             and (fa.disposed_at is null or fa.disposed_at >= p_from)
           order by fa.class_account, coalesce(fa.available_date, fa.created_at::date), fa.number loop
    v_rate := private.tax_rule('ca_rate:' || a.class_account, p_to);
    if v_rate is null then v_missing := v_missing || a.class_name; end if;
    v_start := coalesce(a.available_date, a.created_at::date);
    v_first_end := (private.fy_start(p_org, v_start) + interval '1 year' - interval '1 day')::date;
    v_years := case when v_first_end >= p_from then 0
                    else (select count(*) from generate_series(v_first_end::timestamp, (p_from - 1)::timestamp, interval '1 year'))::int end;
    v_annual := round(a.cost * coalesce(v_rate, 0), 2);
    v_floor := round(a.cost * v_ret, 2);
    v_add := case when v_start >= p_from then a.cost else 0 end;
    v_twdv := case when v_start >= p_from then 0 when coalesce(v_rate, 0) = 0 then a.cost else greatest(a.cost - v_annual * v_years, least(v_floor, a.cost)) end;
    v_allow := 0; v_bc := 0; v_ba := 0; v_disp := 0;
    if a.status = 'disposed' and a.disposed_at between p_from and p_to then
      -- Not owned at the end of the period: no allowance, and the proceeds settle the tax value left.
      v_disp := coalesce(a.proceeds, 0);
      if coalesce(v_rate, 0) > 0 then
        if v_disp > v_twdv + v_add then v_bc := least(v_disp - (v_twdv + v_add), greatest(a.cost - (v_twdv + v_add), 0));
        else v_ba := (v_twdv + v_add) - v_disp; end if;
      end if;
      v_cf := 0;
    else
      v_allow := case when coalesce(v_rate, 0) = 0 then 0 else round(least(v_annual * v_factor, greatest(v_twdv + v_add - v_floor, 0)), 2) end;
      v_cf := v_twdv + v_add - v_allow;
    end if;
    v_assets := v_assets || jsonb_build_array(jsonb_build_object('asset_id', a.id, 'number', a.number, 'name', a.name, 'class', a.class_account, 'class_name', a.class_name,
      'rate', v_rate, 'in_use', v_start, 'cost', a.cost, 'years_before', v_years, 'twdv_bf', v_twdv, 'additions', v_add, 'disposals', v_disp, 'allowance', v_allow,
      'balancing_charge', v_bc, 'balancing_allowance', v_ba, 'twdv_cf', v_cf));
    c := coalesce(v_cls->a.class_account, jsonb_build_object('class', a.class_account, 'class_name', a.class_name, 'rate', v_rate, 'twdv_bf', 0, 'additions', 0, 'disposals', 0,
      'allowance', 0, 'balancing_charge', 0, 'balancing_allowance', 0, 'twdv_cf', 0, 'assets', 0));
    c := c || jsonb_build_object('twdv_bf', (c->>'twdv_bf')::numeric + v_twdv, 'additions', (c->>'additions')::numeric + v_add, 'disposals', (c->>'disposals')::numeric + v_disp,
      'allowance', (c->>'allowance')::numeric + v_allow, 'balancing_charge', (c->>'balancing_charge')::numeric + v_bc,
      'balancing_allowance', (c->>'balancing_allowance')::numeric + v_ba, 'twdv_cf', (c->>'twdv_cf')::numeric + v_cf, 'assets', (c->>'assets')::int + 1);
    v_cls := jsonb_set(v_cls, array[a.class_account], c);
    v_t_bf := v_t_bf + v_twdv; v_t_add := v_t_add + v_add; v_t_disp := v_t_disp + v_disp; v_t_allow := v_t_allow + v_allow;
    v_t_bc := v_t_bc + v_bc; v_t_ba := v_t_ba + v_ba; v_t_cf := v_t_cf + v_cf;
  end loop;
  for k in select key from jsonb_each(v_cls) order by key loop
    c := v_cls->k;
    v_rows := v_rows || jsonb_build_array(c || jsonb_build_object('line', c->>'class_name', '_style', 'line', '_indent', 1,
      'rate_pct', case when c->>'rate' is not null then round((c->>'rate')::numeric * 100, 1) end));
  end loop;
  v_tot := jsonb_build_object('line', 'Total', '_style', 'total', '_indent', 0, 'twdv_bf', v_t_bf, 'additions', v_t_add, 'disposals', v_t_disp, 'allowance', v_t_allow,
    'balancing_charge', v_t_bc, 'balancing_allowance', v_t_ba, 'twdv_cf', v_t_cf);
  return jsonb_build_object('rows', v_rows || jsonb_build_array(v_tot), 'assets', v_assets, 'months', v_months, 'factor', v_factor, 'retention', v_ret,
    'totals', v_tot - 'line' - '_style' - '_indent', 'missing_rates', to_jsonb(v_missing));
end $$;

-- The companies income tax computation for a basis period, from the ledger. Each line says where its figure comes from;
-- the business's own adjustments are shown with their reasons. Amounts are naira; positive adds to taxable profit.
create or replace function private.tax_computation(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; st public.tax_settings; mv jsonb; t jsonb; s jsonb; ca jsonb; v_rows jsonb := '[]'::jsonb; x jsonb; v_flags jsonb := '[]'::jsonb;
  v_pbt numeric; v_turn numeric; v_fa numeric; v_dep numeric; v_fines numeric; v_ecl numeric; v_imp numeric; v_lossd numeric; v_fxl numeric; v_don numeric; v_don_cap numeric;
  v_don_out numeric; v_rd numeric; v_rd_out numeric; v_gain numeric; v_fii numeric; v_nontax numeric; v_fxg numeric; v_fv numeric; v_wb numeric; v_adj_add numeric := 0;
  v_adj_less numeric := 0; v_adjusted numeric; v_loss_used numeric; v_assess numeric; v_bc numeric; v_ca_year numeric; v_ca_avail numeric; v_ca_used numeric;
  v_total numeric; v_small boolean; v_rate numeric; v_cit numeric; v_levy numeric; v_met boolean; v_topup numeric := 0; v_wht numeric; v_wht_used numeric;
  v_payable numeric; v_loss_cf numeric; v_ca_cf numeric; v_company boolean; v_add_rows jsonb := '[]'::jsonb; v_less_rows jsonb := '[]'::jsonb; v_restr numeric;
  v_tax_exp numeric; v_n int; v_adds jsonb; v_lesses jsonb;
  dep_codes text[] := array['5204', '5205', '6901', '6902', '6903'];
begin
  select * into o from orgs where id = p_org;
  select * into st from tax_settings where org_id = p_org and period_end = private.tax_year_end(p_org, p_to);
  v_company := coalesce(o.legal_form, 'company') = 'company';
  select coalesce(jsonb_object_agg(code, net), '{}'::jsonb) into mv from private.movement(p_org, p_from, p_to);
  t := private.pl_totals(private.pl_map(p_org, p_from, p_to));
  s := private.sofp_map(p_org, p_to);
  ca := private.ca_schedule(p_org, p_from, p_to);
  v_pbt := round((t->>'profit_before_tax')::numeric, 2);
  v_turn := round((t->>'revenue')::numeric, 2);
  v_fa := private.v(s, 'Property, plant and equipment') + private.v(s, 'Intangible assets');
  -- Expenses the law does not allow, from their own accounts.
  v_dep := private.sum_codes(mv, dep_codes);
  v_fines := private.sum_codes(mv, array['6513', '6514']);
  v_ecl := private.sum_codes(mv, array['6802']);
  v_imp := private.sum_codes(mv, array['6803']);
  v_lossd := private.sum_codes(mv, array['6804']);
  v_fxl := private.sum_codes(mv, array['6704']);
  v_don := private.sum_codes(mv, array['6904']);
  v_rd := private.sum_codes(mv, array['6905']);
  -- Income that is not taxable here, or taxed another way.
  v_gain := -private.sum_codes(mv, array['4508']);
  v_fii := -private.sum_codes(mv, array['4505']);
  v_nontax := -private.sum_codes(mv, array['4509']);
  v_fxg := -private.sum_codes(mv, array['4511']);
  v_fv := -private.sum_codes(mv, array['4515']);
  v_wb := -private.sum_codes(mv, array['4507']);
  v_tax_exp := private.sum_codes(mv, array['7501', '7502', '7505']);
  -- Donations above the cap and research above its share of turnover are added back.
  v_don_cap := round(greatest(v_pbt + v_dep + v_fines + v_ecl + v_imp + v_lossd + v_fxl + v_don, 0) * coalesce(private.tax_rule('donations_cap', p_to), 0.10), 2);
  v_don_out := greatest(v_don - v_don_cap, 0);
  v_rd_out := greatest(v_rd - round(v_turn * coalesce(private.tax_rule('rd_cap', p_to), 0.05), 2), 0);
  for x in select * from jsonb_array_elements(coalesce(st.adjustments, '[]'::jsonb)) loop
    if coalesce(private.num(x->>'amount'), 0) = 0 then continue; end if;
    if x->>'kind' = 'deduct' then
      v_adj_less := v_adj_less + abs(private.num(x->>'amount'));
      v_less_rows := v_less_rows || jsonb_build_array(jsonb_build_object('line', coalesce(nullif(x->>'label', ''), 'Adjustment'), 'current', -abs(private.num(x->>'amount')),
        'basis', coalesce(nullif(x->>'reason', ''), 'Entered by the business'), '_style', 'line', '_indent', 1, 'manual', true));
    else
      v_adj_add := v_adj_add + abs(private.num(x->>'amount'));
      v_add_rows := v_add_rows || jsonb_build_array(jsonb_build_object('line', coalesce(nullif(x->>'label', ''), 'Adjustment'), 'current', abs(private.num(x->>'amount')),
        'basis', coalesce(nullif(x->>'reason', ''), 'Entered by the business'), '_style', 'line', '_indent', 1, 'manual', true));
    end if;
  end loop;
  v_adjusted := v_pbt + v_dep + v_lossd + v_fines + v_ecl + v_imp + v_fxl + v_don_out + v_rd_out + v_adj_add
              - v_gain - v_fii - v_nontax - v_fxg - v_fv - v_wb - v_adj_less;
  v_loss_used := least(coalesce(st.losses_bf, 0), greatest(v_adjusted, 0));
  v_assess := greatest(v_adjusted - v_loss_used, 0);
  v_loss_cf := coalesce(st.losses_bf, 0) - v_loss_used + greatest(-v_adjusted, 0);
  v_bc := round((ca->'totals'->>'balancing_charge')::numeric, 2);
  v_ca_year := round((ca->'totals'->>'allowance')::numeric + (ca->'totals'->>'balancing_allowance')::numeric, 2);
  v_ca_avail := v_ca_year + coalesce(st.unabsorbed_ca_bf, 0);
  v_restr := coalesce(private.tax_rule('ca_restriction', p_to), 1);
  v_ca_used := least(v_ca_avail, round((v_assess + v_bc) * v_restr, 2));
  v_ca_cf := v_ca_avail - v_ca_used;
  v_total := v_assess + v_bc - v_ca_used;
  v_small := v_turn <= coalesce(private.tax_rule('small_company_turnover', p_to), 100000000) and v_fa <= coalesce(private.tax_rule('small_company_fixed_assets', p_to), 250000000)
             and not coalesce(st.professional_services, false);
  v_rate := case when v_small then coalesce(private.tax_rule('small_company_rate', p_to), 0) else coalesce(private.tax_rule('cit_rate', p_to), 0.30) end;
  v_cit := case when v_company then round(v_total * v_rate, 2) else 0 end;
  v_levy := case when v_company and not v_small then round((v_assess + v_bc) * coalesce(private.tax_rule('development_levy_rate', p_to), 0.04), 2) else 0 end;
  v_met := v_company and v_turn >= coalesce(private.tax_rule('met_turnover', p_to), 50000000000);
  if v_met and v_pbt > 0 and v_cit < round(v_pbt * coalesce(private.tax_rule('met_rate', p_to), 0.15), 2) then
    v_topup := round(v_pbt * coalesce(private.tax_rule('met_rate', p_to), 0.15), 2) - v_cit;
  end if;
  select coalesce(sum(bal), 0) into v_wht from private.balances_at(p_org, p_to) where split_part(code, '-', 1) = '1401';
  v_wht_used := least(greatest(v_wht, 0), v_cit + v_topup);
  v_payable := v_cit + v_levy + v_topup - v_wht_used;

  select count(*) into v_n from journal_lines l join journals j on j.id = l.journal_id where l.org_id = p_org and j.entry_date between p_from and p_to
    and split_part(l.account_code, '-', 1) = any(dep_codes);
  v_adds := case when v_dep <> 0 then jsonb_build_array(jsonb_build_object('line', 'Depreciation and amortisation', 'current', v_dep,
         'basis', 'Accounts 5204, 5205, 6901-6903 (' || v_n || case when v_n = 1 then ' entry' else ' entries' end || '); capital allowances are given instead', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_lossd <> 0 then jsonb_build_array(jsonb_build_object('line', 'Loss on disposal of property, plant and equipment', 'current', v_lossd,
         'basis', 'Account 6804; the balancing allowance takes its place', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_fines <> 0 then jsonb_build_array(jsonb_build_object('line', 'Fines and penalties', 'current', v_fines, 'basis', 'Accounts 6513 and 6514; never deductible', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_ecl <> 0 then jsonb_build_array(jsonb_build_object('line', 'Expected credit loss charge (general provision)', 'current', v_ecl,
         'basis', 'Account 6802; a debt is deductible when written off (6801)', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_imp <> 0 then jsonb_build_array(jsonb_build_object('line', 'Impairment of other assets', 'current', v_imp, 'basis', 'Account 6803', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_fxl <> 0 then jsonb_build_array(jsonb_build_object('line', 'Unrealised exchange losses', 'current', v_fxl, 'basis', 'Account 6704; deductible when realised', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_don_out <> 0 then jsonb_build_array(jsonb_build_object('line', 'Donations above the deductible limit', 'current', v_don_out,
         'basis', 'Account 6904: ' || private.naira(v_don) || ' given, ' || private.naira(v_don_cap) || ' allowed (10% of profit before donations)', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_rd_out <> 0 then jsonb_build_array(jsonb_build_object('line', 'Research costs above 5% of turnover', 'current', v_rd_out, 'basis', 'Account 6905', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || v_add_rows;
  v_lesses := case when v_gain <> 0 then jsonb_build_array(jsonb_build_object('line', 'Gain on disposal of property, plant and equipment', 'current', -v_gain,
         'basis', 'Account 4508; the balancing charge takes its place', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_fii <> 0 then jsonb_build_array(jsonb_build_object('line', 'Dividends received (franked investment income)', 'current', -v_fii, 'basis', 'Account 4505; taxed at source', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_nontax <> 0 then jsonb_build_array(jsonb_build_object('line', 'Non-taxable income, grants and donations received', 'current', -v_nontax, 'basis', 'Account 4509', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_fxg <> 0 then jsonb_build_array(jsonb_build_object('line', 'Unrealised exchange gains', 'current', -v_fxg, 'basis', 'Account 4511; taxed when realised', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_fv <> 0 then jsonb_build_array(jsonb_build_object('line', 'Fair value gains not realised', 'current', -v_fv, 'basis', 'Account 4515', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || case when v_wb <> 0 then jsonb_build_array(jsonb_build_object('line', 'Provisions written back', 'current', -v_wb, 'basis', 'Account 4507; the provision was not allowed when made', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || v_less_rows;
  v_rows := jsonb_build_array(jsonb_build_object('line', 'Profit / (loss) before tax', 'current', v_pbt, 'basis', 'Statement of profit or loss', '_style', 'subtotal', '_indent', 0))
    || case when jsonb_array_length(v_adds) > 0 then jsonb_build_array(jsonb_build_object('line', 'Add: expenses not allowed', '_style', 'heading', '_indent', 0)) || v_adds else '[]'::jsonb end
    || case when jsonb_array_length(v_lesses) > 0 then jsonb_build_array(jsonb_build_object('line', 'Less: income not taxed here', '_style', 'heading', '_indent', 0)) || v_lesses else '[]'::jsonb end
    || jsonb_build_array(jsonb_build_object('line', 'Adjusted profit / (loss)', 'current', v_adjusted, '_style', 'subtotal', '_indent', 0))
    || case when coalesce(st.losses_bf, 0) > 0 then jsonb_build_array(jsonb_build_object('line', 'Less: losses brought forward', 'current', -v_loss_used,
         'basis', private.naira(st.losses_bf) || ' brought forward; losses carry forward without time limit', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || jsonb_build_array(jsonb_build_object('line', 'Assessable profit', 'current', v_assess, '_style', 'subtotal', '_indent', 0))
    || case when v_bc <> 0 then jsonb_build_array(jsonb_build_object('line', 'Add: balancing charges', 'current', v_bc, 'basis', 'Capital allowance schedule', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || jsonb_build_array(
      jsonb_build_object('line', 'Less: capital allowances', 'current', -v_ca_used, 'basis', private.naira(v_ca_year) || ' for the year'
        || case when coalesce(st.unabsorbed_ca_bf, 0) > 0 then ', ' || private.naira(st.unabsorbed_ca_bf) || ' brought forward' else '' end
        || case when v_ca_cf > 0 then ', ' || private.naira(v_ca_cf) || ' carried forward' else '' end, '_style', 'line', '_indent', 1),
      jsonb_build_object('line', 'Total profit', 'current', v_total, '_style', 'subtotal', '_indent', 0),
      jsonb_build_object('line', 'Tax', '_style', 'heading', '_indent', 0),
      jsonb_build_object('line', case when not v_company then 'Companies income tax' else 'Companies income tax at ' || trim(to_char(v_rate * 100, 'FM990.##')) || '%'
        || case when v_small then ' (small company)' else '' end end, 'current', v_cit,
        'basis', case when not v_company then 'Not a company: the owners pay personal income tax on this profit' when v_small then 'Turnover and fixed assets within the small-company limits (NTA 2025 s.202)'
          else 'NTA 2025 s.56' end, '_style', 'line', '_indent', 1),
      jsonb_build_object('line', 'Development levy at ' || trim(to_char(coalesce(private.tax_rule('development_levy_rate', p_to), 0.04) * 100, 'FM990.##')) || '% of assessable profits',
        'current', v_levy, 'basis', case when not v_company then 'Not a company' when v_small then 'Not charged on a small company' else 'NTA 2025 s.59' end, '_style', 'line', '_indent', 1))
    || case when v_met then jsonb_build_array(jsonb_build_object('line', 'Minimum effective tax top-up (indicative)', 'current', v_topup,
         'basis', 'Turnover at or above the threshold: tax must reach 15% of profit. The regulations set the exact base.', '_style', 'line', '_indent', 1)) else '[]'::jsonb end
    || jsonb_build_array(
      jsonb_build_object('line', 'Tax charge for the year', 'current', v_cit + v_levy + v_topup, '_style', 'subtotal', '_indent', 0),
      jsonb_build_object('line', 'Less: withholding tax credit notes held', 'current', -v_wht_used, 'basis', private.naira(v_wht) || ' in account 1401 at ' || to_char(p_to, 'DD Mon YYYY')
        || '; set against companies income tax only', '_style', 'line', '_indent', 1),
      jsonb_build_object('line', 'Tax payable', 'current', v_payable, '_style', 'total', '_indent', 0));
  if v_loss_cf > 0 then v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Loss carried forward', 'current', v_loss_cf, '_style', 'line', '_indent', 0, 'memo', true)); end if;
  if v_ca_cf > 0 then v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Unabsorbed capital allowances carried forward', 'current', v_ca_cf, '_style', 'line', '_indent', 0, 'memo', true)); end if;

  if p_from < date '2026-01-01' then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'warn', 'text',
    'This period starts before 1 January 2026. The Nigeria Tax Act 2025 rules are used throughout; earlier months fell under the Companies Income Tax Act.')); end if;
  if jsonb_array_length(ca->'missing_rates') > 0 then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'warn', 'text',
    'No capital allowance rate is set for: ' || (select string_agg(value, ', ') from jsonb_array_elements_text(ca->'missing_rates')) || '. Those assets get no allowance until the rate is set.')); end if;
  if v_tax_exp <> 0 and st.posted_journal_id is null then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Tax of ' || private.naira(v_tax_exp) || ' is already in the accounts for this period. Posting this computation replaces only a charge posted from here.')); end if;
  if private.sum_codes(mv, array['6409', '6410', '6408']) <> 0 then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Entertainment, gifts and social responsibility spending of ' || private.naira(private.sum_codes(mv, array['6409', '6410', '6408']))
    || ' is treated as allowed. Add back any part not wholly and exclusively for the business.')); end if;
  if private.sum_codes(mv, array['6702']) > 0 then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Interest to connected persons is deductible only up to 30% of EBITDA. Add back any excess.')); end if;
  if v_met then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Turnover is at or above the minimum effective tax threshold: review the top-up with the regulations.')); end if;
  if (ca->>'factor')::numeric < 1 then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'This period is shorter than a year, so capital allowances are a share of the year''s. The return is made on the full financial year.')); end if;
  if v_don > 0 then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Donations are allowed only when made to bodies the Act lists. Add back any that were not.')); end if;
  if not v_company then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text', 'The business is not a company, so no companies income tax or development levy is computed.')); end if;

  return jsonb_build_object('rows', v_rows, 'ca', ca, 'from', p_from, 'to', p_to, 'flags', v_flags,
    'figures', jsonb_build_object('profit_before_tax', v_pbt, 'turnover', v_turn, 'fixed_assets', v_fa, 'adjusted', v_adjusted, 'assessable', v_assess,
      'balancing_charge', v_bc, 'capital_allowances', v_ca_used, 'total_profit', v_total, 'small_company', v_small, 'rate', v_rate, 'cit', v_cit, 'levy', v_levy,
      'topup', v_topup, 'wht_credit', v_wht_used, 'payable', v_payable, 'loss_cf', v_loss_cf, 'ca_cf', v_ca_cf, 'company', v_company, 'tax_in_accounts', v_tax_exp),
    'settings', jsonb_build_object('professional_services', coalesce(st.professional_services, false), 'losses_bf', coalesce(st.losses_bf, 0),
      'unabsorbed_ca_bf', coalesce(st.unabsorbed_ca_bf, 0), 'adjustments', coalesce(st.adjustments, '[]'::jsonb), 'notes', st.notes,
      'posted_journal_id', st.posted_journal_id, 'posted_at', st.posted_at, 'posted_cit', st.posted_cit, 'posted_levy', st.posted_levy,
      'posted_from', st.posted_from, 'posted_to', st.posted_to, 'posted_ref', (select ref from journals where id = st.posted_journal_id),
      'year_end', private.tax_year_end(p_org, p_to)),
    'rules', (select jsonb_agg(jsonb_build_object('key', r.key, 'value', r.value, 'label', r.label, 'source', r.source, 'effective_from', r.effective_from) order by r.key)
      from (select distinct on (key) * from tax_rules where effective_from <= greatest(p_to, (select min(effective_from) from tax_rules)) order by key, effective_from desc) r));
end $$;

create or replace function public.tax_computation(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; pr jsonb;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Tax computations need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  pr := private.fs_periods(p_org, p_from, p_to);
  return private.tax_computation(p_org, (pr->>'from')::date, (pr->>'to')::date) || jsonb_build_object('periods', pr);
end $$;

-- p: {professional_services, losses_bf, unabsorbed_ca_bf, adjustments:[{label, amount, kind: add|deduct, reason}], notes}
create or replace function public.save_tax_settings(p_org uuid, p_period_end date, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; v_adj jsonb := '[]'::jsonb; v_end date;
begin
  m := private.require(p_org, 'keep_books');
  if p_period_end is null then raise exception 'Choose the year.'; end if;
  v_end := private.tax_year_end(p_org, p_period_end);
  for x in select * from jsonb_array_elements(coalesce(p->'adjustments', '[]'::jsonb)) loop
    continue when coalesce(trim(x->>'label'), '') = '' and coalesce(private.num(x->>'amount'), 0) = 0;
    if coalesce(trim(x->>'label'), '') = '' then raise exception 'Name each adjustment.'; end if;
    if coalesce(trim(x->>'reason'), '') = '' then raise exception 'Give the reason for "%".', trim(x->>'label'); end if;
    if coalesce(private.num(x->>'amount'), 0) <= 0 then raise exception 'Enter the amount of "%".', trim(x->>'label'); end if;
    v_adj := v_adj || jsonb_build_array(jsonb_build_object('label', left(trim(x->>'label'), 120), 'amount', round(private.num(x->>'amount'), 2),
      'kind', case when x->>'kind' = 'deduct' then 'deduct' else 'add' end, 'reason', left(trim(x->>'reason'), 300), 'by', m.display_name, 'at', now()));
  end loop;
  if coalesce(private.num(p->>'losses_bf'), 0) < 0 or coalesce(private.num(p->>'unabsorbed_ca_bf'), 0) < 0 then raise exception 'Amounts brought forward cannot be negative.'; end if;
  insert into tax_settings (org_id, period_end, professional_services, losses_bf, unabsorbed_ca_bf, adjustments, notes, updated_by, updated_at)
  values (p_org, v_end, coalesce((p->>'professional_services')::boolean, false), round(coalesce(private.num(p->>'losses_bf'), 0), 2),
    round(coalesce(private.num(p->>'unabsorbed_ca_bf'), 0), 2), v_adj, nullif(trim(p->>'notes'), ''), m.id, now())
  on conflict (org_id, period_end) do update set professional_services = excluded.professional_services, losses_bf = excluded.losses_bf,
    unabsorbed_ca_bf = excluded.unabsorbed_ca_bf, adjustments = excluded.adjustments, notes = excluded.notes, updated_by = m.id, updated_at = now();
  return public.tax_computation(p_org, null, p_period_end);
end $$;

-- Posts the year's charge: Dr 7501 / Cr 2208 for companies income tax, Dr 7505 / Cr 2208 for any top-up and
-- Dr 7502 / Cr 2209 for the development levy, dated the last day of the period. A financial year carries one charge from
-- here: posting again (for the full year after a year-to-date charge, or after the figures change) reverses the earlier
-- one on its own date.
create or replace function public.post_tax_charge(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c jsonb; st public.tax_settings; j public.journals; v_cit numeric; v_levy numeric; v_topup numeric; v_jl jsonb; v_end date; v_old date;
begin
  m := private.require(p_org, 'keep_books');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose the period.'; end if;
  perform private.require_open_day(p_org, p_to);
  v_end := private.tax_year_end(p_org, p_to);
  c := private.tax_computation(p_org, p_from, p_to);
  v_cit := (c->'figures'->>'cit')::numeric; v_levy := (c->'figures'->>'levy')::numeric; v_topup := (c->'figures'->>'topup')::numeric;
  select * into st from tax_settings where org_id = p_org and period_end = v_end for update;
  if st.posted_journal_id is not null and not exists (select 1 from journals where reversal_of = st.posted_journal_id) then
    select entry_date into v_old from journals where id = st.posted_journal_id;
    perform private.require_open_day(p_org, v_old);
    perform private.reverse_entry(st.posted_journal_id, m.id, 'Tax charge recomputed', null);
  end if;
  if v_cit + v_levy + v_topup > 0 then
    v_jl := jsonb_build_array(
      jsonb_build_object('code', '7501', 'debit', v_cit, 'memo', 'Companies income tax'),
      jsonb_build_object('code', '2208', 'credit', v_cit, 'memo', 'Companies income tax'),
      jsonb_build_object('code', '7505', 'debit', v_topup, 'memo', 'Minimum effective tax top-up'),
      jsonb_build_object('code', '2208', 'credit', v_topup, 'memo', 'Minimum effective tax top-up'),
      jsonb_build_object('code', '7502', 'debit', v_levy, 'memo', 'Development levy'),
      jsonb_build_object('code', '2209', 'credit', v_levy, 'memo', 'Development levy'));
    j := private.post_entry(p_org, 'Tax charge for ' || to_char(p_from, 'DD Mon YYYY') || ' to ' || to_char(p_to, 'DD Mon YYYY'), 'tax', null, m.id, m.id, v_jl,
      private.posting_time(p_org, p_to), jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'tax_computation', 'from', p_from, 'to', p_to,
        'total_profit', c->'figures'->'total_profit', 'assessable', c->'figures'->'assessable'))));
  end if;
  insert into tax_settings (org_id, period_end, posted_journal_id, posted_from, posted_to, posted_cit, posted_levy, posted_at, posted_by, computed, updated_by)
  values (p_org, v_end, j.id, p_from, p_to, v_cit + v_topup, v_levy, now(), m.id, c->'figures', m.id)
  on conflict (org_id, period_end) do update set posted_journal_id = excluded.posted_journal_id, posted_from = p_from, posted_to = p_to,
    posted_cit = excluded.posted_cit, posted_levy = excluded.posted_levy, posted_at = now(), posted_by = m.id, computed = excluded.computed;
  return public.tax_computation(p_org, p_from, p_to) || jsonb_build_object('journal_ref', j.ref);
end $$;

-- The statements pack carries the tax computation and the capital allowance schedule, so the set goes out together.
create or replace function public.financial_statements_pack(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; pr jsonb; v jsonb; w jsonb := '[]'::jsonb; k text; n jsonb; v_susp numeric; tc jsonb; x jsonb;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Financial reports need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  pr := private.fs_periods(p_org, p_from, p_to);
  n := coalesce(o.fs_narrative, '{}'::jsonb);
  v := jsonb_build_object('org', private.corporate_json(p_org), 'periods', pr, 'signing_directors', private.signing_directors(p_org), 'generated_at', now());
  foreach k in array array['corporate', 'directors_report', 'responsibilities', 'value_added', 'five_year'] loop
    v := v || jsonb_build_object(k, public.statement_extra(p_org, k, (pr->>'from')::date, (pr->>'to')::date));
  end loop;
  foreach k in array array['sofp', 'sopl', 'soce', 'cash_flow', 'notes'] loop
    v := v || jsonb_build_object(k, public.accounting_report(p_org, k, (pr->>'from')::date, (pr->>'to')::date, '{}'::jsonb));
  end loop;
  tc := private.tax_computation(p_org, (pr->>'from')::date, (pr->>'to')::date);
  v := v || jsonb_build_object('tax_computation', jsonb_build_object('rows', tc->'rows', 'extra', jsonb_build_object('figures', tc->'figures', 'flags', tc->'flags',
      'settings', tc->'settings')),
    'capital_allowances', jsonb_build_object('rows', tc->'ca'->'rows', 'extra', jsonb_build_object('assets', tc->'ca'->'assets', 'months', tc->'ca'->'months',
      'retention', tc->'ca'->'retention', 'totals', tc->'ca'->'totals')));
  -- What to settle before signing.
  if jsonb_array_length(o.directors) = 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Add the directors who sign the statements.')); end if;
  if jsonb_array_length(private.signing_directors(p_org)) = 1 then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Only one director is recorded; the statement of financial position is normally signed by two.')); end if;
  if not ((v->'sofp'->'extra'->>'casts')::boolean) then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'The statement of financial position does not cast.')); end if;
  if coalesce((v->'cash_flow'->'extra'->>'casts')::boolean, true) is false then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'The statement of cash flows does not end on the cash in the books.')); end if;
  if coalesce((v->'sofp'->'extra'->>'unreconciled')::numeric, 0) <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Unreconciled bank balances of ' || private.naira((v->'sofp'->'extra'->>'unreconciled')::numeric) || ' remain. Clear them in Banking.')); end if;
  if coalesce((v->'sofp'->'extra'->>'opening_to_confirm')::numeric, 0) <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Opening balances of ' || private.naira((v->'sofp'->'extra'->>'opening_to_confirm')::numeric) || ' still sit in 3999 and need to be reclassified.')); end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_susp from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and split_part(l.account_code, '-', 1) = '9001' and j.entry_date <= (pr->>'to')::date;
  if v_susp <> 0 then w := w || jsonb_build_array(jsonb_build_object('level', 'error', 'text', 'Transactions of ' || private.naira(v_susp) || ' wait in suspense (9001). Answer the books inbox first.')); end if;
  if coalesce(private.closed_through(p_org), date '1900-01-01') < (pr->>'to')::date then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text',
    case when private.closed_through(p_org) is null then 'No period has been closed yet' else 'The books are open after ' || private.fdate(private.closed_through(p_org)) end
    || '. Close the period so the figures cannot change after signing.')); end if;
  if nullif(n->>'approved_on', '') is null then w := w || jsonb_build_array(jsonb_build_object('level', 'info', 'text', 'No approval date yet: the statements print a blank line for it.')); end if;
  foreach k in array array['going_concern', 'contingencies', 'commitments', 'events_after', 'dividend'] loop
    if nullif(n->>k, '') is null then
      w := w || jsonb_build_array(jsonb_build_object('level', 'info', 'key', k, 'text', 'Standard wording used for ' || replace(k, '_', ' ') || '. Confirm it or write your own.'));
    end if;
  end loop;
  if nullif(o.rc_number, '') is null or nullif(o.tin, '') is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the RC number and Tax ID under Settings, Branding.')); end if;
  if o.company_secretary is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the company secretary for the directors'' report.')); end if;
  -- The tax computation's own checks, and whether the accounts carry the charge it computes.
  for x in select * from jsonb_array_elements(coalesce(tc->'flags', '[]'::jsonb)) loop
    w := w || jsonb_build_array(x || jsonb_build_object('text', 'Tax computation: ' || (x->>'text')));
  end loop;
  if coalesce(o.legal_form, 'company') = 'company'
     and abs(((tc->'figures'->>'cit')::numeric + (tc->'figures'->>'levy')::numeric + (tc->'figures'->>'topup')::numeric) - (tc->'figures'->>'tax_in_accounts')::numeric) >= 1 then
    w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'key', 'tax_charge', 'text', 'The tax computation gives a charge of ' || private.naira((tc->'figures'->>'cit')::numeric
      + (tc->'figures'->>'levy')::numeric + (tc->'figures'->>'topup')::numeric) || ', but the accounts carry ' || private.naira((tc->'figures'->>'tax_in_accounts')::numeric)
      || case when tc->'settings'->>'posted_journal_id' is not null then '. The figures changed after the charge was posted: post it again from the Tax tab.' else '. Post the tax charge from the Tax tab.' end));
  end if;
  return v || jsonb_build_object('warnings', w);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Bank feeds on a schedule, and who may call what
-- ---------------------------------------------------------------------------
-- Every four hours the mono function fetches new transactions for each linked account (Mono refreshes its own copy
-- from the bank during the day; a person can also press Sync on the Banking page).
create or replace function private.feeds_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from bank_accounts where provider = 'mono' and provider_ref is not null and active) then
    perform private.call_function('mono', jsonb_build_object('action', 'sync_all'));
  end if;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-bank-feeds';
    perform cron.schedule('counta-bank-feeds', '20 */4 * * *', 'select private.feeds_tick()');
  end if;
end $$;

grant execute on function public.credit_sale(uuid, jsonb), public.sale_creditable(uuid), public.record_vendor_credit(uuid, jsonb),
  public.use_vendor_credit(uuid, uuid, numeric), public.refund_vendor_credit(uuid, jsonb), public.get_vendor_credits(uuid, uuid),
  public.import_bank_lines(uuid, uuid, jsonb, jsonb), public.bank_feed_context(uuid), public.bank_feed_account(uuid), public.resolve_proposal(uuid, jsonb),
  public.get_banking(uuid), public.tax_computation(uuid, date, date), public.save_tax_settings(uuid, date, jsonb), public.post_tax_charge(uuid, date, date),
  public.financial_statements_pack(uuid, date, date) to authenticated;
revoke execute on function public.credit_sale(uuid, jsonb), public.sale_creditable(uuid), public.record_vendor_credit(uuid, jsonb),
  public.use_vendor_credit(uuid, uuid, numeric), public.refund_vendor_credit(uuid, jsonb), public.get_vendor_credits(uuid, uuid),
  public.import_bank_lines(uuid, uuid, jsonb, jsonb), public.bank_feed_context(uuid), public.bank_feed_account(uuid), public.resolve_proposal(uuid, jsonb),
  public.get_banking(uuid), public.tax_computation(uuid, date, date), public.save_tax_settings(uuid, date, jsonb), public.post_tax_charge(uuid, date, date),
  public.financial_statements_pack(uuid, date, date) from public, anon;
revoke execute on function public.svc_feed_link(uuid, uuid, uuid, jsonb), public.svc_feed_accounts(uuid), public.svc_feed_status(text, jsonb),
  public.svc_feed_import(uuid, jsonb, jsonb), public.svc_feed_unlink(uuid, text), public.svc_feed_account(text) from public, anon, authenticated;
grant execute on function public.svc_feed_link(uuid, uuid, uuid, jsonb), public.svc_feed_accounts(uuid), public.svc_feed_status(text, jsonb),
  public.svc_feed_import(uuid, jsonb, jsonb), public.svc_feed_unlink(uuid, text), public.svc_feed_account(text) to service_role;
revoke execute on function private.name_norm(text), private.find_vendor(uuid, text), private.find_bill(uuid, text, uuid), private.find_account(uuid, text),
  private.bulk_row(uuid, jsonb, text), private.sale_line_creditable(uuid), private.settle_credit_note(uuid, uuid, jsonb, public.members),
  private.sales_analysis(uuid, date, date, text, boolean), private.bill_line_creditable(uuid), private.vendor_credit_json(uuid),
  private.use_vendor_credit(uuid, uuid, numeric, public.members), private.bill_json(uuid), private.vat_rows(uuid, date, date), private.narr_words(text),
  private.narr_like(text, text), private.narr_key(text), private.same_line(uuid, date, numeric, numeric, text, uuid, uuid[], boolean), private.feed_json(uuid),
  private.doc_in_text(text, text), private.ref_in_text(text, text), private.match_bank_line(uuid), private.tax_rule(text, date), private.tax_year_end(uuid, date),
  private.ca_schedule(uuid, date, date), private.tax_computation(uuid, date, date), private.feeds_tick() from public, anon, authenticated;
