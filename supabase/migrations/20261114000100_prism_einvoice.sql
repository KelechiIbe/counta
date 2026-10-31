-- Counta · E-invoicing, part 3 (second half): Prism's channel for partners
--
-- Prism, TaxStreem's product for partners (point-of-sale systems, ERPs, banks' merchant tools), holds the partners' keys,
-- counts their credits and runs the developer portal. It passes each partner's invoices to Counta at
-- /functions/v1/einvoice/prism/..., signed with the secret Prism's bills use (TAXSTREEM_SSO_SECRET). docs/prism-einvoicing.md
-- has the whole contract.
--
--   1. A merchant. Its Counta business is made on Prism's first call, owned by the contact Prism names: that person becomes
--      the owner the first time they open Counta from TaxStreem. Its NRS keys come through the channel (wrapped in the HSM
--      by the einvoice function, as in Settings) or are added in Settings. E-invoicing switches itself on once everything
--      NRS needs is in place.
--   2. An invoice. The partner's key decides where it goes. books: true records it in the merchant's books, a sale like
--      any other (channel api). books: false is e-invoicing only: an einvoice_only document that NRS signs and the
--      merchant sees under E-invoicing, outside the books, the reports and the tax returns. Either way it goes to NRS the
--      way Counta's own sales do, and to the buyer once signed. An invoice NRS refused can be sent again, corrected, under
--      the same ref.
--   3. Paid invoices in the books are paid into a holding account named after the partner (like Paystack's), matched to
--      the bank in Banking when the money lands. An invoice to a business waits for NRS to sign it before it is issued,
--      as in Counta, and its payment is booked then.
--   4. Invoices through Prism never count against the merchant's plan: Prism charges partners in credits.
--   5. Prism hears how each one went (prism_callbacks, sent to PRISM_CALLBACK_URL): signed, refused, delivered to the
--      buyer, NRS told it is paid.
--
-- einvoice_docs now holds documents outside the books too (source 'only'): its sale_id is the einvoice_only id for those,
-- so it no longer references sales. Deleting a sale or a document still deletes its row, by trigger.

-- ---------------------------------------------------------------------------
-- 1. Documents outside the books
-- ---------------------------------------------------------------------------
alter table public.einvoice_docs add column if not exists source text not null default 'sale';
alter table public.einvoice_docs drop constraint if exists einvoice_docs_source_check;
alter table public.einvoice_docs add constraint einvoice_docs_source_check check (source in ('sale', 'only'));
alter table public.einvoice_docs drop constraint if exists einvoice_docs_sale_id_fkey;
comment on column public.einvoice_docs.sale_id is 'The sale (source sale), or the einvoice_only document (source only).';

-- An invoice NRS signs for a business, kept outside its books. facts holds what einvoice_facts gives for a sale (sale,
-- lines, customer, payments), as the partner sent it; the seller and NRS's codes are added each time it goes to NRS.
create table if not exists public.einvoice_only (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  partner_name text check (partner_name is null or length(partner_name) <= 120),
  number text not null check (number ~ '^[A-Za-z0-9]{1,40}$'),
  doc text not null check (doc in ('invoice', 'receipt', 'credit_note')),
  issue_date date not null,
  due_date date,
  currency text not null default 'NGN' check (currency ~ '^[A-Z]{3}$'),
  customer_name text check (customer_name is null or length(customer_name) <= 160),
  customer_tin text check (customer_tin is null or length(customer_tin) <= 30),
  customer_kind text not null default 'individual' check (customer_kind in ('individual', 'business', 'government')),
  subtotal numeric(16, 2) not null default 0,
  vat_total numeric(16, 2) not null default 0,
  total numeric(16, 2) not null check (total > 0),
  paid boolean not null default false,
  paid_at timestamptz,
  pay_reference text check (pay_reference is null or length(pay_reference) <= 80),
  original_id uuid references public.einvoice_only(id) on delete set null,
  facts jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- The IRN is the number, the Service ID and the day: one number a day for each business.
create unique index if not exists einvoice_only_number on public.einvoice_only (org_id, number, issue_date);
create index if not exists einvoice_only_org on public.einvoice_only (org_id, created_at desc);
create index if not exists einvoice_only_original on public.einvoice_only (original_id) where original_id is not null;
alter table public.einvoice_only enable row level security;
revoke all on public.einvoice_only from anon, authenticated;

-- Prism's invoices, whichever way they went: the partner's ref, and the sale or document it became.
create table if not exists public.prism_einvoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  partner_id text not null check (partner_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$'),
  partner_name text check (partner_name is null or length(partner_name) <= 120),
  ref text not null check (length(ref) between 1 and 100),
  books boolean not null,
  doc_id uuid not null,
  doc text not null check (doc in ('invoice', 'receipt', 'credit_note')),
  -- A payment that waits for NRS to sign the invoice before it is booked (an invoice to a business, in the books).
  pay_pending jsonb,
  body jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists prism_einvoices_ref on public.prism_einvoices (org_id, partner_id, ref);
create unique index if not exists prism_einvoices_doc on public.prism_einvoices (doc_id);
alter table public.prism_einvoices enable row level security;
revoke all on public.prism_einvoices from anon, authenticated;

-- What Prism is told, each change once. The body is made when it is sent, so it carries the invoice as it is then.
create table if not exists public.prism_callbacks (
  id uuid primary key default gen_random_uuid(),
  prism_id uuid not null references public.prism_einvoices(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  change text not null check (change in ('signed', 'refused', 'stopped', 'buyer_transmitted', 'buyer_acknowledged', 'buyer_failed', 'paid_reported')),
  state text not null default 'due' check (state in ('due', 'sending', 'sent', 'failed')),
  tries int not null default 0,
  next_at timestamptz not null default now(),
  sending_at timestamptz,
  last_status int,
  last_error text check (last_error is null or length(last_error) <= 500),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists prism_callbacks_due on public.prism_callbacks (next_at) where state in ('due', 'sending');
create index if not exists prism_callbacks_prism on public.prism_callbacks (prism_id);
create index if not exists prism_callbacks_org on public.prism_callbacks (org_id);
alter table public.prism_callbacks enable row level security;
revoke all on public.prism_callbacks from anon, authenticated;

-- A notification about a document outside the books is kept against it.
alter table public.einvoice_webhooks add column if not exists only_id uuid references public.einvoice_only(id) on delete set null;
create index if not exists einvoice_webhooks_only on public.einvoice_webhooks (only_id) where only_id is not null;
-- The HS code a partner gave for a goods line that is not one of the business's items.
alter table public.sale_lines add column if not exists hs_code text check (hs_code is null or hs_code ~ '^[0-9]{4}\.[0-9]{2}$');
-- A business Prism made (and keeps up to date) rather than one its owner set up.
alter table public.orgs add column if not exists prism_merchant boolean not null default false;

-- Deleting a sale or a document takes its row in einvoice_docs, and the partner's ref, with it.
create or replace function private.on_einvoice_source_deleted() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  delete from einvoice_docs where sale_id = old.id and source = case when tg_table_name = 'sales' then 'sale' else 'only' end;
  delete from prism_einvoices where doc_id = old.id;
  return null;
end $$;
drop trigger if exists sales_einvoice_deleted on public.sales;
create trigger sales_einvoice_deleted after delete on public.sales for each row execute function private.on_einvoice_source_deleted();
drop trigger if exists einvoice_only_deleted on public.einvoice_only;
create trigger einvoice_only_deleted after delete on public.einvoice_only for each row execute function private.on_einvoice_source_deleted();

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- The sale an e-invoice is about, or, for a document outside the books, a sale made up from it with the same fields
-- (number, dates, buyer, totals, the document it corrects), so the sending reads both the same way.
create or replace function private.einvoice_doc_sale(p_id uuid) returns public.sales
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; o public.einvoice_only;
begin
  select * into s from sales where id = p_id;
  if found then return s; end if;
  select * into o from einvoice_only where id = p_id;
  if not found then return null; end if;
  s.id := o.id; s.org_id := o.org_id; s.number := o.number; s.doc_type := o.doc; s.status := case when o.paid then 'paid' else 'open' end;
  s.issue_date := o.issue_date; s.due_date := o.due_date; s.currency := o.currency; s.customer_name := o.customer_name; s.customer_tin := o.customer_tin;
  s.subtotal := o.subtotal; s.vat_total := o.vat_total; s.total := o.total; s.original_sale_id := o.original_id; s.channel := 'api';
  s.created_at := o.created_at;
  return s;
end $$;

-- Where a person opens it: the sale, or the document under E-invoicing in Settings.
create or replace function private.einvoice_doc_link(p_id uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select case when exists (select 1 from public.sales where id = p_id) then '/sell/sales?open=' || p_id
    else '/settings?einvoice=' || p_id || '#einvoicing' end
$$;

-- A state or LGA as a partner sends it: Counta's names, or NRS's codes (NG-LA, NG-LA-IKE).
create or replace function private.prism_state(p text) returns text
language sql stable set search_path = public, private as $$
  select case when upper(btrim(coalesce(p, ''))) ~ '^NG-[A-Z]{2}$'
    then (select l.state from public.ng_lgas l where left(l.nrs_code, 5) = upper(btrim(p)) limit 1)
    else private.ng_state(p) end
$$;
create or replace function private.prism_lga(p_state text, p text) returns text
language sql stable set search_path = public, private as $$
  select case when upper(btrim(coalesce(p, ''))) ~ '^NG-[A-Z]{2}-[A-Z0-9]{2,4}$'
    then (select l.lga from public.ng_lgas l where l.nrs_code = upper(btrim(p)) and l.state = private.ng_state(p_state) limit 1)
    else private.ng_lga(p_state, p) end
$$;

-- What Prism is given about one of its invoices: in the answer to each call, and in each callback.
create or replace function private.prism_invoice_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', pe.id, 'ref', pe.ref, 'partner_id', pe.partner_id, 'books', pe.books, 'type', pe.doc,
    'counta_org_id', pe.org_id, 'sale_id', case when pe.books then pe.doc_id end,
    'number', s.number, 'issue_date', s.issue_date, 'due_date', s.due_date, 'currency', coalesce(s.currency, 'NGN'),
    'subtotal', s.subtotal, 'vat', s.vat_total, 'total', s.total, 'paid', coalesce(s.status = 'paid', false), 'payment_waiting', pe.pay_pending is not null,
    'kind', d.kind, 'state', coalesce(d.state, 'not_sent'), 'irn', d.irn, 'qr', d.qr, 'signed_at', d.signed_at, 'note', d.note,
    'tries', coalesce(d.tries, 0), 'next_try_at', case when d.state in ('waiting', 'sending') then d.next_try_at end,
    'nrs_knows_paid', coalesce(d.pay_status, '') = 'PAID',
    'buyer', case when d.xm_state is null then null else jsonb_build_object('state', d.xm_state, 'note', d.xm_note, 'at', d.xm_at) end,
    'created_at', pe.created_at, 'updated_at', greatest(pe.updated_at, d.updated_at))
  from public.prism_einvoices pe
  left join public.einvoice_docs d on d.sale_id = pe.doc_id
  cross join lateral private.einvoice_doc_sale(pe.doc_id) s
  where pe.id = p_id
$$;

-- The holding account a partner's payments are booked to, named after the partner.
create or replace function private.prism_account(p_org uuid, p_partner text, p_name text, p_author uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; v_ref text := p_org::text || ':prism:' || p_partner;
begin
  select * into b from bank_accounts where org_id = p_org and provider = 'integration' and provider_ref = v_ref;
  if not found then
    b := private.open_bank_account(p_org, 'wallet', left(coalesce(p_name, 'Partner') || ' balance', 120),
      jsonb_build_object('provider', 'integration', 'provider_ref', v_ref, 'provider_meta', jsonb_build_object('prism_partner', p_partner)), p_author);
  elsif not b.active then
    update bank_accounts set active = true where id = b.id;
  end if;
  return b.id;
end $$;

-- A payment the partner reported, booked to its holding account: at most what is still owed.
create or replace function private.prism_pay(p_org uuid, p_partner text, p_name text, p_sale uuid, p_amount numeric, p_method text, p_ref text,
  p_at timestamptz, m public.members) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v_amt numeric; v_bank uuid;
begin
  select * into s from sales where id = p_sale for update;
  if s.status in ('draft', 'void', 'cancelled', 'pending') then return 0; end if;
  v_amt := round(least(coalesce(p_amount, s.total), s.total - s.amount_paid - s.credited), 2);
  if v_amt <= 0.004 then return 0; end if;
  v_bank := private.prism_account(p_org, p_partner, p_name, m.id);
  perform private.add_collection(p_org, s.customer_id, v_amt, case when p_method in ('cash', 'transfer', 'card', 'pos', 'cheque') then p_method else 'other' end,
    jsonb_build_object('bank_account_id', v_bank, 'provider_ref', 'prism:' || p_sale::text || ':' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'reference', left(coalesce(nullif(btrim(p_ref), ''), s.reference, s.number), 80), 'received_at', least(coalesce(p_at, now()), now()), 'spread', false,
      'note', 'Paid through ' || coalesce(p_name, 'a partner') || ' (Prism)'), m, 'confirmed', array[s.id]);
  update sales set settle_later = false where id = s.id and settle_later;
  return v_amt;
end $$;

-- The owner who records what comes through Prism (the contact Prism named, before they first sign in).
create or replace function private.prism_owner(p_org uuid) returns public.members
language sql stable security definer set search_path = public, private as $$
  select * from public.members where org_id = p_org and role = 'owner' and status <> 'disabled' order by (status = 'active') desc, created_at limit 1
$$;

-- ---------------------------------------------------------------------------
-- 3. The sending reads documents outside the books as it reads sales
-- ---------------------------------------------------------------------------
-- As before, and Prism's calls make the edge function send at once itself, so the database does not ask it too.
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
  if d.state = 'waiting' and coalesce(current_setting('counta.einvoice_kick', true), '') <> 'off' then
    perform private.call_function('einvoice', jsonb_build_object('action', 'send', 'sale_id', s.id));
  end if;
  return d;
end $$;

-- A sale's facts as before (a line a partner gave an HS code for, with no item, is goods with that code); a document
-- outside the books gives its own, with the seller and the codes as for a sale.
create or replace function private.einvoice_facts(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; o public.orgs; e public.einvoice_settings; c public.customers; b public.locations; orig public.sales; v_tz text;
  eo public.einvoice_only; oo public.einvoice_only; v_org uuid; v_seller jsonb; v_codes jsonb;
begin
  select * into s from sales where id = p_sale;
  if not found then
    select * into eo from einvoice_only where id = p_sale;
    if not found then return null; end if;
  end if;
  v_org := coalesce(s.org_id, eo.org_id);
  select * into o from orgs where id = v_org;
  select * into e from einvoice_settings where org_id = v_org;
  select * into b from locations where org_id = v_org order by is_main desc, created_at limit 1;
  v_tz := coalesce(o.timezone, 'Africa/Lagos');
  v_seller := jsonb_build_object('name', o.name, 'tin', o.tin, 'email', o.email, 'phone', o.phone, 'description', o.principal_activity, 'offering', o.offering,
    'street', coalesce(nullif(btrim(b.address), ''), o.address), 'city', b.city, 'postcode', b.postcode, 'state', b.state, 'lga', b.lga,
    'place', private.nrs_place(b.state, b.lga), 'service_code', e.service_code, 'service_label', private.nrs_label('services-codes', e.service_code));
  v_codes := jsonb_build_object(
    'invoice', coalesce((select code from nrs_codes where list = 'invoice-types' and lower(label) = 'commercial invoice' limit 1), '381'),
    'credit_note', coalesce((select code from nrs_codes where list = 'invoice-types' and lower(label) = 'credit note' limit 1), '380'));
  if eo.id is not null then
    select * into oo from einvoice_only where id = eo.original_id;
    return eo.facts || jsonb_build_object(
      'sale', coalesce(eo.facts->'sale', '{}'::jsonb) || jsonb_build_object('paid', eo.paid, 'amount_paid', case when eo.paid then eo.total else 0 end),
      'payments', case when eo.paid then coalesce(eo.facts->'payments', '[]'::jsonb) else '[]'::jsonb end,
      'org', v_seller, 'codes', v_codes,
      'original', case when oo.id is not null then jsonb_build_object('number', oo.number, 'issue_date', oo.issue_date,
        'irn', (select irn from einvoice_docs where sale_id = oo.id)) end);
  end if;
  select * into c from customers where id = s.customer_id;
  select * into orig from sales where id = s.original_sale_id;
  return jsonb_build_object(
    'sale', jsonb_build_object('id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'status', s.status, 'issue_date', s.issue_date,
      'issue_time', to_char(coalesce(s.issued_at, s.created_at) at time zone v_tz, 'HH24:MI:SS'), 'due_date', s.due_date, 'currency', s.currency,
      'subtotal', s.subtotal, 'discount_total', s.discount_total, 'vat_total', s.vat_total, 'delivery_fee', s.delivery_fee, 'total', s.total,
      'amount_paid', s.amount_paid, 'credited', s.credited, 'paid', s.status = 'paid' or (s.amount_paid + s.credited >= s.total - 0.004 and s.total > 0),
      'prices_include_vat', s.prices_include_vat, 'reference', s.reference, 'notes', s.notes, 'terms', s.terms, 'export', s.export,
      'customer_country', s.customer_country, 'channel', s.channel),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no,
        'kind', case when l.item_id is null and l.hs_code is not null then 'goods' else l.kind end, 'description', l.description, 'qty', l.qty, 'unit_label', l.unit_label,
        'unit_factor', l.unit_factor, 'unit_price', l.unit_price, 'discount', l.discount, 'vat_treatment', l.vat_treatment, 'vat_rate', l.vat_rate, 'net', l.net,
        'vat', l.vat, 'gross', l.gross, 'item_type', i.item_type, 'hs_code', coalesce(i.hs_code, l.hs_code), 'hs_label', private.nrs_label('hs-codes', coalesce(i.hs_code, l.hs_code)),
        'sku', coalesce(i.sku, i.barcode), 'item_name', i.name, 'item_description', i.description) order by l.line_no), '[]'::jsonb)
      from sale_lines l left join items i on i.id = l.item_id where l.sale_id = s.id),
    'org', v_seller,
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
    'codes', v_codes);
end $$;

-- As before, reading a document outside the books as a sale.
create or replace function public.svc_einvoice_claim(p_sale uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; e public.einvoice_settings; od public.einvoice_docs; v_svc text; v_no text; v_irn text; v_mode text;
  v_ref text;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  s := private.einvoice_doc_sale(p_sale);
  select * into e from einvoice_settings where org_id = d.org_id;
  v_mode := case when p_what = 'pay' then 'pay' when p_what = 'kick' and d.kind = 'report' then 'qr' else 'send' end;
  if v_mode = 'pay' then
    if d.state <> 'signed' or d.pay_due is null then return jsonb_build_object('skip', 'nothing to tell'); end if;
    update einvoice_docs set pay_next_at = now() + interval '10 minutes', updated_at = now() where sale_id = p_sale;
    select col.reference into v_ref from collection_allocations a join collections col on col.id = a.collection_id
      where a.sale_id = p_sale and col.status = 'confirmed' order by col.received_at desc limit 1;
    if v_ref is null and d.source = 'only' then select pay_reference into v_ref from einvoice_only where id = p_sale; end if;
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
      update einvoice_docs set next_try_at = now() + interval '5 minutes',
        note = 'Waiting for NRS to sign ' || coalesce((private.einvoice_doc_sale(s.original_sale_id)).number, 'the sale') || ' first.',
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

-- A payment Prism reported for an invoice to a business waited for NRS to sign it, and for the invoice to be issued.
create or replace function private.prism_after_signed(p_sale uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare pe public.prism_einvoices; m public.members;
begin
  select * into pe from prism_einvoices where doc_id = p_sale and books and pay_pending is not null for update;
  if not found then return; end if;
  if coalesce((select status from sales where id = p_sale), 'draft') in ('draft', 'void', 'cancelled', 'pending') then return; end if;
  m := private.prism_owner(pe.org_id);
  begin
    perform private.prism_pay(pe.org_id, pe.partner_id, pe.partner_name, p_sale, private.num(pe.pay_pending->>'amount'), pe.pay_pending->>'method',
      pe.pay_pending->>'reference', nullif(pe.pay_pending->>'paid_at', '')::timestamptz, m);
    update prism_einvoices set pay_pending = null, updated_at = now() where id = pe.id;
  exception when others then
    raise warning 'prism: the payment on % waits: %', p_sale, sqlerrm;
  end;
end $$;

-- As before, for documents outside the books too, and a payment that waited for the signature is booked.
create or replace function public.svc_einvoice_done(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; v_out text := p->>'outcome'; v_wait interval; v_state text;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'gone'); end if;
  s := private.einvoice_doc_sale(p_sale);
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
    perform private.prism_after_signed(p_sale);
    -- Paid while NRS was checking it: NRS hears of the payment next.
    if (private.einvoice_doc_sale(p_sale)).status = 'paid' and coalesce(nullif(p->>'pay_status', ''), '') <> 'PAID' then
      update einvoice_docs set pay_due = 'PAID', pay_next_at = now() where sale_id = p_sale;
    end if;
    v_state := 'signed';
  elsif v_out = 'refused' then
    update einvoice_docs set state = 'refused', sending_at = null, note = left(coalesce(nullif(p->>'note', ''), 'NRS refused it.'), 1000), answer = p->'answer', updated_at = now()
    where sale_id = p_sale;
    update sales set irn_status = 'refused' where id = p_sale;
    perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_refused', 'NRS refused ' || s.number, left(coalesce(nullif(p->>'note', ''), 'NRS refused it.'), 300),
      private.einvoice_doc_link(p_sale), 'einvoice_refused:' || p_sale);
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

-- As before; a notification about a document outside the books is kept against it.
create or replace function public.svc_einvoice_webhook(p_irn text, p_message text, p_body jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_irn text := left(btrim(coalesce(p_irn, '')), 100); v_msg text := upper(left(btrim(coalesce(p_message, '')), 40));
  d public.einvoice_docs; s public.sales; v_sale uuid; v_in uuid; v_matched text := 'none'; v_buyer uuid; v_new boolean := false;
begin
  if v_irn !~ '^[A-Za-z0-9][A-Za-z0-9-]{6,99}$' then
    insert into einvoice_webhooks (irn, message, body, matched) values (nullif(v_irn, ''), nullif(v_msg, ''), p_body, 'invalid');
    return jsonb_build_object('ok', true, 'matched', 'invalid');
  end if;
  -- A sale Counta sent.
  select * into d from einvoice_docs where irn = v_irn and state = 'signed' order by signed_at desc limit 1 for update;
  if found then
    v_sale := d.sale_id; v_matched := 'sale';
    update einvoice_docs set
      xm_state = case
        when v_msg = 'ACKNOWLEDGED' then 'acknowledged'
        when v_msg = 'TRANSMITTED' and coalesce(xm_state, '') <> 'acknowledged' then 'transmitted'
        when v_msg = 'TRANSMITTING' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged') then 'transmitting'
        when v_msg = 'FAILED' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged') then 'failed'
        else xm_state end,
      xm_note = case when v_msg = 'FAILED' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged')
        then 'NRS could not deliver it to the buyer''s access point.' when v_msg in ('TRANSMITTED', 'ACKNOWLEDGED') then null else xm_note end,
      xm_at = now(), updated_at = now()
    where sale_id = d.sale_id;
    if v_msg = 'FAILED' then
      s := private.einvoice_doc_sale(d.sale_id);
      perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_buyer', 'NRS could not deliver ' || s.number || ' to the buyer',
        case when d.source = 'only' then 'Open it under E-invoicing to see why and send it again.' else 'Open the sale to see why and send it again.' end,
        private.einvoice_doc_link(s.id), 'einvoice_buyer:' || s.id);
    end if;
  end if;
  -- An invoice to a Counta business: brought in, unless it is a sale Counta sent to a buyer outside Counta.
  if v_msg in ('TRANSMITTING', 'TRANSMITTED') then
    if v_sale is not null then
      s := private.einvoice_doc_sale(v_sale);
      v_buyer := private.einvoice_buyer_org(s.customer_tin);
    end if;
    if v_sale is null or (v_buyer is not null and v_buyer <> d.org_id) then
      -- One NRS notifies about again after it could not be read is tried again at once.
      v_new := exists (select 1 from einvoice_inbound where irn = v_irn and state = 'failed');
      insert into einvoice_inbound (irn, org_id, last_message) values (v_irn, v_buyer, v_msg)
      on conflict (irn) do update set last_message = excluded.last_message, updated_at = now(),
        state = case when einvoice_inbound.state = 'failed' then 'due' else einvoice_inbound.state end,
        next_at = case when einvoice_inbound.state = 'failed' then now() else einvoice_inbound.next_at end,
        tries = case when einvoice_inbound.state = 'failed' then 0 else einvoice_inbound.tries end
      returning id, (xmax = 0) or v_new into v_in, v_new;
      v_matched := case when v_matched = 'sale' then 'both' else 'inbound' end;
    end if;
  elsif v_msg = 'ACKNOWLEDGED' then
    update einvoice_inbound set last_message = v_msg, updated_at = now() where irn = v_irn returning id into v_in;
  end if;
  insert into einvoice_webhooks (irn, message, body, matched, sale_id, only_id, inbound_id)
  values (v_irn, nullif(v_msg, ''), p_body, v_matched, case when d.source = 'sale' then v_sale end, case when d.source = 'only' then v_sale end, v_in);
  return jsonb_build_object('ok', true, 'matched', v_matched, 'sale_id', v_sale, 'inbound_id', v_in, 'fetch', v_in is not null and v_new);
end $$;

-- As before, with Prism's callbacks to send.
create or replace function public.svc_einvoice_due(p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('sale_id', x.sale_id, 'id', x.id, 'org_id', x.org_id, 'what', x.what) order by x.at), '[]'::jsonb)
  from (select * from (
      select d.sale_id, null::uuid id, d.org_id, 'send'::text what, d.next_try_at at from einvoice_docs d
      where (d.state = 'waiting' and d.next_try_at <= now()) or (d.state = 'sending' and d.sending_at < now() - interval '5 minutes')
      union all
      select d.sale_id, null, d.org_id, 'pay', d.pay_next_at from einvoice_docs d where d.state = 'signed' and d.pay_due is not null and d.pay_next_at <= now()
      union all
      select d.sale_id, null, d.org_id, 'transmit', d.xm_next_at from einvoice_docs d
      where d.state = 'signed' and d.xm_state in ('due', 'sending') and d.xm_next_at <= now()
      union all
      select null, i.id, i.org_id, 'inbound', i.next_at from einvoice_inbound i
      where (i.state in ('due', 'billed') and i.next_at <= now()) or (i.state = 'fetching' and i.fetching_at < now() - interval '5 minutes')
      union all
      select null, c.id, c.org_id, 'callback', c.next_at from prism_callbacks c
      where (c.state = 'due' and c.next_at <= now()) or (c.state = 'sending' and c.sending_at < now() - interval '2 minutes')
    ) y order by y.at limit greatest(least(coalesce(p_limit, 100), 500), 1)) x
$$;

create or replace function public.svc_einvoice_xm_claim(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  if d.state <> 'signed' or d.xm_state is null or d.xm_state not in ('due', 'sending') then return jsonb_build_object('skip', coalesce(d.xm_state, 'not to send')); end if;
  if d.xm_state = 'sending' and d.xm_next_at > now() then return jsonb_build_object('skip', 'busy'); end if;
  s := private.einvoice_doc_sale(p_sale);
  update einvoice_docs set xm_state = 'sending', xm_tries = xm_tries + 1, xm_next_at = now() + interval '10 minutes', updated_at = now() where sale_id = p_sale;
  return jsonb_build_object('sale_id', p_sale, 'org_id', d.org_id, 'irn', d.irn, 'number', s.number, 'tries', d.xm_tries + 1,
    'buyer', s.customer_name, 'buyer_tin', s.customer_tin);
end $$;

create or replace function public.svc_einvoice_xm_done(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; v_out text := p->>'outcome'; v_note text := left(nullif(p->>'note', ''), 600); v_wait interval;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.xm_state is distinct from 'sending' then return jsonb_build_object('ok', false, 'state', d.xm_state); end if;
  s := private.einvoice_doc_sale(p_sale);
  if v_out = 'sent' then
    update einvoice_docs set xm_state = 'transmitting', xm_sent_at = now(), xm_note = null, xm_next_at = null, xm_at = now(), updated_at = now() where sale_id = p_sale;
  elsif v_out = 'wait' then
    update einvoice_docs set xm_state = 'due', xm_tries = greatest(xm_tries - 1, 0), xm_next_at = now() + interval '30 minutes', xm_note = v_note, updated_at = now()
    where sale_id = p_sale;
  elsif v_out = 'retry' and d.xm_tries < 6 then
    v_wait := case when d.xm_tries <= 1 then interval '1 minute' when d.xm_tries = 2 then interval '5 minutes' when d.xm_tries = 3 then interval '15 minutes'
                   when d.xm_tries = 4 then interval '30 minutes' else interval '1 hour' end;
    update einvoice_docs set xm_state = 'due', xm_next_at = now() + v_wait, xm_note = v_note, updated_at = now() where sale_id = p_sale;
  else
    update einvoice_docs set xm_state = 'failed', xm_next_at = null, xm_note = coalesce(v_note, 'NRS did not send it to the buyer.'), xm_at = now(), updated_at = now()
    where sale_id = p_sale;
    perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_buyer', 'NRS could not deliver ' || s.number || ' to the buyer',
      left(coalesce(v_note, case when d.source = 'only' then 'Open it under E-invoicing to see why and send it again.' else 'Open the sale to see why and send it again.' end), 300),
      private.einvoice_doc_link(p_sale), 'einvoice_buyer:' || p_sale);
  end if;
  return jsonb_build_object('ok', true, 'state', (select xm_state from einvoice_docs where sale_id = p_sale));
end $$;

-- What a document outside the books shows: the invoice as the partner sent it, and where it stands with NRS.
create or replace function private.einvoice_only_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', o.id, 'org_id', o.org_id, 'number', o.number, 'doc', o.doc, 'issue_date', o.issue_date, 'due_date', o.due_date,
    'currency', o.currency, 'customer_name', o.customer_name, 'customer_tin', o.customer_tin, 'customer_kind', o.customer_kind,
    'subtotal', o.subtotal, 'vat_total', o.vat_total, 'total', o.total, 'paid', o.paid, 'paid_at', o.paid_at, 'pay_reference', o.pay_reference,
    'partner_name', o.partner_name, 'ref', pe.ref, 'created_at', o.created_at,
    'original', (select jsonb_build_object('id', x.id, 'number', x.number) from einvoice_only x where x.id = o.original_id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'number', x.number, 'total', x.total) order by x.created_at), '[]'::jsonb)
      from einvoice_only x where x.original_id = o.id),
    'customer', o.facts->'customer', 'lines', coalesce(o.facts->'lines', '[]'::jsonb), 'notes', o.facts->'sale'->>'notes',
    'org', private.org_brand(o.org_id),
    'einvoice', (select jsonb_build_object('irn', e.irn, 'kind', e.kind, 'state', e.state, 'held', false, 'qr', e.qr, 'note', e.note, 'signed_at', e.signed_at,
        'tries', e.tries, 'next_try_at', e.next_try_at, 'pay_status', e.pay_status, 'platform_keys', e.platform_keys,
        'buyer', case when e.xm_state is null then null else jsonb_build_object('state', e.xm_state, 'note', e.xm_note, 'at', e.xm_at, 'sent_at', e.xm_sent_at,
          'tries', e.xm_tries, 'next_at', e.xm_next_at) end)
      from einvoice_docs e where e.sale_id = o.id))
  from einvoice_only o left join prism_einvoices pe on pe.doc_id = o.id
  where o.id = p_id
$$;

-- As before, for a document outside the books too.
create or replace function public.einvoice_send_to_buyer(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; d public.einvoice_docs;
begin
  s := private.einvoice_doc_sale(p_sale);
  if s.id is null then raise exception 'Sale not found.'; end if;
  perform private.require(s.org_id, 'record_sales');
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.state <> 'signed' or d.kind <> 'clear' then raise exception 'Only a sale NRS signed for a business or government buyer goes to the buyer.'; end if;
  if d.xm_state in ('due', 'sending') then raise exception '% is on its way to the buyer already.', s.number; end if;
  if d.xm_state in ('transmitted', 'acknowledged') then raise exception 'The buyer''s access point has % already.', s.number; end if;
  update einvoice_docs set xm_state = 'due', xm_tries = 0, xm_next_at = now(), xm_note = null, xm_at = now(), updated_at = now() where sale_id = p_sale;
  perform private.call_function('einvoice', jsonb_build_object('action', 'send'));
  if d.source = 'only' then return private.einvoice_only_json(p_sale); end if;
  return private.sale_json(p_sale, private.can_see_costs(s.org_id));
end $$;

-- As before; the documents outside the books are counted with the sales, and say which they are.
create or replace function private.einvoice_queue(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'waiting', (select count(*) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'oldest_at', (select min(created_at) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'signed_today', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed' and signed_at >= date_trunc('day', now())),
    'signed', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed'),
    'refused', (select count(*) from einvoice_docs where org_id = p_org and state = 'refused'),
    'pay_waiting', (select count(*) from einvoice_docs where org_id = p_org and pay_due is not null),
    'outside_books', (select count(*) from einvoice_docs where org_id = p_org and source = 'only'),
    'to_buyers', jsonb_build_object(
      'sending', (select count(*) from einvoice_docs where org_id = p_org and xm_state in ('due', 'sending', 'transmitting')),
      'delivered', (select count(*) from einvoice_docs where org_id = p_org and xm_state in ('transmitted', 'acknowledged')),
      'acknowledged', (select count(*) from einvoice_docs where org_id = p_org and xm_state = 'acknowledged'),
      'failed', (select count(*) from einvoice_docs where org_id = p_org and xm_state = 'failed')),
    'received', jsonb_build_object(
      'total', (select count(*) from einvoice_inbound where org_id = p_org and state in ('billed', 'confirmed')),
      'to_review', (select count(*) from einvoice_inbound i join supplier_invoices si on si.id = i.supplier_invoice_id
                    where i.org_id = p_org and si.status = 'review'),
      'failed', (select count(*) from einvoice_inbound where org_id = p_org and state = 'failed')),
    'attention', (select coalesce(jsonb_agg(y.x order by y.x->>'at' desc), '[]'::jsonb) from (
        select z.x from (
          select jsonb_build_object('sale_id', d.sale_id, 'source', d.source, 'number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
            'state', d.state, 'held', d.held, 'note', d.note, 'tries', d.tries, 'at', d.updated_at) x
          from einvoice_docs d cross join lateral private.einvoice_doc_sale(d.sale_id) s
          where d.org_id = p_org and (d.state = 'refused' or (d.state in ('waiting', 'sending') and (d.tries >= 3 or d.created_at < now() - interval '1 hour')))
          union all
          -- Signed, but NRS could not deliver it to the buyer.
          select jsonb_build_object('sale_id', d.sale_id, 'source', d.source, 'number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
            'state', 'not_delivered', 'held', false, 'note', d.xm_note, 'tries', d.xm_tries, 'at', d.xm_at)
          from einvoice_docs d cross join lateral private.einvoice_doc_sale(d.sale_id) s
          where d.org_id = p_org and d.xm_state = 'failed') z
        order by z.x->>'at' desc limit 20) y))
$$;

-- As before, and Prism's callbacks are sent when due.
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
             or (state = 'signed' and pay_due is not null and pay_next_at <= now())
             or (state = 'signed' and xm_state in ('due', 'sending') and xm_next_at <= now()))
     or exists (select 1 from einvoice_inbound where (state in ('due', 'billed') and next_at <= now()) or (state = 'fetching' and fetching_at < now() - interval '5 minutes'))
     or exists (select 1 from prism_callbacks where (state = 'due' and next_at <= now()) or (state = 'sending' and sending_at < now() - interval '2 minutes')) then
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
-- 4. Telling Prism
-- ---------------------------------------------------------------------------
create or replace function private.on_einvoice_doc_prism() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid;
begin
  select id into v_id from prism_einvoices where doc_id = new.sale_id;
  if v_id is null then return null; end if;
  if new.state is distinct from old.state and new.state in ('signed', 'refused', 'stopped') then
    insert into prism_callbacks (prism_id, org_id, change) values (v_id, new.org_id, new.state);
  end if;
  if new.xm_state is distinct from old.xm_state and new.xm_state in ('transmitted', 'acknowledged', 'failed') then
    insert into prism_callbacks (prism_id, org_id, change) values (v_id, new.org_id, 'buyer_' || new.xm_state);
  end if;
  if new.pay_status is distinct from old.pay_status and new.pay_status = 'PAID' and old.state = 'signed' then
    insert into prism_callbacks (prism_id, org_id, change) values (v_id, new.org_id, 'paid_reported');
  end if;
  return null;
end $$;
drop trigger if exists einvoice_docs_prism on public.einvoice_docs;
create trigger einvoice_docs_prism after update of state, xm_state, pay_status on public.einvoice_docs for each row execute function private.on_einvoice_doc_prism();

-- One callback to send: the body, made now, and the callback marked as being sent (for two minutes).
create or replace function public.svc_prism_callback_claim(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.prism_callbacks; pe public.prism_einvoices;
begin
  select * into c from prism_callbacks where id = p_id for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  if c.state not in ('due', 'sending') then return jsonb_build_object('skip', c.state); end if;
  if c.state = 'sending' and c.sending_at > now() - interval '2 minutes' then return jsonb_build_object('skip', 'busy'); end if;
  if c.state = 'due' and c.next_at > now() then return jsonb_build_object('skip', 'not yet'); end if;
  select * into pe from prism_einvoices where id = c.prism_id;
  update prism_callbacks set state = 'sending', sending_at = now(), tries = tries + 1 where id = p_id;
  return jsonb_build_object('id', c.id, 'tries', c.tries + 1, 'body', jsonb_build_object('event', 'einvoice.updated', 'id', c.id, 'change', c.change,
    'at', c.created_at, 'org_id', (select taxstreem_org_id from orgs where id = pe.org_id), 'partner_id', pe.partner_id, 'ref', pe.ref,
    'invoice', private.prism_invoice_json(pe.id)));
end $$;

-- outcome: sent (Prism answered 2xx), wait (no callback address yet: in an hour, uncounted), retry (tried again, a minute
-- then longer, for about a day; then failed).
create or replace function public.svc_prism_callback_done(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.prism_callbacks; v_out text := p->>'outcome'; v_wait interval;
begin
  select * into c from prism_callbacks where id = p_id for update;
  if not found or c.state <> 'sending' then return jsonb_build_object('ok', false, 'state', c.state); end if;
  if v_out = 'sent' then
    update prism_callbacks set state = 'sent', sent_at = now(), sending_at = null, last_status = nullif(p->>'status', '')::int, last_error = null where id = p_id;
  elsif v_out = 'wait' then
    update prism_callbacks set state = 'due', sending_at = null, tries = greatest(tries - 1, 0), next_at = now() + interval '1 hour',
      last_error = left(nullif(p->>'note', ''), 500) where id = p_id;
  elsif c.tries < 12 then
    v_wait := case when c.tries <= 1 then interval '1 minute' when c.tries = 2 then interval '5 minutes' when c.tries = 3 then interval '15 minutes'
                   when c.tries = 4 then interval '30 minutes' when c.tries = 5 then interval '1 hour' else interval '3 hours' end;
    update prism_callbacks set state = 'due', sending_at = null, next_at = now() + v_wait, last_status = nullif(p->>'status', '')::int,
      last_error = left(nullif(p->>'note', ''), 500) where id = p_id;
  else
    update prism_callbacks set state = 'failed', sending_at = null, last_status = nullif(p->>'status', '')::int, last_error = left(nullif(p->>'note', ''), 500) where id = p_id;
  end if;
  return jsonb_build_object('ok', true, 'state', (select state from prism_callbacks where id = p_id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. A merchant
-- ---------------------------------------------------------------------------
-- Made on Prism's first call, or found by its TaxStreem business id. A business Prism made takes what Prism sends; one
-- its owner set up only has its gaps filled. Its NRS Business ID and Service ID are kept here; the keys are wrapped by the
-- einvoice function and saved with svc_einvoice_keys_save. p: { merchant: {...}, nrs: { business_id, service_id } }.
create or replace function public.svc_prism_merchant(p_tsid text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_tsid text := btrim(coalesce(p_tsid, '')); x jsonb := coalesce(p->'merchant', '{}'::jsonb); n jsonb := coalesce(p->'nrs', '{}'::jsonb);
  a jsonb; ct jsonb; o public.orgs; b public.locations; s public.einvoice_settings; v_new boolean := false; v_mine boolean; v_set_new boolean := false;
  v_name text; v_email text; v_phone text; v_tin text; v_rc text; v_desc text; v_offer text; v_vat boolean; v_owner_email text; v_owner_name text;
  v_street text; v_city text; v_post text; v_state text; v_lga text; v_biz text; v_svc text; v_code text; v_changed boolean := false; v_x uuid;
begin
  if v_tsid !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$' then raise exception 'org_id must be the merchant''s TaxStreem business id.'; end if;
  if jsonb_typeof(x) <> 'object' then raise exception 'merchant must be an object.'; end if;
  if jsonb_typeof(n) <> 'object' then raise exception 'nrs must be an object.'; end if;
  a := case when jsonb_typeof(x->'address') = 'object' then x->'address' else '{}'::jsonb end;
  ct := case when jsonb_typeof(x->'contact') = 'object' then x->'contact' else '{}'::jsonb end;
  v_name := nullif(left(btrim(regexp_replace(coalesce(x->>'name', ''), '\s+', ' ', 'g')), 120), '');
  v_email := lower(nullif(btrim(coalesce(x->>'email', '')), ''));
  if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then raise exception 'merchant.email % is not an email address.', v_email; end if;
  v_phone := nullif(btrim(coalesce(x->>'phone', '')), '');
  v_tin := nullif(left(btrim(coalesce(x->>'tin', '')), 30), '');
  v_rc := nullif(left(btrim(coalesce(x->>'rc_number', '')), 30), '');
  v_desc := nullif(left(btrim(regexp_replace(coalesce(x->>'description', ''), '\s+', ' ', 'g')), 300), '');
  v_offer := lower(nullif(btrim(coalesce(x->>'offering', '')), ''));
  if v_offer is not null and v_offer not in ('goods', 'services', 'both') then raise exception 'merchant.offering must be goods, services or both.'; end if;
  if x ? 'vat_registered' then
    if jsonb_typeof(x->'vat_registered') <> 'boolean' then raise exception 'merchant.vat_registered must be true or false.'; end if;
    v_vat := (x->>'vat_registered')::boolean;
  end if;
  v_street := nullif(left(btrim(regexp_replace(coalesce(a->>'street', ''), '\s+', ' ', 'g')), 255), '');
  v_city := nullif(left(btrim(coalesce(a->>'city', '')), 80), '');
  v_post := nullif(btrim(coalesce(a->>'postcode', '')), '');
  if nullif(btrim(coalesce(a->>'state', '')), '') is not null then
    v_state := private.prism_state(a->>'state');
    if v_state is null then raise exception 'merchant.address.state % is not a Nigerian state.', a->>'state'; end if;
  end if;
  if nullif(btrim(coalesce(a->>'lga', '')), '') is not null then
    if v_state is null then raise exception 'merchant.address.state is needed with the LGA.'; end if;
    v_lga := private.prism_lga(v_state, a->>'lga');
    if v_lga is null then raise exception 'merchant.address.lga % is not a local government area of %.', a->>'lga', v_state; end if;
  end if;

  select * into o from orgs where taxstreem_org_id = v_tsid for update;
  if not found then
    if v_name is null then raise exception 'merchant.name is required the first time a merchant is sent.'; end if;
    v_owner_email := lower(nullif(btrim(coalesce(ct->>'email', x->>'email', '')), ''));
    if v_owner_email is null or v_owner_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then
      raise exception 'merchant.contact.email is required the first time: that person becomes the owner of the business in Counta when they first open it from TaxStreem.';
    end if;
    v_owner_name := coalesce(nullif(left(btrim(coalesce(ct->>'name', '')), 120), ''), split_part(v_owner_email, '@', 1));
    insert into orgs (name, email, phone, vat_registered, is_sample, taxstreem_org_id, prism_merchant)
    values (v_name, coalesce(v_email, v_owner_email), v_phone, coalesce(v_vat, true), false, v_tsid, true)
    returning * into o;
    insert into locations (org_id, name, code, is_main) values (o.id, 'Main store', 'MAIN', true);
    insert into members (org_id, user_id, email, display_name, phone, role, title, status,
      p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
    values (o.id, null, v_owner_email, v_owner_name, nullif(btrim(coalesce(ct->>'phone', '')), ''), 'owner', 'Owner', 'invited',
      true, true, true, true, true, true, true, true);
    v_new := true;
  end if;
  v_mine := o.prism_merchant;
  update orgs set
    name = case when v_mine and v_name is not null then v_name else name end,
    email = case when v_email is not null and (v_mine or nullif(btrim(coalesce(email, '')), '') is null) then v_email else email end,
    phone = case when v_phone is not null and (v_mine or nullif(btrim(coalesce(phone, '')), '') is null) then v_phone else phone end,
    tin = case when v_tin is not null and (v_mine or nullif(btrim(coalesce(tin, '')), '') is null) then v_tin else tin end,
    rc_number = case when v_rc is not null and (v_mine or nullif(btrim(coalesce(rc_number, '')), '') is null) then v_rc else rc_number end,
    principal_activity = case when v_desc is not null and (v_mine or principal_activity is null) then v_desc else principal_activity end,
    offering = case when v_offer is not null and (v_mine or offering is null) then v_offer else offering end,
    vat_registered = case when v_vat is not null and v_mine then v_vat else vat_registered end,
    address = case when v_street is not null and (v_mine or address is null) then left(v_street, 300) else address end
  where id = o.id
  returning * into o;
  -- The address NRS puts on every invoice is the main branch's.
  select * into b from locations where org_id = o.id order by is_main desc, created_at limit 1;
  update locations set
    address = case when v_street is not null and (v_mine or nullif(btrim(coalesce(address, '')), '') is null) then v_street else address end,
    city = case when v_city is not null and (v_mine or city is null) then v_city else city end,
    postcode = case when v_post is not null and (v_mine or postcode is null) then v_post else postcode end,
    state = case when v_state is not null and (v_mine or state is null) then v_state else state end,
    lga = case when v_state is not null and (v_mine or state is null) then coalesce(v_lga, case when state = v_state then lga end) else lga end
  where id = b.id;

  insert into einvoice_settings (org_id) values (o.id) on conflict (org_id) do nothing returning org_id into v_x;
  v_set_new := v_x is not null;
  select * into s from einvoice_settings where org_id = o.id for update;
  if nullif(btrim(coalesce(n->>'business_id', '')), '') is not null then
    v_biz := lower(btrim(n->>'business_id'));
    if v_biz !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'nrs.business_id is the Business ID on the merchant''s NRS dashboard, in five groups like 6dc03c76-1d83-4a39-a4de-51bd70547aef.';
    end if;
    if v_biz is distinct from s.business_id then update einvoice_settings set business_id = v_biz where org_id = o.id; v_changed := true; end if;
  end if;
  if nullif(btrim(coalesce(n->>'service_id', '')), '') is not null then
    v_svc := upper(regexp_replace(n->>'service_id', '\s', '', 'g'));
    if v_svc !~ '^[A-Z0-9]{8}$' then raise exception 'nrs.service_id is the 8 letters and numbers NRS gave the merchant, like 94ND90NR.'; end if;
    if v_svc is distinct from s.service_id then update einvoice_settings set service_id = v_svc where org_id = o.id; v_changed := true; end if;
  end if;
  if v_changed and not s.platform_keys then
    update einvoice_settings set keys_version = keys_version + 1, enabled = false where org_id = o.id;
  end if;
  if nullif(btrim(coalesce(x->>'service_code', '')), '') is not null then
    v_code := regexp_replace(x->>'service_code', '[^0-9]', '', 'g');
    if v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code) then
      raise exception 'merchant.service_code % is not on NRS''s list of service codes.', x->>'service_code';
    end if;
    update einvoice_settings set service_code = v_code, service_checked_at = now(), service_review = false,
      service_basis = jsonb_build_object('source', 'manual', 'code', v_code, 'by', 'Prism', 'at', now())
    where org_id = o.id;
  end if;
  update einvoice_settings set updated_at = now() where org_id = o.id;
  -- Gemini chooses the service code when Prism did not send one.
  if v_set_new and nullif(btrim(coalesce(x->>'service_code', '')), '') is null then
    perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending'));
  end if;
  select * into s from einvoice_settings where org_id = o.id;
  return jsonb_build_object('org_id', o.id, 'created', v_new, 'name', o.name, 'prism_merchant', o.prism_merchant, 'platform_keys', s.platform_keys,
    'check_current', coalesce(s.check_version = s.keys_version, false));
end $$;

-- E-invoicing switched on once everything NRS needs is in place, for a business Prism made or one that never had it on (a
-- business whose owner switched it off stays off). Says what is still missing, by the readiness ids.
create or replace function public.svc_prism_enable(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.einvoice_settings; o public.orgs; v_missing jsonb;
begin
  select * into o from orgs where id = p_org;
  select * into s from einvoice_settings where org_id = p_org for update;
  if not found then
    return jsonb_build_object('enabled', false, 'switched_off', false, 'missing', jsonb_build_array(jsonb_build_object('id', 'start', 'title', 'E-invoicing', 'detail', 'E-invoicing is not set up.')));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r->>'id', 'title', r->>'title', 'detail', r->>'detail')), '[]'::jsonb) into v_missing
  from jsonb_array_elements(private.einvoice_readiness(p_org)) r where (r->>'blocking')::boolean and not (r->>'ok')::boolean;
  if not s.enabled and jsonb_array_length(v_missing) = 0 and (o.prism_merchant or s.enabled_at is null) then
    update einvoice_settings set enabled = true, enabled_at = now(), updated_at = now() where org_id = p_org;
    s.enabled := true;
  end if;
  return jsonb_build_object('enabled', s.enabled, 'platform_keys', s.platform_keys, 'missing', v_missing,
    'switched_off', not s.enabled and s.enabled_at is not null and not o.prism_merchant,
    'keys', jsonb_build_object('api_key', s.api_key_hint, 'api_secret', s.api_secret_hint, 'crypto_keys', s.crypto_hint),
    'check', case when s.checked_at is null then null else jsonb_build_object('ok', coalesce(s.check_ok and s.check_version = s.keys_version, false),
      'note', s.check_note, 'at', s.checked_at) end);
end $$;

-- ---------------------------------------------------------------------------
-- 6. An invoice
-- ---------------------------------------------------------------------------
-- An invoice NRS refused may be sent again, corrected: e-invoicing only, or in the books while it is still a draft (an
-- invoice to a business waits as a draft until NRS signs it).
create or replace function private.prism_resubmittable(p_id uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from public.prism_einvoices pe join public.einvoice_docs d on d.sale_id = pe.doc_id
    where pe.id = p_id and d.state = 'refused'
      and (not pe.books or (d.held and exists (select 1 from public.sales s where s.id = pe.doc_id and s.status = 'draft' and s.journal_id is null))))
$$;

-- p_partner: { id, name, books }. p_inv: the invoice in Prism's simple format (docs/prism-einvoicing.md). Answers
-- { duplicate, resubmitted, kick, invoice }: kick is the document the einvoice function sends to NRS straight away.
create or replace function public.svc_prism_einvoice(p_org uuid, p_partner jsonb, p_inv jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v_pid text := btrim(coalesce(p_partner->>'id', ''));
  v_pname text := nullif(left(btrim(regexp_replace(coalesce(p_partner->>'name', ''), '\s+', ' ', 'g')), 120), '');
  v_books boolean; v_ref text := btrim(coalesce(p_inv->>'ref', '')); v_type text := lower(coalesce(nullif(btrim(p_inv->>'type'), ''), 'invoice'));
  pe public.prism_einvoices; po public.prism_einvoices; o public.orgs; st public.einvoice_settings; v_en jsonb; m public.members; s public.sales;
  it public.items; cu jsonb; ca jsonb; x jsonb; v_paid jsonb; v_pending jsonb; v_facts jsonb; v_cust jsonb;
  v_kind text; v_cname text; v_ctin text; v_cemail text; v_cphone text; v_cstreet text; v_ccity text; v_cpost text; v_cstate text; v_clga text; v_country text;
  v_today date; v_day date; v_due date; v_incl boolean; v_rate numeric; v_notes text; v_no text; v_tz text;
  v_i int := 0; v_desc text; v_q numeric; v_p numeric; v_dsc numeric; v_treat text; v_hs text; v_lkind text; v_sku text; v_unit text; v_lrate numeric;
  v_base numeric; v_net numeric; v_vat numeric; v_gross numeric; v_net_t numeric := 0; v_vat_t numeric := 0; v_total numeric;
  v_lines jsonb := '[]'::jsonb; v_sale_lines jsonb := '[]'::jsonb; v_up numeric;
  v_pamt numeric; v_pmethod text; v_pref text; v_pat timestamptz; v_full boolean := false;
  v_cid uuid; v_held boolean; v_route text; v_id uuid; v_orig uuid; v_oref text; v_resub boolean := false;
begin
  -- Prism's own edge call sends the invoice to NRS itself, at once.
  perform set_config('counta.einvoice_kick', 'off', true);
  if v_pid !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$' then raise exception 'partner.id must be Prism''s id for the partner: letters, digits and . _ : -, up to 80.'; end if;
  if jsonb_typeof(p_partner->'books') is distinct from 'boolean' then
    raise exception 'partner.books must be true (the invoice goes in the merchant''s books) or false (e-invoicing only).';
  end if;
  v_books := (p_partner->>'books')::boolean;
  if jsonb_typeof(p_inv) is distinct from 'object' then raise exception 'invoice must be an object.'; end if;
  if v_ref = '' or length(v_ref) > 100 then raise exception 'invoice.ref is required: the partner''s own id for the invoice, up to 100 characters.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || '|' || v_pid || '|' || v_ref, 0));
  select * into pe from prism_einvoices where org_id = p_org and partner_id = v_pid and ref = v_ref for update;
  if found then
    -- Sent again: the same invoice, or one NRS refused, corrected.
    if pe.body = p_inv or not private.prism_resubmittable(pe.id) then
      return jsonb_build_object('duplicate', true, 'resubmitted', false, 'kick', null, 'invoice', private.prism_invoice_json(pe.id));
    end if;
    if pe.books is distinct from v_books then
      raise exception 'invoice % went %; a corrected one goes the same way.', v_ref, case when pe.books then 'in the merchant''s books' else 'as e-invoicing only' end;
    end if;
    if pe.doc is distinct from v_type then raise exception 'invoice % was sent as a %; a corrected one is the same type.', v_ref, replace(pe.doc, '_', ' '); end if;
    v_resub := true;
  end if;

  select * into o from orgs where id = p_org;
  v_tz := coalesce(o.timezone, 'Africa/Lagos');
  if v_type not in ('invoice', 'receipt', 'credit_note') then raise exception 'invoice.type must be invoice, receipt or credit_note.'; end if;
  if v_type = 'credit_note' and v_books then
    raise exception 'Through Prism, credit notes are for e-invoicing only for now. For a merchant whose books are in Counta, the credit note is raised in Counta, from the sale.';
  end if;
  if upper(coalesce(nullif(btrim(p_inv->>'currency'), ''), 'NGN')) <> 'NGN' then raise exception 'Only naira (NGN) invoices go through Prism for now.'; end if;
  v_today := private.local_day(p_org, now());
  begin
    v_day := coalesce(nullif(btrim(coalesce(p_inv->>'issue_date', '')), '')::date, v_today);
    v_due := nullif(btrim(coalesce(p_inv->>'due_date', '')), '')::date;
  exception when others then
    raise exception 'invoice.issue_date and invoice.due_date are dates, like 2026-11-14.';
  end;
  if v_day > v_today then raise exception 'invoice.issue_date cannot be in the future.'; end if;
  if v_day < v_today - 366 then raise exception 'invoice.issue_date is more than a year ago.'; end if;
  if v_due is not null and v_due < v_day then raise exception 'invoice.due_date is before invoice.issue_date.'; end if;
  if v_type = 'receipt' then v_due := null; end if;
  v_incl := case when jsonb_typeof(p_inv->'prices_include_vat') = 'boolean' then (p_inv->>'prices_include_vat')::boolean else false end;
  v_rate := case when o.vat_registered then private.vat_rate(v_day) else 0 end;
  v_notes := nullif(left(btrim(coalesce(p_inv->>'notes', '')), 400), '');

  -- The buyer.
  cu := coalesce(p_inv->'customer', '{}'::jsonb);
  if jsonb_typeof(cu) <> 'object' then raise exception 'invoice.customer must be an object.'; end if;
  ca := case when jsonb_typeof(cu->'address') = 'object' then cu->'address' else '{}'::jsonb end;
  v_cname := nullif(left(btrim(regexp_replace(coalesce(cu->>'name', ''), '\s+', ' ', 'g')), 120), '');
  v_ctin := nullif(left(btrim(coalesce(cu->>'tin', '')), 30), '');
  v_kind := lower(coalesce(nullif(btrim(cu->>'kind'), ''), case when v_ctin is not null then 'business' else 'individual' end));
  if v_kind not in ('individual', 'business', 'government') then raise exception 'invoice.customer.kind must be individual, business or government.'; end if;
  v_country := upper(coalesce(nullif(btrim(coalesce(ca->>'country', '')), ''), nullif(btrim(coalesce(cu->>'country', '')), ''), 'NG'));
  if v_country !~ '^[A-Z]{2}$' then raise exception 'invoice.customer.address.country is a two-letter country code, like NG.'; end if;
  if v_kind in ('business', 'government') and v_cname is null then raise exception 'invoice.customer.name is required for a business or government buyer.'; end if;
  if v_kind in ('business', 'government') and v_country = 'NG' and v_ctin is null then
    raise exception 'invoice.customer.tin is required: NRS checks invoices to businesses and government against the buyer''s Tax ID.';
  end if;
  if v_type = 'invoice' and v_cname is null then raise exception 'invoice.customer.name is required on an invoice. A sale to someone unnamed is sent as a receipt.'; end if;
  if v_type = 'credit_note' and v_cname is null then raise exception 'invoice.customer.name is required on a credit note.'; end if;
  v_cemail := lower(nullif(btrim(coalesce(cu->>'email', '')), ''));
  if v_cemail is not null and v_cemail !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then raise exception 'invoice.customer.email % is not an email address.', v_cemail; end if;
  v_cphone := private.clean_phone(cu->>'phone');
  v_cstreet := nullif(left(btrim(regexp_replace(coalesce(ca->>'street', ''), '\s+', ' ', 'g')), 255), '');
  v_ccity := nullif(left(btrim(coalesce(ca->>'city', '')), 80), '');
  v_cpost := nullif(replace(btrim(coalesce(ca->>'postcode', '')), ' ', ''), '');
  if v_country = 'NG' then
    if v_cpost is not null and v_cpost !~ '^[0-9]{6}$' then raise exception 'invoice.customer.address.postcode: a Nigerian postcode has 6 digits.'; end if;
    if nullif(btrim(coalesce(ca->>'state', '')), '') is not null then
      v_cstate := private.prism_state(ca->>'state');
      if v_cstate is null then raise exception 'invoice.customer.address.state % is not a Nigerian state.', ca->>'state'; end if;
      if nullif(btrim(coalesce(ca->>'lga', '')), '') is not null then
        v_clga := private.prism_lga(v_cstate, ca->>'lga');
        if v_clga is null then raise exception 'invoice.customer.address.lga % is not a local government area of %.', ca->>'lga', v_cstate; end if;
      end if;
    end if;
  else
    v_cstate := nullif(left(btrim(coalesce(ca->>'state', '')), 80), '');
  end if;

  -- The lines, worked out as Counta works out a sale's: VAT at the merchant's rate, on the price before or with VAT.
  if jsonb_typeof(p_inv->'lines') is distinct from 'array' or jsonb_array_length(p_inv->'lines') = 0 then raise exception 'invoice.lines needs at least one line.'; end if;
  if jsonb_array_length(p_inv->'lines') > 300 then raise exception 'invoice.lines can have up to 300 lines.'; end if;
  for x in select value from jsonb_array_elements(p_inv->'lines') loop
    v_i := v_i + 1;
    if jsonb_typeof(x) <> 'object' then raise exception 'Line % is not an object.', v_i; end if;
    v_desc := nullif(left(btrim(regexp_replace(coalesce(x->>'description', x->>'name', ''), '\s+', ' ', 'g')), 300), '');
    if v_desc is null then raise exception 'Line %: description is required.', v_i; end if;
    v_q := round(private.num(x->>'qty'), 3);
    if coalesce(v_q, 0) <= 0 then raise exception 'Line % (%): qty must be above zero.', v_i, v_desc; end if;
    v_p := round(private.num(x->>'unit_price'), 2);
    if v_p is null or v_p < 0 then raise exception 'Line % (%): unit_price is required, and not below zero.', v_i, v_desc; end if;
    v_dsc := round(coalesce(private.num(x->>'discount'), 0), 2);
    if v_dsc < 0 or v_dsc > round(v_q * v_p, 2) then raise exception 'Line % (%): discount must be between zero and the line''s amount.', v_i, v_desc; end if;
    v_treat := lower(coalesce(nullif(btrim(coalesce(x->>'vat', '')), ''), nullif(btrim(coalesce(x->>'vat_treatment', '')), ''), 'standard'));
    if v_treat not in ('standard', 'zero', 'exempt') then raise exception 'Line % (%): vat must be standard, zero or exempt.', v_i, v_desc; end if;
    v_hs := case when nullif(btrim(coalesce(x->>'hs_code', '')), '') is not null then private.hs_code(x->>'hs_code') end;
    if nullif(btrim(coalesce(x->>'hs_code', '')), '') is not null and v_hs is null then
      raise exception 'Line % (%): hs_code % is not an HS code (at least six digits, like 1902.30).', v_i, v_desc, x->>'hs_code';
    end if;
    v_lkind := lower(coalesce(nullif(btrim(coalesce(x->>'kind', '')), ''), case when v_hs is not null then 'goods' else 'service' end));
    if v_lkind not in ('goods', 'service') then raise exception 'Line % (%): kind must be goods or service.', v_i, v_desc; end if;
    v_sku := nullif(left(btrim(coalesce(x->>'sku', '')), 100), '');
    v_unit := nullif(left(btrim(coalesce(x->>'unit', x->>'unit_label', '')), 30), '');
    it := null;
    if v_books and v_sku is not null then
      select * into it from items where org_id = p_org and not archived and (lower(sku) = lower(v_sku) or barcode = v_sku) order by created_at limit 1;
    end if;
    -- An item of the merchant's keeps its own VAT treatment and HS code.
    if it.id is not null then
      v_treat := coalesce(it.vat_treatment, v_treat);
      v_lkind := 'goods';
    end if;
    if v_lkind = 'goods' then
      if coalesce(it.hs_code, v_hs) is null then
        raise exception 'Line % (%): goods need hs_code, the HS code from NRS''s list%.', v_i, v_desc,
          case when v_books then ', or the sku of one of the merchant''s items that has an HS code' else '' end;
      end if;
      if it.hs_code is null and not private.nrs_code_ok('hs-codes', v_hs) then
        raise exception 'Line % (%): % is not on NRS''s list of HS codes.', v_i, v_desc, v_hs;
      end if;
    else
      v_hs := null;
    end if;
    v_lrate := case when v_treat = 'standard' then v_rate else 0 end;
    v_base := round(v_q * v_p, 2) - v_dsc;
    if v_incl then v_gross := v_base; v_net := round(v_gross / (1 + v_lrate), 2); v_vat := v_gross - v_net;
    else v_net := v_base; v_vat := round(v_net * v_lrate, 2); v_gross := v_net + v_vat; end if;
    v_net_t := v_net_t + v_net; v_vat_t := v_vat_t + v_vat;
    v_lines := v_lines || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('line_no', v_i, 'kind', v_lkind, 'description', v_desc, 'qty', v_q,
      'unit_label', coalesce(v_unit, 'unit'), 'unit_factor', 1, 'unit_price', v_p, 'discount', v_dsc, 'vat_treatment', v_treat, 'vat_rate', v_lrate,
      'net', v_net, 'vat', v_vat, 'gross', v_gross, 'hs_code', coalesce(it.hs_code, v_hs), 'hs_label', private.nrs_label('hs-codes', coalesce(it.hs_code, v_hs)),
      'sku', v_sku, 'item_name', v_desc, 'item_description', nullif(left(btrim(coalesce(x->>'item_description', '')), 255), ''))));
    if v_books then
      -- A receipt takes prices the way the merchant records them; an invoice says which way they are.
      v_up := v_p;
      if v_type = 'receipt' and o.prices_include_vat is distinct from v_incl and v_lrate > 0 then
        v_up := case when v_incl then round(v_p / (1 + v_lrate), 2) else round(v_p * (1 + v_lrate), 2) end;
      end if;
      v_sale_lines := v_sale_lines || jsonb_build_array(case when it.id is not null
        then jsonb_build_object('item_id', it.id, 'qty', v_q, 'unit_price', v_up, 'discount', v_dsc, 'line_hs', case when it.hs_code is null then v_hs end)
        else jsonb_strip_nulls(jsonb_build_object('description', v_desc, 'qty', v_q, 'unit_price', v_up, 'discount', v_dsc, 'vat_treatment', v_treat,
          'unit_label', v_unit, 'line_hs', v_hs)) end);
    end if;
  end loop;
  v_total := v_net_t + v_vat_t;
  if v_total <= 0 then raise exception 'The invoice total must be above zero.'; end if;
  if p_inv ? 'total' and private.num(p_inv->>'total') is not null and abs(private.num(p_inv->>'total') - v_total) > 1 then
    raise exception 'invoice.total is % but the lines come to % with VAT at the merchant''s rate.', to_char(private.num(p_inv->>'total'), 'FM999,999,999,990.00'),
      to_char(v_total, 'FM999,999,999,990.00');
  end if;

  -- What was paid. A receipt is paid in full.
  v_paid := case when jsonb_typeof(p_inv->'paid') = 'object' then p_inv->'paid' when v_type = 'receipt' then '{}'::jsonb end;
  if v_paid is not null then
    if v_type = 'credit_note' then raise exception 'A credit note is not paid: leave out invoice.paid.'; end if;
    v_pamt := round(coalesce(private.num(v_paid->>'amount'), v_total), 2);
    if v_pamt <= 0 or v_pamt > v_total + 0.004 then raise exception 'invoice.paid.amount must be above zero and no more than the total (%).', to_char(v_total, 'FM999,999,999,990.00'); end if;
    if v_type = 'receipt' and v_pamt < v_total - 0.004 then raise exception 'A receipt is paid in full. Send a part payment as an invoice with paid.amount.'; end if;
    v_pmethod := lower(coalesce(nullif(btrim(coalesce(v_paid->>'method', '')), ''), 'other'));
    if v_pmethod not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other') then raise exception 'invoice.paid.method must be cash, transfer, card, pos, cheque or other.'; end if;
    v_pref := nullif(left(btrim(coalesce(v_paid->>'reference', '')), 80), '');
    begin
      v_pat := least(coalesce(nullif(btrim(coalesce(v_paid->>'paid_at', '')), '')::timestamptz, now()), now());
    exception when others then raise exception 'invoice.paid.paid_at is a time, like 2026-11-14T10:30:00+01:00.';
    end;
    v_full := v_pamt >= v_total - 0.004;
  end if;

  -- E-invoicing must be on for the merchant (switched on here once it can be).
  select * into st from einvoice_settings where org_id = p_org;
  if not coalesce(st.enabled, false) then
    v_en := public.svc_prism_enable(p_org);
    if not (v_en->>'enabled')::boolean then
      raise exception '%', case when (v_en->>'switched_off')::boolean then 'The merchant has switched e-invoicing off in Counta.'
        else 'E-invoicing is not on for this merchant yet. ' || coalesce((select string_agg(r->>'detail', ' ') from jsonb_array_elements(v_en->'missing') r), 'It is not set up.') end
        using errcode = 'PX409';
    end if;
  end if;

  v_cust := jsonb_build_object('kind', v_kind, 'walk_in', v_cname is null, 'name', coalesce(v_cname, 'Customer'), 'tin', v_ctin, 'email', v_cemail, 'phone', v_cphone,
    'street', v_cstreet, 'city', v_ccity, 'postcode', v_cpost, 'state', v_cstate, 'lga', v_clga, 'country', v_country, 'place', private.nrs_place(v_cstate, v_clga));
  v_route := case when v_kind in ('business', 'government') then 'clear' else 'report' end;

  if not v_books then
    -- ------------------------------------------------------------ e-invoicing only
    if v_type = 'credit_note' then
      v_oref := btrim(coalesce(p_inv->>'original_ref', ''));
      if v_oref = '' then raise exception 'A credit note needs original_ref: the ref of the invoice it corrects.'; end if;
      select * into po from prism_einvoices where org_id = p_org and partner_id = v_pid and ref = v_oref;
      if not found or po.books or po.doc = 'credit_note' then raise exception 'original_ref % is not an e-invoicing-only invoice this partner sent for the merchant.', v_oref; end if;
      v_orig := po.doc_id;
      if v_total > (select total from einvoice_only where id = v_orig) - coalesce((select sum(total) from einvoice_only where original_id = v_orig and id is distinct from pe.doc_id), 0) + 0.004 then
        raise exception 'The credit notes on % would come to more than it.', v_oref;
      end if;
    end if;
    v_no := left(regexp_replace(coalesce(nullif(btrim(coalesce(p_inv->>'number', '')), ''), v_ref), '[^A-Za-z0-9]', '', 'g'), 40);
    if v_no = '' then raise exception 'invoice.number (or invoice.ref) needs letters or digits: they go in the IRN.'; end if;
    -- The IRN is the number and the day: the merchant may not use the number twice on a day, nor one of its own Counta numbers.
    if exists (select 1 from einvoice_only where org_id = p_org and number = v_no and issue_date = v_day and id is distinct from pe.doc_id)
       or exists (select 1 from sales where org_id = p_org and issue_date = v_day and regexp_replace(number, '[^A-Za-z0-9]', '', 'g') = v_no) then
      raise exception 'Invoice number % is already used by the merchant on %. Send another number.', v_no, v_day using errcode = 'PX409';
    end if;
    v_id := coalesce(pe.doc_id, gen_random_uuid());
    v_facts := jsonb_build_object(
      'sale', jsonb_build_object('id', v_id, 'number', v_no, 'doc_type', v_type, 'status', 'open', 'issue_date', v_day,
        'issue_time', to_char(now() at time zone v_tz, 'HH24:MI:SS'), 'due_date', v_due, 'currency', 'NGN', 'subtotal', v_net_t, 'discount_total', 0,
        'vat_total', v_vat_t, 'delivery_fee', 0, 'total', v_total, 'amount_paid', 0, 'credited', 0, 'paid', false, 'prices_include_vat', v_incl,
        'reference', left(v_ref, 100), 'notes', v_notes, 'terms', null, 'export', false, 'customer_country', v_country, 'channel', 'api'),
      'lines', v_lines, 'customer', v_cust,
      'payments', case when v_paid is not null then jsonb_build_array(v_pmethod) else '[]'::jsonb end);
    if not v_resub then
      insert into einvoice_only (id, org_id, partner_name, number, doc, issue_date, due_date, currency, customer_name, customer_tin, customer_kind,
        subtotal, vat_total, total, paid, paid_at, pay_reference, original_id, facts)
      values (v_id, p_org, v_pname, v_no, v_type, v_day, v_due, 'NGN', v_cname, v_ctin, v_kind, v_net_t, v_vat_t, v_total, v_full,
        case when v_full then v_pat end, v_pref, v_orig, v_facts);
      insert into einvoice_docs (sale_id, org_id, kind, doc, source, state, held) values (v_id, p_org, v_route, v_type, 'only', 'waiting', false);
      insert into prism_einvoices (org_id, partner_id, partner_name, ref, books, doc_id, doc, body)
      values (p_org, v_pid, v_pname, v_ref, false, v_id, v_type, p_inv) returning * into pe;
    else
      update einvoice_only set partner_name = coalesce(v_pname, partner_name), number = v_no, issue_date = v_day, due_date = v_due, customer_name = v_cname,
        customer_tin = v_ctin, customer_kind = v_kind, subtotal = v_net_t, vat_total = v_vat_t, total = v_total, paid = v_full,
        paid_at = case when v_full then v_pat end, pay_reference = v_pref, original_id = v_orig, facts = v_facts, updated_at = now()
      where id = v_id;
      update einvoice_docs set kind = v_route, state = 'waiting', tries = 0, next_try_at = now(), sending_at = null, irn = null, qr = null, qr_at = null,
        note = null, answer = null, alerted = 0, updated_at = now()
      where sale_id = v_id;
      update prism_einvoices set body = p_inv, partner_name = coalesce(v_pname, partner_name), updated_at = now() where id = pe.id returning * into pe;
    end if;
  else
    -- ------------------------------------------------------------ in the merchant's books
    m := private.prism_owner(p_org);
    if m.id is null then raise exception 'The merchant has no owner in Counta.'; end if;
    v_held := v_type = 'invoice' and v_route = 'clear';
    -- The buyer: one the merchant has (by Tax ID, or by email or phone), else a new customer; what the partner says now is kept on it.
    if v_cname is not null then
      select id into v_cid from customers where org_id = p_org and not archived and not is_walk_in and (
          (v_ctin is not null and length(regexp_replace(v_ctin, '[^0-9]', '', 'g')) >= 8
            and regexp_replace(coalesce(tin, ''), '[^0-9]', '', 'g') = regexp_replace(v_ctin, '[^0-9]', '', 'g'))
          or (v_ctin is null and ((v_cemail is not null and lower(email) = v_cemail) or (v_cphone is not null and phone = v_cphone))))
      order by created_at limit 1;
      if v_cid is null then
        v_cid := private.upsert_customer(p_org, jsonb_strip_nulls(jsonb_build_object('name', v_cname, 'kind', v_kind, 'tin', v_ctin, 'email', v_cemail,
          'phone', case when v_cphone is not null and not exists (select 1 from customers where org_id = p_org and phone = v_cphone and not archived) then v_cphone end,
          'address', v_cstreet, 'city', v_ccity, 'country', v_country)), m);
      end if;
      update customers set kind = v_kind, tin = coalesce(v_ctin, tin), email = coalesce(v_cemail, email), address = coalesce(v_cstreet, address),
        city = coalesce(v_ccity, city), country = v_country, postcode = coalesce(v_cpost, postcode),
        state = case when v_cstate is not null then v_cstate else state end, lga = case when v_cstate is not null then v_clga else lga end
      where id = v_cid;
    end if;
    if not v_resub then
      if v_held then perform private.require_open_day(p_org, v_day); end if;
      s := private.create_sale(p_org, jsonb_strip_nulls(jsonb_build_object(
        'doc_type', case when v_type = 'receipt' then 'receipt' else 'invoice' end, 'status', case when v_held then 'draft' else 'issue' end,
        'channel', 'api', 'customer_id', v_cid, 'issue_date', v_day, 'due_date', v_due, 'prices_include_vat', v_incl,
        'reference', left(coalesce(nullif(btrim(coalesce(p_inv->>'number', '')), ''), v_ref), 80),
        'notes', left(coalesce(v_pname, 'A partner') || ' through Prism · ' || v_ref || coalesce(' · ' || v_notes, ''), 500),
        'pay_in_full', case when v_type = 'receipt' then 'later' end, 'lines', v_sale_lines)), m);
    else
      select * into s from sales where id = pe.doc_id for update;
      update sales set customer_id = coalesce(v_cid, customer_id), issue_date = v_day, due_date = coalesce(v_due, due_date), prices_include_vat = v_incl,
        reference = left(coalesce(nullif(btrim(coalesce(p_inv->>'number', '')), ''), v_ref), 80)
      where id = s.id returning * into s;
      s := private.write_lines(s, v_sale_lines, 0, m);
    end if;
    -- The invoice carries the buyer as the partner sent it.
    update sales set customer_name = coalesce(v_cname, customer_name), customer_tin = coalesce(v_ctin, customer_tin), customer_email = coalesce(v_cemail, customer_email),
      customer_phone = coalesce(v_cphone, customer_phone), customer_address = coalesce(v_cstreet, customer_address)
    where id = s.id and v_cname is not null;
    -- An HS code the partner gave for a line that is not one of the merchant's items (or for an item without one).
    v_i := 0;
    for x in select value from jsonb_array_elements(v_sale_lines) loop
      v_i := v_i + 1;
      if nullif(x->>'line_hs', '') is not null then update sale_lines set hs_code = x->>'line_hs' where sale_id = s.id and line_no = v_i; end if;
    end loop;
    select * into s from sales where id = s.id;
    if abs(s.total - v_total) > 1 then
      raise exception 'Counta works this invoice out at %, not %: check the prices and the VAT on each line.', to_char(s.total, 'FM999,999,999,990.00'),
        to_char(v_total, 'FM999,999,999,990.00');
    end if;
    if v_held then
      perform private.einvoice_open(s.id, 'clear', true, m.id);
    end if;
    v_pending := case when v_paid is not null then jsonb_build_object('amount', v_pamt, 'method', v_pmethod, 'reference', v_pref, 'paid_at', v_pat) end;
    if not v_resub then
      insert into prism_einvoices (org_id, partner_id, partner_name, ref, books, doc_id, doc, pay_pending, body)
      values (p_org, v_pid, v_pname, v_ref, true, s.id, v_type, case when v_held then v_pending end, p_inv) returning * into pe;
    else
      update prism_einvoices set body = p_inv, partner_name = coalesce(v_pname, partner_name), pay_pending = v_pending, updated_at = now()
      where id = pe.id returning * into pe;
    end if;
    if v_paid is not null and not v_held then
      perform private.prism_pay(p_org, v_pid, v_pname, s.id, v_pamt, v_pmethod, v_pref, v_pat, m);
    end if;
  end if;
  return jsonb_build_object('duplicate', false, 'resubmitted', v_resub, 'kick', pe.doc_id, 'invoice', private.prism_invoice_json(pe.id));
end $$;

create or replace function public.svc_prism_einvoice_status(p_org uuid, p_partner text, p_ref text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.prism_invoice_json(id) from public.prism_einvoices where org_id = p_org and partner_id = btrim(coalesce(p_partner, '')) and ref = btrim(coalesce(p_ref, ''))
$$;

-- A payment the partner reports later. In the books it is booked to the partner's holding account (at once, or once NRS
-- has signed an invoice to a business); e-invoicing only, the document is marked paid. Either way NRS is told once it is
-- paid in full. Answers { invoice, pay } (pay: the document NRS is to be told about now).
create or replace function public.svc_prism_einvoice_paid(p_org uuid, p_partner text, p_ref text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pe public.prism_einvoices; s public.sales; eo public.einvoice_only; m public.members; v_amt numeric; v_method text; v_ref text; v_at timestamptz;
  v_left numeric; v_full boolean;
begin
  select * into pe from prism_einvoices where org_id = p_org and partner_id = btrim(coalesce(p_partner, '')) and ref = btrim(coalesce(p_ref, '')) for update;
  if not found then raise exception 'No invoice % from this partner for the merchant.', p_ref using errcode = 'PX404'; end if;
  if pe.doc = 'credit_note' then raise exception 'A credit note is not paid.'; end if;
  p := coalesce(p, '{}'::jsonb);
  v_method := lower(coalesce(nullif(btrim(coalesce(p->>'method', '')), ''), 'other'));
  if v_method not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other') then raise exception 'paid.method must be cash, transfer, card, pos, cheque or other.'; end if;
  v_ref := nullif(left(btrim(coalesce(p->>'reference', '')), 80), '');
  begin
    v_at := least(coalesce(nullif(btrim(coalesce(p->>'paid_at', '')), '')::timestamptz, now()), now());
  exception when others then raise exception 'paid.paid_at is a time, like 2026-11-14T10:30:00+01:00.';
  end;
  s := private.einvoice_doc_sale(pe.doc_id);
  if pe.books then
    select * into s from sales where id = pe.doc_id for update;
    if s.status in ('void', 'cancelled') then raise exception 'The merchant voided %.', s.number; end if;
    v_left := s.total - s.amount_paid - s.credited;
    if s.status <> 'draft' and v_left <= 0.004 then raise exception '% is paid already.', s.number; end if;
    v_amt := round(coalesce(private.num(p->>'amount'), case when s.status = 'draft' then s.total else v_left end), 2);
    if v_amt <= 0 then raise exception 'paid.amount must be above zero.'; end if;
    if s.status = 'draft' then
      -- Still waiting for NRS to sign it: booked once it is issued.
      if v_amt > s.total + 0.004 then raise exception 'paid.amount is more than the invoice (%).', to_char(s.total, 'FM999,999,999,990.00'); end if;
      update prism_einvoices set pay_pending = jsonb_build_object('amount', v_amt, 'method', v_method, 'reference', v_ref, 'paid_at', v_at), updated_at = now() where id = pe.id;
    else
      if v_amt > v_left + 0.004 then raise exception 'paid.amount is more than what is owed on % (%).', s.number, to_char(v_left, 'FM999,999,999,990.00'); end if;
      m := private.prism_owner(p_org);
      perform private.prism_pay(p_org, pe.partner_id, pe.partner_name, s.id, v_amt, v_method, v_ref, v_at, m);
      update prism_einvoices set updated_at = now() where id = pe.id;
    end if;
  else
    select * into eo from einvoice_only where id = pe.doc_id for update;
    if eo.paid then raise exception 'Invoice % is paid already.', pe.ref; end if;
    v_amt := round(coalesce(private.num(p->>'amount'), eo.total), 2);
    if v_amt <= 0 or v_amt > eo.total + 0.004 then raise exception 'paid.amount must be above zero and no more than the total (%).', to_char(eo.total, 'FM999,999,999,990.00'); end if;
    v_full := v_amt >= eo.total - 0.004;
    update einvoice_only set paid = v_full, paid_at = case when v_full then v_at end, pay_reference = coalesce(v_ref, pay_reference),
      facts = jsonb_set(facts, '{payments}', jsonb_build_array(v_method)), updated_at = now()
    where id = eo.id;
    if v_full then
      update einvoice_docs set pay_due = 'PAID', pay_next_at = now(), pay_tries = 0, pay_note = null, updated_at = now()
      where sale_id = eo.id and state = 'signed' and coalesce(pay_status, '') <> 'PAID';
    end if;
    update prism_einvoices set updated_at = now() where id = pe.id;
  end if;
  return jsonb_build_object('invoice', private.prism_invoice_json(pe.id),
    'pay', (select d.sale_id from einvoice_docs d where d.sale_id = pe.doc_id and d.state = 'signed' and d.pay_due is not null));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Prism's invoices are not counted against the merchant's plan
-- ---------------------------------------------------------------------------
create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    -- Partners' invoices through Prism are charged by Prism in credits.
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') and new.channel is distinct from 'api' then
      perform private.check_quota(new.org_id, 'sales');
    end if;
  elsif tg_table_name = 'members' then
    if new.role <> 'owner' and new.status in ('active', 'invited') then perform private.check_quota(new.org_id, 'users'); end if;
  elsif tg_table_name = 'locations' then
    perform private.check_quota(new.org_id, 'locations');
  elsif tg_table_name = 'payouts' then
    if new.batch_id is not null and not private.feature_on(new.org_id, 'bulk_payments') then
      raise exception 'Bulk payments are not in your plan. The owner can change the plan in Settings, Subscription.';
    end if;
    perform private.check_quota(new.org_id, 'payouts');
  elsif tg_table_name = 'supplier_invoices' then
    if new.source = 'portal' and not private.feature_on(new.org_id, 'supplier_portal') then
      raise exception 'This business is not taking invoices on its portal right now.';
    end if;
    perform private.check_quota(new.org_id, 'supplier_invoices');
  elsif tg_table_name = 'tin_checks' then
    perform private.check_quota(new.org_id, 'tin_checks');
  elsif tg_table_name = 'bank_accounts' then
    if new.provider = 'mono' and (tg_op = 'INSERT' or old.provider is distinct from 'mono') then
      if not private.feature_on(new.org_id, 'bank_feeds') then
        raise exception 'Bank feeds are not in your plan. The owner can change the plan in Settings, Subscription.';
      end if;
      perform private.check_quota(new.org_id, 'bank_feeds');
    end if;
  elsif tg_table_name = 'voice_calls' then
    perform private.check_quota(new.org_id, 'call_minutes');
  elsif tg_table_name = 'messages' then
    -- A message over a blocking limit is kept, marked failed with the reason, so whatever queued it carries on. Counta's
    -- own alerts to the team are not counted.
    if new.template is distinct from 'alert' then
      begin
        perform private.check_quota(new.org_id, case when new.channel = 'whatsapp' then 'whatsapp' else 'emails' end);
      exception when sqlstate 'P0001' then
        new.status := 'failed'; new.error := left(sqlerrm, 300);
      end;
    end if;
  end if;
  return new;
end $$;

create or replace function private.meter_usage(p_org uuid, p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := private.month_start(); v numeric;
begin
  case p_meter
    when 'sales' then
      select count(*) into v from sales where org_id = p_org and created_at >= v_from and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled')
        and channel <> 'api';
    when 'ai_reads' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_read_kinds()) and at >= v_from;
    when 'assistant' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_assistant_kinds()) and at >= v_from;
    when 'call_minutes' then
      select coalesce(sum(ceil(coalesce(duration_secs, 0) / 60.0)), 0) into v from voice_calls where org_id = p_org and created_at >= v_from;
    when 'whatsapp' then
      select count(*) into v from messages where org_id = p_org and channel = 'whatsapp' and template <> 'alert' and status <> 'failed' and created_at >= v_from;
    when 'emails' then
      select count(*) into v from messages where org_id = p_org and channel = 'email' and template <> 'alert' and status <> 'failed' and created_at >= v_from;
    when 'tin_checks' then
      select count(*) into v from tin_checks where org_id = p_org and at >= v_from;
    when 'supplier_invoices' then
      select count(*) into v from supplier_invoices where org_id = p_org and created_at >= v_from;
    when 'payouts' then
      select count(*) into v from payouts where org_id = p_org and created_at >= v_from and status <> 'cancelled';
    when 'users' then
      select count(*) into v from members where org_id = p_org and status in ('active', 'invited');
    when 'locations' then
      select count(*) into v from locations where org_id = p_org;
    when 'bank_feeds' then
      select count(*) into v from bank_accounts where org_id = p_org and provider = 'mono' and active;
    else v := 0;
  end case;
  return coalesce(v, 0);
end $$;

-- ---------------------------------------------------------------------------
-- 8. What the merchant sees: e-invoices outside the books, under E-invoicing
-- ---------------------------------------------------------------------------
-- p: { state: attention | waiting | signed, q (number, customer or ref), limit, offset }.
create or replace function public.einvoice_only_list(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_state text := nullif(p->>'state', '');
  v_limit int := least(greatest(coalesce(nullif(p->>'limit', '')::int, 50), 1), 200); v_off int := greatest(coalesce(nullif(p->>'offset', '')::int, 0), 0);
begin
  perform private.einvoice_viewer(p_org);
  return (with rows as (
      select o.*, d.state, d.irn, d.kind, d.xm_state, d.signed_at, d.note, pe.ref
      from einvoice_only o join einvoice_docs d on d.sale_id = o.id left join prism_einvoices pe on pe.doc_id = o.id
      where o.org_id = p_org
        and (v_state is null or (v_state = 'attention' and (d.state = 'refused' or d.xm_state = 'failed'))
          or (v_state = 'waiting' and d.state in ('waiting', 'sending')) or (v_state = 'signed' and d.state = 'signed'))
        and (v_q is null or o.number ilike '%' || v_q || '%' or o.customer_name ilike '%' || v_q || '%' or pe.ref ilike '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from rows),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'doc', r.doc, 'issue_date', r.issue_date, 'customer_name', r.customer_name,
          'total', r.total, 'currency', r.currency, 'paid', r.paid, 'partner_name', r.partner_name, 'ref', r.ref, 'state', r.state, 'irn', r.irn, 'kind', r.kind,
          'buyer_state', r.xm_state, 'signed_at', r.signed_at, 'note', r.note, 'created_at', r.created_at) order by r.created_at desc)
        from (select * from rows order by created_at desc limit v_limit offset v_off) r), '[]'::jsonb)));
end $$;

create or replace function public.einvoice_only_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_org uuid; m public.members;
begin
  select org_id into v_org from einvoice_only where id = p_id;
  if v_org is null then raise exception 'E-invoice not found.'; end if;
  m := private.einvoice_viewer(v_org);
  return private.einvoice_only_json(p_id) || jsonb_build_object('can', jsonb_build_object('send_to_buyer', private.perm_of(m, 'record_sales')));
end $$;

-- ---------------------------------------------------------------------------
-- 9. The admin portal: Prism's callback address, and how the callbacks are going
-- ---------------------------------------------------------------------------
create or replace function public.admin_einvoice_webhook() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object('path', '/functions/v1/einvoice/nrs-hook/' || coalesce(public.svc_einvoice_hook_token(), ''),
    'last', (select jsonb_build_object('at', w.at, 'message', w.message, 'matched', w.matched) from einvoice_webhooks w order by w.at desc limit 1),
    'today', (select count(*) from einvoice_webhooks where at >= now() - interval '24 hours'),
    'to_buyers', (select count(*) from einvoice_docs where xm_state in ('transmitted', 'acknowledged')),
    'received', (select count(*) from einvoice_inbound where state in ('billed', 'confirmed')),
    'prism', jsonb_build_object(
      'merchants', (select count(distinct org_id) from prism_einvoices),
      'invoices_today', (select count(*) from prism_einvoices where created_at >= now() - interval '24 hours'),
      'callbacks_waiting', (select count(*) from prism_callbacks where state in ('due', 'sending')),
      'callbacks_failed', (select count(*) from prism_callbacks where state = 'failed'),
      'last_sent', (select max(sent_at) from prism_callbacks),
      'last_error', (select c.last_error from prism_callbacks c where c.last_error is not null order by coalesce(c.sending_at, c.created_at) desc limit 1)));
end $$;

-- As of 13 November, with Prism's callback address added and the APP key's hint brought up to date.
create or replace function private.secret_catalog() returns table (name text, grp text, label text, secret boolean, hint text, sort int)
language sql immutable as $$
  values
    ('GOOGLE_APPLICATION_CREDENTIALS_JSON', 'gemini', 'Service account key (JSON)', true, 'A Google Cloud service account with the Vertex AI User role. Paste the whole key file.', 101),
    ('GOOGLE_CLOUD_PROJECT', 'gemini', 'Google Cloud project', false, 'Leave empty to use the key''s own project.', 102),
    ('GOOGLE_CLOUD_LOCATION', 'gemini', 'Vertex AI region', false, 'us-central1 unless the project uses another region.', 103),
    ('GEMINI_MODEL', 'gemini', 'Gemini model', false, 'Leave empty for gemini-3.8-flash.', 104),
    ('GEMINI_API_KEY', 'gemini', 'Gemini API key (fallback)', true, 'Only used when there is no service account key.', 105),
    ('ELEVENLABS_API_KEY', 'elevenlabs', 'API key', true, 'Needs access to text to speech, voices, agents and phone numbers.', 201),
    ('ELEVENLABS_PHONE_NUMBER_ID', 'elevenlabs', 'Phone number for calls', false, 'Only needed when ElevenLabs has more than one number. The id from Phone Numbers in ElevenLabs.', 202),
    ('ELEVENLABS_TTS_MODEL', 'elevenlabs', 'Voice model for announcements', false, 'Leave empty for eleven_flash_v2_5.', 203),
    ('FLW_SECRET_KEY', 'flutterwave', 'Secret key', true, 'From Flutterwave, Settings, API keys. Live keys start FLWSECK-.', 301),
    ('FLW_PUBLIC_KEY', 'flutterwave', 'Public key', false, 'From the same page. Starts FLWPUBK-.', 302),
    ('FLW_WEBHOOK_HASH', 'flutterwave', 'Webhook secret hash', true, 'The same value as Secret hash in Flutterwave''s webhook settings.', 303),
    ('FLW_RELAY_URL', 'flutterwave', 'Transfer relay address', false, 'The https address of TaxStreem''s transfer relay (the server with the fixed IP address whitelisted on Flutterwave).', 304),
    ('FLW_RELAY_SECRET', 'flutterwave', 'Transfer relay secret', true, 'The 64 characters after RELAY_SECRET= in /etc/counta-relay.env on the relay server. Signs every request Counta sends through it.', 305),
    ('FLW_MERCHANT_ID', 'flutterwave', 'TaxStreem merchant ID', false, 'TaxStreem''s own Flutterwave merchant ID (Flutterwave, Settings, Business preferences). Counta plans paid from a business''s wallet go to this account.', 306),
    ('MONO_SECRET_KEY', 'mono', 'Secret key', true, 'From the Mono dashboard, for bank feeds.', 401),
    ('MONO_PUBLIC_KEY', 'mono', 'Public key', false, 'From the same app in the Mono dashboard.', 402),
    ('MONO_WEBHOOK_SECRET', 'mono', 'Webhook secret', true, 'The same value as the webhook secret in the Mono dashboard.', 403),
    ('MONO_LOOKUP_SECRET_KEY', 'mono', 'Lookup key (optional)', true, 'A separate key for CAC, Tax ID and NIN lookups. Without it the secret key is used.', 404),
    ('RESEND_API_KEY', 'email', 'Resend API key', true, 'From Resend, API keys, with sending access.', 501),
    ('RESEND_FROM', 'email', 'Sending address', false, 'An address on the domain verified in Resend, such as billing@taxstreem.com. Customers see "Business name via Counta".', 502),
    ('WHATSAPP_TOKEN', 'whatsapp', 'Access token', true, 'A permanent system user token from Meta Business, with WhatsApp messaging access.', 601),
    ('WHATSAPP_PHONE_NUMBER_ID', 'whatsapp', 'Phone number id', false, 'From WhatsApp, API setup, in the Meta app.', 602),
    ('WHATSAPP_BUSINESS_ACCOUNT_ID', 'whatsapp', 'Business account id', false, 'From the same page.', 603),
    ('WHATSAPP_APP_SECRET', 'whatsapp', 'App secret', true, 'From the Meta app''s basic settings. Checks that webhooks come from Meta.', 604),
    ('WHATSAPP_VERIFY_TOKEN', 'whatsapp', 'Webhook verify token', true, 'Any long random text, entered in the same place in the Meta app.', 605),
    ('WHATSAPP_TEMPLATE_LANG', 'whatsapp', 'Template language', false, 'en unless the message templates were approved in another language.', 606),
    ('WHATSAPP_PROVIDER', 'openwa', 'Which WhatsApp sends', false, 'openwa sends everything from TaxStreem''s number on the OpenWA server; meta uses the official WhatsApp Business API above. Leave empty for openwa once OpenWA is connected.', 650),
    ('OPENWA_URL', 'openwa', 'OpenWA server address', false, 'The https address of TaxStreem''s OpenWA server, such as https://wa.taxstreem.com.', 651),
    ('OPENWA_API_KEY', 'openwa', 'OpenWA API key', true, 'An Operator key made in the OpenWA dashboard, under API keys. Not the admin key.', 652),
    ('OPENWA_WEBHOOK_SECRET', 'openwa', 'Webhook secret', true, 'Counta makes this when you press Connect, and gives it to OpenWA. It proves that messages arriving at Counta came from your server.', 653),
    ('OPENWA_BUSINESS_NUMBERS', 'openwa', 'Businesses may link their own number', false, 'on lets businesses link their own WhatsApp number on the Integrations page, so their invoices come from it. Each linked number uses about 400 MB on the server. Leave empty for off.', 654),
    ('NUMENS_API_URL', 'numens', 'Numens address', false, 'The https address of TaxStreem''s tax model.', 701),
    ('NUMENS_API_KEY', 'numens', 'Numens key', true, null, 702),
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account. Prism signs its bills and partners'' invoices with it too.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('FLUX_FILE_HOSTS', 'taxstreem', 'Flux file hosts', false, 'Other hosts Flux''s file links may point to, comma separated, such as files.taxstreem.com. Links on the Flux address itself are always allowed. Leave empty if Flux sends files only from there.', 805),
    ('PRISM_CALLBACK_URL', 'taxstreem', 'Prism callback address', false, 'The https address on Prism where Counta says how each partner invoice went with NRS (signed, refused, delivered to the buyer). Each call is signed with the single sign-on secret. Until it is set, the callbacks wait.', 806),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903),
    ('NRS_BASE_URL', 'nrs', 'NRS e-invoicing address', false, 'The base address on the NRS e-invoicing dashboard (sandbox first, production after NRS''s review), such as https://… with nothing after the host.', 1001),
    ('NRS_API_KEY', 'nrs', 'API key', true, 'From the NRS e-invoicing dashboard. Sent as x-api-key.', 1002),
    ('NRS_API_SECRET', 'nrs', 'API secret', true, 'From the same page. Sent as x-api-secret.', 1003),
    ('NRS_BUSINESS_ID', 'nrs', 'TaxStreem''s Business ID', false, 'The Business ID NRS gave TaxStreem Technologies Limited when it was enabled for e-invoicing.', 1004),
    ('NRS_SERVICE_ID', 'nrs', 'TaxStreem''s Service ID', false, 'The 8-character Service ID NRS gave TaxStreem. It is the middle part of every IRN.', 1005),
    ('NRS_CRYPTO_KEYS', 'nrs', 'QR code keys (crypto_keys.txt)', true, 'The whole contents of crypto_keys.txt from My Account, Manage Cryptographic Keys: the public key and certificate the QR code is made with.', 1006),
    ('NRS_APP_API_KEY', 'nrs', 'APP API key', true, 'TaxStreem''s access point key, from NRS''s APP portal (einvoice.nrs.gov.ng/access-point), Developer section, once TaxStreem is an accredited access point. Sends invoices to buyers and brings in invoices for businesses. Until it is set, signed sales wait to go to the buyer.', 1007),
    ('NRS_APP_API_SECRET', 'nrs', 'APP API secret', true, 'The secret that goes with the APP key, from the same page.', 1008),
    ('GOOGLE_KMS_KEY_RING', 'kms', 'Key ring', false, 'Leave empty for projects/<project>/locations/us-central1/keyRings/counta-einvoice. It holds nrs-credentials (encrypt and decrypt) and invoice-signing (EC P-256, SHA-256), both HSM keys. The service account in Google Gemini above signs in, with Cloud KMS CryptoKey Encrypter/Decrypter on the first key and Signer/Verifier on the second.', 1101)
$$;

-- ---------------------------------------------------------------------------
-- 10. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.svc_prism_merchant(text, jsonb), public.svc_prism_enable(uuid), public.svc_prism_einvoice(uuid, jsonb, jsonb),
  public.svc_prism_einvoice_status(uuid, text, text), public.svc_prism_einvoice_paid(uuid, text, text, jsonb),
  public.svc_prism_callback_claim(uuid), public.svc_prism_callback_done(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_prism_merchant(text, jsonb), public.svc_prism_enable(uuid), public.svc_prism_einvoice(uuid, jsonb, jsonb),
  public.svc_prism_einvoice_status(uuid, text, text), public.svc_prism_einvoice_paid(uuid, text, text, jsonb),
  public.svc_prism_callback_claim(uuid), public.svc_prism_callback_done(uuid, jsonb)
  to service_role;
revoke all on function public.einvoice_only_list(uuid, jsonb), public.einvoice_only_get(uuid) from public, anon;
grant execute on function public.einvoice_only_list(uuid, jsonb), public.einvoice_only_get(uuid) to authenticated;
revoke all on function private.on_einvoice_source_deleted(), private.einvoice_doc_sale(uuid), private.einvoice_doc_link(uuid), private.prism_state(text),
  private.prism_lga(text, text), private.prism_invoice_json(uuid), private.prism_account(uuid, text, text, uuid),
  private.prism_pay(uuid, text, text, uuid, numeric, text, text, timestamptz, public.members), private.prism_owner(uuid), private.prism_after_signed(uuid),
  private.einvoice_only_json(uuid), private.on_einvoice_doc_prism(), private.prism_resubmittable(uuid)
  from public, anon, authenticated;
