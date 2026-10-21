-- Counta, 30 October 2026: supplier invoices.
--
-- 1. Every business has an invoice portal: a link its suppliers open to upload an invoice (PDF or photo), with no account.
--    People in the business can upload invoices too, from Bills. Either way Counta reads the invoice, finds the supplier
--    (or adds a profile for it), writes a draft bill and checks the invoice: the arithmetic, the VAT (rate, amount, and VAT
--    on exempt or zero-rated items), the address, the Tax ID (and that the NRS has it under the supplier's name), the bank
--    account (and whose name the bank holds it in), the buyer, the invoice number and date, and duplicates.
-- 2. What is wrong goes to the supplier by email (or WhatsApp) on its own, when the business allows it. The business
--    approves the invoice for payment, or rejects it with a notice to the supplier.
-- 3. Payment holds (TaxStreem, 20 October 2026). A bill with withholding tax is not paid until the supplier's Tax ID is on
--    file and checked (as before; a Tax ID on file from earlier invoices is enough). A bill from a Nigerian enterprise (a
--    company, business name, partnership or NGO) is not paid until the supplier's address is on file, from the invoice or
--    from earlier. Other problems are flagged and do not stop payment.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists invoice_portal_token text;
alter table public.orgs add column if not exists invoice_portal_on boolean not null default true;
alter table public.orgs add column if not exists invoice_notices boolean not null default true;
update public.orgs set invoice_portal_token = encode(extensions.gen_random_bytes(16), 'hex') where invoice_portal_token is null;
alter table public.orgs alter column invoice_portal_token set default encode(extensions.gen_random_bytes(16), 'hex');
create unique index if not exists orgs_invoice_portal_token on public.orgs(invoice_portal_token);
comment on column public.orgs.invoice_notices is 'Problems found on a supplier''s invoice go to the supplier by email or WhatsApp on their own.';

alter table public.bills drop constraint if exists bills_source_check;
alter table public.bills add constraint bills_source_check check (source in ('manual', 'receipt', 'prism', 'ai', 'import', 'landed_cost', 'supplier', 'bulk'));

create table if not exists public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  source text not null check (source in ('portal', 'upload')),
  status text not null default 'reading' check (status in ('reading', 'review', 'approved', 'rejected', 'failed')),
  document_path text not null,
  mime text,
  file_name text,
  file_size int,
  file_sha256 text,
  submitted_by uuid references public.members(id) on delete set null,
  submitter jsonb not null default '{}'::jsonb,
  extract jsonb,
  model text,
  checks jsonb not null default '[]'::jsonb,
  blocks int not null default 0,
  vendor_id uuid references public.vendors(id) on delete set null,
  vendor_created boolean not null default false,
  bill_id uuid references public.bills(id) on delete set null,
  bank_resolved_name text,
  notice_status text not null default 'none' check (notice_status in ('none', 'sent', 'skipped', 'off', 'no_contact')),
  notice_message_id uuid references public.messages(id) on delete set null,
  notice_at timestamptz,
  decided_by uuid references public.members(id) on delete set null,
  decided_at timestamptz,
  rejected_reason text,
  error text,
  ip_hash text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create unique index if not exists supplier_invoices_number on public.supplier_invoices(org_id, number);
create index if not exists supplier_invoices_org on public.supplier_invoices(org_id, created_at desc);
create index if not exists supplier_invoices_bill on public.supplier_invoices(bill_id) where bill_id is not null;
create index if not exists supplier_invoices_vendor on public.supplier_invoices(vendor_id) where vendor_id is not null;
create index if not exists supplier_invoices_sha on public.supplier_invoices(org_id, file_sha256) where file_sha256 is not null;
create index if not exists supplier_invoices_ip on public.supplier_invoices(ip_hash, created_at) where ip_hash is not null;
create index if not exists supplier_invoices_submitted_by on public.supplier_invoices(submitted_by) where submitted_by is not null;
create index if not exists supplier_invoices_decided_by on public.supplier_invoices(decided_by) where decided_by is not null;
create index if not exists supplier_invoices_notice on public.supplier_invoices(notice_message_id) where notice_message_id is not null;
alter table public.supplier_invoices enable row level security;
drop policy if exists supplier_invoices_read on public.supplier_invoices;
create policy supplier_invoices_read on public.supplier_invoices for select to authenticated
  using ((select private.is_member_text(org_id::text)) and (select private.can_handle_money_text(org_id::text)));
revoke insert, update, delete on public.supplier_invoices from anon, authenticated;

alter table public.messages add column if not exists supplier_invoice_id uuid references public.supplier_invoices(id) on delete set null;
alter table public.messages drop constraint if exists messages_template_check;
alter table public.messages add constraint messages_template_check
  check (template in ('document', 'reminder', 'receipt', 'statement', 'order', 'custom', 'bill_returned', 'invite', 'alert', 'invoice_issues'));
create index if not exists messages_supplier_invoice on public.messages(supplier_invoice_id) where supplier_invoice_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Payment holds: the Tax ID (where WHT applies) and, for enterprises, the address
-- ---------------------------------------------------------------------------
-- A Nigerian enterprise: a company, business name, partnership or NGO. Individuals and government bodies are not.
create or replace function private.vendor_is_enterprise(v public.vendors) returns boolean
language sql immutable set search_path = public as $$
  select coalesce(v.resident, true) and not coalesce(v.is_individual, false)
    and (v.entity_type in ('company', 'plc', 'llp', 'ltd_gte', 'business_name', 'sole_proprietor', 'partnership', 'lp', 'ngo')
         or (v.entity_type is null and nullif(trim(coalesce(v.rc_number, '')), '') is not null))
$$;

create or replace function private.bill_tin_hold(p_bill uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    case
      when not coalesce(v.resident, true) then null
      when not exists (select 1 from bill_lines l where l.bill_id = b.id and l.wht > 0 and coalesce(l.wht_category, b.wht_category, '') <> 'compensation') then null
      when private.clean_tax_id(v.tin) is null then 'no_tin'
      when v.tin_status in ('verified', 'confirmed') then null
      when v.tin_status = 'mismatch' then 'tin_mismatch'
      when v.tin_status = 'not_found' then 'tin_not_found'
      else 'tin_unchecked' end,
    case when private.vendor_is_enterprise(v) and nullif(trim(coalesce(v.address, '')), '') is null then 'no_address' end)
  from bills b join vendors v on v.id = b.vendor_id where b.id = p_bill
$$;

create or replace function private.tin_hold_text(p_reason text, p_vendor text, p_bill text) returns text
language sql immutable set search_path = public as $$
  select case p_reason
    when 'no_tin' then format('%s has no Tax ID. A bill with withholding tax is paid only once the supplier''s Tax ID is on record and checked with the NRS, because the WHT schedule needs it. Add it to the supplier, or send %s back for it.', p_vendor, p_bill)
    when 'tin_unchecked' then format('%s''s Tax ID has not been checked with the NRS yet. Check it before paying %s.', p_vendor, p_bill)
    when 'tin_not_found' then format('The NRS has no record of %s''s Tax ID. Correct it, or send %s back for the right one.', p_vendor, p_bill)
    when 'tin_mismatch' then format('The NRS name for %s''s Tax ID is different. Confirm it is the same business or correct the Tax ID before paying %s.', p_vendor, p_bill)
    when 'no_address' then format('%s has no address on file. A bill from a business is paid only once its address is known. Add it to the supplier, or send %s back for it.', p_vendor, p_bill)
  end
$$;

-- ---------------------------------------------------------------------------
-- 3. Reading an invoice into Counta
-- ---------------------------------------------------------------------------
-- Money as the reader gave it: "₦1,250.00", "1250", 1250.5. Null when there is no number.
create or replace function private.si_num(p jsonb) returns numeric
language sql immutable set search_path = public, private as $$
  select case when p is null or jsonb_typeof(p) = 'null' then null
    when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
    else private.num(regexp_replace(p #>> '{}', '[^0-9.\-]', '', 'g')) end
$$;

create or replace function private.si_text(p text, n int) returns text
language sql immutable set search_path = public as $$
  select nullif(left(trim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), n), '')
$$;

-- The account number digits, when there are ten of them.
create or replace function private.si_nuban(p text) returns text
language sql immutable set search_path = public as $$
  select case when regexp_replace(coalesce(p, ''), '\D', '', 'g') ~ '^[0-9]{10}$' then regexp_replace(p, '\D', '', 'g') end
$$;

-- The supplier the invoice is from: its Tax ID, RC number, bank account, email, phone, then its name.
create or replace function private.si_find_vendor(p_org uuid, s jsonb, b jsonb) returns uuid
language plpgsql stable security definer set search_path = public, private as $$
declare v_id uuid; v_tin text := private.clean_tax_id(s->>'tax_id'); v_rc text := regexp_replace(coalesce(s->>'rc_number', ''), '\D', '', 'g');
  v_acct text := private.si_nuban(b->>'account_number'); v_mail text := lower(nullif(trim(s->>'email'), ''));
  v_name text := private.si_text(s->>'name', 160);
begin
  if v_tin is not null then
    select id into v_id from vendors where org_id = p_org and private.clean_tax_id(tin) = v_tin order by created_at limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  if v_rc <> '' then
    select id into v_id from vendors where org_id = p_org and regexp_replace(coalesce(rc_number, ''), '\D', '', 'g') = v_rc order by created_at limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  if v_name is not null then
    select id into v_id from vendors where org_id = p_org and (lower(name) = lower(v_name) or private.same_taxpayer(name, v_name))
    order by (lower(name) = lower(v_name)) desc, created_at limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  if v_acct is not null then
    select id into v_id from vendors where org_id = p_org and account_number = v_acct order by created_at limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  -- An email address alone is not enough (an accountant may send for several suppliers): the name must agree too, or be missing.
  if v_mail is not null then
    select id into v_id from vendors where org_id = p_org and lower(email) = v_mail
      and (v_name is null or exists (select 1 from unnest(private.taxpayer_words(name)) w where w = any(private.taxpayer_words(v_name))))
    order by created_at limit 1;
  end if;
  return v_id;
end $$;

create or replace function private.si_entity(p text) returns text
language sql immutable set search_path = public as $$
  select case lower(coalesce(p, ''))
    when 'company' then 'company' when 'business_name' then 'business_name' when 'partnership' then 'partnership'
    when 'individual' then 'individual' when 'government' then 'government' when 'ngo' then 'ngo' when 'foreign' then 'company' end
$$;

-- The checks, worked out from what the invoice says, the draft bill and the supplier's record.
create or replace function private.si_checks(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare si public.supplier_invoices; x jsonb; s jsonb; bk jsonb; buyer jsonb; o public.orgs; v public.vendors; b public.bills; c jsonb := '[]'::jsonb;
  ln jsonb; i int := 0; v_qty numeric; v_up numeric; v_amt numeric; v_sum numeric := 0; v_sub numeric; v_disc numeric; v_vat numeric; v_other numeric;
  v_total numeric; v_rate numeric; v_vr numeric; v_vatable numeric := 0; v_exempt text[] := '{}'; v_tin text; v_day date; v_today date; v_hold text;
  v_lines_ok boolean := true; v_acct text; v_name text;
begin
  select * into si from supplier_invoices where id = p_id;
  x := coalesce(si.extract, '{}'::jsonb); s := coalesce(x->'supplier', '{}'::jsonb); bk := coalesce(x->'bank', '{}'::jsonb); buyer := coalesce(x->'buyer', '{}'::jsonb);
  select * into o from orgs where id = si.org_id;
  select * into v from vendors where id = si.vendor_id;
  select * into b from bills where id = si.bill_id;
  v_today := private.local_day(si.org_id, now());
  v_name := coalesce(v.name, private.si_text(s->>'name', 160), 'The supplier');

  -- What the document is.
  if coalesce((x->>'is_invoice')::boolean, true) = false then
    c := c || jsonb_build_object('code', 'not_invoice', 'severity', 'block', 'notify', true,
      'text', 'This does not look like an invoice' || coalesce(' (it reads as a ' || replace(nullif(x->>'document_kind', ''), '_', ' ') || ')', '') || '. Send the invoice itself.');
  end if;
  if private.si_text(s->>'name', 160) is null and jsonb_array_length(coalesce(x->'lines', '[]'::jsonb)) = 0 then
    c := c || jsonb_build_object('code', 'unreadable', 'severity', 'block', 'notify', true, 'text', 'Counta could not read the supplier or any items on this file. Send a clearer copy.');
  end if;
  -- The same invoice again.
  if b.id is not null and b.vendor_ref is not null and exists (select 1 from bills ob where ob.org_id = si.org_id and ob.vendor_id = b.vendor_id and ob.id <> b.id
       and lower(ob.vendor_ref) = lower(b.vendor_ref) and ob.status <> 'void') then
    c := c || jsonb_build_object('code', 'duplicate', 'severity', 'block', 'notify', true,
      'text', format('Invoice %s from %s is already in Counta.', b.vendor_ref, v_name));
  elsif si.file_sha256 is not null and exists (select 1 from supplier_invoices o2 where o2.org_id = si.org_id and o2.id <> si.id and o2.file_sha256 = si.file_sha256
       and o2.status not in ('rejected', 'failed') and o2.created_at < si.created_at) then
    c := c || jsonb_build_object('code', 'duplicate', 'severity', 'block', 'notify', true, 'text', 'This file was sent before.');
  end if;
  -- Number and date.
  if private.si_text(x->>'invoice_no', 60) is null then
    c := c || jsonb_build_object('code', 'no_invoice_no', 'severity', 'warn', 'notify', true, 'text', 'The invoice has no invoice number.');
  end if;
  begin v_day := nullif(x->>'invoice_date', '')::date; exception when others then v_day := null; end;
  if v_day is null then
    c := c || jsonb_build_object('code', 'no_date', 'severity', 'warn', 'notify', true, 'text', 'The invoice has no date.');
  elsif v_day > v_today then
    c := c || jsonb_build_object('code', 'future_date', 'severity', 'warn', 'notify', true, 'text', format('The invoice is dated %s, in the future.', to_char(v_day, 'FMDD Mon YYYY')));
  end if;

  -- The arithmetic, line by line and in total.
  for ln in select value from jsonb_array_elements(coalesce(x->'lines', '[]'::jsonb)) loop
    i := i + 1;
    v_qty := private.si_num(ln->'qty'); v_up := private.si_num(ln->'unit_price'); v_amt := private.si_num(ln->'amount');
    if v_qty is not null and v_up is not null and v_amt is not null and abs(round(v_qty * v_up, 2) - v_amt) >= 1 then
      v_lines_ok := false;
      c := c || jsonb_build_object('code', 'arith_line', 'severity', 'warn', 'notify', true, 'line', i,
        'text', format('Line %s (%s): %s × %s is %s, not %s.', i, coalesce(private.si_text(ln->>'description', 60), 'item'), case when v_qty = trunc(v_qty) then to_char(v_qty, 'FM999,999,999,990') else trim_scale(v_qty)::text end,
          private.naira(v_up), private.naira(round(v_qty * v_up, 2)), private.naira(v_amt)));
    end if;
    v_amt := coalesce(case when v_qty is not null and v_up is not null then round(v_qty * v_up, 2) end, v_amt, 0);
    v_sum := v_sum + v_amt;
    if coalesce(ln->>'vat_treatment', 'standard') in ('exempt', 'zero') then
      v_exempt := v_exempt || coalesce(private.si_text(ln->>'description', 60), 'line ' || i);
    else
      v_vatable := v_vatable + v_amt;
    end if;
  end loop;
  v_sub := private.si_num(x->'subtotal'); v_disc := coalesce(private.si_num(x->'discount'), 0); v_vat := private.si_num(x->'vat_amount');
  v_other := coalesce(private.si_num(x->'other_charges'), 0); v_total := private.si_num(x->'total');
  if i > 0 and v_sub is not null and abs(v_sum - v_sub) >= 1 then
    c := c || jsonb_build_object('code', 'arith_subtotal', 'severity', 'warn', 'notify', true,
      'text', format('The lines add up to %s, but the subtotal shows %s.', private.naira(v_sum), private.naira(v_sub)));
  end if;
  if v_total is not null and coalesce(v_sub, case when i > 0 then v_sum end) is not null
     and abs(coalesce(v_sub, v_sum) - v_disc + coalesce(v_vat, 0) + v_other - v_total) >= 1 and not coalesce((x->>'prices_include_vat')::boolean, false) then
    c := c || jsonb_build_object('code', 'arith_total', 'severity', 'warn', 'notify', true,
      'text', format('The subtotal%s%s%s comes to %s, but the total shows %s.', case when v_disc > 0 then ' less the discount' end,
        case when coalesce(v_vat, 0) > 0 then ' plus VAT' end, case when v_other > 0 then ' and other charges' end,
        private.naira(coalesce(v_sub, v_sum) - v_disc + coalesce(v_vat, 0) + v_other), private.naira(v_total)));
  end if;

  -- VAT: the rate, the amount, VAT on exempt or zero-rated items, and VAT without a Tax ID.
  v_vr := private.vat_rate(coalesce(v_day, v_today));
  v_rate := private.si_num(x->'vat_rate');
  v_tin := private.clean_tax_id(s->>'tax_id');
  if coalesce(v_vat, 0) > 0 or coalesce((x->>'vat_shown')::boolean, false) then
    if v_rate is not null and abs(v_rate - v_vr * 100) >= 0.01 then
      c := c || jsonb_build_object('code', 'vat_rate', 'severity', 'warn', 'notify', true,
        'text', format('VAT is charged at %s%%. The rate is %s%%.', trim_scale(round(v_rate, 2))::text, trim_scale(round(v_vr * 100, 2))::text));
    end if;
    if v_vat is not null and not coalesce((x->>'prices_include_vat')::boolean, false) and abs(round((v_vatable - least(v_disc, v_vatable)) * v_vr, 2) - v_vat) >= 1 then
      c := c || jsonb_build_object('code', 'vat_amount', 'severity', 'warn', 'notify', true,
        'text', format('VAT should be %s (%s%% of %s), but the invoice shows %s.', private.naira(round((v_vatable - least(v_disc, v_vatable)) * v_vr, 2)),
          trim_scale(round(v_vr * 100, 2))::text, private.naira(v_vatable - least(v_disc, v_vatable)), private.naira(v_vat)));
    end if;
    -- VAT on items the Act exempts or zero-rates: a line that carries VAT, an invoice whose items are all exempt, or VAT worked
    -- out on the whole invoice rather than on the VATable part.
    if cardinality(v_exempt) > 0 and (v_vatable = 0
         or exists (select 1 from jsonb_array_elements(coalesce(x->'lines', '[]'::jsonb)) l
                    where coalesce(l->>'vat_treatment', '') in ('exempt', 'zero') and coalesce(private.si_num(l->'vat'), 0) > 0)
         or (v_vat is not null and abs(round((v_sum - v_disc) * v_vr, 2) - v_vat) < 1 and abs(round((v_vatable - least(v_disc, v_vatable)) * v_vr, 2) - v_vat) >= 1)) then
      c := c || jsonb_build_object('code', 'vat_on_exempt', 'severity', 'warn', 'notify', true,
        'text', format('VAT is charged on %s, which %s exempt or zero-rated under the Nigeria Tax Act 2025.', array_to_string(v_exempt[1:4], ', '),
          case when cardinality(v_exempt) = 1 then 'is' else 'are' end));
    end if;
    if v_tin is null and private.clean_tax_id(v.tin) is null then
      c := c || jsonb_build_object('code', 'vat_no_tin', 'severity', 'warn', 'notify', true,
        'text', 'VAT is charged, but the invoice shows no Tax ID. Only a business registered with the NRS charges VAT, and the VAT cannot be claimed without it.');
    end if;
  end if;

  -- Tax ID: on the invoice, on file, and as the NRS has it.
  v_hold := case when b.id is not null and b.status in ('draft', 'approved', 'partially_paid') then private.bill_tin_hold(b.id) end;
  if coalesce(v.resident, s->>'entity_kind' is distinct from 'foreign') then
    if v_tin is null then
      if v_hold = 'no_tin' then
        c := c || jsonb_build_object('code', 'tin_missing', 'severity', 'block', 'notify', true,
          'text', 'The invoice has no Tax ID and none is on file. Withholding tax applies, so it cannot be paid until the Tax ID is known (taxid.nrs.gov.ng).');
      elsif private.clean_tax_id(v.tin) is not null then
        c := c || jsonb_build_object('code', 'tin_missing', 'severity', 'warn', 'notify', true,
          'text', 'The invoice does not show the supplier''s Tax ID. The one on file is used; please print it on invoices.');
      else
        c := c || jsonb_build_object('code', 'tin_missing', 'severity', 'warn', 'notify', true,
          'text', 'The invoice has no Tax ID. Please send it (taxid.nrs.gov.ng) and print it on invoices.');
      end if;
    elsif private.clean_tax_id(v.tin) is not null and private.clean_tax_id(v.tin) <> v_tin then
      c := c || jsonb_build_object('code', 'tin_differs', 'severity', 'warn', 'notify', false,
        'text', format('The Tax ID on the invoice (%s) differs from the one on file for %s (%s).', v_tin, v_name, v.tin));
    end if;
    if v.tin_status = 'mismatch' then
      c := c || jsonb_build_object('code', 'tin_mismatch', 'severity', case when v_hold = 'tin_mismatch' then 'block' else 'warn' end, 'notify', true,
        'text', format('The NRS has the Tax ID %s under %s, not %s.', v.tin, coalesce(v.tin_check->>'taxpayer_name', 'another name'), v_name));
    elsif v.tin_status = 'not_found' then
      c := c || jsonb_build_object('code', 'tin_not_found', 'severity', case when v_hold = 'tin_not_found' then 'block' else 'warn' end, 'notify', true,
        'text', format('The NRS has no record of the Tax ID %s.', v.tin));
    elsif v_hold = 'tin_unchecked' then
      c := c || jsonb_build_object('code', 'tin_unchecked', 'severity', 'block', 'notify', false,
        'text', format('%s''s Tax ID has not been checked with the NRS yet. Check it on the supplier before paying.', v_name));
    end if;
  end if;

  -- Address.
  if v_hold = 'no_address' or (v.id is not null and private.vendor_is_enterprise(v) and nullif(trim(coalesce(v.address, '')), '') is null) then
    c := c || jsonb_build_object('code', 'address_missing', 'severity', 'block', 'notify', true,
      'text', 'The invoice has no address for the business and none is on file. It cannot be paid until the address is known.');
  elsif private.si_text(s->>'address', 300) is null and v.id is not null and private.vendor_is_enterprise(v) then
    c := c || jsonb_build_object('code', 'address_not_printed', 'severity', 'warn', 'notify', true,
      'text', 'The invoice does not show the business''s address. The one on file is used; please print it on invoices.');
  end if;

  -- Bank account.
  v_acct := private.si_nuban(bk->>'account_number');
  if v_acct is null and v.account_number is null then
    c := c || jsonb_build_object('code', 'bank_missing', 'severity', 'warn', 'notify', true,
      'text', 'The invoice has no bank account for payment. Please send the account number, bank and account name.');
  elsif v_acct is not null and v.account_number is not null and v.account_number <> v_acct then
    c := c || jsonb_build_object('code', 'bank_changed', 'severity', 'warn', 'notify', false,
      'text', format('The account on the invoice (%s, %s) is not the one on file for %s (%s, %s). Confirm the change with the supplier before paying.',
        v_acct, coalesce(nullif(bk->>'bank_name', ''), 'bank not shown'), v_name, v.account_number, coalesce(v.bank_name, 'bank not shown')));
  end if;
  if v_acct is not null and si.bank_resolved_name is not null and not private.same_taxpayer(si.bank_resolved_name, v_name)
     and not private.same_taxpayer(si.bank_resolved_name, coalesce(bk->>'account_name', '')) then
    c := c || jsonb_build_object('code', 'bank_name', 'severity', 'warn', 'notify', false,
      'text', format('The bank holds account %s in the name %s, not %s.', v_acct, si.bank_resolved_name, v_name));
  elsif v_acct is not null and si.bank_resolved_name is not null and not private.same_taxpayer(si.bank_resolved_name, v_name) then
    c := c || jsonb_build_object('code', 'bank_name', 'severity', 'warn', 'notify', false,
      'text', format('The bank holds account %s in the name %s, which is not %s.', v_acct, si.bank_resolved_name, v_name));
  end if;

  -- Who it is addressed to.
  if private.si_text(buyer->>'name', 160) is not null and not private.same_taxpayer(buyer->>'name', o.name)
     and not (private.clean_tax_id(buyer->>'tax_id') is not null and private.clean_tax_id(buyer->>'tax_id') = private.clean_tax_id(o.tin)) then
    c := c || jsonb_build_object('code', 'buyer_mismatch', 'severity', 'warn', 'notify', true,
      'text', format('The invoice is addressed to %s, not %s.', private.si_text(buyer->>'name', 160), o.name));
  end if;
  if nullif(upper(x->>'currency'), '') is not null and upper(x->>'currency') <> 'NGN' then
    c := c || jsonb_build_object('code', 'currency', 'severity', 'info', 'notify', false, 'text', format('The invoice is in %s.', upper(x->>'currency')));
  end if;
  return c;
end $$;

-- Writes what Counta read: the supplier (found, filled in, or added), the draft bill and the checks.
create or replace function private.si_apply(p_id uuid, p_extract jsonb, p_model text, p_resolved text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; o public.orgs; m public.members; s jsonb; bk jsonb; v public.vendors; v_vendor uuid; v_new boolean := false; x jsonb;
  ln jsonb; v_lines jsonb := '[]'::jsonb; v_code text; v_treat text; v_qty numeric; v_up numeric; v_amt numeric; b public.bills; v_checks jsonb;
  v_day date; v_due date; v_state text; v_addr text; v_tin text; v_acct text; v_wht text; v_entity text; v_mail text; v_phone text; v_vat boolean;
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
    v_lines := v_lines || jsonb_build_object('description', private.si_text(ln->>'description', 300), 'qty', v_qty, 'unit_cost', v_up, 'account_code', v_code,
      'vat_treatment', v_treat, 'ai_confidence', least(greatest(coalesce(private.num(x->>'confidence'), 70) / 100, 0), 1));
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
    'submitted_by_name', (select display_name from members where id = si.submitted_by),
    'decided_by_name', (select display_name from members where id = si.decided_by))
  from supplier_invoices si where si.id = p_id
$$;

-- Where to write to the supplier: the person who sent the invoice (email, else WhatsApp), else the supplier on file.
create or replace function private.si_contact(p_sub jsonb, v public.vendors, out channel text, out address text)
language plpgsql immutable set search_path = public, private as $$
declare e text;
begin
  for e in select x from unnest(array[lower(trim(p_sub->>'email')), 'phone:' || coalesce(private.clean_phone(p_sub->>'phone'), ''),
                                      lower(trim(v.email)), 'phone:' || coalesce(private.clean_phone(v.phone), '')]) x loop
    if e like 'phone:%' then
      if length(substr(e, 7)) >= 11 then channel := 'whatsapp'; address := substr(e, 7); return; end if;
    elsif e ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then channel := 'email'; address := e; return; end if;
  end loop;
end $$;

-- Tells the supplier what is wrong, once, by email (else WhatsApp), when the business allows it.
create or replace function private.si_notify(p_id uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; o public.orgs; v public.vendors; v_to text; v_ch text; v_issues text[]; msg public.messages; v_ref text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if si.notice_status = 'sent' then return 'sent'; end if;
  select * into o from orgs where id = si.org_id;
  select * into v from vendors where id = si.vendor_id;
  select array_agg(c->>'text' order by case c->>'severity' when 'block' then 0 else 1 end) into v_issues
  from jsonb_array_elements(si.checks) c where (c->>'notify')::boolean and c->>'severity' in ('block', 'warn');
  if coalesce(cardinality(v_issues), 0) = 0 then update supplier_invoices set notice_status = 'none' where id = si.id; return 'none'; end if;
  if not o.invoice_notices or o.is_sample then update supplier_invoices set notice_status = 'off' where id = si.id; return 'off'; end if;
  select r.channel, r.address into v_ch, v_to from private.si_contact(si.submitter, v) r;
  if v_to is null then update supplier_invoices set notice_status = 'no_contact' where id = si.id; return 'no_contact'; end if;
  v_ref := left(coalesce(nullif(trim(regexp_replace(si.extract->>'invoice_no', '[[:cntrl:]\s]+', ' ', 'g')), ''), si.number), 60);
  begin
    msg := private.queue_message(si.org_id, v_ch, v_to, 'invoice_issues', 'Your invoice ' || v_ref || ' to ' || o.name || ' needs a look',
      jsonb_build_object('customer_name', coalesce(nullif(trim(si.submitter->>'name'), ''), v.name), 'business', o.name, 'number', v_ref,
        'total', private.si_num(si.extract->'total'), 'issues', to_jsonb(v_issues[1:8]), 'reference', si.number), null, null, si.submitted_by);
  exception when others then
    update supplier_invoices set notice_status = 'skipped', error = left(sqlerrm, 300) where id = si.id;
    return 'skipped';
  end;
  update messages set vendor_id = v.id, bill_id = si.bill_id, supplier_invoice_id = si.id where id = msg.id;
  update supplier_invoices set notice_status = 'sent', notice_message_id = msg.id, notice_at = now() where id = si.id;
  return 'sent';
end $$;

-- ---------------------------------------------------------------------------
-- 4. The portal (anyone with the link) and uploads from the business
-- ---------------------------------------------------------------------------
-- What the supplier sees on the upload page. Nothing private.
create or replace function public.invoice_portal(p_token text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('business', o.name, 'logo_path', o.logo_path, 'brand_color', o.brand_color,
    'open', o.invoice_portal_on and not o.is_sample and private.feature_on(o.id, 'supplier_portal'),
    'sample', o.is_sample)
  from orgs o where o.invoice_portal_token = p_token and p_token ~ '^[0-9a-f]{32}$'
$$;

-- The edge function opens the record before reading: the portal checks the link, the business allows it and the sender is
-- not sending too many.
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
    'wht', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort) from wht_rates where not exemption and code <> 'none'));
end $$;

-- The reader's answer: everything above, then the notice to the supplier.
create or replace function public.svc_si_read(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; r jsonb;
begin
  select * into si from supplier_invoices where id = p_id;
  if not found then raise exception 'Invoice not found.'; end if;
  if p ? 'path' then update supplier_invoices set document_path = p->>'path', file_size = coalesce(nullif(p->>'file_size', '')::int, file_size),
    file_sha256 = coalesce(nullif(p->>'sha256', ''), file_sha256), mime = coalesce(private.si_text(p->>'mime', 60), mime) where id = si.id; end if;
  if p ? 'error' then
    update supplier_invoices set status = 'failed', error = left(p->>'error', 500), read_at = now() where id = si.id;
    perform private.notify_perm(si.org_id, 'keep_books', 'bill', 'An invoice could not be read: ' || si.number, left(p->>'error', 200), '/purchases/bills?tab=invoices&open=' || si.id);
    return private.si_json(si.id);
  end if;
  r := private.si_apply(si.id, p->'extract', p->>'model', p->>'bank_resolved_name');
  return r || jsonb_build_object('tin_check', (select case when v.id is not null and coalesce(v.resident, true) and private.clean_tax_id(v.tin) is not null and v.tin_status is null
      then v.id end from supplier_invoices x join vendors v on v.id = x.vendor_id where x.id = si.id));
end $$;

-- After the NRS check: the checks again, the notice and a word to the business.
create or replace function public.svc_si_finish(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; v_checks jsonb; v_notice text; v_name text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if si.status = 'review' then
    v_checks := private.si_checks(si.id);
    update supplier_invoices set checks = v_checks, blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
    v_notice := private.si_notify(si.id);
  end if;
  select name into v_name from vendors where id = si.vendor_id;
  perform private.notify_perm(si.org_id, 'keep_books', 'bill', 'Invoice to review: ' || coalesce(v_name, si.number),
    case when si.source = 'portal' then 'Uploaded on your invoice portal' else 'Read by Counta' end
      || coalesce(' · ' || nullif((select count(*)::text from jsonb_array_elements(v_checks) c where c->>'severity' in ('block', 'warn')), '0') || ' to look at', ''),
    '/purchases/bills?tab=invoices&open=' || si.id, 'si-' || si.id);
  return private.si_json(si.id) || jsonb_build_object('notice_result', v_notice);
end $$;

-- A service-level version of the Tax ID check target, for invoices from the portal (no one is signed in).
create or replace function public.svc_tin_check_target(p_org uuid, p_vendor uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.vendors; v_num text; v_channel text; v_rc text; v_id uuid;
begin
  select * into v from vendors where id = p_vendor and org_id = p_org;
  if not found then raise exception 'Vendor not found.'; end if;
  if not coalesce(v.resident, true) then raise exception '% is outside Nigeria.', v.name; end if;
  v_num := private.clean_tax_id(v.tin); v_rc := regexp_replace(coalesce(v.rc_number, ''), '\D', '', 'g');
  if v_num is not null then v_channel := 'tin'; elsif v_rc <> '' then v_channel := 'cac'; v_num := v_rc; else raise exception 'No Tax ID or RC number.'; end if;
  if (select count(*) from tin_checks where org_id = p_org and at > now() - interval '1 day') >= 60 then
    raise exception 'Counta has checked many Tax IDs for this business today.';
  end if;
  insert into tin_checks (org_id, vendor_id, number, channel) values (p_org, p_vendor, v_num, v_channel) returning id into v_id;
  return jsonb_build_object('check_id', v_id, 'kind', 'vendor', 'number', v_num, 'channel', v_channel, 'name', v.name);
end $$;

-- ---------------------------------------------------------------------------
-- 5. What the business sees and does
-- ---------------------------------------------------------------------------
create or replace function public.supplier_invoices_list(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_status text := nullif(p->>'status', '');
begin
  m := private.require(p_org, 'keep_books');
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', si.id, 'number', si.number, 'source', si.source, 'status', si.status, 'created_at', si.created_at,
        'vendor_name', coalesce(v.name, si.extract->'supplier'->>'name', si.submitter->>'name'), 'vendor_created', si.vendor_created,
        'invoice_no', si.extract->>'invoice_no', 'invoice_date', si.extract->>'invoice_date', 'total', coalesce(b.total, private.si_num(si.extract->'total')),
        'invoice_total', private.si_num(si.extract->'total'),
        'bill_id', si.bill_id, 'bill_number', b.number, 'bill_status', b.status, 'blocks', si.blocks,
        'warns', (select count(*) from jsonb_array_elements(si.checks) c where c->>'severity' = 'warn'), 'notice_status', si.notice_status,
        'error', si.error) order by si.created_at desc), '[]'::jsonb)
      from (select * from supplier_invoices where org_id = p_org and (v_status is null or status = v_status or (v_status = 'open' and status in ('reading', 'review', 'failed')))
            order by created_at desc limit least(coalesce(nullif(p->>'limit', '')::int, 100), 300)) si
      left join vendors v on v.id = si.vendor_id left join bills b on b.id = si.bill_id),
    'counts', (select jsonb_build_object('review', count(*) filter (where status = 'review'), 'reading', count(*) filter (where status = 'reading'),
        'failed', count(*) filter (where status = 'failed')) from supplier_invoices where org_id = p_org),
    'portal', (select jsonb_build_object('token', invoice_portal_token, 'on', invoice_portal_on, 'notices', invoice_notices,
      'allowed', private.feature_on(p_org, 'supplier_portal')) from orgs where id = p_org));
end $$;

create or replace function public.supplier_invoice(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members;
begin
  select * into si from supplier_invoices where id = p_id;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(si.org_id, 'keep_books');
  return private.si_json(si.id);
end $$;

-- After the supplier or the bill was put right: the checks again.
create or replace function public.recheck_supplier_invoice(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members; v_checks jsonb;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(si.org_id, 'keep_books');
  if si.status <> 'review' then raise exception '% is %.', si.number, si.status; end if;
  v_checks := private.si_checks(si.id);
  update supplier_invoices set checks = v_checks, blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
  return private.si_json(si.id);
end $$;

-- Approved for payment: the bill goes into the books. Not while anything still stops payment.
create or replace function public.approve_supplier_invoice(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members; v_checks jsonb; v_block text; b public.bills;
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
  select * into b from bills where id = si.bill_id;
  if b.status = 'draft' then perform public.approve_bill(b.id); end if;
  update supplier_invoices set status = 'approved', decided_by = m.id, decided_at = now() where id = si.id;
  return private.si_json(si.id);
end $$;

-- Rejected: the draft bill goes, and the supplier is told why (by email or WhatsApp) unless the person says not to.
create or replace function public.reject_supplier_invoice(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members; b public.bills; v public.vendors; o public.orgs; v_note text := private.si_text(p->>'reason', 1000);
  v_send boolean := coalesce((p->>'send')::boolean, true); v_to text; v_ch text; msg public.messages; v_ref text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(si.org_id, 'keep_books');
  if si.status not in ('review', 'failed') then raise exception '% is %.', si.number, si.status; end if;
  if v_note is null then raise exception 'Write why the invoice is rejected; the supplier sees it.'; end if;
  select * into b from bills where id = si.bill_id;
  select * into v from vendors where id = si.vendor_id;
  select * into o from orgs where id = si.org_id;
  if v_send then
    select r.channel, r.address into v_ch, v_to from private.si_contact(si.submitter, v) r;
    if v_to is null then raise exception 'There is no email address or WhatsApp number for the supplier. Add one to %, or reject it without telling them.', coalesce(v.name, 'the supplier'); end if;
  end if;
  if b.id is not null and b.status = 'draft' then
    perform public.return_bill(b.id, jsonb_build_object('reason', 'other', 'note', v_note));
  elsif b.id is not null and b.status = 'approved' then
    raise exception '% is already approved. Send the bill back from Bills instead.', b.number;
  end if;
  if v_send then
    v_ref := left(coalesce(nullif(trim(regexp_replace(si.extract->>'invoice_no', '[[:cntrl:]\s]+', ' ', 'g')), ''), b.vendor_ref, si.number), 60);
    msg := private.queue_message(si.org_id, v_ch, v_to, 'bill_returned', 'Invoice ' || v_ref || ' returned',
      jsonb_build_object('customer_name', coalesce(nullif(trim(si.submitter->>'name'), ''), v.name, 'there'), 'business', o.name, 'number', v_ref,
        'total', coalesce(b.total, private.si_num(si.extract->'total')), 'reason', 'other', 'note', v_note), null, null, m.id);
    update messages set vendor_id = v.id, bill_id = b.id, supplier_invoice_id = si.id where id = msg.id;
  end if;
  update supplier_invoices set status = 'rejected', rejected_reason = v_note, decided_by = m.id, decided_at = now() where id = si.id;
  return private.si_json(si.id) || jsonb_build_object('sent_to', v_to, 'sent_by', v_ch);
end $$;

-- The portal link: on or off, notices on or off, and a new link (the old one stops working).
create or replace function public.set_invoice_portal(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'keep_books');
  update orgs set invoice_portal_on = coalesce((p->>'on')::boolean, invoice_portal_on), invoice_notices = coalesce((p->>'notices')::boolean, invoice_notices),
    invoice_portal_token = case when coalesce((p->>'new_link')::boolean, false) then encode(extensions.gen_random_bytes(16), 'hex') else invoice_portal_token end
  where id = p_org;
  return (select jsonb_build_object('token', invoice_portal_token, 'on', invoice_portal_on, 'notices', invoice_notices) from orgs where id = p_org);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.vendor_is_enterprise(public.vendors), private.si_num(jsonb), private.si_text(text, int), private.si_nuban(text),
  private.si_find_vendor(uuid, jsonb, jsonb), private.si_entity(text), private.si_checks(uuid), private.si_apply(uuid, jsonb, text, text), private.si_json(uuid),
  private.si_notify(uuid), private.si_contact(jsonb, public.vendors) from public, anon, authenticated;
revoke all on function public.svc_si_open(jsonb), public.svc_si_read(uuid, jsonb), public.svc_si_finish(uuid), public.svc_tin_check_target(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_si_open(jsonb), public.svc_si_read(uuid, jsonb), public.svc_si_finish(uuid), public.svc_tin_check_target(uuid, uuid) to service_role;
revoke all on function public.supplier_invoices_list(uuid, jsonb), public.supplier_invoice(uuid), public.recheck_supplier_invoice(uuid),
  public.approve_supplier_invoice(uuid), public.reject_supplier_invoice(uuid, jsonb), public.set_invoice_portal(uuid, jsonb) from public, anon;
grant execute on function public.supplier_invoices_list(uuid, jsonb), public.supplier_invoice(uuid), public.recheck_supplier_invoice(uuid),
  public.approve_supplier_invoice(uuid), public.reject_supplier_invoice(uuid, jsonb), public.set_invoice_portal(uuid, jsonb) to authenticated;
revoke all on function public.invoice_portal(text) from public;
grant execute on function public.invoice_portal(text) to anon, authenticated;
