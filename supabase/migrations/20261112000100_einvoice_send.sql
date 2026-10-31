-- E-invoicing, part 2b: Counta's sales go to NRS (docs/e-invoicing.md).
--
-- Who the buyer is decides how. Invoices, receipts and credit notes to a business or a government body are cleared: NRS
-- validates and signs them before the buyer gets them, and an invoice stays a draft (held) until NRS signs it. Sales to
-- individuals and walk-in customers are reported: they get their IRN and QR code at once, and a queue sends them to NRS
-- every five minutes. Only sales posted while e-invoicing is on go; a credit note goes only when its sale went.
-- The einvoice edge function does the talking to NRS (it maps each sale to NRS's schema, so the mapping can change without
-- a database update); the database decides what goes, keeps the state, and posts a held invoice once NRS signs it.

-- ---------------------------------------------------------------------------
-- 1. The service code: one Gemini is unsure of waits for the owner, as an unsure HS code does.
-- ---------------------------------------------------------------------------
alter table public.einvoice_settings add column if not exists service_review boolean not null default false;

-- (A code the owner has already confirmed stays confirmed if this runs again.)
update public.einvoice_settings e set service_review = true
where coalesce(e.service_basis->>'source', '') = 'gemini' and e.service_code is not null and not e.service_review
  and not (e.service_basis ? 'confirmed_by')
  and coalesce(private.num(e.service_basis->>'confidence'), 0) < (select greatest(coalesce(o.auto_post_threshold, 0.8), 0.8) from public.orgs o where o.id = e.org_id);

create or replace function public.svc_set_service_code(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.einvoice_settings; v_code text := nullif(regexp_replace(coalesce(p->>'code', ''), '[^0-9]', '', 'g'), '');
  v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1); v_threshold numeric;
begin
  select * into s from einvoice_settings where org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false); end if;
  if coalesce(s.service_basis->>'source', '') = 'manual' then
    update einvoice_settings set service_checked_at = now() where org_id = p_org;
    return jsonb_build_object('ok', true, 'kept', 'manual');
  end if;
  if v_code is not null and (v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code)) then v_code := null; end if;
  select greatest(coalesce(auto_post_threshold, 0.8), 0.8) into v_threshold from orgs where id = p_org;
  update einvoice_settings set service_checked_at = now(),
    service_code = coalesce(v_code, service_code),
    service_review = case when v_code is not null then v_conf < v_threshold else service_review end,
    service_basis = jsonb_build_object('source', 'gemini', 'code', v_code, 'reason', left(coalesce(nullif(p->>'reason', ''), case when v_code is null then 'Gemini could not choose a service code.' end), 400),
      'confidence', v_conf, 'model', p->>'model', 'at', now())
  where org_id = p_org;
  return jsonb_build_object('ok', v_code is not null, 'code', v_code, 'review', v_code is not null and v_conf < v_threshold);
end $$;

-- ---------------------------------------------------------------------------
-- 2. What goes to NRS: one row per sale.
-- ---------------------------------------------------------------------------
create table if not exists public.einvoice_docs (
  sale_id uuid primary key references public.sales(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('clear', 'report')),
  doc text not null check (doc in ('invoice', 'receipt', 'credit_note')),
  irn text,
  state text not null default 'waiting' check (state in ('waiting', 'sending', 'signed', 'refused', 'stopped')),
  held boolean not null default false,
  issued_by uuid references public.members(id) on delete set null,
  tries int not null default 0,
  next_try_at timestamptz not null default now(),
  sending_at timestamptz,
  note text,
  answer jsonb,
  qr text,
  qr_at timestamptz,
  platform_keys boolean,
  signed_at timestamptz,
  pay_status text check (pay_status in ('PENDING', 'PAID')),
  pay_due text check (pay_due in ('PAID')),
  pay_tries int not null default 0,
  pay_next_at timestamptz,
  pay_note text,
  alerted int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists einvoice_docs_irn on public.einvoice_docs (org_id, irn) where irn is not null;
create index if not exists einvoice_docs_due on public.einvoice_docs (next_try_at) where state in ('waiting', 'sending');
create index if not exists einvoice_docs_pay on public.einvoice_docs (pay_next_at) where pay_due is not null;
create index if not exists einvoice_docs_org on public.einvoice_docs (org_id, state);
alter table public.einvoice_docs enable row level security;
revoke all on public.einvoice_docs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Which sales go, and how.
-- ---------------------------------------------------------------------------
-- 'clear' for a business or government buyer, 'report' for anyone else, null when the sale stays in Counta: e-invoicing
-- off, a document NRS does not take, a sale recorded from another system, or a credit note whose sale never went.
create or replace function private.einvoice_route(p_sale uuid) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; e public.einvoice_settings; c public.customers;
begin
  select * into s from sales where id = p_sale;
  if not found or s.doc_type not in ('receipt', 'invoice', 'order', 'credit_note') or s.channel in ('import', 'schedule', 'bank') then return null; end if;
  select * into e from einvoice_settings where org_id = s.org_id;
  if not found or not e.enabled then return null; end if;
  if s.doc_type = 'credit_note' and not exists (select 1 from einvoice_docs d where d.sale_id = s.original_sale_id and d.state in ('waiting', 'sending', 'signed')) then
    return null;
  end if;
  select * into c from customers where id = s.customer_id;
  return case when c.kind in ('business', 'government') and not coalesce(c.is_walk_in, false) then 'clear' else 'report' end;
end $$;

-- Puts a sale in line for NRS (again, after a refusal or after it was taken back), and asks the edge function to start at
-- once: a cleared one is validated and signed, a reported one gets its QR code. A business buyer with no Tax ID is
-- refused here, without asking NRS.
create or replace function private.einvoice_open(p_sale uuid, p_kind text, p_held boolean, p_by uuid) returns public.einvoice_docs
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; c public.customers; d public.einvoice_docs; v_note text;
begin
  select * into s from sales where id = p_sale;
  select * into c from customers where id = s.customer_id;
  if p_kind = 'clear' and coalesce(upper(c.country), 'NG') = 'NG' and nullif(btrim(coalesce(c.tin, '')), '') is null then
    v_note := 'Add ' || c.name || '''s Tax ID, then send it again: NRS needs it on sales to businesses and government.';
  end if;
  insert into einvoice_docs (sale_id, org_id, kind, doc, held, issued_by, state, note)
  values (s.id, s.org_id, p_kind, case s.doc_type when 'invoice' then 'invoice' when 'credit_note' then 'credit_note' else 'receipt' end,
    p_held, p_by, case when v_note is null then 'waiting' else 'refused' end, v_note)
  on conflict (sale_id) do update set kind = excluded.kind, held = excluded.held, issued_by = coalesce(excluded.issued_by, einvoice_docs.issued_by),
    state = excluded.state, note = excluded.note, tries = 0, next_try_at = now(), sending_at = null, irn = null, qr = null, qr_at = null,
    answer = null, alerted = 0, updated_at = now()
    where einvoice_docs.state in ('refused', 'stopped')
  returning * into d;
  if d.sale_id is null then select * into d from einvoice_docs where sale_id = s.id; end if;
  update sales set irn_status = d.state, irn = d.irn where id = s.id;
  if d.state = 'waiting' then perform private.call_function('einvoice', jsonb_build_object('action', 'send', 'sale_id', s.id)); end if;
  return d;
end $$;

-- Every sale posted while e-invoicing is on is put in line (an invoice held for NRS is in line already).
create or replace function private.on_sale_posted_einvoice() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_kind text;
begin
  if exists (select 1 from einvoice_docs where sale_id = new.id) then return null; end if;
  v_kind := private.einvoice_route(new.id);
  if v_kind is not null then perform private.einvoice_open(new.id, v_kind, false, new.created_by); end if;
  return null;
end $$;
drop trigger if exists sales_einvoice_posted on public.sales;
create trigger sales_einvoice_posted after update of journal_id on public.sales for each row
  when (old.journal_id is null and new.journal_id is not null) execute function private.on_sale_posted_einvoice();

-- An invoice Bujeti issued was issued there, not in Counta: it is not sent again.
create or replace function private.on_bujeti_invoice_einvoice() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.kind = 'invoice' and new.sale_id is not null then
    delete from einvoice_docs where sale_id = new.sale_id and state in ('waiting', 'refused') and tries = 0;
    update sales set irn_status = null, irn = null where id = new.sale_id and not exists (select 1 from einvoice_docs where sale_id = new.sale_id);
  end if;
  return null;
end $$;
drop trigger if exists bujeti_items_einvoice on public.bujeti_items;
create trigger bujeti_items_einvoice after insert or update of sale_id on public.bujeti_items for each row execute function private.on_bujeti_invoice_einvoice();

-- A sale NRS has signed is corrected by credit note only. One NRS has not signed yet stops going when it is voided.
create or replace function private.on_sale_void_einvoice() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs;
begin
  select * into d from einvoice_docs where sale_id = new.id;
  if found then
    if d.state = 'signed' then raise exception 'NRS has signed %. Cancel it with a credit note instead.', new.number; end if;
    if d.state = 'sending' and d.sending_at > now() - interval '5 minutes' then raise exception 'NRS is checking % right now. Try again in a minute.', new.number; end if;
    update einvoice_docs set state = 'stopped', note = 'Voided before NRS signed it, so it was not sent.', sending_at = null, updated_at = now() where sale_id = new.id;
    new.irn_status := 'stopped';
  end if;
  return new;
end $$;
drop trigger if exists sales_einvoice_void on public.sales;
create trigger sales_einvoice_void before update of status on public.sales for each row
  when (new.status in ('void', 'cancelled') and old.status is distinct from new.status) execute function private.on_sale_void_einvoice();

-- Once a sale is paid in full, NRS is told (PATCH update/{irn}, payment_status PAID).
create or replace function private.on_sale_paid_einvoice() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  update einvoice_docs set pay_due = 'PAID', pay_next_at = now(), pay_tries = 0, pay_note = null, updated_at = now()
  where sale_id = new.id and coalesce(pay_status, '') <> 'PAID' and state <> 'stopped';
  return null;
end $$;
drop trigger if exists sales_einvoice_paid on public.sales;
create trigger sales_einvoice_paid after update of status on public.sales for each row
  when (new.status = 'paid' and old.status is distinct from 'paid') execute function private.on_sale_paid_einvoice();

-- ---------------------------------------------------------------------------
-- 4. Invoices to businesses and government wait, as drafts, until NRS signs them.
-- ---------------------------------------------------------------------------
create or replace function public.issue_invoice(p_sale uuid, p_issue_date date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; c public.customers; v_owed numeric; v_day date; v_today date; d public.einvoice_docs;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.doc_type <> 'invoice' or s.status <> 'draft' then raise exception '% is not a draft invoice.', s.number; end if;
  select * into d from einvoice_docs where sale_id = s.id;
  if d.state in ('waiting', 'sending') then raise exception 'NRS is already checking %.', s.number; end if;
  if s.total <= 0 then raise exception 'The invoice total must be above zero.'; end if;
  v_today := private.local_day(s.org_id, now());
  -- A draft left with the day it was started takes the day it is issued.
  v_day := coalesce(p_issue_date, case when s.issue_date = private.local_day(s.org_id, s.created_at) then v_today else s.issue_date end);
  if v_day > v_today then raise exception 'An invoice cannot be dated in the future.'; end if;
  perform private.require_open_day(s.org_id, v_day);
  select * into c from customers where id = s.customer_id;
  v_owed := private.customer_balance(s.org_id, c.id) + s.total;
  if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception '% would owe % against a credit limit of %. A manager can issue it.', c.name, to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
  end if;
  -- To a business or government buyer, with e-invoicing on: NRS signs it first. It stays a draft, locked, until then.
  if private.einvoice_route(s.id) = 'clear' then
    if coalesce(upper(c.country), 'NG') = 'NG' and nullif(btrim(coalesce(c.tin, '')), '') is null then
      raise exception 'Add %''s Tax ID before issuing: NRS checks invoices to businesses and government, and needs it.', c.name;
    end if;
    update sales set due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day,
      customer_name = c.name, customer_tin = c.tin, customer_email = c.email, customer_phone = c.phone, customer_address = c.address where id = s.id;
    perform private.einvoice_open(s.id, 'clear', true, m.id);
    return private.sale_json(s.id, private.can_see_costs(s.org_id));
  end if;
  update sales set status = 'open', due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day where id = s.id;
  s := private.post_sale(s.id, m, private.posting_time(s.org_id, v_day));
  s := private.refresh_sale(s.id);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- Once NRS signs a held invoice it is issued: posted on its issue date (today, when the books are closed for that day),
-- by the person who issued it.
create or replace function private.einvoice_issue_held(p_sale uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; v_closed date;
begin
  select * into s from sales where id = p_sale for update;
  if s.status <> 'draft' or s.journal_id is not null then return; end if;
  select * into m from members where id = coalesce((select issued_by from einvoice_docs where sale_id = p_sale), s.created_by);
  if m.id is null then select * into m from members where org_id = s.org_id and role = 'owner' order by created_at limit 1; end if;
  update sales set status = 'open' where id = s.id;
  v_closed := private.closed_through(s.org_id);
  perform private.post_sale(s.id, m, case when v_closed is not null and s.issue_date <= v_closed then now() else private.posting_time(s.org_id, s.issue_date) end);
  perform private.refresh_sale(s.id);
  update einvoice_docs set held = false, updated_at = now() where sale_id = p_sale;
end $$;

-- New invoices issued from the editor go through issue_invoice, like drafts, so the same rules apply. A held invoice
-- cannot be changed while NRS checks it.
create or replace function public.save_sale_doc(p_org uuid, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.sales; v_id uuid := nullif(p_doc->>'id', '')::uuid; v_type text := coalesce(nullif(p_doc->>'doc_type', ''), 'invoice');
  c public.customers; o public.orgs;
begin
  m := private.require(p_org, 'record_sales');
  if v_type not in ('invoice', 'quote') then raise exception 'Only invoices and quotes are edited here.'; end if;
  if v_id is null then
    s := private.create_sale(p_org, (p_doc - 'tenders' - 'pay_in_full' - 'retail_only') || jsonb_build_object('doc_type', v_type, 'status', 'draft'), m);
    if v_type = 'invoice' and p_doc->>'status' = 'issue' then
      return public.issue_invoice(s.id, s.issue_date);
    end if;
  else
    select * into s from sales where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Document not found.'; end if;
    if not (s.status = 'draft' or (s.doc_type = 'quote' and s.status = 'open')) then
      raise exception '% is already issued. Void it or raise a credit note instead.', s.number;
    end if;
    if exists (select 1 from einvoice_docs where sale_id = s.id and state in ('waiting', 'sending')) then
      raise exception 'NRS is checking %. Take it back first to change it.', s.number;
    end if;
    select * into o from orgs where id = p_org;
    if nullif(p_doc->>'customer_id', '') is not null and (p_doc->>'customer_id')::uuid <> s.customer_id then
      select * into c from customers where id = (p_doc->>'customer_id')::uuid and org_id = p_org and not archived;
      if not found then raise exception 'Customer not found.'; end if;
      update sales set customer_id = c.id, customer_name = c.name, customer_phone = c.phone, customer_email = c.email, customer_tin = c.tin,
        customer_address = c.address, price_list_id = c.price_list_id where id = s.id;
    end if;
    update sales set issue_date = coalesce(nullif(p_doc->>'issue_date', '')::date, issue_date),
      due_date = coalesce(nullif(p_doc->>'due_date', '')::date, due_date),
      price_list_id = case when p_doc ? 'price_list_id' then (select id from price_lists where id = nullif(p_doc->>'price_list_id', '')::uuid and org_id = p_org)
                           else price_list_id end,
      reference = case when p_doc ? 'reference' then nullif(trim(p_doc->>'reference'), '') else reference end,
      notes = case when p_doc ? 'notes' then nullif(trim(p_doc->>'notes'), '') else notes end,
      terms = case when p_doc ? 'terms' then nullif(trim(p_doc->>'terms'), '') else terms end,
      delivery_fee = case when p_doc ? 'delivery_fee' then round(greatest(coalesce(private.num(p_doc->>'delivery_fee'), 0), 0), 2) else delivery_fee end,
      delivery_address = case when p_doc ? 'delivery_address' then nullif(trim(p_doc->>'delivery_address'), '') else delivery_address end,
      location_id = coalesce((select id from locations where id = nullif(p_doc->>'location_id', '')::uuid and org_id = p_org), location_id),
      prices_include_vat = coalesce((p_doc->>'prices_include_vat')::boolean, prices_include_vat), vat_registered = o.vat_registered
    where id = s.id returning * into s;
    if s.issue_date > private.local_day(p_org, now()) then raise exception 'A document cannot be dated in the future.'; end if;
    if s.due_date < s.issue_date then raise exception 'The due date is before the issue date.'; end if;
    s := private.write_lines(s, coalesce(p_doc->'lines', (select jsonb_agg(case when l.item_id is not null then
        jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end, 'unit_price', l.unit_price,
          'discount', l.discount)
      else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
          'vat_treatment', l.vat_treatment, 'revenue_account', l.revenue_account) end order by l.line_no)
      from sale_lines l where l.sale_id = s.id and l.kind <> 'delivery')), private.num(p_doc->>'cart_discount'), m);
    if p_doc->>'status' = 'issue' and s.doc_type = 'invoice' then
      return public.issue_invoice(s.id, null);
    end if;
  end if;
  return private.sale_json(s.id, private.can_see_costs(p_org));
end $$;

-- Takes a held invoice back from NRS's queue to change it (not once NRS has started on it).
create or replace function public.einvoice_take_back(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; d public.einvoice_docs;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or not d.held then raise exception '% is not waiting for NRS.', s.number; end if;
  if d.state = 'sending' and d.sending_at > now() - interval '5 minutes' then raise exception 'NRS is checking % right now. Try again in a minute.', s.number; end if;
  if d.state = 'signed' then raise exception 'NRS has signed % already.', s.number; end if;
  if d.state in ('waiting', 'sending') then
    update einvoice_docs set state = 'stopped', note = 'Taken back to change by ' || coalesce(m.display_name, 'staff') || '.', sending_at = null, updated_at = now()
    where sale_id = p_sale;
    update sales set irn_status = 'stopped' where id = p_sale;
  end if;
  return private.sale_json(p_sale, private.can_see_costs(s.org_id));
end $$;

-- Sends a sale NRS refused again, once its details are put right (the buyer's details are taken again from the customer).
-- A held invoice is changed and issued again instead.
create or replace function public.einvoice_send_again(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; d public.einvoice_docs; c public.customers;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.state <> 'refused' then raise exception 'Only a sale NRS refused is sent again.'; end if;
  if d.held then raise exception 'Change % if needed and issue it again.', s.number; end if;
  select * into c from customers where id = s.customer_id;
  if d.kind = 'clear' and coalesce(upper(c.country), 'NG') = 'NG' and nullif(btrim(coalesce(c.tin, '')), '') is null then
    raise exception 'Add %''s Tax ID first: NRS needs it on sales to businesses and government.', c.name;
  end if;
  update sales set customer_name = c.name, customer_tin = c.tin, customer_email = c.email, customer_phone = c.phone, customer_address = c.address,
    irn_status = 'waiting' where id = p_sale;
  update einvoice_docs set state = 'waiting', tries = 0, next_try_at = now(), note = null, answer = null, alerted = 0, updated_at = now() where sale_id = p_sale;
  perform private.call_function('einvoice', jsonb_build_object('action', 'send', 'sale_id', p_sale));
  return private.sale_json(p_sale, private.can_see_costs(s.org_id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. A cleared sale reaches the buyer only once NRS has signed it.
-- ---------------------------------------------------------------------------
create or replace function public.send_document(p_sale uuid, p_channel text, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; msg public.messages; o public.orgs; v_label text;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.kind = 'clear' and d.state in ('waiting', 'sending')) then
    raise exception 'NRS has not signed % yet. It can be sent once NRS signs it.', s.number;
  end if;
  if exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.kind = 'clear' and d.state = 'refused') then
    raise exception 'NRS refused %. Put it right and send it to NRS again first.', s.number;
  end if;
  if s.status = 'draft' then raise exception 'Issue it before sending.'; end if;
  select * into o from orgs where id = s.org_id;
  v_label := case s.doc_type when 'receipt' then 'Receipt' when 'invoice' then 'Invoice' when 'quote' then 'Quote' when 'order' then 'Order' else 'Credit note' end;
  msg := private.queue_message(s.org_id, p_channel, coalesce(nullif(trim(p_to), ''), case when p_channel = 'whatsapp' then s.customer_phone else s.customer_email end),
    case when s.doc_type = 'receipt' then 'receipt' when s.doc_type = 'order' then 'order' else 'document' end,
    v_label || ' ' || s.number || ' from ' || o.name,
    jsonb_build_object('customer_name', s.customer_name, 'business', o.name, 'doc_label', v_label, 'number', s.number, 'total', s.total,
      'balance', case when s.doc_type in ('invoice', 'order', 'receipt') then s.total - s.amount_paid - s.credited else 0 end,
      'due_date', s.due_date, 'link', private.doc_link(s.public_token), 'reply_to', coalesce(o.reply_to_email, o.email), 'business_phone', o.phone),
    s.id, s.customer_id, m.id);
  update sales set sent_at = now() where id = s.id;
  return to_jsonb(msg);
end $$;

create or replace function public.public_document(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v jsonb; d public.deliveries;
begin
  if p_token is null or length(p_token) < 24 then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if exists (select 1 from einvoice_docs e where e.sale_id = s.id and e.kind = 'clear' and e.state <> 'signed') then
    raise exception 'This document is waiting for NRS to sign it. Open the link again in a few minutes.';
  end if;
  if s.viewed_at is null then update sales set viewed_at = now() where id = s.id; end if;
  v := private.sale_json(s.id, false);
  select * into d from deliveries where sale_id = s.id and status <> 'cancelled' order by created_at desc limit 1;
  return (v - 'created_by' - 'voided_by' - 'shift_id' - 'device_id' - 'client_uuid' - 'journal_id' - 'journal_ref' - 'org_id' - 'cost_total' - 'location_id'
    - 'price_list_id' - 'created_by_name' - 'deliveries' - 'refunds' - 'void_reason' - 'offline' - 'customer_credit' - 'export_note' - 'einvoice')
    || jsonb_build_object(
      'lines', (select coalesce(jsonb_agg(l - 'cost' - 'item_id' - 'revenue_account' - 'list_price' - 'original_line_id' - 'returned_qty' - 'sale_id' - 'id'
          order by (l->>'line_no')::int), '[]'::jsonb) from jsonb_array_elements(v->'lines') l),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p->>'method', 'amount', p->'amount', 'status', p->>'status', 'received_at', p->'received_at')), '[]'::jsonb)
        from jsonb_array_elements(v->'payments') p where p->>'status' in ('confirmed', 'pending')),
      'requests', (select coalesce(jsonb_agg(r - 'id'), '[]'::jsonb) from jsonb_array_elements(v->'requests') r where r->>'status' = 'pending'),
      'shop_slug', (select shop_slug from orgs where id = s.org_id and shop_enabled),
      'einvoice', case when v->'einvoice' is not null and v->'einvoice'->>'state' in ('waiting', 'sending', 'signed') and v->'einvoice'->>'irn' is not null then
        jsonb_build_object('irn', v->'einvoice'->>'irn', 'qr', v->'einvoice'->>'qr', 'signed', v->'einvoice'->>'state' = 'signed',
          'kind', v->'einvoice'->>'kind', 'state', v->'einvoice'->>'state') end,
      'tracking', case when s.doc_type = 'order' then jsonb_build_object(
        'placed_at', s.created_at, 'confirmed', s.journal_id is not null, 'confirmed_at', s.issued_at, 'method', s.delivery_method,
        'cancelled', s.status in ('cancelled', 'void'),
        'delivery_status', d.status, 'scheduled_for', d.scheduled_for, 'dispatched_at', d.dispatched_at, 'delivered_at', d.delivered_at,
        'pickup_address', case when s.delivery_method = 'pickup' then (select coalesce(nullif(l.address, ''), o.address) from locations l join orgs o on o.id = l.org_id where l.id = s.location_id) end)
      end);
end $$;

-- The sale as the app sees it, now with where it stands with NRS.
create or replace function private.sale_json(p_sale uuid, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(s) || jsonb_build_object(
    'cost_total', case when p_cost then (select sum(cost) from sale_lines where sale_id = s.id) end,
    'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                    when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
    'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
    'confirmed', s.journal_id is not null,
    'location_name', (select name from locations where id = s.location_id),
    'created_by_name', (select display_name from members where id = s.created_by),
    'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(private.local_day(s.org_id, now()) - s.due_date, 0) end,
    'org', private.org_brand(s.org_id),
    'customer', (select jsonb_build_object('city', c.city, 'state', c.state, 'country', c.country, 'contact_person', c.contact_person)
      from customers c where c.id = s.customer_id),
    'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'cost' - 'org_id' || jsonb_build_object('cost', case when p_cost then l.cost end) order by l.line_no), '[]'::jsonb)
              from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'status', c.status, 'direction', c.direction,
        'amount', a.amount, 'collection_amount', c.amount, 'fee', c.fee, 'received_at', c.received_at, 'reference', c.reference, 'bank_account_id', c.bank_account_id,
        'confirmed_by_name', (select display_name from members where id = c.confirmed_by)) order by c.received_at), '[]'::jsonb)
      from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id),
    'refunds', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'received_at', c.received_at)), '[]'::jsonb)
      from collections c where c.sale_id = s.id and c.direction = 'out'),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('credit_note_id', ca.credit_note_id, 'number', cn.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales cn on cn.id = ca.credit_note_id where ca.sale_id = s.id and ca.credit_note_id <> s.id),
    'applied_to', (select coalesce(jsonb_agg(jsonb_build_object('sale_id', ca.sale_id, 'number', x.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales x on x.id = ca.sale_id where ca.credit_note_id = s.id and ca.sale_id <> s.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', cn.id, 'number', cn.number, 'total', cn.total, 'status', cn.status)), '[]'::jsonb)
      from sales cn where cn.original_sale_id = s.id and cn.doc_type = 'credit_note'),
    'original_number', (select number from sales where id = s.original_sale_id),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'method', r.method, 'status', r.status, 'amount', r.amount, 'account_number', r.account_number,
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref,
        'direct', r.direct, 'pay_ref', r.pay_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end,
    'einvoice', (select jsonb_build_object('irn', e.irn, 'kind', e.kind, 'state', e.state, 'held', e.held, 'qr', e.qr, 'note', e.note, 'signed_at', e.signed_at,
        'tries', e.tries, 'next_try_at', e.next_try_at, 'pay_status', e.pay_status, 'platform_keys', e.platform_keys)
      from einvoice_docs e where e.sale_id = s.id))
  from sales s where s.id = p_sale
$$;

-- The sales list carries where each sale stands with NRS.
create or replace function public.get_sales(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_from date := nullif(p_filter->>'from', '')::date; v_to date := nullif(p_filter->>'to', '')::date;
  v_q text := nullif(lower(trim(p_filter->>'q')), ''); v_lim int := least(greatest(coalesce((p_filter->>'limit')::int, 300), 1), 2000); v_today date;
begin
  m := private.require(p_org, null);
  v_cost := private.can_see_costs(p_org);
  v_today := private.local_day(p_org, now());
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(r order by (r->>'created_at')::timestamptz desc), '[]'::jsonb) from (
      select jsonb_build_object('id', s.id, 'doc_type', s.doc_type, 'number', s.number, 'status', s.status, 'customer_id', s.customer_id,
        'customer_name', s.customer_name, 'customer_phone', s.customer_phone, 'customer_email', s.customer_email, 'location_id', s.location_id, 'channel', s.channel,
        'issue_date', s.issue_date, 'due_date', s.due_date, 'total', s.total, 'subtotal', s.subtotal, 'vat_total', s.vat_total, 'discount_total', s.discount_total,
        'amount_paid', s.amount_paid, 'credited', s.credited, 'confirmed', s.journal_id is not null, 'delivery_method', s.delivery_method,
        'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                        when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
        'cost_total', case when v_cost then (select sum(cost) from sale_lines where sale_id = s.id) end, 'created_at', s.created_at,
        'created_by_name', (select display_name from members where id = s.created_by),
        'shift_id', s.shift_id, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at, 'public_token', s.public_token, 'reference', s.reference,
        'original_sale_id', s.original_sale_id, 'export', s.export, 'customer_country', s.customer_country, 'pay_later', s.pay_later,
        'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
        'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
        'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(v_today - s.due_date, 0) end,
        'irn', s.irn, 'irn_status', s.irn_status) r
      from sales s
      where s.org_id = p_org
        and (nullif(p_filter->>'doc_type', '') is null or s.doc_type = any(string_to_array(p_filter->>'doc_type', ',')))
        and (nullif(p_filter->>'status', '') is null or s.status = any(string_to_array(p_filter->>'status', ',')))
        and (nullif(p_filter->>'customer_id', '') is null or s.customer_id = (p_filter->>'customer_id')::uuid)
        and (nullif(p_filter->>'location_id', '') is null or s.location_id = (p_filter->>'location_id')::uuid)
        and (nullif(p_filter->>'shift_id', '') is null or s.shift_id = (p_filter->>'shift_id')::uuid)
        and (nullif(p_filter->>'vat_status', '') is null or exists (select 1 from sale_lines l where l.sale_id = s.id and l.vat_status = (p_filter->>'vat_status')::smallint))
        and (nullif(p_filter->>'irn_status', '') is null or s.irn_status = any(string_to_array(p_filter->>'irn_status', ',')))
        and (v_from is null or s.issue_date >= v_from) and (v_to is null or s.issue_date <= v_to)
        and (v_q is null or lower(s.number) like '%' || v_q || '%' or lower(s.customer_name) like '%' || v_q || '%' or coalesce(s.customer_phone, '') like '%' || v_q || '%'
             or lower(coalesce(s.reference, '')) like '%' || v_q || '%' or lower(coalesce(s.irn, '')) like '%' || v_q || '%')
      order by s.created_at desc limit v_lim) x),
    'pending_payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'reference', c.reference,
        'customer_id', c.customer_id, 'customer_name', cu.name, 'received_at', c.received_at, 'note', c.note, 'bank_account_id', c.bank_account_id,
        'created_by_name', (select display_name from members where id = c.created_by),
        'sales', (select jsonb_agg(jsonb_build_object('id', s2.id, 'number', s2.number, 'amount', a.amount)) from collection_allocations a join sales s2 on s2.id = a.sale_id
                  where a.collection_id = c.id)) order by c.received_at), '[]'::jsonb)
      from collections c join customers cu on cu.id = c.customer_id where c.org_id = p_org and c.status = 'pending'),
    'orders_waiting', (select count(*) from sales where org_id = p_org and doc_type = 'order' and journal_id is null and status not in ('cancelled', 'void')));
end $$;

-- ---------------------------------------------------------------------------
-- 6. The edge function's calls: what is due, the facts of one sale, and what NRS said.
-- ---------------------------------------------------------------------------
-- Sales waiting to go (or stuck in sending for five minutes), oldest first, and payment news for signed ones.
create or replace function public.svc_einvoice_due(p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('sale_id', x.sale_id, 'org_id', x.org_id, 'what', x.what) order by x.at), '[]'::jsonb)
  from (select * from (
      select d.sale_id, d.org_id, 'send'::text what, d.next_try_at at from einvoice_docs d
      where (d.state = 'waiting' and d.next_try_at <= now()) or (d.state = 'sending' and d.sending_at < now() - interval '5 minutes')
      union all
      select d.sale_id, d.org_id, 'pay', d.pay_next_at from einvoice_docs d where d.state = 'signed' and d.pay_due is not null and d.pay_next_at <= now()
    ) y order by y.at limit greatest(least(coalesce(p_limit, 100), 500), 1)) x
$$;

-- Everything about a sale that NRS's schema asks for, as Counta keeps it. The edge function maps it.
create or replace function private.einvoice_facts(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; o public.orgs; e public.einvoice_settings; c public.customers; b public.locations; orig public.sales; v_tz text;
begin
  select * into s from sales where id = p_sale;
  select * into o from orgs where id = s.org_id;
  select * into e from einvoice_settings where org_id = s.org_id;
  select * into c from customers where id = s.customer_id;
  select * into b from locations where org_id = s.org_id order by is_main desc, created_at limit 1;
  select * into orig from sales where id = s.original_sale_id;
  v_tz := coalesce(o.timezone, 'Africa/Lagos');
  return jsonb_build_object(
    'sale', jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'status', s.status, 'issue_date', s.issue_date,
      'issue_time', to_char(coalesce(s.issued_at, s.created_at) at time zone v_tz, 'HH24:MI:SS'), 'due_date', s.due_date, 'currency', s.currency,
      'subtotal', s.subtotal, 'discount_total', s.discount_total, 'vat_total', s.vat_total, 'delivery_fee', s.delivery_fee, 'total', s.total,
      'amount_paid', s.amount_paid, 'credited', s.credited, 'paid', s.status = 'paid' or (s.amount_paid + s.credited >= s.total - 0.004 and s.total > 0),
      'prices_include_vat', s.prices_include_vat, 'reference', s.reference, 'notes', s.notes, 'terms', s.terms, 'export', s.export,
      'customer_country', s.customer_country, 'channel', s.channel),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'kind', l.kind, 'description', l.description, 'qty', l.qty, 'unit_label', l.unit_label,
        'unit_factor', l.unit_factor, 'unit_price', l.unit_price, 'discount', l.discount, 'vat_treatment', l.vat_treatment, 'vat_rate', l.vat_rate, 'net', l.net,
        'vat', l.vat, 'gross', l.gross, 'item_type', i.item_type, 'hs_code', i.hs_code, 'hs_label', private.nrs_label('hs-codes', i.hs_code), 'sku', coalesce(i.sku, i.barcode),
        'item_name', i.name, 'item_description', i.description) order by l.line_no), '[]'::jsonb)
      from sale_lines l left join items i on i.id = l.item_id where l.sale_id = s.id),
    'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'email', o.email, 'phone', o.phone, 'description', o.principal_activity, 'offering', o.offering,
      'street', coalesce(nullif(btrim(b.address), ''), o.address), 'city', b.city, 'postcode', b.postcode, 'state', b.state, 'lga', b.lga,
      'place', private.nrs_place(b.state, b.lga), 'service_code', e.service_code, 'service_label', private.nrs_label('services-codes', e.service_code)),
    'customer', jsonb_build_object('kind', c.kind, 'walk_in', coalesce(c.is_walk_in, false), 'name', coalesce(nullif(btrim(s.customer_name), ''), c.name),
      'tin', coalesce(nullif(btrim(s.customer_tin), ''), c.tin), 'email', coalesce(s.customer_email, c.email), 'phone', coalesce(s.customer_phone, c.phone),
      'street', coalesce(nullif(btrim(s.customer_address), ''), c.address), 'city', c.city, 'postcode', c.postcode, 'state', c.state, 'lga', c.lga,
      'country', upper(coalesce(nullif(s.customer_country, ''), c.country, 'NG')), 'place', private.nrs_place(c.state, c.lga)),
    'payments', (select coalesce(jsonb_agg(distinct x.method), '[]'::jsonb) from (
        select col.method from collection_allocations a join collections col on col.id = a.collection_id
        where a.sale_id = s.id and col.status in ('confirmed', 'pending') and col.direction = 'in'
        union select r.method from payment_requests r where r.sale_id = s.id and r.status = 'paid') x),
    'original', case when orig.id is not null then jsonb_build_object('number', orig.number, 'issue_date', orig.issue_date,
      'irn', (select irn from einvoice_docs where sale_id = orig.id)) end,
    'codes', jsonb_build_object(
      'invoice', coalesce((select code from nrs_codes where list = 'invoice-types' and lower(label) = 'commercial invoice' limit 1), '381'),
      'credit_note', coalesce((select code from nrs_codes where list = 'invoice-types' and lower(label) = 'credit note' limit 1), '380')));
end $$;

-- Takes one sale to work on. what: 'send' (validate and sign), 'kick' (as asked when it was issued: a cleared sale is
-- sent, a reported one only gets its QR code and waits for the next batch) or 'pay' (tell NRS it was paid).
-- p: {service_id} TaxStreem's Service ID, for a business on TaxStreem's keys. The IRN is made here: the number in letters
-- and digits (on TaxStreem's keys, after four characters of the business's id, since businesses share TaxStreem's
-- Service ID), the Service ID and the issue date.
create or replace function public.svc_einvoice_claim(p_sale uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; e public.einvoice_settings; od public.einvoice_docs; v_svc text; v_no text; v_irn text; v_mode text;
  v_ref text;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  select * into s from sales where id = p_sale;
  select * into e from einvoice_settings where org_id = d.org_id;
  v_mode := case when p_what = 'pay' then 'pay' when p_what = 'kick' and d.kind = 'report' then 'qr' else 'send' end;
  if v_mode = 'pay' then
    if d.state <> 'signed' or d.pay_due is null then return jsonb_build_object('skip', 'nothing to tell'); end if;
    update einvoice_docs set pay_next_at = now() + interval '10 minutes', updated_at = now() where sale_id = p_sale;
    select col.reference into v_ref from collection_allocations a join collections col on col.id = a.collection_id
      where a.sale_id = p_sale and col.status = 'confirmed' order by col.received_at desc limit 1;
    return jsonb_build_object('what', 'pay', 'org_id', d.org_id, 'irn', d.irn, 'pay', d.pay_due, 'reference', coalesce(v_ref, s.number),
      'creds', jsonb_build_object('platform_keys', coalesce(d.platform_keys, e.platform_keys), 'business_id', e.business_id, 'api_key_ct', e.api_key_ct,
        'api_secret_ct', e.api_secret_ct));
  end if;
  if d.state not in ('waiting', 'sending') then return jsonb_build_object('skip', d.state); end if;
  if d.state = 'sending' and d.sending_at > now() - interval '5 minutes' then return jsonb_build_object('skip', 'busy'); end if;
  if v_mode = 'qr' and d.qr is not null then return jsonb_build_object('skip', 'has a QR code'); end if;
  -- A credit note goes after its sale is signed, and not at all when its sale never went.
  if d.doc = 'credit_note' then
    select * into od from einvoice_docs where sale_id = s.original_sale_id;
    if od.state in ('waiting', 'sending') then
      update einvoice_docs set next_try_at = now() + interval '5 minutes', note = 'Waiting for NRS to sign ' || coalesce((select number from sales where id = s.original_sale_id), 'the sale') || ' first.',
        updated_at = now() where sale_id = p_sale;
      return jsonb_build_object('skip', 'waiting for the original');
    end if;
    if od.state is distinct from 'signed' then
      update einvoice_docs set state = 'stopped', note = 'NRS never signed the sale it corrects, so this credit note stays in Counta.', updated_at = now() where sale_id = p_sale;
      update sales set irn_status = 'stopped' where id = p_sale;
      return jsonb_build_object('skip', 'original not signed');
    end if;
  end if;
  v_svc := case when e.platform_keys then upper(btrim(coalesce(p->>'service_id', ''))) else e.service_id end;
  if v_svc is null or v_svc !~ '^[A-Z0-9]{8}$' then
    update einvoice_docs set state = 'waiting', next_try_at = now() + interval '15 minutes', note = 'The Service ID is not set, so the IRN cannot be made.', updated_at = now()
    where sale_id = p_sale;
    return jsonb_build_object('skip', 'no service id');
  end if;
  v_no := regexp_replace(s.number, '[^A-Za-z0-9]', '', 'g');
  if e.platform_keys then v_no := upper(left(replace(s.org_id::text, '-', ''), 4)) || v_no; end if;
  v_irn := private.nrs_irn(v_no, v_svc, s.issue_date);
  -- Not signed yet, so the IRN follows the keys now in use (its QR code with it).
  if d.irn is distinct from v_irn then
    update einvoice_docs set irn = v_irn, qr = null, qr_at = null where sale_id = p_sale;
    d.irn := v_irn; d.qr := null;
  end if;
  if v_mode = 'send' then
    update einvoice_docs set state = 'sending', sending_at = now(), tries = tries + 1, platform_keys = e.platform_keys, updated_at = now() where sale_id = p_sale;
    update sales set irn = v_irn, irn_status = 'sending' where id = p_sale;
  else
    update sales set irn = v_irn where id = p_sale;
  end if;
  return jsonb_build_object('what', v_mode, 'org_id', d.org_id, 'kind', d.kind, 'doc', d.doc, 'irn', v_irn, 'invoice_reference', v_no, 'tries', d.tries + case when v_mode = 'send' then 1 else 0 end,
    'has_qr', d.qr is not null, 'held', d.held,
    'creds', jsonb_build_object('platform_keys', e.platform_keys, 'business_id', e.business_id, 'service_id', v_svc, 'api_key_ct', e.api_key_ct,
      'api_secret_ct', e.api_secret_ct, 'crypto_ct', e.crypto_ct),
    'facts', private.einvoice_facts(p_sale));
end $$;

-- What NRS said. outcome: 'signed', 'refused' (NRS will not take it as it is: a person puts it right), 'retry' (NRS was
-- down or busy, or the keys need attention: tried again later) or 'qr' (the QR code only). p: {outcome, note, answer, qr,
-- pay_status}.
create or replace function public.svc_einvoice_done(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; v_out text := p->>'outcome'; v_wait interval; v_state text;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'gone'); end if;
  select * into s from sales where id = p_sale;
  if nullif(p->>'qr', '') is not null and d.qr is null then
    update einvoice_docs set qr = left(p->>'qr', 4000), qr_at = now() where sale_id = p_sale;
  end if;
  if v_out = 'qr' or v_out is null then
    return jsonb_build_object('ok', true, 'state', d.state);
  end if;
  if d.state <> 'sending' then return jsonb_build_object('ok', false, 'reason', 'not sending', 'state', d.state); end if;
  if v_out = 'signed' then
    update einvoice_docs set state = 'signed', signed_at = now(), sending_at = null, note = left(p->>'note', 500), answer = p->'answer',
      pay_status = coalesce(nullif(p->>'pay_status', ''), pay_status),
      pay_due = case when pay_due is not null and pay_due = coalesce(nullif(p->>'pay_status', ''), '') then null else pay_due end,
      pay_next_at = case when pay_due is not null and pay_due <> coalesce(nullif(p->>'pay_status', ''), '') then now() else pay_next_at end, updated_at = now()
    where sale_id = p_sale;
    update sales set irn_status = 'signed' where id = p_sale;
    if d.held then perform private.einvoice_issue_held(p_sale); end if;
    -- Paid while NRS was checking it: NRS hears of the payment next.
    if (select status from sales where id = p_sale) = 'paid' and coalesce(nullif(p->>'pay_status', ''), '') <> 'PAID' then
      update einvoice_docs set pay_due = 'PAID', pay_next_at = now() where sale_id = p_sale;
    end if;
    v_state := 'signed';
  elsif v_out = 'refused' then
    update einvoice_docs set state = 'refused', sending_at = null, note = left(coalesce(nullif(p->>'note', ''), 'NRS refused it.'), 1000), answer = p->'answer', updated_at = now()
    where sale_id = p_sale;
    update sales set irn_status = 'refused' where id = p_sale;
    perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_refused', 'NRS refused ' || s.number, left(coalesce(nullif(p->>'note', ''), 'NRS refused it.'), 300),
      '/sell/sales?open=' || s.id, 'einvoice_refused:' || s.id);
    v_state := 'refused';
  else
    v_wait := case when d.tries <= 1 then interval '1 minute' when d.tries = 2 then interval '5 minutes' when d.tries = 3 then interval '15 minutes'
                   when d.tries = 4 then interval '30 minutes' else interval '1 hour' end;
    update einvoice_docs set state = 'waiting', sending_at = null, next_try_at = now() + v_wait, note = left(p->>'note', 500), answer = p->'answer', updated_at = now()
    where sale_id = p_sale;
    update sales set irn_status = 'waiting' where id = p_sale;
    v_state := 'waiting';
  end if;
  return jsonb_build_object('ok', true, 'state', v_state);
end $$;

create or replace function public.svc_einvoice_pay_done(p_sale uuid, p_ok boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.pay_due is null then return jsonb_build_object('ok', false); end if;
  if p_ok then
    update einvoice_docs set pay_status = d.pay_due, pay_due = null, pay_next_at = null, pay_note = null, pay_tries = 0, updated_at = now() where sale_id = p_sale;
  else
    update einvoice_docs set pay_tries = pay_tries + 1, pay_note = left(p_note, 500),
      pay_next_at = now() + case when d.pay_tries < 2 then interval '5 minutes' when d.pay_tries < 4 then interval '30 minutes' else interval '3 hours' end,
      updated_at = now() where sale_id = p_sale;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Settings: the switch, the service code to confirm, and how the sending is going.
-- ---------------------------------------------------------------------------
create or replace function private.einvoice_queue(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'waiting', (select count(*) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'oldest_at', (select min(created_at) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'signed_today', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed' and signed_at >= date_trunc('day', now())),
    'signed', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed'),
    'refused', (select count(*) from einvoice_docs where org_id = p_org and state = 'refused'),
    'pay_waiting', (select count(*) from einvoice_docs where org_id = p_org and pay_due is not null),
    'attention', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
        select jsonb_build_object('sale_id', d.sale_id, 'number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
          'state', d.state, 'held', d.held, 'note', d.note, 'tries', d.tries, 'at', d.updated_at) x
        from einvoice_docs d join sales s on s.id = d.sale_id
        where d.org_id = p_org and (d.state = 'refused' or (d.state in ('waiting', 'sending') and (d.tries >= 3 or d.created_at < now() - interval '1 hour')))
        order by d.updated_at desc limit 20) y))
$$;

create or replace function private.einvoice_readiness(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; s public.einvoice_settings; b public.locations; v jsonb := '[]'::jsonb; v_missing text[];
  n_items int; n_coded int; n_wait int; n_review int; n_cust int; v_tin text;
begin
  select * into o from orgs where id = p_org;
  select * into s from einvoice_settings where org_id = p_org;
  select * into b from locations where org_id = p_org order by is_main desc, created_at limit 1;

  -- The business's Tax ID.
  v_tin := regexp_replace(coalesce(o.tin, ''), '[^0-9]', '', 'g');
  v := v || jsonb_build_object('id', 'tin', 'blocking', true, 'ok', v_tin <> '', 'title', 'The business''s Tax ID', 'link', '/settings#books',
    'detail', case when v_tin = '' then 'Add the business''s Tax ID in Settings, under Books and tax.'
      when o.tin_status in ('verified', 'confirmed') then 'Tax ID ending ' || right(v_tin, 4) || ', checked with NRS.'
      else 'Tax ID ending ' || right(v_tin, 4) || '. It has not been checked with NRS yet.' end);

  -- Email and phone: NRS puts both on the supplier's side of each invoice.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(o.email, '')), '') is null then 'email' end,
    case when nullif(btrim(coalesce(o.phone, '')), '') is null then 'phone number' end], null);
  v := v || jsonb_build_object('id', 'contact', 'blocking', true, 'ok', cardinality(v_missing) = 0, 'title', 'Email and phone', 'link', '/settings#business',
    'detail', case when cardinality(v_missing) = 0 then o.email || ' and ' || o.phone || '.' else 'Add the business''s ' || private.words_and(v_missing) || ' in Settings.' end);

  -- The address on the invoice: the main branch's street, city, state and LGA. A postcode is asked for, not required.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(b.address, '')), '') is null then 'street address' end,
    case when b.city is null then 'city' end, case when b.state is null then 'state' end, case when b.lga is null then 'LGA' end], null);
  v := v || jsonb_build_object('id', 'address', 'blocking', true, 'ok', b.id is not null and cardinality(v_missing) = 0, 'title', 'The business address', 'link', '/inventory/locations',
    'detail', case when b.id is null then 'Add the main branch under Locations.'
      when cardinality(v_missing) = 0 then b.address || ', ' || b.city || ', ' || b.lga || ', ' || b.state || coalesce(' ' || b.postcode, '') || '.'
        || case when b.postcode is null then ' Add the postcode if you know it.' else '' end
      else 'Add the ' || private.words_and(v_missing) || ' of ' || b.name || ' under Locations.' end);

  -- The keys.
  v_missing := array_remove(array[case when s.business_id is null then 'Business ID' end, case when s.service_id is null then 'Service ID' end,
    case when s.api_key_ct is null then 'API key' end, case when s.api_secret_ct is null then 'API secret' end,
    case when s.crypto_ct is null then 'crypto_keys.txt' end], null);
  v := v || jsonb_build_object('id', 'keys', 'blocking', true, 'ok', coalesce(s.platform_keys, false) or (s.org_id is not null and cardinality(v_missing) = 0),
    'title', 'Your NRS keys', 'link', '/settings#einvoicing',
    'detail', case when s.platform_keys then 'Running on TaxStreem''s keys while NRS is in test mode. Add your own before you go live.'
      when s.org_id is null or cardinality(v_missing) = 5 then 'Add the Business ID, Service ID, API key, API secret and crypto_keys.txt from your NRS dashboard.'
      when cardinality(v_missing) = 0 then 'All five are saved.'
      else 'Add the ' || private.words_and(v_missing) || '.' end);

  -- NRS has accepted them.
  v := v || jsonb_build_object('id', 'check', 'blocking', true, 'ok', coalesce(s.check_ok and s.check_version = s.keys_version, false),
    'title', 'NRS accepts the keys', 'link', '/settings#einvoicing',
    'detail', case when s.checked_at is null or s.check_version is distinct from s.keys_version then 'Test the keys with NRS.'
      else coalesce(s.check_note, case when s.check_ok then 'NRS accepted them.' else 'NRS did not accept them.' end) end);

  -- The service code. Required when the business sells services; goods sellers use it for delivery and other service lines.
  -- One Gemini was unsure of counts once the owner confirms it.
  v := v || jsonb_build_object('id', 'service', 'blocking', coalesce(o.offering, 'goods') in ('services', 'both'),
    'ok', s.service_code is not null and not coalesce(s.service_review, false),
    'title', 'Service code', 'link', '/settings#einvoicing',
    'detail', case when s.service_code is not null and coalesce(s.service_review, false) then s.service_code || ' ' || coalesce(private.nrs_label('services-codes', s.service_code), '')
        || '. Gemini is ' || round(coalesce(private.num(s.service_basis->>'confidence'), 0) * 100) || '% sure: confirm it or choose another.'
      when s.service_code is not null then s.service_code || ' ' || coalesce(private.nrs_label('services-codes', s.service_code), '') || '.'
      when s.org_id is not null and s.service_checked_at is null then 'Gemini is choosing it.'
      else 'Choose the code for the services you sell.' end);

  -- HS codes on items: Gemini chooses them; an invoice line waits for its item's code.
  select count(*), count(*) filter (where hs_code is not null), count(*) filter (where hs_checked_at is null and coalesce(hs_basis->>'source', '') <> 'manual'),
         count(*) filter (where hs_review)
    into n_items, n_coded, n_wait, n_review
  from items where org_id = p_org and not archived;
  v := v || jsonb_build_object('id', 'items', 'blocking', false, 'ok', n_coded = n_items and n_review = 0, 'title', 'HS codes on items', 'link', '/inventory/items',
    'counts', jsonb_build_object('items', n_items, 'coded', n_coded, 'waiting', n_wait, 'review', n_review),
    'detail', case when n_items = 0 then 'No items yet.'
      else n_coded || ' of ' || n_items || case when n_items = 1 then ' item has' else ' items have' end || ' an HS code.'
        || case when n_wait > 0 and s.org_id is not null then ' Gemini is choosing ' || n_wait || ' more.' else '' end
        || case when n_review > 0 then ' ' || n_review || ' to confirm.' else '' end end);

  -- Business and government customers need a Tax ID on their invoices.
  select count(*) into n_cust from customers where org_id = p_org and not archived and kind in ('business', 'government')
    and coalesce(upper(country), 'NG') = 'NG' and nullif(btrim(coalesce(tin, '')), '') is null;
  v := v || jsonb_build_object('id', 'customers', 'blocking', false, 'ok', n_cust = 0, 'title', 'Tax IDs of business customers', 'link', '/sell/customers',
    'detail', case when n_cust = 0 then 'Every business and government customer has a Tax ID.'
      else n_cust || case when n_cust = 1 then ' business or government customer has' else ' business or government customers have' end
        || ' no Tax ID. Invoices to them wait until one is added.' end);
  return v;
end $$;

create or replace function public.einvoice_settings_get(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; s public.einvoice_settings; v_ready jsonb;
begin
  m := private.einvoice_viewer(p_org);
  select * into s from einvoice_settings where org_id = p_org;
  v_ready := private.einvoice_readiness(p_org);
  return jsonb_build_object(
    'started', s.org_id is not null,
    'enabled', coalesce(s.enabled, false), 'enabled_at', s.enabled_at,
    'platform_keys', coalesce(s.platform_keys, false),
    'business_id', s.business_id, 'service_id', s.service_id,
    'keys', jsonb_build_object('api_key', s.api_key_hint, 'api_secret', s.api_secret_hint, 'crypto_keys', s.crypto_hint),
    'service', case when s.service_code is null then null else jsonb_build_object('code', s.service_code, 'label', private.nrs_label('services-codes', s.service_code),
      'source', s.service_basis->>'source', 'reason', s.service_basis->>'reason', 'confidence', s.service_basis->'confidence', 'review', coalesce(s.service_review, false)) end,
    'service_waiting', s.org_id is not null and s.service_checked_at is null,
    'check', case when s.checked_at is null then null else jsonb_build_object('at', s.checked_at, 'ok', s.check_ok, 'note', s.check_note,
      'current', s.check_version = s.keys_version) end,
    'readiness', v_ready,
    'ready', not exists (select 1 from jsonb_array_elements(v_ready) r where (r->>'blocking')::boolean and not (r->>'ok')::boolean),
    'queue', case when s.org_id is null then null else private.einvoice_queue(p_org) end,
    'can', jsonb_build_object('edit', private.perm_of(m, 'manage_settings')));
end $$;

create or replace function public.einvoice_settings_set(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.einvoice_settings; v_new uuid; v_biz text; v_svc text; v_code text; v_changed boolean := false;
  v_kick boolean := false; r jsonb;
begin
  m := private.require(p_org, 'manage_settings');
  p := coalesce(p, '{}'::jsonb);
  insert into einvoice_settings (org_id, updated_by) values (p_org, auth.uid()) on conflict (org_id) do nothing returning org_id into v_new;
  v_kick := v_new is not null;
  select * into s from einvoice_settings where org_id = p_org for update;
  if p ? 'business_id' then
    v_biz := lower(nullif(btrim(coalesce(p->>'business_id', '')), ''));
    if v_biz is not null and v_biz !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'The Business ID is the long code on your NRS dashboard, in five groups like 6dc03c76-1d83-4a39-a4de-51bd70547aef.';
    end if;
    if v_biz is distinct from s.business_id then update einvoice_settings set business_id = v_biz where org_id = p_org; v_changed := true; end if;
  end if;
  if p ? 'service_id' then
    v_svc := nullif(upper(regexp_replace(coalesce(p->>'service_id', ''), '\s', '', 'g')), '');
    if v_svc is not null and v_svc !~ '^[A-Z0-9]{8}$' then raise exception 'The Service ID is 8 letters and numbers, like 94ND90NR.'; end if;
    if v_svc is distinct from s.service_id then update einvoice_settings set service_id = v_svc where org_id = p_org; v_changed := true; end if;
  end if;
  if v_changed and not s.platform_keys then
    update einvoice_settings set keys_version = keys_version + 1, enabled = false where org_id = p_org;
  end if;
  if p ? 'service_code' then
    v_code := nullif(regexp_replace(coalesce(p->>'service_code', ''), '[^0-9]', '', 'g'), '');
    if v_code is null then
      update einvoice_settings set service_code = null, service_basis = null, service_checked_at = null, service_review = false where org_id = p_org;
      v_kick := true;
    else
      if v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code) then
        raise exception '% is not on NRS''s list of service codes.', coalesce(nullif(btrim(p->>'service_code'), ''), v_code);
      end if;
      update einvoice_settings set service_code = v_code, service_checked_at = now(), service_review = false,
        service_basis = jsonb_build_object('source', 'manual', 'code', v_code, 'by', m.display_name, 'at', now(),
          'ai', case when coalesce(s.service_basis->>'source', '') = 'manual' then s.service_basis->'ai' else s.service_basis end)
      where org_id = p_org;
    end if;
  end if;
  -- Gemini's code, confirmed as it is.
  if coalesce((p->>'service_confirm')::boolean, false) then
    if s.service_code is null then raise exception 'There is no service code to confirm yet.'; end if;
    update einvoice_settings set service_review = false,
      service_basis = coalesce(service_basis, '{}'::jsonb) || jsonb_build_object('confirmed_by', m.display_name, 'confirmed_at', now())
    where org_id = p_org;
  end if;
  if p ? 'enabled' then
    if coalesce((p->>'enabled')::boolean, false) then
      select x into r from jsonb_array_elements(private.einvoice_readiness(p_org)) x where (x->>'blocking')::boolean and not (x->>'ok')::boolean limit 1;
      if r is not null then raise exception 'Not ready yet. %', r->>'detail'; end if;
      update einvoice_settings set enabled = true, enabled_at = case when enabled then enabled_at else now() end where org_id = p_org;
    else
      update einvoice_settings set enabled = false where org_id = p_org;
    end if;
  end if;
  update einvoice_settings set updated_at = now(), updated_by = auth.uid() where org_id = p_org;
  if v_kick then perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending')); end if;
  return public.einvoice_settings_get(p_org);
end $$;

-- What TaxStreem's admins see: now also how the sending is going.
create or replace function public.admin_einvoice_business(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.einvoice_settings; v_ready jsonb;
begin
  perform private.require_staff();
  if not exists (select 1 from orgs where id = p_org) then raise exception 'Business not found.'; end if;
  select * into s from einvoice_settings where org_id = p_org;
  v_ready := private.einvoice_readiness(p_org);
  return jsonb_build_object('started', s.org_id is not null, 'enabled', coalesce(s.enabled, false), 'enabled_at', s.enabled_at,
    'platform_keys', coalesce(s.platform_keys, false), 'platform_keys_note', s.platform_keys_note,
    'own', jsonb_build_object('business_id', s.business_id is not null, 'service_id', s.service_id is not null, 'api_key', s.api_key_ct is not null,
      'api_secret', s.api_secret_ct is not null, 'crypto_keys', s.crypto_ct is not null),
    'check', case when s.checked_at is null then null else jsonb_build_object('at', s.checked_at, 'ok', s.check_ok, 'note', s.check_note,
      'current', s.check_version = s.keys_version) end,
    'ready', not exists (select 1 from jsonb_array_elements(v_ready) r where (r->>'blocking')::boolean and not (r->>'ok')::boolean),
    'readiness', (select coalesce(jsonb_agg(jsonb_build_object('id', r->>'id', 'ok', (r->>'ok')::boolean, 'blocking', (r->>'blocking')::boolean, 'title', r->>'title',
      'counts', r->'counts')), '[]'::jsonb) from jsonb_array_elements(v_ready) r),
    'queue', case when s.org_id is null then null else (private.einvoice_queue(p_org) - 'attention') end);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Every five minutes: the codes Gemini still has to choose, the sales due to go, and a warning when one has waited
--    twelve hours (and again at twenty) of the twenty-four NRS allows.
-- ---------------------------------------------------------------------------
create or replace function private.einvoice_tick() returns void
language plpgsql security definer set search_path = public, private as $$
declare r record; v_h int;
begin
  if exists (select 1 from items i join einvoice_settings s on s.org_id = i.org_id
             where i.hs_checked_at is null and not i.archived and coalesce(i.hs_basis->>'source', '') <> 'manual')
     or exists (select 1 from einvoice_settings where service_checked_at is null and coalesce(service_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending'));
  end if;
  if exists (select 1 from einvoice_docs where (state = 'waiting' and next_try_at <= now()) or (state = 'sending' and sending_at < now() - interval '5 minutes')
             or (state = 'signed' and pay_due is not null and pay_next_at <= now())) then
    perform private.call_function('einvoice', jsonb_build_object('action', 'send'));
  end if;
  for r in select d.org_id, min(d.created_at) oldest, count(*) filter (where d.created_at < now() - interval '12 hours') n12,
             count(*) filter (where d.created_at < now() - interval '20 hours') n20
           from einvoice_docs d where d.state in ('waiting', 'sending')
           group by d.org_id having min(d.created_at) < now() - interval '12 hours' loop
    v_h := case when r.oldest < now() - interval '20 hours' then 20 else 12 end;
    perform private.alert_send(r.org_id, 'einvoice_late', v_h || 'h:' || to_char(r.oldest, 'YYYYMMDDHH24MISS'), array['push', 'email'], jsonb_build_object(
      'perm', 'manage_settings', 'url', '/settings#einvoicing',
      'title', case when (case when v_h = 20 then r.n20 else r.n12 end) = 1 then 'A sale has waited '
        else (case when v_h = 20 then r.n20 else r.n12 end) || ' sales have waited ' end || v_h || ' hours to reach NRS',
      'body', 'NRS expects each sale within 24 hours. Counta keeps trying; open E-invoicing in Settings to see why they are waiting.'));
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Who may call what.
-- ---------------------------------------------------------------------------
revoke all on function public.einvoice_take_back(uuid), public.einvoice_send_again(uuid) from public, anon;
grant execute on function public.einvoice_take_back(uuid), public.einvoice_send_again(uuid) to authenticated;
revoke all on function public.svc_einvoice_due(int), public.svc_einvoice_claim(uuid, text, jsonb), public.svc_einvoice_done(uuid, jsonb),
  public.svc_einvoice_pay_done(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.svc_einvoice_due(int), public.svc_einvoice_claim(uuid, text, jsonb), public.svc_einvoice_done(uuid, jsonb),
  public.svc_einvoice_pay_done(uuid, boolean, text) to service_role;
revoke all on function private.einvoice_route(uuid), private.einvoice_open(uuid, text, boolean, uuid), private.on_sale_posted_einvoice(),
  private.on_bujeti_invoice_einvoice(), private.on_sale_void_einvoice(), private.on_sale_paid_einvoice(), private.einvoice_issue_held(uuid),
  private.einvoice_facts(uuid), private.einvoice_queue(uuid) from public, anon, authenticated;
