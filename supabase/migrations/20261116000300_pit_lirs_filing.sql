-- Counta · personal income tax, filed on the state portals by TaxStreem Flux
--
-- There is no template to fill for personal income tax on the LIRS e-tax portal: Flux's bot fills the portal's fields, so
-- Counta hands Flux each person's figures as those fields, and the documents the portal asks for.
--
-- 1. Tax portal logins. The business saves its login for NRS Rev360 and for any state revenue service under Settings.
--    The password goes straight to Flux (through the tax-files function) and is never kept in Counta: portal_logins
--    holds only which portal, a hint of the username, the tax office, Flux's reference and whether the login worked.
-- 2. What the LIRS return asks for, person by person: the statement of income (salary, commission, trade income,
--    allowance, pension, annuity, foreign income, dividend, interest, rent, other income) as Counta's taxable figures, the
--    accommodation disclosure, the pension details (RSA number, PFA), and each relief with its documents. A relief
--    entered without its documents is left out of the computation until they are attached (no document, no relief).
-- 3. The business's employees for the year and its fixed assets, for the portal's staff and assets screens.
-- 4. After filing: the pay bill Flux generates (paid by the partner or the business through its link; Counta does not
--    pay personal income tax), the payment, and the tax clearance certificate (profile picture, three years of filed
--    returns, authority to file any outstanding return).
-- Companies are not touched. Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Data
-- ---------------------------------------------------------------------------
-- Each person's year gains what the portal asks for and what follows filing.
--   accommodation:   {address, type, occupancy (tenant | owner | employer | family), landlord_name, landlord_id, landlord_address,
--                     rent_paid, rent_paid_by_employer, started_on, ended_on}
--   pension_details: {rsa_number, pfa}
--   relief_docs:     {relief: [{doc, path, name, at}]}, the documents for each relief (private.pit_relief_needs)
--   computation_path: the person's computation (PDF) as approved, made by the app when the return goes to Flux
--   bill:            the pay bill Flux generated on the portal {amount, reference, agency, revenue, payment_url, generated_at, expires_at}
--   tcc:             {photo_path, prior_returns: {year: {path, name}}, authorise_outstanding, status, ref, number, issued_at, expires_on, message, requested_at}
alter table public.pit_person_years
  add column if not exists accommodation jsonb not null default '{}'::jsonb,
  add column if not exists pension_details jsonb not null default '{}'::jsonb,
  add column if not exists relief_docs jsonb not null default '{}'::jsonb,
  add column if not exists computation_path text,
  add column if not exists bill jsonb,
  add column if not exists paid_at timestamptz,
  add column if not exists payment_ref text,
  add column if not exists tcc jsonb not null default '{}'::jsonb;

-- The business's employees for the year (for the portal's support staff screen): [{name, role, annual_pay, tin}].
alter table public.pit_years add column if not exists staff jsonb not null default '[]'::jsonb;

-- The business's logins to the tax portals. Never the password: Flux keeps that; Counta keeps Flux's reference to it.
create table if not exists public.portal_logins (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  authority text not null references public.tax_authorities(code),
  username_hint text check (username_hint is null or length(username_hint) <= 80),
  tax_office text check (tax_office is null or length(tax_office) <= 120),
  flux_ref text check (flux_ref is null or length(flux_ref) <= 200),
  status text not null default 'saved' check (status in ('saved', 'verified', 'failed')),
  message text check (message is null or length(message) <= 1000),
  saved_by uuid references public.members(id) on delete set null,
  saved_at timestamptz not null default now(),
  checked_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (org_id, authority)
);
alter table public.portal_logins enable row level security;
revoke all on public.portal_logins from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. What each relief needs before it is claimed
-- ---------------------------------------------------------------------------
-- The LIRS portal refuses a relief without its document, so Counta leaves the relief out until it has them. Pension also
-- needs the RSA number and the pension fund administrator; rent relief (2026 accounts onwards) needs the accommodation
-- disclosure of a tenant. TaxStreem's list names the pension, health insurance, life insurance and mortgage documents;
-- the NHF and gratuity statements follow the same rule.
create or replace function private.pit_relief_needs() returns jsonb
language sql immutable set search_path = '' as $$
  select '{
    "pension": {"label": "Pension contributions", "docs": [{"id": "rsa_statement", "label": "Retirement savings account (RSA) statement for the year"}], "fields": ["rsa_number", "pfa"]},
    "nhis": {"label": "Health insurance", "docs": [{"id": "policy", "label": "Health insurance policy and evidence of payment"}]},
    "life_insurance": {"label": "Life insurance or deferred annuity", "docs": [{"id": "policy", "label": "Life insurance policy and evidence of payment"}]},
    "home_loan_interest": {"label": "Mortgage interest", "docs": [{"id": "mortgage", "label": "Mortgage agreement or loan documents showing the lender and the property"},
                                                                 {"id": "interest", "label": "Statement of the mortgage interest paid"}]},
    "nhf": {"label": "National Housing Fund", "docs": [{"id": "nhf_statement", "label": "National Housing Fund contribution statement"}]},
    "gratuity": {"label": "Gratuity", "docs": [{"id": "gratuity_statement", "label": "Statement of the gratuity contributions"}]},
    "rent_paid": {"label": "Rent relief", "docs": [], "accommodation": true}
  }'::jsonb
$$;

-- The accommodation disclosure is complete: the address, the kind of home, how it is held and since when; for a tenant,
-- the landlord, their address and the rent. p_rent: also that the person rents it (for rent relief).
create or replace function private.pit_accommodation_ok(p jsonb, p_rent boolean default false) returns boolean
language sql immutable set search_path = public, private as $$
  select coalesce(trim(p->>'address'), '') <> '' and coalesce(p->>'type', '') <> '' and coalesce(p->>'occupancy', '') <> '' and coalesce(p->>'started_on', '') <> ''
    and (coalesce(p->>'occupancy', '') <> 'tenant'
         or (coalesce(trim(p->>'landlord_name'), '') <> '' and coalesce(trim(p->>'landlord_address'), '') <> '' and coalesce(private.num(p->>'rent_paid'), 0) > 0))
    and (not p_rent or p->>'occupancy' = 'tenant')
$$;

-- The reliefs a person can claim now: {claimed: {relief: amount}, held: [{relief, label, amount, missing: [what]}]}.
create or replace function private.pit_relief_check(p_reliefs jsonb, p_docs jsonb, p_pension jsonb, p_acc jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare n jsonb := private.pit_relief_needs(); k text; v numeric; need jsonb; d jsonb; miss text[]; v_claimed jsonb := '{}'::jsonb; v_held jsonb := '[]'::jsonb;
begin
  for k, v in select key, private.num(value #>> '{}') from jsonb_each(coalesce(p_reliefs, '{}'::jsonb)) loop
    continue when coalesce(v, 0) <= 0;
    need := n->k; miss := '{}';
    if need is null then v_claimed := v_claimed || jsonb_build_object(k, v); continue; end if;
    for d in select value from jsonb_array_elements(coalesce(need->'docs', '[]'::jsonb)) loop
      if not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_docs->k) = 'array' then p_docs->k else '[]'::jsonb end) f
                     where f->>'doc' = d->>'id' and coalesce(f->>'path', '') <> '') then
        miss := miss || (d->>'label');
      end if;
    end loop;
    if coalesce(need->'fields', '[]'::jsonb) ? 'rsa_number' and coalesce(trim(p_pension->>'rsa_number'), '') = '' then miss := miss || 'the RSA number'::text; end if;
    if coalesce(need->'fields', '[]'::jsonb) ? 'pfa' and coalesce(trim(p_pension->>'pfa'), '') = '' then miss := miss || 'the pension fund administrator'::text; end if;
    if coalesce((need->>'accommodation')::boolean, false) and not private.pit_accommodation_ok(coalesce(p_acc, '{}'::jsonb), true) then
      miss := miss || 'the accommodation details of a tenant (landlord, address, rent, dates)'::text;
    end if;
    if cardinality(miss) = 0 then v_claimed := v_claimed || jsonb_build_object(k, v);
    else v_held := v_held || jsonb_build_array(jsonb_build_object('relief', k, 'label', need->>'label', 'amount', v, 'missing', to_jsonb(miss))); end if;
  end loop;
  return jsonb_build_object('claimed', v_claimed, 'held', v_held);
end $$;

-- A person's income as the LIRS statement of income asks for it, from Counta's computation: the taxable figures only
-- (trade income after losses and capital allowances; income exempt or taxed in full at source left out), so the tax the
-- portal works out is the tax Counta worked out. The fields add up to total income.
create or replace function private.pit_portal_income(t jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  with l as (
    select x->>'kind' kind, coalesce(x->>'field', '') field, coalesce(private.num(x->>'amount'), 0) amt, x->>'treatment' tr, x->>'label' label
    from jsonb_array_elements(coalesce(t->'other_income', '[]'::jsonb)) x),
  s as (select
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field not in ('commission', 'allowance')), 0) salary,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field = 'commission'), 0) commission,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field = 'allowance'), 0) allowance,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'pension_gratuity' and field <> 'annuity'), 0) pension,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'pension_gratuity' and field = 'annuity'), 0) annuity,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind in ('foreign_earned', 'foreign_investment')), 0) foreign_income,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'dividend'), 0) dividend,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind in ('interest', 'gov_bond_interest')), 0) interest,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'rent'), 0) rent,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind not in ('employment', 'pension_gratuity', 'foreign_earned', 'foreign_investment', 'dividend', 'interest',
      'gov_bond_interest', 'rent')), 0) other
    from l),
  g as (select coalesce(private.num(t->'figures'->>'gains_taxed'), 0) gains)
  select jsonb_build_object(
    'fields', jsonb_build_object('salary', s.salary, 'commission', s.commission, 'trade_income', coalesce(private.num(t->'figures'->>'business_net'), 0),
      'allowance', s.allowance, 'pension', s.pension, 'annuity', s.annuity, 'foreign_income', s.foreign_income, 'dividend', s.dividend,
      'interest', s.interest, 'rent', s.rent, 'other_income', s.other + g.gains),
    'total', coalesce(private.num(t->'figures'->>'total_income'), 0),
    'other_lines', (select coalesce(jsonb_agg(jsonb_build_object('label', l.label, 'amount', l.amt)), '[]'::jsonb) from l
                    where l.tr = 'taxable' and l.kind not in ('employment', 'pension_gratuity', 'foreign_earned', 'foreign_investment', 'dividend', 'interest', 'gov_bond_interest', 'rent'))
      || case when g.gains > 0 then jsonb_build_array(jsonb_build_object('label', 'Chargeable gains on the business''s disposals', 'amount', g.gains)) else '[]'::jsonb end,
    'left_out', (select coalesce(jsonb_agg(jsonb_build_object('label', l.label, 'kind', l.kind, 'amount', l.amt, 'treatment', l.tr)), '[]'::jsonb) from l where l.tr <> 'taxable'))
  from s, g
$$;

-- ---------------------------------------------------------------------------
-- 3. Who may attach and open the documents of a person's return
-- ---------------------------------------------------------------------------
-- Each person's documents are kept under <business>/tax/pit/<year>/people/<person>/ (a pension statement, an insurance
-- policy, the profile picture for a tax clearance certificate). Whoever files the business's tax may attach and open them,
-- and so may the person, when linked to their own Counta login; those who only keep the books do not see them. The
-- computations made for the portal go under <business>/tax/pit/<year>/computation/, for whoever files tax.
create or replace function private.pit_doc_path_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public, private as $$
declare a text[]; v_org uuid; m public.members;
begin
  a := regexp_match(coalesce(p_name, ''), '^([0-9a-fA-F-]{36})/tax/pit/([0-9]{4})/(people/([0-9a-fA-F-]{36})/|computation/)');
  if a is null or p_name ~ '\.\.' then return false; end if;
  v_org := a[1]::uuid;
  select * into m from members where org_id = v_org and user_id = auth.uid() and status = 'active' limit 1;
  if m.id is null then return false; end if;
  if private.perm_of(m, 'file_tax') then return true; end if;
  if a[4] is null then return false; end if;
  return exists (select 1 from pit_people where id = a[4]::uuid and org_id = v_org and member_id = m.id);
exception when invalid_text_representation then return false;
end $$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    -- The rules from 1 November, with a person's own return documents kept to those who file tax and the person.
    drop policy if exists "documents read by members" on storage.objects;
    create policy "documents read by members" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax'
             or case when name ~ '^[^/]+/tax/pit/[^/]+/people/' then private.pit_doc_path_ok(name)
                     else (select private.can_handle_money_text((storage.foldername(name))[1])) or private.pit_doc_path_ok(name) end)
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'documents' or (select private.doc_cat_ok_text((storage.foldername(name))[1], (storage.foldername(name))[3]))));
    drop policy if exists "documents upload by members" on storage.objects;
    create policy "documents upload by members" on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax'
             or case when name ~ '^[^/]+/tax/pit/[^/]+/people/' then private.pit_doc_path_ok(name)
                     else (select private.can_handle_money_text((storage.foldername(name))[1])) or private.pit_doc_path_ok(name) end)
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'documents' or (select private.doc_cat_ok_text((storage.foldername(name))[1], (storage.foldername(name))[3]))));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Tax portal logins (Settings)
-- ---------------------------------------------------------------------------
-- The portal each tax authority files on, for the screens.
create or replace function private.portal_of(p_code text) returns text
language sql immutable set search_path = '' as $$
  select case when p_code = 'NRS' then 'Rev360' when p_code = 'SIRS:LA' then 'LIRS e-Tax' else 'Online tax portal' end
$$;

-- The logins the business has saved, for the owner and those who file tax. Nothing secret is here to show.
create or replace function public.portal_logins(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'file_tax')) then
    raise exception 'Tax portal logins are for the owner and those who file tax.' using errcode = '42501';
  end if;
  return jsonb_build_object('can_manage', m.role = 'owner',
    'logins', (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'authority_name', a.name, 'short_name', a.short_name, 'portal', private.portal_of(l.authority),
        'username_hint', l.username_hint, 'tax_office', l.tax_office, 'status', l.status, 'message', l.message, 'saved_at', l.saved_at, 'checked_at', l.checked_at,
        'saved_by', (select display_name from members where id = l.saved_by)) order by a.sort), '[]'::jsonb)
      from portal_logins l join tax_authorities a on a.code = l.authority where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'short_name', a.short_name, 'state', a.state, 'kind', a.kind,
        'portal', private.portal_of(a.code)) order by a.sort) from tax_authorities a));
end $$;

-- Asked by the tax-files function as the person, before a login goes to Flux: only the owner, signed in with two-step.
create or replace function public.portal_login_begin(p_org uuid, p_authority text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; a public.tax_authorities; o public.orgs; l public.portal_logins;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner saves or removes the business''s tax portal logins.' using errcode = '42501'; end if;
  if private.jwt_aal() <> 'aal2' and private.mfa_required(auth.uid()) then
    raise exception 'Enter the code from your authenticator app first: tax portal logins need two-step sign-in.' using errcode = 'PX403';
  end if;
  select * into a from tax_authorities where code = p_authority;
  if not found then raise exception 'Choose the tax authority.'; end if;
  select * into o from orgs where id = p_org;
  select * into l from portal_logins where org_id = p_org and authority = p_authority;
  return jsonb_build_object('member_id', m.id, 'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'taxstreem_org_id', o.taxstreem_org_id),
    'authority', jsonb_build_object('code', a.code, 'name', a.name, 'short_name', a.short_name, 'state', a.state, 'portal', private.portal_of(a.code)),
    'existing', case when l.id is not null then jsonb_build_object('flux_ref', l.flux_ref, 'username_hint', l.username_hint) end);
end $$;

-- After Flux has taken a login (service role): what Counta keeps of it.
create or replace function public.svc_portal_login_saved(p_org uuid, p_authority text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.portal_logins;
begin
  if not exists (select 1 from tax_authorities where code = p_authority) then raise exception 'Unknown tax authority %.', p_authority; end if;
  insert into portal_logins (org_id, authority, username_hint, tax_office, flux_ref, status, message, saved_by, saved_at, checked_at, updated_at)
  values (p_org, p_authority, left(nullif(p->>'username_hint', ''), 80), left(nullif(trim(coalesce(p->>'tax_office', '')), ''), 120), left(nullif(p->>'flux_ref', ''), 200),
    'saved', null, nullif(p->>'member_id', '')::uuid, now(), null, now())
  on conflict (org_id, authority) do update set username_hint = excluded.username_hint, tax_office = excluded.tax_office, flux_ref = excluded.flux_ref,
    status = 'saved', message = null, saved_by = excluded.saved_by, saved_at = now(), checked_at = null, updated_at = now()
  returning * into l;
  return jsonb_build_object('authority', l.authority, 'status', l.status, 'username_hint', l.username_hint, 'tax_office', l.tax_office);
end $$;

create or replace function public.svc_portal_login_removed(p_org uuid, p_authority text) returns jsonb
language sql security definer set search_path = public, private as $$
  with d as (delete from portal_logins where org_id = p_org and authority = p_authority returning 1)
  select jsonb_build_object('removed', (select count(*) from d) > 0)
$$;

-- Flux saying whether a login worked when it signed in (service role). A login that failed is flagged to the owner.
create or replace function public.svc_portal_login_status(p_org uuid, p_authority text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.portal_logins; v_status text := p->>'status'; v_name text;
begin
  if v_status not in ('verified', 'failed') then raise exception 'status must be verified or failed.'; end if;
  update portal_logins set status = v_status, message = left(nullif(p->>'message', ''), 1000), checked_at = now(), updated_at = now()
  where org_id = p_org and authority = p_authority returning * into l;
  if not found then raise exception 'No login is saved for % in this business.', p_authority; end if;
  if v_status = 'failed' then
    select coalesce(short_name, name) into v_name from tax_authorities where code = p_authority;
    perform private.notify_perm(p_org, 'manage_settings', 'books', 'The ' || v_name || ' login did not work',
      coalesce(nullif(p->>'message', ''), 'Flux could not sign in with it. Save the login again under Settings, Tax portal logins.'),
      '/settings#tax-logins', 'portal-login-' || p_authority || '-' || to_char(now(), 'YYYYMMDDHH24MI'), null);
  end if;
  return jsonb_build_object('authority', l.authority, 'status', l.status);
end $$;

-- ---------------------------------------------------------------------------
-- 6. The person's computation as a file, and the tax clearance certificate
-- ---------------------------------------------------------------------------
-- The app makes each person's computation (PDF) from the approved figures when the return goes to Flux, and records it.
create or replace function public.save_pit_computation_file(p_org uuid, p_year int, p_person uuid, p_path text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' then raise exception 'Approve the % return first.', p_year; end if;
  if not exists (select 1 from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person and included) then
    raise exception 'That person is not in the % return.', p_year;
  end if;
  if coalesce(p_path, '') !~ ('^' || p_org::text || '/tax/pit/' || p_year || '/computation/[^/]+\.pdf$') then raise exception 'That file is not this return''s computation.'; end if;
  update pit_person_years set computation_path = p_path, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person;
  return jsonb_build_object('person_id', p_person, 'computation_path', p_path);
end $$;

-- The three years a tax clearance certificate covers: the year filed and the two before it, each shown either as filed
-- through Counta or by the return the business uploads.
create or replace function private.pit_tcc_years(p_org uuid, p_year int, p_person uuid, p_tcc jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_agg(jsonb_build_object('year', y, 'yoa', y + 1,
      'filed_in_counta', exists (select 1 from pit_person_years z where z.org_id = p_org and z.person_id = p_person and z.accounting_year = y and z.status = 'filed'),
      'acknowledgement_ref', (select z.acknowledgement_ref from pit_person_years z where z.org_id = p_org and z.person_id = p_person and z.accounting_year = y and z.status = 'filed'),
      'path', p_tcc->'prior_returns'->(y::text)->>'path', 'name', p_tcc->'prior_returns'->(y::text)->>'name') order by y desc)
  from generate_series(p_year - 2, p_year) y
$$;

-- What the certificate needs, entered by whoever files tax: p {photo_path, photo_name, prior_returns: {year: {path, name} | null}, authorise_outstanding}.
create or replace function public.save_pit_tcc(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; y public.pit_person_years; v_tcc jsonb; k text; v_pre text := p_org::text || '/tax/pit/' || p_year || '/people/' || p_person::text || '/tcc/';
begin
  m := private.require(p_org, 'file_tax');
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  if not found then raise exception 'That person is not in the % return.', p_year; end if;
  if y.status <> 'filed' then raise exception 'File the % return first: the certificate needs it.', p_year; end if;
  if coalesce(y.tcc->>'status', '') in ('requested', 'processing', 'issued') then raise exception 'The certificate is already %.', y.tcc->>'status'; end if;
  v_tcc := coalesce(y.tcc, '{}'::jsonb);
  for k in select jsonb_object_keys(p) loop
    if k not in ('photo_path', 'photo_name', 'prior_returns', 'authorise_outstanding') then raise exception 'Unknown field %.', k; end if;
  end loop;
  if p ? 'photo_path' then
    if nullif(p->>'photo_path', '') is not null and (left(p->>'photo_path', length(v_pre)) <> v_pre or p->>'photo_path' ~ '\.\.') then raise exception 'That picture is not this person''s.'; end if;
    v_tcc := v_tcc || jsonb_build_object('photo_path', nullif(p->>'photo_path', ''), 'photo_name', left(nullif(p->>'photo_name', ''), 160));
  end if;
  if p ? 'prior_returns' then
    if jsonb_typeof(p->'prior_returns') <> 'object' then raise exception 'The returns are {year: file}.'; end if;
    for k in select jsonb_object_keys(p->'prior_returns') loop
      if k !~ '^\d{4}$' or k::int not between p_year - 2 and p_year - 1 then raise exception 'The certificate covers % and the two years before it.', p_year; end if;
      if jsonb_typeof(p->'prior_returns'->k) = 'null' then v_tcc := jsonb_set(v_tcc, '{prior_returns}', coalesce(v_tcc->'prior_returns', '{}'::jsonb) - k); continue; end if;
      if left(coalesce(p->'prior_returns'->k->>'path', ''), length(v_pre)) <> v_pre or p->'prior_returns'->k->>'path' ~ '\.\.' then raise exception 'That return is not this person''s.'; end if;
      v_tcc := jsonb_set(v_tcc, '{prior_returns}', coalesce(v_tcc->'prior_returns', '{}'::jsonb)
        || jsonb_build_object(k, jsonb_build_object('path', p->'prior_returns'->k->>'path', 'name', left(coalesce(p->'prior_returns'->k->>'name', 'Return ' || k), 160))));
    end loop;
  end if;
  if p ? 'authorise_outstanding' then v_tcc := v_tcc || jsonb_build_object('authorise_outstanding', coalesce((p->>'authorise_outstanding')::boolean, false)); end if;
  update pit_person_years set tcc = v_tcc, updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year and person_id = p_person;
  return jsonb_build_object('person_id', p_person, 'tcc', v_tcc, 'years', private.pit_tcc_years(p_org, p_year, p_person, v_tcc));
end $$;

-- For the tax-files function, asked as the person: everything Flux needs to apply for the certificate, or why it cannot yet.
create or replace function public.pit_tcc_pack(p_org uuid, p_year int, p_person uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; y public.pit_person_years; x jsonb; v_years jsonb; v_missing text; l public.portal_logins;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person;
  if py.snapshot is null or y.person_id is null then raise exception 'That person is not in an approved % return.', p_year; end if;
  if y.status <> 'filed' then raise exception 'File the % return first: the certificate needs it.', p_year; end if;
  select p into x from jsonb_array_elements(py.snapshot->'computation'->'people') p where (p->>'person_id')::uuid = p_person;
  if coalesce(private.num(y.bill->>'amount'), private.num(x->'computation'->'figures'->>'payable'), 0) > 0 and y.paid_at is null then
    raise exception 'Pay the % bill first: the certificate is issued once the tax is paid.', p_year;
  end if;
  if coalesce(y.tcc->>'status', '') in ('requested', 'processing', 'issued') then raise exception 'The certificate is already %.', y.tcc->>'status'; end if;
  if coalesce(y.tcc->>'photo_path', '') = '' then raise exception 'Add a profile picture of %.', x->>'name'; end if;
  v_years := private.pit_tcc_years(p_org, p_year, p_person, y.tcc);
  select string_agg((e->>'year'), ', ' order by (e->>'year')) into v_missing from jsonb_array_elements(v_years) e
    where not (e->>'filed_in_counta')::boolean and coalesce(e->>'path', '') = '';
  if v_missing is not null then raise exception 'Attach the filed return for % (accounts years), or the acknowledgement the state gave.', v_missing; end if;
  select * into l from portal_logins where org_id = p_org and authority = x->>'authority';
  return jsonb_build_object('org', py.snapshot->'org', 'year', p_year, 'yoa', p_year + 1,
    'taxpayer', jsonb_build_object('person_id', p_person, 'name', x->>'name', 'tin', x->>'tin', 'role', x->>'role', 'authority', x->>'authority',
      'authority_name', x->>'authority_name', 'state', x->>'authority_state'),
    'years', v_years, 'photo_path', y.tcc->>'photo_path', 'photo_name', y.tcc->>'photo_name',
    'authorise_outstanding', coalesce((y.tcc->>'authorise_outstanding')::boolean, false),
    'paid', jsonb_build_object('at', y.paid_at, 'reference', y.payment_ref, 'bill', y.bill),
    'login', case when l.id is not null then jsonb_build_object('flux_ref', l.flux_ref, 'tax_office', l.tax_office, 'status', l.status) end);
end $$;

-- ---------------------------------------------------------------------------
-- 7. The computation: reliefs with their documents, the portal's lines, the checks before approval
-- ---------------------------------------------------------------------------
-- Each line of other income keeps the portal line it goes on (field: salary, commission, allowance, pension, annuity).
create or replace function private.pit_person_tax(p_rb jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare
  v_nta boolean := coalesce(p_rb->'meta'->>'regime', '') = 'NTA_2025_PIT';
  v_sole boolean := coalesce((p->>'sole')::boolean, false);
  v_share numeric := round(coalesce(private.num(p->>'share_pct'), 0), 4);
  v_ap numeric := round(coalesce(private.num(p->>'assessable'), 0), 2);
  v_rem numeric := round(greatest(coalesce(private.num(p->>'remuneration'), 0), 0), 2);
  v_ca_year numeric := round(greatest(coalesce(private.num(p->>'ca_year'), 0), 0), 2);
  v_gains_all numeric := round(coalesce(private.num(p->>'gains_net'), 0), 2);
  v_wht_all numeric := round(greatest(coalesce(private.num(p->>'wht_available'), 0), 0), 2);
  v_loss_bf numeric := round(greatest(coalesce(private.num(p->>'losses_bf'), 0), 0), 2);
  v_ca_bf numeric := round(greatest(coalesce(private.num(p->>'ca_bf'), 0), 0), 2);
  rl jsonb := coalesce(p->'reliefs', '{}'::jsonb);
  oi jsonb := coalesce(p->'other_income', '[]'::jsonb);
  v_final text[] := coalesce(array(select jsonb_array_elements_text(p_rb->'other_income'->'final_tax_kinds')), '{}');
  v_exempt text[] := coalesce(array(select jsonb_array_elements_text(p_rb->'other_income'->'exempt_kinds')), '{}');
  v_minwage numeric := coalesce(private.num(p_rb->'other_income'->>'minimum_wage_monthly_ngn'), 70000) * 12;
  v_sh numeric; v_biz numeric; v_loss_use numeric; v_rem1 numeric; v_ca_share numeric; v_ca_avail numeric; v_ca_use numeric; v_biz_net numeric;
  v_new_loss numeric; v_g numeric; v_g_tax numeric := 0; v_off numeric; v_cgt numeric := 0;
  x jsonb; v_kind text; v_amt numeric; v_td numeric; v_treat text; v_lines jsonb := '[]'::jsonb; v_oth numeric := 0; v_oth_ex numeric := 0; v_oth_fin numeric := 0;
  v_cred numeric := 0; v_fx_inc numeric := 0; v_fx_tax numeric := 0;
  v_total numeric; v_pension numeric; v_nhf numeric; v_nhis numeric; v_life numeric; v_home numeric; v_grat numeric; v_rent numeric; v_rent_relief numeric := 0;
  v_exempt_tot numeric := 0; v_base numeric := 0; v_cra numeric := 0; v_cra_fixed numeric := 0; v_reliefs numeric; v_chargeable numeric; b jsonb; v_bt numeric;
  v_mt numeric := 0; v_mt_used boolean := false; v_tax numeric; v_ftc numeric := 0; v_after numeric; v_cred_use numeric; v_wht_share numeric; v_wht_use numeric;
  v_payable numeric; v_rows jsonb := '[]'::jsonb; v_pct text; v_law text; v_marg numeric;
begin
  v_pct := trim(to_char(v_share, 'FM990.####')) || '%';
  v_law := case when v_nta then 'NTA 2025' else 'PITA' end;

  -- Income from the business: the share of its assessable profit, and what the accounts charged for the person (s.15(1)).
  v_sh := round(v_ap * v_share / 100, 2);
  v_biz := v_sh + v_rem;
  v_loss_use := least(v_loss_bf, greatest(v_biz, 0));
  v_rem1 := greatest(v_biz, 0) - v_loss_use;
  v_ca_share := round(v_ca_year * v_share / 100, 2);
  v_ca_avail := v_ca_share + v_ca_bf;
  v_ca_use := least(v_ca_avail, v_rem1);
  v_biz_net := v_rem1 - v_ca_use;
  v_new_loss := greatest(-v_biz, 0);

  -- Chargeable gains on the business's disposals, shared like the profit.
  v_g := round(v_gains_all * v_share / 100, 2);
  if coalesce((p_rb->'chargeable_gains'->>'in_total_income')::boolean, false) then
    if v_g > 0 then
      v_off := least(v_new_loss, v_g); v_new_loss := v_new_loss - v_off; v_g_tax := v_g - v_off;
    else
      v_new_loss := v_new_loss - v_g;
    end if;
  else
    v_cgt := round(greatest(v_g, 0) * coalesce(private.num(p_rb->'chargeable_gains'->>'separate_rate'), 0.10), 2);
  end if;

  -- Other income, line by line: taxable (with any tax deducted as a credit), taxed in full at source, or exempt.
  for x in select value from jsonb_array_elements(oi) loop
    v_kind := coalesce(x->>'kind', 'other');
    v_amt := round(greatest(coalesce(private.num(x->>'amount'), 0), 0), 2);
    v_td := round(greatest(coalesce(private.num(x->>'tax_deducted'), 0), 0), 2);
    continue when v_amt = 0;
    v_treat := case
      when v_kind = any(v_exempt) then 'exempt'
      when v_kind = 'employment' and v_amt <= v_minwage then 'exempt_minimum_wage'
      when v_kind = any(v_final) and v_td > 0 and coalesce((x->>'final_tax')::boolean, true) then 'final'
      else 'taxable' end;
    if v_treat = 'taxable' then
      v_oth := v_oth + v_amt;
      if v_kind = 'foreign_earned' then v_fx_inc := v_fx_inc + v_amt; v_fx_tax := v_fx_tax + v_td; else v_cred := v_cred + v_td; end if;
    elsif v_treat = 'final' then v_oth_fin := v_oth_fin + v_amt;
    else v_oth_ex := v_oth_ex + v_amt; end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', v_kind, 'label', coalesce(nullif(trim(x->>'label'), ''), initcap(replace(v_kind, '_', ' '))),
      'amount', v_amt, 'tax_deducted', v_td, 'treatment', v_treat) || case when coalesce(x->>'field', '') <> '' then jsonb_build_object('field', x->>'field') else '{}'::jsonb end);
  end loop;

  v_total := v_biz_net + v_g_tax + v_oth;

  -- Reliefs.
  v_pension := round(greatest(coalesce(private.num(rl->>'pension'), 0), 0), 2);
  v_nhf := round(greatest(coalesce(private.num(rl->>'nhf'), 0), 0), 2);
  v_nhis := round(greatest(coalesce(private.num(rl->>'nhis'), 0), 0), 2);
  v_life := round(greatest(coalesce(private.num(rl->>'life_insurance'), 0), 0), 2);
  v_home := round(greatest(coalesce(private.num(rl->>'home_loan_interest'), 0), 0), 2);
  v_grat := round(greatest(coalesce(private.num(rl->>'gratuity'), 0), 0), 2);
  v_rent := round(greatest(coalesce(private.num(rl->>'rent_paid'), 0), 0), 2);
  if v_nta then
    v_rent_relief := least(round(v_rent * coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'pct'), 0.20), 2),
                           coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'cap_ngn'), 500000));
    v_reliefs := v_nhf + v_nhis + v_pension + v_home + v_life + v_rent_relief;
  else
    -- PITA s.33 as amended by the Finance Act 2020: the tax-exempt contributions come off first, the CRA is worked on what
    -- is left, and home loan interest comes off after it.
    v_exempt_tot := v_pension + v_nhf + v_nhis + v_life + v_grat;
    v_base := greatest(v_total - v_exempt_tot, 0);
    v_cra_fixed := greatest(coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_ngn'), 200000), round(v_base * coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_pct'), 0.01), 2));
    v_cra := v_cra_fixed + round(v_base * coalesce(private.num(p_rb->'reliefs'->'cra'->>'variable_pct'), 0.20), 2);
    v_reliefs := v_exempt_tot + v_cra + v_home;
  end if;
  v_chargeable := greatest(v_total - v_reliefs, 0);

  b := private.pit_bands(v_chargeable, p_rb->'tax_bands');
  v_bt := (b->>'tax')::numeric;
  v_tax := v_bt;
  if coalesce((p_rb->'minimum_tax'->>'applies')::boolean, false) and v_total > 0 then
    v_mt := round(v_base * coalesce(private.num(p_rb->'minimum_tax'->>'rate'), 0.01), 2);
    if v_mt > v_bt then v_tax := v_mt; v_mt_used := true; end if;
  end if;

  -- Credits: foreign tax (the lower of the foreign tax and the Nigerian tax on that income), tax deducted from other income,
  -- then the person's share of the business's WHT credit notes. None makes the tax negative.
  if v_fx_inc > 0 and v_total > 0 then v_ftc := least(v_fx_tax, round(v_tax * least(v_fx_inc / v_total, 1), 2)); end if;
  v_after := v_tax - v_ftc;
  v_cred_use := least(v_cred, v_after);
  v_after := v_after - v_cred_use;
  v_wht_share := round(v_wht_all * v_share / 100, 2);
  v_wht_use := least(v_wht_share, v_after);
  v_payable := v_after - v_wht_use;
  v_marg := (select (x2->>'rate')::numeric from jsonb_array_elements(b->'bands') x2 where (x2->>'slice')::numeric > 0 order by (x2->>'from')::numeric desc limit 1);

  -- The computation, line by line.
  v_rows := jsonb_build_array(jsonb_build_object('id', 'S1',
    'line', case when v_sole then 'Assessable profit of the business' else 'Share of the business''s assessable profit (' || v_pct || ')' end,
    'amount', v_sh, 'basis', case when v_sole then 'PIT rule book s.1: the owner is taxed on the whole profit'
                                  else v_pct || ' of ' || private.naira(v_ap) || ' (s.15(1)(b) and (3))' end, '_style', 'line'));
  if v_rem <> 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S2',
      'line', case when v_sole then 'Add: the owner''s own pay charged as an expense' else 'Add: pay, interest on capital and benefits charged in the accounts' end,
      'amount', v_rem, 'basis', case when v_sole then 'A drawing, not a business expense (s.21(c))' else 's.15(1)(a)' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S3', 'line', 'Income from the business', 'amount', v_biz, '_style', 'subtotal'));
  if v_loss_bf > 0 or v_loss_use > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S4', 'line', 'Less: losses brought forward', 'amount', -v_loss_use,
      'basis', private.naira(v_loss_bf) || ' brought forward' || case when v_nta then '; no time limit (s.28(3))' else '' end, '_style', 'line'));
  end if;
  if v_ca_avail > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S5', 'line', 'Less: capital allowances', 'amount', -v_ca_use,
      'basis', case when v_sole then private.naira(v_ca_share) || ' for the year' else private.naira(v_ca_share) || ', ' || v_pct || ' of the business''s ' || private.naira(v_ca_year) end
        || case when v_ca_bf > 0 then ' and ' || private.naira(v_ca_bf) || ' brought forward' else '' end, '_style', 'line'));
  end if;
  if v_nta and v_g <> 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S6', 'line', 'Add: chargeable gains on the business''s disposals', 'amount', v_g_tax,
      'basis', case when v_sole then '' else v_pct || ' of ' || private.naira(v_gains_all) || '; ' end || 'taxed with income (s.28(2)(a)(v))'
        || case when v_g < 0 then '; the net loss is carried forward' when v_g_tax < v_g then '; reduced by the year''s business loss' else '' end, '_style', 'line'));
  end if;
  if v_oth > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S7', 'line', 'Add: other income', 'amount', v_oth,
      'basis', (select string_agg((l->>'label') || ' ' || private.naira((l->>'amount')::numeric), '; ') from jsonb_array_elements(v_lines) l where l->>'treatment' = 'taxable'),
      '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'T', 'line', 'Total income', 'amount', v_total, '_style', 'subtotal'));
  if v_nta then
    v_rows := v_rows
      || case when v_nhf > 0 then jsonb_build_array(jsonb_build_object('id', 'R1', 'line', 'Less: National Housing Fund contributions', 'amount', -v_nhf, 'basis', 's.30(2)(a)(i)', '_style', 'line')) else '[]'::jsonb end
      || case when v_nhis > 0 then jsonb_build_array(jsonb_build_object('id', 'R2', 'line', 'Less: National Health Insurance contributions', 'amount', -v_nhis, 'basis', 's.30(2)(a)(ii)', '_style', 'line')) else '[]'::jsonb end
      || case when v_pension > 0 then jsonb_build_array(jsonb_build_object('id', 'R3', 'line', 'Less: pension contributions', 'amount', -v_pension, 'basis', 's.30(2)(a)(iii), Pension Reform Act', '_style', 'line')) else '[]'::jsonb end
      || case when v_home > 0 then jsonb_build_array(jsonb_build_object('id', 'R4', 'line', 'Less: interest on a loan for an owner-occupied home', 'amount', -v_home, 'basis', 's.30(2)(a)(iv)', '_style', 'line')) else '[]'::jsonb end
      || case when v_life > 0 then jsonb_build_array(jsonb_build_object('id', 'R5', 'line', 'Less: life insurance or deferred annuity premiums', 'amount', -v_life, 'basis', 's.30(2)(a)(v)', '_style', 'line')) else '[]'::jsonb end
      || case when v_rent > 0 then jsonb_build_array(jsonb_build_object('id', 'R6', 'line', 'Less: rent relief', 'amount', -v_rent_relief,
           'basis', '20% of ' || private.naira(v_rent) || ' rent paid, at most ' || private.naira(coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'cap_ngn'), 500000)) || ' (s.30(2)(a)(vi))', '_style', 'line')) else '[]'::jsonb end;
  else
    v_rows := v_rows
      || case when v_exempt_tot > 0 then jsonb_build_array(jsonb_build_object('id', 'R1', 'line', 'Less: pension, NHF, NHIS, life insurance and gratuity', 'amount', -v_exempt_tot,
           'basis', 'Tax-exempt contributions, taken off before the CRA (PITA s.33(2))', '_style', 'line')) else '[]'::jsonb end
      || jsonb_build_array(jsonb_build_object('id', 'R2', 'line', 'Less: consolidated relief allowance', 'amount', -v_cra,
           'basis', 'Higher of ' || private.naira(coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_ngn'), 200000)) || ' or 1% (' || private.naira(v_cra_fixed) || '), plus 20%, of ' || private.naira(v_base)
             || ' (PITA s.33(1), Sixth Schedule)', '_style', 'line'))
      || case when v_home > 0 then jsonb_build_array(jsonb_build_object('id', 'R3', 'line', 'Less: interest on a loan for an owner-occupied home', 'amount', -v_home, 'basis', 'PITA s.20(1)(c)', '_style', 'line')) else '[]'::jsonb end;
  end if;
  v_rows := v_rows || jsonb_build_array(
    jsonb_build_object('id', 'C', 'line', 'Chargeable income', 'amount', v_chargeable, 'basis', case when v_reliefs > v_total and v_total > 0 then 'The reliefs are more than the income' end, '_style', 'subtotal'),
    jsonb_build_object('id', 'X', 'line', 'Tax at the ' || case when v_nta then 'Fourth' else 'Sixth' end || ' Schedule rates', 'amount', v_bt,
      'basis', coalesce((select string_agg(trim(to_char((x2->>'rate')::numeric * 100, 'FM990.##')) || '% on ' || private.naira((x2->>'slice')::numeric), ', ' order by (x2->>'from')::numeric)
        from jsonb_array_elements(b->'bands') x2 where (x2->>'slice')::numeric > 0), 'No tax at the rates'), '_style', 'line'));
  if coalesce((p_rb->'minimum_tax'->>'applies')::boolean, false) then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'M', 'line', 'Minimum tax (1% of ' || private.naira(v_base) || ')', 'amount', v_mt,
      'basis', case when v_total <= 0 then 'No income, so no minimum tax' when v_mt_used then 'Higher than the tax at the rates, so it is payable instead (PITA s.37)'
                    else 'Lower than the tax at the rates' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'K', 'line', 'Income tax for the year', 'amount', v_tax, '_style', 'subtotal'));
  if v_ftc > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F1', 'line', 'Less: foreign tax credit', 'amount', -v_ftc,
      'basis', 'Lower of the foreign tax (' || private.naira(v_fx_tax) || ') and the Nigerian tax on that income (PIT rule book s.7)', '_style', 'line'));
  end if;
  if v_cred > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F2', 'line', 'Less: PAYE and tax deducted from other income', 'amount', -v_cred_use,
      'basis', private.naira(v_cred) || ' deducted' || case when v_cred_use < v_cred then '; ' || private.naira(v_cred - v_cred_use) || ' more than the tax' else '' end, '_style', 'line'));
  end if;
  if v_wht_share > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F3', 'line', 'Less: ' || case when v_sole then 'the business''s' else 'share of the business''s' end || ' WHT credit notes',
      'amount', -v_wht_use, 'basis', private.naira(v_wht_share) || case when v_sole then '' else ' (' || v_pct || ')' end || ' held'
        || case when v_wht_use < v_wht_share then '; ' || private.naira(v_wht_share - v_wht_use) || ' kept for later years' else '' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'P', 'line', 'Tax payable', 'amount', v_payable, '_style', 'total'));
  if v_cgt > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'CGT', 'line', 'Capital gains tax at 10% on ' || case when v_sole then 'the' else 'the share of the' end || ' gains (' || private.naira(v_g) || ')',
      'amount', v_cgt, 'basis', 'Filed on its own capital gains tax return (Capital Gains Tax Act); not part of the income tax above', '_style', 'memo'));
  end if;

  return jsonb_build_object('rows', v_rows, 'bands', b->'bands', 'other_income', v_lines, 'regime', case when v_nta then 'NTA_2025_PIT' else 'PITA' end,
    'figures', jsonb_build_object('share_pct', v_share, 'share_profit', v_sh, 'remuneration', v_rem, 'business_income', v_biz, 'losses_bf', v_loss_bf,
      'loss_relief', v_loss_use, 'ca_share', v_ca_share, 'ca_bf', v_ca_bf, 'ca_available', v_ca_avail, 'capital_allowances', v_ca_use, 'business_net', v_biz_net,
      'gains', v_g, 'gains_taxed', v_g_tax, 'other_income', v_oth, 'other_income_final_tax', v_oth_fin, 'other_income_exempt', v_oth_ex,
      'total_income', v_total, 'exempt_contributions', v_exempt_tot, 'cra_base', v_base, 'cra', v_cra, 'rent_relief', v_rent_relief, 'reliefs', v_reliefs,
      'chargeable_income', v_chargeable, 'tax_at_rates', v_bt, 'minimum_tax', v_mt, 'minimum_tax_used', v_mt_used, 'tax', v_tax,
      'foreign_income', v_fx_inc, 'foreign_tax', v_fx_tax, 'foreign_tax_credit', v_ftc, 'other_credits', v_cred, 'other_credits_used', v_cred_use,
      'wht_share', v_wht_share, 'wht_credit', v_wht_use, 'payable', v_payable, 'cgt', v_cgt,
      'effective_rate', case when v_total > 0 then round(v_tax / v_total, 4) else 0 end, 'marginal_rate', coalesce(v_marg, 0)),
    'cf', jsonb_build_object('losses', round(v_loss_bf - v_loss_use + v_new_loss, 2), 'ca', round(v_ca_avail - v_ca_use, 2)));
end $$;

-- The people in a year, with the accommodation, pension details and relief documents. Where a person has not entered
-- the year's accommodation, last year's home carries on (without its rent), unless they moved out of it.
create or replace function private.pit_people_year(p_org uuid, p_year int) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with main as (select l.id, l.state from locations l where l.org_id = p_org order by l.is_main desc, l.created_at limit 1),
  ppl as (
    select pp.*, y.person_id is not null has_row, y as yr,
      (select p2 from pit_person_years p2 where p2.org_id = p_org and p2.person_id = pp.id and p2.accounting_year < p_year order by p2.accounting_year desc limit 1) prev
    from pit_people pp
    left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = pp.id
    where pp.org_id = p_org and case when y.person_id is not null then y.included else pp.active end),
  n as (select count(*)::numeric n from ppl)
  select coalesce(jsonb_agg(jsonb_build_object(
      'person_id', x.id, 'name', x.name, 'tin', x.tin, 'member_id', x.member_id, 'source', x.source, 'has_row', x.has_row,
      'share_pct', coalesce((x.yr).share_pct, (x.prev).share_pct, round(100 / nullif((select n from n), 0), 4)),
      'role', coalesce((x.yr).role, (x.prev).role),
      'office_location_id', coalesce((x.yr).office_location_id, (x.prev).office_location_id, (select id from main)),
      'residence', coalesce((x.yr).residence, (x.prev).residence, private.state_code((select state from main))),
      'resident', coalesce((x.yr).resident, (x.prev).resident, true),
      'remuneration', coalesce((x.yr).remuneration, 0), 'remuneration_note', (x.yr).remuneration_note,
      'opening', coalesce((x.yr).opening, '{}'::jsonb), 'reliefs', coalesce((x.yr).reliefs, '{}'::jsonb), 'other_income', coalesce((x.yr).other_income, '[]'::jsonb),
      'accommodation', case when coalesce((x.yr).accommodation, '{}'::jsonb) <> '{}'::jsonb then (x.yr).accommodation
        when coalesce((x.prev).accommodation->>'ended_on', '') = '' then coalesce((x.prev).accommodation, '{}'::jsonb) - 'rent_paid' - 'rent_paid_by_employer'
        else '{}'::jsonb end,
      'accommodation_carried', coalesce((x.yr).accommodation, '{}'::jsonb) = '{}'::jsonb and coalesce((x.prev).accommodation, '{}'::jsonb) <> '{}'::jsonb
        and coalesce((x.prev).accommodation->>'ended_on', '') = '',
      'pension_details', coalesce(nullif((x.yr).pension_details, '{}'::jsonb), (x.prev).pension_details, '{}'::jsonb),
      'relief_docs', coalesce((x.yr).relief_docs, '{}'::jsonb),
      'status', coalesce((x.yr).status, 'draft'), 'flux_ref', (x.yr).flux_ref, 'flux_status', (x.yr).flux_status, 'flux_message', (x.yr).flux_message,
      'flux_sent_at', (x.yr).flux_sent_at, 'filed_at', (x.yr).filed_at, 'filed_by_business', coalesce((x.yr).filed_by_business, false),
      'acknowledgement_ref', (x.yr).acknowledgement_ref, 'assessment', (x.yr).assessment, 'payment_url', (x.yr).payment_url,
      'in_previous_year', (x.prev).person_id is not null)
    order by x.sort, x.created_at), '[]'::jsonb)
  from ppl x
$$;

-- The whole year. A relief counts only with its documents; the person's figures also come as the lines of the portal's
-- statement of income; and a return Flux files needs the accommodation disclosure, the business's staff and a login.
create or replace function private.pit_compute(p_org uuid, p_year int, p_bf jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; rbr public.tax_rulebooks; rb jsonb; v_kind text; b jsonb; bf jsonb; ppl jsonb; x jsonb; v_out jsonb := '[]'::jsonb; t jsonb;
  py public.pit_years; v_wht_used_bf numeric; v_wht_avail numeric; v_role text; v_auth text; v_share numeric; v_sum numeric := 0; v_n int;
  v_tax numeric := 0; v_payable numeric := 0; v_wht_used numeric := 0; v_cgt numeric := 0; v_cf jsonb := '{}'::jsonb; v_checks jsonb := '[]'::jsonb;
  v_flags jsonb; v_open text; v_rem numeric := 0; v_lb numeric; v_cb numeric; v_loc record; v_auth_name text; v_lines jsonb; v_flux text[];
  v_new text; v_gone text; v_prev_n int; rc jsonb; v_reliefs jsonb; v_has_flux boolean; v_staff_pay numeric;
begin
  select * into o from orgs where id = p_org;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  rbr := private.pit_rulebook(p_year); rb := rbr.config;
  v_kind := private.income_tax_kind(p_org, p_year);
  v_flux := coalesce(array(select jsonb_array_elements_text(rb->'filing'->'flux_authorities')), '{}');
  b := private.pit_business(p_org, p_year);
  ppl := private.pit_people_year(p_org, p_year);
  v_n := jsonb_array_length(ppl);
  bf := coalesce(p_bf, '{}'::jsonb);
  v_wht_used_bf := coalesce(private.num(bf->>'wht_used'), 0);
  v_wht_avail := greatest(private.v(b->'figures', 'wht_held') - v_wht_used_bf, 0);
  v_cf := coalesce(bf->'people', '{}'::jsonb);

  for x in select value from jsonb_array_elements(ppl) loop
    v_role := case when v_kind = 'sole' then 'proprietor' when coalesce(x->>'role', 'proprietor') = 'proprietor' then 'active' else x->>'role' end;
    v_share := case when v_kind = 'sole' then 100 else coalesce(private.num(x->>'share_pct'), 0) end;
    v_sum := v_sum + v_share;
    -- Brought forward: last year's computation for the person, or the amounts entered for the first year Counta prepares.
    if p_bf is not null and bf->'people' ? (x->>'person_id') then
      v_lb := coalesce(private.num(bf->'people'->(x->>'person_id')->>'losses'), 0); v_cb := coalesce(private.num(bf->'people'->(x->>'person_id')->>'ca'), 0);
    else
      v_lb := coalesce(private.num(x->'opening'->>'losses_bf'), 0); v_cb := coalesce(private.num(x->'opening'->>'ca_bf'), 0);
    end if;
    -- A relief counts only with its documents (pension also with the RSA number and administrator; rent relief with a
    -- tenant's accommodation disclosure). Rent relief is for 2026 accounts onwards, gratuity for 2025 accounts only.
    v_reliefs := coalesce(x->'reliefs', '{}'::jsonb) - case when rbr.regime = 'NTA_2025_PIT' then 'gratuity' else 'rent_paid' end;
    rc := private.pit_relief_check(v_reliefs, x->'relief_docs', x->'pension_details', x->'accommodation');
    t := private.pit_person_tax(rb, jsonb_build_object('name', x->>'name', 'sole', v_kind = 'sole', 'share_pct', v_share,
      'assessable', b->'figures'->'assessable', 'remuneration', x->'remuneration', 'ca_year', b->'figures'->'ca_year',
      'gains_net', b->'figures'->'gains_net', 'wht_available', v_wht_avail, 'losses_bf', v_lb, 'ca_bf', v_cb,
      'reliefs', rc->'claimed', 'other_income', x->'other_income'));
    v_auth := private.pit_authority(v_kind, v_role, (x->>'office_location_id')::uuid, x->>'residence', coalesce((x->>'resident')::boolean, true));
    select a.name, a.short_name, a.state into v_loc from tax_authorities a where a.code = v_auth;
    v_out := v_out || jsonb_build_array(x || jsonb_build_object('role', v_role, 'share_pct', v_share, 'authority', v_auth,
      'authority_name', v_loc.name, 'authority_short', v_loc.short_name, 'authority_state', v_loc.state,
      'office', (select jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'address', l.address) from locations l where l.id = (x->>'office_location_id')::uuid),
      'flux', v_auth = any(v_flux), 'reliefs_claimed', rc->'claimed', 'reliefs_held', rc->'held', 'income_fields', private.pit_portal_income(t),
      'computation', t, 'bf', jsonb_build_object('losses', v_lb, 'ca', v_cb, 'from_previous_year', p_bf is not null and bf->'people' ? (x->>'person_id'))));
    v_cf := jsonb_set(v_cf, array[x->>'person_id'], t->'cf');
    v_tax := v_tax + private.v(t->'figures', 'tax');
    v_payable := v_payable + private.v(t->'figures', 'payable');
    v_wht_used := v_wht_used + private.v(t->'figures', 'wht_credit');
    v_cgt := v_cgt + private.v(t->'figures', 'cgt');
    v_rem := v_rem + coalesce(private.num(x->>'remuneration'), 0);
  end loop;

  -- Checks before the year can be approved.
  v_checks := coalesce(b->'checks', '[]'::jsonb);
  if v_kind not in ('sole', 'partnership') then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'not_pit', 'severity', 'block', 'text',
      case when v_kind = 'company' then 'The business is a company: it files companies income tax, not personal income tax.'
           else 'The business is exempt from income tax unless it carries on a trade or business (NTA 2025 s.162(1)(a)(iii)).' end));
  end if;
  if v_n = 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'no_people', 'severity', 'block',
      'text', 'Add the owner of the business, or its partners, under People.'));
  elsif v_kind = 'partnership' and abs(v_sum - 100) >= 0.005 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'shares_total', 'severity', 'block',
      'text', 'The partners'' shares of the profit add up to ' || trim(to_char(v_sum, 'FM990.####')) || '%, not 100%.'));
  end if;
  if o.legal_form = 'partnership' and v_n = 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'lp_partners', 'severity', 'block',
      'text', 'A limited partnership has at least two partners. Add the others under People.'));
  end if;
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p where p->>'authority' is null;
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'authority_missing', 'severity', 'block',
      'text', 'Counta cannot tell which state taxes ' || v_open || '. ' || case when v_kind = 'sole' then 'Choose the state the owner lived in on 1 January.'
        else 'Choose the office each active partner works from (with its state in Settings, Branches), or the state a dormant partner lives in.' end));
  end if;
  if py.soa_path is null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'soa_missing', 'severity', 'block',
      'text', 'Attach the statement of accounts (or use Counta''s financial statements). The state revenue service asks for it with the return (NTAA 2025 s.13(2)(d)).'));
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(b->'mixed_use', '[]'::jsonb)) l where (l->>'amount')::numeric > 0)
     and not coalesce((py.settings->>'mixed_use_reviewed')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'mixed_use_review', 'severity', 'block',
      'text', 'Say under Mixed use which of these expenses are partly private (a car, internet, power, a home that is also the office), or that none are. '
        || 'Only the business share is deductible (PIT rule book s.4).'));
  end if;
  if v_kind = 'partnership' and v_rem > private.v(b->'figures', 'salaries') + 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pay_vs_books', 'severity', 'warn',
      'text', 'The pay charged for the partners (' || private.naira(v_rem) || ') is more than the salaries in the accounts (' || private.naira(private.v(b->'figures', 'salaries')) || ').'));
  end if;
  select string_agg(p->>'name', ', ') into v_new from jsonb_array_elements(v_out) p where not coalesce((p->>'in_previous_year')::boolean, false);
  select count(*) into v_prev_n from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year - 1 and y.included;
  select string_agg(pp.name, ', ') into v_gone from pit_person_years y join pit_people pp on pp.id = y.person_id
    where y.org_id = p_org and y.accounting_year = p_year - 1 and y.included
      and not exists (select 1 from jsonb_array_elements(v_out) p where (p->>'person_id')::uuid = y.person_id);
  if v_kind = 'partnership' and v_prev_n > 0 and (v_new is not null or v_gone is not null) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'partner_change', 'severity', 'warn',
      'text', concat_ws(' ', case when v_new is not null then v_new || ' joined.' end, case when v_gone is not null then v_gone || ' left.' end)
        || ' When a partner joins or leaves during the year, the year splits at that date (First Schedule para 19(2)); Counta treats it as one year. Check the split with your adviser.'));
  end if;
  if exists (select 1 from jsonb_array_elements(v_out) p where p->>'authority' = 'NRS') then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'non_resident', 'severity', 'info',
      'text', 'A partner who does not live in Nigeria files with the NRS (NTAA 2025 s.3(1)(a)(iv)).'));
  end if;
  if rbr.regime = 'PITA' and private.v(b->'figures', 'gains_net') > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'cgt_separate', 'severity', 'info',
      'text', 'Under the old law, gains on disposals go on a separate capital gains tax return at 10%. Each person''s share is shown below the income tax.'));
  end if;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'evidence', 'severity', 'info',
    'text', 'Keep the evidence for the deductions in the accounts (receipts, the tenancy agreement): the state may ask for it (NTA 2025 s.32).'));

  -- What the state portal needs. A relief entered without its documents is left out (the portal refuses it), and says so to
  -- the person and those who file tax only.
  for x in select value from jsonb_array_elements(v_out) loop
    continue when jsonb_array_length(coalesce(x->'reliefs_held', '[]'::jsonb)) = 0;
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'relief_docs', 'severity', 'warn', 'person_id', x->>'person_id',
      'text', 'Left out of ' || (x->>'name') || '''s return until attached: '
        || (select string_agg((h->>'label') || ' (' || (select string_agg(mm, ', ') from jsonb_array_elements_text(h->'missing') mm) || ')', '; ')
            from jsonb_array_elements(x->'reliefs_held') h)
        || '. The state portal refuses a relief without its documents. Attach them under People.'));
  end loop;
  v_has_flux := exists (select 1 from jsonb_array_elements(v_out) p where (p->>'flux')::boolean);
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p
    where (p->>'flux')::boolean and not private.pit_accommodation_ok(coalesce(p->'accommodation', '{}'::jsonb));
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'accommodation_missing', 'severity', 'block',
      'text', 'Enter where ' || v_open || ' lived during the year under People: the address, the kind of home, whether it is rented or owned and since when, '
        || 'and for a tenant the landlord and the rent. The state portal will not take the return without it.'));
  end if;
  if v_has_flux and not coalesce((py.settings->>'staff_reviewed')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'staff_review', 'severity', 'block',
      'text', 'List the business''s employees for the year under Staff, or confirm it had none. The state portal asks for them with the return.'));
  end if;
  if coalesce((py.settings->>'staff_reviewed')::boolean, false) then
    select coalesce(sum(private.num(s->>'annual_pay')), 0) into v_staff_pay from jsonb_array_elements(coalesce(py.staff, '[]'::jsonb)) s;
    if abs(v_staff_pay + v_rem - private.v(b->'figures', 'salaries')) > greatest(1, 0.01 * private.v(b->'figures', 'salaries')) then
      v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'staff_pay', 'severity', 'info',
        'text', 'The pay listed under Staff (' || private.naira(v_staff_pay) || ')' || case when v_rem > 0 then ' and for the ' || case when v_kind = 'sole' then 'owner' else 'partners' end
          || ' (' || private.naira(v_rem) || ')' else '' end || ' differs from the salaries in the accounts (' || private.naira(private.v(b->'figures', 'salaries')) || ').'));
    end if;
  end if;
  select string_agg(distinct coalesce(p->>'authority_short', p->>'authority_name', p->>'authority'), ', ') into v_open from jsonb_array_elements(v_out) p
    where (p->>'flux')::boolean and not exists (select 1 from portal_logins l where l.org_id = p_org and l.authority = p->>'authority');
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'portal_login', 'severity', 'warn',
      'text', 'Save the business''s ' || v_open || ' login under Settings, Tax portal logins, so Flux can file the return.'));
  end if;
  if rbr.status <> 'approved' then
    select string_agg(k || ' ' || (v->>'title'), ', ' order by k) into v_open from jsonb_each(coalesce(rb->'configurable_flags'->'flags', '{}'::jsonb)) f(k, v)
      where v->>'status' <> 'agreed';
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'rulebook_pending', 'severity', 'warn',
      'text', 'The rules for this year (' || rbr.id || ') are awaiting TaxStreem sign-off' || coalesce(': ' || v_open, '') || '.'));
  end if;

  return jsonb_build_object('year', p_year, 'yoa', p_year + 1, 'from', b->>'from', 'to', b->>'to', 'ended', (b->>'ended')::boolean, 'source', b->>'source',
    'kind', v_kind, 'regime', rbr.regime, 'rulebook', jsonb_build_object('id', rbr.id, 'version', rbr.version, 'status', rbr.status, 'law', rb->'meta'->>'governing_law'),
    'business', b, 'people', v_out, 'checks', v_checks, 'due', private.pit_due(p_org, p_year), 'flux_authorities', to_jsonb(v_flux),
    'figures', jsonb_build_object('assessable', b->'figures'->'assessable', 'tax', v_tax, 'payable', v_payable, 'wht_held', b->'figures'->'wht_held',
      'wht_available', v_wht_avail, 'wht_credit_used', v_wht_used, 'cgt', v_cgt, 'people', v_n, 'shares_total', v_sum),
    'bf', jsonb_build_object('wht_used', v_wht_used_bf, 'from_previous_year', p_bf is not null),
    'cf', jsonb_build_object('people', v_cf, 'wht_used', round(v_wht_used_bf + v_wht_used, 2)),
    'status', coalesce(py.status, 'draft'), 'staff', coalesce(py.staff, '[]'::jsonb),
    'staff_review', jsonb_build_object('reviewed', coalesce((py.settings->>'staff_reviewed')::boolean, false), 'by', py.settings->>'staff_by', 'at', py.settings->>'staff_at'));
end $$;

-- A person's own figures (reliefs, other income, accommodation, documents, tax, bill, certificate) are left out for those
-- who may not see them, and so are the checks about them. The staff and their pay are for those who see the money.
create or replace function private.pit_mask(p_comp jsonb, p_acc jsonb) returns jsonb
language sql stable set search_path = public, private as $$
  select case when coalesce((p_acc->>'all')::boolean, false) or p_comp is null or p_comp->'people' is null then p_comp
  else p_comp || jsonb_build_object(
    'people', (select coalesce(jsonb_agg(case when p->>'person_id' = p_acc->>'me' then p
        else (p - 'reliefs' - 'other_income' - 'opening' - 'assessment' - 'payment_url' - 'bf' - 'accommodation' - 'accommodation_carried' - 'pension_details'
            - 'relief_docs' - 'reliefs_claimed' - 'reliefs_held' - 'income_fields' - 'bill' - 'paid_at' - 'payment_ref' - 'tcc' - 'computation_path') || jsonb_build_object('hidden', true,
          'computation', jsonb_build_object('rows', (select coalesce(jsonb_agg(r), '[]'::jsonb) from jsonb_array_elements(p->'computation'->'rows') r where r->>'id' in ('S1', 'S2', 'S3')),
            'figures', jsonb_build_object('share_pct', p->'computation'->'figures'->'share_pct', 'share_profit', p->'computation'->'figures'->'share_profit',
              'remuneration', p->'computation'->'figures'->'remuneration', 'business_income', p->'computation'->'figures'->'business_income'))) end), '[]'::jsonb)
      from jsonb_array_elements(p_comp->'people') p),
    'figures', (p_comp->'figures') - 'tax' - 'payable' - 'cgt' - 'wht_credit_used',
    'cf', null, 'staff', case when coalesce((p_acc->>'money')::boolean, false) then p_comp->'staff' end,
    'checks', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_array_elements(coalesce(p_comp->'checks', '[]'::jsonb)) k
               where (k->>'person_id' is null or k->>'person_id' = p_acc->>'me') and (k->>'id' is distinct from 'staff_pay' or coalesce((p_acc->>'money')::boolean, false)))) end
$$;

-- An approved year's people with where each return stands now, its bill, payment and certificate.
create or replace function private.pit_live(p_org uuid, p_year int, p_comp jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when p_comp is null or p_comp->'people' is null then p_comp else p_comp || jsonb_build_object('people',
    (select coalesce(jsonb_agg(case when y.person_id is null then x else x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'flux_message', y.flux_message, 'flux_sent_at', y.flux_sent_at, 'filed_at', y.filed_at, 'filed_by_business', y.filed_by_business,
        'acknowledgement_ref', y.acknowledgement_ref, 'assessment', y.assessment, 'payment_url', y.payment_url, 'bill', y.bill, 'paid_at', y.paid_at,
        'payment_ref', y.payment_ref, 'tcc', coalesce(y.tcc, '{}'::jsonb) || jsonb_build_object('years', private.pit_tcc_years(p_org, p_year, y.person_id, y.tcc)),
        'computation_path', y.computation_path) end order by o.n), '[]'::jsonb)
     from jsonb_array_elements(p_comp->'people') with ordinality o(x, n)
     left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (o.x->>'person_id')::uuid)) end
$$;

-- One year, for its screens: also the documents each relief needs and which portal logins the business has saved.
create or replace function public.pit_year(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare acc jsonb; py public.pit_years; comp jsonb; v_cit jsonb; v_draft boolean; v_all boolean; v_books boolean; p record;
begin
  acc := private.pit_access(p_org);
  if p_year < 2025 or p_year > 2100 then raise exception 'Counta prepares personal income tax from 2025 accounts.'; end if;
  v_all := (acc->>'all')::boolean;
  v_books := (acc->>'books')::boolean or v_all;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  v_draft := coalesce(py.status, 'draft') = 'draft';
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.pit_live(p_org, p_year, private.pit_run(p_org, p_year));
  if private.can_handle_money(p_org) then
    v_cit := public.cit_year(p_org, p_year);
    v_cit := v_cit || jsonb_build_object('can_edit', coalesce((v_cit->>'can_edit')::boolean, false) and v_draft);
  end if;
  return jsonb_build_object('kind', private.income_tax_kind(p_org, p_year), 'computation', private.pit_mask(comp, acc), 'state', private.pit_state(p_org, p_year),
    'row', jsonb_build_object('status', coalesce(py.status, 'draft'), 'settings', coalesce(py.settings, '{}'::jsonb), 'soa_path', py.soa_path,
      'approved_at', py.approved_at, 'approved_by', (select display_name from members where id = py.approved_by), 'attested', py.snapshot->'attested',
      'updated_at', py.updated_at),
    'cit', v_cit,
    'people_all', (select coalesce(jsonb_agg(jsonb_build_object('id', pp.id, 'name', pp.name, 'tin', pp.tin, 'member_id', pp.member_id, 'active', pp.active,
        'source', pp.source) order by pp.sort, pp.created_at), '[]'::jsonb) from pit_people pp where pp.org_id = p_org),
    'members', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('id', mm.id, 'name', mm.display_name, 'role', mm.role) order by mm.display_name), '[]'::jsonb)
        from members mm where mm.org_id = p_org and mm.status = 'active' and mm.practice_id is null) end,
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'authority', private.state_code(l.state), 'is_main', l.is_main)
        order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name) order by a.sort) from tax_authorities a),
    'needs_setup', not exists (select 1 from pit_people where org_id = p_org),
    'suggested', case when not exists (select 1 from pit_people where org_id = p_org) then
        coalesce((select jsonb_agg(d->>'name') from orgs o, jsonb_array_elements(case when jsonb_typeof(o.directors) = 'array' then o.directors else '[]'::jsonb end) d
                  where o.id = p_org and coalesce(d->>'name', '') <> ''), '[]'::jsonb) end,
    'can', jsonb_build_object('see_all', v_all, 'edit_business', v_books and v_draft, 'edit_people', v_all and v_draft,
      'edit_self', acc->>'me' is not null and v_draft, 'approve', v_all, 'owner', (acc->>'owner')::boolean),
    'me', acc->'me', 'period', jsonb_build_object('from', p.pfrom, 'to', p.pto), 'relief_needs', private.pit_relief_needs(),
    'logins', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'status', l.status, 'tax_office', l.tax_office,
        'username_hint', l.username_hint)), '[]'::jsonb) from portal_logins l where l.org_id = p_org) end);
end $$;

-- ---------------------------------------------------------------------------
-- 8. What a person brings to a year, now with what the portal asks for
-- ---------------------------------------------------------------------------
-- Partners' shares, roles, offices and pay are set by those who file tax; a person linked to a team member may enter their
-- own state, reliefs, other income, amounts brought forward, accommodation, pension details and documents.
-- p: {share_pct, role, office_location_id, residence, resident, remuneration, remuneration_note, included,
--     opening: {losses_bf, ca_bf}, reliefs: {pension, nhf, nhis, life_insurance, home_loan_interest, gratuity, rent_paid},
--     other_income: [{kind, field, label, amount, tax_deducted, final_tax}],
--     accommodation: {address, type, occupancy, landlord_name, landlord_id, landlord_address, rent_paid, rent_paid_by_employer, started_on, ended_on},
--     pension_details: {rsa_number, pfa}, relief_docs: {relief: [{doc, path, name}] | null}}
-- field says which line of the portal's statement of income a line goes on: salary, commission or allowance for a job;
-- pension or annuity for a pension. For a tenant, rent relief is the rent in the accommodation, less what an employer paid.
create or replace function public.save_pit_person_year(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare acc jsonb; m public.members; py public.pit_years; d jsonb; k text; v_kinds text[]; x jsonb; v_oi jsonb := '[]'::jsonb; v_rl jsonb := '{}'::jsonb; v_n numeric;
  v_self_keys text[] := array['residence', 'resident', 'reliefs', 'other_income', 'opening', 'accommodation', 'pension_details', 'relief_docs'];
  v_field text; a jsonb; v_acc jsonb; v_pen jsonb; v_rsa text; y public.pit_person_years; v_docs jsonb; v_needs jsonb := private.pit_relief_needs();
  v_ids text[]; v_list jsonb; f jsonb; v_pre text; v_at text; per record; v_net numeric;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if p_year < 2025 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  if not exists (select 1 from pit_people where id = p_person and org_id = p_org) then raise exception 'That person is not in this business.'; end if;
  if not (acc->>'all')::boolean then
    if acc->>'me' is distinct from p_person::text then raise exception 'Only those who file tax change another person''s return.' using errcode = '42501'; end if;
    for k in select jsonb_object_keys(p) loop
      if not k = any(v_self_keys) then raise exception 'Your share, role, office and pay are set by whoever files the business''s tax.' using errcode = '42501'; end if;
    end loop;
  end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(array['share_pct', 'role', 'office_location_id', 'residence', 'resident', 'remuneration', 'remuneration_note', 'included', 'opening', 'reliefs', 'other_income',
                         'accommodation', 'pension_details', 'relief_docs']) then
      raise exception 'Unknown field %.', k;
    end if;
  end loop;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  select pfrom, pto into per from private.cit_period(p_org, p_year);

  -- Validate.
  if p ? 'share_pct' and (private.num(p->>'share_pct') is null or private.num(p->>'share_pct') < 0 or private.num(p->>'share_pct') > 100) then
    raise exception 'A share of the profit is between 0%% and 100%%.';
  end if;
  if p ? 'role' and p->>'role' not in ('proprietor', 'active', 'dormant') then raise exception 'Choose whether the partner works in the business or is dormant.'; end if;
  if nullif(p->>'office_location_id', '') is not null and not exists (select 1 from locations where id = (p->>'office_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose one of the business''s offices.';
  end if;
  if nullif(p->>'residence', '') is not null and not exists (select 1 from tax_authorities where code = p->>'residence' and kind = 'state') then
    raise exception 'Choose the state.';
  end if;
  if p ? 'remuneration' and (private.num(p->>'remuneration') is null or private.num(p->>'remuneration') < 0) then raise exception 'Enter the pay as an amount of zero or more.'; end if;
  if p ? 'reliefs' then
    if jsonb_typeof(p->'reliefs') <> 'object' then raise exception 'Reliefs are {pension, nhf, ...}.'; end if;
    for k in select jsonb_object_keys(p->'reliefs') loop
      if not k = any(array['pension', 'nhf', 'nhis', 'life_insurance', 'home_loan_interest', 'gratuity', 'rent_paid']) then raise exception 'Unknown relief %.', k; end if;
      continue when jsonb_typeof(p->'reliefs'->k) = 'null' or coalesce(p->'reliefs'->>k, '') = '';
      v_n := private.num(p->'reliefs'->>k);
      if v_n is null or v_n < 0 then raise exception 'Enter % as an amount of zero or more.', replace(k, '_', ' '); end if;
      if v_n > 0 then v_rl := jsonb_set(v_rl, array[k], to_jsonb(round(v_n, 2))); end if;
    end loop;
  end if;
  if p ? 'other_income' then
    if jsonb_typeof(p->'other_income') <> 'array' then raise exception 'Other income is a list.'; end if;
    v_kinds := array(select jsonb_array_elements_text((private.pit_rulebook(p_year)).config->'other_income'->'kinds'));
    for x in select value from jsonb_array_elements(p->'other_income') loop
      continue when coalesce(private.num(x->>'amount'), 0) = 0 and coalesce(trim(x->>'label'), '') = '';
      if not coalesce(x->>'kind', '') = any(v_kinds) then raise exception 'Choose what kind of income "%" is.', coalesce(nullif(trim(x->>'label'), ''), x->>'kind', 'this line'); end if;
      if private.num(x->>'amount') is null or private.num(x->>'amount') <= 0 then raise exception 'Enter the amount of "%".', coalesce(nullif(x->>'label', ''), x->>'kind'); end if;
      if coalesce(private.num(x->>'tax_deducted'), 0) < 0 or coalesce(private.num(x->>'tax_deducted'), 0) > private.num(x->>'amount') then
        raise exception 'The tax deducted from "%" is more than the income.', coalesce(nullif(x->>'label', ''), x->>'kind');
      end if;
      v_field := nullif(x->>'field', '');
      if v_field is not null and not ((x->>'kind' = 'employment' and v_field in ('salary', 'commission', 'allowance'))
                                      or (x->>'kind' = 'pension_gratuity' and v_field in ('pension', 'annuity'))) then
        raise exception 'The return has no % line for that kind of income.', v_field;
      end if;
      v_oi := v_oi || jsonb_build_array(jsonb_build_object('kind', x->>'kind', 'label', left(coalesce(nullif(trim(x->>'label'), ''), initcap(replace(x->>'kind', '_', ' '))), 120),
        'amount', round(private.num(x->>'amount'), 2), 'tax_deducted', round(coalesce(private.num(x->>'tax_deducted'), 0), 2))
        || case when x ? 'final_tax' and jsonb_typeof(x->'final_tax') = 'boolean' then jsonb_build_object('final_tax', (x->>'final_tax')::boolean) else '{}'::jsonb end
        || case when v_field is not null then jsonb_build_object('field', v_field) else '{}'::jsonb end);
    end loop;
    if jsonb_array_length(v_oi) > 40 then raise exception 'At most 40 lines of other income.'; end if;
  end if;
  if p ? 'opening' and (jsonb_typeof(p->'opening') <> 'object' or coalesce(private.num(p->'opening'->>'losses_bf'), 0) < 0 or coalesce(private.num(p->'opening'->>'ca_bf'), 0) < 0) then
    raise exception 'Amounts brought forward are zero or more.';
  end if;

  -- Where the person lived: the portal's accommodation disclosure.
  if p ? 'accommodation' then
    a := p->'accommodation';
    if jsonb_typeof(a) <> 'object' then raise exception 'The accommodation is {address, type, occupancy, ...}.'; end if;
    for k in select jsonb_object_keys(a) loop
      if not k = any(array['address', 'type', 'occupancy', 'landlord_name', 'landlord_id', 'landlord_address', 'rent_paid', 'rent_paid_by_employer', 'started_on', 'ended_on']) then
        raise exception 'Unknown accommodation field %.', k;
      end if;
    end loop;
    if nullif(a->>'type', '') is not null and a->>'type' not in ('flat', 'room', 'bungalow', 'duplex', 'terrace', 'detached', 'other') then raise exception 'Choose the kind of home.'; end if;
    if nullif(a->>'occupancy', '') is not null and a->>'occupancy' not in ('tenant', 'owner', 'employer', 'family') then raise exception 'Choose whether they rent the home, own it, or live there another way.'; end if;
    for k in select unnest(array['rent_paid', 'rent_paid_by_employer']) loop
      if coalesce(a->>k, '') <> '' and (private.num(a->>k) is null or private.num(a->>k) < 0) then raise exception 'Enter the rent as an amount of zero or more.'; end if;
    end loop;
    if coalesce(private.num(a->>'rent_paid_by_employer'), 0) > coalesce(private.num(a->>'rent_paid'), 0) and a->>'occupancy' = 'tenant' then
      raise exception 'The rent an employer paid is more than the rent.';
    end if;
    for k in select unnest(array['started_on', 'ended_on']) loop
      if coalesce(a->>k, '') <> '' and a->>k !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the dates as days.'; end if;
    end loop;
    if coalesce(a->>'started_on', '') <> '' and (a->>'started_on')::date > per.pto then raise exception 'They moved in after the year ended: enter the home they lived in during %.', p_year; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < coalesce(nullif(a->>'started_on', '')::date, per.pfrom) then raise exception 'They moved out before they moved in.'; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < per.pfrom then raise exception 'They moved out before the year began: enter the home they lived in during %.', p_year; end if;
    v_acc := jsonb_strip_nulls(jsonb_build_object('address', left(nullif(trim(coalesce(a->>'address', '')), ''), 300), 'type', nullif(a->>'type', ''),
      'occupancy', nullif(a->>'occupancy', ''), 'landlord_name', left(nullif(trim(coalesce(a->>'landlord_name', '')), ''), 120),
      'landlord_id', left(nullif(trim(coalesce(a->>'landlord_id', '')), ''), 60), 'landlord_address', left(nullif(trim(coalesce(a->>'landlord_address', '')), ''), 300),
      'rent_paid', round(nullif(private.num(a->>'rent_paid'), 0), 2), 'rent_paid_by_employer', round(nullif(private.num(a->>'rent_paid_by_employer'), 0), 2),
      'started_on', nullif(a->>'started_on', ''), 'ended_on', nullif(a->>'ended_on', '')));
  end if;
  if p ? 'pension_details' then
    if jsonb_typeof(p->'pension_details') <> 'object' then raise exception 'The pension details are {rsa_number, pfa}.'; end if;
    for k in select jsonb_object_keys(p->'pension_details') loop
      if k not in ('rsa_number', 'pfa') then raise exception 'Unknown pension detail %.', k; end if;
    end loop;
    v_rsa := nullif(upper(regexp_replace(coalesce(p->'pension_details'->>'rsa_number', ''), '\s', '', 'g')), '');
    if v_rsa is not null and v_rsa !~ '^[A-Z]{0,4}[0-9]{6,20}$' then raise exception 'An RSA number is PEN followed by twelve digits.'; end if;
    v_pen := jsonb_strip_nulls(jsonb_build_object('rsa_number', v_rsa, 'pfa', left(nullif(trim(coalesce(p->'pension_details'->>'pfa', '')), ''), 120)));
  end if;

  -- The person's row for the year starts from what the year already gives them.
  select x2 into d from jsonb_array_elements(private.pit_people_year(p_org, p_year)) x2 where (x2->>'person_id')::uuid = p_person;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, updated_by)
  values (p_org, p_year, p_person, private.num(d->>'share_pct'), d->>'role', nullif(d->>'office_location_id', '')::uuid, nullif(d->>'residence', ''),
    coalesce((d->>'resident')::boolean, true), m.id)
  on conflict (org_id, accounting_year, person_id) do nothing;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;

  -- The documents for each relief, replacing those of each relief given (null or [] removes them).
  if p ? 'relief_docs' then
    if jsonb_typeof(p->'relief_docs') <> 'object' then raise exception 'The documents are {relief: [file]}.'; end if;
    v_docs := coalesce(y.relief_docs, '{}'::jsonb);
    for k in select jsonb_object_keys(p->'relief_docs') loop
      if not (v_needs ? k) or jsonb_array_length(coalesce(v_needs->k->'docs', '[]'::jsonb)) = 0 then raise exception 'There are no documents to attach for %.', replace(k, '_', ' '); end if;
      if jsonb_typeof(p->'relief_docs'->k) = 'null' then v_docs := v_docs - k; continue; end if;
      if jsonb_typeof(p->'relief_docs'->k) <> 'array' then raise exception 'The documents for % are a list.', replace(k, '_', ' '); end if;
      if jsonb_array_length(p->'relief_docs'->k) > 10 then raise exception 'At most 10 documents for each relief.'; end if;
      v_ids := array(select e->>'id' from jsonb_array_elements(v_needs->k->'docs') e);
      v_pre := p_org::text || '/tax/pit/' || p_year || '/people/' || p_person::text || '/' || k || '/';
      v_list := '[]'::jsonb;
      for f in select value from jsonb_array_elements(p->'relief_docs'->k) loop
        if not coalesce(f->>'doc', '') = any(v_ids) then raise exception 'That is not one of the documents for %.', replace(k, '_', ' '); end if;
        if left(coalesce(f->>'path', ''), length(v_pre)) <> v_pre or f->>'path' ~ '\.\.' or length(f->>'path') > 400 then raise exception 'That file is not this person''s.'; end if;
        select e->>'at' into v_at from jsonb_array_elements(case when jsonb_typeof(y.relief_docs->k) = 'array' then y.relief_docs->k else '[]'::jsonb end) e where e->>'path' = f->>'path' limit 1;
        v_list := v_list || jsonb_build_array(jsonb_build_object('doc', f->>'doc', 'path', f->>'path',
          'name', left(coalesce(nullif(trim(coalesce(f->>'name', '')), ''), split_part(f->>'path', '/', -1)), 160), 'at', coalesce(v_at, now()::text)));
      end loop;
      v_docs := case when jsonb_array_length(v_list) = 0 then v_docs - k else v_docs || jsonb_build_object(k, v_list) end;
    end loop;
  end if;

  update pit_person_years set
    share_pct = case when p ? 'share_pct' then round(private.num(p->>'share_pct'), 4) else share_pct end,
    role = case when p ? 'role' then p->>'role' else role end,
    office_location_id = case when p ? 'office_location_id' then nullif(p->>'office_location_id', '')::uuid else office_location_id end,
    residence = case when p ? 'residence' then nullif(p->>'residence', '') else residence end,
    resident = case when p ? 'resident' then coalesce((p->>'resident')::boolean, true) else resident end,
    remuneration = case when p ? 'remuneration' then round(private.num(p->>'remuneration'), 2) else remuneration end,
    remuneration_note = case when p ? 'remuneration_note' then nullif(left(trim(p->>'remuneration_note'), 300), '') else remuneration_note end,
    included = case when p ? 'included' then coalesce((p->>'included')::boolean, true) else included end,
    opening = case when p ? 'opening' then jsonb_strip_nulls(jsonb_build_object('losses_bf', round(nullif(private.num(p->'opening'->>'losses_bf'), 0), 2),
      'ca_bf', round(nullif(private.num(p->'opening'->>'ca_bf'), 0), 2))) else opening end,
    reliefs = case when p ? 'reliefs' then v_rl else reliefs end,
    other_income = case when p ? 'other_income' then v_oi else other_income end,
    accommodation = case when p ? 'accommodation' then v_acc else accommodation end,
    pension_details = case when p ? 'pension_details' then v_pen else pension_details end,
    relief_docs = case when p ? 'relief_docs' then v_docs else relief_docs end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person
  returning * into y;

  -- Rent relief follows the accommodation: a tenant's rent, less any part an employer paid. Saving a home that is not
  -- rented takes the rent relief away.
  if y.accommodation->>'occupancy' = 'tenant' then
    v_net := round(coalesce(private.num(y.accommodation->>'rent_paid'), 0) - coalesce(private.num(y.accommodation->>'rent_paid_by_employer'), 0), 2);
    update pit_person_years set reliefs = case when v_net > 0 then reliefs || jsonb_build_object('rent_paid', v_net) else reliefs - 'rent_paid' end
    where org_id = p_org and accounting_year = p_year and person_id = p_person;
  elsif p ? 'accommodation' then
    update pit_person_years set reliefs = reliefs - 'rent_paid' where org_id = p_org and accounting_year = p_year and person_id = p_person;
  end if;
  update pit_years set updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- The business's side of the year, now with its employees for the portal's staff screen.
-- p: {mixed_use: {template cell: business share % | null}, mixed_use_reviewed, soa_path, notes,
--     staff: [{name, role, annual_pay, tin}], staff_reviewed}. Saving the staff (even none) confirms them.
create or replace function public.save_pit_year(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare acc jsonb; m public.members; py public.pit_years; v_set jsonb; x record; v_cells text[]; v_n numeric; s jsonb; v_staff jsonb; v_tin text;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if not ((acc->>'all')::boolean or (acc->>'books')::boolean) then raise exception 'Your role does not allow this (keep books).' using errcode = '42501'; end if;
  if p_year < 2025 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  v_set := coalesce(py.settings, '{}'::jsonb);
  for x in select key, value from jsonb_each(p) loop
    if x.key not in ('mixed_use', 'mixed_use_reviewed', 'soa_path', 'notes', 'staff', 'staff_reviewed') then raise exception 'Unknown setting %.', x.key; end if;
  end loop;
  if p ? 'mixed_use' then
    if jsonb_typeof(p->'mixed_use') <> 'object' then raise exception 'Mixed use is {line: business share %%}.'; end if;
    v_cells := array(select l->>'cell' from jsonb_array_elements((private.pit_rulebook(p_year)).config->'business'->'mixed_use'->'lines') l);
    for x in select key, value from jsonb_each(p->'mixed_use') loop
      if not x.key = any(v_cells) then raise exception 'That line is not one the rule book treats as mixed use.'; end if;
      if jsonb_typeof(x.value) = 'null' then v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) - x.key); continue; end if;
      v_n := private.num(x.value #>> '{}');
      if v_n is null or v_n < 0 or v_n > 100 then raise exception 'The business share of a mixed-use expense is between 0%% and 100%%.'; end if;
      v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) || jsonb_build_object(x.key, round(v_n, 2)));
    end loop;
    v_set := v_set || jsonb_build_object('mixed_use_reviewed', true, 'mixed_use_by', m.display_name, 'mixed_use_at', now());
  end if;
  if p ? 'mixed_use_reviewed' then v_set := v_set || jsonb_build_object('mixed_use_reviewed', coalesce((p->>'mixed_use_reviewed')::boolean, false)); end if;
  if p ? 'notes' then v_set := case when coalesce(trim(p->>'notes'), '') = '' then v_set - 'notes' else v_set || jsonb_build_object('notes', left(trim(p->>'notes'), 2000)) end; end if;
  if p ? 'staff' then
    if jsonb_typeof(p->'staff') <> 'array' then raise exception 'Staff is a list.'; end if;
    if jsonb_array_length(p->'staff') > 500 then raise exception 'At most 500 employees.'; end if;
    v_staff := '[]'::jsonb;
    for s in select value from jsonb_array_elements(p->'staff') loop
      continue when coalesce(trim(s->>'name'), '') = '' and coalesce(private.num(s->>'annual_pay'), 0) = 0 and coalesce(trim(s->>'role'), '') = '';
      if length(trim(coalesce(s->>'name', ''))) < 2 then raise exception 'Enter each employee''s name.'; end if;
      if private.num(s->>'annual_pay') is null or private.num(s->>'annual_pay') < 0 then raise exception 'Enter %''s pay for the year.', trim(s->>'name'); end if;
      v_tin := nullif(regexp_replace(coalesce(s->>'tin', ''), '\s', '', 'g'), '');
      if v_tin is not null and v_tin !~ '^[0-9][0-9-]{6,15}$' then raise exception 'A Tax ID is digits (with dashes, if any).'; end if;
      v_staff := v_staff || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('name', left(trim(s->>'name'), 120),
        'role', left(nullif(trim(coalesce(s->>'role', '')), ''), 80), 'annual_pay', round(private.num(s->>'annual_pay'), 2), 'tin', v_tin)));
    end loop;
    v_set := v_set || jsonb_build_object('staff_reviewed', true, 'staff_by', m.display_name, 'staff_at', now());
  end if;
  if p ? 'staff_reviewed' then
    v_set := v_set || jsonb_build_object('staff_reviewed', coalesce((p->>'staff_reviewed')::boolean, false), 'staff_by', m.display_name, 'staff_at', now());
  end if;
  if p ? 'soa_path' then
    if nullif(p->>'soa_path', '') is not null and split_part(p->>'soa_path', '/', 1) <> p_org::text then raise exception 'That file is not this business''s.'; end if;
  end if;
  update pit_years set settings = v_set, soa_path = case when p ? 'soa_path' then nullif(p->>'soa_path', '') else soa_path end,
    staff = case when p ? 'staff' then v_staff else staff end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- Approving keeps each person's accommodation and pension details with their row, so the next year starts from them.
create or replace function public.approve_pit_year(p_org uuid, p_year int, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; comp jsonb; v_blocks text; x jsonb; v_statement text;
begin
  m := private.require(p_org, 'file_tax');
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if py.status <> 'draft' then raise exception 'The % return is already %.', p_year, replace(py.status, '_', ' '); end if;
  if not coalesce((p->>'attest')::boolean, false) then raise exception 'Confirm the statement of accounts before approving.'; end if;
  comp := private.pit_run(p_org, p_year);
  select string_agg(k->>'text', ' ') into v_blocks from jsonb_array_elements(comp->'checks') k where k->>'severity' = 'block';
  if v_blocks is not null then raise exception 'Not ready: %', v_blocks; end if;
  v_statement := 'I confirm that the statement of accounts for ' || coalesce((select name from orgs where id = p_org), 'the business') || ' for the year ended '
    || private.fdate((comp->>'to')::date) || ' is a true and correct account of its income and expenses, and that the people, shares and reliefs in this return are as stated.';
  for x in select value from jsonb_array_elements(comp->'people') loop
    insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, remuneration, reliefs, other_income, opening,
      accommodation, pension_details, status, updated_by)
    values (p_org, p_year, (x->>'person_id')::uuid, private.num(x->>'share_pct'), x->>'role', nullif(x->>'office_location_id', '')::uuid, nullif(x->>'residence', ''),
      coalesce((x->>'resident')::boolean, true), coalesce(private.num(x->>'remuneration'), 0), coalesce(x->'reliefs', '{}'::jsonb), coalesce(x->'other_income', '[]'::jsonb),
      coalesce(x->'opening', '{}'::jsonb), coalesce(x->'accommodation', '{}'::jsonb), coalesce(x->'pension_details', '{}'::jsonb), 'approved', m.id)
    on conflict (org_id, accounting_year, person_id) do update set share_pct = excluded.share_pct, role = excluded.role, status = 'approved',
      accommodation = case when pit_person_years.accommodation = '{}'::jsonb then excluded.accommodation else pit_person_years.accommodation end,
      pension_details = case when pit_person_years.pension_details = '{}'::jsonb then excluded.pension_details else pit_person_years.pension_details end,
      flux_status = null, flux_message = null, updated_by = m.id, updated_at = now();
  end loop;
  update pit_years set status = 'approved', approved_by = m.id, approved_at = now(), rulebook_id = comp->'rulebook'->>'id',
    snapshot = jsonb_build_object('computation', comp,
      'org', (select jsonb_build_object('name', name, 'tin', tin, 'rc_number', rc_number, 'address', coalesce(registered_office, address), 'taxstreem_org_id', taxstreem_org_id,
        'legal_form', legal_form) from orgs where id = p_org),
      'attested', jsonb_build_object('by', m.display_name, 'at', now(), 'statement', v_statement),
      'approved_by', m.display_name, 'approved_at', now()),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- Reopening also drops the computation made for the portal: the next approval makes a new one.
create or replace function public.reopen_pit_year(p_org uuid, p_year int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or py.status <> 'approved' then raise exception 'Only an approved return can be reopened.'; end if;
  if exists (select 1 from pit_person_years where org_id = p_org and accounting_year = p_year and status in ('sent', 'filed')) then
    raise exception 'A return in this year is with Flux or filed. File an amended return with the state instead.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why the return is reopened.'; end if;
  update pit_years set status = 'draft', snapshot = null, approved_by = null, approved_at = null,
    settings = settings || jsonb_build_object('reopened', jsonb_build_object('by', m.display_name, 'at', now(), 'reason', left(trim(p_reason), 300))),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  update pit_person_years set status = 'draft', flux_ref = null, flux_status = null, flux_message = null, flux_sent_at = null, computation_path = null,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- For the tax-files function, asked as the person: the approved year and each person's return, for Flux, with the
-- portal's lines, the staff, the fixed assets and the business's logins (Flux's references, never a password).
create or replace function public.pit_pack(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; comp jsonb;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' or py.snapshot is null then raise exception 'Approve the % return before sending it.', p_year; end if;
  comp := py.snapshot->'computation';
  return jsonb_build_object('org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'from', comp->>'from', 'to', comp->>'to', 'regime', comp->>'regime',
    'kind', comp->>'kind', 'due', comp->>'due', 'org', py.snapshot->'org', 'attested', py.snapshot->'attested', 'approved_by', py.snapshot->>'approved_by',
    'approved_at', py.snapshot->>'approved_at', 'soa_path', py.soa_path, 'business', comp->'business'->'rows', 'business_figures', comp->'business'->'figures',
    'flux_authorities', comp->'flux_authorities', 'rulebook', comp->'rulebook',
    'staff', coalesce(comp->'staff', '[]'::jsonb), 'staff_review', comp->'staff_review', 'portal_ready', comp ? 'staff_review', 'relief_needs', private.pit_relief_needs(),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('number', a->>'number', 'name', a->>'name', 'category', a->>'category', 'cost', a->'qce', 'in_use', a->>'in_use',
        'first_year', a->'first_year', 'use_pct', a->'use_pct', 'tax_value_bf', a->'twdv_bf', 'allowance', a->'allowance', 'tax_value_cf', a->'twdv_cf',
        'disposed', a->'disposed', 'proceeds', a->'proceeds', 'qualifies', a->'qualifies')), '[]'::jsonb)
      from jsonb_array_elements(coalesce(comp->'business'->'ca'->'assets', '[]'::jsonb)) a),
    'logins', (select coalesce(jsonb_object_agg(l.authority, jsonb_build_object('flux_ref', l.flux_ref, 'tax_office', l.tax_office, 'status', l.status)), '{}'::jsonb)
      from portal_logins l where l.org_id = p_org),
    'people', (select coalesce(jsonb_agg(x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'computation_path', y.computation_path, 'income_fields', coalesce(x->'income_fields', private.pit_portal_income(x->'computation')))), '[]'::jsonb)
      from jsonb_array_elements(comp->'people') x
      left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (x->>'person_id')::uuid));
end $$;

-- ---------------------------------------------------------------------------
-- 9. Flux reporting on one person's return (service role): the filing, then the pay bill, the payment and the
--    tax clearance certificate
-- ---------------------------------------------------------------------------
-- p: {status, ref, message, acknowledgement_ref, filed_at, assessment, payment_url,
--     bill: {amount, reference, agency, revenue, payer_id, payment_url (https), generated_at, expires_at},
--     paid: {paid_at, reference, amount},
--     tcc: {status: requested | processing | issued | rejected, ref, number, issued_at, expires_on, message}}
-- Each part may come alone. The bill, the payment and the certificate follow the filing.
create or replace function public.svc_pit_flux_update(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare py public.pit_years; y public.pit_person_years; v_status text := nullif(p->>'status', ''); v_name text; v_bill jsonb; v_paid jsonb; v_tcc jsonb; v_t text;
  v_amt numeric; v_filed boolean;
begin
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' then raise exception 'The % return is not approved.', p_year; end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  if not found then raise exception 'No such person in the % return.', p_year; end if;
  if v_status is not null and v_status not in ('sent', 'processing', 'filed', 'rejected', 'send_failed') then raise exception 'Unknown status %.', v_status; end if;
  -- A filed return stays filed: a late "sent" or "rejected" for it is ignored, while its bill, payment and certificate still count.
  if y.status = 'filed' and v_status in ('sent', 'processing', 'rejected', 'send_failed') then
    if not (jsonb_typeof(p->'bill') = 'object' or jsonb_typeof(p->'paid') = 'object' or jsonb_typeof(p->'tcc') = 'object') then
      return jsonb_build_object('person_id', p_person, 'status', y.status, 'flux_ref', y.flux_ref, 'unchanged', true);
    end if;
    v_status := null;
  end if;
  v_filed := y.status = 'filed' or coalesce(v_status, '') = 'filed';
  select name into v_name from pit_people where id = p_person;

  if jsonb_typeof(p->'bill') = 'object' then
    if not v_filed then raise exception 'The return is not filed yet: the bill follows the filing.'; end if;
    v_amt := private.num(p->'bill'->>'amount');
    if v_amt is null or v_amt < 0 then raise exception 'bill.amount is an amount of zero or more.'; end if;
    if coalesce(p->'bill'->>'payment_url', '') !~ '^https://' then raise exception 'bill.payment_url must be an https link.'; end if;
    v_bill := jsonb_strip_nulls(jsonb_build_object('amount', round(v_amt, 2), 'reference', left(nullif(p->'bill'->>'reference', ''), 80),
      'agency', left(nullif(p->'bill'->>'agency', ''), 160), 'revenue', left(nullif(p->'bill'->>'revenue', ''), 160), 'payer_id', left(nullif(p->'bill'->>'payer_id', ''), 80),
      'payment_url', left(p->'bill'->>'payment_url', 1000), 'generated_at', coalesce(nullif(p->'bill'->>'generated_at', '')::timestamptz, now()),
      'expires_at', nullif(p->'bill'->>'expires_at', '')::timestamptz));
  end if;
  if jsonb_typeof(p->'paid') = 'object' then
    if not v_filed then raise exception 'The return is not filed yet.'; end if;
    v_paid := jsonb_strip_nulls(jsonb_build_object('paid_at', coalesce(nullif(p->'paid'->>'paid_at', '')::timestamptz, now()),
      'reference', left(nullif(p->'paid'->>'reference', ''), 120), 'amount', round(private.num(p->'paid'->>'amount'), 2)));
  end if;
  if jsonb_typeof(p->'tcc') = 'object' then
    v_t := p->'tcc'->>'status';
    if v_t is null or v_t not in ('requested', 'processing', 'issued', 'rejected') then raise exception 'tcc.status must be requested, processing, issued or rejected.'; end if;
    if not v_filed then raise exception 'The return is not filed yet: the certificate follows the filing.'; end if;
    if v_t = 'issued' and coalesce(p->'tcc'->>'number', '') = '' then raise exception 'An issued certificate has its number.'; end if;
    v_tcc := coalesce(y.tcc, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('status', v_t, 'ref', left(nullif(p->'tcc'->>'ref', ''), 120),
      'number', left(nullif(p->'tcc'->>'number', ''), 80), 'issued_at', nullif(p->'tcc'->>'issued_at', '')::timestamptz,
      'expires_on', nullif(p->'tcc'->>'expires_on', '')::date, 'message', left(nullif(p->'tcc'->>'message', ''), 1000),
      'requested_at', case when v_t = 'requested' then now() end, 'updated_at', now()));
    if v_t <> 'rejected' then v_tcc := v_tcc - 'message' || jsonb_strip_nulls(jsonb_build_object('message', left(nullif(p->'tcc'->>'message', ''), 1000))); end if;
  end if;

  update pit_person_years set
    status = case when v_status in ('sent', 'filed', 'rejected') then v_status else status end,
    flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref),
    flux_status = coalesce(v_status, flux_status),
    flux_message = case when p ? 'message' then left(p->>'message', 1000) else flux_message end,
    flux_sent_at = case when v_status = 'sent' then now() else flux_sent_at end,
    flux_updated_at = now(),
    filed_at = case when v_status = 'filed' then coalesce(nullif(p->>'filed_at', '')::timestamptz, now()) else filed_at end,
    acknowledgement_ref = coalesce(nullif(p->>'acknowledgement_ref', ''), acknowledgement_ref),
    assessment = coalesce(case when jsonb_typeof(p->'assessment') = 'object' then p->'assessment' end, assessment),
    payment_url = coalesce(v_bill->>'payment_url', case when p->>'payment_url' ~ '^https://' then left(p->>'payment_url', 1000) end, payment_url),
    bill = coalesce(v_bill, bill),
    paid_at = coalesce((v_paid->>'paid_at')::timestamptz, paid_at),
    payment_ref = coalesce(v_paid->>'reference', payment_ref),
    tcc = coalesce(v_tcc, tcc)
  where org_id = p_org and accounting_year = p_year and person_id = p_person
  returning * into y;

  if v_status in ('filed', 'rejected') then
    perform private.notify_perm(p_org, 'file_tax', 'books', v_name || '''s ' || p_year || ' income tax return ' || v_status,
      coalesce(nullif(p->>'message', ''), case when v_status = 'filed' then 'Acknowledgement ' || coalesce(p->>'acknowledgement_ref', '') else 'The state did not accept it' end),
      '/tax/pit?year=' || p_year, 'pit-' || p_year || '-' || p_person || '-' || v_status, null);
  end if;
  if v_bill is not null then
    perform private.notify_perm(p_org, 'file_tax', 'books', 'Pay ' || v_name || '''s ' || p_year || ' income tax: ' || private.naira((v_bill->>'amount')::numeric),
      'The state generated the bill' || coalesce(' ' || (v_bill->>'reference'), '') || '. Pay it through the link on the return'
        || coalesce(', before ' || private.fdate((v_bill->>'expires_at')::timestamptz::date), '') || '.',
      '/tax/pit?year=' || p_year, 'pit-' || p_year || '-' || p_person || '-bill-' || coalesce(v_bill->>'reference', to_char(now(), 'YYYYMMDDHH24MI')), null);
  end if;
  if v_paid is not null then
    perform private.notify_perm(p_org, 'file_tax', 'books', v_name || '''s ' || p_year || ' income tax is paid',
      coalesce('Receipt ' || (v_paid->>'reference'), 'The state has the payment') || '.', '/tax/pit?year=' || p_year, 'pit-' || p_year || '-' || p_person || '-paid', null);
  end if;
  if v_t in ('issued', 'rejected') then
    perform private.notify_perm(p_org, 'file_tax', 'books', v_name || '''s tax clearance certificate ' || case when v_t = 'issued' then 'is ready' else 'was refused' end,
      coalesce(nullif(p->'tcc'->>'message', ''), case when v_t = 'issued' then 'Certificate ' || (p->'tcc'->>'number') else 'The state did not issue it' end),
      '/tax/pit?year=' || p_year, 'pit-' || p_year || '-' || p_person || '-tcc-' || v_t, null);
  end if;
  return jsonb_build_object('person_id', p_person, 'status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status, 'year_state', private.pit_state(p_org, p_year),
    'bill', y.bill, 'paid_at', y.paid_at, 'tcc', y.tcc);
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.portal_logins(uuid), public.portal_login_begin(uuid, text), public.save_pit_computation_file(uuid, int, uuid, text),
  public.save_pit_tcc(uuid, int, uuid, jsonb), public.pit_tcc_pack(uuid, int, uuid) from public, anon;
grant execute on function public.portal_logins(uuid), public.portal_login_begin(uuid, text), public.save_pit_computation_file(uuid, int, uuid, text),
  public.save_pit_tcc(uuid, int, uuid, jsonb), public.pit_tcc_pack(uuid, int, uuid) to authenticated;
revoke execute on function public.svc_portal_login_saved(uuid, text, jsonb), public.svc_portal_login_removed(uuid, text), public.svc_portal_login_status(uuid, text, jsonb),
  public.svc_pit_flux_update(uuid, int, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_portal_login_saved(uuid, text, jsonb), public.svc_portal_login_removed(uuid, text), public.svc_portal_login_status(uuid, text, jsonb),
  public.svc_pit_flux_update(uuid, int, uuid, jsonb) to service_role;
-- The private PIT functions are for the database's own functions; the storage rule's check is the one exception.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and (p.proname like 'pit\_%' or p.proname = 'portal_of') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function private.pit_doc_path_ok(text) to authenticated;
