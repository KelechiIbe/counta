-- Counta: financial statements ready for signing. Corporate information (directors from TaxStreem onboarding), full IFRS
-- notes with the usual narrative, the directors' report (CAMA 2020), the statement of directors' responsibilities, the
-- statement of value added, the five-year financial summary, and one pack that carries all of it for Word, PDF and Excel.

-- ---------------------------------------------------------------------------
-- 1. Corporate information
-- ---------------------------------------------------------------------------
-- directors: [{name, role, frc_number, appointed, resigned}]
alter table public.orgs add column if not exists directors jsonb not null default '[]';
alter table public.orgs add column if not exists company_secretary text;
alter table public.orgs add column if not exists auditors text;
alter table public.orgs add column if not exists audit_exempt boolean not null default false;
alter table public.orgs add column if not exists bankers text;
alter table public.orgs add column if not exists solicitors text;
alter table public.orgs add column if not exists registered_office text;
alter table public.orgs add column if not exists incorporation_date date;
-- {authorised_shares, issued_shares, nominal_value}
alter table public.orgs add column if not exists share_info jsonb not null default '{}';
-- The sentences only the directors can vouch for: {approved_on, going_concern, dividend, events_after, contingencies, commitments,
-- employees_count, employees, review, future, directors_interests, pledged}
alter table public.orgs add column if not exists fs_narrative jsonb not null default '{}';

create or replace function private.clean_directors(p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare v jsonb := '[]'::jsonb; d jsonb; n int := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' then return v; end if;
  for d in select * from jsonb_array_elements(p) loop
    continue when jsonb_typeof(d) <> 'object' or coalesce(trim(d->>'name'), '') = '';
    n := n + 1;
    if n > 20 then raise exception 'Up to 20 directors.'; end if;
    if length(trim(d->>'name')) > 120 then raise exception 'A director''s name is too long.'; end if;
    if nullif(trim(d->>'appointed'), '') is not null and trim(d->>'appointed') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Check the date % was appointed.', trim(d->>'name'); end if;
    if nullif(trim(d->>'resigned'), '') is not null and trim(d->>'resigned') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Check the date % resigned.', trim(d->>'name'); end if;
    v := v || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('name', trim(d->>'name'), 'role', nullif(left(trim(d->>'role'), 60), ''),
      'frc_number', nullif(upper(left(trim(d->>'frc_number'), 40)), ''), 'appointed', nullif(trim(d->>'appointed'), ''), 'resigned', nullif(trim(d->>'resigned'), ''))));
  end loop;
  return v;
end $$;

-- Owner or the bookkeeper. Directors usually arrive from TaxStreem onboarding; this keeps them editable here.
create or replace function public.update_corporate_info(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_share jsonb; v_narr jsonb; k text; v text;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'keep_books')) then raise exception 'Only the owner or the bookkeeper changes the corporate information.' using errcode = '42501'; end if;
  if p_patch ? 'share_info' then
    if jsonb_typeof(p_patch->'share_info') <> 'object' then raise exception 'Enter the share details.'; end if;
    v_share := jsonb_strip_nulls(jsonb_build_object(
      'authorised_shares', round(private.num(p_patch->'share_info'->>'authorised_shares')),
      'issued_shares', round(private.num(p_patch->'share_info'->>'issued_shares')),
      'nominal_value', round(private.num(p_patch->'share_info'->>'nominal_value'), 4)));
    if (v_share->>'issued_shares')::numeric > (v_share->>'authorised_shares')::numeric then raise exception 'More shares are issued than authorised.'; end if;
    if exists (select 1 from jsonb_each_text(v_share) where value::numeric < 0) then raise exception 'Share numbers cannot be negative.'; end if;
  end if;
  if p_patch ? 'fs_narrative' then
    if jsonb_typeof(p_patch->'fs_narrative') <> 'object' then raise exception 'Enter the statements wording.'; end if;
    v_narr := '{}'::jsonb;
    for k, v in select key, value from jsonb_each_text(p_patch->'fs_narrative') loop
      continue when k not in ('approved_on', 'going_concern', 'dividend', 'events_after', 'contingencies', 'commitments', 'employees_count', 'employees',
        'review', 'future', 'directors_interests', 'pledged');
      v := nullif(trim(v), '');
      if k = 'approved_on' and v is not null and v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose the date the board approves the statements.'; end if;
      if k = 'employees_count' and v is not null and v !~ '^\d{1,7}$' then raise exception 'Enter the number of employees as a whole number.'; end if;
      if v is not null then v_narr := v_narr || jsonb_build_object(k, left(v, 4000)); end if;
    end loop;
  end if;
  update orgs set
    directors = case when p_patch ? 'directors' then private.clean_directors(p_patch->'directors') else directors end,
    company_secretary = case when p_patch ? 'company_secretary' then nullif(left(trim(p_patch->>'company_secretary'), 300), '') else company_secretary end,
    auditors = case when p_patch ? 'auditors' then nullif(left(trim(p_patch->>'auditors'), 300), '') else auditors end,
    audit_exempt = coalesce((p_patch->>'audit_exempt')::boolean, audit_exempt),
    bankers = case when p_patch ? 'bankers' then nullif(left(trim(p_patch->>'bankers'), 500), '') else bankers end,
    solicitors = case when p_patch ? 'solicitors' then nullif(left(trim(p_patch->>'solicitors'), 300), '') else solicitors end,
    registered_office = case when p_patch ? 'registered_office' then nullif(left(trim(p_patch->>'registered_office'), 300), '') else registered_office end,
    incorporation_date = case when p_patch ? 'incorporation_date' then private.date_or_null(p_patch->>'incorporation_date') else incorporation_date end,
    share_info = case when p_patch ? 'share_info' then v_share else share_info end,
    -- Wording is merged: keys sent empty fall back to the standard sentence.
    fs_narrative = case when p_patch ? 'fs_narrative' then (fs_narrative - (select coalesce(array_agg(key), '{}') from jsonb_object_keys(p_patch->'fs_narrative') key)) || v_narr
                        else fs_narrative end
  where id = p_org returning * into o;
  return private.corporate_json(o.id);
end $$;

create or replace function private.corporate_json(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('name', o.name, 'legal_form', o.legal_form, 'rc_number', o.rc_number, 'tin', o.tin, 'address', o.address,
    'registered_office', coalesce(o.registered_office, o.address), 'principal_activity', o.principal_activity, 'industry', o.industry,
    'incorporation_date', o.incorporation_date, 'directors', o.directors, 'company_secretary', o.company_secretary, 'auditors', o.auditors,
    'audit_exempt', o.audit_exempt, 'bankers', o.bankers, 'solicitors', o.solicitors, 'share_info', o.share_info, 'fs_narrative', o.fs_narrative,
    'framework', o.reporting_framework, 'logo_path', o.logo_path, 'brand_color', o.brand_color, 'website', o.website, 'email', o.email, 'phone', o.phone,
    'fiscal_year_start', o.fiscal_year_start)
  from orgs o where o.id = p_org
$$;

-- TaxStreem onboarding sends the directors (and other company details) in the sign-on token; each sign-on refreshes them.
-- c: {jti, sub, email, name, phone, org:{id, name, email, phone, tin, rc_number, vat_registered, address, principal_activity, incorporation_date,
--     company_secretary, directors:[{name, role, frc_number, appointed}]}, role, rail, exp}
create or replace function public.svc_sso_login(c jsonb, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_email text := lower(trim(c->>'email')); v_role text; mm public.members; p jsonb; v_new boolean := false; v_dirs jsonb;
begin
  if coalesce(c->>'jti', '') = '' or v_email is null or coalesce(c->'org'->>'id', '') = '' then raise exception 'The sign-in token is incomplete.'; end if;
  insert into sso_logins (jti, taxstreem_user_id, email, user_id) values (c->>'jti', coalesce(c->>'sub', v_email), v_email, p_user)
  on conflict (jti) do nothing;
  if not found then raise exception 'This sign-in link was already used.'; end if;
  v_role := case lower(coalesce(c->>'role', 'owner')) when 'owner' then 'owner' when 'admin' then 'manager' when 'manager' then 'manager'
    when 'accountant' then 'accountant' when 'cashier' then 'cashier' else 'staff' end;
  select id into v_org from orgs where taxstreem_org_id = c->'org'->>'id';
  if v_org is null then
    -- First visit from this TaxStreem business: create it, owned by the person signing in.
    perform set_config('request.jwt.claim.sub', p_user::text, true);
    v_org := public.create_org(coalesce(nullif(trim(c->'org'->>'name'), ''), 'My business'), coalesce(nullif(c->'org'->>'email', ''), v_email),
      nullif(c->'org'->>'phone', ''), coalesce(nullif(trim(c->>'name'), ''), split_part(v_email, '@', 1)), '[]'::jsonb,
      coalesce((c->'org'->>'vat_registered')::boolean, true), false);
    update orgs set taxstreem_org_id = c->'org'->>'id', tin = coalesce(nullif(c->'org'->>'tin', ''), tin), rc_number = coalesce(nullif(c->'org'->>'rc_number', ''), rc_number)
    where id = v_org;
    v_new := true;
  end if;
  -- Company details from onboarding: fill what is empty, and take the directors whenever TaxStreem sends them.
  begin
    v_dirs := private.clean_directors(c->'org'->'directors');
  exception when others then v_dirs := '[]'::jsonb;
  end;
  update orgs set
    directors = case when jsonb_array_length(v_dirs) > 0 then v_dirs else directors end,
    company_secretary = coalesce(company_secretary, nullif(left(trim(c->'org'->>'company_secretary'), 300), '')),
    address = coalesce(address, nullif(left(trim(c->'org'->>'address'), 300), '')),
    principal_activity = coalesce(principal_activity, nullif(left(trim(c->'org'->>'principal_activity'), 300), '')),
    incorporation_date = coalesce(incorporation_date, private.date_or_null(c->'org'->>'incorporation_date')),
    tin = coalesce(tin, nullif(c->'org'->>'tin', '')), rc_number = coalesce(rc_number, nullif(c->'org'->>'rc_number', ''))
  where id = v_org;
  if nullif(c->>'rail', '') is not null and exists (select 1 from payment_rails where code = c->>'rail' and active) then
    update orgs set payment_rail = c->>'rail' where id = v_org and payment_rail <> c->>'rail'
      and not exists (select 1 from wallets w where w.org_id = v_org and w.status = 'active');
  end if;
  select * into mm from members where org_id = v_org and (user_id = p_user or (user_id is null and lower(email) = v_email)) order by user_id nulls last limit 1;
  if mm.id is null then
    p := private.role_template(v_role);
    insert into members (org_id, user_id, email, display_name, phone, role, title, status, p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments,
      p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins, p_issue_stock, p_keep_books, p_make_payments)
    values (v_org, p_user, v_email, coalesce(nullif(trim(c->>'name'), ''), split_part(v_email, '@', 1)), nullif(c->>'phone', ''), v_role, initcap(v_role), 'active',
      (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
      (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
      (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean);
  elsif mm.user_id is null then
    update members set user_id = p_user, status = 'active' where id = mm.id;
  elsif mm.status = 'disabled' then
    raise exception 'Your access to this business has been switched off. Ask the owner.';
  end if;
  update sso_logins set org_id = v_org where jti = c->>'jti';
  return jsonb_build_object('org_id', v_org, 'new_business', v_new);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- Sum of a code-to-amount map over account families (1012 also takes 1012-01, 1012-02 ...).
create or replace function private.sum_codes(p jsonb, p_codes text[]) returns numeric
language sql immutable set search_path = '' as $$
  select coalesce(sum(value::numeric), 0) from jsonb_each_text(coalesce(p, '{}'::jsonb)) where split_part(key, '-', 1) = any(p_codes)
$$;
create or replace function private.sum_range(p jsonb, p_lo text, p_hi text) returns numeric
language sql immutable set search_path = '' as $$
  select coalesce(sum(value::numeric), 0) from jsonb_each_text(coalesce(p, '{}'::jsonb)) where split_part(key, '-', 1) between p_lo and p_hi
$$;
create or replace function private.ftxt(p text) returns jsonb language sql immutable set search_path = public, private as $$ select private.fr(p, null, null, 'text', 0) $$;
create or replace function private.fhd(p text) returns jsonb language sql immutable set search_path = public, private as $$ select private.fr(p, null, null, 'heading', 0) $$;
create or replace function private.fsh(p text) returns jsonb language sql immutable set search_path = public, private as $$ select private.fr(p, null, null, 'subheading', 0) $$;
create or replace function private.fdate(p date) returns text language sql immutable set search_path = '' as $$ select to_char(p, 'FMDD FMMonth YYYY') $$;
create or replace function private.naira(p numeric) returns text language sql immutable set search_path = '' as $$
  select case when p < 0 then '(₦' || to_char(abs(p), 'FM999,999,999,999,990.00') || ')' else '₦' || to_char(coalesce(p, 0), 'FM999,999,999,999,990.00') end
$$;
-- A line only when it has an amount now or in the comparative.
create or replace function private.fl(p_line text, p_cur numeric, p_pri numeric, p_indent int default 1) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when coalesce(p_cur, 0) <> 0 or coalesce(p_pri, 0) <> 0 then jsonb_build_array(private.fr(p_line, p_cur, p_pri, 'line', p_indent)) else '[]'::jsonb end
$$;

-- The note numbers the statements point to.
create or replace function private.note_no(p_key text) returns text
language sql immutable set search_path = '' as $$
  select case p_key when 'general' then '1' when 'basis' then '2' when 'policies' then '3' when 'judgements' then '4' when 'revenue' then '5'
    when 'cost_of_sales' then '6' when 'expenses' then '7' when 'finance' then '8' when 'pbt' then '9' when 'employees' then '10' when 'tax' then '11'
    when 'ppe' then '12' when 'intangibles' then '13' when 'inventories' then '14' when 'receivables' then '15' when 'cash' then '16' when 'equity' then '17'
    when 'borrowings' then '18' when 'payables' then '19' when 'statutory' then '20' when 'related' then '21' when 'financial_risk' then '22'
    when 'capital' then '23' when 'contingencies' then '24' when 'events_after' then '25' when 'approval' then '26' when 'unreconciled' then '27' else null end
$$;

-- Periods for a set of statements, the same way accounting_report works them out (prior year comparatives; balances against the
-- end of the previous financial year).
create or replace function private.fs_periods(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_to date; v_from date; v_pfrom date; v_pto date; v_bpto date;
begin
  v_to := coalesce(p_to, private.local_day(p_org, now()));
  v_from := coalesce(p_from, private.fy_start(p_org, v_to));
  if v_from > v_to then raise exception 'The start date is after the end date.'; end if;
  v_pto := (v_to - interval '1 year')::date; v_pfrom := (v_from - interval '1 year')::date;
  v_bpto := private.fy_start(p_org, v_to) - 1;
  return jsonb_build_object('from', v_from, 'to', v_to, 'prior_from', v_pfrom, 'prior_to', v_pto, 'balance_prior_to', v_bpto,
    'full_year', v_from = private.fy_start(p_org, v_to) and v_to = (private.fy_start(p_org, v_to) + interval '1 year' - interval '1 day')::date);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Statement rows with note references on every line that has a note
-- ---------------------------------------------------------------------------
create or replace function private.sofp_rows(c jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; l text; v_nca numeric; v_ncap numeric; v_ca numeric; v_cap numeric; v_eq numeric; v_eqp numeric; v_ncl numeric; v_nclp numeric;
  v_cl numeric; v_clp numeric;
  nca text[] := array['Property, plant and equipment', 'Intangible assets', 'Right-of-use assets', 'Investments in subsidiaries and associates', 'Investment property',
    'Other financial assets', 'Deferred tax assets', 'Other non-current assets'];
  ca text[] := array['Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments', 'Other current financial assets', 'Current tax assets',
    'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)'];
  eq text[] := array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings', 'Opening balances to be confirmed', 'Non-controlling interests'];
  ncl text[] := array['Borrowings (non-current)', 'Lease liabilities (non-current)', 'Deferred tax liabilities', 'Other non-current liabilities'];
  cl text[] := array['Trade and other payables', 'Contract liabilities', 'Current tax liabilities', 'Other statutory liabilities', 'Bank overdrafts', 'Borrowings (current)',
    'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities', 'Unreconciled balances (liabilities)'];
begin
  v := v || private.fr('Assets', null, null, 'heading', 0) || private.fr('Non-current assets', null, null, 'subheading', 0);
  v_nca := 0; v_ncap := 0;
  foreach l in array nca loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Property, plant and equipment' then private.note_no('ppe')
        when 'Right-of-use assets' then private.note_no('ppe') when 'Intangible assets' then private.note_no('intangibles')
        when 'Deferred tax assets' then private.note_no('tax') when 'Other financial assets' then private.note_no('financial_risk') end);
      v_nca := v_nca + private.v(c, l); v_ncap := v_ncap + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total non-current assets', v_nca, v_ncap, 'subtotal', 0) || private.fr('Current assets', null, null, 'subheading', 0);
  v_ca := 0; v_cap := 0;
  foreach l in array ca loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Inventories' then private.note_no('inventories')
        when 'Trade and other receivables' then private.note_no('receivables') when 'Contract assets' then private.note_no('receivables')
        when 'Prepayments' then private.note_no('receivables') when 'Other current assets' then private.note_no('receivables')
        when 'Current tax assets' then private.note_no('tax') when 'Cash and cash equivalents' then private.note_no('cash')
        when 'Unreconciled balances (assets)' then private.note_no('unreconciled') end);
      v_ca := v_ca + private.v(c, l); v_cap := v_cap + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total current assets', v_ca, v_cap, 'subtotal', 0) || private.fr('Total assets', v_nca + v_ca, v_ncap + v_cap, 'total', 0)
    || private.fr('', null, null, 'blank', 0) || private.fr('Equity and liabilities', null, null, 'heading', 0) || private.fr('Equity', null, null, 'subheading', 0);
  v_eq := 0; v_eqp := 0;
  foreach l in array eq loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case when l <> 'Non-controlling interests' then private.note_no('equity') end);
      v_eq := v_eq + private.v(c, l); v_eqp := v_eqp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total equity', v_eq, v_eqp, 'subtotal', 0) || private.fr('Non-current liabilities', null, null, 'subheading', 0);
  v_ncl := 0; v_nclp := 0;
  foreach l in array ncl loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case when l like 'Borrowings%' or l like 'Lease%' then private.note_no('borrowings')
        when l = 'Deferred tax liabilities' then private.note_no('tax') when l = 'Other non-current liabilities' then private.note_no('payables') end);
      v_ncl := v_ncl + private.v(c, l); v_nclp := v_nclp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total non-current liabilities', v_ncl, v_nclp, 'subtotal', 0) || private.fr('Current liabilities', null, null, 'subheading', 0);
  v_cl := 0; v_clp := 0;
  foreach l in array cl loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Trade and other payables' then private.note_no('payables')
        when 'Contract liabilities' then private.note_no('payables') when 'Provisions (current)' then private.note_no('payables')
        when 'Other current liabilities' then private.note_no('payables') when 'Current tax liabilities' then private.note_no('tax')
        when 'Other statutory liabilities' then private.note_no('statutory') when 'Borrowings (current)' then private.note_no('borrowings')
        when 'Lease liabilities (current)' then private.note_no('borrowings') when 'Bank overdrafts' then private.note_no('cash')
        when 'Unreconciled balances (liabilities)' then private.note_no('unreconciled') end);
      v_cl := v_cl + private.v(c, l); v_clp := v_clp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total current liabilities', v_cl, v_clp, 'subtotal', 0) || private.fr('Total liabilities', v_ncl + v_cl, v_nclp + v_clp, 'subtotal', 0)
    || private.fr('Total equity and liabilities', v_eq + v_ncl + v_cl, v_eqp + v_nclp + v_clp, 'total', 0);
  return v;
end $$;

create or replace function private.sopl_rows(c jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; gp numeric; gpp numeric; op numeric; opp numeric; pbt numeric; pbtp numeric; pat numeric; patp numeric; oci numeric; ocip numeric;
begin
  gp := private.v(c, 'Revenue') + private.v(c, 'Cost of sales'); gpp := private.v(p, 'Revenue') + private.v(p, 'Cost of sales');
  v := v || private.fr('Revenue', private.v(c, 'Revenue'), private.v(p, 'Revenue'), 'line', 0, private.note_no('revenue'))
    || private.fr('Cost of sales', private.v(c, 'Cost of sales'), private.v(p, 'Cost of sales'), 'line', 0, private.note_no('cost_of_sales'))
    || private.fr('Gross profit', gp, gpp, 'subtotal', 0);
  op := gp; opp := gpp;
  for i in 1 .. 7 loop
    declare l text := (array['Other income', 'Selling and distribution expenses', 'Administrative expenses', 'Impairment losses on financial assets',
      'Other operating expenses', 'Other gains and losses', 'Other expenses'])[i];
    begin
      if private.v(c, l) <> 0 or private.v(p, l) <> 0 or l in ('Administrative expenses') then
        v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 0, case when l = 'Impairment losses on financial assets' then private.note_no('receivables')
          else private.note_no('expenses') end);
      end if;
      op := op + private.v(c, l); opp := opp + private.v(p, l);
    end;
  end loop;
  v := v || private.fr('Operating profit', op, opp, 'subtotal', 0)
    || private.fr('Finance income', private.v(c, 'Finance income'), private.v(p, 'Finance income'), 'line', 0, private.note_no('finance'))
    || private.fr('Finance costs', private.v(c, 'Finance costs'), private.v(p, 'Finance costs'), 'line', 0, private.note_no('finance'));
  pbt := op + private.v(c, 'Finance income') + private.v(c, 'Finance costs'); pbtp := opp + private.v(p, 'Finance income') + private.v(p, 'Finance costs');
  v := v || private.fr('Profit before tax', pbt, pbtp, 'subtotal', 0, private.note_no('pbt'))
    || private.fr('Income tax expense', private.v(c, 'Income tax expense'), private.v(p, 'Income tax expense'), 'line', 0, private.note_no('tax'));
  pat := pbt + private.v(c, 'Income tax expense'); patp := pbtp + private.v(p, 'Income tax expense');
  v := v || private.fr('Profit for the period', pat, patp, 'total', 0) || private.fr('Other comprehensive income', null, null, 'subheading', 0)
    || private.fr('Items that will not be reclassified to profit or loss', private.v(c, 'Items that will not be reclassified to profit or loss'),
         private.v(p, 'Items that will not be reclassified to profit or loss'), 'line', 1)
    || private.fr('Items that may be reclassified to profit or loss', private.v(c, 'Items that may be reclassified to profit or loss'),
         private.v(p, 'Items that may be reclassified to profit or loss'), 'line', 1)
    || private.fr('Income tax relating to other comprehensive income', private.v(c, 'Income tax relating to other comprehensive income'),
         private.v(p, 'Income tax relating to other comprehensive income'), 'line', 1);
  oci := private.v(c, 'Items that will not be reclassified to profit or loss') + private.v(c, 'Items that may be reclassified to profit or loss')
       + private.v(c, 'Income tax relating to other comprehensive income');
  ocip := private.v(p, 'Items that will not be reclassified to profit or loss') + private.v(p, 'Items that may be reclassified to profit or loss')
       + private.v(p, 'Income tax relating to other comprehensive income');
  v := v || private.fr('Other comprehensive income for the period', oci, ocip, 'subtotal', 0)
    || private.fr('Total comprehensive income for the period', pat + oci, patp + ocip, 'total', 0);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Notes to the financial statements
-- ---------------------------------------------------------------------------
-- Every figure comes from the ledger; every sentence the books cannot know comes from fs_narrative, with the usual wording when it is empty.
-- p_bpto: the date balances are compared at (end of the previous financial year); p_pfrom..p_pto: the comparative period.
create or replace function private.note_rows(p_org uuid, p_from date, p_to date, p_pfrom date, p_pto date, p_bpto date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v jsonb := '[]'::jsonb; r record; c jsonb; p jsonb; plc jsonb; plp jsonb; tc jsonb; tp jsonb;
  mvc jsonb; mvp jsonb; drc jsonb; crc jsonb; balc jsonb; balo jsonb; balp jsonb; v_bpto date := coalesce(p_bpto, p_pto); n jsonb; v_mv jsonb;
  v_fw text; v_ifrs boolean; v_nta boolean; v_co boolean; v_period text; v_ended text; v_cmp text; v_x numeric; v_y numeric; v_z numeric; v_w numeric;
  v_rate numeric; v_pbt numeric; v_pbtp numeric; v_tax numeric; v_taxp numeric; v_ca numeric; v_cl numeric; v_eq numeric; v_cash numeric; v_debt numeric;
  v_txt text; v_lives text; v_name text; v_dirs text; v_start int;
begin
  select * into o from orgs where id = p_org;
  n := coalesce(o.fs_narrative, '{}'::jsonb);
  c := private.sofp_map(p_org, p_to);
  p := case when v_bpto is null then '{}'::jsonb else private.sofp_map(p_org, v_bpto) end;
  plc := private.pl_map(p_org, p_from, p_to);
  plp := case when p_pfrom is null then '{}'::jsonb else private.pl_map(p_org, p_pfrom, p_pto) end;
  tc := private.pl_totals(plc); tp := private.pl_totals(plp);
  select coalesce(jsonb_object_agg(code, net), '{}'), coalesce(jsonb_object_agg(code, dr), '{}'), coalesce(jsonb_object_agg(code, cr), '{}') into mvc, drc, crc
    from private.movement(p_org, p_from, p_to);
  select coalesce(jsonb_object_agg(code, net), '{}') into mvp from private.movement(p_org, coalesce(p_pfrom, p_from), coalesce(p_pto, p_from - 1)) where p_pfrom is not null;
  select coalesce(jsonb_object_agg(code, bal), '{}') into balc from private.balances_at(p_org, p_to);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balo from private.balances_at(p_org, p_from - 1);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balp from private.balances_at(p_org, v_bpto) where v_bpto is not null;
  mvp := coalesce(mvp, '{}'); balp := coalesce(balp, '{}');
  v_ifrs := coalesce(o.reporting_framework, 'ifrs') <> 'ifrs_sme';
  v_fw := case when v_ifrs then 'IFRS Accounting Standards as issued by the International Accounting Standards Board (IASB)' else 'the IFRS for SMEs Accounting Standard issued by the IASB' end;
  v_nta := p_to >= date '2026-01-01';
  v_co := coalesce(o.legal_form, 'company') = 'company';
  v_ended := private.fdate(p_to);
  v_period := case when private.fs_periods(p_org, p_from, p_to)->>'full_year' = 'true' then 'year ended ' || v_ended else 'period from ' || private.fdate(p_from) || ' to ' || v_ended end;
  v_cmp := case when v_bpto is null then '' else to_char(v_bpto, 'YYYY') end;
  v_name := case when v_co then 'the Company' else 'the business' end;
  select string_agg(d->>'name' || coalesce(' (' || (d->>'role') || ')', ''), ', ') into v_dirs from jsonb_array_elements(o.directors) d;

  -- 1 ----------------------------------------------------------------------
  v := v || private.fhd('1. General information')
    || private.ftxt(o.name || case when v_co then ' ("the Company") is a private limited liability company incorporated in Nigeria under the Companies and Allied Matters Act'
         else ' ("the business") is registered in Nigeria' end
         || coalesce(' on ' || private.fdate(o.incorporation_date), '') || coalesce(' with registration number RC ' || nullif(regexp_replace(o.rc_number, '^\s*RC\s*', '', 'i'), ''), '') || '.'
         || coalesce(' Its registered office is at ' || nullif(coalesce(o.registered_office, o.address), '') || '.', ''))
    || private.ftxt('The principal activity of ' || v_name || ' is ' || coalesce(nullif(o.principal_activity, ''), replace(coalesce(o.industry, 'trading'), '_', ' ')) || '.'
         || coalesce(' Its tax identification number is ' || nullif(o.tin, '') || '.', ''))
    || private.ftxt('These financial statements are for the ' || v_period || '.');

  -- 2 ----------------------------------------------------------------------
  v := v || private.fhd('2. Basis of preparation')
    || private.fsh('2.1 Statement of compliance')
    || private.ftxt('The financial statements have been prepared in accordance with ' || v_fw || ', and comply with the requirements of the Companies and Allied Matters Act 2020'
         || ' and the Financial Reporting Council of Nigeria Act 2011 (as amended).')
    || private.fsh('2.2 Basis of measurement')
    || private.ftxt('The financial statements are prepared on the historical cost basis, except where a policy below states otherwise.')
    || private.fsh('2.3 Functional and presentation currency')
    || private.ftxt('The financial statements are presented in Nigerian naira (₦), the functional currency of ' || v_name || '. Amounts are shown to the nearest kobo.')
    || private.fsh('2.4 Going concern');
  v_ca := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments',
    'Other current financial assets', 'Current tax assets', 'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)'));
  v_cl := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Trade and other payables', 'Contract liabilities', 'Current tax liabilities',
    'Other statutory liabilities', 'Bank overdrafts', 'Borrowings (current)', 'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities',
    'Unreconciled balances (liabilities)'));
  v_eq := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Share capital', 'Share premium', 'Deposit for shares', 'Other reserves',
    'Retained earnings', 'Opening balances to be confirmed', 'Non-controlling interests'));
  v := v || private.ftxt(coalesce(n->>'going_concern', 'The directors have assessed the ability of ' || v_name || ' to continue as a going concern and are satisfied that it has the resources'
         || ' to continue in business for at least twelve months from the date these financial statements are approved. The financial statements are therefore prepared on the going concern basis.'));
  if v_cl > v_ca + 0.005 or v_eq < -0.005 then
    v := v || private.ftxt('At ' || v_ended || ', ' || case when v_cl > v_ca + 0.005 then 'current liabilities exceeded current assets by ' || private.naira(v_cl - v_ca) else '' end
      || case when v_cl > v_ca + 0.005 and v_eq < -0.005 then ' and ' else '' end
      || case when v_eq < -0.005 then 'total liabilities exceeded total assets by ' || private.naira(-v_eq) else '' end
      || '. The directors have taken this into account in their assessment.');
  end if;
  v := v || private.fsh('2.5 Use of judgements and estimates')
    || private.ftxt('Preparing financial statements requires the directors to make judgements, estimates and assumptions that affect the application of accounting policies and the reported amounts'
         || ' of assets, liabilities, income and expenses. Estimates are reviewed on an ongoing basis and revisions are recognised prospectively. The judgements and estimates with the most significant effect are described in note 4.')
    || private.fsh('2.6 Comparative information')
    || case when p_pfrom is null then private.ftxt('These are the first financial statements prepared from these books, so no comparative figures are presented.')
       else private.ftxt('Comparative figures for profit or loss, other comprehensive income and cash flows are for ' || private.fdate(p_pfrom) || ' to ' || private.fdate(p_pto)
         || '. Comparative balances are at ' || private.fdate(v_bpto) || case when v_bpto <> p_pto then ', the end of the previous financial year' else '' end || '.') end
    || private.fsh('2.7 New and amended standards');
  v_start := extract(year from private.fy_start(p_org, p_to))::int;
  if not v_ifrs then
    v := v || private.ftxt(case when v_start >= 2027 then 'The third edition of the IFRS for SMEs Accounting Standard, issued in February 2025, is effective for periods beginning on or after 1 January 2027 and has been applied.'
      else 'The third edition of the IFRS for SMEs Accounting Standard, issued in February 2025, is effective for periods beginning on or after 1 January 2027. The directors are assessing its effect; the main changes concern revenue (a new section aligned with IFRS 15), fair value measurement and the expected credit loss model for financial assets.' end);
  elsif v_start >= 2027 then
    v := v || private.ftxt('IFRS 18 Presentation and Disclosure in Financial Statements, which replaces IAS 1, and IFRS 19 Subsidiaries without Public Accountability: Disclosures are effective for annual periods beginning on or after 1 January 2027.'
      || ' IFRS 18 changes the structure of the statement of profit or loss into operating, investing and financing categories and requires disclosure of management-defined performance measures.');
  elsif v_start = 2026 then
    v := v || private.ftxt('The following amendments are effective for periods beginning on or after 1 January 2026 and have no material effect on these financial statements: Amendments to the Classification and Measurement of Financial Instruments (IFRS 9 and IFRS 7);'
        || ' Contracts Referencing Nature-dependent Electricity (IFRS 9 and IFRS 7); and Annual Improvements to IFRS Accounting Standards, Volume 11.')
      || private.ftxt('IFRS 18 Presentation and Disclosure in Financial Statements, which replaces IAS 1, and IFRS 19 Subsidiaries without Public Accountability: Disclosures have been issued and are effective for annual periods beginning on or after 1 January 2027.'
        || ' They have not been applied early. IFRS 18 will change the structure of the statement of profit or loss and add disclosure of management-defined performance measures; the directors are assessing its effect.');
  else
    v := v || private.ftxt('Lack of Exchangeability (Amendments to IAS 21) is effective for periods beginning on or after 1 January 2025 and has no material effect on these financial statements.')
      || private.ftxt('The following have been issued but are not yet effective and have not been applied early: Amendments to the Classification and Measurement of Financial Instruments (IFRS 9 and IFRS 7),'
        || ' Contracts Referencing Nature-dependent Electricity and Annual Improvements Volume 11 (all effective 1 January 2026); and IFRS 18 Presentation and Disclosure in Financial Statements and IFRS 19'
        || ' Subsidiaries without Public Accountability: Disclosures (effective 1 January 2027). The directors are assessing their effect.');
  end if;

  -- 3 ----------------------------------------------------------------------
  select string_agg(ac.name || ' ' || case when ac.default_life_months % 12 = 0 then (ac.default_life_months / 12)::text || ' years' else ac.default_life_months::text || ' months' end, '; ' order by ac.cost_account)
    into v_lives from asset_classes ac where ac.depreciates and (private.sum_codes(balc, array[ac.cost_account]) <> 0 or private.sum_codes(balp, array[ac.cost_account]) <> 0);
  v := v || private.fhd('3. Material accounting policies')
    || private.ftxt('The accounting policies below have been applied consistently to all periods presented.')
    || private.fsh('3.1 Revenue from contracts with customers (IFRS 15)')
    || private.ftxt('Revenue is recognised when control of goods or services passes to the customer, at the amount ' || v_name || ' expects to be entitled to, excluding value added tax and net of discounts, rebates and returns.'
         || ' Sales of goods are recognised at a point in time, when the goods are collected by or delivered to the customer. Services are recognised as they are performed.')
    || private.ftxt('Invoices are generally due within ' || coalesce(o.invoice_terms_days, 30) || ' days and contain no significant financing component. Amounts received before goods or services are delivered are contract liabilities until the performance obligation is met.'
         || ' Where customers have a right of return, revenue is reduced by the returns expected and a refund liability is recognised.')
    || private.fsh('3.2 Foreign currency transactions (IAS 21)')
    || private.ftxt('Transactions in foreign currencies are translated into naira at the exchange rate on the date of the transaction. Monetary assets and liabilities in foreign currencies are retranslated at the closing rate at the reporting date.'
         || ' Exchange differences are recognised in profit or loss.')
    || private.fsh('3.3 Financial instruments (IFRS 9)')
    || private.ftxt('Financial assets and liabilities are recognised when ' || v_name || ' becomes party to the contractual provisions of the instrument. Trade receivables without a significant financing component are measured initially at the transaction price; other financial instruments at fair value plus transaction costs.')
    || private.ftxt('Trade and other receivables and cash and cash equivalents are held to collect contractual cash flows that are solely payments of principal and interest, and are measured at amortised cost.'
         || ' Trade and other payables and borrowings are financial liabilities measured at amortised cost.')
    || private.ftxt('Impairment: loss allowances on trade receivables are measured at lifetime expected credit losses using the simplified approach, through a provision matrix based on how long amounts have been overdue,'
         || ' adjusted for forward-looking information. A receivable is written off when there is no reasonable expectation of recovery.')
    || private.ftxt('A financial asset is derecognised when the rights to its cash flows expire or are transferred; a financial liability when it is discharged, cancelled or expires.')
    || private.fsh('3.4 Cash and cash equivalents')
    || private.ftxt('Cash and cash equivalents comprise cash in hand, balances with banks and payment wallets, and short-term deposits with original maturities of three months or less.'
         || ' Bank overdrafts repayable on demand form part of cash management and are included in cash and cash equivalents in the statement of cash flows.')
    || private.fsh('3.5 Inventories (IAS 2)')
    || private.ftxt('Inventories are measured at the lower of cost and net realisable value. Cost is determined on the weighted average basis and includes purchase price, import duties, freight and other costs of bringing inventories to their present location and condition.'
         || ' Net realisable value is the estimated selling price less the costs of completion and sale. Write-downs to net realisable value are recognised in profit or loss in the period they occur.')
    || private.fsh('3.6 Property, plant and equipment (IAS 16)')
    || private.ftxt('Items of property, plant and equipment are measured at cost less accumulated depreciation and impairment losses. Cost includes expenditure directly attributable to bringing the asset into use.'
         || ' Purchases below ' || private.naira(o.capitalisation_threshold) || ' are expensed. Subsequent costs are capitalised only when it is probable that future economic benefits will flow from them; repairs and maintenance are expensed as incurred.')
    || private.ftxt('Depreciation is charged on a straight-line basis over the estimated useful life of each asset from the date it is available for use. Land and assets under construction are not depreciated.'
         || coalesce(' The useful lives used are: ' || v_lives || '.', ''))
    || private.ftxt('Useful lives, residual values and depreciation methods are reviewed at each reporting date. Gains and losses on disposal are recognised in profit or loss.')
    || private.fsh('3.7 Intangible assets (IAS 38)')
    || private.ftxt('Intangible assets acquired separately, such as computer software, are measured at cost less accumulated amortisation and impairment, and amortised on a straight-line basis over their useful lives, generally three to five years.')
    || private.fsh('3.8 Impairment of non-financial assets (IAS 36)')
    || private.ftxt('At each reporting date the carrying amounts of non-financial assets are reviewed for indications of impairment. Where such an indication exists, the recoverable amount is estimated and an impairment loss is recognised in profit or loss for any excess of carrying amount over recoverable amount.')
    || private.fsh('3.9 Leases (IFRS 16)')
    || private.ftxt('At the start of a lease a right-of-use asset and a lease liability are recognised. The lease liability is measured at the present value of the lease payments, discounted at the rate implicit in the lease or the incremental borrowing rate;'
         || ' the right-of-use asset is depreciated over the shorter of the lease term and its useful life. Payments for short-term leases of twelve months or less and leases of low-value assets are expensed on a straight-line basis.')
    || private.fsh('3.10 Employee benefits (IAS 19)')
    || private.ftxt('Salaries, allowances and other short-term benefits are expensed as the related service is provided. ' || (upper(left(v_name, 1)) || substr(v_name, 2)) || ' operates a defined contribution pension scheme under the Pension Reform Act 2014,'
         || ' contributing at least 10% of qualifying emoluments while employees contribute at least 8%. Contributions are expensed when due; there is no further obligation once they are paid.')
    || private.fsh('3.11 Provisions and contingent liabilities (IAS 37)')
    || private.ftxt('A provision is recognised when there is a present obligation from a past event, an outflow of resources is probable and the amount can be estimated reliably. Contingent liabilities are not recognised but are disclosed unless an outflow is remote.')
    || private.fsh('3.12 Taxation (IAS 12)')
    || case when v_nta then private.ftxt('Current tax is the tax expected to be payable on the taxable profit for the period under the Nigeria Tax Act 2025: companies income tax at 30% of assessable profits and the development levy at 4%,'
         || ' together with any top-up to the 15% minimum effective tax rate where it applies. Small companies, as defined in the Act, are exempt from companies income tax and the development levy.')
       else private.ftxt('Current tax is the tax expected to be payable on the taxable profit for the period under the Companies Income Tax Act, at the rate that applies to ' || v_name
         || '''s size (30% for large companies, 20% for medium-sized companies and nil for small companies), together with tertiary education tax at 3% of assessable profits.') end
    || private.ftxt('Deferred tax is recognised on temporary differences between the carrying amounts of assets and liabilities and their tax bases, using rates enacted at the reporting date.'
         || ' Deferred tax assets are recognised only to the extent that taxable profits are expected to be available to use them.')
    || private.ftxt('Revenue, expenses and assets are recognised net of value added tax where the input tax is recoverable. Withholding tax deducted by customers is held as an asset and set against income tax payable.')
    || private.fsh('3.13 Share capital and dividends (IAS 32)')
    || private.ftxt('Ordinary shares are classified as equity. Dividends are recognised as a liability in the period in which they are approved by the shareholders.')
    || private.fsh('3.14 Events after the reporting period (IAS 10)')
    || private.ftxt('Events after the reporting date that provide evidence of conditions at the reporting date are adjusted for. Material events that arise after the reporting date are disclosed.');

  -- 4 ----------------------------------------------------------------------
  v := v || private.fhd('4. Critical accounting judgements and key sources of estimation uncertainty')
    || private.fsh('Expected credit losses on trade receivables')
    || private.ftxt('The loss allowance depends on loss rates by ageing band, taken from collection experience and adjusted for current and forward-looking conditions. At ' || v_ended
         || ' the allowance was ' || private.naira(-private.sum_codes(balc, array['1103'])) || ' against gross trade receivables of ' || private.naira(private.sum_codes(balc, array['1101', '1102'])) || '.')
    || private.fsh('Net realisable value of inventories')
    || private.ftxt('Slow-moving, expired and damaged items are written down to the amount expected to be realised, using recent selling prices and stock counts. Write-downs charged in the period were '
         || private.naira(private.sum_codes(mvc, array['6805'])) || '.')
    || private.fsh('Useful lives of property, plant and equipment')
    || private.ftxt('Depreciation depends on the useful lives and residual values set for each class of asset, which are reviewed each year against how the assets are used and maintained.')
    || private.fsh('Income taxes')
    || private.ftxt('Determining the tax charge requires judgement on the deductibility of expenses and the tax treatment of transactions. Where the final outcome differs from the amounts recorded, the difference affects the tax charge of the period in which it is determined.');

  -- 5 Revenue ------------------------------------------------------------
  v := v || private.fhd('5. Revenue');
  v_mv := (select jsonb_agg(private.fr(m.name, -private.v(mvc, m.code), case when p_pfrom is null then null else -private.v(mvp, m.code) end, 'line', 1) order by m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line = 'Revenue' and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, '[]'::jsonb) || private.fr('Total revenue', private.v(plc, 'Revenue'), private.v(plp, 'Revenue'), 'subtotal', 0);
  v := v || private.fsh('Disaggregation of revenue');
  select coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.kind = 'goods' or l.kind = 'delivery'), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.kind = 'service'), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where s.export), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where not s.export), 0)
    into v_x, v_y, v_z, v_w
  from sales s join sale_lines l on l.sale_id = s.id where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
    and s.issue_date between p_from and p_to;
  v := v || private.fr('Goods, recognised at a point in time', v_x, null, 'line', 1) || private.fl('Services', v_y, null)
    || private.fr('Customers in Nigeria', v_w, null, 'line', 1) || private.fl('Exports to customers outside Nigeria (zero-rated)', v_z, null)
    || coalesce((select jsonb_agg(private.fr('By channel: ' || x.label, x.amt, null, 'line', 1) order by x.amt desc) from (
        select case s.channel when 'till' then 'shop counter' when 'online' then 'online shop' when 'invoice' then 'invoiced sales' when 'van' then 'van sales'
          when 'whatsapp' then 'WhatsApp' when 'phone' then 'phone orders' else s.channel end label,
          sum(case when s.doc_type = 'credit_note' then -s.subtotal else s.subtotal end) amt from sales s
        where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to group by 1) x where x.amt <> 0), '[]'::jsonb);
  v := v || private.ftxt('Revenue recorded directly in the ledger (for example from bank receipts) is included in the totals above but not in the analysis by sale document.')
    || private.fsh('Contract balances')
    || private.fr('Trade receivables', private.sum_codes(balc, array['1101', '1102']), private.sum_codes(balp, array['1101', '1102']), 'line', 1)
    || private.fr('Contract liabilities (advances from customers)', -private.sum_codes(balc, array['2107']), -private.sum_codes(balp, array['2107']), 'line', 1);

  -- 6 Cost of sales --------------------------------------------------------
  v := v || private.fhd('6. Cost of sales');
  v_mv := (select jsonb_agg(private.fr(m.name, private.v(mvc, m.code), case when p_pfrom is null then null else private.v(mvp, m.code) end, 'line', 1) order by m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line = 'Cost of sales' and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, '[]'::jsonb) || private.fr('Total cost of sales', -private.v(plc, 'Cost of sales'), -private.v(plp, 'Cost of sales'), 'subtotal', 0)
    || private.ftxt('The cost of inventories recognised as an expense was ' || private.naira(private.sum_codes(mvc, array['5400', '5401'])) || '.');

  -- 7 Other income and operating expenses ------------------------------------
  v := v || private.fhd('7. Other income and operating expenses');
  for r in select * from (values (1, 'Other income', array['Other income', 'Other gains and losses'], -1), (2, 'Selling and distribution expenses', array['Selling and distribution expenses'], 1),
      (3, 'Administrative expenses', array['Administrative expenses'], 1), (4, 'Other operating expenses', array['Other operating expenses', 'Other expenses'], 1)) t(k, title, lines, sg) loop
    v_mv := (select jsonb_agg(private.fr(m.name, r.sg * private.v(mvc, m.code), case when p_pfrom is null then null else r.sg * private.v(mvp, m.code) end, 'line', 1) order by m.code)
      from private.acct_meta(p_org) m where m.statement = 'pl' and (m.ifrs_line = any(r.lines) or (r.k = 4 and m.ifrs_line = 'Unclassified'))
        and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
    continue when v_mv is null;
    v := v || private.fsh(r.title) || v_mv
      || private.fr('Total ' || lower(r.title), r.sg * -(select coalesce(sum(private.v(plc, x)), 0) from unnest(r.lines) x),
           case when p_pfrom is null then null else r.sg * -(select coalesce(sum(private.v(plp, x)), 0) from unnest(r.lines) x) end, 'subtotal', 0);
  end loop;

  -- 8 Finance income and costs ------------------------------------------------
  v := v || private.fhd('8. Finance income and finance costs');
  v_mv := (select jsonb_agg(private.fr(m.name, case when m.ifrs_line = 'Finance income' then -1 else 1 end * private.v(mvc, m.code),
      case when p_pfrom is null then null else case when m.ifrs_line = 'Finance income' then -1 else 1 end * private.v(mvp, m.code) end, 'line', 1) order by m.ifrs_line desc, m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line in ('Finance income', 'Finance costs') and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, private.ftxt('There was no finance income and no finance costs in the period.'))
    || private.fr('Net finance (costs) / income', private.v(plc, 'Finance income') + private.v(plc, 'Finance costs'), private.v(plp, 'Finance income') + private.v(plp, 'Finance costs'), 'subtotal', 0);

  -- 9 Profit before tax --------------------------------------------------------
  v := v || private.fhd('9. Profit before taxation') || private.ftxt('Profit before taxation is stated after charging / (crediting):')
    || private.fl('Depreciation of property, plant and equipment', private.sum_codes(mvc, array['5204', '6901']), private.sum_codes(mvp, array['5204', '6901']))
    || private.fl('Depreciation of right-of-use assets', private.sum_codes(mvc, array['6902']), private.sum_codes(mvp, array['6902']))
    || private.fl('Amortisation of intangible assets', private.sum_codes(mvc, array['5205', '6903']), private.sum_codes(mvp, array['5205', '6903']))
    || private.fl('Staff costs (note 10)', private.sum_codes(mvc, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']),
         private.sum_codes(mvp, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']))
    || private.fl('Directors'' emoluments (note 10)', private.sum_codes(mvc, array['6109', '6110']), private.sum_codes(mvp, array['6109', '6110']))
    || private.fl('Auditors'' remuneration', private.sum_codes(mvc, array['6501']), private.sum_codes(mvp, array['6501']))
    || private.fl('Rent on short-term leases', private.sum_codes(mvc, array['6201', '5301']), private.sum_codes(mvp, array['6201', '5301']))
    || private.fl('Impairment losses on trade receivables and bad debts', private.sum_codes(mvc, array['6801', '6802']), private.sum_codes(mvp, array['6801', '6802']))
    || private.fl('Inventory write-downs', private.sum_codes(mvc, array['6805']), private.sum_codes(mvp, array['6805']))
    || private.fl('Donations', private.sum_codes(mvc, array['6904']), private.sum_codes(mvp, array['6904']))
    || private.fl('Bank charges', private.sum_codes(mvc, array['6701']), private.sum_codes(mvp, array['6701']))
    || private.fl('Net foreign exchange loss / (gain)', private.sum_codes(mvc, array['6703', '6704', '4510', '4511']), private.sum_codes(mvp, array['6703', '6704', '4510', '4511']))
    || private.fl('Net loss / (gain) on disposal of property, plant and equipment', private.sum_codes(mvc, array['6804', '4508']), private.sum_codes(mvp, array['6804', '4508']))
    || private.fl('Interest income', private.sum_codes(mvc, array['4502', '4503']), private.sum_codes(mvp, array['4502', '4503']));

  -- 10 Staff costs and directors' emoluments ---------------------------------------
  v := v || private.fhd('10. Staff costs and directors'' emoluments') || private.fsh('Staff costs')
    || private.fl('Salaries and wages', private.sum_codes(mvc, array['5201', '5304', '6101']), private.sum_codes(mvp, array['5201', '5304', '6101']))
    || private.fl('Allowances and other benefits', private.sum_codes(mvc, array['6102', '6103', '6106', '6108']), private.sum_codes(mvp, array['6102', '6103', '6106', '6108']))
    || private.fl('Employer pension contributions', private.sum_codes(mvc, array['6104']), private.sum_codes(mvp, array['6104']))
    || private.fl('Gratuity', private.sum_codes(mvc, array['6105']), private.sum_codes(mvp, array['6105']))
    || private.fl('Training and development', private.sum_codes(mvc, array['6107']), private.sum_codes(mvp, array['6107']))
    || private.fl('Contract staff and other staff costs', private.sum_codes(mvc, array['6111', '6112', '6113', '6114']), private.sum_codes(mvp, array['6111', '6112', '6113', '6114']))
    || private.fr('Total staff costs', private.sum_codes(mvc, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']),
         private.sum_codes(mvp, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']), 'subtotal', 0)
    || case when nullif(n->>'employees_count', '') is not null then private.ftxt('The average number of persons employed during the period was ' || (n->>'employees_count') || '.') else '[]'::jsonb end
    || private.fsh('Directors'' emoluments')
    || private.fr('Fees and other emoluments', private.sum_codes(mvc, array['6109']), private.sum_codes(mvp, array['6109']), 'line', 1)
    || private.fl('Directors'' expenses', private.sum_codes(mvc, array['6110']), private.sum_codes(mvp, array['6110']));

  -- 11 Taxation ------------------------------------------------------------------
  v_rate := case when v_nta then 0.34 else 0.33 end;
  v_pbt := (tc->>'profit_before_tax')::numeric; v_pbtp := (tp->>'profit_before_tax')::numeric;
  v_tax := -private.v(plc, 'Income tax expense'); v_taxp := -private.v(plp, 'Income tax expense');
  v := v || private.fhd('11. Taxation') || private.fsh('11.1 Income tax expense')
    || private.fl('Companies income tax', private.sum_codes(mvc, array['7501']), private.sum_codes(mvp, array['7501']))
    || private.fl(case when v_nta then 'Development levy' else 'Tertiary education tax' end, private.sum_codes(mvc, array['7502']), private.sum_codes(mvp, array['7502']))
    || private.fl('Minimum effective tax rate top-up', private.sum_codes(mvc, array['7505']), private.sum_codes(mvp, array['7505']))
    || private.fl('Under / (over) provision in prior years', private.sum_codes(mvc, array['7504']), private.sum_codes(mvp, array['7504']))
    || private.fl('Deferred tax charge / (credit)', private.sum_codes(mvc, array['7503']), private.sum_codes(mvp, array['7503']))
    || private.fr('Income tax expense', v_tax, case when p_pfrom is null then null else v_taxp end, 'subtotal', 0)
    || private.fsh('11.2 Reconciliation of the tax charge')
    || private.fr('Profit before tax', v_pbt, case when p_pfrom is null then null else v_pbtp end, 'line', 1)
    || private.fr('Tax at the statutory rates (' || case when v_nta then 'companies income tax 30% and development levy 4%' else 'companies income tax 30% and tertiary education tax 3%' end || ')',
         round(greatest(v_pbt, 0) * v_rate, 2), case when p_pfrom is null then null else round(greatest(v_pbtp, 0) * v_rate, 2) end, 'line', 1)
    || private.fr('Effect of exempt income, non-deductible expenses, capital allowances, small-company relief and other differences',
         v_tax - round(greatest(v_pbt, 0) * v_rate, 2), case when p_pfrom is null then null else v_taxp - round(greatest(v_pbtp, 0) * v_rate, 2) end, 'line', 1)
    || private.fr('Income tax expense', v_tax, case when p_pfrom is null then null else v_taxp end, 'subtotal', 0)
    || case when v_pbt > 0 then private.ftxt('The effective tax rate for the period was ' || to_char(round(v_tax / v_pbt * 100, 1), 'FM990.0') || '%.') else '[]'::jsonb end
    || private.fsh('11.3 Current tax payable')
    || private.fr('At the start of the period', -private.sum_codes(balo, array['2208', '2209']), null, 'line', 1)
    || private.fr('Charge for the period', private.sum_codes(crc, array['2208', '2209']), null, 'line', 1)
    || private.fr('Paid and withholding tax credits applied', -private.sum_codes(drc, array['2208', '2209']), null, 'line', 1)
    || private.fr('At the end of the period', -private.sum_codes(balc, array['2208', '2209']), case when v_bpto is null then null else -private.sum_codes(balp, array['2208', '2209']) end, 'subtotal', 0)
    || private.fsh('11.4 Tax assets')
    || private.fr('Withholding tax credit notes held', private.sum_codes(balc, array['1401']), private.sum_codes(balp, array['1401']), 'line', 1)
    || private.fl('Income tax paid in advance', private.sum_codes(balc, array['1403']), private.sum_codes(balp, array['1403']))
    || private.fl('VAT recoverable', private.sum_codes(balc, array['1402']), private.sum_codes(balp, array['1402']))
    || private.fsh('11.5 Deferred tax')
    || case when private.sum_codes(balc, array['1803', '2601']) = 0 and private.sum_codes(balp, array['1803', '2601']) = 0
         then private.ftxt('No deferred tax asset or liability is recognised. Temporary differences between the carrying amounts of assets and their tax written-down values are not material.')
         else private.fr('Deferred tax asset / (liability)', private.sum_codes(balc, array['1803', '2601']), private.sum_codes(balp, array['1803', '2601']), 'line', 1) end;

  -- 12 Property, plant and equipment ------------------------------------------------
  v := v || private.fhd('12. Property, plant and equipment');
  v_x := 0;
  for r in select ac.* from asset_classes ac where private.sum_codes(balo, array[ac.cost_account]) <> 0 or private.sum_codes(drc, array[ac.cost_account]) <> 0
           or private.sum_codes(crc, array[ac.cost_account]) <> 0 order by ac.cost_account loop
    v_x := v_x + 1;
    v := v || private.fr(r.name, null, null, 'subheading', 1)
      || private.fr('Cost at the start of the period', private.sum_codes(balo, array[r.cost_account]), null, 'line', 2)
      || private.fl('Additions', private.sum_codes(drc, array[r.cost_account]), null, 2)
      || private.fl('Disposals', -private.sum_codes(crc, array[r.cost_account]), null, 2)
      || private.fr('Cost at the end of the period', private.sum_codes(balc, array[r.cost_account]), null, 'subtotal', 2);
    if r.accum_account is not null then
      v := v || private.fr('Accumulated depreciation at the start', private.sum_codes(balo, array[r.accum_account]), null, 'line', 2)
        || private.fr('Charge for the period', -private.sum_codes(crc, array[r.accum_account]), null, 'line', 2)
        || private.fl('Eliminated on disposal', private.sum_codes(drc, array[r.accum_account]), null, 2)
        || private.fr('Accumulated depreciation at the end', private.sum_codes(balc, array[r.accum_account]), null, 'subtotal', 2);
    end if;
    v := v || private.fr('Carrying amount', private.sum_codes(balc, array[r.cost_account]) + case when r.accum_account is not null then private.sum_codes(balc, array[r.accum_account]) else 0 end,
      case when v_bpto is null then null else private.sum_codes(balp, array[r.cost_account]) + case when r.accum_account is not null then private.sum_codes(balp, array[r.accum_account]) else 0 end end, 'total', 2);
  end loop;
  if private.sum_range(balc, '1650', '1654') <> 0 or private.sum_range(balp, '1650', '1654') <> 0 then
    v_x := v_x + 1;
    v := v || private.fr('Right-of-use assets', null, null, 'subheading', 1)
      || private.fr('Cost', private.sum_codes(balc, array['1650', '1651', '1652', '1653']), private.sum_codes(balp, array['1650', '1651', '1652', '1653']), 'line', 2)
      || private.fr('Accumulated depreciation', private.sum_codes(balc, array['1654']), private.sum_codes(balp, array['1654']), 'line', 2)
      || private.fr('Carrying amount', private.sum_range(balc, '1650', '1654'), private.sum_range(balp, '1650', '1654'), 'total', 2);
  end if;
  if v_x = 0 then v := v || private.ftxt('No property, plant or equipment was held during the period.'); end if;
  v := v || private.fr('Total carrying amount', private.v(c, 'Property, plant and equipment') + private.v(c, 'Right-of-use assets'),
      case when v_bpto is null then null else private.v(p, 'Property, plant and equipment') + private.v(p, 'Right-of-use assets') end, 'subtotal', 0)
    || private.ftxt(coalesce(n->>'pledged', 'No item of property, plant and equipment was pledged as security for liabilities at the reporting date.'));

  -- 13 Intangible assets -------------------------------------------------------------
  v := v || private.fhd('13. Intangible assets');
  if private.sum_range(balc, '1600', '1610') = 0 and private.sum_range(balp, '1600', '1610') = 0 then
    v := v || private.ftxt('No intangible assets were held at the reporting date' || case when v_bpto is null then '.' else ' or at ' || private.fdate(v_bpto) || '.' end);
  else
    v := v || private.fr('Cost', private.sum_range(balc, '1600', '1608') + private.sum_codes(balc, array['1610']), private.sum_range(balp, '1600', '1608') + private.sum_codes(balp, array['1610']), 'line', 1)
      || private.fr('Accumulated amortisation', private.sum_codes(balc, array['1609']), private.sum_codes(balp, array['1609']), 'line', 1)
      || private.fr('Carrying amount', private.sum_range(balc, '1600', '1610'), private.sum_range(balp, '1600', '1610'), 'subtotal', 0)
      || private.fr('Amortisation charged in the period', private.sum_codes(mvc, array['5205', '6903']), private.sum_codes(mvp, array['5205', '6903']), 'line', 1);
  end if;

  -- 14 to 20: balances behind the statement lines ---------------------------------------
  for r in select * from (values
      ('14. Inventories', array['Inventories'], 'inventories'),
      ('15. Trade and other receivables', array['Trade and other receivables', 'Contract assets', 'Prepayments', 'Other current assets', 'Other current financial assets'], 'receivables'),
      ('16. Cash and cash equivalents', array['Cash and cash equivalents'], 'cash'),
      ('17. Share capital and reserves', array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings', 'Opening balances to be confirmed'], 'equity'),
      ('18. Borrowings and lease liabilities', array['Borrowings (current)', 'Borrowings (non-current)', 'Lease liabilities (current)', 'Lease liabilities (non-current)'], 'borrowings'),
      ('19. Trade and other payables', array['Trade and other payables', 'Contract liabilities', 'Provisions (current)', 'Other current liabilities', 'Other non-current liabilities'], 'payables'),
      ('20. Statutory liabilities', array['Other statutory liabilities'], 'statutory')) t(title, lines, k) loop
    if r.k = 'cash' then
      -- Accounts in credit are overdrafts, listed separately below.
      v_mv := (select jsonb_agg(private.fr(m.name, greatest(private.v(balc, m.code), 0), case when v_bpto is null then null else greatest(private.v(balp, m.code), 0) end, 'line', 1) order by m.code)
        from private.acct_meta(p_org) m where m.ifrs_line = 'Cash and cash equivalents' and (private.v(balc, m.code) > 0 or private.v(balp, m.code) > 0));
    else
      v_mv := (select jsonb_agg(private.fr(m.name, sg * private.v(balc, m.code), case when v_bpto is null then null else sg * private.v(balp, m.code) end, 'line', 1) order by m.code)
        from (select mm.*, case when mm.code ~ '^(1|9)' then 1 else -1 end sg from private.acct_meta(p_org) mm where mm.ifrs_line = any(r.lines)
              and not (r.k = 'equity' and split_part(mm.code, '-', 1) = '3005')) m
        where private.v(balc, m.code) <> 0 or private.v(balp, m.code) <> 0);
      -- Retained earnings include profit not yet closed to the account.
      if r.k = 'equity' and (private.v(c, 'Retained earnings') <> 0 or private.v(p, 'Retained earnings') <> 0) then
        v_mv := coalesce(v_mv, '[]'::jsonb) || private.fr('Retained earnings', private.v(c, 'Retained earnings'), case when v_bpto is null then null else private.v(p, 'Retained earnings') end, 'line', 1);
      end if;
    end if;
    v := v || private.fhd(r.title);
    if r.k = 'equity' and (o.share_info ? 'issued_shares') then
      v := v || private.ftxt(coalesce('Authorised: ' || to_char((o.share_info->>'authorised_shares')::numeric, 'FM999,999,999,999') || ' ordinary shares'
             || coalesce(' of ₦' || to_char((o.share_info->>'nominal_value')::numeric, case when round((o.share_info->>'nominal_value')::numeric, 2) = (o.share_info->>'nominal_value')::numeric then 'FM999,999,990.00' else 'FM999,999,990.0000' end) || ' each', '') || '. ', '')
           || 'Issued and fully paid: ' || to_char((o.share_info->>'issued_shares')::numeric, 'FM999,999,999,999') || ' ordinary shares'
           || coalesce(' of ₦' || to_char((o.share_info->>'nominal_value')::numeric, case when round((o.share_info->>'nominal_value')::numeric, 2) = (o.share_info->>'nominal_value')::numeric then 'FM999,999,990.00' else 'FM999,999,990.0000' end) || ' each', '') || '.');
    end if;
    if v_mv is null then
      v := v || private.ftxt(case r.k when 'borrowings' then 'There were no borrowings or lease liabilities at the reporting date.'
        when 'inventories' then 'No inventories were held at the reporting date.' when 'statutory' then 'There were no statutory liabilities outstanding at the reporting date.'
        else 'There was no balance at the reporting date.' end);
    else
      v := v || v_mv || private.fr('Total', (select coalesce(sum(private.v(c, x)), 0) from unnest(r.lines) x),
        case when v_bpto is null then null else (select coalesce(sum(private.v(p, x)), 0) from unnest(r.lines) x) end, 'subtotal', 0);
    end if;
    if r.k = 'inventories' and v_mv is not null then
      v := v || private.ftxt('Inventories recognised as an expense in cost of sales during the period amounted to ' || private.naira(private.sum_codes(mvc, array['5400', '5401']))
        || '. Write-downs to net realisable value of ' || private.naira(private.sum_codes(mvc, array['6805'])) || ' were recognised in the period.');
    elsif r.k = 'receivables' then
      if private.v(c, '_customer_credit_reclass') > 0 then
        v := v || private.ftxt('Trade receivables include ' || private.naira(private.v(c, '_customer_credit_reclass')) || ' for customers in credit, which is shown within contract liabilities.');
      end if;
      v := v || private.fsh('Movement in the loss allowance')
        || private.fr('At the start of the period', -private.sum_codes(balo, array['1103']), null, 'line', 1)
        || private.fr('Charged to profit or loss', private.sum_codes(crc, array['1103']), null, 'line', 1)
        || private.fr('Written off or released', -private.sum_codes(drc, array['1103']), null, 'line', 1)
        || private.fr('At the end of the period', -private.sum_codes(balc, array['1103']), null, 'subtotal', 0)
        || private.fsh('Ageing of trade receivables from invoices at ' || v_ended);
      select coalesce(sum(bal) filter (where age <= 0), 0), coalesce(sum(bal) filter (where age between 1 and 30), 0), coalesce(sum(bal) filter (where age between 31 and 90), 0),
             coalesce(sum(bal) filter (where age > 90), 0) into v_x, v_y, v_z, v_w
      from (select s.total - s.amount_paid - s.credited bal, p_to - coalesce(s.due_date, s.issue_date) age from sales s
            where s.org_id = p_org and s.status in ('open', 'partially_paid') and s.journal_id is not null and s.issue_date <= p_to) d;
      v := v || private.fr('Not yet due', v_x, null, 'line', 1) || private.fr('1 to 30 days overdue', v_y, null, 'line', 1)
        || private.fr('31 to 90 days overdue', v_z, null, 'line', 1) || private.fr('More than 90 days overdue', v_w, null, 'line', 1)
        || private.fr('Open invoices', v_x + v_y + v_z + v_w, null, 'subtotal', 0);
    elsif r.k = 'cash' then
      if private.v(c, 'Bank overdrafts') <> 0 or private.v(p, 'Bank overdrafts') <> 0 then
        v := v || private.fsh('Bank overdrafts, shown under current liabilities')
          || coalesce((select jsonb_agg(private.fr(m.name, -least(private.v(balc, m.code), 0), case when v_bpto is null then null else -least(private.v(balp, m.code), 0) end, 'line', 1) order by m.code)
               from private.acct_meta(p_org) m where m.ifrs_line = 'Cash and cash equivalents' and (private.v(balc, m.code) < 0 or private.v(balp, m.code) < 0)), '[]'::jsonb)
          || private.fr('Total bank overdrafts', private.v(c, 'Bank overdrafts'), case when v_bpto is null then null else private.v(p, 'Bank overdrafts') end, 'subtotal', 0)
          || private.ftxt('Overdrawn accounts are repayable on demand and form part of day-to-day cash management, so the statement of cash flows counts them within cash (IAS 7.8).');
      end if;
      v := v || private.fr('Cash and cash equivalents in the statement of cash flows', private.v(c, 'Cash and cash equivalents') - private.v(c, 'Bank overdrafts'),
        case when v_bpto is null then null else private.v(p, 'Cash and cash equivalents') - private.v(p, 'Bank overdrafts') end, 'subtotal', 0);
    elsif r.k = 'equity' then
      v_x := private.v(private.sofp_map(p_org, p_from - 1), 'Retained earnings');
      v_y := private.v(plc, 'Items that will not be reclassified to profit or loss') + private.v(plc, 'Items that may be reclassified to profit or loss')
        + private.v(plc, 'Income tax relating to other comprehensive income');
      v_z := -private.sum_codes(drc, array['3005']);
      v := v || private.fsh('Retained earnings')
        || private.fr('At the start of the period', v_x, null, 'line', 1)
        || private.fr('Profit for the period', (tc->>'profit')::numeric, null, 'line', 1)
        || private.fl('Other comprehensive income', v_y, null)
        || private.fl('Dividends paid', v_z, null)
        || private.fl('Transfers and other movements', private.v(c, 'Retained earnings') - v_x - (tc->>'profit')::numeric - v_y - v_z, null)
        || private.fr('At the end of the period', private.v(c, 'Retained earnings'), null, 'subtotal', 0);
      if private.v(c, 'Opening balances to be confirmed') <> 0 then
        v := v || private.ftxt('Opening balances of ' || private.naira(private.v(c, 'Opening balances to be confirmed')) || ' were brought into the books without a full split between share capital and reserves. They are to be confirmed and reclassified.');
      end if;
    end if;
  end loop;

  -- 21 Related parties -----------------------------------------------------------------
  v := v || private.fhd('21. Related party transactions')
    || private.ftxt('The directors' || coalesce(' (' || v_dirs || ')', '') || ' are the key management personnel of ' || v_name || '. Their emoluments are shown in note 10.')
    || private.fl('Amounts owed by directors (directors'' current accounts)', private.sum_codes(balc, array['1105']), private.sum_codes(balp, array['1105']))
    || private.fl('Amounts owed by other related parties', private.sum_codes(balc, array['1108']), private.sum_codes(balp, array['1108']))
    || private.fl('Amounts owed to directors (directors'' current accounts)', -private.sum_codes(balc, array['2106']), -private.sum_codes(balp, array['2106']))
    || private.fl('Amounts owed to other related parties', -private.sum_codes(balc, array['2105']), -private.sum_codes(balp, array['2105']))
    || private.fl('Loans from shareholders and related parties', -private.sum_codes(balc, array['2502']), -private.sum_codes(balp, array['2502']))
    || private.ftxt('Balances with related parties are unsecured, interest-free and repayable on demand unless stated otherwise. No guarantees were given or received.');

  -- 22 Financial instruments and risk management -----------------------------------------
  v_cash := private.v(c, 'Cash and cash equivalents');
  v := v || private.fhd('22. Financial instruments and risk management') || private.fsh('22.1 Categories of financial instruments')
    || private.fr('Financial assets at amortised cost', null, null, 'line', 1)
    || private.fr('Trade receivables, net of loss allowance', private.sum_codes(balc, array['1101', '1102', '1103']), private.sum_codes(balp, array['1101', '1102', '1103']), 'line', 2)
    || private.fl('Other receivables', private.sum_codes(balc, array['1104', '1105', '1107', '1108', '1110']), private.sum_codes(balp, array['1104', '1105', '1107', '1108', '1110']), 2)
    || private.fr('Cash and cash equivalents', v_cash, private.v(p, 'Cash and cash equivalents'), 'line', 2)
    || private.fr('Financial liabilities at amortised cost', null, null, 'line', 1)
    || private.fr('Trade payables and accruals', -private.sum_codes(balc, array['2101', '2102', '2103']), -private.sum_codes(balp, array['2101', '2102', '2103']), 'line', 2)
    || private.fl('Other payables', -private.sum_codes(balc, array['2104', '2105', '2106', '2108']), -private.sum_codes(balp, array['2104', '2105', '2106', '2108']), 2)
    || private.fl('Borrowings, lease liabilities and overdrafts', -private.sum_range(balc, '2301', '2306') - private.sum_range(balc, '2501', '2504'),
         -private.sum_range(balp, '2301', '2306') - private.sum_range(balp, '2501', '2504'), 2)
    || private.ftxt('The carrying amounts of these financial assets and liabilities approximate their fair values because of their short-term nature.')
    || private.fsh('22.2 Credit risk')
    || private.ftxt('Credit risk is the risk of loss if a customer or bank fails to meet its obligations. It arises mainly on trade receivables and bank balances, whose carrying amounts are the maximum exposure.'
         || ' Credit limits are set for customers buying on account, overdue balances are followed up through statements and reminders, and bank balances are held with licensed Nigerian banks and payment institutions.');
  select coalesce(sum(b) filter (where rk <= 5), 0), coalesce(sum(b), 0) into v_x, v_y from (
    select sum(l.debit - l.credit) b, row_number() over (order by sum(l.debit - l.credit) desc) rk from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and l.party_type = 'customer' and split_part(l.account_code, '-', 1) in ('1101', '1102') and j.entry_date <= p_to group by l.party_id having sum(l.debit - l.credit) > 0) x;
  if v_y > 0 then
    v := v || private.ftxt('The five largest customer balances make up ' || to_char(round(v_x / v_y * 100, 1), 'FM990.0') || '% of trade receivables.');
  end if;
  v := v || private.fsh('22.3 Liquidity risk')
    || private.ftxt('Liquidity risk is the risk of being unable to pay obligations as they fall due. Cash is forecast thirteen weeks ahead and payments are scheduled against expected collections.'
         || ' At ' || v_ended || ' current assets were ' || private.naira(v_ca) || ' against current liabilities of ' || private.naira(v_cl)
         || case when v_cl > 0 then ' (a current ratio of ' || to_char(round(v_ca / v_cl, 2), 'FM990.00') || ')' else '' end || '.')
    || private.fr('Due within one year: trade and other payables and current borrowings', -private.sum_codes(balc, array['2101', '2102', '2103', '2104', '2105', '2106', '2108'])
         - private.sum_range(balc, '2301', '2306'), null, 'line', 1)
    || private.fl('Due after one year: non-current borrowings and lease liabilities', -private.sum_range(balc, '2501', '2504'), null)
    || private.fsh('22.4 Market risk')
    || case when private.sum_codes(balc, array['1013', '1102', '2102']) <> 0 or private.sum_codes(balp, array['1013', '1102', '2102']) <> 0 then
         private.ftxt('Currency risk arises on balances in foreign currencies, which are retranslated at the closing rate. The naira equivalent of foreign currency balances at the reporting date was:')
         || private.fl('Domiciliary bank balances', private.sum_codes(balc, array['1013']), private.sum_codes(balp, array['1013']))
         || private.fl('Receivables from foreign customers', private.sum_codes(balc, array['1102']), private.sum_codes(balp, array['1102']))
         || private.fl('Payables to foreign suppliers', -private.sum_codes(balc, array['2102']), -private.sum_codes(balp, array['2102']))
       else private.ftxt('No material balances were held in foreign currencies at the reporting date, so exposure to currency risk is limited.') end
    || private.ftxt(case when private.sum_range(balc, '2301', '2306') + private.sum_range(balc, '2501', '2504') <> 0
         then 'Interest rate risk arises on borrowings. Rates and repayment terms are reviewed before facilities are taken or renewed.'
         else 'There were no interest-bearing borrowings at the reporting date, so exposure to interest rate risk is limited.' end);

  -- 23 Capital management ---------------------------------------------------------------
  v_debt := -(private.sum_range(balc, '2301', '2306') + private.sum_range(balc, '2501', '2504'));
  v := v || private.fhd('23. Capital management')
    || private.ftxt('The directors manage capital, being equity and net debt, to keep ' || v_name || ' able to continue as a going concern and to fund its growth. Net debt and equity are reviewed with the management accounts.')
    || private.fr('Borrowings, lease liabilities and overdrafts', v_debt, null, 'line', 1)
    || private.fr('Less cash and cash equivalents', -v_cash, null, 'line', 1)
    || private.fr('Net debt / (net cash)', v_debt - v_cash, null, 'subtotal', 0)
    || private.fr('Total equity', v_eq, null, 'line', 1)
    || case when v_eq > 0 and v_debt - v_cash > 0 then private.ftxt('Net debt to equity was ' || to_char(round((v_debt - v_cash) / v_eq * 100, 1), 'FM990.0') || '% at ' || v_ended || '.') else '[]'::jsonb end;

  -- 24 to 26 ---------------------------------------------------------------------------
  v := v || private.fhd('24. Contingent liabilities and commitments')
    || private.ftxt(coalesce(n->>'contingencies', 'There were no contingent liabilities at the reporting date, including pending litigation, that require disclosure.'))
    || private.ftxt(coalesce(n->>'commitments', 'There were no capital commitments contracted for but not provided at the reporting date.'))
    || private.fhd('25. Events after the reporting period')
    || private.ftxt(coalesce(n->>'events_after', 'There were no events after the reporting date that require adjustment to, or disclosure in, these financial statements.'))
    || private.fhd('26. Approval of the financial statements')
    || private.ftxt('These financial statements were approved by the Board of Directors and authorised for issue on '
         || coalesce(private.fdate(nullif(n->>'approved_on', '')::date), '.......................................') || '.');
  if private.v(c, 'Unreconciled balances (assets)') <> 0 or private.v(c, 'Unreconciled balances (liabilities)') <> 0 then
    v := v || private.fhd('27. Unreconciled balances')
      || private.fr('Unreconciled balances (assets)', private.v(c, 'Unreconciled balances (assets)'), private.v(p, 'Unreconciled balances (assets)'), 'line', 1)
      || private.fr('Unreconciled balances (liabilities)', private.v(c, 'Unreconciled balances (liabilities)'), private.v(p, 'Unreconciled balances (liabilities)'), 'line', 1)
      || private.ftxt('These are bank movements not yet explained and money between accounts. They must be cleared before the financial statements are signed.');
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Front pages and other national information
-- ---------------------------------------------------------------------------
-- A row for the corporate information page: {line: label, text, _style: 'kv'}
create or replace function private.kv(p_label text, p_text text) returns jsonb
language sql immutable set search_path = '' as $$
  select case when nullif(trim(p_text), '') is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('line', p_label, 'text', p_text, '_style', 'kv', '_indent', 0)) end
$$;
-- Signature lines: {line: name, text: role and FRC number, _style: 'signature'}
create or replace function private.sig(p_name text, p_role text) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('line', coalesce(nullif(trim(p_name), ''), '..............................................'), 'text', p_role, '_style', 'signature', '_indent', 0))
$$;

-- The two directors who sign: the chair or managing director first.
create or replace function private.signing_directors(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce((select jsonb_agg(d order by rk) from (
    select d, row_number() over (order by case when d->>'role' ~* 'chair' then 0 when d->>'role' ~* 'managing|chief executive|ceo|md' then 1 else 2 end,
      (d->>'appointed') nulls last) rk
    from orgs o, jsonb_array_elements(o.directors) d where o.id = p_org and nullif(d->>'resigned', '') is null) x where rk <= 2), '[]'::jsonb)
$$;

create or replace function private.director_sigs(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; d jsonb; s jsonb := private.signing_directors(p_org);
begin
  for d in select * from jsonb_array_elements(s) loop
    v := v || private.sig(d->>'name', coalesce(d->>'role', 'Director') || ' · ' || coalesce('FRC/' || nullif(regexp_replace(d->>'frc_number', '^FRC/', '', 'i'), ''), 'FRC/....................'));
  end loop;
  for i in (jsonb_array_length(s) + 1) .. 2 loop
    v := v || private.sig(null, 'Director · FRC/....................');
  end loop;
  return v;
end $$;

-- p_report: 'corporate' | 'directors_report' | 'responsibilities' | 'value_added' | 'five_year'
create or replace function public.statement_extra(p_org uuid, p_report text, p_from date default null, p_to date default null, p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; pr jsonb; v_from date; v_to date; v_pfrom date; v_pto date; v_rows jsonb := '[]'::jsonb; v_extra jsonb; n jsonb;
  plc jsonb; plp jsonb; tc jsonb; tp jsonb; mvc jsonb; mvp jsonb; d jsonb; v_co boolean; v_name text; v_period text; v_audited boolean; v_txt text;
  v_staff text[] := array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6109', '6110', '6111', '6112', '6113', '6114'];
  v_dep text[] := array['5204', '5205', '6901', '6902', '6903']; v_rev numeric; v_oth numeric; v_staffc numeric; v_fin numeric; v_tax numeric; v_depc numeric; v_pat numeric;
  v_revp numeric; v_othp numeric; v_staffp numeric; v_finp numeric; v_taxp numeric; v_depp numeric; v_patp numeric; v_va numeric; v_vap numeric; v_div numeric;
  v_years jsonb := '[]'::jsonb; y int; v_fy date; v_fy_end date; s jsonb; t jsonb; v_cols jsonb := '[]'::jsonb; v_have boolean; r record;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Financial reports need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  n := coalesce(o.fs_narrative, '{}'::jsonb);
  pr := private.fs_periods(p_org, p_from, p_to);
  v_from := (pr->>'from')::date; v_to := (pr->>'to')::date; v_pfrom := (pr->>'prior_from')::date; v_pto := (pr->>'prior_to')::date;
  v_co := coalesce(o.legal_form, 'company') = 'company';
  v_name := case when v_co then 'the Company' else 'the business' end;
  v_period := case when (pr->>'full_year')::boolean then 'year ended ' || private.fdate(v_to) else 'period ended ' || private.fdate(v_to) end;
  v_audited := o.auditors is not null and not o.audit_exempt;
  v_extra := pr || jsonb_build_object('org', jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'framework', o.reporting_framework),
    'closed_through', private.closed_through(p_org));

  if p_report = 'corporate' then
    select string_agg(dd->>'name' || coalesce(' (' || (dd->>'role') || ')', '') || coalesce(', resigned ' || private.fdate((dd->>'resigned')::date), '')
      || coalesce(', appointed ' || private.fdate((dd->>'appointed')::date), ''), E'\n') into v_txt
    from jsonb_array_elements(o.directors) dd
    where nullif(dd->>'resigned', '') is null or (dd->>'resigned')::date >= v_from;
    v_rows := private.kv('Directors', coalesce(v_txt, 'To be completed: add the directors under Financial statements, Company details.'))
      || private.kv('Company secretary', o.company_secretary)
      || private.kv('Registered office', coalesce(o.registered_office, o.address))
      || private.kv('Company registration number', case when nullif(o.rc_number, '') is not null then 'RC ' || regexp_replace(o.rc_number, '^\s*RC\s*', '', 'i') end)
      || private.kv('Date of incorporation', private.fdate(o.incorporation_date))
      || private.kv('Tax identification number', o.tin)
      || private.kv('Principal activity', o.principal_activity)
      || private.kv('Auditors', case when v_audited then o.auditors when o.audit_exempt then 'Exempt from audit (small company)' end)
      || private.kv('Bankers', o.bankers)
      || private.kv('Solicitors', o.solicitors);

  elsif p_report = 'directors_report' then
    plc := private.pl_map(p_org, v_from, v_to); plp := private.pl_map(p_org, v_pfrom, v_pto);
    tc := private.pl_totals(plc); tp := private.pl_totals(plp);
    select coalesce(sum(dr), 0) into v_div from private.movement(p_org, v_from, v_to) where split_part(code, '-', 1) = '3005';
    v_rows := jsonb_build_array(private.ftxt('The directors present their report on the affairs of ' || o.name || ', together with the ' || case when v_audited then 'audited ' else '' end
        || 'financial statements for the ' || v_period || '.'))
      || private.fhd('Legal form and principal activity')
      || private.ftxt(o.name || case when v_co then ' is a private limited liability company incorporated in Nigeria' else ' is a business registered in Nigeria' end
        || coalesce(' on ' || private.fdate(o.incorporation_date), '') || '. Its principal activity is ' || coalesce(nullif(o.principal_activity, ''), replace(coalesce(o.industry, 'trading'), '_', ' ')) || '.')
      || private.fhd('Business review')
      || private.ftxt(coalesce(n->>'review', 'Revenue for the ' || v_period || ' was ' || private.naira((tc->>'revenue')::numeric)
        || case when (tp->>'revenue')::numeric <> 0 then ', compared with ' || private.naira((tp->>'revenue')::numeric) || ' for the comparative period ('
             || case when (tc->>'revenue')::numeric >= (tp->>'revenue')::numeric then 'an increase' else 'a decrease' end || ' of '
             || to_char(abs(round(((tc->>'revenue')::numeric - (tp->>'revenue')::numeric) / (tp->>'revenue')::numeric * 100, 1)), 'FM9999990.0') || '%)' else '' end
        || '. ' || case when (tc->>'profit')::numeric >= 0 then 'Profit' else 'The loss' end || ' after tax was ' || private.naira(abs((tc->>'profit')::numeric)) || '.'))
      || case when n->>'future' is not null then private.fhd('Future developments') || private.ftxt(n->>'future') else '[]'::jsonb end
      || private.fhd('Results')
      || private.fr('Revenue', (tc->>'revenue')::numeric, (tp->>'revenue')::numeric, 'line', 1)
      || private.fr('Profit before tax', (tc->>'profit_before_tax')::numeric, (tp->>'profit_before_tax')::numeric, 'line', 1)
      || private.fr('Income tax expense', -(tc->>'tax')::numeric, -(tp->>'tax')::numeric, 'line', 1)
      || private.fr('Profit for the period', (tc->>'profit_before_tax')::numeric - (tc->>'tax')::numeric, (tp->>'profit_before_tax')::numeric - (tp->>'tax')::numeric, 'subtotal', 0)
      || private.fhd('Dividend')
      || private.ftxt(coalesce(n->>'dividend', case when v_div > 0 then 'Dividends of ' || private.naira(v_div) || ' were paid during the period. ' else '' end
        || 'The directors do not recommend the payment of a dividend for the ' || v_period || '.'))
      || private.fhd('Directors')
      || private.ftxt('The directors who served during the period and up to the date of this report were:');
    for d in select * from jsonb_array_elements(o.directors) loop
      continue when nullif(d->>'resigned', '') is not null and (d->>'resigned')::date < v_from;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', d->>'name', 'text',
        concat_ws(' · ', coalesce(d->>'role', 'Director'), case when d->>'appointed' is not null and (d->>'appointed')::date >= v_from then 'appointed ' || private.fdate((d->>'appointed')::date) end,
          case when d->>'resigned' is not null then 'resigned ' || private.fdate((d->>'resigned')::date) end), '_style', 'kv', '_indent', 1));
    end loop;
    if jsonb_array_length(o.directors) = 0 then v_rows := v_rows || private.ftxt('To be completed: add the directors under Financial statements, Company details.'); end if;
    v_rows := v_rows
      || private.fhd('Directors'' interests in shares and contracts')
      || private.ftxt(coalesce(n->>'directors_interests', 'The directors'' interests in the issued share capital of ' || v_name || ' are recorded in the register of directors'' shareholdings.'
        || ' No director has notified ' || v_name || ' of any declarable interest in contracts with it, as required by the Companies and Allied Matters Act 2020.'))
      || private.fhd('Property, plant and equipment')
      || private.ftxt('Movements in property, plant and equipment during the period are shown in note 12 to the financial statements.')
      || private.fhd('Donations and charitable gifts')
      || private.ftxt(case when private.sum_codes((select coalesce(jsonb_object_agg(code, net), '{}') from private.movement(p_org, v_from, v_to)), array['6904']) > 0
        then 'Donations and charitable gifts during the period amounted to ' || private.naira(private.sum_codes((select coalesce(jsonb_object_agg(code, net), '{}') from private.movement(p_org, v_from, v_to)), array['6904']))
          || '. No donation was made to any political party or political association.'
        else (upper(left(v_name, 1)) || substr(v_name, 2)) || ' made no donations or charitable gifts during the period, and none to any political party or political association.' end)
      || private.fhd('Employment and employees')
      || private.ftxt(coalesce(n->>'employees', (upper(left(v_name, 1)) || substr(v_name, 2)) || ' gives fair consideration to applications for employment from all persons, including persons with disabilities, having regard to their abilities.'
        || ' It maintains safe working conditions, provides training to develop its staff, and keeps employees informed of matters affecting them.'))
      || private.fhd('Events after the reporting period')
      || private.ftxt('Events after the reporting date are described in note 25 to the financial statements.');
    if v_audited then
      v_rows := v_rows || private.fhd('Auditors') || private.ftxt(o.auditors || ' have indicated their willingness to continue in office as auditors in accordance with the Companies and Allied Matters Act 2020.');
    elsif o.audit_exempt then
      v_rows := v_rows || private.fhd('Auditors') || private.ftxt((upper(left(v_name, 1)) || substr(v_name, 2)) || ' qualifies as a small company under the Companies and Allied Matters Act 2020 and has not appointed auditors for the period.');
    end if;
    v_rows := v_rows || private.ftxt('By order of the Board') || private.sig(o.company_secretary, 'Company Secretary');

  elsif p_report = 'responsibilities' then
    v_rows := jsonb_build_array(private.ftxt('The Companies and Allied Matters Act 2020 requires the directors to prepare financial statements for each financial year that give a true and fair view of the state of affairs of '
        || v_name || ' at the end of the year and of its profit or loss. The responsibilities include ensuring that ' || v_name || ':'))
      || private.ftxt('(a) keeps proper accounting records that disclose, with reasonable accuracy, its financial position and that enable the directors to ensure that the financial statements comply with the requirements of the Act;')
      || private.ftxt('(b) establishes adequate internal controls to safeguard its assets and to prevent and detect fraud and other irregularities; and')
      || private.ftxt('(c) prepares its financial statements using suitable accounting policies, supported by reasonable and prudent judgements and estimates, that are consistently applied.')
      || private.ftxt('The directors accept responsibility for the financial statements, which have been prepared using appropriate accounting policies supported by reasonable and prudent judgements and estimates, in conformity with '
        || case when coalesce(o.reporting_framework, 'ifrs') = 'ifrs_sme' then 'the IFRS for SMEs Accounting Standard' else 'IFRS Accounting Standards' end
        || ' and the requirements of the Companies and Allied Matters Act 2020 and the Financial Reporting Council of Nigeria Act 2011 (as amended).')
      || private.ftxt('The directors are of the opinion that the financial statements give a true and fair view of the state of the financial affairs of ' || v_name
        || ' and of its financial performance and cash flows for the ' || v_period || '. The directors further accept responsibility for the maintenance of accounting records that may be relied upon in the preparation of financial statements, as well as adequate systems of internal financial control.')
      || private.ftxt('Nothing has come to the attention of the directors to indicate that ' || v_name || ' will not remain a going concern for at least twelve months from the date of this statement.')
      || private.ftxt('Signed on behalf of the Board of Directors by:')
      || private.director_sigs(p_org);

  elsif p_report = 'value_added' then
    select coalesce(jsonb_object_agg(code, net), '{}') into mvc from private.movement(p_org, v_from, v_to);
    select coalesce(jsonb_object_agg(code, net), '{}') into mvp from private.movement(p_org, v_pfrom, v_pto);
    plc := private.pl_map(p_org, v_from, v_to); plp := private.pl_map(p_org, v_pfrom, v_pto);
    tc := private.pl_totals(plc); tp := private.pl_totals(plp);
    v_rev := private.v(plc, 'Revenue'); v_revp := private.v(plp, 'Revenue');
    v_oth := private.v(plc, 'Other income') + private.v(plc, 'Other gains and losses') + private.v(plc, 'Finance income');
    v_othp := private.v(plp, 'Other income') + private.v(plp, 'Other gains and losses') + private.v(plp, 'Finance income');
    v_staffc := private.sum_codes(mvc, v_staff); v_staffp := private.sum_codes(mvp, v_staff);
    v_fin := -private.v(plc, 'Finance costs'); v_finp := -private.v(plp, 'Finance costs');
    v_tax := (tc->>'tax')::numeric - private.sum_codes(mvc, array['7503']); v_taxp := (tp->>'tax')::numeric - private.sum_codes(mvp, array['7503']);
    v_depc := private.sum_codes(mvc, v_dep); v_depp := private.sum_codes(mvp, v_dep);
    v_pat := (tc->>'profit_before_tax')::numeric - (tc->>'tax')::numeric; v_patp := (tp->>'profit_before_tax')::numeric - (tp->>'tax')::numeric;
    v_va := v_staffc + v_fin + v_tax + v_depc + private.sum_codes(mvc, array['7503']) + v_pat;
    v_vap := v_staffp + v_finp + v_taxp + v_depp + private.sum_codes(mvp, array['7503']) + v_patp;
    v_rows := jsonb_build_array(
      private.fr('Revenue', v_rev, v_revp, 'line', 0), private.fr('Other income', v_oth, v_othp, 'line', 0),
      private.fr('Bought-in materials and services', -(v_rev + v_oth - v_va), -(v_revp + v_othp - v_vap), 'line', 0),
      private.fr('Value added', v_va, v_vap, 'total', 0) || jsonb_build_object('current_pct', 100, 'prior_pct', case when v_vap <> 0 then 100 end),
      private.fr('Applied as follows', null, null, 'heading', 0),
      private.fr('To pay employees: salaries, wages and other benefits', v_staffc, v_staffp, 'line', 1),
      private.fr('To pay providers of finance: interest and finance costs', v_fin, v_finp, 'line', 1),
      private.fr('To pay government: income taxes', v_tax, v_taxp, 'line', 1),
      private.fr('Retained for the replacement of assets and expansion: depreciation and amortisation', v_depc, v_depp, 'line', 1),
      private.fr('Retained for the replacement of assets and expansion: deferred tax', private.sum_codes(mvc, array['7503']), private.sum_codes(mvp, array['7503']), 'line', 1),
      private.fr('Retained for the replacement of assets and expansion: profit / (loss) for the period', v_pat, v_patp, 'line', 1),
      private.fr('Value added', v_va, v_vap, 'total', 0) || jsonb_build_object('current_pct', 100, 'prior_pct', case when v_vap <> 0 then 100 end));
    v_rows := (select jsonb_agg(case when x->>'_style' = 'line' and (x->>'_indent')::int = 1 then x || jsonb_build_object(
        'current_pct', case when v_va <> 0 then round((x->>'current')::numeric / v_va * 100, 1) end,
        'prior_pct', case when v_vap <> 0 then round((x->>'prior')::numeric / v_vap * 100, 1) end) else x end order by i)
      from jsonb_array_elements(v_rows) with ordinality t(x, i)
      where not (x->>'_style' = 'line' and (x->>'_indent')::int = 1 and coalesce((x->>'current')::numeric, 0) = 0 and coalesce((x->>'prior')::numeric, 0) = 0));
    v_extra := v_extra || jsonb_build_object('casts', true);

  elsif p_report = 'five_year' then
    -- The last five financial years that have entries, ending with this period.
    for y in 0 .. 4 loop
      v_fy_end := case when y = 0 then v_to else (private.fy_start(p_org, v_to) - 1 - ((y - 1) || ' years')::interval)::date end;
      v_fy := case when y = 0 then v_from else private.fy_start(p_org, v_fy_end) end;
      select exists (select 1 from journals j where j.org_id = p_org and j.entry_date <= v_fy_end) into v_have;
      exit when not v_have;
      s := private.sofp_map(p_org, v_fy_end);
      t := private.pl_totals(private.pl_map(p_org, v_fy, v_fy_end));
      v_years := v_years || jsonb_build_array(jsonb_build_object('key', 'y' || y, 'label', to_char(v_fy_end, 'DD Mon YYYY'),
        'nca', (select coalesce(sum(value::numeric), 0) from jsonb_each_text(s) where key in ('Property, plant and equipment', 'Intangible assets', 'Right-of-use assets',
          'Investments in subsidiaries and associates', 'Investment property', 'Other financial assets', 'Deferred tax assets', 'Other non-current assets')),
        'ca', (select coalesce(sum(value::numeric), 0) from jsonb_each_text(s) where key in ('Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments',
          'Other current financial assets', 'Current tax assets', 'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)')),
        'cl', (select coalesce(sum(value::numeric), 0) from jsonb_each_text(s) where key in ('Trade and other payables', 'Contract liabilities', 'Current tax liabilities',
          'Other statutory liabilities', 'Bank overdrafts', 'Borrowings (current)', 'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities', 'Unreconciled balances (liabilities)')),
        'ncl', (select coalesce(sum(value::numeric), 0) from jsonb_each_text(s) where key in ('Borrowings (non-current)', 'Lease liabilities (non-current)', 'Deferred tax liabilities', 'Other non-current liabilities')),
        'capital', private.v(s, 'Share capital') + private.v(s, 'Share premium') + private.v(s, 'Deposit for shares'),
        'reserves', private.v(s, 'Other reserves') + private.v(s, 'Retained earnings') + private.v(s, 'Opening balances to be confirmed') + private.v(s, 'Non-controlling interests'),
        'revenue', (t->>'revenue')::numeric, 'pbt', (t->>'profit_before_tax')::numeric, 'tax', (t->>'tax')::numeric,
        'pat', (t->>'profit_before_tax')::numeric - (t->>'tax')::numeric));
    end loop;
    v_cols := (select coalesce(jsonb_agg(jsonb_build_object('key', x->>'key', 'label', x->>'label') order by i), '[]'::jsonb) from jsonb_array_elements(v_years) with ordinality t(x, i));
    if jsonb_array_length(v_years) = 0 then
      return jsonb_build_object('rows', '[]'::jsonb, 'extra', v_extra || jsonb_build_object('columns', v_cols));
    end if;
    v_rows := jsonb_build_array(jsonb_build_object('line', 'Statement of financial position', '_style', 'heading', '_indent', 0));
    for r in select * from (values ('Non-current assets', 'nca', 1), ('Net current assets / (liabilities)', 'nwc', 1), ('Non-current liabilities', 'ncl', 1),
        ('Net assets', 'net', 2), ('Share capital and premium', 'capital', 1), ('Reserves', 'reserves', 1), ('Total equity', 'equity', 2)) t(label, k, st) loop
      v_rows := v_rows || jsonb_build_array((select jsonb_object_agg(x->>'key', case r.k when 'nwc' then (x->>'ca')::numeric - (x->>'cl')::numeric
          when 'ncl' then -(x->>'ncl')::numeric when 'net' then (x->>'nca')::numeric + (x->>'ca')::numeric - (x->>'cl')::numeric - (x->>'ncl')::numeric
          when 'equity' then (x->>'capital')::numeric + (x->>'reserves')::numeric else (x->>r.k)::numeric end) from jsonb_array_elements(v_years) x)
        || jsonb_build_object('line', r.label, '_style', case when r.st = 2 then 'subtotal' else 'line' end, '_indent', case when r.st = 2 then 0 else 1 end));
    end loop;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Statement of profit or loss', '_style', 'heading', '_indent', 0));
    for r in select * from (values ('Revenue', 'revenue', 1), ('Profit before tax', 'pbt', 1), ('Income tax expense', 'tax', 1), ('Profit for the year', 'pat', 2)) t(label, k, st) loop
      v_rows := v_rows || jsonb_build_array((select jsonb_object_agg(x->>'key', case when r.k = 'tax' then -(x->>'tax')::numeric else (x->>r.k)::numeric end) from jsonb_array_elements(v_years) x)
        || jsonb_build_object('line', r.label, '_style', case when r.st = 2 then 'subtotal' else 'line' end, '_indent', case when r.st = 2 then 0 else 1 end));
    end loop;
    if (o.share_info->>'issued_shares')::numeric > 0 then
      v_rows := v_rows || jsonb_build_array((select jsonb_object_agg(x->>'key', round((x->>'pat')::numeric / (o.share_info->>'issued_shares')::numeric * 100, 2)) from jsonb_array_elements(v_years) x)
        || jsonb_build_object('line', 'Earnings per share (kobo)', '_style', 'line', '_indent', 1, '_number', true));
    end if;
    v_extra := v_extra || jsonb_build_object('columns', v_cols);
  else
    raise exception 'Unknown report.';
  end if;
  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'extra', v_extra);
end $$;

-- ---------------------------------------------------------------------------
-- 6. The whole set, for Word, PDF and Excel
-- ---------------------------------------------------------------------------
create or replace function public.financial_statements_pack(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; pr jsonb; v jsonb; w jsonb := '[]'::jsonb; k text; n jsonb; v_susp numeric;
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
  if nullif(o.rc_number, '') is null or nullif(o.tin, '') is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the RC number and TIN under Settings, Branding.')); end if;
  if o.company_secretary is null then w := w || jsonb_build_array(jsonb_build_object('level', 'warn', 'text', 'Add the company secretary for the directors'' report.')); end if;
  return v || jsonb_build_object('warnings', w);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.update_corporate_info(uuid, jsonb), public.statement_extra(uuid, text, date, date, jsonb),
  public.financial_statements_pack(uuid, date, date) from public, anon;
grant execute on function public.update_corporate_info(uuid, jsonb), public.statement_extra(uuid, text, date, date, jsonb),
  public.financial_statements_pack(uuid, date, date) to authenticated;
revoke all on function private.clean_directors(jsonb), private.corporate_json(uuid), private.sum_codes(jsonb, text[]), private.sum_range(jsonb, text, text),
  private.ftxt(text), private.fhd(text), private.fsh(text), private.fdate(date), private.naira(numeric), private.fl(text, numeric, numeric, int),
  private.fs_periods(uuid, date, date), private.kv(text, text), private.sig(text, text), private.signing_directors(uuid), private.director_sigs(uuid)
  from public, anon, authenticated;
