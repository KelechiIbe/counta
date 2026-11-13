-- Practice management, part 11: fee billing.
--
-- Each firm bills its clients from its own Counta business, the "firm business" (practices.firm_org_id): an ordinary
-- business with the usual identity check, Flutterwave business wallet and tax wallet (VAT on fee collections moves to the
-- tax wallet as for any business). A partner links one they really own (the owner, not someone acting for it: a business the
-- firm runs under full mandate never becomes its own), or creates one here; a business created here starts with its
-- identity pending, so its payments stay locked until a director's identity is verified the usual way (create_org's default,
-- not_required, would open them with no check). One firm business per practice, and one practice per firm business.
--
-- Each practice client has a customer in the firm business (practice_clients.fee_customer_id): a business customer named as
-- the client's business, with its TIN, when it is created. Fee invoices are ordinary sales invoices of the firm business to
-- that customer, by hand or by a recurring schedule. Fee invoices to a full-mandate client carry no Counta branding, also
-- the closing ones after the mandate ended without a handover (private.white_label). For a client whose books the practice
-- keeps under full mandate, each fee invoice is also posted, once issued, as a bill in the client's own books (the fee
-- mirror): the practice as vendor (practice_clients.fee_vendor_id, made on the first bill and kept), professional fees
-- (6502, or 6507 where the client has no 6502) and input VAT (the invoice's VAT and total to the kobo), entered and approved
-- in the name of the client's contact (private.org_contact: the bill's created_by and approved_by). The activity log names
-- the person signed in when there is one (auth.uid() comes first in private.activity_add), else the contact, whom the
-- mirror sets as counta.actor for a posting by Counta (a recurring invoice issued by the hourly tick), putting back the actor
-- it found afterwards. Opening balances brought in by a books migration (channel 'import') are not fee invoices: no bill.
-- It is recorded in practice_fee_bills:
--   posted     the bill is in the client's books;
--   failed     it could not be (error says why, as approve_bill would: a month the client's books have closed, an invoice
--              already entered by hand...); a lead tries it again (practice_fee_bill_retry), or a partner dismisses it with
--              a reason when it never can be (practice_fee_bill_dismiss);
--   dismissed  a failed one a partner gave up on;
--   skipped    the client's engagement had ended (its books are read-only) or the practice no longer kept them, so no bill;
--   voided     the fee invoice was voided: its unpaid bill was voided with it (or it had none).
-- The mirror never stops the invoice being issued, and never writes in a business that is read-only or that the practice no
-- longer runs under full mandate: a voided fee invoice whose bill cannot be voided keeps the record posted, with why. An
-- involved client keeps its own books: nothing is posted or recorded. Credit notes on fee invoices are not posted to the
-- client's bill: the fees overview shows what was credited on each invoice and flags its posted bill.
--
-- void_bill keeps its behaviour: its body after the permission check is now private.void_bill_as, which the mirror calls
-- as the client's contact. The fees overview (practice_fees) is for the practice's leads; wallet balances for partners only.
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Bills from fees, and their record
-- ---------------------------------------------------------------------------
alter table public.bills drop constraint if exists bills_source_check;
alter table public.bills add constraint bills_source_check
  check (source in ('manual', 'receipt', 'prism', 'ai', 'import', 'landed_cost', 'supplier', 'bulk', 'practice_fee'));

-- One record per fee invoice of a full-mandate client (sale_id: the invoice in the firm business; bill_id: the bill in the
-- client's books). attempts: how many times the bill was tried. dismissed_*: the partner who gave up on a failed one, and why.
create table public.practice_fee_bills (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  sale_id uuid not null unique references public.sales(id) on delete cascade,
  bill_id uuid references public.bills(id) on delete set null,
  status text not null check (status in ('posted', 'failed', 'voided', 'skipped', 'dismissed')),
  error text,
  attempts int not null default 0,
  dismissed_by uuid references auth.users(id) on delete set null,
  dismissed_at timestamptz,
  dismiss_reason text check (dismiss_reason is null or length(dismiss_reason) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index practice_fee_bills_client on public.practice_fee_bills(client_id, created_at);
create index practice_fee_bills_practice on public.practice_fee_bills(practice_id);
create index practice_fee_bills_bill on public.practice_fee_bills(bill_id) where bill_id is not null;
create index practice_fee_bills_dismissed_by on public.practice_fee_bills(dismissed_by) where dismissed_by is not null;
alter table public.practice_fee_bills enable row level security;
revoke all on public.practice_fee_bills from anon, authenticated;

-- One practice per firm business (the fee mirror finds the practice by it): the index of outbound_branding, made unique.
drop index if exists public.practices_firm_org;
create unique index practices_firm_org on public.practices(firm_org_id) where firm_org_id is not null;

-- white_label: as before, and also the fee customer of a full-mandate client whose mandate ended without a handover (the
-- practice still runs its records, read-only, so its closing fee invoices stay unbranded). A handover lifts it.
create or replace function private.white_label(p_org uuid, p_customer uuid default null) returns boolean
language sql stable set search_path = public, private as $$
  select private.is_managed(p_org) or exists (
    select 1 from practice_clients c join practices p on p.id = c.practice_id
    where p.firm_org_id = p_org and c.fee_customer_id = p_customer and c.mode = 'full'
      and (c.status = 'active' or (c.status = 'ended' and c.end_kind = 'ended')))
$$;

-- ---------------------------------------------------------------------------
-- 2. Voiding a bill as a given member
-- ---------------------------------------------------------------------------
-- void_bill's body after its permission check, for the member m (unchanged).
create or replace function private.void_bill_as(p_bill uuid, p_reason text, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
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

-- void_bill: the bill, the permission check, then void_bill_as (same errors in the same order).
create or replace function public.void_bill(p_bill uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  return private.void_bill_as(b.id, p_reason, m);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The firm business
-- ---------------------------------------------------------------------------
-- A partner sets up the firm's own business. p = {org_id}: link a business the partner really owns (its owner member, not
-- someone acting for it), that no practice runs for a client, that is not a sample and not another practice's; or
-- p = {name, email?, phone?}: create one with create_org (the partner its owner, under the partner's name; the email
-- defaults to the partner's), its identity pending so payments stay locked until a director's identity is verified. One
-- per practice: linking the same one again changes nothing. {firm_org_id}.
create or replace function public.practice_firm_business(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; pr public.practices; o public.orgs; v_org uuid; v_name text; v_other text;
begin
  m := private.practice_require(p_practice, true);
  if m.role <> 'partner' then raise exception 'Only a partner sets up the firm''s own business.' using errcode = '42501'; end if;
  select * into pr from practices where id = p_practice for update;
  p := case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end;
  if p ? 'org_id' then
    select * into o from orgs where id = private.uuid_of(trim(p->>'org_id'));
    -- The real owner: an acting owner (a partner's place in a business the firm runs) may not make it the firm's own.
    if o.id is null or not exists (select 1 from members where org_id = o.id and user_id = auth.uid() and role = 'owner' and status = 'active') then
      raise exception 'Link a business you own: you must be its owner, not someone acting for it.' using errcode = '42501';
    end if;
    if o.managed_by is not null or o.read_only_at is not null then
      raise exception 'A business a practice runs for a client cannot be the firm''s own business.';
    end if;
    if o.is_sample then raise exception 'A sample business cannot be the firm''s own business.'; end if;
    if pr.firm_org_id = o.id then return jsonb_build_object('firm_org_id', o.id); end if;
    if pr.firm_org_id is not null then
      raise exception 'The practice''s own business is already %.', coalesce((select name from orgs where id = pr.firm_org_id), 'set up');
    end if;
    select name into v_other from practices where firm_org_id = o.id and id <> pr.id limit 1;
    if v_other is not null then raise exception '% is already the own business of another practice, %.', o.name, v_other; end if;
    v_org := o.id;
  else
    if pr.firm_org_id is not null then
      raise exception 'The practice''s own business is already %.', coalesce((select name from orgs where id = pr.firm_org_id), 'set up');
    end if;
    v_name := trim(coalesce(p->>'name', ''));
    if v_name = '' then raise exception 'Give the business a name, or choose one you own.'; end if;
    v_org := public.create_org(v_name, p->>'email', p->>'phone', m.display_name);
    update orgs set identity_status = 'pending' where id = v_org;
  end if;
  update practices set firm_org_id = v_org, updated_at = now() where id = pr.id;
  return jsonb_build_object('firm_org_id', v_org);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Fee customers
-- ---------------------------------------------------------------------------
-- A lead upserts the client's customer in the firm business, as the firm business's contact. A new one is a business
-- customer named as the client's business, with the business's TIN (so withholding tax is expected on fees and NRS clears
-- the e-invoice), unless p gives the kind or TIN; an involved client's starts from the business's own email and address (a
-- full-mandate client's business email is the firm's; a phone is never copied, as another customer may have it). After
-- that the name stays as the firm keeps it, and email, phone, address, kind and TIN change only as p gives them (a key
-- given replaces, one left out is kept). The client must be connected (active, or ended for its last fees). Stored as
-- fee_customer_id. {customer_id}.
create or replace function public.practice_fee_customer(p_client uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; pr public.practices; o public.orgs; fm public.members; cu public.customers; v jsonb; k text;
  v_cust uuid;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  select * into pr from practices where id = c.practice_id;
  if pr.firm_org_id is null then raise exception 'Set up the firm''s own business first: fee invoices are issued from it.'; end if;
  if c.status not in ('active', 'ended') or c.org_id is null then raise exception 'Bill a client once it is connected.'; end if;
  p := case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end;
  if p ? 'kind' and coalesce(p->>'kind', '') not in ('individual', 'business', 'government') then
    raise exception 'Choose the customer''s kind: individual, business or government.';
  end if;
  select * into o from orgs where id = c.org_id;
  fm := private.org_contact(pr.firm_org_id);
  if fm.id is null then raise exception 'The firm''s own business has no owner to act for it.'; end if;
  select * into cu from customers where id = c.fee_customer_id and org_id = pr.firm_org_id;
  if cu.id is not null then
    v := jsonb_build_object('id', cu.id, 'name', cu.name, 'archived', false);
  else
    v := jsonb_build_object('name', left(coalesce(o.name, c.business_name), 120), 'kind', 'business', 'tin', o.tin);
    if c.mode = 'involved' then v := v || jsonb_build_object('email', o.email, 'address', o.address); end if;
  end if;
  foreach k in array array['email', 'phone', 'address', 'kind', 'tin'] loop
    if p ? k then v := v || jsonb_build_object(k, p->k); end if;
  end loop;
  v_cust := private.upsert_customer(pr.firm_org_id, v, fm);
  if c.fee_customer_id is distinct from v_cust then
    update practice_clients set fee_customer_id = v_cust where id = c.id;
  end if;
  return jsonb_build_object('customer_id', v_cust);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The fee mirror
-- ---------------------------------------------------------------------------
-- The bill in the client's books for a fee invoice (issued: posted to the firm business's books) to a practice client's
-- fee customer; not for an opening balance a books migration brought in (channel 'import'). For an active full-mandate
-- client of the practice whose books are not read-only: entered in the name of the client's contact (created_by,
-- approved_by), with the contact as counta.actor so that a posting by Counta is logged in their name (a person signed in is
-- logged as themselves) and the actor found put back afterwards; one line per invoice line (its amount
-- as the invoice prices it, before VAT or with VAT included; professional fees; VAT standard when the line carries VAT),
-- checked as approve_bill checks (an amount, a day the books have not closed, not entered already) and posted; the vendor
-- kept on the client; logged (fee_bill_posted). Any error is recorded on the failed record with the attempt counted. A client whose engagement ended, or whose books the
-- practice no longer keeps, gets a skipped record; an involved client nothing. A record already posted, skipped or voided is
-- returned as it is. Returns the record (null fields when there is none).
create or replace function private.fee_mirror(p_sale uuid) returns public.practice_fee_bills
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; c public.practice_clients; pr public.practices; o public.orgs; r public.practice_fee_bills; m public.members;
  b public.bills; v_vendor uuid; v_code text; v_lines jsonb; v_actor text; v_why text;
begin
  select * into s from sales where id = p_sale;
  if s.id is null or s.doc_type <> 'invoice' or s.journal_id is null or s.customer_id is null or s.channel = 'import' then return r; end if;
  -- The client billed: of a practice whose firm business issued the invoice, with this fee customer (an active full mandate
  -- first).
  select x.* into c from practice_clients x join practices p on p.id = x.practice_id
  where p.firm_org_id = s.org_id and x.fee_customer_id = s.customer_id
  order by (x.status = 'active' and x.mode = 'full') desc, (x.status = 'active') desc, x.started_at desc nulls last, x.created_at desc
  limit 1;
  if c.id is null then return r; end if;
  select * into r from practice_fee_bills where sale_id = s.id for update;
  if r.id is not null and r.status <> 'failed' then return r; end if;
  select * into pr from practices where id = c.practice_id;
  select * into o from orgs where id = c.org_id;

  if not (c.status = 'active' and c.mode = 'full' and o.managed_by is not distinct from c.practice_id and o.read_only_at is null) then
    -- An involved client keeps its own books: nothing to post or record (a failed record from before a handover is closed).
    if r.id is null and c.mode <> 'full' and o.read_only_at is null then return r; end if;
    v_why := case when o.read_only_at is not null or c.status = 'ended'
      then 'The client''s engagement has ended: its books are read-only, so no bill was posted in them.'
      else 'The firm no longer keeps this client''s books under full mandate, so no bill was posted in them.' end;
    insert into practice_fee_bills (practice_id, client_id, sale_id, status, error)
    values (c.practice_id, c.id, s.id, 'skipped', v_why)
    on conflict (sale_id) do update set status = 'skipped', error = excluded.error, updated_at = now()
    returning * into r;
    return r;
  end if;

  v_actor := current_setting('counta.actor', true);
  begin
    m := private.org_contact(o.id);
    if m.id is null then raise exception 'Nobody can enter the bill in %: the engagement partner has no place in it.', o.name; end if;
    perform private.set_actor(m.user_id);
    v_code := case when private.bill_account_ok(o.id, '6502') then '6502' else '6507' end;
    -- Each line's amount as the invoice priced it (before VAT, or with VAT included), so the bill's VAT and total are the
    -- invoice's to the kobo (an amount with VAT included, taken back to its amount before VAT and charged VAT again, can
    -- come out a kobo off).
    select jsonb_agg(jsonb_build_object('description', l.description, 'qty', 1,
        'unit_cost', case when s.prices_include_vat then l.gross else l.net end, 'account_code', v_code,
        'vat_treatment', case when l.vat > 0 then 'standard' else 'none' end) order by l.line_no)
      into v_lines from sale_lines l where l.sale_id = s.id;
    v_vendor := (select id from vendors where id = c.fee_vendor_id and org_id = o.id);
    b := private.write_bill(o.id, jsonb_build_object('bill_date', s.issue_date, 'due_date', s.due_date, 'vendor_ref', s.number,
        'source', 'practice_fee', 'vat_charged', s.vat_total > 0, 'prices_include_vat', s.prices_include_vat, 'lines', coalesce(v_lines, '[]'::jsonb))
      || case when v_vendor is not null then jsonb_build_object('vendor_id', v_vendor)
         else jsonb_build_object('vendor', jsonb_build_object('name', pr.name, 'tin', (select tin from orgs where id = s.org_id),
           'email', pr.email, 'wht_category', 'professional')) end, m);
    -- As approve_bill checks a bill before posting it.
    if b.total <= 0 then raise exception 'The bill total must be above zero.'; end if;
    perform private.require_open_day(o.id, b.bill_date);
    if exists (select 1 from bills where org_id = o.id and vendor_id = b.vendor_id and vendor_ref = b.vendor_ref and id <> b.id and status <> 'void') then
      raise exception 'Bill % from this vendor is already entered.', b.vendor_ref;
    end if;
    b := private.post_bill(b.id, m);
    if c.fee_vendor_id is distinct from b.vendor_id then
      update practice_clients set fee_vendor_id = b.vendor_id where id = c.id;
    end if;
    perform private.activity_event(o.id, 'fee_bill_posted', 'Bill ' || b.number || ' from ' || pr.name || ' for fee invoice ' || s.number,
      jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'sale_id', s.id, 'invoice', s.number, 'bill_id', b.id,
        'bill', b.number, 'total', b.total));
    insert into practice_fee_bills (practice_id, client_id, sale_id, bill_id, status, error, attempts)
    values (c.practice_id, c.id, s.id, b.id, 'posted', null, 1)
    on conflict (sale_id) do update set bill_id = excluded.bill_id, status = 'posted', error = null,
      attempts = practice_fee_bills.attempts + 1, updated_at = now()
    returning * into r;
  exception when others then
    insert into practice_fee_bills (practice_id, client_id, sale_id, status, error, attempts)
    values (c.practice_id, c.id, s.id, 'failed', left(sqlerrm, 500), 1)
    on conflict (sale_id) do update set status = 'failed', error = excluded.error, bill_id = null,
      attempts = practice_fee_bills.attempts + 1, updated_at = now()
    returning * into r;
  end;
  perform set_config('counta.actor', coalesce(v_actor, ''), true);
  return r;
end $$;

-- After an invoice is posted (issued) in a firm business: the fee mirror. Never stops the invoice.
create or replace function private.fee_mirror_on_post() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.customer_id is not null and exists (select 1 from practices where firm_org_id = new.org_id) then
    begin
      perform private.fee_mirror(new.id);
    exception when others then
      raise warning 'The fee bill for % was not recorded: %', new.number, sqlerrm;
    end;
  end if;
  return null;
end $$;

-- After a fee invoice is voided: its bill in the client's books is voided in the name of the client's contact (voided_by;
-- counta.actor as in fee_mirror, the actor found put back afterwards) when nothing is paid on it and the practice still runs
-- those books (not read-only); the record becomes voided.
-- A failed record (no bill) is closed as voided; a dismissed, skipped or voided one is left. A bill that cannot be voided is
-- left, the record posted, with why. Never stops the void.
create or replace function private.fee_mirror_on_void() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare r public.practice_fee_bills; c public.practice_clients; o public.orgs; b public.bills; m public.members; v_actor text; v_why text;
begin
  select * into r from practice_fee_bills where sale_id = new.id for update;
  if r.id is null or r.status in ('voided', 'skipped', 'dismissed') then return null; end if;
  begin
    select * into b from bills where id = r.bill_id;
    if r.status = 'failed' or b.id is null or b.status = 'void' then
      update practice_fee_bills set status = 'voided', error = null, updated_at = now() where id = r.id;
      return null;
    end if;
    select * into c from practice_clients where id = r.client_id;
    select * into o from orgs where id = b.org_id;
    v_why := case
      when o.read_only_at is not null then
        format('The client''s books are read-only (its engagement has ended), so bill %s in them was not voided.', b.number)
      when not (c.status = 'active' and c.mode = 'full' and o.managed_by is not distinct from c.practice_id) then
        format('The client keeps its own books now: ask it to void bill %s.', b.number)
      when b.amount_paid > 0 or exists (select 1 from bill_payments where bill_id = b.id and status in ('paid', 'processing')) then
        format('Bill %s in the client''s books has payments, so it was not voided. Record a vendor credit for it there instead.', b.number)
    end;
    if v_why is not null then
      update practice_fee_bills set error = v_why, updated_at = now() where id = r.id;
      return null;
    end if;
    v_actor := current_setting('counta.actor', true);
    begin
      m := private.org_contact(o.id);
      if m.id is null then raise exception 'Nobody can void bill % in %: the engagement partner has no place in it.', b.number, o.name; end if;
      perform private.set_actor(m.user_id);
      perform private.void_bill_as(b.id, 'Fee invoice ' || new.number || ' voided' || coalesce(': ' || nullif(trim(new.void_reason), ''), ''), m);
      update practice_fee_bills set status = 'voided', error = null, updated_at = now() where id = r.id;
    exception when others then
      update practice_fee_bills set error = left(sqlerrm, 500), updated_at = now() where id = r.id;
    end;
    perform set_config('counta.actor', coalesce(v_actor, ''), true);
  exception when others then
    raise warning 'The fee bill for % was not voided: %', new.number, sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists sales_fee_mirror on public.sales;
create trigger sales_fee_mirror after update of journal_id on public.sales
  for each row when (old.journal_id is null and new.journal_id is not null and new.doc_type = 'invoice')
  execute function private.fee_mirror_on_post();
drop trigger if exists sales_fee_mirror_void on public.sales;
create trigger sales_fee_mirror_void after update of status on public.sales
  for each row when (new.status = 'void' and old.status is distinct from 'void')
  execute function private.fee_mirror_on_void();

-- ---------------------------------------------------------------------------
-- 6. Retry and the fees overview
-- ---------------------------------------------------------------------------
-- A lead tries a failed fee bill again (the invoice must still be issued, not voided). The record, as it is now.
create or replace function public.practice_fee_bill_retry(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.practice_fee_bills; s public.sales;
begin
  select * into r from practice_fee_bills where id = p_id for update;
  if r.id is null then raise exception 'Fee bill not found.'; end if;
  perform private.practice_require(r.practice_id, true);
  if r.status <> 'failed' then raise exception 'Only a fee bill that failed is tried again.'; end if;
  select * into s from sales where id = r.sale_id;
  if s.journal_id is null or s.status not in ('open', 'partially_paid', 'paid') then
    raise exception 'Fee invoice % is %: there is no bill to post for it.', s.number, s.status;
  end if;
  r := private.fee_mirror(r.sale_id);
  return to_jsonb(r);
end $$;

-- A partner gives up on a failed fee bill that can never be posted (the client's accountant entered the invoice by hand,
-- or it is dated after the day the bill could be), with a reason of 5 to 500 characters: dismissed, never tried again.
-- The record, as it is now.
create or replace function public.practice_fee_bill_dismiss(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.practice_fee_bills; m public.practice_members; v_reason text := trim(coalesce(p_reason, ''));
begin
  select * into r from practice_fee_bills where id = p_id for update;
  if r.id is null then raise exception 'Fee bill not found.'; end if;
  m := private.practice_require(r.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner dismisses a fee bill.' using errcode = '42501'; end if;
  if r.status <> 'failed' then raise exception 'Only a fee bill that failed is dismissed.'; end if;
  if length(v_reason) < 5 then raise exception 'Give the reason for dismissing it.'; end if;
  if length(v_reason) > 500 then raise exception 'Keep the reason under 500 characters.'; end if;
  update practice_fee_bills set status = 'dismissed', dismissed_by = auth.uid(), dismissed_at = now(), dismiss_reason = v_reason, updated_at = now()
  where id = r.id returning * into r;
  return to_jsonb(r);
end $$;

-- The fees page for a lead: the firm business; each client (active, or ended with a fee customer) with its fee customer,
-- what it owes, its fee invoices (newest first, 100 at most; credited: what credit notes took off it), its recurring
-- schedules in the firm business (total: each repeat invoice, VAT included where the firm business charges it) and its fee
-- bills (newest first). Credit notes are not posted to the client's bill: a posted fee bill whose invoice was credited
-- carries the amount credited and a note saying so. And, for partners only, the firm business's wallet and tax wallet with
-- their balances in the books.
-- {firm_org: {id, name, identity_status} | null, clients: [{client_id, business_name, mode, fee_customer_id, outstanding,
--  invoices: [{id, number, issue_date, total, credited, balance, status}], schedules: [{id, frequency, day_of_month, next_run,
--  status, total}], fee_bills: [{id, sale_id, status, error, bill_id, dismiss_reason, credited, note}]}],
--  wallets?: {wallet: {status, balance}, tax_wallet: {status, balance}}}
create or replace function public.practice_fees(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.practice_members; f public.orgs; w public.wallets; t public.tax_wallets; v jsonb;
begin
  m := private.practice_require(p_practice, true);
  select o.* into f from practices p join orgs o on o.id = p.firm_org_id where p.id = p_practice;
  v := jsonb_build_object(
    'firm_org', case when f.id is not null then jsonb_build_object('id', f.id, 'name', f.name, 'identity_status', f.identity_status) end,
    'clients', coalesce((
      select jsonb_agg(jsonb_build_object(
          'client_id', c.id, 'business_name', coalesce(o.name, c.business_name), 'mode', c.mode, 'fee_customer_id', c.fee_customer_id,
          'outstanding', coalesce((select sum(s.total - s.amount_paid - s.credited) from sales s
            where s.org_id = f.id and s.customer_id = c.fee_customer_id and s.doc_type = 'invoice' and s.status in ('open', 'partially_paid')), 0),
          'invoices', coalesce((
            select jsonb_agg(jsonb_build_object('id', s.id, 'number', s.number, 'issue_date', s.issue_date, 'total', s.total, 'credited', s.credited,
                'balance', case when s.status in ('open', 'partially_paid') then s.total - s.amount_paid - s.credited else 0 end, 'status', s.status)
              order by s.issue_date desc, s.created_at desc)
            from (select * from sales where org_id = f.id and customer_id = c.fee_customer_id and doc_type = 'invoice'
                  order by issue_date desc, created_at desc limit 100) s), '[]'::jsonb),
          'schedules', coalesce((
            select jsonb_agg(jsonb_build_object('id', r.id, 'frequency', r.frequency, 'day_of_month', r.day_of_month, 'next_run', r.next_run,
                'status', r.status, 'total', (
                  select coalesce(sum(round(round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2)
                    * (1 + case when f.vat_registered and l->>'vat_treatment' = 'standard' then private.vat_rate(r.next_run) else 0 end), 2)), 0)
                  from jsonb_array_elements(r.lines) l where not coalesce((l->>'once')::boolean, false)))
              order by r.created_at)
            from recurring_invoices r
            where r.org_id = f.id and (r.practice_client_id = c.id or (c.fee_customer_id is not null and r.customer_id = c.fee_customer_id))), '[]'::jsonb),
          'fee_bills', coalesce((
            select jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'status', x.status, 'error', x.error, 'bill_id', x.bill_id,
                'dismiss_reason', x.dismiss_reason, 'credited', coalesce(fs.credited, 0),
                'note', case when x.status = 'posted' and fs.credited > 0 then 'credited on the invoice, not on the bill' end)
              order by x.created_at desc)
            from practice_fee_bills x left join sales fs on fs.id = x.sale_id where x.client_id = c.id), '[]'::jsonb))
        order by lower(coalesce(o.name, c.business_name)), c.id)
      from practice_clients c left join orgs o on o.id = c.org_id
      where c.practice_id = p_practice and (c.status = 'active' or (c.status = 'ended' and c.fee_customer_id is not null))), '[]'::jsonb));
  if m.role = 'partner' then
    select * into w from wallets where org_id = f.id order by (rail = f.payment_rail) desc, created_at desc limit 1;
    select * into t from tax_wallets where org_id = f.id;
    v := v || jsonb_build_object('wallets', jsonb_build_object(
      'wallet', jsonb_build_object('status', w.status, 'balance', case when w.id is not null then private.wallet_ledger(w.id) else 0 end),
      'tax_wallet', jsonb_build_object('status', t.status, 'balance', case when t.id is not null then private.tax_wallet_ledger(t.id) else 0 end)));
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates are not callable by the
-- signed-in person.
revoke all on function private.void_bill_as(uuid, text, public.members), private.fee_mirror(uuid), private.fee_mirror_on_post(),
  private.fee_mirror_on_void(), private.white_label(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.practice_firm_business(uuid, jsonb), public.practice_fee_customer(uuid, jsonb),
  public.practice_fee_bill_retry(uuid), public.practice_fee_bill_dismiss(uuid, text), public.practice_fees(uuid)
  from public, anon;
grant execute on function public.practice_firm_business(uuid, jsonb), public.practice_fee_customer(uuid, jsonb),
  public.practice_fee_bill_retry(uuid), public.practice_fee_bill_dismiss(uuid, text), public.practice_fees(uuid)
  to authenticated;
