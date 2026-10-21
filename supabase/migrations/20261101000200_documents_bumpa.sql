-- Counta · Documents, and Bumpa by API
--
-- Documents is one place for every file a business has in Counta: customer invoices, receipts and credit notes (made as PDFs
-- when opened), supplier invoices and the invoices behind input VAT, stock received, the VAT, WHT and CIT files Counta made,
-- the accountant's versions, what Flux sent back after filing (acknowledgements, evidence, PRNs, receipts), and files people
-- upload straight into it. Nothing is copied: each file stays where it was saved, and Documents lists it by year, month,
-- kind and folder, for the people whose role may see that kind of file. The page downloads one file or a folder as a zip.
--
-- Folders (the tree the page shows):
--   <year> / <month> / Sales      / Invoices · Receipts · Till receipts (one PDF a day) · Credit notes · Quotes · Orders · Delivery proofs
--                      Purchases  / Supplier invoices · From suppliers · Claim input VAT · Stock received · Supplier credit notes · Import entries
--                      Tax        / VAT · WHT · Withholding VAT  /  Return files · Filing evidence · PRN and payment · Payment receipts · Accountant versions · From Flux
--                      Bank · Accountant · Other  (uploads, and the accountant's requests and financial statements)
--   <year> / Full year / Tax / CIT / ...   (what belongs to a year rather than a month)
--   No date / Company: CAC records and anything uploaded without a period
--
-- Who sees what: Sales needs record_sales or keep_books; Purchases keep_books, make_payments or receive_stock; Tax the money
-- check the storage rules use (keep_books, make_payments or see_margins) and file_tax or keep_books; Bank and Accountant
-- keep_books; Company the owner or someone who manages settings, and the CAC records (with the directors' details) the
-- owner only. A NIN slip is never listed. The storage rules say the same for files kept in Documents.
--
-- Bumpa: a store's secret API key now brings its paid orders in every five minutes, like Shopify; the CSV upload stays.

-- ---------------------------------------------------------------------------
-- 0. One-time accounts: a space between TaxStreem and the business's name. The third ₦100 check on 21 October showed
--    Flutterwave MFB keeps a space ("TaxStreem Kelandellen") where it dropped the slash and the hyphen.
-- ---------------------------------------------------------------------------
update private.config set value = ' ' where key = 'va_separator';

-- ---------------------------------------------------------------------------
-- 1. Bumpa by API: looked at by the five-minute work when it has a key
-- ---------------------------------------------------------------------------
create or replace function public.svc_integrations_due() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'provider', i.provider, 'org_id', i.org_id) order by i.last_sync_at nulls first), '[]'::jsonb)
  from integrations i where i.status in ('active', 'error')
    and (i.provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack') or (i.provider = 'bumpa' and i.secret_id is not null))
    and (i.last_sync_at is null or i.last_sync_at < now() - interval '4 minutes')
$$;
revoke all on function public.svc_integrations_due() from public, anon, authenticated;
grant execute on function public.svc_integrations_due() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-integrations';
    perform cron.schedule('counta-integrations', '*/5 * * * *', $c$select private.call_function('integrations', '{"action":"poll"}'::jsonb)
      where exists (select 1 from public.integrations where status in ('active', 'error')
        and (provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack') or (provider = 'bumpa' and secret_id is not null)))$c$);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Files uploaded straight into Documents, and files Flux sends back
-- ---------------------------------------------------------------------------
create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  cat text not null check (cat in ('sales', 'purchases', 'tax', 'bank', 'accountant', 'company', 'other')),
  folder text not null check (length(folder) between 1 and 60),
  sub text check (sub is null or length(sub) between 1 and 60),
  period date check (period is null or period = date_trunc('month', period)::date),
  year int check (year is null or year between 2000 and 2100),
  name text not null check (length(name) between 1 and 200),
  path text not null unique check (length(path) between 40 and 400),
  mime text check (mime is null or length(mime) <= 120),
  size bigint check (size is null or size between 0 and 60000000),
  source text not null default 'upload' check (source in ('upload', 'flux')),
  kind text check (kind is null or length(kind) <= 40),
  tax text check (tax is null or tax in ('vat', 'wht', 'wvat', 'cit')),
  notes text check (notes is null or length(notes) <= 500),
  uploaded_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists documents_org on public.documents(org_id, period);
create index if not exists documents_uploaded_by on public.documents(uploaded_by);
alter table public.documents enable row level security;
revoke all on public.documents from anon, authenticated;

-- What the caller may see in Documents.
create or replace function private.doc_can(m public.members) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'sales', private.perm_of(m, 'record_sales') or private.perm_of(m, 'keep_books'),
    'purchases', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'receive_stock'),
    'tax', (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'see_margins'))
      and (private.perm_of(m, 'file_tax') or private.perm_of(m, 'keep_books')),
    'bank', private.perm_of(m, 'keep_books'),
    'accountant', private.perm_of(m, 'keep_books'),
    'company', m.role = 'owner' or private.perm_of(m, 'manage_settings'),
    'other', true)
$$;

-- Folder names: the order they show in, inside their kind.
create or replace function private.doc_folder_rank(p_cat text, p_folder text) returns int
language sql immutable set search_path = '' as $$
  select coalesce(array_position(case p_cat
    when 'sales' then array['Invoices', 'Receipts', 'Till receipts', 'Credit notes', 'Quotes', 'Orders', 'Delivery proofs']
    when 'purchases' then array['Supplier invoices', 'From suppliers', 'Claim input VAT', 'Stock received', 'Supplier credit notes', 'Import entries']
    when 'tax' then array['VAT', 'WHT', 'Withholding VAT', 'CIT']
    else array[]::text[] end, p_folder), 50)
$$;

-- Every document the caller may see, between two days (undated documents when p_undated). One row a file, or one row a
-- document Counta makes when it is opened (kind 'sale', 'till' or 'prn').
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
      select 'bill:' || b.id, 'purchases', case when b.document_path like v_pre || 'vat-purchases/%' then 'Claim input VAT'
          when b.source = 'portal' or exists (select 1 from supplier_invoices si where si.bill_id = b.id) then 'From suppliers' else 'Supplier invoices' end,
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

-- ---------------------------------------------------------------------------
-- 3. The page: the tree, a folder's files, and what the PDFs are made from
-- ---------------------------------------------------------------------------
-- Every folder with its count: [{year, month (0 = the full year, null = no date), cat, folder, sub, n, bytes}].
create or replace function public.documents_tree(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return jsonb_build_object(
    'nodes', (select coalesce(jsonb_agg(jsonb_build_object('year', x.year, 'month', x.month, 'cat', x.cat, 'folder', x.folder, 'sub', x.sub, 'n', x.n, 'bytes', x.bytes)
        order by x.year desc nulls last, x.month desc nulls last, x.cat, private.doc_folder_rank(x.cat, x.folder), x.folder, x.sub nulls first), '[]'::jsonb)
      from (select r.year, case when r.period is not null then extract(month from r.period)::int when r.year is not null then 0 end as month,
              r.cat, r.folder, r.sub, count(*) as n, sum(coalesce(r.size, 0)) as bytes
            from private.doc_rows(p_org, m, date '2000-01-01', date '2100-12-31', true) r group by 1, 2, 3, 4, 5) x),
    'can', private.doc_can(m),
    'can_upload', true,
    'business', (select name from orgs where id = p_org));
end $$;

-- A folder's files (or everything under it, for a zip). p: {year (null: no date), month (1-12; 0: the full year; null: the whole
-- year), cat, folder, sub, q (words in the name, across every year), limit (up to 2000)}.
create or replace function public.documents_files(p_org uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_year int := nullif(p->>'year', '')::int; v_month int := nullif(p->>'month', '')::int;
  v_lim int := least(greatest(coalesce(nullif(p->>'limit', '')::int, 500), 1), 2000); v_q text := nullif(lower(trim(p->>'q')), '');
  v_from date; v_to date; v_rows jsonb; v_more boolean;
begin
  m := private.require(p_org, null);
  if v_q is not null or (v_year is null and not (p ? 'year')) then v_from := date '2000-01-01'; v_to := date '2100-12-31';
  elsif v_year is null then v_from := date '2100-12-31'; v_to := date '2100-12-31';
  elsif v_month between 1 and 12 then v_from := make_date(v_year, v_month, 1); v_to := (make_date(v_year, v_month, 1) + interval '1 month - 1 day')::date;
  else v_from := make_date(v_year, 1, 1); v_to := make_date(v_year, 12, 31); end if;
  with r as (
    select * from private.doc_rows(p_org, m, v_from, v_to, v_year is null or v_q is not null) d
    where (v_q is not null or not (p ? 'year') or (p ? 'year' and v_year is null and d.year is null)
           or (v_year is not null and d.year = v_year and (v_month is null or (v_month = 0 and d.period is null) or (v_month > 0 and extract(month from d.period) = v_month))))
      and (nullif(p->>'cat', '') is null or d.cat = p->>'cat')
      and (nullif(p->>'folder', '') is null or d.folder = p->>'folder')
      and (nullif(p->>'sub', '') is null or d.sub = p->>'sub')
      and (v_q is null or lower(d.name) like '%' || v_q || '%' or lower(coalesce(d.party, '')) like '%' || v_q || '%')
    order by d.day desc nulls last, d.at desc nulls last, d.name
    limit v_lim + 1)
  select coalesce(jsonb_agg(to_jsonb(r) order by r.day desc nulls last, r.at desc nulls last, r.name), '[]'::jsonb), count(*) > v_lim into v_rows, v_more from r;
  if v_more then v_rows := v_rows - v_lim; end if;
  return jsonb_build_object('files', v_rows, 'more', v_more);
end $$;

-- Sales documents to draw as PDFs, as the customer's copy shows them (at most 300 a call).
create or replace function public.documents_sales(p_org uuid, p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.doc_can(m)->>'sales')::boolean then raise exception 'Your role does not see sales documents.' using errcode = '42501'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 300 then raise exception 'Ask for at most 300 documents at a time.'; end if;
  return (select coalesce(jsonb_agg(private.sale_json(s.id, false) order by s.issue_date, s.number), '[]'::jsonb)
    from sales s where s.org_id = p_org and s.id = any(p_ids));
end $$;

-- A day's walk-in till receipts, for the day's PDF.
create or replace function public.documents_till(p_org uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.doc_can(m)->>'sales')::boolean then raise exception 'Your role does not see sales documents.' using errcode = '42501'; end if;
  return jsonb_build_object('day', p_day, 'org', private.org_brand(p_org),
    'sales', (select coalesce(jsonb_agg(jsonb_build_object('number', s.number, 'at', s.created_at, 'total', s.total, 'vat', s.vat_total, 'channel', s.channel,
        'location', (select name from locations where id = s.location_id), 'cashier', (select display_name from members where id = s.created_by),
        'paid', (select coalesce(string_agg(distinct c.method, ', '), '') from collections c where c.sale_id = s.id),
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty, 'gross', l.gross) order by l.line_no), '[]'::jsonb)
                  from sale_lines l where l.sale_id = s.id)) order by s.created_at), '[]'::jsonb)
      from sales s left join customers cu on cu.id = s.customer_id
      where s.org_id = p_org and s.issue_date = p_day and s.doc_type = 'receipt' and s.status not in ('draft', 'void', 'converted')
        and (s.customer_id is null or coalesce(cu.is_walk_in, false))));
end $$;

-- A PRN and its payment, for the slip.
create or replace function public.documents_prn(p_org uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; t public.tax_payment_instructions;
begin
  m := private.require(p_org, null);
  if not (private.doc_can(m)->>'tax')::boolean then raise exception 'Your role does not see tax documents.' using errcode = '42501'; end if;
  select * into t from tax_payment_instructions where id = p_id and org_id = p_org;
  if not found then raise exception 'That PRN is not in this business.'; end if;
  return jsonb_build_object('org', private.org_brand(p_org), 'tax', t.tax, 'period', t.period, 'accounting_year', t.accounting_year, 'authority', t.authority,
    'prn', t.prn, 'amount', t.amount, 'breakdown', t.breakdown, 'bank_name', t.bank_name, 'account_number', t.account_number, 'account_name', t.account_name,
    'resolved_name', t.resolved_name, 'status', t.status, 'received_at', t.received_at, 'confirmed_at', t.confirmed_at, 'receipt_ref', t.receipt_ref,
    'expires_at', t.expires_at, 'paid_outside', t.paid_outside,
    'payment', (select jsonb_build_object('reference', p.reference, 'status', p.status, 'completed_at', p.completed_at, 'amount', p.amount)
                from tax_payments p where p.id = t.payment_id));
end $$;

-- ---------------------------------------------------------------------------
-- 4. Uploading into Documents, and taking an upload out again
-- ---------------------------------------------------------------------------
-- After the page has stored the file: p {path, name, mime, size, cat, folder, period ('YYYY-MM' or null), year, notes}.
-- Files go under <org>/documents/<cat>/, or <org>/tax/uploads/ for tax (so the storage rules for tax files apply to them).
create or replace function public.document_save(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_cat text := coalesce(nullif(p->>'cat', ''), 'other'); v_path text := p->>'path';
  v_period date; v_year int := nullif(p->>'year', '')::int; v_folder text := nullif(left(trim(p->>'folder'), 60), ''); d public.documents;
begin
  m := private.require(p_org, null);
  if v_cat not in ('sales', 'purchases', 'tax', 'bank', 'accountant', 'company', 'other') then raise exception 'Choose what kind of document it is.'; end if;
  if coalesce((private.doc_can(m)->>v_cat)::boolean, false) is not true then raise exception 'Your role does not keep that kind of document.' using errcode = '42501'; end if;
  if v_path is null or v_path !~ ('^' || p_org::text || case when v_cat = 'tax' then '/tax/uploads/' else '/documents/' || v_cat || '/' end || '[0-9a-f-]{36}-[^/]{1,160}$') then
    raise exception 'Upload the file through Counta.';
  end if;
  if nullif(p->>'period', '') is not null then
    if p->>'period' !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'The month looks like 2026-10.'; end if;
    v_period := (p->>'period' || '-01')::date; v_year := extract(year from v_period)::int;
  end if;
  if v_cat = 'company' then v_period := null; v_year := null; end if;
  if v_folder is null then
    v_folder := case v_cat when 'sales' then 'Uploaded' when 'purchases' then 'Uploaded' when 'tax' then 'Uploaded' when 'bank' then 'Statements'
      when 'accountant' then 'Uploaded' when 'company' then 'Company files' else 'Uploaded' end;
  end if;
  if v_cat = 'tax' and v_folder not in ('VAT', 'WHT', 'Withholding VAT', 'CIT', 'Uploaded') then raise exception 'Choose VAT, WHT, withholding VAT or CIT.'; end if;
  insert into documents (org_id, cat, folder, sub, period, year, name, path, mime, size, source, notes, uploaded_by,
    tax)
  values (p_org, v_cat, v_folder, case when v_cat = 'tax' and v_folder <> 'Uploaded' then 'Uploaded' end, v_period, v_year,
    left(coalesce(nullif(trim(p->>'name'), ''), regexp_replace(v_path, '^.*/[0-9a-f-]{36}-', '')), 200), v_path,
    nullif(left(p->>'mime', 120), ''), nullif(p->>'size', '')::bigint, 'upload', nullif(left(trim(p->>'notes'), 500), ''), m.id,
    case v_folder when 'VAT' then 'vat' when 'WHT' then 'wht' when 'Withholding VAT' then 'wvat' when 'CIT' then 'cit' end)
  on conflict (path) do nothing returning * into d;
  if d.id is null then raise exception 'That file is in Documents already.'; end if;
  return jsonb_build_object('id', d.id, 'path', d.path);
end $$;

-- Only uploads come out, by whoever uploaded them or the owner. The page removes the file itself once this has said yes.
create or replace function private.document_may_delete(p_path text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from documents d join members mm on mm.org_id = d.org_id and mm.user_id = auth.uid() and mm.status = 'active'
    where d.path = p_path and d.source = 'upload' and (d.uploaded_by = mm.id or mm.role = 'owner'))
$$;
create or replace function public.document_delete(p_org uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; d public.documents;
begin
  m := private.require(p_org, null);
  select * into d from documents where id = p_id and org_id = p_org;
  if not found then raise exception 'That document is not in this business.'; end if;
  if d.source <> 'upload' then raise exception 'Only uploaded files can be taken out. Counta keeps the rest with what they belong to.'; end if;
  if d.uploaded_by is distinct from m.id and m.role <> 'owner' then raise exception 'Only the person who uploaded it, or the owner, takes it out.' using errcode = '42501'; end if;
  delete from documents where id = d.id;
  return jsonb_build_object('ok', true, 'path', d.path);
end $$;

-- A file Flux sent back with a return or a payment, once the taxstreem function has stored it.
-- p {org_id, tax, period ('YYYY-MM'), year, kind, name, path, mime, size}
create or replace function public.svc_document_add(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid := (p->>'org_id')::uuid; v_tax text := nullif(p->>'tax', ''); v_kind text := coalesce(nullif(p->>'kind', ''), 'other'); d public.documents;
  v_period date := case when p->>'period' ~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then (p->>'period' || '-01')::date end; t public.tax_payment_instructions;
begin
  -- A file sent with a payment's status names its PRN; the tax and period are the PRN's.
  if v_tax is null and nullif(p->>'prn', '') is not null then
    select * into t from tax_payment_instructions where org_id = v_org and prn = p->>'prn';
    if found then
      v_tax := t.tax;
      v_period := case when t.tax = 'cit' then null else date_trunc('month', t.period)::date end;
      p := p || jsonb_build_object('year', coalesce(t.accounting_year, extract(year from t.period)::int));
    end if;
  end if;
  if v_tax is null or v_tax not in ('vat', 'wht', 'wvat', 'cit') then raise exception 'Unknown tax.'; end if;
  if coalesce(p->>'path', '') !~ ('^' || v_org::text || '/tax/flux/') then raise exception 'Flux files are stored under the business''s tax/flux folder.'; end if;
  insert into documents (org_id, cat, folder, sub, period, year, name, path, mime, size, source, kind, tax)
  values (v_org, 'tax', case v_tax when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' else 'CIT' end,
    case v_kind when 'acknowledgement' then 'Filing evidence' when 'filing_evidence' then 'Filing evidence' when 'assessment' then 'Filing evidence'
      when 'prn' then 'PRN and payment' when 'payment_receipt' then 'Payment receipts' when 'tax_clearance' then 'Payment receipts' else 'From Flux' end,
    case when v_tax = 'cit' then null else v_period end,
    coalesce(nullif(p->>'year', '')::int, extract(year from v_period)::int),
    left(coalesce(nullif(trim(p->>'name'), ''), 'Flux file'), 200), p->>'path', nullif(left(p->>'mime', 120), ''), nullif(p->>'size', '')::bigint,
    'flux', left(v_kind, 40), v_tax)
  on conflict (path) do update set name = excluded.name, mime = excluded.mime, size = excluded.size, kind = excluded.kind
  returning * into d;
  return jsonb_build_object('id', d.id, 'folder', d.folder, 'sub', d.sub);
end $$;

-- Files kept straight in Documents (<org>/documents/<kind>/...) are read and added only by the roles that see that kind.
create or replace function private.doc_cat_ok_text(p_org text, p_cat text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select (private.doc_can(m)->>p_cat)::boolean from public.members m
    where m.org_id::text = p_org and m.user_id = auth.uid() and m.status = 'active' limit 1), false)
$$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    -- The rules from 23 October, with the one for files kept in Documents added.
    drop policy if exists "documents read by members" on storage.objects;
    create policy "documents read by members" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'documents' or (select private.doc_cat_ok_text((storage.foldername(name))[1], (storage.foldername(name))[3]))));
    drop policy if exists "documents upload by members" on storage.objects;
    create policy "documents upload by members" on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'documents' or (select private.doc_cat_ok_text((storage.foldername(name))[1], (storage.foldername(name))[3]))));
    drop policy if exists "documents uploads removed by uploader" on storage.objects;
    create policy "documents uploads removed by uploader" on storage.objects for delete to authenticated
      using (bucket_id = 'documents' and (storage.foldername(name))[2] in ('documents', 'tax') and (select private.document_may_delete(name)));
  end if;
end $$;

-- The hosts Flux may link its files from, set in the admin portal (Keys and services, TaxStreem). The list as of 31 October,
-- with that one added.
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
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('FLUX_FILE_HOSTS', 'taxstreem', 'Flux file hosts', false, 'Other hosts Flux''s file links may point to, comma separated, such as files.taxstreem.com. Links on the Flux address itself are always allowed. Leave empty if Flux sends files only from there.', 805),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903)
$$;


-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.doc_can(public.members), private.doc_folder_rank(text, text),
  private.doc_rows(uuid, public.members, date, date, boolean) from public, anon, authenticated;
revoke execute on function private.document_may_delete(text), private.doc_cat_ok_text(text, text) from public, anon;
grant execute on function private.document_may_delete(text), private.doc_cat_ok_text(text, text) to authenticated;
revoke all on function public.documents_tree(uuid), public.documents_files(uuid, jsonb), public.documents_sales(uuid, uuid[]), public.documents_till(uuid, date),
  public.documents_prn(uuid, uuid), public.document_save(uuid, jsonb), public.document_delete(uuid, uuid) from public, anon;
grant execute on function public.documents_tree(uuid), public.documents_files(uuid, jsonb), public.documents_sales(uuid, uuid[]), public.documents_till(uuid, date),
  public.documents_prn(uuid, uuid), public.document_save(uuid, jsonb), public.document_delete(uuid, uuid) to authenticated;
revoke all on function public.svc_document_add(jsonb) from public, anon, authenticated;
grant execute on function public.svc_document_add(jsonb) to service_role;
