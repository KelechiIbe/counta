-- Supplier contacts, input VAT claimed when bills are paid in full, and supplier invoices that receive stock.
--
-- 1. Suppliers carry a WhatsApp number and an email, so Counta can tell them what to fix on an invoice and when they are paid.
-- 2. Input VAT on a bill is claimed in the month the bill is paid in full (never before the month of the invoice). The Input VAT
--    invoices list, Documents (Purchases, Input VAT invoices) and the NRS return follow it.
-- 3. An uploaded supplier invoice is read with the business's profile and items list: each line is stock (an item on the list,
--    or a new one), a fixed asset or an expense. Approving the invoice receives the stock into the branch chosen.

-- ---------------------------------------------------------------------------
-- 1. Supplier contacts
-- ---------------------------------------------------------------------------

create or replace function public.save_vendor_details(p_org uuid, p_vendor uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.vendors; v_email text; v_phone text;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'approve_pos')) then
    raise exception 'Your role does not change vendor details.' using errcode = '42501';
  end if;
  if p_patch ? 'wht_category' and nullif(p_patch->>'wht_category', '') is not null and not exists (select 1 from wht_rates where code = p_patch->>'wht_category') then
    raise exception 'Unknown withholding tax category.';
  end if;
  if coalesce(p_patch->>'account_number', '') <> '' and p_patch->>'account_number' !~ '^[0-9]{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if nullif(p_patch->>'default_account', '') is not null and not private.bill_account_ok(p_org, p_patch->>'default_account') then
    raise exception 'Choose an expense, stock or asset account.';
  end if;
  if nullif(p_patch->>'entity_type', '') is not null and p_patch->>'entity_type' not in ('company', 'plc', 'llp', 'ltd_gte', 'business_name', 'sole_proprietor',
       'partnership', 'lp', 'individual', 'government', 'ngo') then
    raise exception 'Choose what kind of business the supplier is.';
  end if;
  if nullif(trim(p_patch->>'state'), '') is not null and private.state_code(p_patch->>'state') is null then raise exception 'Choose the supplier''s state.'; end if;
  if nullif(trim(p_patch->>'nin'), '') is not null and regexp_replace(p_patch->>'nin', '\D', '', 'g') !~ '^[0-9]{11}$' then raise exception 'A NIN has 11 digits.'; end if;
  -- How the supplier is reached: invoice problems and remittance advice go by WhatsApp or email.
  if p_patch ? 'email' then
    v_email := lower(nullif(trim(p_patch->>'email'), ''));
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  end if;
  if p_patch ? 'phone' then
    v_phone := private.clean_phone(nullif(trim(p_patch->>'phone'), ''));
    if v_phone is not null and v_phone !~ '^\+[0-9]{10,15}$' then raise exception 'Write the WhatsApp number as 080… or with its country code, such as +234….'; end if;
  end if;
  if nullif(p_patch->>'channel', '') is not null and p_patch->>'channel' not in ('whatsapp', 'email', 'phone') then raise exception 'Choose WhatsApp or email.'; end if;
  update vendors set
    tin = case when p_patch ? 'tin' then private.tax_id_input(p_patch->>'tin', tin, 'The vendor''s Tax ID') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    is_individual = coalesce((p_patch->>'is_individual')::boolean, case when p_patch ? 'entity_type' then p_patch->>'entity_type' = 'individual' end, is_individual),
    wht_category = case when p_patch ? 'wht_category' then nullif(p_patch->>'wht_category', '') else wht_category end,
    bank_code = case when p_patch ? 'bank_code' then nullif(p_patch->>'bank_code', '') else bank_code end,
    bank_name = case when p_patch ? 'bank_name' then nullif(p_patch->>'bank_name', '') else bank_name end,
    account_number = case when p_patch ? 'account_number' then nullif(p_patch->>'account_number', '') else account_number end,
    account_name = case when p_patch ? 'account_name' then nullif(trim(p_patch->>'account_name'), '') else account_name end,
    default_account = case when p_patch ? 'default_account' then nullif(p_patch->>'default_account', '') else default_account end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    credit_days = coalesce((p_patch->>'credit_days')::int, credit_days),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered),
    entity_type = case when p_patch ? 'entity_type' then nullif(p_patch->>'entity_type', '') else entity_type end,
    resident = coalesce((p_patch->>'resident')::boolean, resident),
    country = case when p_patch ? 'country' then coalesce(nullif(upper(trim(p_patch->>'country')), ''), 'NG') else country end,
    state = case when p_patch ? 'state' then (select a.state from tax_authorities a where a.code = private.state_code(p_patch->>'state')) else state end,
    is_manufacturer = coalesce((p_patch->>'is_manufacturer')::boolean, is_manufacturer),
    wht_exempt = coalesce((p_patch->>'wht_exempt')::boolean, wht_exempt),
    digital_supplier = coalesce((p_patch->>'digital_supplier')::boolean, digital_supplier),
    connected_person = coalesce((p_patch->>'connected_person')::boolean, connected_person),
    email = case when p_patch ? 'email' then v_email else email end,
    phone = case when p_patch ? 'phone' then v_phone else phone end,
    channel = coalesce(nullif(p_patch->>'channel', ''), case when p_patch ? 'email' and v_email is not null and coalesce(v_phone, phone) is null then 'email' end, channel)
  where id = p_vendor and org_id = p_org returning * into v;
  if not found then raise exception 'Vendor not found.'; end if;
  if p_patch ? 'nin' then perform private.set_vendor_nin(v.id, p_patch->>'nin', m.id); end if;
  -- Draft bills from the supplier follow the change.
  perform private.bill_wht(b.id) from bills b where b.vendor_id = v.id and b.status = 'draft';
  -- WHT already deducted while the supplier's state was not known goes to its state service now that it is.
  update wht_deductions d set authority = st.code, state_missing = false, due_date = private.wht_due('wht', st.code, d.category, d.deducted_on)
  from (select private.vendor_wht_profile(v.id)->>'state' code) st
  where d.vendor_id = v.id and d.kind = 'wht' and d.state_missing and d.authority is null and st.code is not null and d.status in ('pending', 'deducted');
  return to_jsonb(v) || jsonb_build_object('nin', private.vendor_nin(v.id), 'wht_profile', private.vendor_wht_profile(v.id));
end $$;

create or replace function public.vendor_tax_details(p_org uuid, p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v public.vendors; pf jsonb; v_auth text;
begin
  m := private.require(p_org, null);
  -- The NIN and what was withheld are for those who pay suppliers or keep the books (as bills are).
  if not (private.can_handle_money(p_org) or private.perm_of(m, 'approve_pos')) then raise exception 'Your role does not see suppliers'' tax details.' using errcode = '42501'; end if;
  select * into v from vendors where id = p_vendor and org_id = p_org;
  if not found then raise exception 'Vendor not found.'; end if;
  pf := private.vendor_wht_profile(v.id);
  v_auth := case when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
  return jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'rc_number', v.rc_number, 'nin', private.vendor_nin(v.id), 'entity_type', v.entity_type,
    'is_individual', v.is_individual, 'resident', coalesce(v.resident, true), 'country', coalesce(v.country, 'NG'), 'state', v.state, 'address', v.address,
    'wht_category', v.wht_category, 'is_manufacturer', coalesce(v.is_manufacturer, false), 'wht_exempt', coalesce(v.wht_exempt, false),
    'digital_supplier', coalesce(v.digital_supplier, false), 'connected_person', coalesce(v.connected_person, false), 'vat_registered', v.vat_registered,
    'wht_profile', pf || jsonb_build_object('authority', v_auth, 'authority_name', (select coalesce(short_name, name) from tax_authorities where code = v_auth),
      'state_needed', v_auth is null),
    'wht_withheld', (select coalesce(sum(amount), 0) from wht_deductions where vendor_id = v.id and kind = 'wht' and status in ('deducted', 'remitted')),
    'tin_status', v.tin_status, 'tin_checked_at', v.tin_checked_at, 'tin_check', v.tin_check,
    'phone', v.phone, 'email', v.email, 'channel', v.channel,
    'bills_held', (select count(*) from bills b where b.vendor_id = v.id and b.status in ('draft', 'approved', 'partially_paid') and private.bill_tin_hold(b.id) is not null));
end $$;

-- ---------------------------------------------------------------------------
-- 2. Input VAT on a bill is claimed when the bill is paid in full
-- ---------------------------------------------------------------------------
-- A bill's VAT goes into the VAT return of the month the bill is paid in full, never before the month of the supplier's
-- invoice. Until then it waits in 1402 with the rest of the input VAT. Months already filed keep what was filed: a bill
-- dated before the first month that was still open when this came in stays in its own month, as it was filed. VAT
-- self-charged on services from abroad stays in the bill's month, beside the self-charge.

-- The first month the rule applies to, per business: the month after the last VAT return filed when this was added
-- (null, every month, for a business that had filed none). Set once, when the column is first added.
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'orgs' and column_name = 'vat_claim_on_payment_from') then
    alter table public.orgs add column vat_claim_on_payment_from date;
    update public.orgs o set vat_claim_on_payment_from = (select (max(vp.period) + interval '1 month')::date from public.vat_periods vp where vp.org_id = o.id);
  end if;
end $$;
comment on column public.orgs.vat_claim_on_payment_from is
  'Input VAT on bills dated from this month is claimed when the bill is paid in full; earlier bills keep the month they were filed in.';

-- The day a bill was paid in full: the last payment, once what was paid covers it.
alter table public.bills add column if not exists paid_in_full_on date;
create index if not exists bills_paid_in_full on public.bills(org_id, paid_in_full_on) where paid_in_full_on is not null;

create or replace function private.bill_paid_on(p_bill uuid) returns date
language sql stable security definer set search_path = public, private as $$
  select private.local_day(b.org_id, x.at) from bills b
    cross join lateral (select max(bp.paid_at) at from bill_payments bp where bp.bill_id = b.id and bp.status = 'paid') x
  where b.id = p_bill and x.at is not null
$$;

create or replace function private.on_bill_paid_day() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  new.paid_in_full_on := case when new.status = 'paid' then coalesce(private.bill_paid_on(new.id), new.paid_in_full_on, new.bill_date) end;
  return new;
end $$;
drop trigger if exists bills_paid_day on public.bills;
create trigger bills_paid_day before insert or update on public.bills for each row execute function private.on_bill_paid_day();

-- A payment's day or status changing after the bill was settled moves the day with it.
create or replace function private.on_bill_payment_day() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_bill uuid := coalesce(new.bill_id, old.bill_id);
begin
  update bills set paid_in_full_on = private.bill_paid_on(id)
  where id = v_bill and status = 'paid' and paid_in_full_on is distinct from private.bill_paid_on(id);
  return null;
end $$;
drop trigger if exists bill_payments_paid_day on public.bill_payments;
create trigger bill_payments_paid_day after insert or delete or update of status, paid_at on public.bill_payments
  for each row execute function private.on_bill_payment_day();

update public.bills set paid_in_full_on = null where status = 'paid' and paid_in_full_on is null;

-- The day VAT on a bill (or stock receipt) is claimed: its own day before the business's change-over month; otherwise the
-- day it was paid in full, never before its own day. Null while it is not paid in full.
create or replace function private.vat_claim_day(p_day date, p_paid boolean, p_paid_on date, p_cut date) returns date
language sql immutable set search_path = '' as $$
  select case when p_day is null then null
    when p_cut is not null and p_day < p_cut then p_day
    when p_paid then greatest(p_day, coalesce(p_paid_on, p_day)) end
$$;

create or replace function private.bill_vat_day(p_bill uuid) returns date
language sql stable security definer set search_path = public, private as $$
  select private.vat_claim_day(case when b.source = 'receipt' and r.id is not null then private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)) else b.bill_date end,
    b.status = 'paid', b.paid_in_full_on, o.vat_claim_on_payment_from)
  from bills b join orgs o on o.id = b.org_id left join receipts r on r.id = b.receipt_id
  where b.id = p_bill and b.journal_id is not null and b.status <> 'void' and b.source <> 'import'
$$;

-- Input VAT invoices: every bill with input VAT claimed in the months asked for (paid in full), and the bills whose VAT
-- waits for payment. p: {from, to} (first days of months).
create or replace function public.input_vat_invoices(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_from date; v_to date;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see VAT work.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  v_from := date_trunc('month', coalesce(nullif(p->>'from', '')::date, (private.local_day(p_org, now()) - interval '11 months')::date))::date;
  v_to := (date_trunc('month', coalesce(nullif(p->>'to', '')::date, private.local_day(p_org, now()))) + interval '1 month' - interval '1 day')::date;
  return jsonb_build_object('from', v_from, 'to', v_to, 'vat_registered', o.vat_registered, 'change_over', o.vat_claim_on_payment_from,
    'claimed', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'vendor', v.name, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date,
        'claim_day', vd.d, 'paid_on', b.paid_in_full_on, 'net', b.subtotal, 'vat', vat.v, 'total', b.total, 'status', b.status, 'source', b.source,
        'document_path', b.document_path, 'wht', b.wht_expected, 'wht_withheld', b.wht_withheld, 'wht_borne', b.wht_borne)
        order by vd.d desc, b.number desc), '[]'::jsonb)
      from bills b join vendors v on v.id = b.vendor_id
        cross join lateral (select private.bill_vat_day(b.id) d) vd
        cross join lateral (select coalesce(sum(l.vat) filter (where l.vat_recoverable), 0) v from bill_lines l where l.bill_id = b.id) vat
      where b.org_id = p_org and b.journal_id is not null and b.status <> 'void' and b.source <> 'import' and b.vat_total > 0
        and b.bill_date <= v_to and (b.bill_date >= v_from or b.paid_in_full_on >= v_from) and vd.d between v_from and v_to and vat.v > 0),
    'waiting', (select jsonb_build_object('count', count(*), 'vat', coalesce(sum(w.vat), 0),
        'rows', coalesce((jsonb_agg(jsonb_build_object('id', w.id, 'number', w.number, 'vendor', w.vendor, 'vendor_ref', w.vendor_ref, 'bill_date', w.bill_date,
          'vat', w.vat, 'total', w.total, 'paid', w.amount_paid, 'status', w.status, 'due_date', w.due_date) order by w.bill_date desc, w.number desc)
          filter (where w.rn <= 100)), '[]'::jsonb))
      from (select b.id, b.number, v.name vendor, b.vendor_ref, b.bill_date, b.total, b.amount_paid, b.status, b.due_date,
              (select coalesce(sum(l.vat) filter (where l.vat_recoverable), 0) from bill_lines l where l.bill_id = b.id) vat,
              row_number() over (order by b.bill_date desc, b.number desc) rn
            from bills b join vendors v on v.id = b.vendor_id
            where b.org_id = p_org and b.journal_id is not null and b.status in ('approved', 'partially_paid') and b.source <> 'import' and b.vat_total > 0
              and (o.vat_claim_on_payment_from is null or b.bill_date >= o.vat_claim_on_payment_from)) w where w.vat > 0),
    'can', jsonb_build_object('work', private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')));
end $$;

-- A bill drawn as a PDF in Documents, for one typed in by hand (no supplier's file).
create or replace function public.documents_bill(p_org uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.doc_can(m)->>'purchases')::boolean then raise exception 'Your role does not see purchase documents.' using errcode = '42501'; end if;
  if not exists (select 1 from bills where id = p_id and org_id = p_org) then raise exception 'That bill is not in this business.'; end if;
  return (select jsonb_build_object('org', private.org_brand(p_org), 'number', b.number, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date, 'due_date', b.due_date,
      'status', b.status, 'subtotal', b.subtotal, 'vat_total', b.vat_total, 'total', b.total, 'wht_expected', b.wht_expected, 'notes', b.notes,
      'prices_include_vat', b.prices_include_vat, 'paid_on', b.paid_in_full_on, 'vat_day', private.bill_vat_day(b.id),
      'journal_ref', (select ref from journals where id = b.journal_id),
      'vendor', (select jsonb_build_object('name', v.name, 'tin', v.tin, 'address', v.address, 'phone', v.phone, 'email', v.email) from vendors v where v.id = b.vendor_id),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_cost', l.unit_cost, 'net', l.net, 'vat', l.vat,
          'gross', l.gross, 'account', l.account_code || ' ' || coalesce(private.account_name(b.org_id, l.account_code), ''), 'vat_treatment', l.vat_treatment)
          order by l.line_no), '[]'::jsonb) from bill_lines l where l.bill_id = b.id),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('paid_at', p.paid_at, 'gross', p.gross, 'wht', p.wht, 'net', p.net, 'method', p.method,
          'reference', p.reference) order by p.paid_at), '[]'::jsonb) from bill_payments p where p.bill_id = b.id and p.status = 'paid'))
    from bills b where b.id = p_id);
end $$;

create or replace function private.vat_month(p_org uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with b as (select date_trunc('month', p_month)::date f, (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date t),
  so as (select coalesce(sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end), 0) vat,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'exempt'), 0) exempt
         from sales s join sale_lines l on l.sale_id = s.id, b
         where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between b.f and b.t),
  cut as (select vat_claim_on_payment_from d from orgs where id = p_org),
  -- A bill's VAT is claimed in the month it is paid in full (never before the invoice's month); VAT self-charged on services from
  -- abroad stays in the bill's month, beside the self-charge itself.
  bi as (select coalesce(sum(l.vat) filter (where l.vat_recoverable and private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, cut.d) between b.f and b.t), 0) vat,
                coalesce(sum(l.reverse_charge_vat) filter (where l.vat_recoverable and x.bill_date between b.f and b.t), 0) rc
         from bills x join bill_lines l on l.bill_id = x.id, b, cut
         where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date <= b.t
           and (x.bill_date >= b.f or x.paid_in_full_on >= b.f)),
  rc as (select coalesce(sum(r.input_vat), 0) vat from receipts r left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt', b, cut
         where r.org_id = p_org and r.status = 'posted' and r.input_vat <> 0
           and private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true), rb.paid_in_full_on, cut.d) between b.f and b.t),
  vc as (select coalesce(sum(vat_total), 0) vat from vendor_credits, b where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between b.f and b.t),
  wv as (select coalesce(sum(amount), 0) vat from collections, b where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between b.f and b.t),
  im as (select coalesce(sum(import_vat), 0) vat from customs_entries, b where org_id = p_org and status = 'posted' and entry_date between b.f and b.t),
  wo as (select coalesce(round(sum(x.cost) * private.vat_rate(max(b.t)), 2), 0) vat from b, private.vat_stock_writeoffs(p_org, b.f, b.t) x)
  select jsonb_build_object('period', b.f, 'output', round(so.vat, 2), 'input', round(bi.vat + bi.rc + rc.vat - vc.vat + im.vat - wo.vat, 2), 'reverse_charge', round(bi.rc, 2),
    'import_vat', round(im.vat, 2), 'stock_writeoff_vat', wo.vat,
    'wvat_credit', round(wv.vat, 2), 'standard_sales', so.std, 'zero_rated_sales', so.zero, 'exempt_sales', so.exempt)
  from b, so, bi, rc, vc, wv, im, wo
$$;


create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  cut as (select vat_claim_on_payment_from d from orgs where id = p_org),
  -- Bills: claimed in the period they are paid in full (never before the invoice), and, for the ledger check, as recorded.
  bl0 as (select bl.vat, bl.net, bl.vat_recoverable, bl.reverse_charge_vat, b.bill_date between p_from and p_to booked,
                 private.vat_claim_day(b.bill_date, b.status = 'paid', b.paid_in_full_on, cut.d) between p_from and p_to claimed
          from bills b join bill_lines bl on bl.bill_id = b.id, cut
          where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date <= p_to
            and (b.bill_date >= p_from or b.paid_in_full_on >= p_from)),
  bi as (select coalesce(sum(vat) filter (where vat_recoverable and claimed), 0) vat, coalesce(sum(net) filter (where vat > 0 and claimed), 0) base,
                coalesce(sum(reverse_charge_vat) filter (where vat_recoverable and booked), 0) rc, coalesce(sum(net) filter (where reverse_charge_vat > 0 and booked), 0) rc_base,
                coalesce(sum(vat) filter (where vat_recoverable and booked), 0) - coalesce(sum(vat) filter (where vat_recoverable and claimed), 0) timing
         from bl0),
  rc0 as (select r.input_vat, r.net, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)) between p_from and p_to booked,
                 private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true), rb.paid_in_full_on, cut.d)
                   between p_from and p_to claimed
          from receipts r left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt', cut
          where r.org_id = p_org and r.status = 'posted' and r.input_vat <> 0),
  rc as (select coalesce(sum(input_vat) filter (where claimed), 0) vat, coalesce(sum(net) filter (where input_vat > 0 and claimed), 0) base,
                coalesce(sum(input_vat) filter (where booked), 0) - coalesce(sum(input_vat) filter (where claimed), 0) timing from rc0),
  vcr as (select coalesce(sum(vat_total), 0) vat, coalesce(sum(subtotal) filter (where vat_total > 0), 0) base from vendor_credits
          where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between p_from and p_to),
  wv as (select coalesce(sum(amount), 0) vat from collections where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between p_from and p_to),
  im as (select coalesce(sum(import_vat), 0) vat, coalesce(sum(vat_base), 0) base from customs_entries
         where org_id = p_org and status = 'posted' and entry_date between p_from and p_to),
  wo as (select coalesce(round(sum(cost) * private.vat_rate(p_to), 2), 0) vat, coalesce(sum(cost), 0) base from private.vat_stock_writeoffs(p_org, p_from, p_to)),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt', 'customs_entry') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
    private.fr('Output VAT charged', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('VAT self-charged on services from abroad (value ' || to_char(bi.rc_base, 'FM999,999,999,990.00') || ')', bi.rc, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('VAT paid at customs on imports (value ' || to_char(im.base, 'FM999,999,999,990.00') || ')', im.vat, null, 'line', 1),
    private.fr('Less credit notes from suppliers (taxable value ' || to_char(vcr.base, 'FM999,999,999,990.00') || ')', -vcr.vat, null, 'line', 1),
    private.fr('Less VAT on standard-rated stock written off (cost ' || to_char(wo.base, 'FM999,999,999,990.00') || ')', -wo.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - wo.vat, null, 'subtotal', 0),
    private.fr('VAT withheld by customers (credited)', wv.vat, null, 'line', 0),
    private.fr('VAT payable / (credit) for the period, before credit brought forward', so.vat - bi.vat - bi.rc - rc.vat - im.vat + vcr.vat + wo.vat - wv.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills, receipts, customs and supplier credit notes', led.in_ledger, null, 'line', 1),
    private.fr('Less VAT on bills recorded in the period and not yet paid in full, net of earlier bills paid in full in it', -(bi.timing + rc.timing), null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - (led.in_ledger - bi.timing - rc.timing)), null, 'subtotal', 0,
      case when wo.vat <> 0 then 'The VAT on stock written off leaves 1402 when the month is filed.' end))
  from so, bi, rc, vcr, wv, im, wo, led
$$;


create or replace function private.vat_schedule(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_f date := date_trunc('month', p_period)::date; v_t date := (date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date;
  v_vr numeric := private.vat_rate((date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date);
  o public.orgs; mn public.locations; a jsonb; b jsonb; c2 jsonb; c2v jsonb; c1 jsonb; d jsonb; e jsonb; f jsonb; checks jsonb := '[]'::jsonb;
  mo jsonb; vp public.vat_periods; v_zs numeric; v_std numeric; v_zero numeric; l jsonb; v_tol numeric; v_lines int; v_net numeric; v_place_state text;
  v_e_place text; v_today date := private.local_day(p_org, now()); rw record; v_wgap numeric;
begin
  select * into o from orgs where id = p_org;
  select * into mn from locations where org_id = p_org order by is_main desc, created_at limit 1;
  mo := private.vat_month(p_org, v_f);
  select * into vp from vat_periods where org_id = p_org and period = v_f;
  v_std := (mo->>'standard_sales')::numeric; v_zero := (mo->>'zero_rated_sales')::numeric;
  v_zs := case when v_std + v_zero > 0 then round(greatest(v_zero, 0) / (v_std + v_zero), 6) else 0 end;

  -- ---- A: every sale line (standard credit notes go to B), by customer, product, VAT status, description and place ----
  create temp table if not exists vat_a_lines (line_id uuid, item_id uuid, description text, treatment text, label text, cust_key text, cname text, ctin text,
    product text, cat int, st text, lga text, place_from text, branch_id uuid, branch_name text, customer_id uuid, c_state text, c_lga text, amount numeric) on commit drop;
  truncate vat_a_lines;
  insert into vat_a_lines
  select l.id, coalesce(l.item_id, ol.item_id), coalesce(ol.description, l.description), l.vat_treatment,
    case when l.vat_treatment = 'standard' then null
      when l.vat_treatment = 'zero' and s.export then case when coalesce(ol.kind, l.kind) = 'service' or i.item_type = 'service' then 'Exported services' else 'Exported goods excluding oil and gas' end
      -- The description chosen for the line or the product, else the one its words point to (TaxStreem sign-off N-3: Counta
      -- applies it without asking).
      else coalesce(l.nrs_vat_label, ol.nrs_vat_label, i.nrs_vat_label,
        private.nrs_label_guess(l.vat_treatment, concat_ws(' ', i.name, i.category, coalesce(ol.description, l.description)))) end,
    case when w.walk_in then 'walkin:' || coalesce(s.location_id, mn.id)::text else 'c:' || coalesce(s.customer_id::text, lower(coalesce(s.customer_name, ''))) end,
    case when w.walk_in then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end,
    case when w.walk_in then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end,
    left(case when coalesce(ol.kind, l.kind) = 'delivery' then 'Delivery' else coalesce(i.name, nullif(trim(coalesce(ol.description, l.description)), ''), 'Sale') end, 120),
    case l.vat_treatment when 'exempt' then 1 when 'zero' then 2 else 0 end,
    case when pc.by_customer then cs.st else br.state end,
    case when pc.by_customer then private.ng_lga(cs.st, c.lga) else br.lga end,
    case when pc.by_customer then 'customer' else 'branch' end,
    br.id, br.name, c.id, c.state, c.lga,
    case when s.doc_type = 'credit_note' then -l.net else l.net end
  -- A credit note's line names the line it credits, so it nets against that product.
  from sales s join sale_lines l on l.sale_id = s.id left join sale_lines ol on ol.id = l.original_line_id
    left join customers c on c.id = s.customer_id left join items i on i.id = coalesce(l.item_id, ol.item_id)
    left join locations br on br.id = coalesce(s.location_id, mn.id)
    cross join lateral (select coalesce(c.is_walk_in, s.customer_id is null and s.channel in ('till', 'voice')) walk_in) w
    -- The customer's state as chosen, else as its address names it.
    cross join lateral (select case when c.id is not null and coalesce(upper(c.country), 'NG') = 'NG'
      then coalesce(private.ng_state(c.state), private.ng_state_of_address(c.address)) end st) cs
    cross join lateral (select not w.walk_in and not coalesce(s.export, false) and cs.st is not null by_customer) pc
  where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between v_f and v_t
    and not (s.doc_type = 'credit_note' and l.vat_treatment = 'standard') and l.net <> 0;

  select coalesce(jsonb_agg(jsonb_build_object('customer', cname, 'tin', ctin, 'product', product, 'category', cat, 'label', label, 'state', st, 'lga', lga,
      'amount', amount, 'place_from', place_from) order by cat, cname, product), '[]'::jsonb)
  into a
  from (select cust_key, cname, ctin, product, cat, label, st, lga, place_from, round(sum(amount), 2) amount from vat_a_lines
        group by cust_key, cname, ctin, product, cat, label, st, lga, place_from having round(sum(amount), 2) <> 0) g;

  -- ---- B: credit notes on standard-rated lines, one row each ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'tin', ctin, 'customer', cname, 'date', issue_date, 'invoice', inv_no,
      'invoice_amount', inv_amount, 'adjusted', adjusted) order by issue_date, number), '[]'::jsonb)
  into b
  from (select s.number, s.issue_date,
          left('Credit note ' || s.number || coalesce(' against ' || orig.number, '') || coalesce(': ' || nullif(trim(s.notes), ''), ''), 200) descr,
          case when coalesce(c.is_walk_in, false) then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end ctin,
          case when coalesce(c.is_walk_in, false) then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end cname,
          coalesce(orig.number, s.number) inv_no,
          round(coalesce((select sum(ol.net) from sale_lines ol where ol.sale_id = orig.id), sum(l.net)), 2) inv_amount,
          round(sum(l.net), 2) adjusted
        from sales s join sale_lines l on l.sale_id = s.id left join customers c on c.id = s.customer_id left join sales orig on orig.id = s.original_sale_id
        where s.org_id = p_org and s.doc_type = 'credit_note' and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
          and s.issue_date between v_f and v_t and l.vat_treatment = 'standard' and l.net <> 0
        group by s.id, s.number, s.issue_date, s.notes, s.customer_tin, s.customer_name, c.is_walk_in, c.tin, c.name, orig.id, orig.number) x;

  -- ---- C_2: standard-rated purchases whose VAT is claimed, by bill (and stock receipt), as goods, services or fixed assets ----
  select coalesce(jsonb_object_agg(kind, rows), '{}'::jsonb) into c2
  from (select kind, jsonb_agg(jsonb_build_object('seller', seller, 'tin', tin, 'description', descr, 'amount', amount, 'ref', ref) order by pday, ref) rows
        from (select private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
                private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, o.vat_claim_on_payment_from) as pday, x.number as ref,
                v.name seller, private.vat_tin(v.tin) tin,
                left(x.number || coalesce(' (their ' || nullif(x.vendor_ref, '') || ')', '') || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Purchase'), ', '), 200) descr,
                round(sum(bl.net), 2) amount
              from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id
              where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date <= v_t
                and (x.bill_date >= v_f or x.paid_in_full_on >= v_f)
                and private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, o.vat_claim_on_payment_from) between v_f and v_t
                and bl.vat_recoverable and bl.vat > 0
              group by 1, 2, x.id, x.number, x.vendor_ref, v.name, v.tin
              union all
              select 'goods', dd.d, r.ref, coalesce(v.name, r.vendor_name, 'Supplier'), private.vat_tin(v.tin),
                left('Stock received ' || r.ref || coalesce(' (their ' || nullif(r.invoice_no, '') || ')', ''), 200), round(r.input_vat / v_vr, 2)
              from receipts r left join vendors v on v.id = r.vendor_id left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt'
                cross join lateral (select private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true),
                  rb.paid_in_full_on, o.vat_claim_on_payment_from) d) dd
              where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and dd.d between v_f and v_t) y
        group by kind) z;
  -- Suppliers' credit notes reduce the purchases (the reconciliation column of schedule C).
  select jsonb_build_object('goods', coalesce(sum(n) filter (where kind = 'goods'), 0), 'services', coalesce(sum(n) filter (where kind = 'services'), 0),
      'fixed_assets', coalesce(sum(n) filter (where kind = 'fixed_assets'), 0))
  into c2v
  from (select private.vat_purchase_kind(cl.account_code, ob.wht_category) kind, -round(cl.net, 2) n
        from vendor_credits vc join vendor_credit_lines cl on cl.credit_id = vc.id left join bill_lines ob on ob.id = cl.bill_line_id
        where vc.org_id = p_org and vc.status <> 'void' and vc.journal_id is not null and vc.credit_date between v_f and v_t and cl.vat > 0) q;

  -- ---- C1: standard-rated stock written off (its VAT is taken back), grouped by why ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'amount', amount, 'zero', round(amount * v_zs, 2)) order by descr), '[]'::jsonb) into c1
  from (select case reason when 'Breakage' then 'Damaged or broken stock written off' when 'Expired' then 'Expired stock written off'
            when 'Theft suspected' then 'Stock lost to theft' when 'Written off' then 'Stock written off' else 'Other stock losses written off' end descr,
          round(sum(cost), 2) amount
        from private.vat_stock_writeoffs(p_org, v_f, v_t) group by 1) w;

  -- ---- D: imports, from the customs entries ----
  select coalesce(jsonb_agg(jsonb_build_object('number', number, 'importer', importer, 'description', left(description || coalesce(' (HS ' || hs_code || ')', ''), 250),
      'vessel', vessel, 'country', country, 'form_m', form_m, 'bill_of_lading', bill_of_lading, 'quantity', quantity, 'currency', currency, 'invoice_value', invoice_value,
      'fx_rate', fx_rate, 'value_ngn', value_ngn, 'other_charges', other_charges, 'total_cost', vat_base, 'import_vat', import_vat) order by entry_date, number), '[]'::jsonb)
  into d
  from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t;

  -- ---- E: VAT self-charged on services (and goods) from suppliers abroad, whose VAT is claimed back ----
  v_place_state := coalesce(mn.state, private.ng_state_of_address(coalesce(o.registered_office, o.address)));
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'tin', tin, 'status', 'Self Charge', 'description', descr,
      'category', case kind when 'goods' then 'VATable Local Goods Purchased (Relating to VATable purchases)'
        when 'fixed_assets' then 'VATable Fixed Assets Purchased Locally (Relating to VATable purchases)'
        else 'VATable Local Services Received (Relating to VATable purchases)' end,
      'place', case when st = 'FCT' then 'Federal Capital Territory' else st end, 'amount', amount) order by name, descr), '[]'::jsonb)
  into e
  from (select v.name, private.vat_tin(v.tin) tin, private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
          coalesce(lb.state, v_place_state) st,
          left(x.number || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Service'), ', '), 200) descr, round(sum(bl.net), 2) amount
        from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id left join locations lb on lb.id = bl.location_id
        where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
          and bl.vat_recoverable and bl.reverse_charge_vat > 0
        group by v.name, v.tin, 3, 4, x.id, x.number) r;

  -- ---- F: VAT kept by withholding agents (MDAs, banks, oil and gas companies) on what we sold them ----
  select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'address', address, 'tin', tin, 'nature', nature, 'date', day, 'invoice', invoice,
      'currency', 'NGN', 'invoice_value', value, 'fx_rate', 1, 'value_ngn', value, 'vat', vat) order by day, invoice), '[]'::jsonb)
  into f
  from (select coalesce(cu.name, s.customer_name, 'Customer') agent, left(concat_ws(', ', nullif(trim(cu.address), ''), nullif(trim(cu.city), ''), nullif(trim(cu.state), '')), 250) address,
          private.vat_tin(coalesce(cu.tin, s.customer_tin)) tin,
          case when bool_and(sl.kind = 'service') then 'Supply of services' when bool_or(sl.kind = 'service') then 'Supply of goods and services' else 'Supply of goods' end nature,
          private.local_day(co.org_id, co.received_at) as day, coalesce(s.number, co.number) as invoice,
          -- The invoice's own value before VAT (its VATable lines, less credit notes on them), shared across the agent's payments
          -- on it by the VAT each kept (TaxStreem sign-off N-5). The template credits 7.5% of it; where that differs from what the
          -- agent kept, a check says so. A payment with no invoice keeps the value its VAT implies.
          coalesce(round(iv.vatable * co.amount / nullif(iv.kept, 0), 2), round(co.amount / v_vr, 2)) value, co.amount vat
        from collections co left join sales s on s.id = co.sale_id left join customers cu on cu.id = co.customer_id left join sale_lines sl on sl.sale_id = s.id
          left join lateral (select nullif(greatest((select coalesce(sum(x.net), 0) from sale_lines x where x.sale_id = s.id and x.vat > 0)
              - (select coalesce(sum(x.net), 0) from sales cn join sale_lines x on x.sale_id = cn.id
                 where cn.original_sale_id = s.id and cn.doc_type = 'credit_note' and cn.status <> 'void' and cn.journal_id is not null and x.vat > 0), 0), 0) vatable,
            (select sum(k.amount) from collections k where k.sale_id = s.id and k.method = 'wvat_credit' and k.status = 'confirmed' and k.journal_id is not null) kept) iv on s.id is not null
        where co.org_id = p_org and co.method = 'wvat_credit' and co.status = 'confirmed' and co.journal_id is not null
          and private.local_day(co.org_id, co.received_at) between v_f and v_t
        group by co.id, co.org_id, co.received_at, co.number, co.amount, cu.name, cu.address, cu.city, cu.state, cu.tin, s.customer_name, s.customer_tin, s.number,
          iv.vatable, iv.kept) w;

  -- ---- The form's lines, as the template's formulas work them out ----
  l := jsonb_build_object(
    '10', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r),
    '15', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 1),
    '20', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 2),
    '22', (select coalesce(sum((r->>'adjusted')::numeric), 0) from jsonb_array_elements(b) r),
    '40', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)
      + coalesce((c2v->>'goods')::numeric, 0) + coalesce((c2v->>'services')::numeric, 0) + coalesce((c2v->>'fixed_assets')::numeric, 0),
    '45', -(select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(c1) r),
    '85', (select coalesce(sum((r->>'total_cost')::numeric), 0) from jsonb_array_elements(d) r),
    '105_base', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(e) r),
    '110', (select coalesce(sum(round(v_vr * (r->>'value_ngn')::numeric, 10)), 0) from jsonb_array_elements(f) r));
  l := l || jsonb_build_object('25', (l->>'10')::numeric - (l->>'15')::numeric - (l->>'20')::numeric - (l->>'22')::numeric);
  l := l || jsonb_build_object('35', round((l->>'25')::numeric * v_vr, 2), '55', round(((l->>'40')::numeric + (l->>'45')::numeric) * v_vr, 2),
    '90', round((l->>'85')::numeric * v_vr, 2), '105', round((l->>'105_base')::numeric * v_vr, 2));
  l := l || jsonb_build_object('95', (l->>'55')::numeric + (l->>'90')::numeric);
  l := l || jsonb_build_object('100', (l->>'35')::numeric - (l->>'95')::numeric);
  l := l || jsonb_build_object('115', round((l->>'100')::numeric - ((l->>'105')::numeric + (l->>'110')::numeric), 2));

  -- ---- What to fix, and how the return ties to Counta's VAT for the month ----
  v_net := (mo->>'output')::numeric - (mo->>'wvat_credit')::numeric - (mo->>'input')::numeric;
  -- What line 110 credits beyond the VAT agents kept (their own check explains it, so the tie leaves it out).
  v_wgap := (select coalesce(round(sum(v_vr * (r->>'value_ngn')::numeric - (r->>'vat')::numeric), 2), 0) from jsonb_array_elements(f) r);
  select count(*) into v_lines from vat_a_lines;
  v_tol := greatest(1, round(0.01 * (v_lines + jsonb_array_length(b) + jsonb_array_length(e) + jsonb_array_length(f)
    + (select count(*) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)), 2));
  if v_t >= v_today then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'month_open', 'text', 'The month has not ended, so these figures can still change.');
  end if;
  if vp.period is not null and (abs((mo->>'output')::numeric - vp.output_vat) >= 0.01 or abs((mo->>'input')::numeric - vp.input_vat) >= 0.01
     or abs((mo->>'wvat_credit')::numeric - vp.wvat_credit) >= 0.01) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'changed_since_filing',
      'text', 'Documents for this month changed after the return was filed. The file shows the books as they are now; reopen the return to file the change.');
  end if;
  -- Places.
  for rw in select branch_id, branch_name, bool_or(st is null) no_state, bool_or(st is not null and lga is null) no_lga, count(*) n
           from vat_a_lines where place_from = 'branch' group by branch_id, branch_name having bool_or(st is null) or bool_or(lga is null) loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', case when rw.no_state then 'branch_state' else 'branch_lga' end,
      'text', case when rw.branch_id is null then 'The business has no branch with a state. Add the state and local government area of the main branch.'
        else 'Add the ' || case when rw.no_state then 'state and local government area' else 'local government area' end || ' of ' || rw.branch_name
          || ': its sales (and those of customers whose state is not known) are placed there.' end,
      'fix', jsonb_build_object('kind', 'branch', 'id', rw.branch_id, 'name', rw.branch_name));
  end loop;
  for rw in select customer_id, max(cname) cname, max(st) st from vat_a_lines where place_from = 'customer' and lga is null and customer_id is not null group by customer_id
           order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'customer_lga', 'text', 'Add the local government area of ' || rw.cname || ' (' || rw.st || ').',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname, 'state', rw.st));
  end loop;
  for rw in select customer_id, max(cname) cname, max(c_state) c_state from vat_a_lines
           where place_from = 'branch' and customer_id is not null and nullif(trim(c_state), '') is not null and private.ng_state(c_state) is null
             and not cust_key like 'walkin:%'
             and exists (select 1 from customers cc where cc.id = customer_id and coalesce(upper(cc.country), 'NG') = 'NG')
           group by customer_id order by 2 limit 20 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'customer_state', 'text', rw.cname || '''s state "' || rw.c_state
      || '" is not a Nigerian state Counta knows, so the branch''s state is used. Choose it from the list if the customer is in Nigeria.',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname));
  end loop;
  -- Descriptions of exempt and zero-rated supplies.
  for rw in select item_id, coalesce(max(i.name), max(vl.description)) name, max(vl.treatment) treatment, min(vl.line_id::text)::uuid line_id, sum(vl.amount) amount
           from vat_a_lines vl left join items i on i.id = vl.item_id where vl.cat in (1, 2) and vl.label is null
           group by vl.item_id, case when vl.item_id is null then vl.line_id end order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'label',
      'text', 'Choose the NRS description for ' || rw.name || ' (' || case rw.treatment when 'zero' then 'zero-rated' else 'exempt' end || ', '
        || private.naira(rw.amount) || '). The template takes only its own list.',
      'fix', case when rw.item_id is not null then jsonb_build_object('kind', 'item', 'id', rw.item_id, 'name', rw.name, 'treatment', rw.treatment)
        else jsonb_build_object('kind', 'line', 'id', rw.line_id, 'name', rw.name, 'treatment', rw.treatment) end);
  end loop;
  -- Descriptions in the Act's words that the template's list does not carry yet.
  for rw in select vl.label, count(distinct vl.product) n, (array_agg(distinct vl.product order by vl.product))[1:5] names
           from vat_a_lines vl join nrs_vat_labels nl on nl.label = vl.label and not nl.on_template group by vl.label order by 1 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'label_off_list',
      'text', 'Schedule A describes ' || array_to_string(rw.names, ', ') || case when rw.n > 5 then ' and ' || (rw.n - 5) || ' more' else '' end
        || ' as "' || rw.label || '", the Act''s words. The NRS template''s list does not have them yet; '
        || 'if the portal refuses the file, choose the nearest description on the list for them.');
  end loop;
  -- An agent that kept a different amount from 7.5% of the invoice value: line 110 credits 7.5% of it.
  for rw in select r->>'agent' agent, r->>'invoice' invoice, (r->>'vat')::numeric kept, round(v_vr * (r->>'value_ngn')::numeric, 2) credited
           from jsonb_array_elements(f) r where abs((r->>'vat')::numeric - round(v_vr * (r->>'value_ngn')::numeric, 2)) >= 1 order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'wvat_partial',
      'text', 'On ' || rw.invoice || ', ' || rw.agent || ' kept ' || private.naira(rw.kept) || ' of VAT, but the template credits 7.5% of the invoice value, '
        || private.naira(rw.credited) || '. Check what the agent withheld before you file.');
  end loop;
  if exists (select 1 from jsonb_array_elements(a) r where (r->>'amount')::numeric < 0) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'negative_row',
      'text', 'Credit notes on exempt or zero-rated sales are more than the sales they net against for some rows. Those rows go in as negative amounts, which the portal may refuse.');
  end if;
  -- What the template holds.
  if jsonb_array_length(a) > 9973 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_a', 'text', 'Schedule A holds 9,973 rows and this month has ' || jsonb_array_length(a) || '.');
  end if;
  if jsonb_array_length(e) > 37 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_e', 'text', 'Schedule E holds 37 rows and this month has ' || jsonb_array_length(e) || ' bills with VAT self-charged.');
  end if;
  if jsonb_array_length(f) > 2299 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_f', 'text', 'Schedule F holds 2,299 rows and this month has ' || jsonb_array_length(f) || '.');
  end if;
  if exists (select 1 from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t and abs(import_vat - round(vat_base * v_vr, 2)) >= 1) then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'import_vat', 'text', 'The template takes import VAT as 7.5% of the total cost of each import; '
      || 'some customs entries paid a different amount, so line 90 differs from what was paid.');
  end if;
  if abs((l->>'115')::numeric + v_wgap - v_net) > v_tol then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'tie',
      'text', 'The return comes to ' || private.naira((l->>'115')::numeric) || ' (line 115) and Counta''s VAT for the month to ' || private.naira(v_net)
        || '. The template works VAT out on totals, Counta line by line; a gap of more than ' || private.naira(v_tol) || ' needs a look.');
  end if;

  return jsonb_build_object('period', v_f, 'to', v_t,
    'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'tax_id', private.vat_tin(o.tin), 'state', v_place_state),
    'file_name', to_char(v_f, 'YYYY') || '_' || coalesce(private.vat_tin(o.tin), regexp_replace(coalesce(o.tin, 'NO-TAX-ID'), '[^0-9A-Za-z-]', '', 'g')) || '_VAT_'
      || extract(month from v_f)::int || '.xlsx',
    'a', a, 'b', b, 'c2', jsonb_build_object('goods', coalesce(c2->'goods', '[]'::jsonb), 'services', coalesce(c2->'services', '[]'::jsonb),
      'fixed_assets', coalesce(c2->'fixed_assets', '[]'::jsonb)), 'c_variance', c2v, 'zero_share', v_zs,
    'c1', c1, 'd', d, 'e', e, 'f', f, 'lines', l,
    'counta', mo || jsonb_build_object('net', v_net, 'filed', vp.period is not null, 'status', coalesce(vp.status, 'open')),
    'tolerance', v_tol, 'difference', round((l->>'115')::numeric - v_net, 2), 'wvat_gap', v_wgap,
    'checks', checks, 'blocked', exists (select 1 from jsonb_array_elements(checks) c where c->>'severity' = 'block'));
end $$;


create or replace function public.save_vat_purchase(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v public.vendors; v_vendor uuid; v_name text := nullif(trim(p->>'supplier_name'), '');
  v_tin text := nullif(regexp_replace(coalesce(p->>'supplier_tin', ''), '[^0-9]', '', 'g'), '');
  v_net numeric := round(private.num(p->>'net'), 2); v_vat numeric := round(private.num(p->>'vat'), 2); v_total numeric; v_day date; v_rate numeric; v_vatable numeric;
  v_rest numeric; b public.bills; v_code text; v_lines jsonb; bl public.bank_lines; ba public.bank_accounts; j public.journals; po public.payouts; bp public.bill_payments;
  v_mode text; v_type text := nullif(p->>'supplier_type', ''); v_cat text; v_paid date; v_taken boolean; v_tol numeric; v_amt numeric; v_jl jsonb; x jsonb;
  v_borne numeric := 0; v_today date; v_state text; v_wl numeric; v_keep numeric;
begin
  m := private.require_vat_work(p_org);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  if not o.vat_registered then raise exception 'Input VAT is claimed only by a business that charges VAT.'; end if;
  if v_name is null then raise exception 'Name the supplier on the invoice.'; end if;
  if coalesce(v_vat, 0) <= 0 then raise exception 'This invoice shows no VAT, so there is no input VAT to claim.'; end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount before VAT.'; end if;
  v_total := coalesce(round(private.num(p->>'total'), 2), v_net + v_vat);
  if abs(v_total - (v_net + v_vat)) > 1 then raise exception 'The total (%) is not the amount before VAT plus the VAT (%).', private.naira(v_total), private.naira(v_net + v_vat); end if;
  begin v_day := nullif(p->>'invoice_date', '')::date; exception when others then raise exception 'Check the invoice date.'; end;
  if v_day is null then raise exception 'Enter the invoice date.'; end if;
  if v_day > v_today then raise exception 'The invoice is dated in the future.'; end if;
  v_rate := private.vat_rate(v_day);
  if v_vat > round(v_net * v_rate, 2) + 1 then raise exception 'The VAT (%) is more than % of the amount before VAT. Check the figures.', private.naira(v_vat), (v_rate * 100)::numeric(5,2) || '%'; end if;
  if v_type is not null and v_type not in ('company', 'business_name', 'individual') then raise exception 'Say whether the supplier is a company, a business name or an individual.'; end if;
  v_mode := coalesce(nullif(p->>'payment', ''), case when nullif(p->>'bank_line_id', '') is not null then 'bank_line' when nullif(p->>'payout_id', '') is not null then 'payout' else 'paid' end);
  if v_mode not in ('bank_line', 'payout', 'paid', 'unpaid') then raise exception 'Say how this invoice was paid.'; end if;
  -- Checked before anything is written, so a mistake leaves nothing behind.
  if v_mode = 'paid' then
    select * into ba from bank_accounts where id = nullif(p->>'paid_from', '')::uuid and org_id = p_org and active;
    if not found then raise exception 'Say which account paid this invoice.'; end if;
    begin v_paid := coalesce(nullif(p->>'paid_on', '')::date, v_day); exception when others then raise exception 'Check the date it was paid.'; end;
    if v_paid > v_today then raise exception 'The payment date is in the future.'; end if;
    if v_paid < v_day - 365 then raise exception 'The payment date is more than a year before the invoice.'; end if;
  end if;
  -- The supplier: by Tax ID, else by name, else a new one with what the invoice gives.
  v := private.vat_purchase_vendor(p_org, v_name, v_tin);
  v_vendor := v.id;
  v_state := coalesce(private.ng_state_of_address(nullif(trim(p->>'supplier_state'), '')), private.ng_state_of_address(nullif(trim(p->>'supplier_address'), '')));
  if v_vendor is null then
    insert into vendors (org_id, name, tin, vat_registered, channel, entity_type, is_individual, address, state)
    values (p_org, left(v_name, 120), v_tin, true, 'email', coalesce(v_type, 'company'), coalesce(v_type, 'company') = 'individual',
      left(nullif(trim(p->>'supplier_address'), ''), 300), v_state)
    returning id into v_vendor;
  else
    -- What is on file stays; the invoice fills only what is missing.
    update vendors set tin = coalesce(nullif(trim(tin), ''), v_tin),
      entity_type = coalesce(entity_type, case when not coalesce(is_individual, false) then v_type end),
      address = coalesce(nullif(trim(address), ''), left(nullif(trim(p->>'supplier_address'), ''), 300)),
      state = coalesce(nullif(trim(state), ''), v_state)
    where id = v_vendor;
  end if;
  select * into v from vendors where id = v_vendor;
  if nullif(trim(p->>'invoice_no'), '') is not null and exists (select 1 from bills where org_id = p_org and vendor_id = v_vendor and status <> 'void'
       and lower(vendor_ref) = lower(trim(p->>'invoice_no'))) then
    raise exception 'Invoice % from % is already in the books.', trim(p->>'invoice_no'), v_name;
  end if;
  v_cat := case when p ? 'wht_category' then coalesce(nullif(p->>'wht_category', ''), nullif(v.wht_category, ''), 'none') else 'none' end;
  if not exists (select 1 from wht_rates where code = v_cat) then raise exception 'Choose the kind of purchase for withholding tax.'; end if;
  v_code := coalesce(nullif(p->>'account_code', ''), v.default_account,
    case when exists (select 1 from items where org_id = p_org) then private.acct(p_org, 'purchases') else private.acct(p_org, 'expenses_default') end);
  -- The part of the price that carries VAT, from the VAT shown; whatever else is on the invoice carries none.
  v_vatable := least(round(v_vat / v_rate, 2), v_net);
  v_rest := round(v_net - v_vatable, 2);
  v_lines := jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(p->>'description'), ''), 'Purchase'), 300), 'account_code', v_code,
    'qty', 1, 'unit_cost', v_vatable, 'vat_treatment', 'standard'));
  if v_rest >= 0.01 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', 'Part of the invoice with no VAT', 'account_code', v_code, 'qty', 1, 'unit_cost', v_rest,
      'vat_treatment', 'exempt'));
  end if;
  b := private.write_bill(p_org, jsonb_build_object('vendor_id', v_vendor, 'vendor_ref', nullif(trim(p->>'invoice_no'), ''), 'source', 'ai', 'bill_date', v_day,
    'due_date', case when v_mode <> 'unpaid' then v_day end, 'prices_include_vat', false, 'vat_charged', true, 'wht_category', v_cat,
    'document_path', nullif(p->>'document_path', ''), 'notes', 'Input VAT claim from an uploaded invoice', 'lines', v_lines), m);
  -- The VAT as printed (the bill worked it out from the rate; a kobo or two of rounding is the invoice's).
  update bill_lines set vat = v_vat, gross = net + v_vat where bill_id = b.id and line_no = 1;
  update bills set vat_total = (select sum(vat) from bill_lines where bill_id = b.id), total = (select sum(gross) from bill_lines where bill_id = b.id) where id = b.id;
  b := private.bill_wht(b.id);
  b := private.post_bill(b.id, m);
  select * into b from bills where id = b.id;
  v_tol := greatest(100, round(b.total * 0.005, 2));
  -- What a payment keeps back: the WHT, and the VAT withheld by a business that withholds VAT.
  v_keep := b.wht_expected + b.wvat_expected;
  if v_mode = 'bank_line' then
    select * into bl from bank_lines where id = nullif(p->>'bank_line_id', '')::uuid and org_id = p_org for update;
    if not found or bl.amount >= 0 then raise exception 'Choose the payment out of the bank that paid this invoice.'; end if;
    if bl.status in ('matched', 'ignored') then raise exception 'That bank line is already settled. Choose another.'; end if;
    v_amt := abs(bl.amount);
    if not (v_amt - b.total between -0.005 and v_tol) and not (v_keep > 0 and v_amt - (b.total - v_keep) between -0.005 and v_tol) then
      raise exception 'The bank line (%) and the invoice (%) differ by more than bank charges%.', private.naira(v_amt), private.naira(b.total),
        case when v_keep > 0 then ', with or without the WHT of ' || private.naira(v_keep) else '' end;
    end if;
    -- Whatever the line was posted to before (suspense, or an expense with no VAT) is taken back.
    if bl.journal_id is not null then perform private.reverse_entry(bl.journal_id, m.id, 'Paid ' || b.number || ' with input VAT from the invoice', null); end if;
    update ai_proposals set status = 'superseded' where source_type = 'bank_line' and source_id = bl.id and status in ('pending', 'info', 'auto_posted');
    update bank_lines set status = 'unmatched', journal_id = null, proposal_id = null where id = bl.id;
    perform private.apply_match(bl.id, jsonb_build_object('kind', 'bill', 'id', b.id, 'basis', 'exact'), m, null);
    select * into bp from bill_payments where bill_id = b.id and status = 'paid' order by created_at desc limit 1;
    if b.wht_expected > 0 and coalesce(bp.wht, 0) = 0 then v_borne := private.book_borne_wht(bp.id, m, true); end if;
  elsif v_mode = 'payout' then
    select * into po from payouts where id = nullif(p->>'payout_id', '')::uuid and org_id = p_org for update;
    if not found or po.status <> 'successful' or po.journal_id is null then raise exception 'Choose a payout from the wallet that went through.'; end if;
    if exists (select 1 from bill_payments where payout_id = po.id) then raise exception 'That payout already paid a bill. Choose another.'; end if;
    v_taken := v_keep > 0 and abs(po.amount - (b.total - v_keep)) <= 0.01;
    if not v_taken and abs(po.amount - b.total) > 0.01 then
      raise exception 'The payout (%) is neither the invoice''s total (%) nor its total less WHT (%).', private.naira(po.amount), private.naira(b.total),
        private.naira(b.total - v_keep);
    end if;
    select coalesce(sum((l->>'debit')::numeric), 0) into v_wl from jsonb_array_elements(po.lines) l;
    if abs(v_wl - po.amount) > 0.01 then raise exception 'Payout % cannot be moved onto a bill. Attach the invoice to its bank line instead.', po.number; end if;
    select * into ba from bank_accounts where id = (select bank_account_id from wallets where id = po.wallet_id);
    -- What the payout was posted to moves onto the bill: the supplier's account now carries it, with the WHT kept back.
    v_jl := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', b.total, 'party_type', 'vendor', 'party_id', v.id,
      'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number || ' paid by payout ' || po.number));
    for x in select value from jsonb_array_elements(po.lines) loop
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', x->>'code', 'credit', (x->>'debit')::numeric, 'party_type', x->>'party_type', 'party_id', x->>'party_id',
        'memo', 'Payout ' || po.number || ' moved onto ' || b.number));
    end loop;
    if v_taken then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'wht_payable'), 'credit', b.wht_expected, 'party_type', 'vendor', 'party_id', v.id,
        'doc_type', 'bill', 'doc_id', b.id, 'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number),
        jsonb_build_object('code', private.acct(p_org, 'wvat_payable'), 'credit', b.wvat_expected, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'VAT withheld on ' || b.number));
    elsif b.wht_expected > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', '6512', 'debit', b.wht_expected, 'memo', 'WHT on ' || b.number || ' not taken off the payment to ' || v.name),
        jsonb_build_object('code', private.acct(p_org, 'wht_payable'), 'credit', b.wht_expected, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'WHT on ' || b.number || ', borne by the business'));
    end if;
    j := private.post_entry(p_org, 'Paid ' || v.name || ' · ' || b.number || ' by payout ' || po.number, 'bill_payment', b.id, m.id, m.id, v_jl, coalesce(po.completed_at, po.created_at),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payout', 'id', po.id, 'ref', po.number))));
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, bank_account_id, payout_id, paid_at, reference, journal_id, created_by)
    values (p_org, b.id, 'wallet', 'paid', b.total, case when v_taken then b.wht_expected else 0 end, case when v_taken then b.wvat_expected else 0 end, po.amount, ba.id, po.id,
      coalesce(po.completed_at, po.created_at),
      coalesce(po.reference, po.number), j.id, m.id)
    returning * into bp;
    if not v_taken and b.wht_expected > 0 then v_borne := private.book_borne_wht(bp.id, m, false); end if;
    perform private.refresh_bill(b.id);
  elsif v_mode = 'paid' then
    v_taken := coalesce((p->>'wht_taken')::boolean, true) and v_keep > 0;
    j := private.record_bill_payment(b.id, ba.id, b.total, case when v_taken then v_keep else 0 end, private.posting_time(p_org, v_paid),
      coalesce(nullif(trim(p->>'invoice_no'), ''), b.number), m);
    select * into bp from bill_payments where journal_id = j.id;
    if not v_taken and b.wht_expected > 0 then v_borne := private.book_borne_wht(bp.id, m, true); end if;
  end if;
  select * into b from bills where id = b.id;
  return jsonb_build_object('bill', jsonb_build_object('id', b.id, 'number', b.number, 'status', b.status, 'net', b.subtotal, 'vat', b.vat_total, 'total', b.total,
      'wht', b.wht_expected, 'wht_withheld', b.wht_withheld, 'wht_borne', b.wht_borne, 'wht_category', b.wht_category, 'due_date', b.due_date),
    'vendor_id', v_vendor, 'payment', v_mode, 'vat_month', date_trunc('month', private.bill_vat_day(b.id))::date,
    'paid_on', case when bp.id is not null then private.local_day(p_org, bp.paid_at) end,
    'wht_month', case when bp.id is not null and b.wht_expected > 0 then date_trunc('month', private.local_day(p_org, bp.paid_at))::date end);
end $$;


create or replace function private.doc_rows(p_org uuid, m public.members, p_from date, p_to date, p_undated boolean default true)
returns table (id text, cat text, folder text, sub text, period date, year int, day date, name text, kind text, path text, mime text,
  size bigint, ref text, party text, amount numeric, at timestamptz, source text)
language plpgsql stable security definer set search_path = public, private as $$
#variable_conflict use_column
declare c jsonb := private.doc_can(m); v_pre text := p_org::text || '/';
begin
  if c->>'sales' = 'true' then
    -- Invoices, receipts for named customers, credit notes, quotes and orders.
    return query
      select 'sale:' || s.id, 'sales', case s.doc_type when 'invoice' then 'Invoices' when 'receipt' then 'Receipts' when 'credit_note' then 'Credit notes'
          when 'quote' then 'Quotes' else 'Orders' end, null::text, date_trunc('month', s.issue_date)::date, extract(year from s.issue_date)::int, s.issue_date,
        s.number || coalesce(' · ' || nullif(s.customer_name, ''), '') || case when s.status = 'void' then ' (void)' else '' end,
        'sale', null::text, 'application/pdf', null::bigint, s.id::text, s.customer_name, s.total, s.created_at, 'counta'
      from sales s left join customers cu on cu.id = s.customer_id
      where s.org_id = p_org and s.issue_date between p_from and p_to and s.status not in ('draft', 'converted')
        and s.doc_type in ('invoice', 'receipt', 'credit_note', 'quote', 'order')
        and not (s.doc_type = 'receipt' and (s.customer_id is null or coalesce(cu.is_walk_in, false)));
    -- Walk-in till receipts: one PDF a day.
    return query
      select 'till:' || s.issue_date::text, 'sales', 'Till receipts', null::text, date_trunc('month', s.issue_date)::date, extract(year from s.issue_date)::int,
        s.issue_date, 'Till receipts, ' || to_char(s.issue_date, 'FMDD Mon YYYY') || ' (' || count(*) || ' ' || case when count(*) = 1 then 'sale' else 'sales' end || ')',
        'till', null::text, 'application/pdf', null::bigint, s.issue_date::text, null::text, sum(s.total), max(s.created_at), 'counta'
      from sales s left join customers cu on cu.id = s.customer_id
      where s.org_id = p_org and s.issue_date between p_from and p_to and s.doc_type = 'receipt' and s.status not in ('draft', 'void', 'converted')
        and (s.customer_id is null or coalesce(cu.is_walk_in, false))
      group by s.issue_date;
    return query
      select 'delivery:' || d.id, 'sales', 'Delivery proofs', null::text, date_trunc('month', d.delivered_at)::date, extract(year from d.delivered_at)::int,
        d.delivered_at::date, d.number || coalesce(' · ' || nullif(d.received_by, ''), ''), 'file', d.proof_path, null::text, null::bigint, d.id::text,
        d.received_by, null::numeric, d.delivered_at, 'counta'
      from deliveries d where d.org_id = p_org and d.proof_path like v_pre || '%' and d.delivered_at::date between p_from and p_to;
  end if;

  if c->>'purchases' = 'true' then
    return query
      select 'bill:' || b.id, 'purchases', case when b.source = 'portal' or exists (select 1 from supplier_invoices si where si.bill_id = b.id) then 'From suppliers'
          else 'Supplier invoices' end,
        null::text, date_trunc('month', b.bill_date)::date, extract(year from b.bill_date)::int, b.bill_date,
        coalesce(nullif(b.vendor_ref, ''), b.number) || coalesce(' · ' || v.name, '') || case when b.status = 'void' then ' (void)' else '' end,
        'file', b.document_path, null::text, null::bigint, b.id::text, v.name, b.total, b.created_at, 'counta'
      from bills b left join vendors v on v.id = b.vendor_id
      where b.org_id = p_org and b.document_path like v_pre || '%' and b.bill_date between p_from and p_to;
    -- Invoices suppliers sent through the portal that are not bills (yet, or at all).
    return query
      select 'si:' || si.id, 'purchases', 'From suppliers', null::text, date_trunc('month', si.created_at)::date, extract(year from si.created_at)::int,
        si.created_at::date, coalesce(nullif(si.file_name, ''), si.number) || ' (' || replace(si.status, '_', ' ') || ')', 'file', si.document_path, si.mime,
        si.file_size::bigint, si.id::text, coalesce(si.submitter->>'name', si.submitter->>'business'), null::numeric, si.created_at, 'counta'
      from supplier_invoices si
      where si.org_id = p_org and si.bill_id is null and si.document_path like v_pre || '%' and si.created_at::date between p_from and p_to
        and not exists (select 1 from bills b where b.org_id = p_org and b.document_path = si.document_path);
    return query
      select 'receipt:' || r.id, 'purchases', 'Stock received', null::text, date_trunc('month', coalesce(r.invoice_date, r.created_at::date))::date,
        extract(year from coalesce(r.invoice_date, r.created_at::date))::int, coalesce(r.invoice_date, r.created_at::date),
        coalesce(nullif(r.invoice_no, ''), r.ref) || coalesce(' · ' || nullif(r.vendor_name, ''), ''), 'file', r.document_path, r.document_mime, null::bigint,
        r.id::text, r.vendor_name, r.gross, r.created_at, 'counta'
      from receipts r
      where r.org_id = p_org and r.document_path like v_pre || '%' and coalesce(r.invoice_date, r.created_at::date) between p_from and p_to
        and not exists (select 1 from bills b where b.org_id = p_org and b.document_path = r.document_path);
    -- Every bill whose input VAT is claimed, in the month it is claimed (the month it was paid in full): its own file, or the
    -- bill drawn as a PDF when it was typed in by hand.
    return query
      select 'vat:' || b.id, 'purchases', 'Input VAT invoices', null::text, date_trunc('month', vd.d)::date, extract(year from vd.d)::int, vd.d,
        coalesce(nullif(b.vendor_ref, ''), b.number) || coalesce(' · ' || v.name, ''),
        case when b.document_path like v_pre || '%' then 'file' else 'bill' end,
        case when b.document_path like v_pre || '%' then b.document_path end, case when b.document_path like v_pre || '%' then null::text else 'application/pdf' end,
        null::bigint, b.id::text, v.name, b.total, b.created_at, 'counta'
      from bills b left join vendors v on v.id = b.vendor_id cross join lateral (select private.bill_vat_day(b.id) d) vd
      where b.org_id = p_org and b.journal_id is not null and b.status = 'paid' and b.vat_total > 0 and b.source <> 'import'
        and b.bill_date <= p_to and (b.bill_date >= p_from or b.paid_in_full_on >= p_from) and vd.d between p_from and p_to;
    return query
      select 'vcredit:' || vc.id, 'purchases', 'Supplier credit notes', null::text, date_trunc('month', vc.credit_date)::date, extract(year from vc.credit_date)::int,
        vc.credit_date, coalesce(nullif(vc.vendor_ref, ''), vc.number) || coalesce(' · ' || v.name, ''), 'file', vc.document_path, null::text, null::bigint,
        vc.id::text, v.name, vc.total, vc.created_at, 'counta'
      from vendor_credits vc left join vendors v on v.id = vc.vendor_id
      where vc.org_id = p_org and vc.document_path like v_pre || '%' and vc.credit_date between p_from and p_to;
    return query
      select 'customs:' || ce.id, 'purchases', 'Import entries', null::text, date_trunc('month', ce.entry_date)::date, extract(year from ce.entry_date)::int,
        ce.entry_date, ce.number || coalesce(' · ' || nullif(ce.description, ''), ''), 'file', ce.document_path, null::text, null::bigint, ce.id::text,
        ce.importer, ce.value_ngn, ce.created_at, 'counta'
      from customs_entries ce where ce.org_id = p_org and ce.document_path like v_pre || '%' and ce.entry_date between p_from and p_to;
  end if;

  if c->>'tax' = 'true' then
    -- The files Counta made for each return (and the audited statements kept with a CIT year), as they are stored.
    return query
      select 'obj:' || o.id::text, 'tax',
        case x[1] when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' else 'CIT' end,
        case when x[1] = 'cit' and o.name like v_pre || 'tax/cit/%/afs/%' then 'Audited statements' else 'Return files' end,
        case when x[1] = 'cit' then null::date else (x[2] || '-01')::date end,
        case when x[1] = 'cit' then x[2]::int else left(x[2], 4)::int end,
        case when x[1] = 'cit' then null::date else (x[2] || '-01')::date end,
        regexp_replace(o.name, '^.*/', ''), 'file', o.name, o.metadata->>'mimetype', nullif(o.metadata->>'size', '')::bigint, null::text, null::text,
        null::numeric, o.created_at, 'counta'
      from storage.objects o, lateral (select regexp_match(o.name, '^[^/]+/tax/(vat|wht|wvat|cit)/([0-9]{4}(?:-[0-9]{2})?)/')) r(x)
      where o.bucket_id = 'documents' and o.name like v_pre || 'tax/%' and x is not null
        and ((x[1] = 'cit' and x[2] ~ '^[0-9]{4}$' and make_date(x[2]::int, 12, 31) >= p_from and make_date(x[2]::int, 1, 1) <= p_to)
          or (x[1] <> 'cit' and x[2] ~ '^[0-9]{4}-[0-9]{2}$' and (x[2] || '-01')::date between date_trunc('month', p_from)::date and p_to));
    -- The accountant's versions of a schedule (financial statements are under Accountant). VAT and WHT periods are months
    -- ('2026-09'), CIT periods years ('2025'), financial statements a span ('2025-01-01:2025-12-31', kept with its last year).
    return query
      select 'version:' || fv.id, case when fv.kind = 'fs' then 'accountant' else 'tax' end,
        case fv.kind when 'vat' then 'VAT' when 'wht' then 'WHT' when 'cit' then 'CIT' else 'Financial statements' end,
        case when fv.kind = 'fs' then null else 'Accountant versions' end, pp.per, pp.yr, pp.per,
        fv.file_name || ' (version ' || fv.version || coalesce(', ' || nullif(fv.practice_name, ''), '') || ')', 'file', fv.file_path, null::text, fv.size_bytes::bigint,
        fv.id::text, fv.uploader_name, null::numeric, fv.created_at, 'accountant'
      from filing_versions fv,
        lateral (select case when fv.kind in ('vat', 'wht') and fv.period ~ '^[0-9]{4}-[0-9]{2}' then (left(fv.period, 7) || '-01')::date end as per,
          coalesce(case when fv.kind = 'fs' then substring(fv.period from '([0-9]{4})-[0-9]{2}-[0-9]{2}$') else substring(fv.period from '^([0-9]{4})') end,
            extract(year from fv.created_at)::text)::int as yr) pp
      where fv.org_id = p_org and fv.file_path like v_pre || '%' and (fv.kind <> 'fs' or c->>'accountant' = 'true')
        and ((pp.per is not null and pp.per between date_trunc('month', p_from)::date and p_to)
          or (pp.per is null and make_date(pp.yr, 12, 31) >= p_from and make_date(pp.yr, 1, 1) <= p_to));
    -- The PRN and payment Rev360 asked for: a slip Counta makes when it is opened.
    return query
      select 'prn:' || t.id, 'tax', case t.tax when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' else 'CIT' end, 'PRN and payment',
        case when t.tax = 'cit' then null::date else date_trunc('month', t.period)::date end,
        coalesce(t.accounting_year, extract(year from t.period)::int), case when t.tax = 'cit' then null::date else t.period end,
        'PRN ' || t.prn || ' · ' || replace(t.status, '_', ' '), 'prn', null::text, 'application/pdf', null::bigint, t.id::text, t.authority, t.amount, t.received_at, 'flux'
      from tax_payment_instructions t where t.org_id = p_org and t.period between date_trunc('month', p_from)::date and p_to;
    return query
      select 'wrem:' || w.id, 'tax', case when w.kind = 'wvat' then 'Withholding VAT' else 'WHT' end, 'Payment receipts', date_trunc('month', w.period)::date,
        extract(year from w.period)::int, w.period, coalesce(nullif(w.reference, ''), 'Remittance') || ' · ' || w.authority, 'file', w.receipt_path, null::text,
        null::bigint, w.id::text, w.authority, w.amount, w.created_at, 'counta'
      from wht_remittances w where w.org_id = p_org and w.receipt_path like v_pre || '%' and w.period between date_trunc('month', p_from)::date and p_to;
  end if;

  if c->>'accountant' = 'true' then
    return query
      select 'request:' || pr.id, 'accountant', 'Requests', null::text, date_trunc('month', coalesce(pr.answered_at, pr.created_at))::date,
        extract(year from coalesce(pr.answered_at, pr.created_at))::int, coalesce(pr.answered_at, pr.created_at)::date,
        coalesce(nullif(pr.file_name, ''), 'File') || ' · ' || pr.title, 'file', pr.file_path, null::text, null::bigint, pr.id::text, null::text, null::numeric,
        coalesce(pr.answered_at, pr.created_at), 'accountant'
      from practice_requests pr where pr.org_id = p_org and pr.file_path like v_pre || '%' and coalesce(pr.answered_at, pr.created_at)::date between p_from and p_to;
  end if;

  -- The CAC records the owner filed in onboarding hold the directors' details: the owner's alone.
  if m.role = 'owner' and p_undated then
    return query
      select 'kyc:' || k.id, 'company', 'Registration', null::text, null::date, null::int, null::date,
        coalesce(nullif(k.doc->>'file_name', ''), 'CAC records'), 'file', k.doc->>'path', nullif(k.doc->>'mime', ''), null::bigint, k.id::text, null::text,
        null::numeric, coalesce(k.updated_at, k.created_at), 'counta'
      from kyc_profiles k where k.org_id = p_org and k.doc->>'path' like v_pre || 'kyc/%' and k.doc->>'path' not like '%nin-slip%';
  end if;

  -- Uploaded files and what Flux sent back.
  return query
    select 'doc:' || d.id, d.cat, d.folder, d.sub, d.period, coalesce(d.year, extract(year from d.period)::int), d.period, d.name, 'file', d.path, d.mime, d.size,
      d.id::text, (select display_name from members where id = d.uploaded_by), null::numeric, d.created_at, d.source
    from documents d
    where d.org_id = p_org and coalesce(c->>d.cat, 'false') = 'true'
      and ((d.period is not null and d.period between date_trunc('month', p_from)::date and p_to)
        or (d.period is null and d.year is not null and make_date(d.year, 12, 31) >= p_from and make_date(d.year, 1, 1) <= p_to)
        or (d.period is null and d.year is null and p_undated));
end $$;


CREATE OR REPLACE FUNCTION private.doc_folder_rank(p_cat text, p_folder text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(array_position(case p_cat
    when 'sales' then array['Invoices', 'Receipts', 'Till receipts', 'Credit notes', 'Quotes', 'Orders', 'Delivery proofs']
    when 'purchases' then array['Supplier invoices', 'From suppliers', 'Input VAT invoices', 'Stock received', 'Supplier credit notes', 'Import entries']
    when 'tax' then array['VAT', 'WHT', 'Withholding VAT', 'CIT', 'PIT']
    else array[]::text[] end, p_folder), 50)
$function$;


create or replace function private.bill_json(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(b) || jsonb_build_object(
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'bank_code', v.bank_code, 'bank_name', v.bank_name,
        'account_number', v.account_number, 'account_name', v.account_name, 'wht_category', v.wht_category, 'entity_type', v.entity_type, 'resident', v.resident,
        'state', v.state, 'rc_number', v.rc_number, 'nin', private.vendor_nin(v.id), 'is_manufacturer', v.is_manufacturer, 'wht_exempt', v.wht_exempt,
        'email', v.email, 'phone', v.phone, 'address', v.address,
        'wht_profile', private.vendor_wht_profile(v.id)) from vendors v where v.id = b.vendor_id),
    'balance', case when b.status in ('approved', 'partially_paid') then b.total - b.amount_paid else 0 end,
    'in_progress', (select coalesce(sum(gross), 0) from bill_payments where bill_id = b.id and status = 'processing'),
    'to_withhold', case when b.status in ('approved', 'partially_paid') then private.bill_withholding(b.id, b.total - b.amount_paid) end,
    'tax_flags', private.bill_tax_flags(b.id),
    'return_notes', jsonb_build_object('missing_tin', private.return_note('missing_tin'), 'missing_state', private.return_note('missing_state')),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', mg.id, 'template', mg.template, 'channel', mg.channel, 'to', mg.to_address, 'status', mg.status,
        'error', mg.error, 'created_at', mg.created_at) order by mg.created_at), '[]'::jsonb) from messages mg where mg.bill_id = b.id),
    'returned_by_name', (select display_name from members where id = b.returned_by),
    'overdue_days', case when b.status in ('approved', 'partially_paid') then greatest(private.local_day(b.org_id, now()) - b.due_date, 0) end,
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('account_name', private.account_name(b.org_id, l.account_code),
        'creditable', private.bill_line_creditable(l.id), 'wht_category_effective', coalesce(l.wht_category, b.wht_category)) order by l.line_no), '[]'::jsonb)
              from bill_lines l where l.bill_id = b.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' || jsonb_build_object('payout_number', (select number from payouts where id = p.payout_id),
        'payout_status', (select status from payouts where id = p.payout_id)) order by p.paid_at), '[]'::jsonb) from bill_payments p where p.bill_id = b.id),
    'deductions', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'category', d.category, 'amount', d.amount, 'base', d.base, 'rate', d.rate,
        'authority', d.authority, 'authority_name', (select case when a.code = 'NRS' then 'NRS' else a.state || ' (' || coalesce(a.short_name, a.name) || ')' end
          from tax_authorities a where a.code = d.authority),
        'due_date', d.due_date, 'status', d.status, 'receipt_no', d.receipt_no) order by d.created_at), '[]'::jsonb)
        from wht_deductions d where d.bill_id = b.id and d.status <> 'void'),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', vc.id, 'number', vc.number, 'vendor_ref', vc.vendor_ref, 'total', vc.total, 'credit_date', vc.credit_date,
        'reason', vc.reason, 'status', vc.status) order by vc.credit_date), '[]'::jsonb) from vendor_credits vc where vc.bill_id = b.id and vc.status <> 'void'),
    'supplier_credit', (select coalesce(sum(vc.total - vc.applied - vc.refunded), 0) from vendor_credits vc where vc.vendor_id = b.vendor_id and vc.status = 'open'),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'number', a.number, 'name', a.name, 'status', a.status)), '[]'::jsonb) from fixed_assets a where a.bill_id = b.id),
    'journal_ref', (select ref from journals where id = b.journal_id),
    'vat_day', private.bill_vat_day(b.id),
    'supplier_invoice_id', (select si.id from supplier_invoices si where si.bill_id = b.id order by si.created_at desc limit 1),
    'receipt_ref', (select r.ref from receipts r where r.id = b.receipt_id and r.status = 'posted'),
    'created_by_name', (select display_name from members where id = b.created_by),
    'approved_by_name', (select display_name from members where id = b.approved_by))
  from bills b where b.id = p_bill
$$;



revoke all on function private.bill_paid_on(uuid), private.on_bill_paid_day(), private.on_bill_payment_day(), private.vat_claim_day(date, boolean, date, date),
  private.bill_vat_day(uuid) from public, anon, authenticated;
revoke execute on function public.input_vat_invoices(uuid, jsonb), public.documents_bill(uuid, uuid) from public, anon;
grant execute on function public.input_vat_invoices(uuid, jsonb), public.documents_bill(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Supplier invoices that receive stock
-- ---------------------------------------------------------------------------
-- The reader is told what the business does and what is on its items list. Each line of an uploaded invoice is stock (an
-- item on the list, or a new product), a fixed asset or an expense. Stock lines are bought into purchases on the bill; when
-- the invoice is approved, the person sees each one with its quantity (lower it if less arrived), the branch it goes to, and
-- any new product to add, and the stock goes in. The bill keeps the purchase, its VAT and what is owed; the stock receipt
-- only moves the stock into the branch, so nothing is counted twice.
alter table public.bill_lines add column if not exists stock boolean not null default false;
alter table public.bill_lines add column if not exists item_id uuid references public.items(id) on delete set null;
alter table public.bill_lines add column if not exists new_item jsonb;
alter table public.bill_lines add column if not exists unit_kind text check (unit_kind in ('purchase', 'selling'));
alter table public.bill_lines add column if not exists received_qty numeric(14,3);
create index if not exists bill_lines_item on public.bill_lines(item_id) where item_id is not null;

create or replace function private.write_bill(p_org uuid, p jsonb, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; o public.orgs; x jsonb; v_no int := 0; v_qty numeric; v_cost numeric; v_base numeric; v_net numeric; v_vat numeric;
  v_treat text; v_rate numeric; v_id uuid := nullif(p->>'id', '')::uuid; v_vendor uuid := nullif(p->>'vendor_id', '')::uuid; v_day date; v_code text;
  v_wht_cat text; v_recov boolean; v_line_cat text; v_item uuid; v_new jsonb; v_stock boolean;
begin
  select * into o from orgs where id = p_org;
  if nullif(p->>'client_uuid', '') is not null and v_id is null then
    select * into b from bills where client_uuid = (p->>'client_uuid')::uuid;
    if found then return b; end if;
  end if;
  if v_vendor is null and coalesce(trim(p->'vendor'->>'name'), '') <> '' then
    select id into v_vendor from vendors where org_id = p_org and (lower(name) = lower(trim(p->'vendor'->>'name'))
      or (nullif(trim(p->'vendor'->>'tin'), '') is not null and tin = trim(p->'vendor'->>'tin'))) limit 1;
    if v_vendor is null then
      insert into vendors (org_id, name, tin, is_individual, wht_category, bank_code, bank_name, account_number, account_name, vat_registered, channel, phone, email,
        entity_type, resident, state, address, rc_number, country)
      values (p_org, left(trim(p->'vendor'->>'name'), 120), nullif(trim(p->'vendor'->>'tin'), ''), coalesce((p->'vendor'->>'is_individual')::boolean, false),
        nullif(p->'vendor'->>'wht_category', ''), nullif(p->'vendor'->>'bank_code', ''), nullif(p->'vendor'->>'bank_name', ''),
        nullif(p->'vendor'->>'account_number', ''), nullif(p->'vendor'->>'account_name', ''), coalesce((p->>'vat_charged')::boolean, true), 'email',
        nullif(p->'vendor'->>'phone', ''), nullif(p->'vendor'->>'email', ''),
        coalesce(nullif(p->'vendor'->>'entity_type', ''), case when coalesce((p->'vendor'->>'is_individual')::boolean, false) then 'individual' end),
        coalesce((p->'vendor'->>'resident')::boolean, true), nullif(trim(p->'vendor'->>'state'), ''), nullif(trim(p->'vendor'->>'address'), ''),
        nullif(trim(p->'vendor'->>'rc_number'), ''), coalesce(nullif(p->'vendor'->>'country', ''), 'NG'))
      returning id into v_vendor;
      if regexp_replace(coalesce(p->'vendor'->>'nin', ''), '\D', '', 'g') ~ '^[0-9]{11}$' then perform private.set_vendor_nin(v_vendor, p->'vendor'->>'nin', m.id); end if;
    end if;
  end if;
  select * into v from vendors where id = v_vendor and org_id = p_org;
  if not found then raise exception 'Choose the vendor.'; end if;
  v_day := coalesce(nullif(p->>'bill_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A bill cannot be dated in the future.'; end if;
  v_wht_cat := coalesce(nullif(p->>'wht_category', ''), v.wht_category, 'none');
  if not exists (select 1 from wht_rates where code = v_wht_cat) then raise exception 'Unknown withholding tax category.'; end if;
  if v_id is null then
    insert into bills (org_id, number, vendor_id, vendor_ref, source, external_ref, bill_date, due_date, prices_include_vat, vat_charged, wht_category,
      notes, document_path, created_by, client_uuid)
    values (p_org, 'BILL-' || lpad(private.next_no(p_org, 'BILL', 1)::text, 4, '0'), v.id, nullif(trim(p->>'vendor_ref'), ''),
      coalesce(nullif(p->>'source', ''), 'manual'), nullif(p->>'external_ref', ''), v_day,
      coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)), coalesce((p->>'prices_include_vat')::boolean, false),
      coalesce((p->>'vat_charged')::boolean, coalesce(v.vat_registered, true) and coalesce(v.resident, true)), v_wht_cat, nullif(trim(p->>'notes'), ''),
      nullif(p->>'document_path', ''), m.id, nullif(p->>'client_uuid', '')::uuid)
    returning * into b;
  else
    select * into b from bills where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status <> 'draft' then raise exception '% is already approved. Void it and enter it again.', b.number; end if;
    update bills set vendor_id = v.id, vendor_ref = case when p ? 'vendor_ref' then nullif(trim(p->>'vendor_ref'), '') else vendor_ref end, bill_date = v_day,
      due_date = coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)),
      prices_include_vat = coalesce((p->>'prices_include_vat')::boolean, prices_include_vat), vat_charged = coalesce((p->>'vat_charged')::boolean, vat_charged),
      wht_category = v_wht_cat, notes = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else notes end,
      document_path = coalesce(nullif(p->>'document_path', ''), document_path)
    where id = b.id returning * into b;
  end if;
  if b.due_date < b.bill_date then raise exception 'The due date is before the bill date.'; end if;
  if p ? 'lines' then
    delete from bill_lines where bill_id = b.id;
    if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line.'; end if;
    for x in select * from jsonb_array_elements(p->'lines') loop
      v_no := v_no + 1;
      v_code := nullif(trim(x->>'account_code'), '');
      -- A line of stock (from an uploaded invoice): an item on the list, or a new one the person may add when approving. It is
      -- bought into purchases; approving receives it into stock.
      v_item := (select id from items where id = case when x->>'item_id' ~ '^[0-9a-f-]{36}$' then (x->>'item_id')::uuid end and org_id = p_org and not archived);
      v_new := case when jsonb_typeof(x->'new_item') = 'object' and coalesce(trim(x->'new_item'->>'name'), '') <> '' then x->'new_item' end;
      v_stock := coalesce((x->>'stock')::boolean, false) and (v_item is not null or v_new is not null);
      if v_stock then v_code := private.acct(p_org, 'purchases'); end if;
      if v_code is null or not private.bill_account_ok(p_org, v_code) then
        raise exception 'Line %: choose an expense, stock or asset account.', v_no;
      end if;
      v_qty := coalesce(round(private.num(x->>'qty'), 3), 1);
      v_cost := round(private.num(x->>'unit_cost'), 2);
      if v_qty <= 0 or v_cost is null or v_cost < 0 then raise exception 'Line %: enter the quantity and cost.', v_no; end if;
      v_treat := case when not b.vat_charged then 'none' else coalesce(nullif(x->>'vat_treatment', ''), 'standard') end;
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_line_cat := nullif(x->>'wht_category', '');
      if v_line_cat is not null and not exists (select 1 from wht_rates where code = v_line_cat) then raise exception 'Line %: unknown withholding tax category.', v_no; end if;
      v_rate := case when v_treat = 'standard' then private.vat_rate(v_day) else 0 end;
      v_base := round(v_qty * v_cost, 2);
      if b.prices_include_vat then v_net := round(v_base / (1 + v_rate), 2); v_vat := v_base - v_net;
      else v_net := v_base; v_vat := round(v_net * v_rate, 2); end if;
      -- Input VAT is recoverable when the business is VAT-registered (NTA 2025 s.156), unless marked otherwise.
      v_recov := o.vat_registered and coalesce((x->>'vat_recoverable')::boolean, true);
      insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross,
        asset_life_months, location_id, ai_confidence, wht_category, stock, item_id, new_item, unit_kind)
      values (b.id, p_org, v_no, left(coalesce(nullif(trim(x->>'description'), ''), 'Line ' || v_no), 300), v_code, v_qty, v_cost, v_treat, v_recov,
        v_net, v_vat, v_net + v_vat, nullif(x->>'asset_life_months', '')::int,
        (select id from locations where id = nullif(x->>'location_id', '')::uuid and org_id = p_org), nullif(x->>'ai_confidence', '')::numeric,
        case when v_line_cat is distinct from v_wht_cat then v_line_cat end, v_stock, case when v_stock then v_item end, case when v_stock and v_item is null then v_new end,
        case when v_stock then case when x->>'unit_kind' = 'selling' then 'selling' else 'purchase' end end);
    end loop;
  end if;
  update bills set subtotal = (select coalesce(sum(net), 0) from bill_lines where bill_id = b.id),
    vat_total = (select coalesce(sum(vat), 0) from bill_lines where bill_id = b.id),
    total = (select coalesce(sum(gross), 0) from bill_lines where bill_id = b.id)
  where id = b.id;
  return private.bill_wht(b.id);
end $$;


create or replace function private.post_receipt_internal(p_receipt uuid, p_member uuid, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; l public.receipt_lines; it public.items; v public.vendors; o public.orgs;
  v_bad int; v_net numeric := 0; v_vat_base numeric := 0; v_vat numeric := 0; v_gross numeric; v_line numeric;
  v_vat_t text; v_pack int; v_su_qty numeric; v_cost_su numeric; v_old_last numeric; v_on_hand numeric; v_wac numeric;
  j public.journals; v_item uuid; v_batch uuid; v_new jsonb; v_price numeric; v_props int := 0; v_can_price boolean; v_pid uuid;
  v_memo text; v_acct text; v_amt numeric; v_by_acct jsonb := '{}'::jsonb; v_jl jsonb; v_billed boolean;
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
    if l.item_id is not null then
      select vat_treatment into v_vat_t from items where id = l.item_id;
      v_acct := private.inv_acct(l.item_id);
    else
      v_vat_t := coalesce(nullif(l.new_item->>'vat_treatment', ''), 'standard');
      v_acct := private.acct(r.org_id, 'inventory');
    end if;
    v_net := v_net + v_line;
    v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_line));
    if v_vat_t = 'standard' then v_vat_base := v_vat_base + v_line; end if;
  end loop;
  -- Stock received on a supplier's bill (an uploaded invoice): the bill carries the purchase, its VAT and what is owed, so the
  -- receipt only moves the stock in.
  v_billed := exists (select 1 from bills where receipt_id = r.id and source <> 'receipt');
  v_vat := case when v_billed then 0 when r.vendor_vat_registered then round(v_vat_base * private.vat_rate(coalesce(r.invoice_date, p_at::date)), 2) else 0 end;
  v_gross := v_net + v_vat;
  v_memo := v.name || coalesce(' · ' || nullif(r.invoice_no, ''), '');

  v_jl := case when v_billed then '[]'::jsonb else jsonb_build_array(
    jsonb_build_object('code', private.acct(r.org_id, 'purchases'), 'debit', v_net, 'memo', 'Stock bought from ' || v.name),
    jsonb_build_object('code', private.acct(r.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT 7.5%'),
    jsonb_build_object('code', private.acct(r.org_id, 'payables'), 'credit', v_gross, 'memo', 'Payable to ' || v.name)) end;
  for v_acct, v_amt in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'debit', v_amt, 'location_id', r.location_id, 'memo', 'Stock received'));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(r.org_id, 'inventory_movement'), 'credit', v_net,
    'location_id', r.location_id, 'memo', 'Purchases moved into stock'));
  j := private.post_journal(r.org_id, v_memo, 'receipt', r.id, m.id, null, v_jl, p_at);

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
        not coalesce(v_can_price and nullif(v_new->>'price', '')::numeric > 0, false), m.id,
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


create or replace function public.void_bill(p_bill uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason.'; end if;
  if b.status = 'void' then raise exception '% is already void.', b.number; end if;
  if b.source = 'receipt' then raise exception '% came from a stock receipt. Correct the stock instead.', b.number; end if;
  if b.receipt_id is not null and exists (select 1 from receipts where id = b.receipt_id and status = 'posted') then
    raise exception 'Stock from % is already in the books. Correct the stock first (a count or a write-off), or ask the supplier for a credit note.', b.number;
  end if;
  if exists (select 1 from bill_payments where bill_id = b.id and status in ('paid', 'processing')) then
    raise exception '% has payments. Ask the vendor for a credit note instead.', b.number;
  end if;
  if exists (select 1 from fixed_assets where bill_id = b.id and status = 'active') then
    raise exception 'An asset from % is in use. Dispose of it first.', b.number;
  end if;
  if b.journal_id is not null then
    perform private.reverse_entry(b.journal_id, m.id, 'Bill ' || b.number || ' voided: ' || trim(p_reason), null);
    update fixed_assets set status = 'rejected', notes = concat_ws(' · ', notes, 'Bill voided') where bill_id = b.id and status = 'pending_confirmation';
  end if;
  update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = trim(p_reason) where id = b.id;
  return private.bill_json(b.id);
end $$;


create or replace function public.approve_bill(p_bill uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if b.status <> 'draft' then raise exception '% is already %.', b.number, b.status; end if;
  if b.total <= 0 then raise exception 'The bill total must be above zero.'; end if;
  -- A bill with stock on it is approved from its supplier invoice, where the person says what arrived and which branch it goes to.
  if exists (select 1 from bill_lines where bill_id = b.id and stock) and coalesce(current_setting('counta.receiving', true), '') <> b.id::text then
    raise exception '% has stock on it. Approve it from Supplier invoices, where you say what arrived and which branch it goes to.', b.number;
  end if;
  perform private.require_open_day(b.org_id, b.bill_date);
  if exists (select 1 from bills where org_id = b.org_id and vendor_id = b.vendor_id and vendor_ref = b.vendor_ref and b.vendor_ref is not null
             and id <> b.id and status <> 'void') then
    raise exception 'Bill % from this vendor is already entered.', b.vendor_ref;
  end if;
  b := private.post_bill(b.id, m);
  if b.ai_proposal_id is not null then
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), journal_id = b.journal_id where id = b.ai_proposal_id and status = 'pending';
  end if;
  return private.bill_json(b.id);
end $$;


create or replace function private.si_apply(p_id uuid, p_extract jsonb, p_model text, p_resolved text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; o public.orgs; m public.members; s jsonb; bk jsonb; v public.vendors; v_vendor uuid; v_new boolean := false; x jsonb;
  ln jsonb; v_lines jsonb := '[]'::jsonb; v_code text; v_treat text; v_qty numeric; v_up numeric; v_amt numeric; b public.bills; v_checks jsonb;
  v_day date; v_due date; v_state text; v_addr text; v_tin text; v_acct text; v_wht text; v_entity text; v_mail text; v_phone text; v_vat boolean;
  v_item uuid; v_newi jsonb; v_type text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  select * into o from orgs where id = si.org_id;
  -- The person who uploaded it, else the owner, is who wrote the bill.
  select * into m from members where id = si.submitted_by;
  if m.id is null then select * into m from members where org_id = si.org_id and role = 'owner' and status = 'active' order by created_at limit 1; end if;
  x := coalesce(p_extract, '{}'::jsonb); s := coalesce(x->'supplier', '{}'::jsonb); bk := coalesce(x->'bank', '{}'::jsonb);
  update supplier_invoices set extract = x, model = p_model, bank_resolved_name = private.si_text(p_resolved, 160), read_at = now(), error = null where id = si.id
  returning * into si;
  if coalesce((x->>'is_invoice')::boolean, true) = false or private.si_text(s->>'name', 160) is null then
    v_checks := private.si_checks(si.id);
    update supplier_invoices set status = 'review', checks = v_checks,
      blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
    return private.si_json(si.id);
  end if;

  -- The supplier.
  v_vendor := private.si_find_vendor(si.org_id, s, bk);
  v_tin := private.clean_tax_id(s->>'tax_id');
  if v_tin is not null and v_tin !~ '^[0-9]{8,13}$' then v_tin := null; end if;
  v_acct := private.si_nuban(bk->>'account_number');
  v_addr := private.si_text(s->>'address', 300);
  v_state := coalesce(private.ng_state(s->>'state'), case when v_addr is not null then private.ng_state_of_address(v_addr) end);
  v_entity := private.si_entity(s->>'entity_kind');
  v_mail := lower(coalesce(nullif(trim(s->>'email'), ''), nullif(trim(si.submitter->>'email'), '')));
  if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_mail := null; end if;
  v_phone := private.clean_phone(coalesce(nullif(trim(s->>'phone'), ''), nullif(trim(si.submitter->>'phone'), '')));
  v_wht := case when x->>'wht_category' in (select code from wht_rates where not exemption) then x->>'wht_category' end;
  v_vat := coalesce(private.si_num(x->'vat_amount'), 0) > 0 or coalesce((x->>'vat_shown')::boolean, false);
  if v_vendor is null then
    insert into vendors (org_id, name, address, state, tin, rc_number, email, phone, channel, entity_type, is_individual, resident, country,
      bank_name, account_number, account_name, vat_registered, wht_category)
    values (si.org_id, private.si_text(s->>'name', 120), v_addr, v_state, v_tin, private.si_text(s->>'rc_number', 20), v_mail,
      v_phone, case when v_mail is not null then 'email' else 'whatsapp' end, v_entity, coalesce(v_entity = 'individual', false),
      coalesce(s->>'entity_kind', '') <> 'foreign', coalesce(nullif(upper(s->>'country'), ''), case when s->>'entity_kind' = 'foreign' then 'XX' else 'NG' end),
      private.si_text(bk->>'bank_name', 80), v_acct, private.si_text(bk->>'account_name', 120), v_vat and v_tin is not null, v_wht)
    returning id into v_vendor;
    v_new := true;
  else
    -- Filled in where the record is empty; nothing on file is overwritten.
    update vendors set address = coalesce(nullif(trim(address), ''), v_addr), state = coalesce(state, v_state), tin = coalesce(private.clean_tax_id(tin), v_tin),
      rc_number = coalesce(nullif(trim(rc_number), ''), private.si_text(s->>'rc_number', 20)), email = coalesce(nullif(trim(email), ''), v_mail),
      phone = coalesce(nullif(trim(phone), ''), v_phone), entity_type = coalesce(entity_type, v_entity),
      bank_name = case when account_number is null then coalesce(bank_name, private.si_text(bk->>'bank_name', 80)) else bank_name end,
      account_name = case when account_number is null then coalesce(account_name, private.si_text(bk->>'account_name', 120)) else account_name end,
      account_number = coalesce(account_number, v_acct), wht_category = coalesce(wht_category, v_wht)
    where id = v_vendor;
  end if;
  select * into v from vendors where id = v_vendor;

  -- The draft bill, with the arithmetic put right: each line is its quantity times its price, and VAT is worked out at the
  -- rate on the invoice's day on the lines that carry it.
  for ln in select value from jsonb_array_elements(coalesce(x->'lines', '[]'::jsonb)) loop
    v_qty := coalesce(nullif(private.si_num(ln->'qty'), 0), 1); v_up := private.si_num(ln->'unit_price'); v_amt := private.si_num(ln->'amount');
    if v_up is null and v_amt is not null then v_up := round(v_amt / v_qty, 2); end if;
    if v_up is null or v_up < 0 then continue; end if;
    v_code := nullif(trim(ln->>'account_code'), '');
    if v_code is null or not private.bill_account_ok(si.org_id, v_code) then
      v_code := coalesce(case when private.bill_account_ok(si.org_id, v.default_account) then v.default_account end, private.acct(si.org_id, 'expenses_default'));
    end if;
    v_treat := case when ln->>'vat_treatment' in ('exempt', 'zero') then ln->>'vat_treatment' else 'standard' end;
    -- Stock: an item on the list the reader matched, or a new product it describes (added only if the person ticks it when
    -- approving; otherwise the line stays an expense on the account above).
    v_item := null; v_newi := null;
    if ln->>'line_kind' = 'stock' then
      v_item := (select id from items where id = case when ln->>'item_id' ~ '^[0-9a-f-]{36}$' then (ln->>'item_id')::uuid end and org_id = si.org_id
        and not archived and item_type is distinct from 'service');
      if v_item is null and private.si_text(ln->'new_item'->>'name', 120) is not null then
        v_type := case when ln->'new_item'->>'item_type' in ('merchandise', 'raw_material', 'packaging', 'consumable', 'spare_part', 'chemical', 'finished_good')
          then ln->'new_item'->>'item_type' else 'merchandise' end;
        v_newi := jsonb_strip_nulls(jsonb_build_object('name', private.si_text(ln->'new_item'->>'name', 120), 'item_type', v_type,
          'purchase_unit', coalesce(private.si_text(ln->'new_item'->>'purchase_unit', 30), 'Carton'),
          'pack_size', greatest(1, least(10000, coalesce(round(private.si_num(ln->'new_item'->'pack_size'))::int, 1))),
          'selling_unit', coalesce(private.si_text(ln->'new_item'->>'selling_unit', 30), 'piece'), 'category', private.si_text(ln->'new_item'->>'category', 60),
          'expense_account', v_code));
      end if;
    end if;
    v_lines := v_lines || jsonb_strip_nulls(jsonb_build_object('description', private.si_text(ln->>'description', 300), 'qty', v_qty, 'unit_cost', v_up, 'account_code', v_code,
      'vat_treatment', v_treat, 'ai_confidence', least(greatest(coalesce(private.num(x->>'confidence'), 70) / 100, 0), 1),
      'stock', v_item is not null or v_newi is not null, 'item_id', v_item, 'new_item', v_newi,
      'unit_kind', case when ln->>'unit_kind' = 'selling' then 'selling' else 'purchase' end));
  end loop;
  if jsonb_array_length(v_lines) = 0 and private.si_num(x->'total') is not null then
    v_lines := jsonb_build_array(jsonb_build_object('description', coalesce(private.si_text(x->>'description', 300), 'Invoice ' || coalesce(x->>'invoice_no', '')),
      'qty', 1, 'unit_cost', coalesce(private.si_num(x->'subtotal'), private.si_num(x->'total') - coalesce(private.si_num(x->'vat_amount'), 0)),
      'account_code', coalesce(case when private.bill_account_ok(si.org_id, v.default_account) then v.default_account end, private.acct(si.org_id, 'expenses_default'))));
  end if;
  begin v_day := least(nullif(x->>'invoice_date', '')::date, private.local_day(si.org_id, now())); exception when others then v_day := null; end;
  begin v_due := nullif(x->>'due_date', '')::date; exception when others then v_due := null; end;
  if v_due is not null and v_day is not null and v_due < v_day then v_due := null; end if;
  if jsonb_array_length(v_lines) > 0 then
    b := private.write_bill(si.org_id, jsonb_strip_nulls(jsonb_build_object('id', (select id from bills where id = si.bill_id and status = 'draft'),
      'vendor_id', v.id, 'vendor_ref', private.si_text(x->>'invoice_no', 60), 'bill_date', v_day, 'due_date', v_due,
      'source', 'supplier', 'vat_charged', v_vat, 'prices_include_vat', coalesce((x->>'prices_include_vat')::boolean, false),
      'document_path', si.document_path, 'lines', v_lines,
      'notes', concat_ws(' · ', case when si.source = 'portal' then 'Uploaded by the supplier on the invoice portal' else 'Uploaded and read by Counta' end,
        private.si_text(si.submitter->>'note', 300)))), m);
    update bills set invoice_tin = coalesce(private.si_text(s->>'tax_id', 30), invoice_tin), created_by = coalesce(created_by, m.id) where id = b.id;
  end if;
  update supplier_invoices set vendor_id = v.id, vendor_created = vendor_created or v_new, bill_id = coalesce(b.id, bill_id) where id = si.id;
  v_checks := private.si_checks(si.id);
  update supplier_invoices set status = 'review', checks = v_checks,
    blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
  return private.si_json(si.id);
end $$;


create or replace function private.si_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(si) - 'ip_hash' || jsonb_build_object(
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'tin_status', v.tin_status, 'address', v.address, 'state', v.state,
      'email', v.email, 'phone', v.phone, 'bank_name', v.bank_name, 'account_number', v.account_number, 'account_name', v.account_name,
      'entity_type', v.entity_type, 'resident', v.resident) from vendors v where v.id = si.vendor_id),
    'bill', (select jsonb_build_object('id', b.id, 'number', b.number, 'status', b.status, 'total', b.total, 'vat_total', b.vat_total, 'subtotal', b.subtotal,
      'wht_expected', b.wht_expected, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date, 'due_date', b.due_date, 'hold', private.bill_tin_hold(b.id))
      from bills b where b.id = si.bill_id),
    'notice', (select jsonb_build_object('id', mg.id, 'channel', mg.channel, 'to', mg.to_address, 'status', mg.status, 'error', mg.error) from messages mg where mg.id = si.notice_message_id),
    -- What goes into stock: each line with the item it is, or the new item proposed; once approved, where it went.
    'stock', (select jsonb_build_object(
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'description', l.description, 'qty', l.qty, 'unit_cost', l.unit_cost,
            'net', l.net, 'unit_kind', coalesce(l.unit_kind, 'purchase'), 'item_id', l.item_id, 'new_item', l.new_item, 'received_qty', l.received_qty,
            'item', (select jsonb_build_object('name', i.name, 'item_type', i.item_type, 'purchase_unit', i.purchase_unit, 'pack_size', i.pack_size,
              'selling_unit', i.selling_unit) from items i where i.id = l.item_id)) order by l.line_no), '[]'::jsonb)
          from bill_lines l where l.bill_id = b.id and l.stock),
        'receipt', (select jsonb_build_object('id', r.id, 'ref', r.ref, 'location_id', r.location_id, 'location', lo.name, 'posted_at', r.posted_at)
          from receipts r left join locations lo on lo.id = r.location_id where r.id = b.receipt_id))
      from bills b where b.id = si.bill_id),
    'submitted_by_name', (select display_name from members where id = si.submitted_by),
    'decided_by_name', (select display_name from members where id = si.decided_by))
  from supplier_invoices si where si.id = p_id
$$;


create or replace function public.svc_si_open(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; m public.members; v_src text := p->>'source'; si public.supplier_invoices; v_ip text := nullif(p->>'ip_hash', ''); v_sub jsonb;
begin
  if v_src = 'portal' then
    select * into o from orgs where invoice_portal_token = p->>'token' and coalesce(p->>'token', '') ~ '^[0-9a-f]{32}$';
    if not found then raise exception 'This invoice link is not valid. Ask the business for its current link.'; end if;
    if not o.invoice_portal_on or o.is_sample or not private.feature_on(o.id, 'supplier_portal') then
      raise exception '% is not taking invoices on this link just now. Send it to them directly.', o.name;
    end if;
    if v_ip is not null and (select count(*) from supplier_invoices where ip_hash = v_ip and created_at > now() - interval '1 hour') >= 10 then
      raise exception 'That is a lot of invoices in an hour. Try again later.';
    end if;
    if (select count(*) from supplier_invoices where org_id = o.id and source = 'portal' and created_at > now() - interval '1 day') >= 100 then
      raise exception '% has received many invoices today. Try again tomorrow, or send it to them directly.', o.name;
    end if;
    v_sub := jsonb_strip_nulls(jsonb_build_object('name', private.si_text(p->'submitter'->>'name', 120), 'email', lower(private.si_text(p->'submitter'->>'email', 160)),
      'phone', private.clean_phone(p->'submitter'->>'phone'), 'note', private.si_text(p->'submitter'->>'note', 500)));
    if v_sub->>'email' is not null and v_sub->>'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
    if v_sub->>'email' is null and coalesce(length(v_sub->>'phone'), 0) < 11 then
      raise exception 'Give an email address or a WhatsApp number, so the business can reach you about the invoice.';
    end if;
  elsif v_src = 'upload' then
    select * into o from orgs where id = (p->>'org_id')::uuid;
    if not found then raise exception 'Business not found.'; end if;
    select * into m from members where id = (p->>'member_id')::uuid and org_id = o.id and status = 'active';
    if not found then raise exception 'You are not a member of this business.'; end if;
    if not (private.perm_of(m, 'keep_books') or m.role = 'owner') then raise exception 'Your role does not enter bills.' using errcode = '42501'; end if;
    if coalesce(p->>'path', '') !~ ('^' || o.id::text || '/') or p->>'path' like '%..%' then raise exception 'Upload the invoice first.'; end if;
    v_sub := '{}'::jsonb;
  else
    raise exception 'Unknown source.';
  end if;
  if (select count(*) from supplier_invoices where org_id = o.id and created_at > now() - interval '1 hour') >= 120 then
    raise exception 'Counta is reading many invoices for this business. Try again in an hour.';
  end if;
  insert into supplier_invoices (org_id, number, source, document_path, mime, file_name, file_size, file_sha256, submitted_by, submitter, ip_hash)
  values (o.id, 'SI-' || lpad(private.next_no(o.id, 'SI', 1)::text, 5, '0'), v_src,
    coalesce(nullif(p->>'path', ''), o.id::text || '/bills/supplier-' || replace(gen_random_uuid()::text, '-', '') || '.bin'),
    private.si_text(p->>'mime', 60), private.si_text(p->>'file_name', 160), nullif(p->>'file_size', '')::int, nullif(p->>'sha256', ''), m.id, v_sub, v_ip)
  returning * into si;
  return jsonb_build_object('id', si.id, 'org_id', o.id, 'number', si.number, 'path', si.document_path, 'business', o.name,
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name) order by a.code), '[]'::jsonb)
      from (select code, name from accounts union select code, name from org_accounts where org_id = o.id) a
      where a.code ~ '^(5|6|15|12)' and private.bill_account_ok(o.id, a.code)),
    'wht', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort) from wht_rates where not exemption and code <> 'none'),
    -- What the business does, and what it keeps in stock, so the reader can tell stock from assets and expenses.
    'profile', jsonb_strip_nulls(jsonb_build_object('industry', o.industry, 'activity', o.principal_activity, 'offering', o.offering, 'legal_form', o.legal_form,
      'capitalisation_threshold', o.capitalisation_threshold)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'type', i.item_type, 'unit', i.purchase_unit, 'pack', i.pack_size,
        'selling_unit', i.selling_unit, 'category', i.category, 'brand', i.brand) order by i.recent desc nulls last, i.name), '[]'::jsonb)
      from (select i.*, (select max(mv.recorded_at) from movements mv where mv.item_id = i.id) recent from items i
            where i.org_id = o.id and not i.archived and i.item_type is distinct from 'service'
            order by recent desc nulls last, i.name limit 400) i));
end $$;


-- Approving an invoice for payment. With stock on it, p says what arrived and where:
--   {location_id, lines: [{id (the bill line), item_id (to change the match; '' for none), add_new (add the new product), new_item (changes to it),
--     qty (what arrived, up to the invoice's quantity)}]}
-- A stock line with no item, and no new product added, stays on the bill as an expense.
drop function if exists public.approve_supplier_invoice(uuid);
create or replace function public.approve_supplier_invoice(p_id uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members; v_checks jsonb; v_block text; b public.bills; v public.vendors; l public.bill_lines; x jsonb;
  v_loc uuid; v_item uuid; v_qty numeric; v_new jsonb; v_type text; v_pack int; v_cost_su numeric; r public.receipts; v_n int; v_acct text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(si.org_id, 'keep_books');
  if si.status <> 'review' then raise exception '% is %.', si.number, si.status; end if;
  if si.bill_id is null then raise exception 'Counta could not write a bill from %. Reject it, or enter the bill yourself.', si.number; end if;
  v_checks := private.si_checks(si.id);
  update supplier_invoices set checks = v_checks, blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
  select string_agg(c->>'text', ' ') into v_block from jsonb_array_elements(v_checks) c where c->>'severity' = 'block';
  if v_block is not null then raise exception 'Not yet: %', v_block; end if;
  select * into b from bills where id = si.bill_id for update;
  select * into v from vendors where id = b.vendor_id;

  if b.status = 'draft' and exists (select 1 from bill_lines where bill_id = b.id and stock) then
    if not private.perm_of(m, 'receive_stock') then
      raise exception 'This invoice puts stock into a branch, and your role does not receive stock. Ask someone who does to approve it.' using errcode = '42501';
    end if;
    v_loc := (select id from locations where id = case when p->>'location_id' ~ '^[0-9a-f-]{36}$' then (p->>'location_id')::uuid end and org_id = si.org_id);
    if v_loc is null then
      select min(id::text)::uuid into v_loc from locations where org_id = si.org_id having count(*) = 1;
      if v_loc is null then raise exception 'Choose the branch the stock goes to.'; end if;
    end if;
    for l in select * from bill_lines where bill_id = b.id and stock order by line_no for update loop
      x := (select e from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' then p->'lines' else '[]'::jsonb end) e where e->>'id' = l.id::text limit 1);
      -- The item: as the person chose it, else as Counta matched it.
      if x ? 'item_id' then
        v_item := (select id from items where id = case when x->>'item_id' ~ '^[0-9a-f-]{36}$' then (x->>'item_id')::uuid end and org_id = si.org_id
          and not archived and item_type is distinct from 'service');
        if v_item is null and nullif(x->>'item_id', '') is not null then raise exception 'Line %: that item is not on your list.', l.line_no; end if;
      else
        v_item := l.item_id;
      end if;
      v_qty := coalesce(round(private.num(x->>'qty'), 3), l.qty);
      if v_qty < 0 or v_qty > l.qty then
        raise exception 'Line %: receive from 0 up to the % on the invoice. If more arrived, ask the supplier for an invoice for the rest.', l.line_no,
          trim(to_char(l.qty, 'FM999,999,990.###'));
      end if;
      -- A new product the person chose to add.
      if v_item is null and coalesce((x->>'add_new')::boolean, false) then
        v_new := coalesce(l.new_item, '{}'::jsonb) || case when jsonb_typeof(x->'new_item') = 'object' then x->'new_item' else '{}'::jsonb end;
        if coalesce(trim(v_new->>'name'), '') = '' then raise exception 'Line %: name the new item.', l.line_no; end if;
        if exists (select 1 from items where org_id = si.org_id and not archived and lower(name) = lower(trim(v_new->>'name'))) then
          raise exception 'Line %: % is already on your items list. Choose it instead of adding it again.', l.line_no, trim(v_new->>'name');
        end if;
        v_type := case when v_new->>'item_type' in ('merchandise', 'raw_material', 'packaging', 'consumable', 'spare_part', 'chemical', 'finished_good')
          then v_new->>'item_type' else 'merchandise' end;
        v_pack := greatest(1, least(10000, coalesce(round(private.num(v_new->>'pack_size'))::int, 1)));
        v_cost_su := round(l.net / l.qty / case when coalesce(l.unit_kind, 'purchase') = 'purchase' then v_pack else 1 end, 4);
        insert into items (org_id, name, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit, preferred_vendor_id, price, needs_review,
          created_by, item_type)
        values (si.org_id, left(trim(v_new->>'name'), 120), coalesce(nullif(trim(v_new->>'category'), ''), 'General'),
          case when l.vat_treatment in ('zero', 'exempt') then l.vat_treatment else 'standard' end, coalesce(nullif(trim(v_new->>'purchase_unit'), ''), 'Carton'), v_pack,
          coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece'), coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece') in ('derica', 'mudu', 'paint bucket'),
          b.vendor_id, case when v_type in ('merchandise', 'finished_good') then private.round_price(v_cost_su * 1.15) else 0 end, true, m.id, v_type)
        returning id into v_item;
        insert into item_costs (item_id, org_id, wac) values (v_item, si.org_id, 0);
      end if;
      if v_item is null then
        -- Not stock after all: the line stays on the bill as an expense.
        v_acct := l.new_item->>'expense_account';
        if v_acct is null or not private.bill_account_ok(si.org_id, v_acct) then
          v_acct := coalesce(case when private.bill_account_ok(si.org_id, v.default_account) then v.default_account end, private.acct(si.org_id, 'expenses_default'));
        end if;
        update bill_lines set stock = false, item_id = null, unit_kind = null, received_qty = null, account_code = v_acct where id = l.id;
      else
        update bill_lines set item_id = v_item, new_item = null, received_qty = v_qty,
          unit_kind = case when x->>'unit_kind' in ('purchase', 'selling') then x->>'unit_kind' else coalesce(l.unit_kind, 'purchase') end
        where id = l.id;
      end if;
    end loop;
  end if;

  if b.status = 'draft' then
    perform set_config('counta.receiving', b.id::text, true);
    perform public.approve_bill(b.id);
    perform set_config('counta.receiving', '', true);
  end if;
  select * into b from bills where id = b.id;

  -- The stock goes into the branch. The bill already carries the purchase and its VAT; the receipt only moves the stock.
  if b.receipt_id is null and exists (select 1 from bill_lines where bill_id = b.id and stock and item_id is not null and received_qty > 0 and net > 0) then
    insert into receipts (org_id, ref, vendor_id, vendor_name, location_id, source, document_path, document_mime, invoice_no, invoice_date,
      vendor_vat_registered, prices_include_vat, status, created_by)
    values (si.org_id, si.number, b.vendor_id, v.name, v_loc, case when coalesce(si.mime, '') like 'image/%' then 'photo_typed' else 'pdf' end,
      si.document_path, si.mime, b.vendor_ref, b.bill_date, false, false, 'needs_review', m.id)
    returning * into r;
    insert into receipt_lines (receipt_id, org_id, line_no, raw_text, item_id, qty, unit_kind, unit_cost, confirmed)
    select r.id, r.org_id, row_number() over (order by bl.line_no), bl.description, bl.item_id, bl.received_qty, coalesce(bl.unit_kind, 'purchase'), round(bl.net / bl.qty, 4), true
    from bill_lines bl where bl.bill_id = b.id and bl.stock and bl.item_id is not null and bl.received_qty > 0 and bl.net > 0;
    update bills set receipt_id = r.id where id = b.id;
    perform private.post_receipt_internal(r.id, m.id, now());
  end if;
  update supplier_invoices set status = 'approved', decided_by = m.id, decided_at = now() where id = si.id;
  return private.si_json(si.id);
end $$;

revoke execute on function public.approve_supplier_invoice(uuid, jsonb) from public, anon;
grant execute on function public.approve_supplier_invoice(uuid, jsonb) to authenticated, service_role;
