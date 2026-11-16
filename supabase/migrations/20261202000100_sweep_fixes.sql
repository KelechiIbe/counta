-- Fixes from the November bug sweep.
--
-- 1. Deleting a business keeps an accountant practice whose own business it is. The admin portal's delete removed every row
--    that pointed at the business through a link the schema keeps with no business (on delete set null), and two of those
--    rows belong to someone else: the practice (practices.firm_org_id) and the commissions a partner practice earned on the
--    business (partner_commissions.org_id). Those now stay and lose the link, as the schema meant. The preview names the
--    practice that stays.
-- 2. The trial balance of books with no entries balances. With no rows the totals were empty, and the screen and the export
--    read that as "Out of balance".
-- 3. WHT credits used by a return filed or paid outside Counta leave account 1401.
--    a. Personal income tax: marking a year as filed outside Counta takes the WHT credit the return used (Counta's figure
--       unless the person gives another) and moves it out of 1401 as approval does, one line per person; undoing the mark
--       reverses it. The next year then counts that credit as used, in place of Counta's figure.
--    b. Companies income tax: "Record CIT paid outside Counta" on a year whose accounts year has ended takes the WHT credit
--       the return used (Counta's figure unless the person gives another) and posts Dr CIT payable (then the development
--       levy payable, then the tax expense for what the books did not provide) / Cr 1401, tagged with the year. Undo
--       reverses it. A later payment through Counta clears only the credit not cleared already.
-- 4. A Flutterwave webhook for an audit fee (AUD- reference) asks the audits function to settle it now, through the same call
--    as its five-minute check (svc_audit_poll_now), in place of reading every wallet's statement.
-- 5. Sixteen private helpers get a fixed search_path, and five foreign keys get an index (Supabase advisors).

-- ---------------------------------------------------------------------------
-- 0. New column
-- ---------------------------------------------------------------------------
-- cit_years.paid_outside: {by, at, on, wht_credit, computed, note, journal_id} when the year's tax was paid outside Counta.
alter table public.cit_years add column if not exists paid_outside jsonb;

-- ---------------------------------------------------------------------------
-- 3. WHT credits: the posting, and the two actions
-- ---------------------------------------------------------------------------
-- private.pit_wht_post: p_amount (a credit given for a year filed outside Counta) in place of the computation's, dated p_at.
-- Each person's line is their part of the credit the computation used, or, when it used none, their share of the business.
drop function if exists private.pit_wht_post(uuid, integer, jsonb, public.members);
create or replace function private.pit_wht_post(p_org uuid, p_year int, p_comp jsonb, m public.members, p_amount numeric default null,
  p_at timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_used numeric; v_bal numeric; v_post numeric; v_left numeric; v_amt numeric; v_basis numeric; v_by_share boolean; v_n int; i int := 0;
  x jsonb; v_w numeric; v_lines jsonb := '[]'::jsonb; v_sole boolean := p_comp->>'kind' = 'sole'; j public.journals;
begin
  if coalesce(p_comp->'business'->>'source', 'books') = 'imported' then return null; end if;
  v_used := round(coalesce(p_amount, private.num(p_comp->'figures'->>'wht_credit_used'), 0), 2);
  if v_used <= 0.004 then return null; end if;
  v_bal := greatest((select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401'), 0);
  v_post := least(v_used, round(v_bal, 2));
  if v_post <= 0.004 then return null; end if;
  select coalesce(sum(private.num(p->'computation'->'figures'->>'wht_credit')), 0) into v_basis
  from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p where coalesce(private.num(p->'computation'->'figures'->>'wht_credit'), 0) > 0;
  v_by_share := v_basis <= 0.004;
  if v_by_share then
    select coalesce(sum(private.num(p->>'share_pct')), 0) into v_basis
    from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p where coalesce(private.num(p->>'share_pct'), 0) > 0;
  end if;
  select count(*) into v_n from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p
  where case when v_by_share then coalesce(private.num(p->>'share_pct'), 0) > 0 else coalesce(private.num(p->'computation'->'figures'->>'wht_credit'), 0) > 0 end;
  v_left := v_post;
  if v_basis > 0.004 then
    for x in select p from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p
             where case when v_by_share then coalesce(private.num(p->>'share_pct'), 0) > 0 else coalesce(private.num(p->'computation'->'figures'->>'wht_credit'), 0) > 0 end loop
      i := i + 1;
      v_w := case when v_by_share then private.num(x->>'share_pct') else private.num(x->'computation'->'figures'->>'wht_credit') end;
      v_amt := case when i = v_n then v_left else round(v_w * v_post / v_basis, 2) end;
      v_left := v_left - v_amt;
      if v_amt > 0.004 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'retained_earnings'), 'debit', v_amt,
          'memo', case when v_sole then 'WHT credit set against the owner''s ' || p_year || ' income tax'
            else 'WHT credit set against a partner''s ' || p_year || ' income tax (' || rtrim(to_char(private.num(x->>'share_pct'), 'FM990.99'), '.') || '% share)' end));
      end if;
    end loop;
  end if;
  -- Nobody to split it between: one line for the business.
  if jsonb_array_length(v_lines) = 0 then
    v_lines := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'retained_earnings'), 'debit', v_post,
      'memo', 'WHT credit set against the ' || p_year || ' income tax'));
  end if;
  v_lines := v_lines || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'wht_receivable'), 'credit', v_post, 'doc_type', 'pit_wht:' || p_year,
    'memo', 'WHT credit notes used against the ' || p_year || ' income tax' || case when p_amount is not null then ' (filed outside Counta)' else '' end));
  j := private.post_entry(p_org, 'WHT credit notes used against the ' || p_year || ' income tax' || case when p_amount is not null then ' (filed outside Counta)' else '' end,
    'pit_year', null, m.id, m.id, v_lines, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', case when p_amount is not null then 'pit_filed_outside' else 'pit_return' end,
      'year', p_year, 'by', m.display_name))));
  return j.id;
end $$;

-- What account 1401 holds now, for the two actions below.
create or replace function private.wht_held_now(p_org uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select round(greatest(coalesce(sum(debit - credit), 0), 0), 2) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401'
$$;

-- Midday, in the business's time, on p_day or, when the books are closed through that day, on the first open day after.
-- Entries for returns filed or paid outside Counta, and their reversals, go there.
create or replace function private.noon_open(p_org uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public, private as $$
  select (greatest(p_day, coalesce(private.closed_through(p_org) + 1, p_day)) + time '12:00')
    at time zone coalesce((select nullif(timezone, '') from orgs where id = p_org), 'Africa/Lagos')
$$;

-- A WHT credit typed on a form: null when none was given; refused unless it is an amount of 0 or more.
create or replace function private.wht_credit_given(p jsonb) returns numeric
language plpgsql immutable set search_path = public, private as $$
declare v numeric;
begin
  if not (p ? 'wht_credit') or nullif(trim(coalesce(p->>'wht_credit', '')), '') is null then return null; end if;
  v := private.num(replace(p->>'wht_credit', ',', ''));
  if v is null or v < 0 then raise exception 'Enter the WHT credit as an amount, or 0.'; end if;
  return round(v, 2);
end $$;

-- public.mark_pit_filed: a year marked as filed outside Counta moves the WHT credit its return used out of 1401
-- (p.wht_credit, else Counta's figure); undoing the mark reverses it.
create or replace function public.mark_pit_filed(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; y public.pit_person_years; v_on date; comp jsonb; v_credit numeric; v_held numeric; v_journal uuid;
begin
  m := private.require(p_org, 'file_tax');
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  v_on := coalesce(nullif(p->>'filed_on', '')::date, private.local_day(p_org, now()));
  if v_on > private.local_day(p_org, now()) then raise exception 'A return cannot be filed in the future.'; end if;
  if p ? 'outside' then
    if coalesce((p->>'outside')::boolean, false) then
      if py.status <> 'draft' then raise exception 'The % return is %.', p_year, replace(py.status, '_', ' '); end if;
      comp := private.pit_run(p_org, p_year);
      v_credit := coalesce(private.wht_credit_given(p), round(coalesce(private.num(comp->'figures'->>'wht_credit_used'), 0), 2));
      if coalesce(comp->'business'->>'source', 'books') <> 'imported' and v_credit > 0.004 then
        v_held := private.wht_held_now(p_org);
        if v_credit > v_held + 0.004 then
          raise exception 'Account 1401 holds NGN % of WHT credit notes. Enter at most that.', to_char(v_held, 'FM999,999,999,990.00');
        end if;
        v_journal := private.pit_wht_post(p_org, p_year, comp, m, v_credit, private.noon_open(p_org, v_on));
      end if;
      update pit_years set status = 'filed_outside',
        settings = (settings - 'wht_journal_id') || jsonb_build_object('filed_outside', jsonb_build_object('by', m.display_name, 'at', now(),
          'on', v_on, 'note', nullif(left(trim(coalesce(p->>'note', '')), 300), ''), 'wht_credit', v_credit,
          'computed', round(coalesce(private.num(comp->'figures'->>'wht_credit_used'), 0), 2)))
          || case when v_journal is not null then jsonb_build_object('wht_journal_id', v_journal) else '{}'::jsonb end,
        updated_by = m.id, updated_at = now()
      where org_id = p_org and accounting_year = p_year;
    else
      if py.status <> 'filed_outside' then raise exception 'The year was not marked as filed outside Counta.'; end if;
      if py.settings ? 'wht_journal_id' and exists (select 1 from journals where id = (py.settings->>'wht_journal_id')::uuid)
         and not exists (select 1 from journals where reversal_of = (py.settings->>'wht_journal_id')::uuid) then
        perform private.reverse_entry((py.settings->>'wht_journal_id')::uuid, m.id, 'The ' || p_year || ' return is no longer marked as filed outside Counta',
          private.noon_open(p_org, (select entry_date from journals where id = (py.settings->>'wht_journal_id')::uuid)));
      end if;
      update pit_years set status = 'draft', settings = settings - 'filed_outside' - 'wht_journal_id', updated_by = m.id, updated_at = now()
      where org_id = p_org and accounting_year = p_year;
    end if;
    return public.pit_year(p_org, p_year);
  end if;
  if py.status <> 'approved' then raise exception 'Approve the % return first.', p_year; end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = nullif(p->>'person_id', '')::uuid for update;
  if not found then raise exception 'Choose the person.'; end if;
  if y.status not in ('approved', 'rejected') then raise exception 'That return is %.', y.status; end if;
  if length(trim(coalesce(p->>'acknowledgement_ref', ''))) < 3 then raise exception 'Enter the acknowledgement or assessment number the state gave.'; end if;
  update pit_person_years set status = 'filed', filed_by_business = true, filed_at = v_on::timestamptz, acknowledgement_ref = left(trim(p->>'acknowledgement_ref'), 80),
    flux_message = null, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = y.person_id;
  return public.pit_year(p_org, p_year);
end $$;

-- CIT paid outside Counta. p: {wht_credit (else Counta's figure), paid_on (else today), note} | {undo: true}.
-- Dr 2208 CIT payable, then 2209 development levy payable, as far as the books provided them; the rest Dr 7501 (the tax
-- expense, not provided for in the books). Cr 1401 tagged 'cit_wht:<year>', on the day paid (or the first open day after it).
-- Undo reverses it on the same day. Refused once the year's payment is recorded through Counta, which clears the credit itself.
create or replace function public.record_cit_paid_outside(p_org uuid, p_year int, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; pr record; comp jsonb; v_on date; v_credit numeric; v_computed numeric; v_held numeric; v_left numeric;
  v_bal numeric; v_d numeric; c text; v_lines jsonb := '[]'::jsonb; j public.journals;
begin
  m := private.require(p_org, 'file_tax');
  if p_year is null or p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select pfrom, pto into pr from private.cit_period(p_org, p_year);
  insert into cit_years (org_id, accounting_year, period_from, period_to, source, updated_by)
  values (p_org, p_year, pr.pfrom, pr.pto, private.cit_default_source(p_org, pr.pfrom, pr.pto), m.id)
  on conflict (org_id, accounting_year) do nothing;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if coalesce((p->>'undo')::boolean, false) then
    if cy.paid_outside is null then raise exception 'The % tax is not recorded as paid outside Counta.', p_year; end if;
    if cy.tax_paid_at is not null then raise exception 'The % tax payment is now recorded in Counta, so this cannot be undone.', p_year; end if;
    if nullif(cy.paid_outside->>'journal_id', '') is not null and exists (select 1 from journals where id = (cy.paid_outside->>'journal_id')::uuid)
       and not exists (select 1 from journals where reversal_of = (cy.paid_outside->>'journal_id')::uuid) then
      perform private.reverse_entry((cy.paid_outside->>'journal_id')::uuid, m.id, 'The ' || p_year || ' tax is no longer recorded as paid outside Counta',
        private.noon_open(p_org, (select entry_date from journals where id = (cy.paid_outside->>'journal_id')::uuid)));
    end if;
    update cit_years set paid_outside = null, updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
    return public.cit_year(p_org, p_year);
  end if;
  if cy.tax_paid_at is not null then raise exception 'The % tax payment is recorded in Counta already.', p_year; end if;
  if cy.paid_outside is not null then raise exception 'The % tax is already recorded as paid outside Counta. Undo that first to change it.', p_year; end if;
  if pr.pto >= private.local_day(p_org, now()) then raise exception 'The % accounts year has not ended yet.', p_year; end if;
  v_on := coalesce(nullif(p->>'paid_on', '')::date, private.local_day(p_org, now()));
  if v_on > private.local_day(p_org, now()) then raise exception 'A payment cannot be in the future.'; end if;
  if v_on <= pr.pto then raise exception 'The tax for the % accounts is paid after the year ends. Check the date.', p_year; end if;
  comp := private.cit_run(p_org, p_year);
  v_computed := round(coalesce(private.num(comp->'figures'->>'wht_credit'), 0), 2);
  v_credit := coalesce(private.wht_credit_given(p), v_computed);
  if v_credit > 0.004 then
    v_held := private.wht_held_now(p_org);
    if v_credit > v_held + 0.004 then
      raise exception 'Account 1401 holds NGN % of WHT credit notes. Enter at most that.', to_char(v_held, 'FM999,999,999,990.00');
    end if;
    v_left := v_credit;
    foreach c in array array['2208', '2209'] loop
      v_bal := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c), 0);
      v_d := least(v_left, round(v_bal, 2));
      if v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', c, 'debit', v_d, 'memo', 'WHT credit notes set against the ' || p_year || ' tax');
        v_left := v_left - v_d;
      end if;
    end loop;
    if v_left > 0.004 then
      v_lines := v_lines || jsonb_build_object('code', '7501', 'debit', v_left, 'memo', 'WHT credit notes set against the ' || p_year || ' tax · not provided for in the books');
    end if;
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, 'wht_receivable'), 'credit', v_credit, 'doc_type', 'cit_wht:' || p_year,
      'memo', 'WHT credit notes used against the ' || p_year || ' tax (paid outside Counta)');
    j := private.post_entry(p_org, 'WHT credit notes used against the ' || p_year || ' companies income tax (paid outside Counta)', 'cit_year', null, m.id, m.id,
      v_lines, private.noon_open(p_org, v_on),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'cit_paid_outside', 'year', p_year, 'by', m.display_name))));
  end if;
  update cit_years set paid_outside = jsonb_build_object('by', m.display_name, 'at', now(), 'on', v_on, 'wht_credit', v_credit, 'computed', v_computed,
      'note', nullif(left(trim(coalesce(p->>'note', '')), 300), ''), 'journal_id', j.id),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $$;

-- ---------------------------------------------------------------------------
-- 4. An audit fee's webhook
-- ---------------------------------------------------------------------------
-- Asks the audits function to check its open checkouts now (what its cron does every five minutes). True when the call left.
create or replace function public.svc_audit_poll_now() returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  return private.call_function('audits', '{"action":"poll"}'::jsonb) is not null;
end $$;

-- ---------------------------------------------------------------------------
-- Existing functions, each with the change named above it
-- ---------------------------------------------------------------------------

-- private.business_purge_plan: names the accountant practices whose own business this is; they stay (1).
CREATE OR REPLACE FUNCTION private.business_purge_plan(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; v_people jsonb; v_removed uuid[]; v_orgs uuid[]; v_samples jsonb; v_blockers text[] := '{}'; v_moving text[];
  w record; v_bal numeric;
begin
  select * into o from orgs where id = p_org;
  if not found then return null; end if;

  -- Everyone with a login in the business, and whether that login stays.
  with ppl as (
    select distinct on (m.user_id) m.user_id, coalesce(nullif(trim(m.display_name), ''), u.email) as name, coalesce(u.email, m.email) as email, m.role,
      exists (select 1 from platform_admins a where a.user_id = m.user_id) or exists (select 1 from platform_reviewers r where r.user_id = m.user_id) as staff,
      exists (select 1 from practice_members pm where pm.user_id = m.user_id and pm.status <> 'disabled') as accountant,
      (select string_agg(o2.name, ', ' order by o2.name) from members m2 join orgs o2 on o2.id = m2.org_id
        where m2.user_id = m.user_id and m2.org_id <> p_org and not o2.is_sample and m2.status <> 'disabled') as elsewhere
    from members m left join auth.users u on u.id = m.user_id
    where m.org_id = p_org and m.user_id is not null
    order by m.user_id, case m.role when 'owner' then 0 else 1 end
  )
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'name', name, 'email', email, 'role', role,
      'login', case when staff or accountant or elsewhere is not null then 'kept' else 'removed' end,
      'why', case when staff then 'On TaxStreem''s team' when elsewhere is not null then 'Also in ' || elsewhere
                  when accountant then 'In an accountant practice' end) order by (role = 'owner') desc, name), '[]'::jsonb),
    coalesce(array_agg(user_id) filter (where not staff and not accountant and elsewhere is null), '{}')
  into v_people, v_removed from ppl;

  -- Sample businesses that belong only to people whose logins go.
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb), coalesce(array_agg(s.id), '{}')
  into v_samples, v_orgs
  from orgs s
  where s.is_sample and s.id <> p_org
    and (s.created_by = any(v_removed) or exists (select 1 from members m where m.org_id = s.id and m.user_id = any(v_removed)))
    and not exists (select 1 from members m where m.org_id = s.id and m.user_id is not null and m.status <> 'disabled' and not (m.user_id = any(v_removed)));
  v_orgs := array_prepend(p_org, v_orgs);

  -- Money held: the books' balance of each wallet, and the last balance the bank reported.
  for w in select 'The wallet' as what, x.id, x.bank_name, x.account_number, private.wallet_ledger(x.id) as books,
             greatest(coalesce(x.provider_available, 0), coalesce(x.provider_ledger, 0)) as bank from wallets x where x.org_id = any(v_orgs)
           union all
           select 'The tax wallet', t.id, t.bank_name, t.account_number, private.tax_wallet_ledger(t.id), greatest(coalesce(t.provider_available, 0), coalesce(t.provider_ledger, 0))
           from tax_wallets t where t.org_id = any(v_orgs) loop
    v_bal := greatest(abs(coalesce(w.books, 0)), coalesce(w.bank, 0));
    if v_bal > 0 then
      v_blockers := v_blockers || format('%s%s holds NGN %s. Move the money out first.', w.what,
        case when w.account_number is not null then format(' (%s %s)', coalesce(w.bank_name, ''), w.account_number) else '' end, to_char(v_bal, 'FM999,999,999,990.00'));
    end if;
  end loop;
  v_moving := array_remove(array[
    case when exists (select 1 from payouts where org_id = any(v_orgs) and status in ('approved', 'processing')) then 'a payout being sent' end,
    case when exists (select 1 from payout_batches where org_id = any(v_orgs) and status in ('approved', 'sending')) then 'a bulk payment being sent' end,
    case when exists (select 1 from tax_moves where org_id = any(v_orgs) and status in ('pending', 'sending')) then 'money moving between the wallets' end,
    case when exists (select 1 from tax_transfers where org_id = any(v_orgs) and status in ('pending', 'sent')) then 'a transfer to the tax wallet' end,
    case when exists (select 1 from tax_payments where org_id = any(v_orgs) and status in ('approved', 'processing'))
           or exists (select 1 from tax_payment_instructions where org_id = any(v_orgs) and status = 'paying') then 'a tax payment being made' end,
    case when exists (select 1 from subscription_charges where org_id = any(v_orgs) and status in ('pending', 'sent')) then 'a subscription payment' end], null);
  if array_length(v_moving, 1) > 0 then
    v_blockers := v_blockers || format('Money is on its way: %s. Wait until it has landed.', array_to_string(v_moving, ', '));
  end if;
  if o.is_sample then v_blockers := v_blockers || 'This is a sample business. It goes when its owner''s business is deleted.'::text; end if;

  return jsonb_build_object(
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'is_sample', o.is_sample, 'created_at', o.created_at, 'rc_number', o.rc_number, 'tin', o.tin),
    'people', v_people,
    'invited', (select count(*) from members where org_id = p_org and user_id is null and status <> 'disabled'),
    'removed', to_jsonb(v_removed),
    'samples', v_samples,
    'orgs', to_jsonb(v_orgs),
    'counts', jsonb_build_object(
      'sales', (select count(*) from sales where org_id = p_org),
      'bills', (select count(*) from bills where org_id = p_org),
      'customers', (select count(*) from customers where org_id = p_org),
      'vendors', (select count(*) from vendors where org_id = p_org),
      'items', (select count(*) from items where org_id = p_org),
      'journals', (select count(*) from journals where org_id = p_org),
      'branches', (select count(*) from locations where org_id = p_org),
      'files', (select count(*) from storage.objects so where so.bucket_id in ('documents', 'item-photos')
                and split_part(so.name, '/', 1) = any(select x::text from unnest(v_orgs) x)),
      'bank_feeds', (select count(*) from bank_accounts where org_id = any(v_orgs) and provider = 'mono' and provider_ref is not null),
      'tools', (select count(*) from integrations where org_id = any(v_orgs))),
    'mono', (select coalesce(jsonb_agg(provider_ref), '[]'::jsonb) from bank_accounts where org_id = any(v_orgs) and provider = 'mono' and provider_ref is not null),
    'whatsapp', (select coalesce(jsonb_agg(id), '[]'::jsonb) from whatsapp_sessions where org_id = any(v_orgs) and kind <> 'counta'),
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb)
      from practices p where p.firm_org_id = any(v_orgs)),
    'blockers', to_jsonb(v_blockers),
    'can_delete', coalesce(array_length(v_blockers, 1), 0) = 0);
end $function$;

-- public.admin_business_delete: a practice whose own business this is, and a partner practice's commissions on it, stay and lose the link (1).
CREATE OR REPLACE FUNCTION public.admin_business_delete(p_org uuid, p_confirm text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_uid uuid := private.require_staff(); o public.orgs; v jsonb; v_org uuid; r record; v_audit bigint; v_removed uuid[];
  norm text := lower(regexp_replace(trim(coalesce(p_confirm, '')), '\s+', ' ', 'g'));
begin
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'This business is no longer on Counta.'; end if;
  perform private.require_not_kept(o.retain_until);
  if norm = '' or norm <> lower(regexp_replace(trim(o.name), '\s+', ' ', 'g')) then
    raise exception 'Type the business''s name exactly as it shows, to confirm.';
  end if;
  v := private.business_purge_plan(p_org);
  if not (v->>'can_delete')::boolean then raise exception '%', v->'blockers'->>0; end if;
  select coalesce(array_agg(x::uuid), '{}') into v_removed from jsonb_array_elements_text(v->'removed') x;

  perform set_config('app.allow_purge', 'on', true);
  for v_org in select x::uuid from jsonb_array_elements_text(v->'orgs') x loop
    -- Keys its tools kept in Vault.
    delete from vault.secrets where id in (select secret_id from integrations where org_id = v_org and secret_id is not null
                                           union select hook_secret_id from integrations where org_id = v_org and hook_secret_id is not null);
    -- Tables that keep their rows (with no business) when a business goes: deleted here, so nothing of it stays behind.
    -- Two hold another party's records, which stay and lose the link: the practice whose own business this is, and the
    -- commissions a partner practice earned on it.
    for r in select c.conrelid::regclass as tbl, a.attname as col from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
             where c.contype = 'f' and c.confrelid = 'public.orgs'::regclass and c.confdeltype <> 'c' and cardinality(c.conkey) = 1 loop
      if (r.tbl::text, r.col::text) in (('practices', 'firm_org_id'), ('partner_commissions', 'org_id')) then
        execute format('update %s set %I = null where %I = $1', r.tbl, r.col, r.col) using v_org;
      else
        execute format('delete from %s where %I = $1', r.tbl, r.col) using v_org;
      end if;
    end loop;
    delete from orgs where id = v_org;
  end loop;
  perform set_config('app.allow_purge', 'off', true);

  insert into admin_audit (user_id, action, target, detail)
  values (v_uid, 'delete_business', p_org::text, jsonb_build_object('name', o.name,
    'logins_removed', cardinality(v_removed), 'logins_kept', (select count(*) from jsonb_array_elements(v->'people') p where p->>'login' = 'kept'),
    'samples', jsonb_array_length(v->'samples'), 'counts', v->'counts',
    'pending', jsonb_build_object('users', to_jsonb(v_removed), 'orgs', v->'orgs', 'mono', v->'mono', 'whatsapp', v->'whatsapp')))
  returning id into v_audit;
  return jsonb_build_object('ok', true, 'audit_id', v_audit, 'name', o.name, 'logins', cardinality(v_removed));
end $function$;

-- public.accounting_report: the trial balance of books with no entries totals 0 and balances (2).
CREATE OR REPLACE FUNCTION public.accounting_report(p_org uuid, p_report text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_today date; v_from date; v_to date; v_pfrom date; v_pto date; v_rows jsonb := '[]'::jsonb; v_extra jsonb := '{}'::jsonb;
  c jsonb; p jsonb; v_cmp text := coalesce(nullif(p_options->>'compare', ''), 'prior_year'); v_accts text[]; r record; v_cf jsonb; v_days numeric; v_months int;
  v_month date; v_cols jsonb; v_t jsonb; v_pt jsonb; v_bpto date;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Financial reports need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_to := coalesce(p_to, v_today);
  v_from := coalesce(p_from, case when p_report in ('sofp', 'sopl', 'soce', 'cash_flow', 'notes', 'ratios', 'pack') then private.fy_start(p_org, v_to)
                                  else date_trunc('month', v_to)::date end);
  if v_from > v_to then raise exception 'The start date is after the end date.'; end if;
  if v_cmp = 'prior_period' then v_pto := v_from - 1; v_pfrom := v_from - (v_to - v_from) - 1;
  elsif v_cmp = 'prior_year' then v_pto := (v_to - interval '1 year')::date; v_pfrom := (v_from - interval '1 year')::date;
  end if;
  -- The statement of financial position compares with the end of the previous financial year (IAS 1.38; IAS 34.20(a) for part-years).
  v_bpto := case when v_cmp = 'prior_year' then private.fy_start(p_org, v_to) - 1 else v_pto end;
  v_extra := jsonb_build_object('from', v_from, 'to', v_to, 'prior_from', v_pfrom, 'prior_to', v_pto, 'org', jsonb_build_object('name', o.name, 'tin', o.tin,
    'rc_number', o.rc_number, 'address', o.address, 'framework', o.reporting_framework), 'closed_through', private.closed_through(p_org));
  if jsonb_typeof(p_options->'accounts') = 'array' then select array_agg(value) into v_accts from jsonb_array_elements_text(p_options->'accounts'); end if;

  if p_report = 'coa' then
    select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'parent', a.parent_code, 'category', a.category, 'normal_balance', a.normal_balance,
        'statement', case a.statement when 'sofp' then 'Financial position' when 'pl' then 'Profit or loss' when 'oci' then 'Other comprehensive income' else 'System' end,
        'ifrs_line', a.ifrs_line, 'cash_flow', a.cash_flow_class, 'postable', private.postable(p_org, a.code), 'own', a.own, 'active', a.active,
        'balance', coalesce(b.bal, 0), '_style', case when a.is_group then 'subheading' else 'line' end, '_indent', case when a.is_group then 0 else 1 end) order by a.code)
    into v_rows from private.accounts_of(p_org) a left join private.balances_at(p_org, v_to) b on b.code = a.code
    where a.active or coalesce(b.bal, 0) <> 0;

  elsif p_report = 'trial_balance' then
    select jsonb_agg(x order by x->>'code') into v_rows from (
      select jsonb_build_object('code', m2.code, 'name', m2.name, 'ifrs_line', m2.ifrs_line, 'category', m2.category,
        'opening', coalesce(ob.bal, 0), 'debit', coalesce(mv.dr, 0), 'credit', coalesce(mv.cr, 0),
        'closing_dr', greatest(coalesce(ob.bal, 0) + coalesce(mv.net, 0) + coalesce(ye.net, 0), 0), 'closing_cr', greatest(-(coalesce(ob.bal, 0) + coalesce(mv.net, 0) + coalesce(ye.net, 0)), 0)) x
      from private.acct_meta(p_org) m2
      left join private.balances_at(p_org, v_from - 1) ob on ob.code = m2.code
      left join private.movement(p_org, v_from, v_to) mv on mv.code = m2.code
      left join (select l.account_code code, sum(l.debit - l.credit) net from journal_lines l join journals j on j.id = l.journal_id
                 where l.org_id = p_org and j.entry_date between v_from and v_to and j.source_type = 'year_end' group by 1) ye on ye.code = m2.code
      where coalesce(ob.bal, 0) <> 0 or coalesce(mv.dr, 0) <> 0 or coalesce(mv.cr, 0) <> 0 or coalesce(ye.net, 0) <> 0) t;
    v_extra := v_extra || jsonb_build_object('total_dr', (select coalesce(sum((x->>'closing_dr')::numeric), 0) from jsonb_array_elements(coalesce(v_rows, '[]')) x),
      'total_cr', (select coalesce(sum((x->>'closing_cr')::numeric), 0) from jsonb_array_elements(coalesce(v_rows, '[]')) x));
    v_extra := v_extra || jsonb_build_object('balances', abs((v_extra->>'total_dr')::numeric - (v_extra->>'total_cr')::numeric) < 0.01);

  elsif p_report in ('gl', 'account_ledger') then
    with ob as (select * from private.balances_at(p_org, v_from - 1)),
    meta as (select * from private.acct_meta(p_org)),
    ln as (select l.id, l.account_code, l.debit, l.credit, l.memo, l.party_id, j.entry_date, j.je_no, j.ref, j.memo jmemo, j.source_type, j.origin, j.ai_confidence
           from journal_lines l join journals j on j.id = l.journal_id
           where l.org_id = p_org and j.entry_date between v_from and v_to and (v_accts is null or l.account_code = any(v_accts))),
    accts as (select distinct account_code code from ln union select code from ob where bal <> 0 and (v_accts is null or code = any(v_accts)))
    select jsonb_agg(x order by x->>'code', (x->>'_seq')::numeric) into v_rows from (
      select jsonb_build_object('code', a.code, 'account', a.code || ' ' || coalesce(m2.name, ''), 'memo', 'Opening balance', 'balance', coalesce(ob.bal, 0),
        '_style', 'subheading', '_seq', 0) x
      from accts a left join meta m2 on m2.code = a.code left join ob on ob.code = a.code
      union all
      select jsonb_build_object('code', ln.account_code, 'account', ln.account_code || ' ' || coalesce(m2.name, ''), 'date', ln.entry_date, 'ref', ln.ref,
        'memo', coalesce(ln.memo, ln.jmemo), 'source', ln.source_type, 'origin', ln.origin, 'ai_confidence', ln.ai_confidence,
        'party', coalesce((select name from customers where id = ln.party_id), (select name from vendors where id = ln.party_id)),
        'debit', ln.debit, 'credit', ln.credit,
        'balance', coalesce(ob.bal, 0) + sum(ln.debit - ln.credit) over (partition by ln.account_code order by ln.entry_date, ln.je_no, ln.id),
        '_seq', ln.entry_date - date '2000-01-01' + ln.je_no / 1e7) x
      from ln left join ob on ob.code = ln.account_code left join meta m2 on m2.code = ln.account_code
      limit 60000) t;

  elsif p_report = 'journals' then
    select jsonb_agg(jsonb_build_object('date', j.entry_date, 'ref', j.ref, 'memo', j.memo, 'source', j.source_type, 'origin', j.origin, 'ai_confidence', j.ai_confidence,
        'code', l.account_code, 'account_name', private.account_name(p_org, l.account_code), 'debit', l.debit, 'credit', l.credit, 'line_memo', l.memo,
        'party', coalesce((select name from customers where id = l.party_id), (select name from vendors where id = l.party_id)),
        'posted_by', (select display_name from members where id = j.posted_by), 'approved_by', (select display_name from members where id = j.approved_by),
        'reversal_of', (select ref from journals where id = j.reversal_of)) order by j.entry_date, j.je_no, l.debit desc)
    into v_rows from journals j join journal_lines l on l.journal_id = j.id where j.org_id = p_org and j.entry_date between v_from and v_to;

  elsif p_report in ('ar_ledger', 'ap_ledger') then
    select jsonb_agg(jsonb_build_object('party', x.name, 'opening', x.opening, 'debit', x.dr, 'credit', x.cr, 'closing', x.opening + x.dr - x.cr) order by x.name) into v_rows from (
      select pp.name, coalesce(sum(case when j.entry_date < v_from then l.debit - l.credit end), 0) * case when p_report = 'ap_ledger' then -1 else 1 end opening,
        coalesce(sum(case when j.entry_date >= v_from then case when p_report = 'ap_ledger' then l.credit else l.debit end end), 0) dr,
        coalesce(sum(case when j.entry_date >= v_from then case when p_report = 'ap_ledger' then l.debit else l.credit end end), 0) cr
      from journal_lines l join journals j on j.id = l.journal_id
      join (select id, name from customers where org_id = p_org and p_report = 'ar_ledger' union all select id, name from vendors where org_id = p_org and p_report = 'ap_ledger') pp
        on pp.id = l.party_id
      where l.org_id = p_org and j.entry_date <= v_to and l.party_type = case when p_report = 'ar_ledger' then 'customer' else 'vendor' end
        and l.account_code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end,
          case when p_report = 'ar_ledger' then '2107' else '2101' end)
      group by pp.name) x where x.opening <> 0 or x.dr <> 0 or x.cr <> 0;
    -- Sub-ledger against control account (AR-01, AP-01).
    v_extra := v_extra || jsonb_build_object('subledger_total', (select coalesce(sum((x->>'closing')::numeric), 0) from jsonb_array_elements(coalesce(v_rows, '[]')) x),
      'control_total', (select coalesce(sum(b.bal), 0) * case when p_report = 'ap_ledger' then -1 else 1 end from private.balances_at(p_org, v_to) b
        where b.code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end,
          case when p_report = 'ar_ledger' then '2107' else '2101' end)),
      'unassigned', (select coalesce(sum(l.debit - l.credit), 0) * case when p_report = 'ap_ledger' then -1 else 1 end from journal_lines l join journals j on j.id = l.journal_id
        where l.org_id = p_org and j.entry_date <= v_to and l.party_id is null
          and l.account_code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end)));

  elsif p_report in ('ar_aging', 'ap_aging') then
    if p_report = 'ar_aging' then
      select jsonb_agg(jsonb_build_object('party', x.name, 'current', x.b0, 'd1_30', x.b1, 'd31_60', x.b2, 'd61_90', x.b3, 'd90_plus', x.b4, 'total', x.b0 + x.b1 + x.b2 + x.b3 + x.b4,
          'credit_limit', x.credit_limit) order by x.b0 + x.b1 + x.b2 + x.b3 + x.b4 desc) into v_rows from (
        select cu.name, cu.credit_limit,
          sum(bal) filter (where age <= 0) b0, sum(bal) filter (where age between 1 and 30) b1, sum(bal) filter (where age between 31 and 60) b2,
          sum(bal) filter (where age between 61 and 90) b3, sum(bal) filter (where age > 90) b4
        from (select s.customer_id, s.total - s.amount_paid - s.credited bal, v_to - coalesce(s.due_date, s.issue_date) age from sales s
              where s.org_id = p_org and s.status in ('open', 'partially_paid') and s.journal_id is not null and s.issue_date <= v_to) d
        join customers cu on cu.id = d.customer_id group by cu.name, cu.credit_limit) x;
    else
      select jsonb_agg(jsonb_build_object('party', x.name, 'current', x.b0, 'd1_30', x.b1, 'd31_60', x.b2, 'd61_90', x.b3, 'd90_plus', x.b4, 'total', x.b0 + x.b1 + x.b2 + x.b3 + x.b4)
          order by x.b0 + x.b1 + x.b2 + x.b3 + x.b4 desc) into v_rows from (
        select v.name, sum(bal) filter (where age <= 0) b0, sum(bal) filter (where age between 1 and 30) b1, sum(bal) filter (where age between 31 and 60) b2,
          sum(bal) filter (where age between 61 and 90) b3, sum(bal) filter (where age > 90) b4
        from (select b.vendor_id, b.total - b.amount_paid bal, v_to - b.due_date age from bills b where b.org_id = p_org and b.status in ('approved', 'partially_paid') and b.bill_date <= v_to) d
        join vendors v on v.id = d.vendor_id group by v.name) x;
    end if;
    v_rows := coalesce(v_rows, '[]'::jsonb);
    v_rows := (select jsonb_agg(x || jsonb_build_object('current', coalesce((x->>'current')::numeric, 0), 'd1_30', coalesce((x->>'d1_30')::numeric, 0),
      'd31_60', coalesce((x->>'d31_60')::numeric, 0), 'd61_90', coalesce((x->>'d61_90')::numeric, 0), 'd90_plus', coalesce((x->>'d90_plus')::numeric, 0),
      'total', coalesce((x->>'current')::numeric, 0) + coalesce((x->>'d1_30')::numeric, 0) + coalesce((x->>'d31_60')::numeric, 0) + coalesce((x->>'d61_90')::numeric, 0)
        + coalesce((x->>'d90_plus')::numeric, 0))) from jsonb_array_elements(v_rows) x);

  elsif p_report = 'fixed_assets' then
    select jsonb_agg(jsonb_build_object('number', a.number, 'name', a.name, 'class', ac.name, 'location', (select name from locations where id = a.location_id),
        'available_date', a.available_date, 'life_months', a.life_months, 'status', a.status, 'cost', a.cost,
        'accumulated', private.asset_accumulated(a.id), 'carrying_amount', a.cost - private.asset_accumulated(a.id),
        'charge_period', coalesce((select sum(l.credit - l.debit) from journal_lines l join journals j on j.id = l.journal_id where l.party_type = 'asset' and l.party_id = a.id
          and j.entry_date between v_from and v_to and j.source_type = 'depreciation'), 0),
        'disposed_at', a.disposed_at, 'proceeds', a.proceeds, 'serial_no', a.serial_no) order by a.number)
    into v_rows from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account
    where a.org_id = p_org and a.status in ('active', 'pending_confirmation', 'disposed') and coalesce(a.disposed_at, v_to) >= v_from;

  elsif p_report = 'sofp' then
    c := private.sofp_map(p_org, v_to);
    p := case when v_bpto is null then '{}'::jsonb else private.sofp_map(p_org, v_bpto) end;
    v_rows := private.sofp_rows(c, p);
    v_extra := v_extra || jsonb_build_object('prior_from', null, 'prior_to', v_bpto);
    v_extra := v_extra || jsonb_build_object('check', jsonb_build_object(
      'assets', (select (x->>'current')::numeric from jsonb_array_elements(v_rows) x where x->>'line' = 'Total assets'),
      'equity_and_liabilities', (select (x->>'current')::numeric from jsonb_array_elements(v_rows) x where x->>'line' = 'Total equity and liabilities')),
      'unreconciled', private.v(c, 'Unreconciled balances (assets)') + private.v(c, 'Unreconciled balances (liabilities)'),
      'opening_to_confirm', private.v(c, 'Opening balances to be confirmed'));
    v_extra := v_extra || jsonb_build_object('casts', abs(((v_extra->'check')->>'assets')::numeric - ((v_extra->'check')->>'equity_and_liabilities')::numeric) < 0.01);

  elsif p_report = 'sopl' then
    c := private.pl_map(p_org, v_from, v_to);
    p := case when v_pfrom is null then '{}'::jsonb else private.pl_map(p_org, v_pfrom, v_pto) end;
    v_rows := private.sopl_rows(c, p);
    v_extra := v_extra || jsonb_build_object('totals', private.pl_totals(c));

  elsif p_report = 'soce' then
    v_rows := private.soce_rows(p_org, v_from, v_to);

  elsif p_report = 'cash_flow' then
    v_cf := private.cash_flow_rows(p_org, v_from, v_to, v_pfrom, v_pto);
    v_rows := v_cf->'rows';
    v_extra := v_extra || jsonb_build_object('check', v_cf->'check', 'casts', (v_cf->'check'->>'ties')::boolean);

  elsif p_report = 'notes' then
    v_rows := private.note_rows(p_org, v_from, v_to, v_pfrom, v_pto, v_bpto);

  elsif p_report = 'ratios' then
    c := private.sofp_map(p_org, v_to); p := case when v_pto is null then '{}'::jsonb else private.sofp_map(p_org, v_pto) end;
    v_t := private.pl_totals(private.pl_map(p_org, v_from, v_to));
    v_pt := case when v_pfrom is null then '{}'::jsonb else private.pl_totals(private.pl_map(p_org, v_pfrom, v_pto)) end;
    v_days := v_to - v_from + 1;
    select jsonb_agg(jsonb_build_object('group', g, 'ratio', n, 'current', cur, 'prior', pri, 'formula', f, 'reading', rd, 'unit', u)) into v_rows from (values
      ('Liquidity', 'Current ratio', private.ratio(private.cur_assets(c), private.cur_liabs(c)), private.ratio(private.cur_assets(p), private.cur_liabs(p)),
        'Current assets ÷ current liabilities', 'Above 1.5 is comfortable; below 1 means short-term debts exceed short-term assets.', 'x'),
      ('Liquidity', 'Quick ratio', private.ratio(private.cur_assets(c) - private.v(c, 'Inventories'), private.cur_liabs(c)),
        private.ratio(private.cur_assets(p) - private.v(p, 'Inventories'), private.cur_liabs(p)), '(Current assets − inventories) ÷ current liabilities',
        'Ability to pay current debts without selling stock.', 'x'),
      ('Liquidity', 'Cash ratio', private.ratio(private.v(c, 'Cash and cash equivalents'), private.cur_liabs(c)), private.ratio(private.v(p, 'Cash and cash equivalents'), private.cur_liabs(p)),
        'Cash ÷ current liabilities', 'Share of current debts payable from cash today.', 'x'),
      ('Profitability', 'Gross margin', private.pct(private.v(v_t, 'gross_profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'gross_profit'), private.v(v_pt, 'revenue')),
        'Gross profit ÷ revenue', 'What each ₦100 of sales leaves after the cost of the goods.', '%'),
      ('Profitability', 'Operating margin', private.pct(private.v(v_t, 'operating_profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'operating_profit'), private.v(v_pt, 'revenue')),
        'Operating profit ÷ revenue', 'Profit from running the business before finance and tax.', '%'),
      ('Profitability', 'Net margin', private.pct(private.v(v_t, 'profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'profit'), private.v(v_pt, 'revenue')),
        'Profit for the period ÷ revenue', 'What is left for the owners from each ₦100 of sales.', '%'),
      ('Profitability', 'Return on assets (annualised)', private.pct(private.v(v_t, 'profit') * 365 / v_days, private.tot_assets(c)), private.pct(private.v(v_pt, 'profit') * 365 / v_days, private.tot_assets(p)),
        'Profit × 365 ÷ days ÷ total assets', 'How hard the assets work.', '%'),
      ('Profitability', 'Return on equity (annualised)', private.pct(private.v(v_t, 'profit') * 365 / v_days, private.tot_equity(c)), private.pct(private.v(v_pt, 'profit') * 365 / v_days, private.tot_equity(p)),
        'Profit × 365 ÷ days ÷ equity', 'Return earned on the owners'' money.', '%'),
      ('Efficiency', 'Stock days', private.ratio(private.v(c, 'Inventories') * v_days, private.v(v_t, 'cost_of_sales')), private.ratio(private.v(p, 'Inventories') * v_days, private.v(v_pt, 'cost_of_sales')),
        'Inventories ÷ cost of sales × days', 'How long stock sits before it sells.', 'days'),
      ('Efficiency', 'Debtor days', private.ratio(private.v(c, 'Trade and other receivables') * v_days, private.v(v_t, 'revenue') * 1.075),
        private.ratio(private.v(p, 'Trade and other receivables') * v_days, private.v(v_pt, 'revenue') * 1.075), 'Receivables ÷ revenue incl. VAT × days', 'How long customers take to pay.', 'days'),
      ('Efficiency', 'Creditor days', private.ratio(private.v(c, 'Trade and other payables') * v_days, private.v(v_t, 'cost_of_sales') * 1.075),
        private.ratio(private.v(p, 'Trade and other payables') * v_days, private.v(v_pt, 'cost_of_sales') * 1.075), 'Payables ÷ cost of sales incl. VAT × days', 'How long the business takes to pay suppliers.', 'days'),
      ('Efficiency', 'Asset turnover (annualised)', private.ratio(private.v(v_t, 'revenue') * 365 / v_days, private.tot_assets(c)), private.ratio(private.v(v_pt, 'revenue') * 365 / v_days, private.tot_assets(p)),
        'Revenue × 365 ÷ days ÷ total assets', 'Sales generated by each ₦1 of assets.', 'x'),
      ('Leverage', 'Debt to equity', private.ratio(private.v(c, 'Bank overdrafts') + private.v(c, 'Borrowings (current)') + private.v(c, 'Borrowings (non-current)')
          + private.v(c, 'Lease liabilities (current)') + private.v(c, 'Lease liabilities (non-current)'), private.tot_equity(c)),
        private.ratio(private.v(p, 'Bank overdrafts') + private.v(p, 'Borrowings (current)') + private.v(p, 'Borrowings (non-current)')
          + private.v(p, 'Lease liabilities (current)') + private.v(p, 'Lease liabilities (non-current)'), private.tot_equity(p)),
        'Borrowings, overdrafts and leases ÷ equity', 'How much of the business is funded by lenders.', 'x'),
      ('Leverage', 'Interest cover', private.ratio(private.v(v_t, 'operating_profit'), private.v(v_t, 'finance_costs')), private.ratio(private.v(v_pt, 'operating_profit'), private.v(v_pt, 'finance_costs')),
        'Operating profit ÷ finance costs', 'Times interest is covered by profit. Below 2 is tight.', 'x')
    ) t(g, n, cur, pri, f, rd, u);
    v_extra := v_extra || jsonb_build_object('cash_conversion_cycle',
      (select coalesce(sum(case when x->>'ratio' in ('Stock days', 'Debtor days') then (x->>'current')::numeric when x->>'ratio' = 'Creditor days' then -(x->>'current')::numeric end), 0)
       from jsonb_array_elements(v_rows) x));

  elsif p_report in ('management_accounts', 'budget_vs_actual') then
    -- Profit or loss by month (columns m1..m12) or against budget.
    v_months := least(greatest(((extract(year from v_to) - extract(year from v_from)) * 12 + extract(month from v_to) - extract(month from v_from) + 1)::int, 1), 24);
    if p_report = 'management_accounts' then
      v_cols := (select jsonb_agg(jsonb_build_object('key', 'm' || i, 'label', to_char((date_trunc('month', v_from) + make_interval(months => i - 1))::date, 'Mon YY'))) from generate_series(1, v_months) i);
      with mm as (select l.account_code code, ((extract(year from j.entry_date) - extract(year from v_from)) * 12 + extract(month from j.entry_date) - extract(month from v_from) + 1)::int idx,
                     -sum(l.debit - l.credit) amt
                  from journal_lines l join journals j on j.id = l.journal_id
                  where l.org_id = p_org and j.entry_date between v_from and v_to and j.source_type is distinct from 'year_end' group by 1, 2),
      meta as (select * from private.acct_meta(p_org) where statement = 'pl')
      select jsonb_agg(row order by sort, code) into v_rows from (
        select m2.code, case m2.ifrs_line when 'Revenue' then 1 when 'Cost of sales' then 2 when 'Other income' then 3 else 4 end sort,
          jsonb_build_object('code', m2.code, 'account', m2.name, 'ifrs_line', m2.ifrs_line)
          || coalesce((select jsonb_object_agg('m' || mm.idx, mm.amt) from mm where mm.code = m2.code), '{}'::jsonb)
          || jsonb_build_object('total', (select sum(mm.amt) from mm where mm.code = m2.code)) row
        from meta m2 where exists (select 1 from mm where mm.code = m2.code)) z;
      v_extra := v_extra || jsonb_build_object('columns', v_cols);
    else
      select jsonb_agg(jsonb_build_object('code', x.code, 'account', x.name, 'budget', x.budget, 'actual', x.actual, 'variance', x.actual - x.budget,
          'variance_pct', case when x.budget <> 0 then round((x.actual - x.budget) / abs(x.budget) * 100, 1) end) order by x.code) into v_rows from (
        select a.code, a.name, coalesce((select sum(amount) from budgets b where b.org_id = p_org and b.account_code = a.code and b.month between date_trunc('month', v_from) and v_to), 0) budget,
          abs(coalesce((select sum(mv.net) from private.movement(p_org, v_from, v_to) mv where mv.code = a.code), 0)) actual
        from private.acct_meta(p_org) a where a.statement = 'pl'
          and (exists (select 1 from budgets b where b.org_id = p_org and b.account_code = a.code and b.month between date_trunc('month', v_from) and v_to)
               or exists (select 1 from private.movement(p_org, v_from, v_to) mv where mv.code = a.code))) x;
    end if;

  elsif p_report = 'trends' then
    v_months := least(greatest(coalesce((p_options->>'months')::int, 12), 2), 36);
    select jsonb_agg(row order by mo) into v_rows from (
      select mo, (select jsonb_build_object('month', to_char(mo, 'Mon YYYY'), 'revenue', private.v(t, 'revenue'), 'gross_profit', private.v(t, 'gross_profit'),
          'gross_margin', private.pct(private.v(t, 'gross_profit'), private.v(t, 'revenue')), 'opex', private.v(t, 'opex'), 'profit', private.v(t, 'profit'),
          'cash', private.v(s, 'Cash and cash equivalents'), 'receivables', private.v(s, 'Trade and other receivables'), 'payables', private.v(s, 'Trade and other payables'),
          'inventories', private.v(s, 'Inventories'))
        from (select private.pl_totals(private.pl_map(p_org, mo, (mo + interval '1 month' - interval '1 day')::date)) t,
                     private.sofp_map(p_org, least((mo + interval '1 month' - interval '1 day')::date, v_to)) s) q) row
      from (select g::date mo from generate_series(date_trunc('month', v_to) - make_interval(months => v_months - 1), date_trunc('month', v_to), interval '1 month') g) gs) z;

  elsif p_report = 'cash_forecast' then
    v_rows := private.cash_forecast(p_org, v_to);

  elsif p_report = 'vat_return' then
    v_from := date_trunc('month', v_to)::date; v_to := (date_trunc('month', v_to) + interval '1 month' - interval '1 day')::date;
    v_rows := private.vat_rows(p_org, v_from, v_to);
    v_extra := v_extra || jsonb_build_object('from', v_from, 'to', v_to, 'due', (v_to + 21)::date);

  elsif p_report = 'wht_schedule' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('kind', 'Deducted from vendors (pay to NRS)', 'date', private.local_day(p_org, bp.paid_at), 'party', v.name, 'tin', v.tin,
        'individual', v.is_individual, 'category', (select name from wht_rates where code = b.wht_category), 'rate', b.wht_rate,
        'base', round(bp.wht / nullif(b.wht_rate, 0), 2), 'wht', bp.wht, 'document', b.number || coalesce(' · ' || b.vendor_ref, '')) x
      from bill_payments bp join bills b on b.id = bp.bill_id join vendors v on v.id = b.vendor_id
      where bp.org_id = p_org and bp.status = 'paid' and bp.wht > 0 and private.local_day(p_org, bp.paid_at) between v_from and v_to
      union all
      select jsonb_build_object('kind', 'Deducted by customers (credit to collect)', 'date', private.local_day(p_org, c2.received_at), 'party', cu.name, 'tin', cu.tin,
        'rate', c2.wht_rate, 'base', round(c2.amount / nullif(c2.wht_rate, 0), 2), 'wht', c2.amount,
        'document', (select string_agg(s.number, ', ') from collection_allocations a join sales s on s.id = a.sale_id where a.collection_id = c2.id))
      from collections c2 join customers cu on cu.id = c2.customer_id
      where c2.org_id = p_org and c2.method = 'wht_credit' and c2.status = 'confirmed' and private.local_day(p_org, c2.received_at) between v_from and v_to) t;
    v_extra := v_extra || jsonb_build_object('payable_balance', -coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '2202'), 0),
      'receivable_balance', coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '1401'), 0));

  elsif p_report = 'sales_analysis' then
    v_rows := private.sales_analysis(p_org, v_from, v_to, coalesce(nullif(p_options->>'by', ''), 'item'), private.can_see_costs(p_org));

  elsif p_report = 'kpis' then
    v_rows := jsonb_build_array(public.get_finance_overview(p_org));

  else
    raise exception 'Unknown report %.', p_report;
  end if;
  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'extra', v_extra);
end $function$;

-- private.pit_chain: a year filed outside Counta passes on the WHT credit given when it was marked, in place of Counta's (3a).
CREATE OR REPLACE FUNCTION private.pit_chain(p_org uuid, p_upto integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare y int; y0 int := least(private.pit_first_year(p_org), p_upto); bf jsonb := null; comp jsonb; py public.pit_years; v jsonb := '[]'::jsonb; v_has boolean;
begin
  for y in y0 .. p_upto loop
    select * into py from pit_years where org_id = p_org and accounting_year = y;
    v_has := private.cit_has_data(p_org, y);
    if not v_has and py.accounting_year is null and y < p_upto then
      v := v || jsonb_build_array(jsonb_build_object('year', y, 'yoa', y + 1, 'has_data', false));
      bf := null; continue;
    end if;
    if py.snapshot is not null and py.status = 'approved' then comp := py.snapshot->'computation';
    else comp := private.pit_compute(p_org, y, bf); end if;
    v := v || jsonb_build_array(comp || jsonb_build_object('has_data', v_has));
    bf := case when v_has or py.status = 'filed_outside' then comp->'cf' end;
    if py.status = 'filed_outside' and bf is not null and py.settings->'filed_outside' ? 'wht_credit' then
      bf := jsonb_set(bf, '{wht_used}', to_jsonb(round(coalesce(private.num(comp->'bf'->>'wht_used'), 0)
        + coalesce(private.num(py.settings->'filed_outside'->>'wht_credit'), 0), 2)));
    end if;
  end loop;
  return v;
end $function$;

-- private.cit_wht_pending: a year recorded as paid outside Counta used what that record cleared (3b).
CREATE OR REPLACE FUNCTION private.cit_wht_pending(p_org uuid, p_year integer, p_upto date, p_used jsonb)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select coalesce(round(sum(greatest(case when c.total > 0.004 or cy.tax_paid_at is not null or cy.paid_outside is not null then c.total else u.used end - c.by_upto, 0)), 2), 0)
  from (select key::int y, greatest(coalesce(private.num(value), 0), 0) used
        from jsonb_each_text(case when jsonb_typeof(p_used) = 'object' then p_used else '{}'::jsonb end)
        where key ~ '^[0-9]{4}$' and key::int < p_year) u
  left join cit_years cy on cy.org_id = p_org and cy.accounting_year = u.y
  cross join lateral (
    select coalesce(sum(l.credit - l.debit), 0) total, coalesce(sum(l.credit - l.debit) filter (where j.entry_date <= p_upto), 0) by_upto
    from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and split_part(l.account_code, '-', 1) = '1401' and l.doc_type = 'cit_wht:' || u.y) c
$function$;

-- private.post_tax_paid: a CIT payment clears only the WHT credit the year has not cleared already (3b).
CREATE OR REPLACE FUNCTION private.post_tax_paid(p_org uuid, p_tax text, p_period date, p_authority text, p_year integer, p_amount numeric, p_expected numeric, p_credit_code text, p_fee numeric, p_ref text, p_by uuid, p_source_id uuid, p_bank_account uuid, p_at timestamp with time zone, p_label text, p_payee text, p_breakdown jsonb)
 RETURNS journals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare j public.journals; m public.members; v_lines jsonb := '[]'::jsonb; v_amt numeric := round(p_amount, 2); v_left numeric; v_liab numeric; v_extra numeric;
  v_bal numeric; v_d numeric; c text; rm public.wht_remittances; e jsonb; b jsonb := p_breakdown; v_part numeric; v_credit numeric; v_dt numeric; v_dc numeric;
  v_remit numeric;
begin
  select * into m from members where id = p_by;
  e := private.tax_expected(p_org, p_tax, p_period, p_authority, p_year);
  -- The tax itself: what is left of the amount once Rev360's additions and Flutterwave's charge are taken out.
  v_part := case when b is null then v_amt
    else v_amt - (b->>'penalty')::numeric - (b->>'interest')::numeric - (b->>'late_filing_penalty')::numeric - (b->>'charges')::numeric end;
  if p_tax = 'cit' then
    -- What the books provided is cleared by the cash and the WHT credit notes Rev360 took off; the rest is the year's tax.
    v_credit := case when b is null then coalesce((e->>'credit')::numeric, 0) else (b->>'credit_applied')::numeric end;
    -- Recorded as paid outside Counta first: that record cleared part of the credit already.
    v_credit := greatest(v_credit - (select coalesce(sum(l.credit - l.debit), 0) from journal_lines l
      where l.org_id = p_org and split_part(l.account_code, '-', 1) = '1401' and l.doc_type = 'cit_wht:' || p_year), 0);
    v_left := v_part + v_credit;
    foreach c in array array['2208', '2209'] loop
      v_bal := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c), 0);
      v_d := least(v_left, v_bal);
      if v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', c, 'debit', v_d, 'memo', p_ref);
        v_left := v_left - v_d;
      end if;
    end loop;
    if v_left > 0.004 then v_lines := v_lines || jsonb_build_object('code', '7501', 'debit', v_left, 'memo', p_ref || ' · not provided for in the books'); end if;
    if v_credit > 0.004 then
      v_bal := greatest((select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401'), 0);
      v_d := least(v_credit, v_bal);
      if v_d > 0.004 then v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, 'wht_receivable'), 'credit', v_d, 'doc_type', 'cit_wht:' || p_year,
        'memo', 'WHT credit notes used · ' || p_ref); end if;
      if v_credit - v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', '3999', 'credit', v_credit - v_d, 'memo', 'WHT credit notes on Rev360 that the books did not have · ' || p_ref);
      end if;
    end if;
    v_remit := v_part;
  elsif b is null then
    v_liab := case when p_expected is null then v_amt else least(v_amt, round(p_expected, 2)) end;
    v_extra := v_amt - v_liab;
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, case p_tax when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
      'debit', v_liab, 'memo', p_ref);
    if v_extra > 0.004 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', v_extra, 'memo', 'Above the return: penalty or interest · ' || p_ref); end if;
    v_remit := v_liab;
  else
    -- The liability Counta holds for the return is cleared in full; where Rev360's tax or credit differs, the difference goes
    -- to its own account.
    v_liab := round(coalesce(p_expected, (e->>'amount')::numeric, v_part), 2);
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, case p_tax when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
      'debit', v_liab, 'memo', p_ref);
    v_dc := case when p_tax = 'vat' then (b->>'credit_applied')::numeric - coalesce((e->>'credit')::numeric, 0) else 0 end;
    v_dt := v_part - v_liab + v_dc;
    if v_dt > 0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'debit', v_dt, 'memo', 'Rev360 worked the tax out above the return · ' || p_ref);
    elsif v_dt < -0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'credit', -v_dt, 'memo', 'Rev360 worked the tax out below the return · ' || p_ref); end if;
    if v_dc > 0.004 then v_lines := v_lines || jsonb_build_object('code', '3999', 'credit', v_dc, 'memo', 'Input VAT credit on Rev360 that the books did not have · ' || p_ref);
    elsif v_dc < -0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'debit', -v_dc, 'memo', 'Input VAT credit Rev360 did not allow · ' || p_ref); end if;
    v_remit := v_part;
  end if;
  if b is not null then
    if (b->>'penalty')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'penalty', 'memo', 'Penalty charged by the NRS · ' || p_ref); end if;
    if (b->>'late_filing_penalty')::numeric > 0 then
      v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'late_filing_penalty', 'memo', 'Late filing penalty · ' || p_ref);
    end if;
    if (b->>'interest')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'interest', 'memo', 'Interest charged by the NRS · ' || p_ref); end if;
    if (b->>'charges')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6701', 'debit', b->'charges', 'memo', 'Flutterwave charge on the payment · ' || p_ref); end if;
  end if;
  if coalesce(p_fee, 0) > 0 then v_lines := v_lines || jsonb_build_object('code', '6701', 'debit', round(p_fee, 2), 'memo', 'Transfer fee'); end if;
  v_lines := v_lines || jsonb_build_object('code', p_credit_code, 'credit', v_amt + round(coalesce(p_fee, 0), 2), 'memo', p_ref || coalesce(' · ' || p_payee, ''));
  j := private.post_entry(p_org, p_label, 'tax_payment', p_source_id, m.id, m.id, v_lines, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', p_ref, 'authority', p_authority, 'by', m.display_name)
      || case when b is not null then jsonb_build_object('breakdown', b) else '{}'::jsonb end)));
  if p_tax = 'vat' then
    update vat_periods set status = 'paid', paid_at = p_at, payment_journal_id = j.id, reference = p_ref where org_id = p_org and period = p_period and status <> 'paid';
  elsif p_tax in ('wht', 'wvat') then
    insert into wht_remittances (org_id, kind, authority, period, amount, paid_at, bank_account_id, reference, journal_id, created_by)
    values (p_org, p_tax, p_authority, p_period, greatest(round(v_remit, 2), 0.01), p_at, p_bank_account, p_ref, j.id, p_by) returning * into rm;
    update wht_deductions set status = 'remitted', remittance_id = rm.id where org_id = p_org and authority = p_authority and period = p_period and status = 'deducted'
      and (kind = 'wht') = (p_tax = 'wht');
  elsif p_tax = 'cit' then
    update cit_years set tax_paid_at = p_at, tax_paid_amount = v_amt, tax_payment_ref = p_ref where org_id = p_org and accounting_year = p_year;
  end if;
  return j;
end $function$;

-- public.cit_year: the row says whether the tax was paid through Counta or recorded as paid outside it (3b).
CREATE OR REPLACE FUNCTION public.cit_year(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; comp jsonb; p record;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.cit_run(p_org, p_year);
  return jsonb_build_object('computation', comp,
    'row', jsonb_build_object('status', coalesce(cy.status, 'draft'), 'source', comp->>'source', 'settings', coalesce(cy.settings, '{}'::jsonb),
      'adjustments', coalesce(cy.adjustments, '{}'::jsonb), 'overrides', coalesce(cy.overrides, '{}'::jsonb), 'imported', coalesce(cy.imported, '{}'::jsonb),
      'imported_from', cy.imported_from, 'afs_path', cy.afs_path, 'template_path', cy.template_path, 'approved_at', cy.approved_at,
      'approved_by', (select display_name from members where id = cy.approved_by), 'flux_status', cy.flux_status, 'flux_ref', cy.flux_ref,
      'flux_message', cy.flux_message, 'flux_sent_at', cy.flux_sent_at, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'rev360_computation', cy.rev360_computation, 'updated_at', cy.updated_at,
      'tax_paid_at', cy.tax_paid_at, 'tax_paid_amount', cy.tax_paid_amount, 'paid_outside', cy.paid_outside),
    'lines', (select jsonb_agg(jsonb_build_object('cell', l.cell, 'sheet', l.sheet, 'addr', l.addr, 'section', l.section, 'label', l.label, 'note', l.note,
        'codes', l.codes, 'positive_only', l.positive_only, 'config_id', l.config_id,
        'amount', coalesce((comp->'cells'->>l.cell)::numeric, (comp->'adjustments'->>l.cell)::numeric, 0),
        'detail', comp->'detail'->l.cell, 'items', comp->'items'->l.cell,
        'source', case when l.sheet = 'PROFIT_ADJUSTMENT' then 'adjustment' when cy.overrides ? l.cell then 'override'
                       when comp->>'source' = 'imported' then coalesce(cy.imported->l.cell->>'source', 'imported') else 'books' end,
        'imported', cy.imported->l.cell, 'override', cy.overrides->l.cell) order by l.sort) from cit_template_lines l),
    'declaration', private.cit_declaration(p_org, comp),
    'tax_assets', (select coalesce(jsonb_agg(to_jsonb(t) order by t.in_use_from, t.name), '[]'::jsonb) from tax_assets t where t.org_id = p_org),
    'can_edit', private.perm_of(m, 'keep_books') and coalesce(cy.status, 'draft') in ('draft', 'rejected'),
    'can_approve', private.perm_of(m, 'keep_books') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_adjustments')),
    'period', jsonb_build_object('from', p.pfrom, 'to', p.pto));
end $function$;

-- ---------------------------------------------------------------------------
-- 5. Search paths and foreign key indexes (Supabase advisors)
-- ---------------------------------------------------------------------------
alter function private.kyc_missing(jsonb) set search_path = public, private;
alter function private.partner_defaults() set search_path = public, private;
alter function private.partner_new_ref() set search_path = public, private;
alter function private.plan_price(public.plans, text) set search_path = public, private;
alter function private.secret_catalog() set search_path = public, private;
alter function private.words_and(text[]) set search_path = public, private;
alter function private.hs_code(text) set search_path = public, private;
alter function private.nrs_irn(text, text, date) set search_path = public, private;
alter function private.feature_keys() set search_path = public, private;
alter function private.plan_fmt(numeric) set search_path = public, private;
alter function private.ai_read_kinds() set search_path = public, private;
alter function private.ai_assistant_kinds() set search_path = public, private;
alter function private.month_start() set search_path = public, private;
alter function private.audit_defaults() set search_path = public, private;
alter function private.audit_naira(numeric) set search_path = public, private;
alter function private.audit_can_act(public.members) set search_path = public, private;

create index if not exists einvoice_docs_issued_by on public.einvoice_docs(issued_by) where issued_by is not null;
create index if not exists lookup_failures_user on public.lookup_failures(user_id) where user_id is not null;
create index if not exists portal_logins_authority on public.portal_logins(authority);
create index if not exists portal_logins_saved_by on public.portal_logins(saved_by) where saved_by is not null;
create index if not exists recurring_invoices_created_by on public.recurring_invoices(created_by) where created_by is not null;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.pit_wht_post(uuid, integer, jsonb, public.members, numeric, timestamptz), private.wht_held_now(uuid),
  private.wht_credit_given(jsonb), private.noon_open(uuid, date) from public, anon, authenticated;
revoke all on function public.mark_pit_filed(uuid, integer, jsonb), public.record_cit_paid_outside(uuid, integer, jsonb) from public, anon;
grant execute on function public.mark_pit_filed(uuid, integer, jsonb), public.record_cit_paid_outside(uuid, integer, jsonb) to authenticated;
revoke all on function public.svc_audit_poll_now() from public, anon, authenticated;
grant execute on function public.svc_audit_poll_now() to service_role;
