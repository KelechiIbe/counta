-- Withholding tax credits (WHT customers deducted, account 1401) set against income tax once, and out of the books once used.
--
-- 1. Companies income tax. A year's computation sets the 1401 balance at its year end against CIT and the minimum-tax top-up.
--    The books clear what a year used when its tax payment is recorded, so a year whose tax was not recorded as paid by the
--    next year end left its credits in that balance, and the next year used them again (two years filed together, or a year
--    paid late). Now each year takes off the credits earlier years used that the books still held at its year end
--    (private.cit_wht_pending): an earlier year's credit counts as used when the year's payment cleared it from 1401 (what
--    the payment cleared, which is what Rev360 applied), or, while its payment is not recorded, as its computation used it.
--    The year chain (private.cit_run, private.cit_chain) passes each year's credit to the years after it, across years
--    without figures too. The payment tags the 1401 line it clears with its year (doc_type 'cit_wht:<year>'). A year
--    prepared from imported statements keeps the WHT figure in those statements.
-- 2. Personal income tax. The computation already took off the credits earlier years used. Nothing left the books, though:
--    1401 kept credits that had been set against the owner's or the partners' tax. Approving a year's return now moves the
--    credit it uses out of 1401 to retained earnings (where Counta keeps the owner's drawings), one line for each person's
--    share, tagged 'pit_wht:<year>' (private.pit_wht_post); reopening the return reverses it. The computation then takes off
--    only the credits earlier years used that the books still held at its year end, as for CIT. A year prepared from
--    imported statements posts nothing.
-- 3. Personal income tax for 2024 accounts. Release 5 opened the 2024 return, but its two tables still took years from 2025
--    only, so saving or approving a 2024 return failed. They take 2024 now.
--
-- No production return is approved yet and no credit has been cleared, so nothing already filed changes.

-- ---------------------------------------------------------------------------
-- 0. PIT tables take 2024 accounts
-- ---------------------------------------------------------------------------
alter table public.pit_years drop constraint if exists pit_years_accounting_year_check,
  add constraint pit_years_accounting_year_check check (accounting_year >= 2024 and accounting_year <= 2100);
alter table public.pit_person_years drop constraint if exists pit_person_years_accounting_year_check,
  add constraint pit_person_years_accounting_year_check check (accounting_year >= 2024 and accounting_year <= 2100);

-- ---------------------------------------------------------------------------
-- 1. What the books cleared, and what earlier years still hold
-- ---------------------------------------------------------------------------
-- WHT credits cleared from 1401 for earlier years' income tax (p_kind 'cit' or 'pit'), on or before p_upto: the 1401 lines
-- tagged '<kind>_wht:<year>' for years before p_before_year, net of any reversal (a reversal carries the same tag).
create or replace function private.wht_cleared(p_org uuid, p_kind text, p_before_year int, p_upto date) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(l.credit - l.debit), 0)
  from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and split_part(l.account_code, '-', 1) = '1401'
    and l.doc_type ~ ('^' || p_kind || '_wht:[0-9]{4}$') and split_part(l.doc_type, ':', 2)::int < p_before_year
    and j.entry_date <= p_upto
$$;

-- CIT: credits earlier years set against their tax that 1401 still holds at p_upto. p_used: {"<year>": credit used} from
-- the year chain. A year whose tax payment is recorded used what the payment cleared (Rev360's figure); otherwise what its
-- computation used. Only years before p_year count.
create or replace function private.cit_wht_pending(p_org uuid, p_year int, p_upto date, p_used jsonb) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(round(sum(greatest(case when c.total > 0.004 or cy.tax_paid_at is not null then c.total else u.used end - c.by_upto, 0)), 2), 0)
  from (select key::int y, greatest(coalesce(private.num(value), 0), 0) used
        from jsonb_each_text(case when jsonb_typeof(p_used) = 'object' then p_used else '{}'::jsonb end)
        where key ~ '^[0-9]{4}$' and key::int < p_year) u
  left join cit_years cy on cy.org_id = p_org and cy.accounting_year = u.y
  cross join lateral (
    select coalesce(sum(l.credit - l.debit), 0) total, coalesce(sum(l.credit - l.debit) filter (where j.entry_date <= p_upto), 0) by_upto
    from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and split_part(l.account_code, '-', 1) = '1401' and l.doc_type = 'cit_wht:' || u.y) c
$$;

-- What the CIT year chain hands the next year: last year's carry-forward, with the credit each earlier year used. A year
-- after a gap has no carry-forward (no "losses" key) and still gets the credits.
create or replace function private.cit_bf(p_cf jsonb, p_used jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when p_used is null or p_used = '{}'::jsonb then p_cf else coalesce(p_cf, '{}'::jsonb) || jsonb_build_object('wht_years', p_used) end
$$;

-- The credit a year's computation used, added to the chain's record.
create or replace function private.cit_wht_note(p_used jsonb, p_comp jsonb) returns jsonb
language sql stable set search_path = public, private as $$
  select case when coalesce(private.num(p_comp->'figures'->>'wht_credit'), 0) > 0
    then coalesce(p_used, '{}'::jsonb) || jsonb_build_object(p_comp->>'year', round(private.num(p_comp->'figures'->>'wht_credit'), 2))
    else coalesce(p_used, '{}'::jsonb) end
$$;

-- ---------------------------------------------------------------------------
-- 2. PIT: the credit an approved return uses leaves the books
-- ---------------------------------------------------------------------------
-- Dr retained earnings (the owner's drawings, or each partner's share), Cr 1401 tagged 'pit_wht:<year>', dated today. No
-- more than 1401 holds. Names stay out of the ledger: a partner's line gives the share. Returns the journal, or null when
-- there is nothing to move (no credit used, or figures from imported statements).
create or replace function private.pit_wht_post(p_org uuid, p_year int, p_comp jsonb, m public.members) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_used numeric; v_bal numeric; v_post numeric; v_left numeric; v_amt numeric; v_n int; i int := 0; x jsonb; v_lines jsonb := '[]'::jsonb;
  v_sole boolean := p_comp->>'kind' = 'sole'; j public.journals;
begin
  if coalesce(p_comp->'business'->>'source', 'books') = 'imported' then return null; end if;
  v_used := round(coalesce(private.num(p_comp->'figures'->>'wht_credit_used'), 0), 2);
  if v_used <= 0.004 then return null; end if;
  v_bal := greatest((select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401'), 0);
  v_post := least(v_used, round(v_bal, 2));
  if v_post <= 0.004 then return null; end if;
  select count(*) from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p
    where coalesce(private.num(p->'computation'->'figures'->>'wht_credit'), 0) > 0 into v_n;
  v_left := v_post;
  for x in select p from jsonb_array_elements(coalesce(p_comp->'people', '[]'::jsonb)) p
           where coalesce(private.num(p->'computation'->'figures'->>'wht_credit'), 0) > 0 loop
    i := i + 1;
    v_amt := case when i = v_n then v_left else round(private.num(x->'computation'->'figures'->>'wht_credit') * v_post / v_used, 2) end;
    v_left := v_left - v_amt;
    if v_amt > 0.004 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'retained_earnings'), 'debit', v_amt,
        'memo', case when v_sole then 'WHT credit set against the owner''s ' || p_year || ' income tax'
          else 'WHT credit set against a partner''s ' || p_year || ' income tax (' || rtrim(to_char(private.num(x->>'share_pct'), 'FM990.99'), '.') || '% share)' end));
    end if;
  end loop;
  v_lines := v_lines || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'wht_receivable'), 'credit', v_post, 'doc_type', 'pit_wht:' || p_year,
    'memo', 'WHT credit notes used against the ' || p_year || ' income tax'));
  j := private.post_entry(p_org, 'WHT credit notes used against the ' || p_year || ' income tax', 'pit_year', null, m.id, m.id, v_lines, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'pit_return', 'year', p_year, 'by', m.display_name))));
  return j.id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Existing functions, each with the change named above it
-- ---------------------------------------------------------------------------

-- private.cit_compute: credits earlier years used that 1401 still holds at the year end are not used again (books only). A carry-forward with no "losses" (a year after a gap, given only the credits) opens like a first year.
CREATE OR REPLACE FUNCTION private.cit_compute(p_org uuid, p_year integer, p_bf jsonb DEFAULT NULL::jsonb, p_as_of date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; cy public.cit_years; rbr public.tax_rulebooks; rb jsonb; v_yoa int := p_year + 1; v_from date; v_to date; v_upto date;
  v_source text; bk jsonb; cells jsonb := '{}'::jsonb; det jsonb := '{}'::jsonb; codes jsonb := '{}'::jsonb; t jsonb; x record; k text; v_amt numeric;
  st jsonb; adj jsonb; prof jsonb; ca jsonb; items jsonb := '{}'::jsonb; pa jsonb := '{}'::jsonb; v_auto jsonb; i int;
  v_pbt numeric; v_turn numeric; v_fii numeric; v_fixed numeric; v_dep numeric; v_amort numeric; v_int numeric; v_ebitda numeric; v_conn numeric;
  v_cap_pct numeric; v_excess numeric := 0; v_capacity numeric := 0; v_relief numeric := 0; v_int_bf jsonb; v_int_cf jsonb := '[]'::jsonb; v_avail numeric;
  v_use numeric; v_don numeric; v_don_listed numeric; v_don_cap numeric; v_don_base numeric; v_don_out numeric; v_b numeric; v_c numeric; v_d numeric;
  v_loss_bf numeric; v_ca_bf numeric; v_e1 numeric; v_rem numeric; v_ca_avail numeric; v_e2 numeric; v_f numeric; v_g numeric; v_h numeric; v_lev numeric := 0;
  v_j numeric := 0; v_k numeric; v_class text; v_rate numeric; v_small boolean; v_company boolean; v_nonres boolean; v_etr boolean; v_ni numeric; v_cov numeric;
  v_ap numeric; v_bc numeric; v_cap numeric; v_restricted boolean; v_mt numeric := 0; v_mt_applies boolean := false; v_mt_used boolean := false; v_tet numeric := 0;
  v_tet_rate numeric; v_wht numeric; v_wht_used numeric; v_wht_pending numeric := 0; v_loss_new numeric; v_loss_cf numeric; v_ca_cf numeric; v_legacy boolean; v_rows jsonb := '[]'::jsonb;
  v_checks jsonb := '[]'::jsonb; v_flags jsonb; v_lev_base numeric; v_gain_inv numeric; v_gains_other numeric; v_loss_vs_gains numeric := 0; v_ntax numeric;
  v_short numeric := 1; v_first_open boolean; v_comm date; v_years_in int; v_exempt_sector boolean; v_manu numeric; v_sum numeric; v_others jsonb := '[]'::jsonb;
  v_books_pbt numeric; v_ended boolean; v_cell text; v_imp jsonb; v_ovr jsonb; v_cit_payable numeric; v_ca_used_detail jsonb; v_dlevy_applies boolean;
begin
  select * into o from orgs where id = p_org;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into v_from, v_to from private.cit_period(p_org, p_year);
  v_upto := least(coalesce(p_as_of, v_to), v_to);
  v_ended := private.local_day(p_org, now()) > v_to;
  rbr := private.rulebook(v_yoa); rb := rbr.config;
  v_legacy := rbr.regime = 'LEGACY_CITA';
  v_flags := coalesce(rb->'configurable_flags'->'flags', '{}'::jsonb);
  st := coalesce(cy.settings, '{}'::jsonb);
  adj := coalesce(cy.adjustments, '{}'::jsonb);
  prof := coalesce(o.cit_profile, '{}'::jsonb);
  v_source := coalesce(cy.source, private.cit_default_source(p_org, v_from, v_to));

  -- Figures: from the books (with any lines the business changed), or from audited accounts / a trial balance mapped onto the template.
  if v_source = 'books' then
    bk := private.cit_books_figures(p_org, v_from, v_upto);
    cells := bk->'cells'; det := bk->'detail'; codes := bk->'codes';
    v_books_pbt := (private.cit_totals(cells)->>'profit_before_tax')::numeric;
    for x in select key, value from jsonb_each(coalesce(cy.overrides, '{}'::jsonb)) loop
      cells := case when coalesce((x.value->>'amount')::numeric, 0) = 0 then cells - x.key else jsonb_set(cells, array[x.key], to_jsonb(round((x.value->>'amount')::numeric, 2))) end;
    end loop;
  else
    for x in select key, value from jsonb_each(coalesce(cy.imported, '{}'::jsonb)) where key not like 'PROFIT_ADJUSTMENT!%' and key <> 'INCOME_STATEMENT!D113' loop
      if coalesce((x.value->>'amount')::numeric, 0) <> 0 then cells := jsonb_set(cells, array[x.key], to_jsonb(round((x.value->>'amount')::numeric, 2))); end if;
    end loop;
  end if;
  cells := cells - 'INCOME_STATEMENT!D113';
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cells from jsonb_each(cells) where key not like 'PROFIT_ADJUSTMENT!%';
  t := private.cit_totals(cells);
  v_pbt := round((t->>'profit_before_tax')::numeric, 2);
  v_turn := round((t->>'revenue')::numeric, 2);
  v_fii := private.v(cells, 'OTHER_INCOME!D8');
  v_fixed := private.v(t, 'ppe') + private.v(t, 'intangibles');
  v_dep := private.v(t, 'depreciation'); v_amort := private.v(t, 'amortisation'); v_int := private.v(t, 'interest_expense');
  v_company := private.income_tax_kind(p_org) = 'company';
  v_nonres := coalesce((prof->>'non_resident')::boolean, false);
  v_ntax := case when v_turn + private.v(t, 'other_income') > 0 then private.v(cells, 'OTHER_INCOME!D12') / (v_turn + private.v(t, 'other_income')) else 0 end;
  v_comm := coalesce(o.commenced_on, o.incorporation_date);
  if v_comm is not null and v_comm > v_from and v_comm <= v_to then v_short := round(((v_to - v_comm + 1)::numeric / 365), 6); end if;

  -- Amounts brought forward: from the previous year's computation, or this year's own settings when it opens the chain
  -- (or when the business has replaced them, with a reason).
  v_first_open := p_bf is null or not (p_bf ? 'losses') or coalesce((st->>'bf_override')::boolean, false);
  v_loss_bf := round(case when v_first_open then coalesce((st->>'losses_bf')::numeric, 0) else coalesce((p_bf->>'losses')::numeric, 0) end, 2);
  v_ca_bf := round(case when v_first_open then coalesce((st->>'ca_bf')::numeric, 0) else coalesce((p_bf->>'ca')::numeric, 0) end, 2);
  v_int_bf := case when v_first_open then coalesce(st->'interest_bf', '[]'::jsonb) else coalesce(p_bf->'interest', '[]'::jsonb) end;

  -- Capital allowances.
  ca := private.cit_ca(p_org, p_year, jsonb_build_object('nontax_share', v_ntax, 'short_factor', v_short,
    'opening_year', case when v_first_open and st ? 'opening_twdv' then p_year end, 'opening_twdv', coalesce(st->'opening_twdv', '{}'::jsonb)));

  -- Interest to connected persons above 30% of EBITDA is added back and carried forward up to five years.
  v_cap_pct := coalesce(private.rbn(rb, 'interest_restriction', 'ebitda_cap_pct'), 0.30);
  v_ebitda := v_pbt + v_int + v_dep + v_amort;
  v_conn := coalesce((st->>'connected_interest')::numeric, 0);
  if coalesce((prof->>'bank_or_insurer_subsidiary')::boolean, false) then v_conn := 0; end if;
  v_excess := round(greatest(v_conn - v_cap_pct * greatest(v_ebitda, 0), 0), 2);
  v_capacity := round(greatest(v_cap_pct * greatest(v_ebitda, 0) - v_conn, 0), 2);
  v_avail := v_capacity;
  for x in select value from jsonb_array_elements(v_int_bf) order by (value->>'yoa')::int loop
    continue when (x.value->>'yoa')::int < v_yoa - coalesce(private.rbn(rb, 'interest_restriction', 'carry_forward_years'), 5)::int;
    v_use := least(v_avail, coalesce((x.value->>'amount')::numeric, 0));
    v_relief := v_relief + v_use; v_avail := v_avail - v_use;
    if coalesce((x.value->>'amount')::numeric, 0) - v_use > 0 then
      v_int_cf := v_int_cf || jsonb_build_array(jsonb_build_object('yoa', (x.value->>'yoa')::int, 'amount', round((x.value->>'amount')::numeric - v_use, 2)));
    end if;
  end loop;
  if v_excess > 0 then v_int_cf := v_int_cf || jsonb_build_array(jsonb_build_object('yoa', v_yoa, 'amount', v_excess)); end if;

  -- Profit adjustments, row by row (PROFIT_ADJUSTMENT rows 14-32 add back, 36-40 deduct). Automatic rows come from named
  -- accounts in the books or named lines in the template; the business adds its own with reasons, or replaces a row.
  v_auto := '{}'::jsonb;
  if private.v(codes, '6704') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D16}', jsonb_build_array(private.cit_item('Unrealised foreign exchange losses (account 6704)', private.v(codes, '6704'), 'Deductible when realised'))); end if;
  if private.v(cells, 'ADMINISTRATIVE_EXPENSES!C29') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D17}', jsonb_build_array(private.cit_item('Loss on disposal of fixed assets', private.v(cells, 'ADMINISTRATIVE_EXPENSES!C29'),
    case when v_legacy then 'Capital allowance schedule gives the balancing allowance instead' else 'Capital: the disposal is dealt with in the capital allowance schedule and chargeable gains' end))); end if;
  if private.v(codes, '6803') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D20}', jsonb_build_array(private.cit_item('Impairment of non-current assets (account 6803)', private.v(codes, '6803'), 'Capital in nature'))); end if;
  if private.v(codes, '6802') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D25}', jsonb_build_array(private.cit_item('General provision for doubtful debts (expected credit loss charge, account 6802)', private.v(codes, '6802'),
    'Only specific debts written off are deductible'))); end if;
  if private.v(cells, 'ADMINISTRATIVE_EXPENSES!C57') + private.v(cells, 'ADMINISTRATIVE_EXPENSES!C58') > 0 then
    v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D29}', jsonb_build_array(private.cit_item('Fines and penalties', private.v(cells, 'ADMINISTRATIVE_EXPENSES!C57') + private.v(cells, 'ADMINISTRATIVE_EXPENSES!C58'), 'Never deductible'))); end if;
  v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', '[]'::jsonb);
  if v_amort > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', (v_auto->'PROFIT_ADJUSTMENT!D32') || jsonb_build_array(private.cit_item('Amortisation of intangible assets',
    v_amort, 'The template adds back depreciation only; capital allowances are given instead'))); end if;
  if v_excess > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', (v_auto->'PROFIT_ADJUSTMENT!D32') || jsonb_build_array(private.cit_item('Interest to connected persons above 30% of EBITDA',
    v_excess, private.naira(v_conn) || ' paid; limit ' || private.naira(round(v_cap_pct * greatest(v_ebitda, 0), 2)) || ' (30% of EBITDA of ' || private.naira(round(v_ebitda, 2)) || ')'))); end if;
  if private.v(cells, 'OTHER_INCOME!D12') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D36}', jsonb_build_array(private.cit_item('Non-taxable revenue', private.v(cells, 'OTHER_INCOME!D12'), 'Exempt income'))); end if;
  if private.v(cells, 'OTHER_INCOME!D11') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D37}', jsonb_build_array(private.cit_item('Profit on disposal of fixed assets', private.v(cells, 'OTHER_INCOME!D11'),
    case when v_legacy then 'Any gain is for the capital gains tax return' else 'Dealt with as a chargeable gain' end))); end if;
  if v_fii > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D38}', jsonb_build_array(private.cit_item('Franked investment income (dividends received)', v_fii, 'Taxed at source'))); end if;
  v_amt := private.v(cells, 'OTHER_INCOME!D14') + greatest(private.v(codes, '4515') * -1, 0);
  if v_amt > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D39}', jsonb_build_array(private.cit_item('Unrealised exchange and fair value gains', v_amt, 'Taxed when realised'))); end if;
  v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', '[]'::jsonb);
  if private.v(cells, 'OTHER_INCOME!D10') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Provisions written back',
    private.v(cells, 'OTHER_INCOME!D10'), 'The provision was not allowed when it was made'))); end if;
  v_gain_inv := private.v(cells, 'OTHER_INCOME!D9');
  if v_gain_inv > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Gain on disposal of investments',
    v_gain_inv, case when v_legacy then 'Capital gains tax, not CIT' else 'Dealt with as a chargeable gain' end))); end if;
  if v_relief > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Interest disallowed in earlier years, now within the 30% limit',
    v_relief, 'Third Schedule carry forward'))); end if;

  -- Rows: automatic items, then the business's own, unless the business replaced the row or audited accounts gave it.
  for x in select l.cell from cit_template_lines l where l.sheet = 'PROFIT_ADJUSTMENT' order by l.sort loop
    v_imp := case when v_source = 'imported' then cy.imported->x.cell end;
    v_ovr := adj->x.cell->'override';
    if x.cell = 'PROFIT_ADJUSTMENT!D23' then
      items := jsonb_set(items, array[x.cell], '[]'::jsonb);     -- the template starts from profit before tax: the tax charge is never added back
      continue;
    end if;
    if v_ovr is not null and v_ovr ? 'amount' then
      items := jsonb_set(items, array[x.cell], jsonb_build_array(private.cit_item(coalesce(v_ovr->>'label', 'Set by the business'), (v_ovr->>'amount')::numeric, coalesce(v_ovr->>'reason', ''), false)));
    elsif v_imp is not null and coalesce((v_imp->>'amount')::numeric, 0) <> 0 then
      items := jsonb_set(items, array[x.cell], jsonb_build_array(private.cit_item(coalesce(v_imp->>'note', 'From the tax computation imported'), (v_imp->>'amount')::numeric, 'Imported', false)));
    else
      items := jsonb_set(items, array[x.cell], coalesce(v_auto->x.cell, '[]'::jsonb));
    end if;
    for i in 0 .. coalesce(jsonb_array_length(adj->x.cell->'items'), 0) - 1 loop
      if coalesce((adj->x.cell->'items'->i->>'amount')::numeric, 0) > 0 then
        items := jsonb_set(items, array[x.cell], (items->x.cell) || jsonb_build_array(private.cit_item(adj->x.cell->'items'->i->>'label',
          (adj->x.cell->'items'->i->>'amount')::numeric, coalesce(adj->x.cell->'items'->i->>'reason', ''), false)));
      end if;
    end loop;
  end loop;

  -- Donations: allowed up to the cap of profit before the donation, and only to listed bodies; the rest is added back.
  v_don := private.v(cells, 'ADMINISTRATIVE_EXPENSES!C22');
  if v_don > 0 and not coalesce(adj->'PROFIT_ADJUSTMENT!D15' ? 'override', false) and not coalesce(v_source = 'imported' and cy.imported ? 'PROFIT_ADJUSTMENT!D15', false) then
    v_don_listed := greatest(v_don - coalesce((st->>'donations_unlisted')::numeric, 0), 0);
    select coalesce(sum((it->>'amount')::numeric), 0) into v_b from jsonb_each(items) e(c, arr), jsonb_array_elements(e.arr) it
      where e.c <> 'PROFIT_ADJUSTMENT!D15' and e.c between 'PROFIT_ADJUSTMENT!D14' and 'PROFIT_ADJUSTMENT!D32' and length(e.c) = length('PROFIT_ADJUSTMENT!D14');
    select coalesce(sum((it->>'amount')::numeric), 0) into v_c from jsonb_each(items) e(c, arr), jsonb_array_elements(e.arr) it
      where e.c in ('PROFIT_ADJUSTMENT!D36', 'PROFIT_ADJUSTMENT!D37', 'PROFIT_ADJUSTMENT!D38', 'PROFIT_ADJUSTMENT!D39', 'PROFIT_ADJUSTMENT!D40');
    v_don_base := greatest(v_pbt + v_dep + v_b - v_c + v_don, 0);
    v_don_cap := round(v_don_base * coalesce(case when v_legacy then private.rbn(rb, 'add_backs', 'donations', 'cap_pct') end, private.tax_rule('donations_cap', v_to), 0.10), 2);
    v_don_out := round(v_don - least(v_don_listed, v_don_cap), 2);
    if v_don_out > 0 then
      items := jsonb_set(items, '{PROFIT_ADJUSTMENT!D15}', jsonb_build_array(private.cit_item('Donations above the deductible limit', v_don_out,
        private.naira(v_don) || ' given; ' || private.naira(least(v_don_listed, v_don_cap)) || ' allowed (10% of ' || private.naira(v_don_base) || ' profit before donations'
        || case when v_don_listed < v_don then ', listed bodies only' else '' end || ')')) || (items->'PROFIT_ADJUSTMENT!D15'));
    end if;
  end if;

  for x in select l.cell from cit_template_lines l where l.sheet = 'PROFIT_ADJUSTMENT' loop
    select coalesce(sum((it->>'amount')::numeric), 0) into v_amt from jsonb_array_elements(coalesce(items->x.cell, '[]'::jsonb)) it;
    if v_amt <> 0 then pa := jsonb_set(pa, array[x.cell], to_jsonb(round(v_amt, 2))); end if;
  end loop;
  -- Expenses relating to non-taxable revenue (the template insists on them whenever non-taxable revenue is declared).
  if private.v(cells, 'OTHER_INCOME!D12') > 0 and private.v(pa, 'PROFIT_ADJUSTMENT!D14') + private.v(pa, 'PROFIT_ADJUSTMENT!D27') > 0 then
    cells := jsonb_set(cells, '{INCOME_STATEMENT!D113}', to_jsonb(private.v(pa, 'PROFIT_ADJUSTMENT!D14') + private.v(pa, 'PROFIT_ADJUSTMENT!D27')));
  end if;
  v_b := round(v_dep + (select coalesce(sum(value::numeric), 0) from jsonb_each_text(pa) where key between 'PROFIT_ADJUSTMENT!D14' and 'PROFIT_ADJUSTMENT!D32'
                        and length(key) = length('PROFIT_ADJUSTMENT!D14')), 2);
  v_c := round((select coalesce(sum(value::numeric), 0) from jsonb_each_text(pa) where key in ('PROFIT_ADJUSTMENT!D36', 'PROFIT_ADJUSTMENT!D37', 'PROFIT_ADJUSTMENT!D38',
                 'PROFIT_ADJUSTMENT!D39', 'PROFIT_ADJUSTMENT!D40')), 2);
  v_d := round(v_pbt + v_b - v_c, 2);

  -- Chargeable gains (NTA: in total profits at the CIT rate; old law: a separate capital gains tax return).
  v_gains_other := coalesce((st->>'chargeable_gains_other')::numeric, 0);
  v_f := case when v_legacy then 0 else greatest(private.v(ca->'totals', 'gains') - private.v(ca->'totals', 'losses') + v_gain_inv + v_gains_other, 0) end;
  v_bc := private.v(ca->'totals', 'balancing_charge');

  if v_legacy then
    -- Old law: CIT by size, minimum tax, tertiary education tax on assessable profit.
    v_class := case when v_turn <= coalesce(private.rbn(rb, 'company_classification', 'classes', 'SMALL', 'turnover_max_ngn'), 25000000) then 'SMALL'
                    when v_turn < coalesce(private.rbn(rb, 'company_classification', 'classes', 'LARGE', 'turnover_min_ngn'), 100000000) then 'MEDIUM' else 'LARGE' end;
    v_small := v_class = 'SMALL';
    v_rate := coalesce(private.rbn(rb, 'cit_rates', 'by_class', v_class), 0.30);
    v_ap := v_d + v_bc;
    v_e1 := least(v_loss_bf, greatest(v_ap, 0));
    v_rem := greatest(v_ap, 0) - v_e1;
    select coalesce(sum(case when l.addr in ('D7', 'D8') then private.v(cells, l.cell) end), 0), coalesce(sum(private.v(cells, l.cell)), 0) into v_manu, v_sum
      from cit_template_lines l where l.section = 'revenue';
    v_exempt_sector := o.industry in ('manufacturing', 'agro') or (v_sum > 0 and v_manu / v_sum >= 0.5);
    v_restricted := not v_exempt_sector;
    v_cap := case when v_restricted then round(greatest(v_ap, 0) * 2 / 3, 2) end;
    v_ca_avail := round(private.v(ca->'totals', 'allowance') + private.v(ca->'totals', 'investment') + private.v(ca->'totals', 'balancing_allowance') + v_ca_bf, 2);
    v_e2 := least(v_ca_avail, coalesce(v_cap, v_ca_avail), v_rem);
    v_g := greatest(v_ap - v_e1 - v_e2, 0);
    v_h := case when v_company then round(v_g * v_rate, 2) else 0 end;
    v_years_in := case when v_comm is not null then p_year - extract(year from v_comm)::int else 99 end;
    v_mt_applies := v_company and not v_small and v_years_in >= 4 and coalesce(o.industry, '') <> 'agro' and not coalesce((prof->>'agricultural_trade')::boolean, false)
                    and not coalesce((prof->>'imported_equity_25')::boolean, false);
    v_mt := case when v_mt_applies then round(greatest(v_turn - v_fii, 0) * coalesce(private.rbn(rb, 'minimum_tax', 'rate'), 0.005), 2) else 0 end;
    v_mt_used := v_mt_applies and v_mt > v_h;
    v_cit_payable := case when v_mt_used then v_mt else v_h end;
    v_tet_rate := coalesce(private.rbn(rb, 'tertiary_education_tax', 'rate_by_yoa', v_yoa::text), 0.03);
    v_tet := case when v_company and not (v_small and coalesce(private.rbb(rb, 'tertiary_education_tax', 'exempt_small_companies'), true)) then round(greatest(v_ap, 0) * v_tet_rate, 2) else 0 end;
    v_lev := v_tet;
    v_k := v_cit_payable + v_tet;
    v_loss_new := greatest(-v_ap, 0);
  else
    -- NTA 2025: classification, CIT on total profits, development levy on assessable profit, 15% minimum effective tax.
    -- Small (s.202): turnover and fixed assets alone. A company providing professional services is classified like any other
    -- here; the rule that it is never small applies to VAT only.
    v_small := v_turn <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_turnover_max_ngn'), 100000000)
               and v_fixed <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_fixed_assets_max_ngn'), 250000000);
    v_class := case when v_nonres then 'NON_RESIDENT' when v_small then 'SMALL' else 'REGULAR' end;
    v_rate := coalesce(private.rbn(rb, 'cit_rates', 'by_class', v_class), case when v_small then 0 else 0.30 end);
    v_ap := v_d + v_bc;
    v_e1 := least(v_loss_bf, greatest(v_ap, 0));
    v_rem := greatest(v_ap, 0) - v_e1;
    v_ca_avail := round(private.v(ca->'totals', 'allowance') + private.v(ca->'totals', 'balancing_allowance') + private.v(ca->'totals', 'residue_on_disposal') + v_ca_bf, 2);
    v_e2 := least(v_ca_avail, v_rem);
    v_loss_vs_gains := case when v_ap < 0 then least(-v_ap, v_f) else 0 end;
    v_g := greatest(v_ap - v_e1 - v_e2 + v_f, 0);
    v_h := case when v_company and not v_nonres then round(v_g * v_rate, 2) else 0 end;
    v_dlevy_applies := v_company and v_class = 'REGULAR' and not coalesce((prof->>'hydrocarbon')::boolean, false);
    v_lev_base := case when coalesce((v_flags->'development_levy_base_before_capital_allowances'->>'default')::boolean, true) then greatest(v_ap, 0)
                       else greatest(v_ap - v_e1 - v_e2, 0) end
                + case when coalesce((v_flags->'chargeable_gains_in_development_levy_base'->>'default')::boolean, false) then v_f else 0 end;
    v_lev := case when v_dlevy_applies then round(v_lev_base * coalesce(private.rbn(rb, 'development_levy', 'rate'), 0.04), 2) else 0 end;
    v_etr := v_company and (v_turn >= coalesce((v_flags->'etr_turnover_threshold_ngn'->>'default')::numeric, private.rbn(rb, 'company_classification', 'thresholds', 'etr_turnover_trigger_ngn'), 50000000000)
             or (coalesce((prof->>'mne_constituent')::boolean, false) and coalesce((prof->>'group_turnover_eur')::numeric, 0) >= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'etr_mne_group_turnover_trigger_eur'), 750000000)));
    v_ni := v_pbt - v_fii - (private.v(pa, 'PROFIT_ADJUSTMENT!D39') - private.v(pa, 'PROFIT_ADJUSTMENT!D16'));
    v_cov := v_h + v_lev;
    if v_etr and v_ni > 0 and v_cov / v_ni < coalesce(private.rbn(rb, 'etr_topup', 'minimum_rate'), 0.15) then
      v_j := round(coalesce(private.rbn(rb, 'etr_topup', 'minimum_rate'), 0.15) * v_ni - v_cov, 2);
    end if;
    v_cit_payable := v_h;
    v_k := v_h + v_lev + v_j;
    v_loss_new := greatest(-v_ap, 0) - v_loss_vs_gains;
  end if;

  select coalesce(sum(b.bal), 0) into v_wht from private.balances_at(p_org, v_upto) b where split_part(b.code, '-', 1) = '1401';
  if v_source = 'imported' then v_wht := private.v(cells, 'STATEMENT_OF_FINANCIAL_POSITION!D51');
  -- Credits earlier years set against their tax stay in 1401 until their payment is recorded: not used twice.
  else v_wht_pending := least(greatest(v_wht, 0), private.cit_wht_pending(p_org, p_year, v_upto, p_bf->'wht_years')); end if;
  v_wht_used := round(least(greatest(v_wht - v_wht_pending, 0), v_cit_payable + v_j), 2);
  v_loss_cf := round(v_loss_bf - v_e1 + v_loss_new, 2);
  v_ca_cf := round(v_ca_avail - v_e2, 2);

  -- The computation, line by line, as the rule book stages it.
  v_rows := jsonb_build_array(
    jsonb_build_object('id', 'A', 'line', 'Profit / (loss) before tax', 'amount', v_pbt, 'basis', 'INCOME_STATEMENT!E115', '_style', 'subtotal'),
    jsonb_build_object('id', 'B', 'line', 'Add: disallowable expenses', 'amount', v_b, 'basis', 'PROFIT_ADJUSTMENT!E33 (depreciation ' || private.naira(v_dep) || ' and rows 14-32)', '_style', 'line'),
    jsonb_build_object('id', 'C', 'line', 'Less: non-taxable income and tax-only deductions', 'amount', -v_c, 'basis', 'PROFIT_ADJUSTMENT!E41', '_style', 'line'),
    jsonb_build_object('id', 'D', 'line', case when v_legacy then 'Adjusted profit / (loss)' else 'Assessable profit / (loss)' end, 'amount', v_d, '_style', 'subtotal'))
  || case when v_bc <> 0 then jsonb_build_array(jsonb_build_object('id', 'D2', 'line', 'Add: balancing charges', 'amount', v_bc, 'basis', 'Capital allowance schedule', '_style', 'line')) else '[]'::jsonb end
  || case when v_legacy then jsonb_build_array(jsonb_build_object('id', 'AP', 'line', 'Assessable profit / (loss)', 'amount', v_ap, '_style', 'subtotal')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('id', 'E1', 'line', 'Less: losses brought forward', 'amount', -v_e1, 'basis', private.naira(v_loss_bf) || ' brought forward; no time limit', '_style', 'line'),
    jsonb_build_object('id', 'E2', 'line', 'Less: capital allowances', 'amount', -v_e2, 'basis', private.naira(v_ca_avail) || ' available'
      || case when v_ca_bf > 0 then ' (' || private.naira(v_ca_bf) || ' brought forward)' else '' end
      || case when v_legacy and v_restricted then '; limited to two-thirds of assessable profit' else '' end, '_style', 'line'))
  || case when not v_legacy then jsonb_build_array(jsonb_build_object('id', 'F', 'line', 'Add: net chargeable gains', 'amount', v_f, 'basis', 'Disposals in the year (s.27(1), s.33-55)', '_style', 'line')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('id', 'G', 'line', 'Total profits', 'amount', v_g, '_style', 'subtotal'),
    jsonb_build_object('id', 'H', 'line', 'Companies income tax at ' || trim(to_char(coalesce(v_rate, 0) * 100, 'FM990.##')) || '% (' || lower(v_class) || ' company)', 'amount', v_h,
      'basis', case when v_legacy then 'CITA s.40' else 'NTA 2025 s.56' end, '_style', 'line'))
  || case when v_legacy then jsonb_build_array(
       jsonb_build_object('id', 'MT', 'line', 'Minimum tax (0.5% of turnover less franked investment income)', 'amount', v_mt,
         'basis', case when v_mt_applies then case when v_mt_used then 'Higher than the CIT computed, so it is payable instead' else 'Lower than the CIT computed' end
                  else 'Not applicable to this company' end, '_style', 'line'),
       jsonb_build_object('id', 'I', 'line', 'Tertiary education tax at ' || trim(to_char(v_tet_rate * 100, 'FM990.##')) || '% of assessable profit', 'amount', v_tet,
         'basis', case when v_small then 'Not charged on a small company' else 'TETFund Act s.1(2) as amended' end, '_style', 'line'))
     else jsonb_build_array(
       jsonb_build_object('id', 'I', 'line', 'Development levy at ' || trim(to_char(coalesce(private.rbn(rb, 'development_levy', 'rate'), 0.04) * 100, 'FM990.##')) || '% of assessable profit',
         'amount', v_lev, 'basis', case when v_dlevy_applies then 'NTA 2025 s.59' else 'Not charged on a ' || lower(v_class) || ' company' end, '_style', 'line'),
       jsonb_build_object('id', 'J', 'line', 'Minimum effective tax top-up (15%)', 'amount', v_j, 'basis', case when v_etr then 'NTA 2025 s.57' else 'Not in scope' end, '_style', 'line')) end
  || jsonb_build_array(
    jsonb_build_object('id', 'K', 'line', 'Total tax for the year', 'amount', v_k, '_style', 'subtotal'),
    jsonb_build_object('id', 'W', 'line', 'Less: withholding tax credit notes held', 'amount', -v_wht_used, 'basis', private.naira(v_wht) || ' held'
      || case when v_wht_pending > 0 then ', of which ' || private.naira(v_wht_pending) || ' is already set against earlier years'' tax' else '' end
      || '; set against companies income tax only', '_style', 'line'),
    jsonb_build_object('id', 'P', 'line', 'Tax payable', 'amount', v_k - v_wht_used, '_style', 'total'));

  -- Checks before the return can be approved.
  if v_source = 'books' and abs(coalesce(v_books_pbt, v_pbt) - v_pbt) >= 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pbt_ties_to_books', 'severity', 'warn',
      'text', 'Profit before tax is ' || private.naira(v_pbt) || ' after the lines you changed; the books give ' || private.naira(v_books_pbt) || '.'));
  end if;
  if v_source = 'books' and not private.cit_books_cover(p_org, v_from, v_to) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'books_partial', 'severity', 'block',
      'text', 'Counta''s books start on ' || private.fdate(coalesce(o.books_start, (select min(j.entry_date) from journals j where j.org_id = p_org))) || ', after this year began. '
        || 'Use the audited accounts or a trial balance for the whole year instead.'));
  end if;
  if abs(private.v(t, 'total_assets') - private.v(t, 'total_equity_liabilities')) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'sfp_ties_to_accounts', 'severity', 'block',
      'text', 'Total assets (' || private.naira(private.v(t, 'total_assets')) || ') do not equal equity and liabilities (' || private.naira(private.v(t, 'total_equity_liabilities')) || ').'));
  end if;
  if v_source = 'imported' and cy.imported_from ? 'profit_before_tax' and abs(coalesce((cy.imported_from->>'profit_before_tax')::numeric, v_pbt) - v_pbt) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pbt_ties_to_afs', 'severity', 'block',
      'text', 'Profit before tax from the lines is ' || private.naira(v_pbt) || '; the audited accounts show ' || private.naira((cy.imported_from->>'profit_before_tax')::numeric) || '.'));
  end if;
  if v_source = 'imported' and cy.imported_from ? 'revenue' and abs(coalesce((cy.imported_from->>'revenue')::numeric, v_turn) - v_turn) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'revenue_ties_to_pl', 'severity', 'block',
      'text', 'Revenue on the template is ' || private.naira(v_turn) || '; the audited accounts show ' || private.naira((cy.imported_from->>'revenue')::numeric) || '.'));
  end if;
  if v_source = 'imported' and jsonb_typeof(cy.imported) = 'object' and (select count(*) from jsonb_object_keys(cy.imported)) = 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'figures_missing', 'severity', 'block',
      'text', 'Counta does not hold this year in its books. Upload the audited accounts or a trial balance, or enter the figures.'));
  end if;
  if private.v(cells, 'OTHER_INCOME!D12') > 0 and private.v(cells, 'INCOME_STATEMENT!D113') <= 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'non_taxable_income_pairing', 'severity', 'block',
      'text', 'Non-taxable revenue of ' || private.naira(private.v(cells, 'OTHER_INCOME!D12')) || ' is declared: enter the expenses relating to it (profit adjustment row 14).'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('cell', l.cell, 'label', l.label, 'amount', private.v(cells, l.cell)) order by l.sort), '[]'::jsonb) into v_others
    from cit_template_lines l where l.cell in ('ADMINISTRATIVE_EXPENSES!C70', 'OTHER_INCOME!D17', 'STATEMENT_OF_FINANCIAL_POSITION!D62', 'STATEMENT_OF_FINANCIAL_POSITION!D92',
      'STATEMENT_OF_FINANCIAL_POSITION!D42', 'STATEMENT_OF_FINANCIAL_POSITION!D110', 'INCOME_STATEMENT!D27') and private.v(cells, l.cell) <> 0;
  if jsonb_array_length(v_others) > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'no_expense_lumping', 'severity', 'warn', 'items', v_others,
      'text', 'Some amounts sit on "Others" lines: ' || (select string_agg(o2->>'label' || ' ' || private.naira((o2->>'amount')::numeric), '; ') from jsonb_array_elements(v_others) o2)
        || '. Rev360 asks for each expense on its own line where the template has one.'));
  end if;
  if private.v(cells, 'INCOME_STATEMENT!D27') > 0 and v_turn > 0 and private.v(cells, 'INCOME_STATEMENT!D27') / v_turn > 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'sector_revenue_block', 'severity', 'warn',
      'text', 'Most revenue is under "Others". Post sales to the revenue account for your sector so the right block is filled.'));
  end if;
  if exists (select 1 from jsonb_each(cells) where key in (select cell from cit_template_lines where positive_only) and value::numeric < 0) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'positive_only', 'severity', 'block',
      'text', 'These lines only take amounts above zero on the template: ' || (select string_agg(l.label, ', ') from cit_template_lines l where l.positive_only and private.v(cells, l.cell) < 0) || '.'));
  end if;
  if not v_ended then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'year_not_ended', 'severity', 'block',
      'text', 'The year ends on ' || private.fdate(v_to) || '. Until then this is an estimate.'));
  end if;
  if cy.afs_path is null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'afs_attached', 'severity', 'block',
      'text', 'Attach the audited financial statements (PDF): auditor''s report, statements, notes and the capital allowance schedule.'));
  end if;
  if rbr.status <> 'approved' then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'rulebook_pending', 'severity', 'warn',
      'text', 'The rules for this year (' || coalesce(rb->'meta'->>'config_id', '') || ' ' || rbr.version || ') are awaiting TaxStreem sign-off.'));
  end if;
  if jsonb_array_length(ca->'missing') > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'ca_category_missing', 'severity', 'warn',
      'text', 'No Rev360 category for: ' || (select string_agg(value, ', ') from jsonb_array_elements_text(ca->'missing')) || '. They get no allowance until a category is chosen.'));
  end if;
  if not v_company then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'not_company', 'severity', 'block', 'text',
      case when private.income_tax_kind(p_org) = 'exempt' then 'The business is exempt from income tax unless it carries on a trade or business (NTA 2025 s.162(1)(a)(iii)). The owner says so under Income tax.'
           else 'The business is not a company: its owners file personal income tax instead, under Income tax.' end));
  end if;
  if v_nonres or coalesce(prof->>'sector_regime', '') <> '' or coalesce(o.industry, '') = 'other' and coalesce((prof->>'hydrocarbon')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'out_of_scope', 'severity', 'block',
      'text', 'This company is taxed under special rules (' || coalesce(nullif(prof->>'sector_regime', ''), case when v_nonres then 'non-resident' else 'sector regime' end) || ') that Counta does not compute yet.'));
  end if;
  if v_comm is not null and v_legacy and p_year - extract(year from v_comm)::int < 3 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'commencement_years', 'severity', 'warn',
      'text', 'The business started on ' || private.fdate(v_comm) || ': the first years use special basis periods under CITA s.29. Check the year of assessment with your adviser.'));
  end if;
  if v_small then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'small_company_still_files', 'severity', 'info', 'text', 'A small company still files a full return.'));
  end if;
  if private.v(cells, 'INCOME_STATEMENT!D116') = 0 and v_source = 'books' and private.v(codes, '7501') + private.v(codes, '7502') + private.v(codes, '7503') < 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'tax_credit', 'severity', 'info', 'text', 'The tax line in the accounts is a credit; the template takes a charge only, so it is left empty.'));
  end if;

  return jsonb_build_object('year', p_year, 'yoa', v_yoa, 'from', v_from, 'to', v_to, 'as_of', v_upto, 'ended', v_ended, 'source', v_source,
    'regime', rbr.regime, 'rulebook', jsonb_build_object('id', rbr.id, 'version', rbr.version, 'status', rbr.status, 'law', rb->'meta'->>'governing_law'),
    'class', v_class, 'small', v_small, 'company', v_company, 'cells', cells, 'detail', det, 'totals', t, 'adjustments', pa, 'items', items,
    'ca', ca, 'rows', v_rows,
    'figures', jsonb_build_object('profit_before_tax', v_pbt, 'turnover', v_turn, 'fixed_assets', v_fixed, 'addbacks', v_b, 'deductions', v_c, 'assessable', v_d,
      'balancing_charge', v_bc, 'assessable_after_bc', v_ap, 'loss_relief', v_e1, 'capital_allowances_available', v_ca_avail, 'capital_allowances', v_e2,
      'chargeable_gains', v_f, 'total_profits', v_g, 'cit_rate', v_rate, 'cit', v_h, 'minimum_tax', v_mt, 'minimum_tax_applies', v_mt_applies,
      'minimum_tax_used', v_mt_used, 'cit_payable', v_cit_payable, 'tertiary_education_tax', v_tet, 'development_levy', case when v_legacy then 0 else v_lev end,
      'etr_in_scope', coalesce(v_etr, false), 'etr_net_income', v_ni, 'topup', v_j, 'total_tax', v_k, 'wht_credit', v_wht_used, 'wht_held', v_wht, 'wht_pending', v_wht_pending,
      'payable', v_k - v_wht_used, 'ebitda', round(v_ebitda, 2), 'connected_interest', v_conn, 'interest_excess', v_excess, 'interest_relief', v_relief,
      'restricted', coalesce(v_restricted, false), 'cap', v_cap, 'short_factor', v_short),
    'bf', jsonb_build_object('losses', v_loss_bf, 'ca', v_ca_bf, 'interest', v_int_bf, 'from_previous_year', not v_first_open),
    'cf', jsonb_build_object('losses', v_loss_cf, 'ca', v_ca_cf, 'interest', v_int_cf),
    'checks', v_checks, 'due', (v_to + interval '6 months')::date,
    'status', coalesce(cy.status, 'draft'));
end $function$;

-- private.cit_run: each year is given the credits earlier years used, across years without figures too.
CREATE OR REPLACE FUNCTION private.cit_run(p_org uuid, p_year integer, p_as_of date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare y int; y0 int := least(private.cit_first_year(p_org), p_year); bf jsonb := null; comp jsonb; cy public.cit_years; v_used jsonb := '{}'::jsonb;
begin
  for y in y0 .. p_year loop
    select * into cy from cit_years where org_id = p_org and accounting_year = y;
    if y < p_year and not private.cit_has_data(p_org, y) then bf := null; continue; end if;
    if cy.snapshot is not null and cy.status <> 'draft' then comp := cy.snapshot->'computation';
    else comp := private.cit_compute(p_org, y, private.cit_bf(bf, v_used), case when y = p_year then p_as_of end); end if;
    v_used := private.cit_wht_note(v_used, comp);
    bf := comp->'cf';
  end loop;
  return comp;
end $function$;

-- private.cit_chain: the same, for the years list.
CREATE OR REPLACE FUNCTION private.cit_chain(p_org uuid, p_upto integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare y int; y0 int := least(private.cit_first_year(p_org), p_upto); bf jsonb := null; comp jsonb; cy public.cit_years; v jsonb := '[]'::jsonb; v_has boolean; v_used jsonb := '{}'::jsonb;
begin
  for y in y0 .. p_upto loop
    select * into cy from cit_years where org_id = p_org and accounting_year = y;
    v_has := private.cit_has_data(p_org, y);
    if not v_has and cy.accounting_year is null and y < p_upto then
      v := v || jsonb_build_array(jsonb_build_object('year', y, 'yoa', y + 1, 'has_data', false));
      bf := null; continue;
    end if;
    if cy.snapshot is not null and cy.status <> 'draft' then comp := cy.snapshot->'computation';
    else comp := private.cit_compute(p_org, y, private.cit_bf(bf, v_used), null); end if;
    v_used := private.cit_wht_note(v_used, comp);
    v := v || jsonb_build_array(comp || jsonb_build_object('has_data', v_has));
    bf := case when v_has then comp->'cf' end;
  end loop;
  return v;
end $function$;

-- private.post_tax_paid: the 1401 line a CIT payment clears names its year.
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

-- private.pit_compute: credits earlier years used leave 1401 when their returns are approved; only what 1401 still holds at this year end is taken off again (books only).
CREATE OR REPLACE FUNCTION private.pit_compute(p_org uuid, p_year integer, p_bf jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; rbr public.tax_rulebooks; rb jsonb; v_kind text; b jsonb; bf jsonb; ppl jsonb; x jsonb; v_out jsonb := '[]'::jsonb; t jsonb;
  py public.pit_years; v_wht_used_bf numeric; v_wht_avail numeric; v_wht_pending numeric; v_role text; v_auth text; v_share numeric; v_sum numeric := 0; v_n int;
  v_tax numeric := 0; v_payable numeric := 0; v_wht_used numeric := 0; v_cgt numeric := 0; v_cf jsonb := '{}'::jsonb; v_checks jsonb := '[]'::jsonb;
  v_flags jsonb; v_open text; v_rem numeric := 0; v_lb numeric; v_cb numeric; v_loc record; v_auth_name text; v_lines jsonb; v_flux text[];
  v_new text; v_gone text; v_prev_n int; rc jsonb; v_reliefs jsonb; v_has_flux boolean; v_staff_pay numeric;
  v_bot text[] := private.pit_bot_authorities();
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
  v_wht_pending := greatest(v_wht_used_bf - case when b->>'source' = 'imported' then 0
    else private.wht_cleared(p_org, 'pit', p_year, (b->>'to')::date) end, 0);
  v_wht_avail := greatest(private.v(b->'figures', 'wht_held') - v_wht_pending, 0);
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
      'flux', v_auth = any(v_flux) or v_auth = any(v_bot), 'bot', v_auth = any(v_bot), 'reliefs_claimed', rc->'claimed', 'reliefs_held', rc->'held', 'income_fields', private.pit_portal_income(t),
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
  -- The business's staff screen is for the states Flux files; on e-Tax each person lists their own household staff.
  v_has_flux := exists (select 1 from jsonb_array_elements(v_out) p where (p->>'flux')::boolean and not coalesce((p->>'bot')::boolean, false));
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
    where (p->>'flux')::boolean and not coalesce((p->>'bot')::boolean, false)
      and not exists (select 1 from portal_logins l where l.org_id = p_org and l.authority = p->>'authority');
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'portal_login', 'severity', 'warn',
      'text', 'Save the business''s ' || v_open || ' login under Settings, Tax portal logins, so Flux can file the return.'));
  end if;
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p
    where coalesce((p->>'bot')::boolean, false)
      and not exists (select 1 from pit_etax_logins l where l.org_id = p_org and l.person_id = (p->>'person_id')::uuid and l.authority = p->>'authority');
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'etax_login', 'severity', 'warn',
      'text', 'Save the e-Tax login (Payer ID and password) of ' || v_open || ' under People, so Counta can file the return on LIRS e-Tax.'));
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
      'wht_available', v_wht_avail, 'wht_pending', v_wht_pending, 'wht_credit_used', v_wht_used, 'cgt', v_cgt, 'people', v_n, 'shares_total', v_sum),
    'bf', jsonb_build_object('wht_used', v_wht_used_bf, 'from_previous_year', p_bf is not null),
    'cf', jsonb_build_object('people', v_cf, 'wht_used', round(v_wht_used_bf + v_wht_used, 2)),
    'status', coalesce(py.status, 'draft'), 'staff', coalesce(py.staff, '[]'::jsonb),
    'staff_review', jsonb_build_object('reviewed', coalesce((py.settings->>'staff_reviewed')::boolean, false), 'by', py.settings->>'staff_by', 'at', py.settings->>'staff_at'));
end $function$;

-- public.approve_pit_year: the credit the return uses moves out of 1401 (private.pit_wht_post).
CREATE OR REPLACE FUNCTION public.approve_pit_year(p_org uuid, p_year integer, p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; py public.pit_years; comp jsonb; v_blocks text; x jsonb; v_statement text; v_wht_journal uuid;
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
      accommodation, pension_details, household_staff, status, updated_by)
    values (p_org, p_year, (x->>'person_id')::uuid, private.num(x->>'share_pct'), x->>'role', nullif(x->>'office_location_id', '')::uuid, nullif(x->>'residence', ''),
      coalesce((x->>'resident')::boolean, true), coalesce(private.num(x->>'remuneration'), 0), coalesce(x->'reliefs', '{}'::jsonb), coalesce(x->'other_income', '[]'::jsonb),
      coalesce(x->'opening', '{}'::jsonb), coalesce(x->'accommodation', '{}'::jsonb), coalesce(x->'pension_details', '{}'::jsonb), coalesce(x->'household_staff', '[]'::jsonb), 'approved', m.id)
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
  v_wht_journal := private.pit_wht_post(p_org, p_year, comp, m);
  if v_wht_journal is not null then
    update pit_years set settings = settings || jsonb_build_object('wht_journal_id', v_wht_journal) where org_id = p_org and accounting_year = p_year;
  end if;
  return public.pit_year(p_org, p_year);
end $function$;

-- public.reopen_pit_year: the credit moved out of 1401 on approval goes back.
CREATE OR REPLACE FUNCTION public.reopen_pit_year(p_org uuid, p_year integer, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; py public.pit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or py.status <> 'approved' then raise exception 'Only an approved return can be reopened.'; end if;
  if exists (select 1 from pit_person_years where org_id = p_org and accounting_year = p_year and status in ('sent', 'filed')) then
    raise exception 'A return in this year is being filed or is filed. File an amended return with the state instead.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why the return is reopened.'; end if;
  if py.settings ? 'wht_journal_id' and exists (select 1 from journals where id = (py.settings->>'wht_journal_id')::uuid)
     and not exists (select 1 from journals where reversal_of = (py.settings->>'wht_journal_id')::uuid) then
    perform private.reverse_entry((py.settings->>'wht_journal_id')::uuid, m.id, 'The ' || p_year || ' return was reopened', now());
  end if;
  update pit_years set status = 'draft', snapshot = null, approved_by = null, approved_at = null,
    settings = (settings - 'wht_journal_id') || jsonb_build_object('reopened', jsonb_build_object('by', m.display_name, 'at', now(), 'reason', left(trim(p_reason), 300))),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  update lirs_jobs set status = 'cancelled', error = 'The return was reopened.', finished_at = now(), updated_at = now()
  where org_id = p_org and accounting_year = p_year and status = 'queued';
  update pit_person_years set status = 'draft', flux_ref = null, flux_status = null, flux_message = null, flux_sent_at = null, computation_path = null,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $function$;

-- ---------------------------------------------------------------------------
-- 4. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.wht_cleared(uuid, text, integer, date), private.cit_wht_pending(uuid, integer, date, jsonb), private.cit_bf(jsonb, jsonb),
  private.cit_wht_note(jsonb, jsonb), private.pit_wht_post(uuid, integer, jsonb, public.members) from public, anon, authenticated;
